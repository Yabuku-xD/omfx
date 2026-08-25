const std = @import("std");
const deadline = @import("../tools/deadline.zig");
const orient_mod = @import("orient.zig");

pub const OrientDepth = orient_mod.Depth;
pub const orientDepth = orient_mod.orientDepth;

/// Orientation, not a long operation.
pub const git_secs: u32 = 15;
const Io = std.Io;

const log = std.log.scoped(.context);

/// AGENTS.md is a table of contents, not a dump. 8000 bytes is the tripwire.
pub const agents_max_bytes: usize = 8_000;
/// git status -sb is a few lines; 1500 bytes names a runaway status.
pub const git_max_bytes: usize = 1_500;

fn existsFile(dir: Io.Dir, io: Io, name: []const u8) bool {
    var f = dir.openFile(io, name, .{ .mode = .read_only }) catch return false;
    f.close(io);
    return true;
}

fn existsDir(dir: Io.Dir, io: Io, name: []const u8) bool {
    var d = dir.openDir(io, name, .{}) catch return false;
    d.close(io);
    return true;
}

fn firstLine(src: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    return std.mem.trim(u8, src[0..nl], " \t\r#");
}

pub const Scaffold = union(enum) {
    exists: usize,
    wrote: usize,
};

const Row = struct {
    name: []const u8,
    dir: bool = false,
    layout: []const u8,
    verify: []const u8 = "",
};

const rows = [_]Row{
    .{ .name = "src", .dir = true, .layout = "- `src/` is source.\n" },
    .{ .name = "build.zig", .layout = "- `build.zig` is the build graph.\n", .verify = "- `zig build test`\n- `zig build`\n" },
    .{ .name = "package.json", .layout = "- `package.json` is the JS package manifest.\n", .verify = "- `npm test`\n" },
    .{ .name = "go.mod", .layout = "- `go.mod` is the Go module.\n", .verify = "- `go test ./...`\n" },
    .{ .name = "Cargo.toml", .layout = "- `Cargo.toml` is the Rust package.\n", .verify = "- `cargo test`\n" },
    .{ .name = "pyproject.toml", .layout = "- `pyproject.toml` is the Python project.\n", .verify = "- `pytest`\n" },
    .{ .name = "Makefile", .layout = "", .verify = "- `make test`\n" },
};

fn present(dir: Io.Dir, io: Io, row: Row) bool {
    return if (row.dir) existsDir(dir, io, row.name) else existsFile(dir, io, row.name);
}

