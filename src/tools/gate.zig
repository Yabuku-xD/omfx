const std = @import("std");
const Io = std.Io;
const undo = @import("undo.zig");
const diag = @import("diag.zig");
const fs = @import("fs.zig");

const log = std.log.scoped(.gate);

/// An edit that breaks the file it touches is undone rather than reported.
///
/// SWE-agent (arXiv:2405.15793) ablated exactly this and measured +3.0
/// percentage points on SWE-bench: the win is not that the model is told about
/// the error, it is that the broken state never exists. A reported error
/// leaves the model to repair a file it can no longer trust; a rejected edit
/// leaves the file it already read.
///
/// The verdict `afterWrite` produced is not enough on its own, because a file
/// that was already broken would make every later edit look guilty. So the
/// question here is narrower: was this write what broke it?
pub fn rejectIfNewlyBroken(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    dir: Io.Dir,
    rel: []const u8,
    mark: usize,
    note: []const u8,
) !?[]u8 {
    if (!isFindings(note)) return null;

    // Keep the rejected bytes: if the file turns out to have been broken
    // already, this write was not the cause and must stand.
    const written = dir.readFileAlloc(io, rel, allocator, .limited(fs.max_read_bytes)) catch return null;
    defer allocator.free(written);

    const rewound = undo.popTo(allocator, dir, io, workspace, mark) catch return null;
    allocator.free(rewound);

    const before = diag.afterWrite(allocator, io, workspace, dir, rel) catch return null;
    defer allocator.free(before);

    if (isFindings(before)) {
        // Already broken before this edit. Put the edit back and let the
        // ordinary report carry the news.
        undo.recordWrite(allocator, dir, io, workspace, rel);
        fs.write(dir, io, allocator, workspace, rel, written) catch |err| {
            log.warn("restoring {s} after a false rejection: {s}", .{ rel, @errorName(err) });
        };
        return null;
    }

    const msg = try std.fmt.allocPrint(
        allocator,
        "That edit left {s} unparseable, so it was undone and the file is as you last read it.\n{s}Read the file again and make the edit whole.\n",
        .{ rel, body(note) },
    );
    return msg;
}

fn isFindings(note: []const u8) bool {
    return std.mem.startsWith(u8, note, "diagnostics: findings");
}

/// The checker's own words, without the header the caller is replacing.
fn body(note: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, note, '\n') orelse return "";
    return note[nl + 1 ..];
}

test "a clean verdict is never a rejection" {
    const out = try rejectIfNewlyBroken(
        std.testing.allocator,
        std.testing.io,
        ".",
        Io.Dir.cwd(),
        "nothing.zig",
        0,
        "diagnostics: clean (zig ast-check)\n",
    );
    try std.testing.expect(out == null);
}

test "an edit that breaks a good file is undone" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);

    try fs.write(tmp.dir, io, a, ws, "m.zig", "pub fn a() void {}\n");
    const mark = undo.depth(a, tmp.dir, io);

    undo.recordWrite(a, tmp.dir, io, ws, "m.zig");
    try fs.write(tmp.dir, io, a, ws, "m.zig", "pub fn a() void {\n");

    const note = try diag.afterWrite(a, io, ws, tmp.dir, "m.zig");
    defer a.free(note);
    const msg = try rejectIfNewlyBroken(a, io, ws, tmp.dir, "m.zig", mark, note);
    defer if (msg) |m| a.free(m);

    try std.testing.expect(msg != null);
    const back = try fs.read(tmp.dir, io, a, ws, "m.zig");
    defer a.free(back);
    try std.testing.expectEqualStrings("pub fn a() void {}\n", back);
}

test "an edit to an already-broken file stands" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);

    // Broken before the edit and still broken after: the edit is not the
    // cause, so undoing it would strand the model on a file it cannot fix.
    try fs.write(tmp.dir, io, a, ws, "m.zig", "pub fn a() void {\n");
    const mark = undo.depth(a, tmp.dir, io);

    undo.recordWrite(a, tmp.dir, io, ws, "m.zig");
    try fs.write(tmp.dir, io, a, ws, "m.zig", "pub fn a() void {\n// halfway there\n");

    const note = try diag.afterWrite(a, io, ws, tmp.dir, "m.zig");
    defer a.free(note);
    const msg = try rejectIfNewlyBroken(a, io, ws, tmp.dir, "m.zig", mark, note);
    defer if (msg) |m| a.free(m);

    try std.testing.expect(msg == null);
    const kept = try fs.read(tmp.dir, io, a, ws, "m.zig");
    defer a.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "halfway there") != null);
}
