const std = @import("std");

const layout_mod = @import("layout.zig");
const width = @import("../width.zig");

pub const Layout = layout_mod.Layout;
pub const Transcript = @import("../transcript.zig").Transcript;

const cellsTo = width.cellsTo;

/// One binding and what it does. `pinned` survives a narrow terminal; the rest
/// are dropped, last first, until the row fits.
///
/// The bar used to be three hand-written strings per context, which meant every
/// new binding had to be spliced into each of them at the right width. Building
/// it from the list a context actually offers is how grok-build does it, and it
/// is the only way the bar cannot drift from the keys that work.
pub const HintItem = struct {
    keys: []const u8,
    label: []const u8,
    pinned: bool = false,
};

pub const hint_sep = "  \u{b7}  ";
const hint_sep_cells: u16 = 5;
pub const max_hints: usize = 8;

const scrollback_hints = [_]HintItem{
    .{ .keys = "j/k", .label = "move", .pinned = true },
    .{ .keys = "e", .label = "see all", .pinned = true },
    .{ .keys = "y", .label = "copy" },
    .{ .keys = "n/p", .label = "section" },
    .{ .keys = "esc", .label = "back", .pinned = true },
};

fn hintCells(item: HintItem) u16 {
    return cellsTo(item.keys) + 1 + cellsTo(item.label);
}

fn hintWidth(items: []const HintItem, keep: *const [max_hints]bool) u16 {
    var total: u16 = 0;
    var shown: usize = 0;
    for (items, 0..) |item, i| {
        if (!keep[i]) continue;
        total +|= hintCells(item) + (if (shown == 0) @as(u16, 0) else hint_sep_cells);
        shown += 1;
    }
    return total;
}

fn lastKept(keep: *const [max_hints]bool) ?usize {
    var found: ?usize = null;
    for (keep, 0..) |on, i| {
        if (on) found = i;
    }
    return found;
}

fn clipCells(src: []const u8, cols: u16) []const u8 {
    if (cellsTo(src) <= cols) return src;
    return src[0..width.indexAtCell(src, cols)];
}

pub fn renderHints(buf: []u8, all: []const HintItem, cols: u16) []const u8 {
    // Clamped, not asserted: a release build with one hint too many would write
    // past `keep`, and a dropped hint is not worth that.
    const items = all[0..@min(all.len, max_hints)];
    var keep: [max_hints]bool = @splat(false);
    var used: u16 = 0;
    var shown: usize = 0;
    for (items, 0..) |item, i| {
        if (!item.pinned) continue;
        keep[i] = true;
        used += hintCells(item) + (if (shown == 0) @as(u16, 0) else hint_sep_cells);
        shown += 1;
    }
    for (items, 0..) |item, i| {
        if (item.pinned) continue;
        const want = hintCells(item) + (if (shown == 0) @as(u16, 0) else hint_sep_cells);
        if (used + want > cols) continue;
        keep[i] = true;
        used += want;
        shown += 1;
    }
    // Even the pinned hints can overrun a narrow pane. They give way from the
    // front, because the last one is the way back out and half a hint is worse
    // than one fewer.
    while (hintWidth(items, &keep) > cols) {
        const last = lastKept(&keep) orelse break;
        var dropped = false;
        for (keep[0..items.len], 0..) |on, i| {
            if (!on or i == last) continue;
            keep[i] = false;
            dropped = true;
            break;
        }
        if (!dropped) break;
    }

    var n: usize = 0;
    var first = true;
    for (items, 0..) |item, i| {
        if (!keep[i]) continue;
        if (!first) {
            if (n + hint_sep.len > buf.len) break;
            @memcpy(buf[n..][0..hint_sep.len], hint_sep);
            n += hint_sep.len;
        }
        first = false;
        const one = std.fmt.bufPrint(buf[n..], "{s} {s}", .{ item.keys, item.label }) catch break;
        n += one.len;
    }
    return clipCells(buf[0..n], cols);
}

/// The keys that work in the scrollback are not the keys that work in the
/// composer, and a bar that lies about that is worse than no bar.
pub fn scrollbackHint(buf: []u8, cols: u16) []const u8 {
    return renderHints(buf, &scrollback_hints, cols);
}

pub fn maxScroll(total: usize, rows: u16) usize {
    return if (total > rows) total - rows else 0;
}

/// Rows from the live tail before the jump-to-bottom pill appears.
pub fn jumpThreshold(transcript_rows: u16) usize {
    return @max(3, transcript_rows / 4);
}

pub fn jumpVisible(scroll: usize, transcript_rows: u16) bool {
    return scroll >= jumpThreshold(transcript_rows);
}

/// Label matches the Cursor affordance people already know.
pub const jump_label = "Jump to bottom (click) \u{2193}";

pub const JumpHit = struct {
    /// 1-based terminal row (matches SGR mouse reports).
    row: u16,
    /// Inclusive 1-based columns of the pill only — not the full row.
    col0: u16,
    col1: u16,
};

pub fn jumpHitBox(layout: Layout) ?JumpHit {
    if (layout.footer_start_row <= layout.transcript_start_row) return null;
    const row = layout.footer_start_row - 1;
    // One cell of padding each side inside the pill.
    const inner_cells = width.cellsTo(jump_label) + 2;
    if (inner_cells == 0 or inner_cells > layout.cols) return null;
    const start0 = (layout.cols - inner_cells) / 2;
    return .{
        .row = row,
        .col0 = start0 + 1,
        .col1 = start0 + inner_cells,
    };
}

