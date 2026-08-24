//! Display-cell arithmetic: how wide a rune is, where a cell lands in a byte
//! string, and where a line has to break.
//!
//! Everything here is pure and allocation-free. It is separate from painting
//! because the two share nothing but these answers, and separate from input
//! decoding because that shares nothing at all.

const std = @import("std");

const wide_ranges = [_][2]u21{
    .{ 0x1100, 0x115F },
    .{ 0x2329, 0x232A },
    .{ 0x2E80, 0x303E },
    .{ 0x3040, 0xA4CF },
    .{ 0xAC00, 0xD7A3 },
    .{ 0xF900, 0xFAFF },
    .{ 0xFE10, 0xFE19 },
    .{ 0xFE30, 0xFE6F },
    .{ 0xFF00, 0xFF60 },
    .{ 0xFFE0, 0xFFE6 },
    .{ 0x1F300, 0x1FAFF },
};

pub fn runeWidth(cp: u21) u16 {
    if (cp == 0 or cp < 0x20 or cp == 0x7F) return 0;
    if (cp >= 0x0300 and cp <= 0x036F) return 0;
    for (wide_ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return 2;
    }
    return 1;
}

pub fn utf8LenAt(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    return std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
}

pub fn runeAt(s: []const u8, i: usize) u21 {
    const n = utf8LenAt(s, i);
    if (n == 0 or i + n > s.len) return s[i];
    return std.unicode.utf8Decode(s[i..][0..n]) catch s[i];
}

/// Byte index just past the escape sequence at `i`, so measurement can
/// skip SGR without counting it as content.
pub fn skipEsc(s: []const u8, i: usize) usize {
    if (i >= s.len or s[i] != 0x1b) return i;
    var n = i + 1;
    if (n >= s.len) return s.len;
    if (s[n] == ']') {
        n += 1;
        while (n < s.len) : (n += 1) {
            if (s[n] == 0x07) return n + 1;
            if (s[n] == 0x1b and n + 1 < s.len and s[n + 1] == '\\') return n + 2;
        }
        return s.len;
    }
    if (s[n] != '[') return n + 1;
    n += 1;
    while (n < s.len and (s[n] < 0x40 or s[n] > 0x7E)) n += 1;
    if (n < s.len) n += 1;
    return n;
}

pub fn cellsTo(s: []const u8) u16 {
    var col: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEsc(s, i);
            continue;
        }
        if (s[i] == '\n' or s[i] == '\r') {
            col += 1;
            i += 1;
            continue;
        }
        const n = utf8LenAt(s, i);
        col += runeWidth(runeAt(s, i));
        i += n;
    }
    return @intCast(@min(col, std.math.maxInt(u16)));
}

pub fn indexAtCell(s: []const u8, cell: u16) usize {
    var col: u16 = 0;
    var i: usize = 0;
    while (i < s.len and col < cell) {
        if (s[i] == 0x1b) {
            i = skipEsc(s, i);
            continue;
        }
        const n = utf8LenAt(s, i);
        const w = if (s[i] == '\n' or s[i] == '\r') @as(u16, 1) else runeWidth(runeAt(s, i));
        if (w != 0 and col + w > cell) break;
        i += n;
        col += w;
    }
    return i;
}

pub fn utf8Prev(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var n = i - 1;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return n;
}

pub fn utf8Next(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var n = i + 1;
    while (n < s.len and s[n] & 0xC0 == 0x80) n += 1;
    return n;
}

pub fn wordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Breaks one line into rows of at most `cols` cells, without allocating.
///
/// An iterator rather than a function taking an out-list: the two callers want
/// different things (one records offsets, one counts rows), and neither should
/// have to own a buffer to ask.
pub const Fold = struct {
    line: []const u8,
    cols: u16,
    at: usize = 0,
    done: bool = false,

    pub const Piece = struct { off: usize, len: usize };

    pub fn init(line: []const u8, cols: u16) Fold {
        return .{ .line = line, .cols = cols };
    }

    pub fn next(self: *Fold) ?Piece {
        if (self.done) return null;
        // An empty line is still a row; that is how blank lines survive.
        if (self.line.len == 0 or self.cols == 0) {
            self.done = true;
            return .{ .off = 0, .len = self.line.len };
        }
        if (self.at >= self.line.len) {
            self.done = true;
            return null;
        }
        const start = self.at;
        var col: u16 = 0;
        var i = self.at;
        while (i < self.line.len) {
            if (self.line[i] == 0x1b) {
                i = skipEsc(self.line, i);
                continue;
            }
            const n = utf8LenAt(self.line, i);
            const w = runeWidth(runeAt(self.line, i));
            if (w != 0 and col + w > self.cols and col > 0) break;
            i += n;
            col += w;
        }
        self.at = i;
        if (i >= self.line.len) self.done = true;
        return .{ .off = start, .len = i - start };
    }
};

test "cellsTo ignores SGR and counts wide runes" {
    try std.testing.expectEqual(@as(u16, 3), cellsTo("abc"));
    try std.testing.expectEqual(@as(u16, 3), cellsTo("\x1b[1mabc\x1b[0m"));
    try std.testing.expectEqual(@as(u16, 2), cellsTo("\u{4e16}"));
    try std.testing.expectEqual(@as(u16, 3), cellsTo("\x1b]0;title\x07abc"));
}

test "Fold breaks on cells, not bytes" {
    var it = Fold.init("\u{4e16}\u{4e16}\u{4e16}", 4);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "Fold keeps an empty line as one row" {
    var it = Fold.init("", 10);
    const first = it.next().?;
    try std.testing.expectEqual(@as(usize, 0), first.len);
    try std.testing.expect(it.next() == null);
}

test "Fold pieces tile the line exactly" {
    const line = "the quick brown fox jumps over the lazy dog";
    var it = Fold.init(line, 7);
    var at: usize = 0;
    while (it.next()) |p| {
        try std.testing.expectEqual(at, p.off);
        at += p.len;
    }
    try std.testing.expectEqual(line.len, at);
}
