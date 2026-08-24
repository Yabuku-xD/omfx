const std = @import("std");
const Io = std.Io;
const pathing = @import("../tools/pathing.zig");

pub const max_files: usize = 8;
pub const max_bytes: usize = 32_000;
pub const max_dir_names: usize = 50;

comptime {
    if (max_files == 0) @compileError("max_files must attach at least one @file");
    if (max_bytes == 0) @compileError("max_bytes must hold one file");
    if (max_dir_names == 0) @compileError("max_dir_names must list at least one entry");
}

pub const Line = union(enum) {
    text,
    shell: []const u8,
};

const Class = enum { skip, path };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn classify(line: []const u8) Line {
    const s = std.mem.trim(u8, line, " \t\r");
    if (s.len == 0 or s[0] != '!') return .text;
    return .{ .shell = std.mem.trim(u8, s[1..], " \t") };
}

fn atStart(src: []const u8, i: usize) bool {
    if (src[i] != '@') return false;
    if (i == 0) return true;
    const p = src[i - 1];
    return isSpace(p) or p == '(' or p == '[' or p == '"';
}

fn pathEnd(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 2;
            continue;
        }
        const c = src[i];
        if (isSpace(c) or c == ')' or c == ']' or c == '"' or c == '\'' or c == ',') break;
        i += 1;
    }
    return i;
}

fn classOf(tok: []const u8) Class {
    if (tok.len == 0) return .skip;
    if (std.mem.startsWith(u8, tok, "http://") or std.mem.startsWith(u8, tok, "https://")) return .skip;
    if (std.mem.indexOfScalar(u8, tok, '/') != null) return .path;
    if (std.mem.indexOfScalar(u8, tok, '.') != null) return .path;
    return .skip;
}

fn unescape(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return allocator.dupe(u8, raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            try out.append(allocator, raw[i + 1]);
            i += 2;
            continue;
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn listNames(allocator: std.mem.Allocator, dir: *Io.Dir, io: Io) ![]u8 {
    var it = dir.iterate();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (n >= max_dir_names) {
            try out.appendSlice(allocator, "...\n");
            break;
        }
        try out.appendSlice(allocator, entry.name);
        try out.append(allocator, '\n');
        n += 1;
    }
    return out.toOwnedSlice(allocator);
}

const Attach = union(enum) {
    file: []u8,
    dir: []u8,
    note: []u8,

    fn text(self: Attach) []const u8 {
        return switch (self) {
            .file => |s| s,
            .dir => |s| s,
            .note => |s| s,
        };
    }

    fn deinit(self: Attach, allocator: std.mem.Allocator) void {
        allocator.free(self.text());
    }
};

fn loadOne(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    rel: []const u8,
) !Attach {
    pathing.assertInside(workspace, rel) catch {
        return .{ .note = try std.fmt.allocPrint(allocator, "(@{s}: outside workspace)\n", .{rel}) };
    };
    if (pathing.isSecret(rel)) {
        return .{ .note = try std.fmt.allocPrint(allocator, "(@{s}: secret)\n", .{rel}) };
    }
    if (dir.openDir(io, rel, .{ .iterate = true })) |dir_val| {
        var child = dir_val;
        defer child.close(io);
        const names = try listNames(allocator, &child, io);
        defer allocator.free(names);
        return .{ .dir = try std.fmt.allocPrint(allocator, "--- @{s}/ ---\n{s}", .{ rel, names }) };
    } else |_| {}
    const body = dir.readFileAlloc(io, rel, allocator, .limited(max_bytes)) catch |err| {
        return .{ .note = try std.fmt.allocPrint(allocator, "(@{s}: {s})\n", .{ rel, @errorName(err) }) };
    };
    defer allocator.free(body);
    const trunc: []const u8 = if (body.len >= max_bytes) "\ntruncated at 32000 bytes\n" else "";
    return .{ .file = try std.fmt.allocPrint(allocator, "--- @{s} ---\n{s}{s}", .{ rel, body, trunc }) };
}

pub fn expand(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    src: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var used: usize = 0;
    while (i < src.len) {
        if (!atStart(src, i)) {
            try out.append(allocator, src[i]);
            i += 1;
            continue;
        }
        const path_from = i + 1;
        const path_to = pathEnd(src, path_from);
        const raw = src[path_from..path_to];
        if (classOf(raw) != .path) {
            try out.append(allocator, src[i]);
            i += 1;
            continue;
        }
        if (used >= max_files) {
            try out.appendSlice(allocator, src[i..]);
            try out.appendSlice(allocator, "\nmax_files=8 exceeded; extra @paths left as text\n");
            break;
        }
        const rel = try unescape(allocator, raw);
        defer allocator.free(rel);
        const block = try loadOne(allocator, dir, io, workspace, rel);
        defer block.deinit(allocator);
        try out.appendSlice(allocator, block.text());
        used += 1;
        i = path_to;
    }
    return out.toOwnedSlice(allocator);
}

test "classify splits shell lines from text" {
    try std.testing.expectEqualStrings("git status", classify("!git status").shell);
    try std.testing.expectEqualStrings("", classify("!").shell);
    try std.testing.expect(classify("hello") == .text);
    try std.testing.expect(classify("/help") == .text);
}

test "expand injects a file and leaves unknown tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "note.txt", .{ .truncate = true });
        defer f.close(io);
        var buf: [32]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("hello from note\n");
        try w.interface.flush();
    }
    const got = try expand(std.testing.allocator, tmp.dir, io, ".", "see @note.txt please");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "hello from note") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "--- @note.txt ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "please") != null);
}

test "expand skips @word without a path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const got = try expand(std.testing.allocator, tmp.dir, std.testing.io, ".", "ask @alice later");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("ask @alice later", got);
}

test "expand refuses a secret env file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, ".env", .{ .truncate = true });
        defer f.close(io);
        var buf: [16]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("SECRET=1\n");
        try w.interface.flush();
    }
    const got = try expand(std.testing.allocator, tmp.dir, io, ".", "leak @.env");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "SECRET=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "secret") != null);
}
