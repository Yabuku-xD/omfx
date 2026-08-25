//! Deterministic handoff packet for the next thread.
//! Builds a capped packet from board + paths + recall ids + open todos, and
//! puts a thin stub in the new session — never an LLM-drafted summary and
//! never a last-reply dump into the prompt.

const std = @import("std");
const Io = std.Io;
const board = @import("board.zig");
const recall = @import("recall.zig");
const todos = @import("todos.zig");

const log = std.log.scoped(.handoff);

pub const max_paths: usize = 16;
pub const max_board_lines: usize = 12;
pub const max_todo_lines: usize = 8;
pub const max_goal: usize = 240;

const packet_dir = ".omfx/handoff";

pub const Input = struct {
    goal: []const u8,
    last_tool: []const u8 = "",
    last_reply: []const u8 = "",
};

pub const Built = struct {
    /// Thin first user turn for the new session (no last_reply dump).
    stub: []u8,
    /// Reviewable packet under `.omfx/handoff/<id>.md` (caller owns).
    packet: []u8,
    /// Relative path written: `.omfx/handoff/<id>.md`
    rel_path: []u8,
};

fn clipGoal(goal: []const u8) []const u8 {
    const t = std.mem.trim(u8, goal, " \t\r\n");
    if (t.len == 0) return "(none)";
    if (t.len > max_goal) return t[0..max_goal];
    return t;
}

fn appendPaths(allocator: std.mem.Allocator, notes: []const board.Note, out: *std.ArrayList(u8), seen: *std.StringHashMap(void)) !usize {
    var n: usize = 0;
    for (notes) |note| {
        if (note.path.len == 0) continue;
        if (seen.contains(note.path)) continue;
        try seen.put(note.path, {});
        if (n > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, note.path);
        n += 1;
        if (n >= max_paths) break;
    }
    return n;
}

fn appendBoardLines(allocator: std.mem.Allocator, notes: []const board.Note, out: *std.ArrayList(u8)) !void {
    var n: usize = 0;
    for (notes) |note| {
        if (n >= max_board_lines) break;
        const tag = switch (note.kind) {
            .fact => "FACT",
            .fail => "FAIL",
            .path => "PATH",
        };
        if (note.path.len > 0) {
            try out.print(allocator, "{s} path={s} {s}\n", .{ tag, note.path, note.text });
        } else {
            try out.print(allocator, "{s} {s}\n", .{ tag, note.text });
        }
        n += 1;
    }
    if (n == 0) try out.appendSlice(allocator, "(empty)\n");
}

fn appendTodos(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const list = todos.get();
    var n: usize = 0;
    for (list.items[0..list.n]) |*it| {
        if (it.status == .done) continue;
        if (n >= max_todo_lines) break;
        const mark: u8 = switch (it.status) {
            .pending => ' ',
            .in_progress => '~',
            .done => 'x',
        };
        try out.print(allocator, "- [{c}] {s}\n", .{ mark, it.slice() });
        n += 1;
    }
    if (n == 0) try out.appendSlice(allocator, "(none)\n");
}

fn appendRecallIds(allocator: std.mem.Allocator, reply: []const u8, out: *std.ArrayList(u8)) !usize {
    var ids: [recall.max_items]recall.Id = undefined;
    const n = recall.collectIds(reply, &ids);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try out.append(allocator, ' ');
        try out.print(allocator, "r{d}", .{@intFromEnum(ids[i])});
    }
    return n;
}

/// Build stub + packet body. Caller writes packet to disk and encodes stub as session turn.
pub fn build(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    id: []const u8,
    input: Input,
) !Built {
    const goal = clipGoal(input.goal);
    const tail = board.loadTail(allocator, io, workspace);
    defer if (tail.len > 0) allocator.free(tail);

    var notes: [board.max_notes]board.Note = undefined;
    const note_n = board.parseAll(tail, &notes);

    var path_buf: std.ArrayList(u8) = .empty;
    errdefer path_buf.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    _ = try appendPaths(allocator, notes[0..note_n], &path_buf, &seen);

    var board_buf: std.ArrayList(u8) = .empty;
    defer board_buf.deinit(allocator);
    try appendBoardLines(allocator, notes[0..note_n], &board_buf);

    var todo_buf: std.ArrayList(u8) = .empty;
    defer todo_buf.deinit(allocator);
    try appendTodos(allocator, &todo_buf);

    var recall_buf: std.ArrayList(u8) = .empty;
    defer recall_buf.deinit(allocator);
    const recall_n = try appendRecallIds(allocator, input.last_reply, &recall_buf);

    const rel = try std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ packet_dir, id });
    errdefer allocator.free(rel);

    var packet: std.ArrayList(u8) = .empty;
    errdefer packet.deinit(allocator);
    try packet.print(allocator,
        \\# handoff {s}
        \\
        \\## goal
        \\{s}
        \\
        \\## last_tool
        \\{s}
        \\
        \\## board
        \\{s}
        \\## paths
        \\{s}
        \\
        \\## recall
        \\{s}
        \\
        \\## open_todos
        \\{s}
        \\
        \\Do not dump prior transcript. Open cites or paths only if needed.
        \\
    , .{
        id,
        goal,
        if (input.last_tool.len == 0) "(none)" else input.last_tool,
        board_buf.items,
        if (path_buf.items.len == 0) "(none)" else path_buf.items,
        if (recall_n == 0) "(none)" else recall_buf.items,
        todo_buf.items,
    });

    var stub: std.ArrayList(u8) = .empty;
    errdefer stub.deinit(allocator);
    try stub.print(allocator,
        \\HANDOFF goal={s}
        \\paths: {s}
        \\recall: {s}
        \\packet: {s}
        \\Do not replay prior turns. Open packet or cites only if needed.
        \\
    , .{
        goal,
        if (path_buf.items.len == 0) "(none)" else path_buf.items,
        if (recall_n == 0) "(none)" else recall_buf.items,
        rel,
    });

    path_buf.deinit(allocator);
    return .{
        .stub = try stub.toOwnedSlice(allocator),
        .packet = try packet.toOwnedSlice(allocator),
        .rel_path = rel,
    };
}

pub fn writePacket(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    rel_path: []const u8,
    body: []const u8,
) !void {
    const full = try std.fs.path.join(allocator, &.{ workspace, rel_path });
    defer allocator.free(full);
    if (std.fs.path.dirname(full)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            log.warn("mkdir handoff: {s}", .{@errorName(err)});
            return err;
        };
    }
    var file = try Io.Dir.cwd().createFile(io, full, .{ .truncate = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

test "build stub has no last_reply dump" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const built = try build(a, io, "/tmp", "h1", .{
        .goal = "ship handoff",
        .last_tool = "write",
        .last_reply = "SECRET_SHOULD_NOT_APPEAR " ** 20,
    });
    defer a.free(built.stub);
    defer a.free(built.packet);
    defer a.free(built.rel_path);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "SECRET_SHOULD_NOT_APPEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, built.packet, "SECRET_SHOULD_NOT_APPEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "HANDOFF goal=ship handoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "packet: .omfx/handoff/h1.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.packet, "## goal") != null);
}
