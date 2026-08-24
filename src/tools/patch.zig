const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const undo = @import("undo.zig");
const pathing = @import("pathing.zig");

pub const Error = error{
    EmptyPatch,
    MissingPath,
    MissingHunk,
    HashMismatch,
    OldStringNotFound,
    OldStringNotUnique,
    PathEscape,
    ApplyFailed,
} || std.mem.Allocator.Error;

pub const Hash = enum(u32) { _ };

pub const max_ops: usize = 16;

comptime {
    if (max_ops == 0) @compileError("max_ops must apply at least one hunk");
}

pub fn hashOf(s: []const u8) Hash {
    return @enumFromInt(@as(u32, @truncate(std.hash.Wyhash.hash(0, s))));
}

pub fn hash8(s: []const u8) [8]u8 {
    var buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>8}", .{@intFromEnum(hashOf(s))}) catch buf;
    return buf;
}

fn parseHash(s: []const u8) ?Hash {
    if (s.len != 8) return null;
    const v = std.fmt.parseInt(u32, s, 16) catch return null;
    return @enumFromInt(v);
}

const HashCheck = union(enum) {
    none,
    expect: Hash,
    bad,
};

const Kind = enum { update, add, delete };

const Update = struct {
    path: []const u8,
    hash: HashCheck,
    old: []const u8,
    new: []const u8,
};

const Add = struct {
    path: []const u8,
    contents: []const u8,
};

const Step = union(Kind) {
    update: Update,
    add: Add,
    delete: []const u8,
};

const Hit = struct {
    step: Step,
    rest: []const u8,
};

const Parse = union(enum) {
    done,
    hit: Hit,
};

const Found = union(enum) {
    none,
    at: struct { kind: Kind, pos: usize, len: usize },
};

