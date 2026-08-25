//! Virtual window over a long list: only `view` rows are painted.
//!
//! Panels and pickers already scrolled; this names the math once so a short
//! terminal and a tall one keep the selection on screen the same way.

const std = @import("std");

pub fn windowStart(total: usize, sel: usize, view: usize) usize {
    if (total <= view or view == 0) return 0;
    var start: usize = if (sel + 1 > view) sel + 1 - view else 0;
    if (start + view > total) start = total - view;
    return start;
}

pub fn viewRows(term_rows: u16, chrome: u16, max_view: u16) usize {
    const room: usize = if (term_rows > chrome) term_rows - chrome else 1;
    return @min(room, max_view);
}

pub fn clampSel(total: usize, sel: usize) usize {
    if (total == 0) return 0;
    return @min(sel, total - 1);
}

test "window keeps selection on screen" {
    try std.testing.expectEqual(@as(usize, 0), windowStart(10, 0, 5));
    try std.testing.expectEqual(@as(usize, 0), windowStart(10, 4, 5));
    try std.testing.expectEqual(@as(usize, 1), windowStart(10, 5, 5));
    try std.testing.expectEqual(@as(usize, 5), windowStart(10, 9, 5));
}

test "viewRows shrinks on a short terminal" {
    try std.testing.expectEqual(@as(usize, 5), viewRows(10, 5, 15));
    try std.testing.expectEqual(@as(usize, 15), viewRows(40, 5, 15));
    try std.testing.expectEqual(@as(usize, 1), viewRows(3, 5, 15));
}

test "clampSel" {
    try std.testing.expectEqual(@as(usize, 0), clampSel(0, 3));
    try std.testing.expectEqual(@as(usize, 2), clampSel(3, 9));
}
