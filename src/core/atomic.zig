//! Whole-file replacement that a crash cannot half-finish.
//!
//! Settings, credentials and config are rewritten in full on every change. A
//! truncate-then-write leaves an empty or partial file when the process dies or
//! the disk fills mid-write, and the next launch reads that as "no settings".
//! Writing beside the target and renaming over it keeps either the old bytes
//! or the new ones, never a mix.

const std = @import("std");
const Io = std.Io;

pub const Options = struct {
    /// Owner-only by default: most callers hold keys or tokens.
    mode: std.posix.mode_t = 0o600,
    /// Create the parent directory first when it is missing.
    make_parent: bool = true,
};

pub fn writeFile(allocator: std.mem.Allocator, io: Io, link_path: []const u8, body: []const u8, opts: Options) !void {
    // A settings file kept in a dotfiles repo is often a symlink. Renaming
    // over the link would replace it with a plain file and silently detach
    // the repo copy, so the write goes to the file the link names.
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (Io.Dir.cwd().realPathFile(io, link_path, &real_buf)) |n| real_buf[0..n] else |_| link_path;
    if (opts.make_parent) {
        if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        var file = try Io.Dir.cwd().createFile(io, tmp, .{
            .truncate = true,
            .permissions = .fromMode(opts.mode),
        });
        defer file.close(io);
        errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

test "writeFile replaces the target and leaves no temp file" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const p = try std.fs.path.join(a, &.{ root, "sub", "settings.json" });
    defer a.free(p);

    try writeFile(a, io, p, "{\"a\":1}", .{});
    try writeFile(a, io, p, "{\"b\":2}", .{});

    const got = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64));
    defer a.free(got);
    try std.testing.expectEqualStrings("{\"b\":2}", got);

    const leftover = try std.fmt.allocPrint(a, "{s}.tmp", .{p});
    defer a.free(leftover);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, leftover, .{}));
}

test "writeFile writes through a symlinked target and keeps the link" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, "dotfiles");
    const real = try std.fs.path.join(a, &.{ root, "dotfiles", "settings.json" });
    defer a.free(real);
    try writeFile(a, io, real, "{}", .{});
    try tmp.dir.symLink(io, "dotfiles/settings.json", "settings.json", .{});
    const link = try std.fs.path.join(a, &.{ root, "settings.json" });
    defer a.free(link);

    try writeFile(a, io, link, "{\"x\":1}", .{});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try tmp.dir.readLink(io, "settings.json", &buf);
    const got = try tmp.dir.readFileAlloc(io, "dotfiles/settings.json", a, .limited(64));
    defer a.free(got);
    try std.testing.expectEqualStrings("{\"x\":1}", got);
}

test "writeFile keeps the old bytes when the rename target cannot be replaced" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    // A directory in the target's place makes the rename fail after the temp
    // file is fully written; the directory must survive and the temp go.
    const p = try std.fs.path.join(a, &.{ root, "blocked" });
    defer a.free(p);
    try tmp.dir.createDirPath(io, "blocked/inner");

    try std.testing.expect(std.meta.isError(writeFile(a, io, p, "new", .{})));
    try tmp.dir.access(io, "blocked/inner", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "blocked.tmp", .{}));
}