/// Write a short project map. Refuses to replace an existing file unless `overwrite`.
pub fn scaffoldAgents(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, overwrite: bool) !Scaffold {
    if (existsFile(dir, io, "AGENTS.md") and !overwrite) {
        const body = try readCapped(dir, io, allocator, "AGENTS.md", agents_max_bytes) orelse try allocator.dupe(u8, "");
        defer allocator.free(body);
        return .{ .exists = body.len };
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# AGENTS.md\n\nInstructions for agents working in this repository.\n\n## Layout\n");
    for (rows) |row| {
        if (row.layout.len == 0) continue;
        if (present(dir, io, row)) try out.appendSlice(allocator, row.layout);
    }
    if (existsFile(dir, io, "README.md")) {
        if (try readCapped(dir, io, allocator, "README.md", 400)) |readme| {
            defer allocator.free(readme);
            const title = firstLine(readme);
            if (title.len > 0) {
                try out.appendSlice(allocator, "- README: ");
                try out.appendSlice(allocator, title);
                try out.append(allocator, '\n');
            }
        }
    }
    try out.appendSlice(allocator, "\n## Style\n- Prefer the smallest change that solves the request.\n- Do not invent paths. List or grep if unknown.\n\n## Verify\n");
    var verify: []const u8 = "- Run the project's existing tests.\n";
    for (rows) |row| {
        if (row.verify.len == 0) continue;
        if (!present(dir, io, row)) continue;
        verify = row.verify;
        break;
    }
    try out.appendSlice(allocator, verify);
    const body = try out.toOwnedSlice(allocator);
    defer allocator.free(body);
    var file = try dir.createFile(io, "AGENTS.md", .{ .truncate = true });
    defer file.close(io);
    var buf: [512]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
    return .{ .wrote = body.len };
}

pub fn loadAgents(dir: Io.Dir, io: Io, allocator: std.mem.Allocator) ![]u8 {
    if (try readCapped(dir, io, allocator, "AGENTS.md", agents_max_bytes)) |body| return body;
    if (try readCapped(dir, io, allocator, "CLAUDE.md", agents_max_bytes)) |body| return body;
    return allocator.dupe(u8, "");
}

fn hasGit(io: Io, workspace: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.git", .{workspace}) catch return false;
    var d = Io.Dir.cwd().openDir(io, p, .{}) catch {
        var f = Io.Dir.cwd().openFile(io, p, .{ .mode = .read_only }) catch return false;
        f.close(io);
        return true;
    };
    d.close(io);
    return true;
}

pub fn gitSnapshot(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    if (!hasGit(io, workspace)) return allocator.dupe(u8, "");
    // git blocks indefinitely on an index.lock or a credential prompt.
    var cap: deadline.Capped = undefined;
    cap.init(&.{ "git", "status", "-sb" }, git_secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return allocator.dupe(u8, "");
    };
    var out_buf: [1024]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    errdefer {
        collected.deinit(allocator);
        child.kill(io);
    }
    if (child.stdout) |f| {
        var reader = Io.File.Reader.initStreaming(f, io, &out_buf);
        while (reader.interface.takeByte()) |b| {
            try collected.append(allocator, b);
            if (collected.items.len >= git_max_bytes) break;
        } else |_| {}
    }
    const term = child.wait(io) catch {
        collected.deinit(allocator);
        return allocator.dupe(u8, "");
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        collected.deinit(allocator);
        return allocator.dupe(u8, "");
    }
    if (collected.items.len >= git_max_bytes) {
        try collected.appendSlice(allocator, "\ntruncated at 1500 bytes\n");
    }
    if (collected.items.len == 0) return allocator.dupe(u8, "");
    return collected.toOwnedSlice(allocator);
}

fn readCapped(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    cap: usize,
) !?[]u8 {
    var file = dir.openFile(io, name, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(allocator);
    var reader = Io.File.Reader.initStreaming(file, io, &buf);
    var truncated = false;
    while (reader.interface.takeByte()) |b| {
        if (collected.items.len >= cap) {
            truncated = true;
            break;
        }
        try collected.append(allocator, b);
    } else |_| {}
    if (collected.items.len == 0) {
        collected.deinit(allocator);
        return try allocator.dupe(u8, "");
    }
    if (truncated) {
        try collected.appendSlice(allocator, "\ntruncated at 8000 bytes\n");
    }
    return try collected.toOwnedSlice(allocator);
}

test "scaffoldAgents writes a map and refuses clobber" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    {
        var f = try tmp.dir.createFile(io, "build.zig", .{ .truncate = true });
        defer f.close(io);
        var buf: [16]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("// build\n");
        try w.interface.flush();
    }
    try tmp.dir.createDirPath(io, "src");
    const first = try scaffoldAgents(a, tmp.dir, io, false);
    try std.testing.expect(std.meta.activeTag(first) == .wrote);
    const body = try loadAgents(tmp.dir, io, a);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "`src/` is source.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "zig build test") != null);
    const second = try scaffoldAgents(a, tmp.dir, io, false);
    try std.testing.expect(std.meta.activeTag(second) == .exists);
}

test "missing agents file is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try loadAgents(tmp.dir, std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("", s);
}

test "loadAgents prefers AGENTS.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "AGENTS.md", .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("map: see README.md\n");
        try w.interface.flush();
    }
    {
        var f = try tmp.dir.createFile(io, "CLAUDE.md", .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("claude-only\n");
        try w.interface.flush();
    }
    const s = try loadAgents(tmp.dir, io, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "map: see README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "claude-only") == null);
}

test "git snapshot without repo is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try gitSnapshot(std.testing.allocator, std.testing.io, "/no-such-omfx-git-workspace");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("", s);
}

test "agents_max_bytes is 8000" {
    try std.testing.expectEqual(@as(usize, 8_000), agents_max_bytes);
}
