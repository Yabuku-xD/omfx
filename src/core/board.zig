const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.board);

pub const max_notes: usize = 32;
pub const max_note_chars: usize = 800;

pub const Kind = enum { fact, fail, path };

pub const Note = struct {
    kind: Kind,
    path: []const u8 = "",
    text: []const u8,
};

fn stripSeq(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i > 0 and i < line.len and line[i] == ' ') return std.mem.trim(u8, line[i + 1 ..], " \t");
    return line;
}

pub fn parseLine(line: []const u8) ?Note {
    const t = stripSeq(std.mem.trim(u8, line, " \t\r"));
    if (t.len < 4) return null;
    const tag = std.meta.stringToEnum(enum { FACT, FAIL, PATH }, t[0..4]) orelse return null;
    const kind: Kind = switch (tag) {
        .FACT => .fact,
        .FAIL => .fail,
        .PATH => .path,
    };
    var rest = std.mem.trim(u8, t[4..], " \t");
    var path: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "path=")) {
        rest = rest["path=".len..];
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            path = rest;
            rest = "";
            return admit(kind, path, rest);
        };
        path = rest[0..sp];
        rest = std.mem.trim(u8, rest[sp + 1 ..], " \t");
    }
    return admit(kind, path, rest);
}

fn admit(kind: Kind, path: []const u8, text: []const u8) ?Note {
    if (kind == .fact and path.len == 0) return null;
    if (text.len == 0 and path.len == 0) return null;
    return .{ .kind = kind, .path = path, .text = text };
}

pub fn parseAll(text: []const u8, out: *[max_notes]Note) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (n >= max_notes) break;
        const note = parseLine(line) orelse continue;
        out[n] = note;
        n += 1;
    }
    return n;
}

pub fn format(allocator: std.mem.Allocator, notes: []const Note) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("Note (kept):\n");
    for (notes) |note| {
        const tag = switch (note.kind) {
            .fact => "FACT",
            .fail => "FAIL",
            .path => "PATH",
        };
        if (note.path.len > 0) {
            try aw.writer.print("[{s}] path={s} {s}\n", .{ tag, note.path, note.text });
        } else {
            try aw.writer.print("[{s}] {s}\n", .{ tag, note.text });
        }
        if (aw.written().len > max_note_chars) break;
    }
    if (std.mem.eql(u8, aw.written(), "Note (kept):\n")) {
        try aw.writer.writeAll("(no verified notes)\n");
    }
    return aw.toOwnedSlice();
}

pub fn boardPath(allocator: std.mem.Allocator, workspace: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace, ".omfx", "board.jsonl" });
}

pub fn append(allocator: std.mem.Allocator, io: Io, workspace: []const u8, notes: []const Note) void {
    if (notes.len == 0) return;
    const p = boardPath(allocator, workspace) catch return;
    defer allocator.free(p);
    const dir = std.fs.path.dirname(p) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
        return;
    };
    const existing = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(32_000)) catch "";
    defer if (existing.len > 0) allocator.free(existing);
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(allocator);
    extra.appendSlice(allocator, existing) catch return;
    for (notes) |note| {
        extra.appendSlice(allocator, switch (note.kind) {
            .fact => "FACT path=",
            .fail => "FAIL ",
            .path => "PATH path=",
        }) catch return;
        extra.appendSlice(allocator, note.path) catch return;
        extra.append(allocator, ' ') catch return;
        extra.appendSlice(allocator, note.text) catch return;
        extra.append(allocator, '\n') catch return;
    }
    var file = Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buf: [512]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(extra.items) catch return;
    w.interface.flush() catch return;
}

pub fn loadTail(allocator: std.mem.Allocator, io: Io, workspace: []const u8) []u8 {
    const p = boardPath(allocator, workspace) catch return allocator.dupe(u8, "") catch return &.{};
    defer allocator.free(p);
    return Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(8_000)) catch allocator.dupe(u8, "") catch return &.{};
}

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    action: []const u8,
    line: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, action, "post")) {
        const note = parseLine(line) orelse
            return allocator.dupe(u8, "board: rejected (FACT needs path=rel/path claim)\n");
        append(allocator, io, workspace, &.{note});
        return format(allocator, &.{note});
    }
    const tail = loadTail(allocator, io, workspace);
    defer if (tail.len > 0) allocator.free(tail);
    if (tail.len == 0) return allocator.dupe(u8, "Note (kept):\n(empty board)\n");
    return std.fmt.allocPrint(allocator, "Note (kept):\n{s}", .{tail});
}

test "fact without path is rejected" {
    try std.testing.expect(parseLine("FACT the printer is wrong") == null);
    const n = parseLine("FACT path=src/a.zig printer bypasses join").?;
    try std.testing.expectEqual(Kind.fact, n.kind);
    try std.testing.expectEqualStrings("src/a.zig", n.path);
}

test "fail needs no path" {
    const n = parseLine("FAIL changing StrPrinter did not affect output").?;
    try std.testing.expectEqual(Kind.fail, n.kind);
}

test "seq prefix still parses" {
    const n = parseLine("3 FACT path=src/a.zig claim").?;
    try std.testing.expectEqualStrings("src/a.zig", n.path);
}
