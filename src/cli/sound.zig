//! Launch and turn-end chimes. Recipes are from cuelume (MIT, Daniel Belyi);
//! see `sounds/NOTICE`. macOS plays the AAC through afplay; everywhere else
//! falls back to the terminal bell.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const env = @import("../core/env.zig");
const permissions = @import("../core/permissions.zig");

const log = std.log.scoped(.sound);

pub const Cue = enum { bloom, success };

const macos_player = "/usr/bin/afplay";

fn chime(cue: Cue) []const u8 {
    return switch (cue) {
        .bloom => @embedFile("sounds/bloom.m4a"),
        .success => @embedFile("sounds/success.m4a"),
    };
}

fn fileName(cue: Cue) []const u8 {
    return switch (cue) {
        .bloom => "omfx-bloom.m4a",
        .success => "omfx-success.m4a",
    };
}

var paths: [std.enums.values(Cue).len]?[]const u8 = .{null} ** std.enums.values(Cue).len;
var path_bufs: [std.enums.values(Cue).len][std.fs.max_path_bytes]u8 = undefined;

pub fn play(io: Io, lookup: env.Lookup, cue: Cue) void {
    if (comptime builtin.os.tag != .macos) {
        permissions.writeBell(io);
        return;
    }
    const path = materialize(io, lookup, cue) orelse {
        permissions.writeBell(io);
        return;
    };
    spawnPlayer(io, path) catch |err| {
        log.debug("afplay: {s}", .{@errorName(err)});
        permissions.writeBell(io);
    };
}

fn materialize(io: Io, lookup: env.Lookup, cue: Cue) ?[]const u8 {
    const idx = @intFromEnum(cue);
    if (paths[idx]) |path| return path;

    const dir = lookup.get("TMPDIR") orelse "/tmp";
    const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
    const path = std.fmt.bufPrint(&path_bufs[idx], "{s}{s}{s}", .{ dir, sep, fileName(cue) }) catch return null;
    const bytes = chime(cue);
    if (!fileMatches(io, path, bytes)) {
        writeCue(Io.Dir.cwd(), io, path, bytes) catch |err| {
            log.debug("chime write: {s}", .{@errorName(err)});
            return null;
        };
    }
    paths[idx] = path;
    return path;
}

fn fileMatches(io: Io, path: []const u8, expected: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.size != expected.len) return false;
    const got = Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(expected.len)) catch return false;
    defer std.heap.page_allocator.free(got);
    return std.mem.eql(u8, got, expected);
}

fn writeCue(dir: Io.Dir, io: Io, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

const Waiter = struct {
    io: Io,
    child: std.process.Child,

    fn run(self: *Waiter) void {
        _ = self.child.wait(self.io) catch |err| {
            log.debug("afplay wait: {s}", .{@errorName(err)});
        };
        std.heap.page_allocator.destroy(self);
    }
};

fn spawnPlayer(io: Io, path: []const u8) !void {
    const waiter = try std.heap.page_allocator.create(Waiter);
    errdefer std.heap.page_allocator.destroy(waiter);
    waiter.* = .{
        .io = io,
        .child = try std.process.spawn(io, .{
            .argv = &.{ macos_player, path },
            .stdin = .close,
            .stdout = .ignore,
            .stderr = .ignore,
        }),
    };
    const thread = std.Thread.spawn(.{}, Waiter.run, .{waiter}) catch {
        waiter.run();
        return;
    };
    thread.detach();
}

test "chimes are AAC" {
    try std.testing.expect(std.mem.indexOf(u8, chime(.bloom), "ftyp") != null);
    try std.testing.expect(std.mem.indexOf(u8, chime(.success), "ftyp") != null);
    try std.testing.expect(chime(.bloom).len > 1000);
    try std.testing.expect(chime(.success).len > 1000);
}

test "writeCue round-trips the embedded bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCue(tmp.dir, io, "bloom.m4a", chime(.bloom));
    const got = try tmp.dir.readFileAlloc(io, "bloom.m4a", std.testing.allocator, .limited(16_384));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, chime(.bloom), got);
}
