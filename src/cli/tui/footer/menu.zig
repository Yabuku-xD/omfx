const std = @import("std");

const slash = @import("../../../core/slash.zig");
const paint = @import("../../../core/ansi.zig");
const palette = @import("../palette.zig");
const width = @import("../../width.zig");
const box = @import("box.zig");

const cellsTo = width.cellsTo;
const padCells = box.padCells;
const clipCells = box.clipCells;
const ruleLine = box.ruleLine;
const boxEdge = box.boxEdge;
const widestRow = box.widestRow;

fn rowTitle(hit: slash.Spec) []const u8 {
    return if (hit.flip) hit.help else hit.name;
}

fn rowMeta(hit: slash.Spec) []const u8 {
    return if (hit.flip) hit.name else hit.help;
}

fn boxBottomCount(allocator: std.mem.Allocator, cols: u16, selected: usize, total: usize, view: usize) ![]u8 {
    const inner: u16 = if (cols >= 2) cols - 2 else cols;
    if (total <= view) return boxEdge(allocator, cols, "╰", "╯");
    var count_buf: [24]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, " {d}/{d} ", .{ selected + 1, total }) catch " ? ";
    const cw = cellsTo(count);
    const dashes: u16 = if (inner > cw) inner - cw else 0;
    const rule = try ruleLine(allocator, dashes);
    defer allocator.free(rule);
    return std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}{s}{s}{s}{s}╯{s}",
        .{ paint.border, paint.reset, paint.muted, count, paint.reset, paint.border, rule, paint.reset },
    );
}

fn writeBoxRow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), inner: u16, body: []const u8) !void {
    const padded = try padCells(allocator, body, inner);
    defer allocator.free(padded);
    try out.appendSlice(allocator, paint.border);
    try out.appendSlice(allocator, "│");
    try out.appendSlice(allocator, paint.reset);
    try out.appendSlice(allocator, padded);
    try out.appendSlice(allocator, paint.border);
    try out.appendSlice(allocator, "│");
    try out.appendSlice(allocator, paint.reset);
}

/// A menu narrower than this is two borders and a marker with nothing between
/// them; drawing it just tears the row.
pub const min_menu_cols: u16 = 12;

pub fn formatSlashMenu(
    allocator: std.mem.Allocator,
    cols: u16,
    hits: []const slash.Spec,
    selected: usize,
    item_rows: usize,
) ![]u8 {
    if (cols < min_menu_cols) return allocator.dupe(u8, "");
    const view: usize = if (item_rows == 0) 1 else item_rows;
    const box_w = palette.paletteWidth(cols);
    const inner: u16 = if (box_w >= 2) box_w - 2 else box_w;
    const start = palette.slashWindowStart(selected, hits.len, view);
    const filled = palette.slashVisible(hits.len -| start, view);
    const vis = if (hits.len == 0) hits else hits[start .. start + filled];
    const vis_sel: usize = if (hits.len == 0) 0 else selected - start;
    var name_w: u16 = 0;
    for (vis) |hit| name_w = @max(name_w, cellsTo(rowTitle(hit)));
    const cap: u16 = if (inner > 8) inner / 2 else inner;
    name_w = @min(name_w, cap);

    const top = try boxEdge(allocator, box_w, "╭", "╮");
    defer allocator.free(top);
    const bot = try boxBottomCount(allocator, box_w, selected, hits.len, view);
    defer allocator.free(bot);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, top);
    var body_rows: usize = 0;
    if (vis.len == 0) {
        try out.append(allocator, '\n');
        try writeBoxRow(allocator, &out, inner, " no match");
        body_rows = 1;
    }
    for (vis, 0..) |hit, i| {
        try out.append(allocator, '\n');
        const sel = i == vis_sel;
        const mark: []const u8 = if (sel) "▸ " else "  ";
        const title = clipCells(rowTitle(hit), name_w);
        const named = try padCells(allocator, title, name_w);
        defer allocator.free(named);
        const used = 2 + name_w + 2;
        const help_cols: u16 = if (inner > used) inner - used else 0;
        const help = clipCells(rowMeta(hit), help_cols);
        const helped = try padCells(allocator, help, help_cols);
        defer allocator.free(helped);
        // Selected row: accent marker and title, meta stays quiet either way.
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "│");
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, if (sel) paint.accent else paint.border);
        try out.appendSlice(allocator, mark);
        try out.appendSlice(allocator, if (sel) paint.bold ++ paint.accent else paint.label);
        try out.appendSlice(allocator, named);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, helped);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "│");
        try out.appendSlice(allocator, paint.reset);
        body_rows += 1;
    }
    while (body_rows < view) : (body_rows += 1) {
        try out.append(allocator, '\n');
        try writeBoxRow(allocator, &out, inner, "");
    }
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, bot);
    return out.toOwnedSlice(allocator);
}

test "slash menu highlights the selected row" {
    const hits = [_]slash.Spec{
        .{ .name = "/help", .help = "list slash commands" },
        .{ .name = "/quit", .help = "exit" },
    };
    const s = try formatSlashMenu(std.testing.allocator, 40, &hits, 1, 8);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "/quit") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "▸") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.accent) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[2K") == null);
}

test "a flipped row leads with the description, not the id" {
    const hits = [_]slash.Spec{
        .{ .name = "grok-composer-2.5-fast", .help = "Grok Composer 2.5 Fast", .flip = true },
    };
    const s = try formatSlashMenu(std.testing.allocator, 64, &hits, 0, 8);
    defer std.testing.allocator.free(s);
    const title_at = std.mem.indexOf(u8, s, "Grok Composer 2.5 Fast") orelse {
        try std.testing.expect(false);
        return;
    };
    const id_at = std.mem.indexOf(u8, s, "grok-composer-2.5-fast") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(title_at < id_at);
}

test "slash menu windows past the first page" {
    var hits: [12]slash.Spec = undefined;
    for (&hits, 0..) |*h, i| {
        h.* = .{ .name = "/help", .help = "x" };
        _ = i;
    }
    hits[0].name = "/help";
    hits[9].name = "/trace";
    const s = try formatSlashMenu(std.testing.allocator, 40, &hits, 9, 6);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "/trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "10/12") != null);
    try std.testing.expectEqual(@as(usize, 4), palette.slashWindowStart(9, 12, 6));
}

test "the slash menu fits every width" {
    const a = std.testing.allocator;
    const hits = [_]slash.Spec{
        .{ .name = "/a-very-long-command-name-here", .help = "an equally long description of what it does" },
        .{ .name = "/b", .help = "short" },
    };
    for ([_]u16{ 1, 2, 8, 20, 40, 80, 200 }) |cols| {
        const menu = try formatSlashMenu(a, cols, &hits, 0, 2);
        defer a.free(menu);
        try std.testing.expect(widestRow(menu) <= cols);
    }
}

test "picker menu height follows match count" {
    const layout = @import("../layout.zig").Layout.compute(24, 80);
    var b: [12]slash.Spec = undefined;
    for (&b) |*h| h.* = .{ .name = "/help", .help = "x" };
    const two = try formatSlashMenu(std.testing.allocator, 80, b[0..2], 0, palette.paletteItemRows(layout, 2));
    defer std.testing.allocator.free(two);
    const many = try formatSlashMenu(std.testing.allocator, 80, &b, 0, palette.paletteItemRows(layout, b.len));
    defer std.testing.allocator.free(many);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, two, "\n"));
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, many, "\n"));
}
