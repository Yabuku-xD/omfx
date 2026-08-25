//! Centered modal overlay. Permission and confirm flows share one box so the
//! pane does not invent a new shape per prompt.

const std = @import("std");
const paint = @import("../core/ansi.zig");
const width = @import("width.zig");
const virt = @import("virt.zig");

pub const max_cols: u16 = 72;
pub const max_body_lines: usize = 16;

pub const Button = struct {
    key: []const u8,
    label: []const u8,
};

pub const perm_buttons = [_]Button{
    .{ .key = "1", .label = "Allow once" },
    .{ .key = "2", .label = "Always allow this" },
    .{ .key = "3", .label = "Don't allow" },
};

pub const Geometry = struct {
    cols: u16,
    rows: u16,
    row0: u16,
    col0: u16,
};

pub fn geometry(term_rows: u16, term_cols: u16, body_lines: usize, button_n: usize) Geometry {
    const want_cols: u16 = @min(max_cols, if (term_cols > 6) term_cols - 4 else term_cols);
    const shown = @min(body_lines, max_body_lines);
    const inner = 1 + shown + 1 + button_n + 2;
    const want_rows: u16 = @intCast(@min(@as(usize, term_rows), inner + 2));
    return .{
        .cols = @max(want_cols, 24),
        .rows = @max(want_rows, 7),
        .row0 = if (term_rows > want_rows) (term_rows - want_rows) / 2 + 1 else 1,
        .col0 = if (term_cols > want_cols) (term_cols - want_cols) / 2 + 1 else 1,
    };
}

fn padLine(out: *std.ArrayList(u8), a: std.mem.Allocator, inner: u16, text: []const u8, fg: []const u8) !void {
    try out.appendSlice(a, paint.border);
    try out.appendSlice(a, "│");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, fg);
    const take = width.indexAtCell(text, inner);
    try out.appendSlice(a, text[0..take]);
    var used = width.cellsTo(text[0..take]);
    while (used < inner) : (used += 1) try out.append(a, ' ');
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.border);
    try out.appendSlice(a, "│");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.el);
    try out.append(a, '\n');
}

fn padPainted(out: *std.ArrayList(u8), a: std.mem.Allocator, inner: u16, text: []const u8) !void {
    try out.appendSlice(a, paint.border);
    try out.appendSlice(a, "│");
    try out.appendSlice(a, paint.reset);
    const take = width.indexAtCell(text, inner);
    try out.appendSlice(a, text[0..take]);
    var used = width.cellsTo(text[0..take]);
    while (used < inner) : (used += 1) try out.append(a, ' ');
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.border);
    try out.appendSlice(a, "│");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.el);
    try out.append(a, '\n');
}

fn ruleLine(out: *std.ArrayList(u8), a: std.mem.Allocator, inner: u16) !void {
    try out.appendSlice(a, paint.border);
    try out.appendSlice(a, "├");
    var i: u16 = 0;
    while (i < inner) : (i += 1) try out.appendSlice(a, "─");
    try out.appendSlice(a, "┤");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.el);
    try out.append(a, '\n');
}

fn topLine(out: *std.ArrayList(u8), a: std.mem.Allocator, inner: u16) !void {
    try out.appendSlice(a, paint.border);
    try out.appendSlice(a, "╭");
    var i: u16 = 0;
    while (i < inner) : (i += 1) try out.appendSlice(a, "─");
    try out.appendSlice(a, "╮");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.el);
    try out.append(a, '\n');
}

fn botLine(out: *std.ArrayList(u8), a: std.mem.Allocator, inner: u16) !void {
    try out.appendSlice(a, paint.border);
    try out.appendSlice(a, "╰");
    var i: u16 = 0;
    while (i < inner) : (i += 1) try out.appendSlice(a, "─");
    try out.appendSlice(a, "╯");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.el);
    try out.append(a, '\n');
}

pub fn bodyLineCount(body: []const u8) usize {
    if (body.len == 0) return 1;
    return std.mem.count(u8, body, "\n") + 1;
}

/// `painted_body` true = lines already carry SGR (diff); false = plain text.
pub fn render(
    allocator: std.mem.Allocator,
    g: Geometry,
    title: []const u8,
    body: []const u8,
    buttons: []const Button,
    sel: usize,
    painted_body: bool,
) ![]u8 {
    const inner: u16 = if (g.cols > 2) g.cols - 2 else g.cols;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try topLine(&out, allocator, inner);
    try padLine(&out, allocator, inner, title, paint.warn);
    try ruleLine(&out, allocator, inner);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (lines >= max_body_lines) break;
        if (painted_body) {
            try padPainted(&out, allocator, inner, line);
        } else {
            try padLine(&out, allocator, inner, line, paint.asst_fg);
        }
        lines += 1;
    }
    if (lines == 0) try padLine(&out, allocator, inner, "", paint.asst_fg);

    try ruleLine(&out, allocator, inner);
    const focus = virt.clampSel(buttons.len, sel);
    for (buttons, 0..) |b, i| {
        var row_buf: [96]u8 = undefined;
        const row = std.fmt.bufPrint(&row_buf, " {s}  {s}", .{ b.key, b.label }) catch b.label;
        const fg = if (i == focus) paint.accent else paint.muted;
        const mark = if (i == focus) "▸" else " ";
        var marked: [100]u8 = undefined;
        const full = std.fmt.bufPrint(&marked, "{s}{s}", .{ mark, row }) catch row;
        try padLine(&out, allocator, inner, full, fg);
    }
    try botLine(&out, allocator, inner);
    return out.toOwnedSlice(allocator);
}

test "geometry centers on a tall pane" {
    const g = geometry(40, 80, 2, 3);
    try std.testing.expect(g.row0 > 1);
    try std.testing.expect(g.col0 > 1);
    try std.testing.expect(g.cols <= max_cols);
}

test "render names the action and buttons" {
    const g = geometry(24, 80, 2, 3);
    const s = try render(
        std.testing.allocator,
        g,
        "Allow this?",
        "Change a file\nsrc/hello.txt",
        &perm_buttons,
        0,
        false,
    );
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Allow this?") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Allow once") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Always allow this") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Don't allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Change a file") != null);
}

test "narrow terminal still renders" {
    const g = geometry(12, 30, 3, 3);
    const s = try render(std.testing.allocator, g, "Allow this?", "Write a file", &perm_buttons, 2, false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(s.len > 0);
}

test "confirm buttons name the consequence" {
    const buttons = [_]Button{
        .{ .key = "1", .label = "Leave" },
        .{ .key = "2", .label = "Stay" },
    };
    const g = geometry(20, 60, 2, buttons.len);
    const s = try render(std.testing.allocator, g, "Leave omfx?", "Your chat is saved.", &buttons, 0, false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Leave omfx?") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Leave") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Stay") != null);
}

test "tiny pane still has room for buttons" {
    const g = geometry(8, 24, 8, 3);
    try std.testing.expect(g.cols >= 24);
    try std.testing.expect(g.rows >= 7);
    const s = try render(std.testing.allocator, g, "Allow this?", "a\nb\nc\nd\ne\nf\ng\nh", &perm_buttons, 0, false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Allow once") != null);
}