/// Unique hunks, add, delete. All-or-nothing via undo. Inspectable hash.
/// Format:
/// ```
/// *** Update File: rel/path
/// *** Hash: deadbeef
/// old unique text
/// *** To
/// new unique text
/// *** Add File: rel/path
/// contents
/// *** Delete File: rel/path
/// ```
pub fn apply(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    spec: []const u8,
) Error![]u8 {
    if (std.mem.trim(u8, spec, " \t\r\n").len == 0) return error.EmptyPatch;
    var steps: [max_ops]Step = undefined;
    var n: usize = 0;
    var rest = spec;
    while (n < max_ops) {
        switch (nextOp(rest)) {
            .done => break,
            .hit => |hit| {
                steps[n] = hit.step;
                n += 1;
                rest = hit.rest;
            },
        }
    }
    if (n == 0) return error.EmptyPatch;

    const mark = undo.depth(allocator, dir, io);
    var applied: usize = 0;
    errdefer {
        if (applied > 0) {
            const msg = undo.popTo(allocator, dir, io, workspace, mark) catch null;
            if (msg) |m| allocator.free(m);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (steps[0..n]) |step| {
        try applyStep(allocator, dir, io, workspace, step, &out);
        applied += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// One replacement in a multi-edit call.
pub const Edit = struct { old: []const u8, new: []const u8 };

/// Sequential edits to one file, all-or-nothing. Each edit sees the result of
/// the ones before it, so a later hunk can target text an earlier one wrote.
///
/// Same engine and same rollback as `apply`; only the wire format differs. A
/// JSON array is the shape models emit reliably, the `*** Update File:` DSL is
/// the shape that survives a diff paste. Both had to exist; two engines did not.
pub fn applyEdits(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    path: []const u8,
    edits: []const Edit,
) Error![]u8 {
    if (edits.len == 0) return error.EmptyPatch;
    if (edits.len > max_ops) return error.ApplyFailed;
    const clean = std.mem.trim(u8, path, " \t\r");
    if (clean.len == 0) return error.MissingPath;
    try pathing.assertInside(workspace, clean);

    const mark = undo.depth(allocator, dir, io);
    var applied: usize = 0;
    errdefer {
        if (applied > 0) {
            const msg = undo.popTo(allocator, dir, io, workspace, mark) catch null;
            if (msg) |m| allocator.free(m);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (edits) |e| {
        if (e.old.len == 0) return error.MissingHunk;
        undo.recordWrite(allocator, dir, io, workspace, clean);
        fs.edit(dir, io, allocator, workspace, clean, e.old, e.new) catch |err| switch (err) {
            error.OldStringNotUnique => return error.OldStringNotUnique,
            error.OldStringNotFound => return error.OldStringNotFound,
            error.PathEscape => return error.PathEscape,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OldStringNotFound,
        };
        applied += 1;
    }
    try out.print(allocator, "edited {s} ({d} hunks)\n", .{ clean, edits.len });
    return out.toOwnedSlice(allocator);
}

fn applyStep(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    step: Step,
    out: *std.ArrayList(u8),
) Error!void {
    switch (step) {
        .update => |u| {
            const path = std.mem.trim(u8, u.path, " \t\r");
            if (path.len == 0) return error.MissingPath;
            try pathing.assertInside(workspace, path);
            const old = std.mem.trim(u8, u.old, " \t\r\n");
            if (old.len == 0) return error.MissingHunk;
            switch (u.hash) {
                .none => {},
                .expect => |want| if (hashOf(old) != want) return error.HashMismatch,
                .bad => return error.HashMismatch,
            }
            undo.recordWrite(allocator, dir, io, workspace, path);
            fs.edit(dir, io, allocator, workspace, path, old, u.new) catch |err| switch (err) {
                error.OldStringNotUnique => return error.OldStringNotUnique,
                error.OldStringNotFound => return error.OldStringNotFound,
                error.PathEscape => return error.PathEscape,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OldStringNotFound,
            };
            try out.appendSlice(allocator, "patched ");
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\n');
        },
        .add => |a| {
            const path = std.mem.trim(u8, a.path, " \t\r");
            if (path.len == 0) return error.MissingPath;
            try pathing.assertInside(workspace, path);
            undo.recordWrite(allocator, dir, io, workspace, path);
            fs.write(dir, io, allocator, workspace, path, a.contents) catch return error.ApplyFailed;
            try out.appendSlice(allocator, "added ");
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\n');
        },
        .delete => |raw_path| {
            const path = std.mem.trim(u8, raw_path, " \t\r");
            if (path.len == 0) return error.MissingPath;
            try pathing.assertInside(workspace, path);
            undo.recordDelete(allocator, dir, io, workspace, path);
            dir.deleteFile(io, path) catch {
                dir.deleteDir(io, path) catch return error.ApplyFailed;
            };
            try out.appendSlice(allocator, "deleted ");
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\n');
        },
    }
}

fn nextOp(src: []const u8) Parse {
    const found = firstMark(src, 0);
    const at = switch (found) {
        .none => return .done,
        .at => |a| a,
    };
    var i = at.pos + at.len;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
    const path = src[i..nl];
    var j = if (nl < src.len) nl + 1 else src.len;
    const rest_start = switch (firstMark(src, j)) {
        .none => src.len,
        .at => |a| a.pos,
    };
    return switch (at.kind) {
        .delete => .{ .hit = .{ .step = .{ .delete = path }, .rest = src[rest_start..] } },
        .add => .{ .hit = .{
            .step = .{ .add = .{ .path = path, .contents = src[j..rest_start] } },
            .rest = src[rest_start..],
        } },
        .update => blk: {
            var hash: HashCheck = .none;
            const hmark = "*** Hash:";
            if (j + hmark.len <= src.len and std.mem.startsWith(u8, src[j..], hmark)) {
                var k = j + hmark.len;
                while (k < src.len and (src[k] == ' ' or src[k] == '\t')) k += 1;
                const hn = std.mem.indexOfScalarPos(u8, src, k, '\n') orelse src.len;
                const raw = std.mem.trim(u8, src[k..hn], " \t\r");
                hash = if (parseHash(raw)) |h| .{ .expect = h } else .bad;
                j = if (hn < src.len) hn + 1 else src.len;
            }
            const to_mark = "*** To";
            const to = std.mem.indexOfPos(u8, src, j, to_mark) orelse break :blk .done;
            const old = src[j..to];
            var n = to + to_mark.len;
            if (n < src.len and src[n] == '\n') n += 1;
            const next = switch (firstMark(src, n)) {
                .none => src.len,
                .at => |a| a.pos,
            };
            break :blk .{ .hit = .{
                .step = .{ .update = .{ .path = path, .hash = hash, .old = old, .new = src[n..next] } },
                .rest = src[next..],
            } };
        },
    };
}

fn firstMark(src: []const u8, from: usize) Found {
    const marks = [_]struct { kind: Kind, text: []const u8 }{
        .{ .kind = .update, .text = "*** Update File:" },
        .{ .kind = .add, .text = "*** Add File:" },
        .{ .kind = .delete, .text = "*** Delete File:" },
    };
    var best: Found = .none;
    for (marks) |m| {
        const at = std.mem.indexOfPos(u8, src, from, m.text) orelse continue;
        switch (best) {
            .none => best = .{ .at = .{ .kind = m.kind, .pos = at, .len = m.text.len } },
            .at => |cur| if (at < cur.pos) {
                best = .{ .at = .{ .kind = m.kind, .pos = at, .len = m.text.len } };
            },
        }
    }
    return best;
}

test "apply unique hunk and reject a bad hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "hello world\n");
    const spec =
        \\*** Update File: a.txt
        \\hello world
        \\*** To
        \\hello there
        \\
    ;
    const msg = try apply(a, tmp.dir, io, "ws", spec);
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "patched a.txt") != null);
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "hello there") != null);

    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(a);
    try bad.appendSlice(a, "*** Update File: a.txt\n*** Hash: 00000000\nhello there\n*** To\nnope\n");
    try std.testing.expectError(error.HashMismatch, apply(a, tmp.dir, io, "ws", bad.items));
}

test "apply maps a non-unique old string" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "x x\n");
    const spec =
        \\*** Update File: a.txt
        \\x
        \\*** To
        \\y
        \\
    ;
    try std.testing.expectError(error.OldStringNotUnique, apply(a, tmp.dir, io, "ws", spec));
}

