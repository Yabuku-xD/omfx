//! Shared caps + board/todo/recall snips for handoff and run packets.
//! Keep stubs thin: paths and cite ids only, never reply bodies.

const std = @import("std");
const board = @import("board.zig");
const recall = @import("recall.zig");
const todos = @import("todos.zig");

pub const max_paths: usize = 16;
pub const max_board_lines: usize = 12;
pub const max_todo_lines: usize = 8;
pub const max_goal: usize = 240;

pub fn clip(s: []const u8, max: usize) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return "";
    if (t.len > max) return t[0..max];
    return t;
}

pub fn clipGoal(goal: []const u8) []const u8 {
    const t = clip(goal, max_goal);
    if (t.len == 0) return "(none)";
    return t;
}

pub fn appendPaths(
    allocator: std.mem.Allocator,
    notes: []const board.Note,
    out: *std.ArrayList(u8),
    seen: *std.StringHashMap(void),
) !usize {
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

pub fn appendBoardLines(allocator: std.mem.Allocator, notes: []const board.Note, out: *std.ArrayList(u8)) !void {
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

pub fn appendTodos(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
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

pub fn appendRecallIds(allocator: std.mem.Allocator, reply: []const u8, out: *std.ArrayList(u8)) !usize {
    var ids: [recall.max_items]recall.Id = undefined;
    const n = recall.collectIds(reply, &ids);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try out.append(allocator, ' ');
        try out.print(allocator, "r{d}", .{@intFromEnum(ids[i])});
    }
    return n;
}

test "clipGoal empty is none" {
    try std.testing.expectEqualStrings("(none)", clipGoal("  "));
}
