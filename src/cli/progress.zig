//! Determinate progress bar. Spinner covers unknown work; this covers known
//! fractions (update stages, job bytes when reported).

const std = @import("std");
const paint = @import("../core/ansi.zig");
const width = @import("width.zig");

pub fn barWidth(cols: u16) u16 {
    if (cols < 20) return 8;
    if (cols < 40) return 16;
    return 24;
}

fn push(buf: []u8, n: *usize, part: []const u8) bool {
    if (n.* + part.len > buf.len) return false;
    @memcpy(buf[n.*..][0..part.len], part);
    n.* += part.len;
    return true;
}

pub fn render(buf: []u8, cols: u16, done: u64, total: u64, label: []const u8) []const u8 {
    const tw = barWidth(cols);
    const pct: u64 = if (total == 0) 0 else @min(100, (done * 100) / total);
    const filled: u16 = if (total == 0) 0 else @intCast(@min(@as(u64, tw), (done * tw) / total));
    const lab = if (width.cellsTo(label) > 18) label[0..@min(label.len, 18)] else label;

    var n: usize = 0;
    if (!push(buf, &n, paint.muted)) return "";
    if (!push(buf, &n, lab)) return "";
    if (!push(buf, &n, " ")) return "";
    if (!push(buf, &n, paint.accent_dim)) return "";
    if (!push(buf, &n, "[")) return "";
    var i: u16 = 0;
    while (i < tw) : (i += 1) {
        if (!push(buf, &n, if (i < filled) "█" else "░")) return "";
    }
    if (!push(buf, &n, "]")) return "";
    if (!push(buf, &n, paint.muted)) return "";
    var pct_buf: [8]u8 = undefined;
    const pct_s = std.fmt.bufPrint(&pct_buf, " {d}%", .{pct}) catch return "";
    if (!push(buf, &n, pct_s)) return "";
    if (!push(buf, &n, paint.reset)) return "";
    return buf[0..n];
}

test "bar fills and reports percent" {
    var buf: [256]u8 = undefined;
    const s = render(&buf, 80, 1, 2, "update");
    try std.testing.expect(s.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, s, "50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "█") != null);
}

test "barWidth responds to cols" {
    try std.testing.expectEqual(@as(u16, 8), barWidth(12));
    try std.testing.expectEqual(@as(u16, 24), barWidth(80));
}
