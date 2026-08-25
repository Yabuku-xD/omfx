//! Unified diff with hunk awareness. Collapsed: preview + expand hint.
//! Expanded (opened call): full colour without drowning the summary card.

const std = @import("std");
const paint = @import("../core/ansi.zig");
const chat_clip = struct {
    // Local clip: avoid importing chat (cycle). Same rule as chat.clipCols.
    fn cols(src: []const u8, n: u16) []const u8 {
        if (n == 0 or src.len == 0) return "";
        var cells: u16 = 0;
        var i: usize = 0;
        while (i < src.len) {
            if (src[i] == '\x1b') {
                i += 1;
                if (i < src.len and src[i] == '[') {
                    i += 1;
                    while (i < src.len and (src[i] < 0x40 or src[i] > 0x7e)) : (i += 1) {}
                    if (i < src.len) i += 1;
                }
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
            if (i + len > src.len) break;
            cells += 1;
            if (cells > n) return src[0..i];
            i += len;
        }
        return src;
    }
};

pub const hunk_preview: usize = 8;
/// Hard cap on collapsed total lines (headers + previews).
pub const collapsed_cap: usize = 36;

fn appendPadded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8, cols: u16) !void {
    try out.appendSlice(allocator, chat_clip.cols(line, cols));
}

fn paintLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8, cols: u16) !void {
    if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "diff ")) {
        try out.appendSlice(allocator, paint.dim);
        try appendPadded(out, allocator, line, cols);
        try out.appendSlice(allocator, paint.reset);
    } else if (std.mem.startsWith(u8, line, "@@")) {
        try out.appendSlice(allocator, paint.hunk);
        try appendPadded(out, allocator, line, cols);
        try out.appendSlice(allocator, paint.reset);
    } else if (std.mem.startsWith(u8, line, "+")) {
        try out.appendSlice(allocator, paint.add_bg);
        try out.appendSlice(allocator, paint.add_fg);
        try appendPadded(out, allocator, line, cols);
        try out.appendSlice(allocator, paint.reset);
    } else if (std.mem.startsWith(u8, line, "-")) {
        try out.appendSlice(allocator, paint.del_bg);
        try out.appendSlice(allocator, paint.del_fg);
        try appendPadded(out, allocator, line, cols);
        try out.appendSlice(allocator, paint.reset);
    } else {
        try out.appendSlice(allocator, paint.dim);
        const rest = if (line.len > 0 and line[0] == ' ') line[1..] else line;
        try out.append(allocator, ' ');
        try appendPadded(out, allocator, rest, if (cols > 0) cols - 1 else cols);
        try out.appendSlice(allocator, paint.reset);
    }
    try out.append(allocator, '\n');
}

fn isHunkHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "@@");
}

fn isFileHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "diff ") or
        std.mem.startsWith(u8, line, "+++") or
        std.mem.startsWith(u8, line, "---") or
        std.mem.startsWith(u8, line, "index ");
}

/// Collapsed by default. Prefer `renderFocus` when highlighting a hunk.
pub fn render(allocator: std.mem.Allocator, cols: u16, src: []const u8, expanded: bool) ![]u8 {
    return renderFocus(allocator, cols, src, expanded, null);
}

/// `focus_hunk` highlights that @@ (0-based among hunks), or null for none.
pub fn renderFocus(allocator: std.mem.Allocator, cols: u16, src: []const u8, expanded: bool, focus_hunk: ?usize) ![]u8 {
    const width: u16 = if (cols < 8) 80 else cols;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (expanded) {
        var it = std.mem.splitScalar(u8, src, '\n');
        var any = false;
        var hunk_i: usize = 0;
        while (it.next()) |line| {
            if (line.len == 0 and !any) continue;
            any = true;
            if (isHunkHeader(line)) {
                if (focus_hunk) |f| {
                    if (hunk_i == f) {
                        try out.appendSlice(allocator, paint.bold);
                        try out.appendSlice(allocator, paint.accent);
                        try appendPadded(&out, allocator, line, width);
                        try out.appendSlice(allocator, paint.reset);
                        try out.append(allocator, '\n');
                        hunk_i += 1;
                        continue;
                    }
                }
                hunk_i += 1;
            }
            try paintLine(&out, allocator, line, width);
        }
        return out.toOwnedSlice(allocator);
    }

    var shown: usize = 0;
    var total: usize = 0;
    var hunk_body: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and total == 0) continue;
        total += 1;
        const header = isHunkHeader(line) or isFileHeader(line);
        if (isHunkHeader(line)) hunk_body = 0;
        if (!header) {
            if (hunk_body >= hunk_preview) continue;
            hunk_body += 1;
        }
        if (shown >= collapsed_cap) continue;
        try paintLine(&out, allocator, line, width);
        shown += 1;
    }
    if (total > shown) {
        var buf: [160]u8 = undefined;
        const more = std.fmt.bufPrint(
            &buf,
            "{s}… {d} more lines · press e to see everything · n/p jumps to the next change{s}\n",
            .{ paint.dim, total - shown, paint.reset },
        ) catch "…\n";
        try out.appendSlice(allocator, more);
    }
    return out.toOwnedSlice(allocator);
}

pub fn hunkCount(src: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (isHunkHeader(line)) n += 1;
    }
    return n;
}

pub fn lineCount(src: []const u8) usize {
    if (src.len == 0) return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and n == 0) continue;
        n += 1;
    }
    return n;
}

pub fn needsExpand(src: []const u8) bool {
    return lineCount(src) > collapsed_cap;
}

test "collapsed caps and hints" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,20 +1,20 @@\n");
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try body.print(std.testing.allocator, "+line {d}\n", .{i});
    }
    const s = try render(std.testing.allocator, 80, body.items, false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "more") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "press e") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "everything") != null);
}

test "expanded paints all adds" {
    const src = "@@ -1 +1 @@\n-old\n+new\n";
    const s = try render(std.testing.allocator, 40, src, true);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "+new") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "more") == null);
}
