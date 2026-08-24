//! Composer state: the line being typed, its history, and paste assembly.
//!
//! Pure state plus an allocator. No terminal and no escape sequences, which is
//! what lets the editing rules be tested without a pty.

const std = @import("std");
const Io = std.Io;

const width = @import("width.zig");

const log = std.log.scoped(.draft);

const utf8Prev = width.utf8Prev;
const utf8Next = width.utf8Next;
const wordByte = width.wordByte;

/// A paste is a prompt, not a file. Named so a hit is fixable.
pub const max_paste: usize = 256 * 1024;

pub const history_cap: usize = 200;

/// How long a two-press confirmation stays armed. Long enough to be deliberate,
/// short enough that a stray key does not stay dangerous.
pub const arm_quit_ms: i64 = 1000;
pub const arm_esc_ms: i64 = 800;

pub const ArmKind = enum { none, quit, new_session, rewind, clear };

pub const Arm = struct {
    kind: ArmKind = .none,
    at_ms: i64 = 0,

    pub fn confirm(self: *Arm, kind: ArmKind, ttl_ms: i64, now_ms: i64) bool {
        if (self.kind == kind and now_ms - self.at_ms >= 0 and now_ms - self.at_ms <= ttl_ms) {
            self.* = .{};
            return true;
        }
        self.kind = kind;
        self.at_ms = now_ms;
        return false;
    }

    pub fn clear(self: *Arm) void {
        self.* = .{};
    }

    /// Whether the window to confirm has passed.
    ///
    /// `confirm` already refuses a late second press, but the hint it puts up
    /// was drawn from `kind` alone and so outlived the window it describes --
    /// "esc again to rewind" stayed on screen long after esc had stopped
    /// meaning that.
    pub fn expired(self: Arm, ttl_ms: i64, now_ms: i64) bool {
        if (self.kind == .none) return false;
        const since = now_ms - self.at_ms;
        return since < 0 or since > ttl_ms;
    }

    /// The window for this kind: quit and new-session are destructive and get
    /// longer, esc is a key you press often and gets less.
    pub fn ttl(self: Arm) i64 {
        return switch (self.kind) {
            .none => 0,
            .quit, .new_session => arm_quit_ms,
            .rewind, .clear => arm_esc_ms,
        };
    }

    pub fn note(self: Arm, now_ms: i64) []const u8 {
        if (self.expired(self.ttl(), now_ms)) return "";
        return switch (self.kind) {
            .none => "",
            .quit => "ctrl-q again to quit",
            .new_session => "ctrl-n again for a new session",
            .rewind => "esc again to rewind",
            .clear => "esc again to clear",
        };
    }
};

pub const History = struct {
    items: std.ArrayList([]u8) = .empty,
    pos: usize = 0,
    live: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.items.items) |s| allocator.free(s);
        self.items.deinit(allocator);
        self.live.deinit(allocator);
    }

    pub fn remember(self: *History, allocator: std.mem.Allocator, line: []const u8) !void {
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], t)) {
            self.pos = 0;
            return;
        }
        try self.items.append(allocator, try allocator.dupe(u8, t));
        if (self.items.items.len > history_cap) {
            allocator.free(self.items.orderedRemove(0));
        }
        self.pos = 0;
    }

    pub fn older(self: *History, allocator: std.mem.Allocator, current: []const u8) !?[]const u8 {
        if (self.items.items.len == 0) return null;
        if (self.pos == 0) {
            self.live.clearRetainingCapacity();
            try self.live.appendSlice(allocator, current);
        }
        if (self.pos >= self.items.items.len) return self.items.items[0];
        self.pos += 1;
        return self.items.items[self.items.items.len - self.pos];
    }

    pub fn newer(self: *History, current: []const u8) ?[]const u8 {
        _ = current;
        if (self.pos == 0) return null;
        self.pos -= 1;
        if (self.pos == 0) return self.live.items;
        return self.items.items[self.items.items.len - self.pos];
    }
};

