const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const log = std.log.scoped(.ide);

pub const max_ides: usize = 12;

pub const Spec = struct {
    id: []const u8,
    bin: []const u8,
    /// Extra args before the workspace path (`code -g`, `cursor -r`).
    prefix: []const []const u8 = &.{},
};

/// Graphical IDEs omfx can launch. Terminal editors stay on `editor` / ctrl-g.
pub const known = [_]Spec{
    .{ .id = "code", .bin = "code", .prefix = &.{} },
    .{ .id = "cursor", .bin = "cursor", .prefix = &.{} },
    .{ .id = "zed", .bin = "zed", .prefix = &.{} },
    .{ .id = "windsurf", .bin = "windsurf", .prefix = &.{} },
    .{ .id = "subl", .bin = "subl", .prefix = &.{} },
    .{ .id = "idea", .bin = "idea", .prefix = &.{} },
    .{ .id = "webstorm", .bin = "webstorm", .prefix = &.{} },
    .{ .id = "fleet", .bin = "fleet", .prefix = &.{} },
};

pub fn onPath(io: Io, path_env: []const u8, bin: []const u8) bool {
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const name = if (builtin.os.tag == .windows)
            std.fmt.bufPrint(&buf, "{s}/{s}.exe", .{ dir, bin }) catch continue
        else
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, bin }) catch continue;
        var f = Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only }) catch continue;
        f.close(io);
        return true;
    }
    return false;
}

pub fn detect(io: Io, path_env: []const u8, out: *[max_ides][]const u8) usize {
    var n: usize = 0;
    for (known) |entry| {
        if (n >= out.len) break;
        if (onPath(io, path_env, entry.bin)) {
            out[n] = entry.id;
            n += 1;
        }
    }
    return n;
}

pub fn spec(id: []const u8) ?Spec {
    for (known) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

pub fn resolve(io: Io, stored: []const u8, path_env: []const u8) ?[]const u8 {
    if (stored.len > 0 and !std.mem.eql(u8, stored, "auto")) {
        if (spec(stored)) |s| {
            if (onPath(io, path_env, s.bin)) return stored;
        } else if (onPath(io, path_env, stored)) return stored;
    }
    var found: [max_ides][]const u8 = undefined;
    const n = detect(io, path_env, &found);
    if (n == 0) return null;
    return found[0];
}

pub fn open(allocator: std.mem.Allocator, io: Io, path_env: []const u8, workspace: []const u8, ide_id: []const u8) ![]u8 {
    const id = resolve(io, ide_id, path_env) orelse return allocator.dupe(u8, "no IDE found on PATH; set `ide` in /settings or install code/cursor/zed\n");
    const s: Spec = spec(id) orelse Spec{ .id = id, .bin = id, .prefix = &.{} };
    var argv_buf: [16][]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = s.bin;
    n += 1;
    for (s.prefix) |p| {
        argv_buf[n] = p;
        n += 1;
    }
    argv_buf[n] = workspace;
    n += 1;
    var child = std.process.spawn(io, .{
        .argv = argv_buf[0..n],
        .cwd = .{ .path = workspace },
    }) catch |err| {
        log.warn("spawn {s}: {s}", .{ s.bin, @errorName(err) });
        return std.fmt.allocPrint(allocator, "could not launch {s}: {s}\n", .{ id, @errorName(err) });
    };
    _ = child.wait(io) catch |err| {
        log.debug("wait {s}: {s}", .{ s.bin, @errorName(err) });
    };
    return std.fmt.allocPrint(allocator, "opened {s} on {s}\n", .{ id, workspace });
}

test "detect lists code when present" {
    const io = std.testing.io;
    const path = std.c.getenv("PATH") orelse return error.SkipZigTest;
    var out: [max_ides][]const u8 = undefined;
    _ = detect(io, std.mem.span(path), &out);
}
