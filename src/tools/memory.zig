const std = @import("std");
const pathing = @import("pathing.zig");
const Io = std.Io;

const log = std.log.scoped(.memory);

pub fn path(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".omfx", "memory.jsonl" });
}

/// Receipt: a 200-fact store measured 12 KB. 64 KB is a tripwire for a file
/// that has stopped being a memory store, not a budget anyone should reach.
pub const max_store_bytes: usize = 64_000;
pub const prompt_max: usize = 8_000;
/// 20 jsonl facts × playbook.text_max (80).
pub const user_clip: usize = 1_600;

comptime {
    if (prompt_max == 0) @compileError("prompt_max must re-inject at least one memory line");
    if (user_clip == 0) @compileError("user_clip must hold at least one user fact");
}

const Source = enum { workspace, user };

/// Disk memory re-injected every turn (survives compact). Workspace file first, then user jsonl.
pub fn promptBlock(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    dir: Io.Dir,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    inline for (std.meta.tags(Source)) |src| {
        try appendSource(&out, allocator, io, home, dir, src);
    }
    return out.toOwnedSlice(allocator);
}

fn appendSource(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    dir: Io.Dir,
    src: Source,
) !void {
    switch (src) {
        .workspace => {
            const body = dir.readFileAlloc(io, ".omfx/memory.md", allocator, .limited(prompt_max)) catch return;
            defer allocator.free(body);
            if (body.len == 0) return;
            try out.appendSlice(allocator, "Memory (workspace .omfx/memory.md):\n");
            try out.appendSlice(allocator, body);
            if (body[body.len - 1] != '\n') try out.append(allocator, '\n');
        },
        .user => {
            if (home.len == 0) return;
            const p = path(allocator, home) catch return;
            defer allocator.free(p);
            const body = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(prompt_max)) catch return;
            defer allocator.free(body);
            if (body.len == 0) return;
            try out.appendSlice(allocator, "Memory (user):\n");
            const clip = if (body.len > user_clip) body[0..user_clip] else body;
            try out.appendSlice(allocator, clip);
            if (clip[clip.len - 1] != '\n') try out.append(allocator, '\n');
        },
    }
}

const Action = enum { list, clear, save };

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    action: []const u8,
    fact: []const u8,
) ![]u8 {
    const p = try path(allocator, home);
    defer allocator.free(p);
    const act = std.meta.stringToEnum(Action, action) orelse {
        return allocator.dupe(u8, "memory action must be save, list, or clear\n");
    };
    return switch (act) {
        .list => blk: {
            const body = read(io, p, allocator) catch |err| switch (err) {
                error.FileNotFound => break :blk allocator.dupe(u8, "(no memories)\n"),
                else => break :blk unreadable(allocator, p, err),
            };
            if (body.len == 0) {
                allocator.free(body);
                break :blk allocator.dupe(u8, "(no memories)\n");
            }
            break :blk body;
        },
        .clear => blk: {
            const dir = std.fs.path.dirname(p) orelse home;
            Io.Dir.cwd().createDirPath(io, dir) catch |err| {
                log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
            };
            var file = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
            defer file.close(io);
            break :blk allocator.dupe(u8, "cleared memories\n");
        },
        .save => blk: {
            if (fact.len == 0) break :blk allocator.dupe(u8, "memory save needs fact\n");
            const dir = std.fs.path.dirname(p) orelse home;
            Io.Dir.cwd().createDirPath(io, dir) catch |err| {
                log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
            };
            // A store we could not read is not an empty store. Appending to ""
            // and truncating would rewrite the file from nothing and take every
            // saved fact with it, so an oversized or corrupt file is left alone.
            const existing = read(io, p, allocator) catch |err| switch (err) {
                error.FileNotFound => "",
                else => break :blk unreadable(allocator, p, err),
            };
            defer if (existing.len > 0) allocator.free(existing);
            const next = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ existing, fact });
            defer allocator.free(next);
            var file = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
            defer file.close(io);
            var buf: [512]u8 = undefined;
            var w = file.writer(io, &buf);
            try w.interface.writeAll(next);
            try w.interface.flush();
            break :blk std.fmt.allocPrint(allocator, "saved memory\n", .{});
        },
    };
}

fn read(io: Io, p: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_store_bytes));
}

fn unreadable(allocator: std.mem.Allocator, p: []const u8, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "memory unreadable ({s}); left {s} as it is\n", .{
        @errorName(err),
        p,
    });
}

test "promptBlock loads workspace memory.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".omfx");
    var f = try tmp.dir.createFile(std.testing.io, ".omfx/memory.md", .{ .truncate = true });
    defer f.close(std.testing.io);
    var buf: [32]u8 = undefined;
    var w = f.writer(std.testing.io, &buf);
    try w.interface.writeAll("prefer zig fmt\n");
    try w.interface.flush();
    const s = try promptBlock(std.testing.allocator, std.testing.io, "", tmp.dir);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "prefer zig fmt") != null);
}

test "memory save list clear" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try pathing.testWorkspace(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(home_path);
    const saved = try run(std.testing.allocator, io, home_path, "save", "prefers zig");
    defer std.testing.allocator.free(saved);
    const listed = try run(std.testing.allocator, io, home_path, "list", "");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "prefers zig") != null);
    const cleared = try run(std.testing.allocator, io, home_path, "clear", "");
    defer std.testing.allocator.free(cleared);
    const empty = try run(std.testing.allocator, io, home_path, "list", "");
    defer std.testing.allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "no memories") != null);
}

test "an oversized store is reported, not overwritten" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try pathing.testWorkspace(a, &tmp);
    defer a.free(home_path);
    const p = try path(a, home_path);
    defer a.free(p);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);
    {
        var f = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        var i: usize = 0;
        while (i < max_store_bytes + 1) : (i += 1) try w.interface.writeByte('x');
        try w.interface.flush();
    }
    const said = try run(a, io, home_path, "save", "a new fact");
    defer a.free(said);
    try std.testing.expect(std.mem.indexOf(u8, said, "unreadable") != null);
    const after = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(max_store_bytes * 2));
    defer a.free(after);
    try std.testing.expectEqual(max_store_bytes + 1, after.len);
}