/// A trailing backslash means "newline, not send".
///
/// Shift+Enter and Alt+Enter do the same thing, but neither survives every
/// terminal: some send a bare CR for both. A backslash is typed, so it works
/// anywhere a keyboard does.
pub fn endsWithContinuation(text: []const u8) bool {
    if (text.len == 0 or text[text.len - 1] != '\\') return false;
    // An escaped backslash is a literal one the user typed on purpose.
    var back: usize = 0;
    var i = text.len;
    while (i > 0 and text[i - 1] == '\\') : (i -= 1) back += 1;
    return back % 2 == 1;
}

pub const Draft = struct {
    bytes: std.ArrayList(u8) = .empty,
    cur: usize = 0,
    yank_buf: [1024]u8 = undefined,
    yank_len: usize = 0,
    snap: std.ArrayList(u8) = .empty,
    snap_cur: usize = 0,

    pub fn deinit(self: *Draft, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.snap.deinit(allocator);
    }

    pub fn clear(self: *Draft) void {
        self.bytes.clearRetainingCapacity();
        self.cur = 0;
    }

    pub fn items(self: *const Draft) []const u8 {
        return self.bytes.items;
    }

    fn snapshot(self: *Draft, allocator: std.mem.Allocator) void {
        self.snap.clearRetainingCapacity();
        self.snap.appendSlice(allocator, self.bytes.items) catch return;
        self.snap_cur = self.cur;
    }

    fn saveKill(self: *Draft, s: []const u8) void {
        const n = @min(s.len, self.yank_buf.len);
        @memcpy(self.yank_buf[0..n], s[0..n]);
        self.yank_len = n;
    }

    fn deleteRange(self: *Draft, from: usize, to: usize) void {
        if (to <= from) return;
        const n = to - from;
        var i: usize = from;
        while (i + n < self.bytes.items.len) : (i += 1) {
            self.bytes.items[i] = self.bytes.items[i + n];
        }
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len - n);
        self.cur = from;
    }

    pub fn insert(self: *Draft, allocator: std.mem.Allocator, b: u8) !void {
        if (b < 0x20 and b != '\n' and b != '\t') return;
        try self.bytes.insert(allocator, self.cur, b);
        self.cur += 1;
    }

    pub fn insertSlice(self: *Draft, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(allocator);
        for (bytes) |b| {
            if (b < 0x20 and b != '\n' and b != '\t') continue;
            try clean.append(allocator, b);
        }
        if (clean.items.len == 0) return;
        try self.bytes.insertSlice(allocator, self.cur, clean.items);
        self.cur += clean.items.len;
    }

    /// `s` may point into our own buffer -- completing `@mention` keeps a prefix
    /// of the draft. Clearing first and copying back read from memory the list
    /// had already released, which produced garbage. Move, then shrink.
    pub fn replace(self: *Draft, allocator: std.mem.Allocator, s: []const u8) !void {
        const buf = self.bytes.items;
        if (s.len != 0 and buf.len != 0 and
            @intFromPtr(s.ptr) >= @intFromPtr(buf.ptr) and
            @intFromPtr(s.ptr) + s.len <= @intFromPtr(buf.ptr) + buf.len)
        {
            const off = @intFromPtr(s.ptr) - @intFromPtr(buf.ptr);
            std.mem.copyForwards(u8, buf[0..s.len], buf[off..][0..s.len]);
            self.bytes.shrinkRetainingCapacity(s.len);
            self.cur = s.len;
            return;
        }
        self.clear();
        try self.insertSlice(allocator, s);
    }

    pub fn yank(self: *Draft, allocator: std.mem.Allocator) !void {
        if (self.yank_len == 0) return;
        self.snapshot(allocator);
        try self.insertSlice(allocator, self.yank_buf[0..self.yank_len]);
    }

    pub fn undo(self: *Draft) void {
        const tmp = self.bytes;
        const tmp_cur = self.cur;
        self.bytes = self.snap;
        self.cur = @min(self.snap_cur, self.bytes.items.len);
        self.snap = tmp;
        self.snap_cur = tmp_cur;
    }

    pub fn backspace(self: *Draft) void {
        const from = utf8Prev(self.bytes.items, self.cur);
        if (from == self.cur) return;
        self.deleteRange(from, self.cur);
    }

    pub fn delete(self: *Draft) void {
        const to = utf8Next(self.bytes.items, self.cur);
        if (to == self.cur) return;
        self.deleteRange(self.cur, to);
    }

    pub fn left(self: *Draft) void {
        self.cur = utf8Prev(self.bytes.items, self.cur);
    }

    pub fn right(self: *Draft) void {
        self.cur = utf8Next(self.bytes.items, self.cur);
    }

    pub fn home(self: *Draft) void {
        self.cur = 0;
    }

    pub fn end(self: *Draft) void {
        self.cur = self.bytes.items.len;
    }

    pub fn wordLeft(self: *Draft) void {
        var i = self.cur;
        while (i > 0 and !wordByte(self.bytes.items[i - 1])) i -= 1;
        while (i > 0 and wordByte(self.bytes.items[i - 1])) i -= 1;
        self.cur = i;
    }

    pub fn wordRight(self: *Draft) void {
        var i = self.cur;
        const s = self.bytes.items;
        while (i < s.len and !wordByte(s[i])) i += 1;
        while (i < s.len and wordByte(s[i])) i += 1;
        self.cur = i;
    }

    pub fn killLine(self: *Draft, allocator: std.mem.Allocator) void {
        if (self.cur == self.bytes.items.len) return;
        self.snapshot(allocator);
        self.saveKill(self.bytes.items[self.cur..]);
        self.bytes.shrinkRetainingCapacity(self.cur);
    }

    pub fn killToStart(self: *Draft, allocator: std.mem.Allocator) void {
        if (self.cur == 0) return;
        self.snapshot(allocator);
        self.saveKill(self.bytes.items[0..self.cur]);
        const rest = self.bytes.items.len - self.cur;
        var i: usize = 0;
        while (i < rest) : (i += 1) {
            self.bytes.items[i] = self.bytes.items[self.cur + i];
        }
        self.bytes.shrinkRetainingCapacity(rest);
        self.cur = 0;
    }

    pub fn killWord(self: *Draft, allocator: std.mem.Allocator) void {
        var i = self.cur;
        while (i > 0 and self.bytes.items[i - 1] == ' ') i -= 1;
        while (i > 0 and self.bytes.items[i - 1] != ' ') i -= 1;
        if (i == self.cur) return;
        self.snapshot(allocator);
        self.saveKill(self.bytes.items[i..self.cur]);
        self.deleteRange(i, self.cur);
    }

    pub fn killWordRight(self: *Draft, allocator: std.mem.Allocator) void {
        const from = self.cur;
        const mark = self.cur;
        self.wordRight();
        const to = self.cur;
        self.cur = mark;
        if (to == from) return;
        self.snapshot(allocator);
        self.saveKill(self.bytes.items[from..to]);
        self.deleteRange(from, to);
    }

    pub fn setCur(self: *Draft, at: usize) void {
        self.cur = @min(at, self.bytes.items.len);
        while (self.cur > 0 and self.bytes.items[self.cur] & 0xC0 == 0x80) self.cur -= 1;
    }

    pub fn redo(self: *Draft) void {
        self.undo();
    }

    /// Yank the word under the caret (double-click analog).
    pub fn yankWord(self: *Draft, allocator: std.mem.Allocator) void {
        _ = allocator;
        var from = self.cur;
        while (from > 0 and wordByte(self.bytes.items[from - 1])) from -= 1;
        var to = self.cur;
        while (to < self.bytes.items.len and wordByte(self.bytes.items[to])) to += 1;
        if (to <= from) return;
        self.saveKill(self.bytes.items[from..to]);
        self.cur = to;
    }
};

