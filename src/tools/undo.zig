const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const pathing = @import("pathing.zig");
const sse = @import("../providers/sse.zig");

const log = std.log.scoped(.undo);

pub const max_entries: usize = 16;
const dir_name = ".omfx/undo";
const index_name = ".omfx/undo/index.jsonl";

pub const Kind = enum { write, delete, rename };

comptime {
    if (max_entries == 0) @compileError("max_entries must keep at least one undo");
}

const Op = union(enum) {
    overwrite: struct { path: []const u8, slot: usize },
    create: []const u8,
    delete: struct { path: []const u8, slot: usize },
    rename: struct { from: []const u8, to: []const u8 },
};

fn parseOp(line: []const u8) ?Op {
    const kind_s = sse.jsonString(line, "k") orelse return null;
    const kind = std.meta.stringToEnum(Kind, kind_s) orelse return null;
    return switch (kind) {
        .write => blk: {
            const path = sse.jsonString(line, "p") orelse break :blk null;
            if (sse.jsonString(line, "n")) |n_s| {
                const slot = std.fmt.parseInt(usize, n_s, 10) catch break :blk null;
                break :blk .{ .overwrite = .{ .path = path, .slot = slot } };
            }
            break :blk .{ .create = path };
        },
        .delete => blk: {
            const path = sse.jsonString(line, "p") orelse break :blk null;
            const n_s = sse.jsonString(line, "n") orelse break :blk null;
            const slot = std.fmt.parseInt(usize, n_s, 10) catch break :blk null;
            break :blk .{ .delete = .{ .path = path, .slot = slot } };
        },
        .rename => blk: {
            const from = sse.jsonString(line, "a") orelse break :blk null;
            const to = sse.jsonString(line, "b") orelse break :blk null;
            break :blk .{ .rename = .{ .from = from, .to = to } };
        },
    };
}

fn ensureDir(dir: Io.Dir, io: Io) void {
    dir.createDirPath(io, dir_name) catch |err| {
        log.warn("mkdir undo: {s}", .{@errorName(err)});
    };
}

fn blobName(buf: *[48]u8, slot: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{d}", .{ dir_name, slot }) catch dir_name;
}

fn indexBlob(allocator: std.mem.Allocator, dir: Io.Dir, io: Io) std.mem.Allocator.Error![]u8 {
    return dir.readFileAlloc(io, index_name, allocator, .limited(64_000)) catch allocator.dupe(u8, "");
}

