const std = @import("std");
const Io = std.Io;

const tty = @import("../tty.zig");
const layout_mod = @import("layout.zig");
const palette = @import("palette.zig");
const scroll_mod = @import("scroll.zig");
const width = @import("../width.zig");
const paint = @import("../../core/ansi.zig");
const footer_mod = @import("footer.zig");

pub const Transcript = @import("../transcript.zig").Transcript;
pub const Layout = layout_mod.Layout;
pub const moveTo = layout_mod.moveTo;
pub const Footer = footer_mod.Footer;
pub const Turn = footer_mod.Turn;
pub const Hint = footer_mod.Hint;
pub const Sel = footer_mod.Sel;
pub const welcome = footer_mod.welcome;
pub const min_card_cols = footer_mod.min_card_cols;
pub const min_menu_cols = footer_mod.min_menu_cols;
pub const generating = footer_mod.generating;
pub const stop_hint = footer_mod.stop_hint;
pub const queued_hint = footer_mod.queued_hint;

pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";
pub const enter_alt = tty.enter_seq;
pub const leave_alt = tty.restore_seq;

pub const PaintError = error{ OutOfMemory, WriteFailed, NoSpaceLeft };

const cellsTo = width.cellsTo;
const indexAtCell = width.indexAtCell;
const utf8LenAt = width.utf8LenAt;
const skipEsc = width.skipEsc;

const formatHeader = footer_mod.formatHeader;
const formatFooter = footer_mod.formatFooter;
const formatSlashMenu = footer_mod.formatSlashMenu;
const formatWelcome = footer_mod.formatWelcome;

pub fn setScrollRegion(buf: []u8, top: u16, bottom: u16) ![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}r", .{ top, bottom });
}

fn overlayFor(layout: Layout, n: usize) union(enum) { none, menu: u16 } {
    const h = palette.palettePaintRows(layout, n);
    if (h == 0) return .none;
    return .{ .menu = h };
}

fn eraseRows(stdout: *Io.Writer, from_row: u16, n: u16) !void {
    var cup: [32]u8 = undefined;
    var r: u16 = 0;
    while (r < n) : (r += 1) {
        const at = try moveTo(&cup, from_row + r, 1);
        try stdout.writeAll(at);
        try stdout.writeAll("\x1b[2K");
    }
}

fn writeLinesAt(stdout: *Io.Writer, from_row: u16, text: []const u8) !void {
    var cup: [32]u8 = undefined;
    var r = from_row;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const at = try moveTo(&cup, r, 1);
        try stdout.writeAll(at);
        try stdout.writeAll("\x1b[2K");
        try stdout.writeAll(line);
        r +|= 1;
    }
}

fn widestRow(bytes: []const u8) u16 {
    var widest: u16 = 0;
    var row: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\n' or bytes[i] == '\r') {
            widest = @max(widest, width.cellsTo(bytes[row..i]));
            i += 1;
            row = i;
            continue;
        }
        if (bytes[i] == 0x1b) {
            const end = width.skipEsc(bytes, i);
            if (end > i + 1 and (bytes[end - 1] == 'H' or bytes[end - 1] == 'f')) {
                widest = @max(widest, width.cellsTo(bytes[row..i]));
                row = end;
            }
            i = end;
            continue;
        }
        i += 1;
    }
    return @max(widest, width.cellsTo(bytes[row..]));
}
pub fn writeFooter(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
) PaintError!void {
    try writeChrome(allocator, stdout, layout, footer);
}