pub const Utf8Hold = struct {
    buf: [4]u8 = undefined,
    len: usize = 0,

    pub fn push(self: *Utf8Hold, allocator: std.mem.Allocator, draft: *Draft, b: u8) !void {
        if (self.len == 0) {
            const need = std.unicode.utf8ByteSequenceLength(b) catch {
                try draft.insert(allocator, b);
                return;
            };
            if (need == 1) {
                try draft.insert(allocator, b);
                return;
            }
            self.buf[0] = b;
            self.len = 1;
            return;
        }
        self.buf[self.len] = b;
        self.len += 1;
        const need = std.unicode.utf8ByteSequenceLength(self.buf[0]) catch 1;
        if (self.len >= need) {
            try draft.insertSlice(allocator, self.buf[0..self.len]);
            self.len = 0;
        }
    }

    pub fn flush(self: *Utf8Hold, allocator: std.mem.Allocator, draft: *Draft) !void {
        if (self.len == 0) return;
        try draft.insertSlice(allocator, self.buf[0..self.len]);
        self.len = 0;
    }
};

pub fn takePaste(reader: *Io.Reader, allocator: std.mem.Allocator, draft: *Draft) !void {
    const needle = "\x1b[201~";
    var match: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var skip_lf = false;
    var truncated = false;
    while (true) {
        const c = reader.takeByte() catch break;
        if (match > 0) {
            if (c == needle[match]) {
                match += 1;
                if (match == needle.len) break;
                continue;
            }
            if (!truncated and out.items.len + match <= max_paste)
                try out.appendSlice(allocator, needle[0..match]);
            match = 0;
        }
        if (c == needle[0]) {
            match = 1;
            continue;
        }
        if (skip_lf) {
            skip_lf = false;
            if (c == '\n') continue;
        }
        if (out.items.len >= max_paste) {
            truncated = true;
            continue;
        }
        if (c == 0) continue;
        if (c == '\r') {
            try out.append(allocator, '\n');
            skip_lf = true;
            continue;
        }
        try out.append(allocator, c);
    }
    try draft.insertSlice(allocator, out.items);
    if (truncated) {
        log.warn("paste truncated: max_paste={d}, kept {d}", .{ max_paste, out.items.len });
    }
}

