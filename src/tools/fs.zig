const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const log = std.log.scoped(.fs);
const pathing = @import("pathing.zig");
const headless = @import("../core/headless.zig");

pub const max_read_bytes: usize = 1_000_000;
/// A whole-file read of a huge file buries the answer and burns the window.
/// Hitting this is not an error: the tail names the cap and how to page past it.
pub const max_read_lines: usize = 2_000;

/// Raw bytes. Callers that parse the file (symbols, patch) want this.
pub fn read(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    rel: []const u8,
) ![]u8 {
    try pathing.assertReadable(access, rel);
    // Absolute skill paths live outside the workspace Dir; open via cwd.
    const open_dir = if (std.fs.path.isAbsolute(rel)) Io.Dir.cwd() else dir;
    // A FIFO, a socket, or a character device has no end: reading one parks the
    // turn with nothing to interrupt it. Only a regular file is readable here.
    const st = try open_dir.statFile(io, rel, .{});
    if (st.kind != .file) return error.NotAFile;
    return open_dir.readFileAlloc(io, rel, allocator, .limited(max_read_bytes));
}

/// Soft recovery when `read` is aimed at a directory: teach `list` and return
/// one level so the model does not thrash on opaque `NotAFile` (industry: Kilo
/// read→list, Claude EISDIR). FIFOs/sockets stay hard errors via `read`.
pub fn readDirHint(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    rel: []const u8,
) ![]u8 {
    const listing = try list(dir, io, allocator, access, rel);
    defer allocator.free(listing);
    return std.fmt.allocPrint(
        allocator,
        "{s} is a folder, not a file. Use list for directories (or glob/grep under them). Listing:\n{s}",
        .{ rel, listing },
    );
}

/// What the `read` tool shows the model: numbered lines, pageable. `offset` is
/// 1-based, `limit` counts lines; 0 means "from the top" / "to the cap".
/// Numbering lets a `grep` hit at `file:12:` be read without counting.
pub fn numberLines(
    allocator: std.mem.Allocator,
    rel: []const u8,
    body: []const u8,
    offset: usize,
    limit: usize,
) ![]u8 {
    const start = if (offset == 0) 1 else offset;
    const want = if (limit == 0 or limit > max_read_lines) max_read_lines else limit;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var no: usize = 0;
    var shown: usize = 0;
    var more = false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        // A trailing newline yields one empty tail slice; it is not a line.
        if (line.len == 0 and it.index == null) break;
        no += 1;
        if (no < start) continue;
        if (shown == want) {
            more = true;
            break;
        }
        shown += 1;
        try out.print(allocator, "{d: >6}\t{s}\n", .{ no, line });
    }
    if (shown == 0) {
        return std.fmt.allocPrint(allocator, "({s} has {d} lines; offset {d} is past the end)\n", .{ rel, no, start });
    }
    if (more) {
        try out.print(allocator, "... stopped at {d} lines; read on with offset={d}\n", .{ want, start + shown });
    }
    return out.toOwnedSlice(allocator);
}

pub fn write(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    rel: []const u8,
    contents: []const u8,
) !void {
    _ = allocator;
    try pathing.assertInside(access, rel);
    if (std.fs.path.dirname(rel)) |parent| {
        if (parent.len > 0) try dir.createDirPath(io, parent);
    }
    var file = try dir.createFile(io, rel, .{ .truncate = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
}

pub fn edit(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    rel: []const u8,
    old: []const u8,
    new: []const u8,
) !void {
    const body = try read(dir, io, allocator, access, rel);
    defer allocator.free(body);
    const first = std.mem.indexOf(u8, body, old) orelse return error.OldStringNotFound;
    if (std.mem.indexOfPos(u8, body, first + old.len, old) != null) return error.OldStringNotUnique;
    const updated = try std.mem.concat(allocator, u8, &.{ body[0..first], new, body[first + old.len ..] });
    defer allocator.free(updated);
    try write(dir, io, allocator, access, rel, updated);
}

test "read write edit in temp workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const access: pathing.Access = .{ .workspace = "ws" };

    try write(tmp.dir, io, std.testing.allocator, access, "a.txt", "hello");
    const got = try read(tmp.dir, io, std.testing.allocator, access, "a.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello", got);

    try edit(tmp.dir, io, std.testing.allocator, access, "a.txt", "hello", "hello world");
    const got2 = try read(tmp.dir, io, std.testing.allocator, access, "a.txt");
    defer std.testing.allocator.free(got2);
    try std.testing.expectEqualStrings("hello world", got2);
}

test "edit non-unique old_string fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const access: pathing.Access = .{ .workspace = "ws" };
    try write(tmp.dir, io, std.testing.allocator, access, "a.txt", "x x");
    try std.testing.expectError(
        error.OldStringNotUnique,
        edit(tmp.dir, io, std.testing.allocator, access, "a.txt", "x", "y"),
    );
}

