//! Deterministic handoff packet for the next thread: capped board/paths/recall/
//! todos on disk, thin stub in the new session — never a last-reply dump.

const std = @import("std");
const Io = std.Io;
const board = @import("board.zig");
const snip = @import("packet_snip.zig");
const todos = @import("todos.zig");

const log = std.log.scoped(.handoff);

const packet_dir = ".omfx/handoff";

pub const Input = struct {
    goal: []const u8,
    last_tool: []const u8 = "",
    last_reply: []const u8 = "",
};

pub const Built = struct {
    stub: []u8,
    /// Caller owns; write under `.omfx/handoff/`.
    packet: []u8,
    rel_path: []u8,
};

pub fn build(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    id: []const u8,
    input: Input,
    tasks: *const todos.List,
) !Built {
    const goal = snip.clipGoal(input.goal);
    const tail = board.loadTail(allocator, io, workspace);
    defer if (tail.len > 0) allocator.free(tail);

    var notes: [board.max_notes]board.Note = undefined;
    const note_n = board.parseAll(tail, &notes);

    var path_buf: std.ArrayList(u8) = .empty;
    errdefer path_buf.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    _ = try snip.appendPaths(allocator, notes[0..note_n], &path_buf, &seen);

    var board_buf: std.ArrayList(u8) = .empty;
    defer board_buf.deinit(allocator);
    try snip.appendBoardLines(allocator, notes[0..note_n], &board_buf);

    var todo_buf: std.ArrayList(u8) = .empty;
    defer todo_buf.deinit(allocator);
    try snip.appendTodos(allocator, tasks, &todo_buf);

    var recall_buf: std.ArrayList(u8) = .empty;
    defer recall_buf.deinit(allocator);
    const recall_n = try snip.appendRecallIds(allocator, input.last_reply, &recall_buf);

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
        \\Do not replay prior turns. Use read on the packet or recall cites only if needed; continue with the usual tools.
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
    }, &.{});
    defer a.free(built.stub);
    defer a.free(built.packet);
    defer a.free(built.rel_path);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "SECRET_SHOULD_NOT_APPEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, built.packet, "SECRET_SHOULD_NOT_APPEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "HANDOFF goal=ship handoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "packet: .omfx/handoff/h1.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.packet, "## goal") != null);
}