fn nextSlot(blob: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

fn appendLine(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, line: []const u8) void {
    const existing = indexBlob(allocator, dir, io) catch return;
    defer allocator.free(existing);
    const joined = std.mem.concat(allocator, u8, &.{ existing, line }) catch return;
    defer allocator.free(joined);
    var file = dir.createFile(io, index_name, .{ .truncate = true }) catch |err| {
        log.warn("open undo index: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(joined) catch return;
    w.interface.flush() catch {};
}

fn writeBlob(dir: Io.Dir, io: Io, slot: usize, bytes: []const u8) void {
    var name_buf: [48]u8 = undefined;
    const name = blobName(&name_buf, slot);
    var file = dir.createFile(io, name, .{ .truncate = true }) catch |err| {
        log.warn("undo blob: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(bytes) catch return;
    w.interface.flush() catch {};
}

fn readBlob(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, slot: usize) ?[]u8 {
    var name_buf: [48]u8 = undefined;
    const name = blobName(&name_buf, slot);
    return dir.readFileAlloc(io, name, allocator, .limited(1_000_000)) catch null;
}

fn rewriteIndex(dir: Io.Dir, io: Io, keep: []const u8) void {
    var file = dir.createFile(io, index_name, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    if (keep.len > 0) w.interface.writeAll(keep) catch {};
    w.interface.flush() catch {};
}

pub fn recordWrite(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    access: pathing.Access,
    path: []const u8,
) void {
    pathing.assertInside(access, path) catch return;
    ensureDir(dir, io);
    const index = indexBlob(allocator, dir, io) catch return;
    defer allocator.free(index);
    const slot = nextSlot(index);
    if (fs.read(dir, io, allocator, access, path)) |body| {
        defer allocator.free(body);
        writeBlob(dir, io, slot, body);
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{{\"k\":\"write\",\"p\":\"{s}\",\"n\":\"{d}\"}}\n", .{ path, slot }) catch return;
        appendLine(allocator, dir, io, line);
    } else |_| {
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{{\"k\":\"write\",\"p\":\"{s}\"}}\n", .{path}) catch return;
        appendLine(allocator, dir, io, line);
    }
}

pub fn recordDelete(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    access: pathing.Access,
    path: []const u8,
) void {
    pathing.assertInside(access, path) catch return;
    ensureDir(dir, io);
    const index = indexBlob(allocator, dir, io) catch return;
    defer allocator.free(index);
    const slot = nextSlot(index);
    if (fs.read(dir, io, allocator, access, path)) |body| {
        defer allocator.free(body);
        writeBlob(dir, io, slot, body);
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{{\"k\":\"delete\",\"p\":\"{s}\",\"n\":\"{d}\"}}\n", .{ path, slot }) catch return;
        appendLine(allocator, dir, io, line);
    } else |_| {}
}

pub fn recordRename(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    access: pathing.Access,
    from: []const u8,
    to: []const u8,
) void {
    pathing.assertInside(access, from) catch return;
    pathing.assertInside(access, to) catch return;
    ensureDir(dir, io);
    var line_buf: [320]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{{\"k\":\"rename\",\"a\":\"{s}\",\"b\":\"{s}\"}}\n", .{ from, to }) catch return;
    appendLine(allocator, dir, io, line);
}

fn lastLine(blob: []const u8) struct { start: usize, text: []const u8 } {
    var end = blob.len;
    while (end > 0 and (blob[end - 1] == '\n' or blob[end - 1] == '\r')) end -= 1;
    if (end == 0) return .{ .start = 0, .text = "" };
    const nl = std.mem.lastIndexOfScalar(u8, blob[0..end], '\n');
    const start = if (nl) |i| i + 1 else 0;
    return .{ .start = start, .text = blob[start..end] };
}

pub fn depth(allocator: std.mem.Allocator, dir: Io.Dir, io: Io) usize {
    const blob = indexBlob(allocator, dir, io) catch return 0;
    defer allocator.free(blob);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

pub fn popTo(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, access: pathing.Access, keep: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n = depth(allocator, dir, io);
    if (n <= keep) return allocator.dupe(u8, "no file changes to rewind\n");
    while (n > keep) : (n -= 1) {
        const msg = try pop(allocator, dir, io, access);
        defer allocator.free(msg);
        try out.appendSlice(allocator, msg);
    }
    return out.toOwnedSlice(allocator);
}

pub fn pop(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, access: pathing.Access) ![]u8 {
    const blob = try indexBlob(allocator, dir, io);
    defer allocator.free(blob);
    if (blob.len == 0) return allocator.dupe(u8, "nothing to undo\n");
    const last = lastLine(blob);
    if (last.text.len == 0) return allocator.dupe(u8, "nothing to undo\n");
    const op = parseOp(last.text) orelse return allocator.dupe(u8, "nothing to undo\n");
    const msg = switch (op) {
        .overwrite => |w| blk: {
            const body = readBlob(allocator, dir, io, w.slot) orelse break :blk try allocator.dupe(u8, "undo: missing snapshot\n");
            defer allocator.free(body);
            try fs.write(dir, io, allocator, access, w.path, body);
            break :blk try std.fmt.allocPrint(allocator, "undid write {s}\n", .{w.path});
        },
        .create => |path| blk: {
            dir.deleteFile(io, path) catch {};
            break :blk try std.fmt.allocPrint(allocator, "undid create {s}\n", .{path});
        },
        .delete => |d| blk: {
            const body = readBlob(allocator, dir, io, d.slot) orelse break :blk try allocator.dupe(u8, "undo: missing snapshot\n");
            defer allocator.free(body);
            try fs.write(dir, io, allocator, access, d.path, body);
            break :blk try std.fmt.allocPrint(allocator, "undid delete {s}\n", .{d.path});
        },
        .rename => |r| blk: {
            Io.Dir.rename(dir, r.to, dir, r.from, io) catch |err| {
                break :blk try std.fmt.allocPrint(allocator, "undo rename failed: {s}\n", .{@errorName(err)});
            };
            break :blk try std.fmt.allocPrint(allocator, "undid rename {s} <- {s}\n", .{ r.from, r.to });
        },
    };
    rewriteIndex(dir, io, blob[0..last.start]);
    return msg;
}

test "write then undo restores previous body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, .{ .workspace = "ws" }, "a.txt", "old");
    recordWrite(a, tmp.dir, io, .{ .workspace = "ws" }, "a.txt");
    try fs.write(tmp.dir, io, a, .{ .workspace = "ws" }, "a.txt", "new");
    const msg = try pop(a, tmp.dir, io, .{ .workspace = "ws" });
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "undid write") != null);
    const got = try fs.read(tmp.dir, io, a, .{ .workspace = "ws" }, "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("old", got);
}

test "undo create deletes the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    recordWrite(a, tmp.dir, io, .{ .workspace = "ws" }, "b.txt");
    try fs.write(tmp.dir, io, a, .{ .workspace = "ws" }, "b.txt", "fresh");
    const msg = try pop(a, tmp.dir, io, .{ .workspace = "ws" });
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "undid create") != null);
    try std.testing.expectError(error.FileNotFound, fs.read(tmp.dir, io, a, .{ .workspace = "ws" }, "b.txt"));
}

test "pop on empty says nothing to undo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const msg = try pop(std.testing.allocator, tmp.dir, std.testing.io, .{ .workspace = "ws" });
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("nothing to undo\n", msg);
}

test "popTo restores down to a recorded depth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, .{ .workspace = "ws" }, "a.txt", "one");
    recordWrite(a, tmp.dir, io, .{ .workspace = "ws" }, "a.txt");
    try fs.write(tmp.dir, io, a, .{ .workspace = "ws" }, "a.txt", "two");
    try std.testing.expectEqual(@as(usize, 1), depth(a, tmp.dir, io));
    recordWrite(a, tmp.dir, io, .{ .workspace = "ws" }, "a.txt");
    try fs.write(tmp.dir, io, a, .{ .workspace = "ws" }, "a.txt", "three");
    try std.testing.expectEqual(@as(usize, 2), depth(a, tmp.dir, io));
    const msg = try popTo(a, tmp.dir, io, .{ .workspace = "ws" }, 0);
    defer a.free(msg);
    const got = try fs.read(tmp.dir, io, a, .{ .workspace = "ws" }, "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("one", got);
}