pub fn writeChrome(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
) PaintError!void {
    var move_buf: [32]u8 = undefined;
    const head = try formatHeader(allocator, layout, footer);
    defer allocator.free(head);
    const move = try moveTo(&move_buf, layout.footer_start_row, 1);
    const body = try formatFooter(allocator, layout, footer);
    defer allocator.free(body);
    try stdout.writeAll(sync_begin);
    try stdout.writeAll(hide_cursor);
    try stdout.writeAll(head);
    const overlay = chromeOverlay(footer);
    if (overlay != 0 and layout.footer_start_row > layout.transcript_start_row) {
        const start_row = layout.footer_start_row - @min(overlay, layout.footer_start_row - layout.transcript_start_row);
        try eraseRows(stdout, start_row, overlay);
        var cup: [32]u8 = undefined;
        var r = start_row;
        for (footer.tasks) |line| {
            try stdout.writeAll(try moveTo(&cup, r, 1));
            try stdout.writeAll(line);
            try stdout.writeAll("\x1b[K");
            r +|= 1;
        }
        for (footer.peek) |line| {
            try stdout.writeAll(try moveTo(&cup, r, 1));
            try stdout.writeAll(line);
            try stdout.writeAll("\x1b[K");
            r +|= 1;
        }
        if (footer.jump) {
            const pill = try formatJumpPill(allocator, layout.cols);
            defer allocator.free(pill);
            try stdout.writeAll(try moveTo(&cup, r, 1));
            try stdout.writeAll(pill);
            try stdout.writeAll("\x1b[K");
        } else if (footer.toast.len != 0) {
            try stdout.writeAll(try moveTo(&cup, r, 1));
            try stdout.writeAll(footer.toast);
            try stdout.writeAll("\x1b[K");
        }
    }
    switch (overlayFor(layout, footer.slash.len)) {
        .none => {},
        .menu => |overlay_h| {
            const start_row = layout.footer_start_row - @min(overlay_h, layout.footer_start_row - 1);
            try eraseRows(stdout, start_row, overlay_h);
            const menu = try formatSlashMenu(allocator, layout.cols, footer.slash, footer.slash_sel, palette.paletteItemRows(layout, footer.slash.len));
            defer allocator.free(menu);
            try writeLinesAt(stdout, start_row, menu);
        },
    }
    try stdout.writeAll(move);
    try stdout.writeAll(body);
    // Shown in both states. A turn can be steered while it runs, so the
    // composer is live throughout, and a live prompt with no caret reads as a
    // prompt that has stopped taking input.
    try stdout.writeAll(show_cursor);
    try stdout.writeAll(sync_end);
}

pub fn composerRow(layout: Layout) u16 {
    if (layout.footer_rows >= 2)
        return @min(layout.rows, layout.footer_start_row + 1);
    return layout.footer_start_row;
}

pub fn inComposer(layout: Layout, row: u16) bool {
    return row == composerRow(layout);
}
pub const jump_label = "Jump to bottom (click) \u{2193}";

/// Full-width row with a centered pill. Empty cells outside the pill stay
/// inactive so a click beside the button does nothing.
pub fn formatJumpPill(allocator: std.mem.Allocator, cols: u16) ![]u8 {
    const inner = try std.fmt.allocPrint(allocator, " {s} ", .{jump_label});
    defer allocator.free(inner);
    const cells = width.cellsTo(inner);
    if (cells == 0) return allocator.dupe(u8, "");
    const pad: u16 = if (cols > cells) (cols - cells) / 2 else 0;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: u16 = 0;
    while (i < pad) : (i += 1) try out.append(allocator, ' ');
    try out.appendSlice(allocator, paint.sel_bg);
    try out.appendSlice(allocator, paint.user_fg);
    try out.appendSlice(allocator, inner);
    try out.appendSlice(allocator, paint.reset);
    return out.toOwnedSlice(allocator);
}

pub fn paintSequence(allocator: std.mem.Allocator, layout: Layout, footer: Footer) ![]u8 {
    var region_buf: [32]u8 = undefined;
    var move_buf: [32]u8 = undefined;
    const region = try setScrollRegion(&region_buf, layout.regionTop(), layout.regionBottom());
    const head = try formatHeader(allocator, layout, footer);
    defer allocator.free(head);
    const move = try moveTo(&move_buf, layout.footer_start_row, 1);
    const body = try formatFooter(allocator, layout, footer);
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "{s}\x1b[H\x1b[2J{s}{s}{s}{s}{s}{s}", .{
        enter_alt,
        sync_begin,
        region,
        head,
        move,
        body,
        sync_end,
    });
}

