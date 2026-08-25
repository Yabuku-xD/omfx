const std = @import("std");

const cli = @import("../../../core/cli.zig");
const paint = @import("../../../core/ansi.zig");
const layout_mod = @import("../layout.zig");
const width = @import("../../width.zig");
const box = @import("box.zig");

const Layout = layout_mod.Layout;
const moveTo = layout_mod.moveTo;
const cellsTo = width.cellsTo;
const padCells = box.padCells;
const clipCells = box.clipCells;
const boxEdge = box.boxEdge;

const WelcomeRow = struct {
    left: []const u8,
    right: []const u8 = "",
    /// Painted on `left`. `right` is always the accent (it is the thing to type).
    style: []const u8 = "",
};

/// Printed once into the transcript pane: how to fill it, one next step.
pub const welcome = paint.muted ++ "Type what you need. " ++ paint.reset ++ paint.accent_dim ++ "?" ++ paint.reset ++ paint.muted ++ " shows keys, " ++ paint.reset ++ paint.accent_dim ++ "/help" ++ paint.reset ++ paint.muted ++ " shows commands." ++ paint.reset ++ "\n";

/// Centred card: name, what it is talking to, then the four things worth doing.
/// Narrower than this a bordered card is all border and no content, so the
/// welcome degrades to the one-line form instead of drawing a broken box.
pub const min_card_cols: u16 = 24;

pub fn formatWelcome(allocator: std.mem.Allocator, layout: Layout, model: []const u8) ![]u8 {
    if (layout.cols < min_card_cols or layout.transcript_rows < 3) {
        return allocator.dupe(u8, clipCells(welcome, layout.cols));
    }
    // Never wider than the terminal: the borders are two of those columns, so
    // a card sized to `cols` itself overflows by two.
    const card_w: u16 = if (layout.cols >= 56)
        48
    else if (layout.cols > 16)
        layout.cols - 8
    else
        @min(layout.cols, @max(layout.cols, 4));
    const inner: u16 = if (card_w >= 2) card_w - 2 else card_w;
    const top = try boxEdge(allocator, card_w, "\u{256d}", "\u{256e}");
    defer allocator.free(top);
    const bot = try boxEdge(allocator, card_w, "\u{2570}", "\u{256f}");
    defer allocator.free(bot);

    var talk_buf: [160]u8 = undefined;
    const talk = std.fmt.bufPrint(&talk_buf, " Talking to {s}", .{model}) catch " Talking to a model";

    const rows = [_]WelcomeRow{
        .{ .left = " " ++ cli.title, .right = cli.version, .style = paint.bold ++ paint.accent },
        .{ .left = "" },
        .{ .left = talk, .style = paint.label },
        .{ .left = "" },
        .{ .left = " New session", .right = "/clear", .style = paint.muted },
        .{ .left = " Resume session", .right = "/resume", .style = paint.muted },
        .{ .left = " Commands", .right = "/help", .style = paint.muted },
        .{ .left = " Keys", .right = "?", .style = paint.muted },
    };

    const card_h: u16 = @intCast(rows.len + 2);
    const col: u16 = if (layout.cols > card_w) (layout.cols - card_w) / 2 + 1 else 1;
    const room = layout.transcript_rows;
    const row0: u16 = if (room > card_h)
        layout.transcript_start_row + (room - card_h) / 2
    else
        layout.transcript_start_row;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cup: [32]u8 = undefined;
    var r = row0;
    try out.appendSlice(allocator, try moveTo(&cup, r, col));
    try out.appendSlice(allocator, top);
    r += 1;
    for (rows) |row| {
        // Right column is drawn flush; the left pad absorbs the width difference.
        // On a narrow card there is no room for it at all.
        const rw = if (cellsTo(row.right) + 4 <= inner) cellsTo(row.right) else 0;
        const lw: u16 = if (rw == 0) inner else if (inner > rw + 1) inner - rw - 1 else inner;
        const left = try padCells(allocator, clipCells(row.left, lw), lw);
        defer allocator.free(left);
        try out.appendSlice(allocator, try moveTo(&cup, r, col));
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "\u{2502}");
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, row.style);
        try out.appendSlice(allocator, left);
        try out.appendSlice(allocator, paint.reset);
        if (rw != 0) {
            try out.appendSlice(allocator, paint.accent_dim);
            try out.appendSlice(allocator, clipCells(row.right, rw));
            try out.appendSlice(allocator, paint.reset);
            try out.append(allocator, ' ');
        }
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "\u{2502}");
        try out.appendSlice(allocator, paint.reset);
        r += 1;
    }
    try out.appendSlice(allocator, try moveTo(&cup, r, col));
    try out.appendSlice(allocator, bot);
    return out.toOwnedSlice(allocator);
}

test "welcome is one empty-state line" {
    try std.testing.expect(std.mem.indexOf(u8, welcome, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "Type what you need") != null);
}

test "welcome card is centered with commands" {
    const layout = Layout.compute(24, 80);
    const s = try formatWelcome(std.testing.allocator, layout, "grok-4.6");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Oh My Fx") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "/resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Talking to") != null);
}