pub fn list(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    rel: []const u8,
) ![]u8 {
    const path = if (rel.len == 0 or std.mem.eql(u8, rel, ".") or std.mem.eql(u8, rel, "./")) "." else rel;
    if (!std.mem.eql(u8, path, ".")) try pathing.assertReadable(access, path);
    const open_dir = if (std.fs.path.isAbsolute(path)) Io.Dir.cwd() else dir;
    var child = open_dir.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        // Models often `list` a file; NotDir alone reads as a crash, not a hint.
        error.NotDir => return std.fmt.allocPrint(
            allocator,
            "{s} is a file, not a folder. Use read for its contents (or list its parent directory).",
            .{path},
        ),
        else => return err,
    };
    defer child.close(io);
    var it = child.iterate();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        const tag: []const u8 = switch (entry.kind) {
            .directory => "dir ",
            else => "file ",
        };
        try out.appendSlice(allocator, tag);
        try out.appendSlice(allocator, entry.name);
        try out.append(allocator, '\n');
        n += 1;
        if (n >= 200) break;
    }
    if (out.items.len == 0) return allocator.dupe(u8, "(empty)");
    return out.toOwnedSlice(allocator);
}

pub fn copy(
    dir: Io.Dir,
    io: Io,
    access: pathing.Access,
    from: []const u8,
    to: []const u8,
) !void {
    try pathing.assertInside(access, from);
    try pathing.assertInside(access, to);
    if (std.fs.path.dirname(to)) |parent| {
        if (parent.len > 0) try dir.createDirPath(io, parent);
    }
    try Io.Dir.copyFile(dir, from, dir, to, io, .{});
}

pub fn mkdir(
    dir: Io.Dir,
    io: Io,
    access: pathing.Access,
    rel: []const u8,
) !void {
    try pathing.assertInside(access, rel);
    try dir.createDirPath(io, rel);
}

pub fn info(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    rel: []const u8,
) ![]u8 {
    try pathing.assertInside(access, rel);
    if (dir.openDir(io, rel, .{})) |d_val| {
        var d = d_val;
        d.close(io);
        return std.fmt.allocPrint(allocator, "dir {s}\n", .{rel});
    } else |_| {}
    var file = dir.openFile(io, rel, .{ .mode = .read_only }) catch {
        return std.fmt.allocPrint(allocator, "missing {s}\n", .{rel});
    };
    defer file.close(io);
    const st = file.stat(io) catch {
        return std.fmt.allocPrint(allocator, "file {s}\n", .{rel});
    };
    return std.fmt.allocPrint(allocator, "file {s} size={d} bytes\n", .{ rel, st.size });
}

pub fn openPath(io: Io, abs: []const u8) void {
    if (headless.guiBlocked()) return;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", abs },
        .windows => &.{ "cmd", "/c", "start", "", abs },
        else => &.{ "xdg-open", abs },
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch |err| {
        log.debug("open wait: {s}", .{@errorName(err)});
    };
}

test "path escape denied before io" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const access: pathing.Access = .{ .workspace = "ws" };
    try std.testing.expectError(
        error.PathEscape,
        read(tmp.dir, std.testing.io, std.testing.allocator, access, "../etc/passwd"),
    );
}

test "list copy mkdir info" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const access: pathing.Access = .{ .workspace = "ws" };
    try write(tmp.dir, io, std.testing.allocator, access, "a.txt", "hello");
    try mkdir(tmp.dir, io, access, "sub");
    try copy(tmp.dir, io, access, "a.txt", "sub/b.txt");
    const listing = try list(tmp.dir, io, std.testing.allocator, access, ".");
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "a.txt") != null);
    const inf = try info(tmp.dir, io, std.testing.allocator, access, "a.txt");
    defer std.testing.allocator.free(inf);
    try std.testing.expect(std.mem.indexOf(u8, inf, "file") != null);
    try std.testing.expect(std.mem.indexOf(u8, inf, "bytes") != null);
    const nested = try list(tmp.dir, io, std.testing.allocator, access, "sub");
    defer std.testing.allocator.free(nested);
    try std.testing.expect(std.mem.indexOf(u8, nested, "b.txt") != null);
    const on_file = try list(tmp.dir, io, std.testing.allocator, access, "a.txt");
    defer std.testing.allocator.free(on_file);
    try std.testing.expect(std.mem.indexOf(u8, on_file, "is a file") != null);
    try std.testing.expect(std.mem.indexOf(u8, on_file, "read") != null);
}

test "list on a file explains to use read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const access: pathing.Access = .{ .workspace = "ws" };
    try write(tmp.dir, io, std.testing.allocator, access, "a.txt", "hello");
    const msg = try list(tmp.dir, io, std.testing.allocator, access, "a.txt");
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "is a file") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "read") != null);
}

test "read on a directory explains to use list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const access: pathing.Access = .{ .workspace = "ws" };
    try mkdir(tmp.dir, io, access, "sub");
    try write(tmp.dir, io, std.testing.allocator, access, "sub/a.txt", "x");
    try std.testing.expectError(error.NotAFile, read(tmp.dir, io, std.testing.allocator, access, "sub"));
    const msg = try readDirHint(tmp.dir, io, std.testing.allocator, access, "sub");
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "is a folder") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "a.txt") != null);
}

test "write creates missing parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const access: pathing.Access = .{ .workspace = "ws" };
    try write(tmp.dir, io, std.testing.allocator, access, "deep/nested/f.txt", "x");
    const got = try read(tmp.dir, io, std.testing.allocator, access, "deep/nested/f.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("x", got);
}