pub fn writeWelcome(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
) PaintError!void {
    var region_buf: [32]u8 = undefined;
    const region = try setScrollRegion(&region_buf, layout.regionTop(), layout.regionBottom());
    const card = try formatWelcome(allocator, layout, footer);
    defer allocator.free(card);
    try stdout.writeAll(sync_begin);
    try stdout.writeAll(region);
    try eraseRows(stdout, layout.transcript_start_row, layout.transcript_rows);
    try stdout.writeAll(card);
    try stdout.writeAll(sync_end);
}

/// Background off, foreground untouched.
pub const sel_off = "\x1b[49m";

/// `row` with cells [from, to) on the selection background.
///
/// The background is turned off with SGR 49 rather than a full reset so the
/// row keeps its own foreground colours, and it is re-asserted after every
/// escape inside the span, because a row is free to reset its own attributes
/// halfway through.
pub fn writeSelected(out: *Io.Writer, row: []const u8, from: u16, to: u16) !void {
    const a = width.indexAtCell(row, from);
    const b = width.indexAtCell(row, to);
    try out.writeAll(row[0..a]);
    try out.writeAll(paint.sel_bg);
    var i = a;
    while (i < b) {
        const nxt = width.skipEsc(row, i);
        if (nxt != i) {
            try out.writeAll(row[i..nxt]);
            try out.writeAll(paint.sel_bg);
            i = nxt;
            continue;
        }
        const len = width.utf8LenAt(row, i);
        if (len == 0) break;
        try out.writeAll(row[i..][0..len]);
        i += len;
    }
    try out.writeAll(sel_off);
    try out.writeAll(row[b..]);
}

/// The text of cells [from, to) with every escape sequence dropped: what goes
/// on the clipboard is what the eye sees, not how it was painted.
pub fn plainCells(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row: []const u8, from: u16, to: u16) !void {
    const a = width.indexAtCell(row, from);
    const b = width.indexAtCell(row, to);
    var i = a;
    while (i < b) {
        const nxt = width.skipEsc(row, i);
        if (nxt != i) {
            i = nxt;
            continue;
        }
        const len = width.utf8LenAt(row, i);
        if (len == 0) break;
        try out.appendSlice(allocator, row[i..][0..len]);
        i += len;
    }
}

/// Rows reserved above the footer for sticky chrome (tasks, peek, jump, toast).
pub fn chromeOverlay(footer: Footer) u16 {
    var n: u16 = @intCast(@min(footer.tasks.len + footer.peek.len, std.math.maxInt(u16)));
    if (footer.jump) n +|= 1 else if (footer.toast.len != 0) n +|= 1;
    return n;
}

pub fn writeTranscript(
    stdout: *Io.Writer,
    layout: Layout,
    t: *const Transcript,
    scroll: usize,
    sel: Sel,
) PaintError!void {
    return writeTranscriptOverlay(stdout, layout, t, scroll, sel, 0);
}

pub fn writeTranscriptOverlay(
    stdout: *Io.Writer,
    layout: Layout,
    t: *const Transcript,
    scroll: usize,
    sel: Sel,
    overlay_h: u16,
) PaintError!void {
    const total = t.rowCount();
    const full = layout.transcript_rows;
    const rows: u16 = if (full > overlay_h) full - overlay_h else full;
    if (rows == 0) return;
    const off = @min(scroll, scroll_mod.maxScroll(total, rows));
    const start: usize = if (total > rows + off) total - rows - off else 0;
    const vis: u16 = if (total > start) @intCast(@min(rows, total - start)) else 0;
    const first = scroll_mod.transcriptFirstRow(layout.transcript_start_row, rows, vis);
    const bottom = layout.scrollBottom(overlay_h);
    var region_buf: [32]u8 = undefined;
    const region = try setScrollRegion(&region_buf, layout.regionTop(), bottom);
    try stdout.writeAll(sync_begin);
    try stdout.writeAll(region);
    try stdout.writeAll("\x1b[?7l");
    try eraseRows(stdout, layout.transcript_start_row, rows);
    var cup: [32]u8 = undefined;
    var i = start;
    var shown: u16 = 0;
    while (i < total and shown < vis) : (i += 1) {
        try stdout.writeAll(try moveTo(&cup, first + shown, 1));
        const row = t.row(i);
        const hit = if (sel.where == .transcript) sel.span(i, width.cellsTo(row)) else null;
        if (hit) |h| try writeSelected(stdout, row, h.from, h.to) else try stdout.writeAll(row);
        try stdout.writeAll("\x1b[K");
        shown += 1;
    }
    try stdout.writeAll("\x1b[?7h");
    try stdout.writeAll(sync_end);
}