pub fn jumpHit(layout: Layout, term_row: u16, term_col: u16) bool {
    const box = jumpHitBox(layout) orelse return false;
    return term_row == box.row and term_col >= box.col0 and term_col <= box.col1;
}

/// Rightmost header cells that open the context panel (matches idle click).
pub fn contextHitBox(layout: Layout) ?JumpHit {
    if (layout.header_rows == 0 or layout.cols < 16) return null;
    return .{
        .row = 1,
        .col0 = layout.cols - 15,
        .col1 = layout.cols,
    };
}

pub fn contextHit(layout: Layout, term_row: u16, term_col: u16) bool {
    const box = contextHitBox(layout) orelse return false;
    return term_row == box.row and term_col >= box.col0 and term_col <= box.col1;
}

/// Rows one mouse-wheel notch moves the transcript.
pub const wheel_step: u16 = 3;

/// Stays put when content already fits, so the pane does not flicker.
pub fn stepScroll(scroll: usize, total: usize, rows: u16, up: bool, step: u16) usize {
    const max = maxScroll(total, rows);
    if (up) return @min(max, scroll + step);
    if (scroll > step) return @min(max, scroll - step);
    return 0;
}
pub fn transcriptRowAt(layout: Layout, t: *const Transcript, scroll: usize, term_row: u16) ?usize {
    const total = t.rowCount();
    const rows = layout.transcript_rows;
    if (rows == 0 or total == 0) return null;
    const off = @min(scroll, maxScroll(total, rows));
    const start: usize = if (total > rows + off) total - rows - off else 0;
    const vis: u16 = if (total > start) @intCast(@min(rows, total - start)) else 0;
    const first = transcriptFirstRow(layout.transcript_start_row, rows, vis);
    if (term_row < first or term_row >= first + vis) return null;
    return start + (term_row - first);
}

pub fn transcriptFirstRow(start_row: u16, rows: u16, vis: u16) u16 {
    if (vis == 0 or vis >= rows) return start_row;
    return start_row + (rows - vis);
}

test "transcript sits above the footer" {
    try std.testing.expectEqual(@as(u16, 19), transcriptFirstRow(2, 19, 2));
    try std.testing.expectEqual(@as(u16, 2), transcriptFirstRow(2, 19, 19));
    try std.testing.expectEqual(@as(u16, 2), transcriptFirstRow(2, 19, 0));
}

test "the way out is the last hint to go" {
    var buf: [256]u8 = undefined;
    const wide = scrollbackHint(&buf, 72);
    try std.testing.expect(std.mem.indexOf(u8, wide, "j/k move") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "y copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "n/p section") != null);

    // Too narrow for all three pinned hints: the escape hatch survives.
    var buf2: [256]u8 = undefined;
    const narrow = scrollbackHint(&buf2, 24);
    try std.testing.expect(cellsTo(narrow) <= 24);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "esc back") != null);

    var buf3: [256]u8 = undefined;
    const tiny = scrollbackHint(&buf3, 9);
    try std.testing.expect(cellsTo(tiny) <= 9);
    try std.testing.expectEqualStrings("esc back", tiny);
}

test "stepScroll does not move when content fits" {
    try std.testing.expectEqual(@as(usize, 0), maxScroll(10, 20));
    try std.testing.expectEqual(@as(usize, 0), stepScroll(0, 10, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 0), stepScroll(0, 10, 20, false, 3));
}

test "stepScroll clamps to the last page" {
    try std.testing.expectEqual(@as(usize, 5), maxScroll(25, 20));
    try std.testing.expectEqual(@as(usize, 3), stepScroll(0, 25, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 5), stepScroll(3, 25, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 5), stepScroll(5, 25, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 2), stepScroll(5, 25, 20, false, 3));
    try std.testing.expectEqual(@as(usize, 0), stepScroll(2, 25, 20, false, 3));
}

test "a click maps back to the row the pane painted there" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("one\ntwo\nthree\n");
    const layout = Layout.compute(24, 80);
    const first = transcriptFirstRow(layout.transcript_start_row, layout.transcript_rows, 3);
    try std.testing.expectEqual(@as(?usize, 0), transcriptRowAt(layout, &t, 0, first));
    try std.testing.expectEqual(@as(?usize, 2), transcriptRowAt(layout, &t, 0, first + 2));
    try std.testing.expectEqual(@as(?usize, null), transcriptRowAt(layout, &t, 0, first + 3));
    try std.testing.expectEqual(@as(?usize, null), transcriptRowAt(layout, &t, 0, 0));
}

test "jump pill is centered and hit-tested only on the label" {
    const layout = Layout.compute(24, 80);
    try std.testing.expect(jumpVisible(20, layout.transcript_rows));
    try std.testing.expect(!jumpVisible(0, layout.transcript_rows));
    const box = jumpHitBox(layout).?;
    try std.testing.expect(jumpHit(layout, box.row, box.col0));
    try std.testing.expect(jumpHit(layout, box.row, box.col1));
    try std.testing.expect(!jumpHit(layout, box.row, 1));
    try std.testing.expect(!jumpHit(layout, box.row, layout.cols));
}