pub fn popUtf8(buf: *std.ArrayList(u8)) void {
    if (buf.items.len == 0) return;
    var n = buf.items.len - 1;
    while (n > 0 and buf.items[n] & 0xC0 == 0x80) n -= 1;
    buf.shrinkRetainingCapacity(n);
}

test "draft insert and left right backspace" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insert(std.testing.allocator, 'a');
    try d.insert(std.testing.allocator, 'c');
    d.left();
    try d.insert(std.testing.allocator, 'b');
    try std.testing.expectEqualStrings("abc", d.items());
    d.end();
    d.backspace();
    try std.testing.expectEqualStrings("ab", d.items());
    d.home();
    d.delete();
    try std.testing.expectEqualStrings("b", d.items());
}
test "draft insertSlice at caret" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insertSlice(std.testing.allocator, "ac");
    d.left();
    try d.insertSlice(std.testing.allocator, "b");
    try std.testing.expectEqualStrings("abc", d.items());
}
test "utf8 hold waits for a complete rune" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    var hold = Utf8Hold{};
    try hold.push(std.testing.allocator, &d, 0xE3);
    try std.testing.expectEqual(@as(usize, 0), d.items().len);
    try hold.push(std.testing.allocator, &d, 0x81);
    try hold.push(std.testing.allocator, &d, 0x82);
    try std.testing.expectEqualStrings("あ", d.items());
}
test "paste reads until 201 and keeps newlines" {
    const payload = "hello\r\nworld\x1b[201~";
    var reader = Io.Reader.fixed(payload);
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try takePaste(&reader, std.testing.allocator, &d);
    try std.testing.expectEqualStrings("hello\nworld", d.items());
}
test "draft drops control bytes" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insert(std.testing.allocator, 'C');
    try d.insert(std.testing.allocator, 0x1b);
    try d.insertSlice(std.testing.allocator, "\x1b[Mhi");
    try std.testing.expectEqualStrings("C[Mhi", d.items());
}
test "Arm confirm requires a second press inside the ttl" {
    var a = Arm{};
    try std.testing.expect(!a.confirm(.quit, arm_quit_ms, 1000));
    try std.testing.expectEqualStrings("ctrl-q again to quit", a.note(1000));
    try std.testing.expect(!a.confirm(.quit, arm_quit_ms, 1000 + arm_quit_ms + 1));
    try std.testing.expect(a.confirm(.quit, arm_quit_ms, 1000 + arm_quit_ms + 1 + 10));
    try std.testing.expectEqual(ArmKind.none, a.kind);
}