/// The allocator here is footer-only: bounded by terminal width, and freed.
pub fn writePane(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
    t: *Transcript,
    scroll: usize,
) PaintError!void {
    stdout.writeAll(hide_cursor) catch return error.WriteFailed;
    // The activity row belongs to the turn, so it is set here rather than left
    // to each of the callers to remember.
    t.setStatus(switch (footer.turn) {
        .generating => footer.status,
        .idle => "",
    });
    // Open todos live in footer chrome, not the scrollback — clear any legacy
    // pin so they cannot double-draw or steal scroll height.
    t.setPinned(&.{});
    const overlay = chromeOverlay(footer);
    if (t.isEmpty() and footer.turn == .idle) {
        try writeWelcome(allocator, stdout, layout, footer);
    } else {
        try writeTranscriptOverlay(stdout, layout, t, scroll, footer.sel, overlay);
    }
    try writeFooter(allocator, stdout, layout, footer);
}

test "paint keeps footer start after many lines" {
    const layout = Layout.compute(24, 80);
    const painted = try paintSequence(std.testing.allocator, layout, .{
        .model = "anthropic/claude",
        .permission = "ask",
        .composer = "> ",
    });
    defer std.testing.allocator.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, enter_alt) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, sync_begin) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[21;1H") != null);
}

test "writeTranscript clears the pane and paints chunks" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var t = Transcript.init(std.testing.allocator, layout.cols);
    defer t.deinit();
    try t.append("hello from user\n");
    try writeTranscript(&aw.writer, layout, &t, 0, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "hello from user") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[19;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Oh My Fx") == null);
}

test "writePane paints chat then footer" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var t = Transcript.init(std.testing.allocator, layout.cols);
    defer t.deinit();
    try t.append("hello from user\n");
    try writePane(std.testing.allocator, &aw.writer, layout, .{
        .model = "x",
        .permission = "normal",
        .composer = "> ",
        .place = "/tmp",
    }, &t, 0);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "hello from user") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "enter send") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), hide_cursor) != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), show_cursor) != null);
}

test "writePane hides the caret only while it redraws" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var t = Transcript.init(std.testing.allocator, layout.cols);
    defer t.deinit();
    try t.append("You\nhey\n");
    try writePane(std.testing.allocator, &aw.writer, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "",
        .place = "/tmp",
        .turn = .generating,
    }, &t, 0);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, generating) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, stop_hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, hide_cursor) != null);
    // Parked back on the composer at the end of the frame: the pane hides the
    // caret while it redraws, not for the length of the turn.
    try std.testing.expect(std.mem.indexOf(u8, out, show_cursor) != null);
}

test "writeFooter without a menu does not wipe the transcript band" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeFooter(std.testing.allocator, &aw.writer, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "",
        .place = "/tmp",
    });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[13;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[20;1H") == null);
}

test "jump pill is centered on the row" {
    const a = std.testing.allocator;
    const layout = Layout.compute(24, 80);
    const pill = try formatJumpPill(a, layout.cols);
    defer a.free(pill);
    try std.testing.expect(std.mem.indexOf(u8, pill, jump_label) != null);
}