test "add and delete files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const spec =
        \\*** Add File: n.txt
        \\hello
        \\*** Delete File: n.txt
        \\
    ;
    const msg = try apply(a, tmp.dir, io, "ws", spec);
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "added n.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "deleted n.txt") != null);
}

test "second hunk fail rolls back the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "alpha\n");
    try fs.write(tmp.dir, io, a, "ws", "b.txt", "beta\n");
    const spec =
        \\*** Update File: a.txt
        \\alpha
        \\*** To
        \\ALPHA
        \\*** Update File: b.txt
        \\missing
        \\*** To
        \\nope
        \\
    ;
    try std.testing.expectError(error.OldStringNotFound, apply(a, tmp.dir, io, "ws", spec));
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "ALPHA") == null);
}

test "applyEdits applies every hunk in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "one\ntwo\nthree\n");
    const edits = [_]Edit{
        .{ .old = "one", .new = "1" },
        .{ .old = "three", .new = "3" },
    };
    const msg = try applyEdits(a, tmp.dir, io, "ws", "a.txt", &edits);
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "2 hunks") != null);
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("1\ntwo\n3\n", got);
}

test "applyEdits sees what an earlier hunk wrote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "alpha\n");
    const edits = [_]Edit{
        .{ .old = "alpha", .new = "beta" },
        .{ .old = "beta", .new = "gamma" },
    };
    const msg = try applyEdits(a, tmp.dir, io, "ws", "a.txt", &edits);
    defer a.free(msg);
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("gamma\n", got);
}

test "applyEdits rolls the file back when a later hunk misses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "one\ntwo\n");
    const edits = [_]Edit{
        .{ .old = "one", .new = "1" },
        .{ .old = "nowhere", .new = "x" },
    };
    try std.testing.expectError(error.OldStringNotFound, applyEdits(a, tmp.dir, io, "ws", "a.txt", &edits));
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("one\ntwo\n", got);
}

test "applyEdits refuses an empty old_string" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "one\n");
    const edits = [_]Edit{.{ .old = "", .new = "x" }};
    try std.testing.expectError(error.MissingHunk, applyEdits(a, tmp.dir, io, "ws", "a.txt", &edits));
}