test "the hint goes when the window it describes does" {
    var a = Arm{};
    _ = a.confirm(.rewind, arm_esc_ms, 1000);
    try std.testing.expectEqualStrings("esc again to rewind", a.note(1000));
    try std.testing.expectEqualStrings("esc again to rewind", a.note(1000 + arm_esc_ms));
    // Past the window esc no longer rewinds, so it must stop saying it does.
    try std.testing.expectEqualStrings("", a.note(1000 + arm_esc_ms + 1));
    try std.testing.expect(a.expired(a.ttl(), 1000 + arm_esc_ms + 1));
    // Each kind carries its own window.
    try std.testing.expectEqual(arm_esc_ms, a.ttl());
    _ = a.confirm(.quit, arm_quit_ms, 1000);
    try std.testing.expectEqual(arm_quit_ms, a.ttl());
}
test "double-click yanks the word under the caret" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insertSlice(std.testing.allocator, "hello world");
    d.setCur(1);
    d.yankWord(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), d.cur);
    try d.replace(std.testing.allocator, "x");
    try d.yank(std.testing.allocator);
    try std.testing.expectEqualStrings("xhello", d.items());
}
test "history walks older then live" {
    var h = History{};
    defer h.deinit(std.testing.allocator);
    try h.remember(std.testing.allocator, "one");
    try h.remember(std.testing.allocator, "two");
    const a = (try h.older(std.testing.allocator, "now")).?;
    try std.testing.expectEqualStrings("two", a);
    const b = (try h.older(std.testing.allocator, "now")).?;
    try std.testing.expectEqualStrings("one", b);
    const c = h.newer("now").?;
    try std.testing.expectEqualStrings("two", c);
    const d = h.newer("now").?;
    try std.testing.expectEqualStrings("now", d);
}
test "kill yank undo" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insertSlice(std.testing.allocator, "hello world");
    d.killToStart(std.testing.allocator);
    try std.testing.expectEqualStrings("", d.items());
    try d.yank(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", d.items());
    d.undo();
    try std.testing.expectEqualStrings("", d.items());
}
test "word motion skips punctuation" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insertSlice(std.testing.allocator, "aa  bb");
    d.wordLeft();
    try std.testing.expectEqual(@as(usize, 4), d.cur);
    d.home();
    d.wordRight();
    try std.testing.expectEqual(@as(usize, 2), d.cur);
}
test "history evicts the oldest past its cap" {
    var h = History{};
    defer h.deinit(std.testing.allocator);
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < history_cap + 5) : (i += 1) {
        try h.remember(std.testing.allocator, try std.fmt.bufPrint(&buf, "cmd {d}", .{i}));
    }
    try std.testing.expectEqual(history_cap, h.items.items.len);
    try std.testing.expectEqualStrings("cmd 5", h.items.items[0]);
}
test "replace survives a slice of the draft's own buffer" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insertSlice(std.testing.allocator, "look at @src/cli/tu");
    const items = d.items();
    // Exactly what completing a mention does: keep a prefix of ourselves.
    try d.replace(std.testing.allocator, items[0 .. items.len - "@src/cli/tu".len]);
    try std.testing.expectEqualStrings("look at ", d.items());
    try std.testing.expectEqual(@as(usize, 8), d.cur);
    try d.insertSlice(std.testing.allocator, "@src/cli/tui.zig");
    try std.testing.expectEqualStrings("look at @src/cli/tui.zig", d.items());
}
test "replace still takes a foreign buffer" {
    var d = Draft{};
    defer d.deinit(std.testing.allocator);
    try d.insertSlice(std.testing.allocator, "old text");
    try d.replace(std.testing.allocator, "recalled from history");
    try std.testing.expectEqualStrings("recalled from history", d.items());
    try std.testing.expectEqual("recalled from history".len, d.cur);
}

test "a trailing backslash asks for a newline" {
    try std.testing.expect(endsWithContinuation("write a poem \\"));
    try std.testing.expect(!endsWithContinuation("write a poem"));
    try std.testing.expect(!endsWithContinuation(""));
    // An escaped backslash is a literal the user meant to type.
    try std.testing.expect(!endsWithContinuation("path C:\\\\"));
    try std.testing.expect(endsWithContinuation("path C:\\\\\\"));
}
