const std = @import("std");
const Io = std.Io;

/// Addressable Recall Compaction (arXiv:2607.25066). Bodies live on disk;
/// the live thread keeps a cite. 32 * 32k = 1 MiB workspace scratch (mention.max_bytes).
pub const max_items: usize = 32;
/// The archive is the copy the model comes back for, so it holds the whole
/// observation rather than a second trim of it. Receipt: the largest tool
/// result recorded in this repo is a 38 KB provider response; 1 MB is a
/// tripwire for a command printing rather than reporting.
pub const body_max: usize = 1_000_000;

comptime {
    if (max_items == 0) @compileError("max_items must archive at least one tool body");
    if (body_max == 0) @compileError("body_max must hold one tool body");
}

pub const Error = error{ArchiveFailed};

pub const Id = enum(u16) { _ };

pub const Target = union(enum) {
    none,
    path: []const u8,
};

pub const Cite = struct {
    id: Id,
    tool: []const u8,
    target: Target,
    chars: usize,
};

const dir_name = ".omfx/recall";

fn fileName(buf: *[40]u8, id: Id) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/r{d}.txt", .{ dir_name, @intFromEnum(id) }) catch dir_name;
}

fn exists(dir: Io.Dir, io: Io, name: []const u8) bool {
    const f = dir.openFile(io, name, .{ .mode = .read_only }) catch return false;
    f.close(io);
    return true;
}

fn nextId(dir: Io.Dir, io: Io) Id {
    var n: u16 = 1;
    while (n <= max_items) : (n += 1) {
        var buf: [40]u8 = undefined;
        const name = fileName(&buf, @enumFromInt(n));
        if (!exists(dir, io, name)) return @enumFromInt(n);
    }
    return @enumFromInt(1);
}

pub fn put(
    dir: Io.Dir,
    io: Io,
    tool_name: []const u8,
    target: Target,
    body: []const u8,
) Error!Id {
    dir.createDirPath(io, dir_name) catch return error.ArchiveFailed;
    const id = nextId(dir, io);
    var name_buf: [40]u8 = undefined;
    const name = fileName(&name_buf, id);
    var file = dir.createFile(io, name, .{ .truncate = true }) catch return error.ArchiveFailed;
    defer file.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = file.writer(io, &wbuf);
    const clip = if (body.len > body_max) body[0..body_max] else body;
    const clipped = clip.len != body.len;
    const path = switch (target) {
        .none => "",
        .path => |p| p,
    };
    w.interface.print("tool={s} path={s} chars={d}\n", .{ tool_name, path, body.len }) catch return error.ArchiveFailed;
    w.interface.writeAll(clip) catch return error.ArchiveFailed;
    if (clipped) {
        w.interface.print("\n(archive clipped at {d} bytes)\n", .{body_max}) catch return error.ArchiveFailed;
    }
    w.interface.flush() catch return error.ArchiveFailed;
    return id;
}

pub fn cite(allocator: std.mem.Allocator, item: Cite) std.mem.Allocator.Error![]u8 {
    const n = @intFromEnum(item.id);
    return switch (item.target) {
        .path => |p| std.fmt.allocPrint(
            allocator,
            "cite r{d} tool={s} path={s} chars={d}. Re-read the file, or read .omfx/recall/r{d}.txt.\n",
            .{ n, item.tool, p, item.chars, n },
        ),
        .none => std.fmt.allocPrint(
            allocator,
            "cite r{d} tool={s} chars={d}. read .omfx/recall/r{d}.txt for the body.\n",
            .{ n, item.tool, item.chars, n },
        ),
    };
}

pub fn take(dst: *[max_items]Id, n: *usize, id: Id) void {
    if (n.* >= max_items) return;
    if (@intFromEnum(id) == 0) return;
    for (dst[0..n.*]) |old| {
        if (old == id) return;
    }
    dst[n.*] = id;
    n.* += 1;
}

pub fn collectIds(src: []const u8, out: *[max_items]Id) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < max_items) {
        const rest = src[i..];
        const hit = std.mem.indexOf(u8, rest, "cite r") orelse break;
        i += hit + "cite r".len;
        var v: u16 = 0;
        var saw = false;
        while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {
            saw = true;
            v = v *% 10 + (src[i] - '0');
        }
        if (!saw) continue;
        take(out, &n, @enumFromInt(v));
    }
    return n;
}

test "cite names the archive path" {
    const s = try cite(std.testing.allocator, .{
        .id = @enumFromInt(3),
        .tool = "bash",
        .target = .none,
        .chars = 12000,
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "cite r3") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, ".omfx/recall/r3.txt") != null);
}

test "put then collectIds round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const id = try put(tmp.dir, std.testing.io, "read", .{ .path = "a.txt" }, "hello body");
    const s = try cite(std.testing.allocator, .{
        .id = id,
        .tool = "read",
        .target = .{ .path = "a.txt" },
        .chars = 10,
    });
    defer std.testing.allocator.free(s);
    var ids: [max_items]Id = undefined;
    try std.testing.expectEqual(@as(usize, 1), collectIds(s, &ids));
    try std.testing.expectEqual(id, ids[0]);
}
