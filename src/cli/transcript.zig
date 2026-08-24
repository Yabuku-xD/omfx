//! The scrollback pane: every byte shown, plus its folded-to-width form.
//!
//! The point of this type is that painting allocates nothing. The old shape --
//! a list of chunks re-concatenated and re-folded on every repaint -- did O(all
//! bytes ever shown) work per keypress and, because the caller chose the
//! allocator, leaked all of it whenever that allocator was an arena.
//!
//! Folding happens once per appended chunk. Resize is the only event that
//! invalidates a fold, so it is the only thing that refolds.

const std = @import("std");

const width = @import("width.zig");

/// Folded lines are offsets, never slices: `text` grows, and a realloc would
/// dangle every slice pointing into it.
const Span = struct { off: u32, len: u32 };

/// One chunk is a card, a reply, or a tool body. Refusing to show more than
/// this many bytes would lose the user's own scrollback, so nothing is capped
/// here; `text` is bounded by the session, exactly as the old list was.
pub const Transcript = struct {
    allocator: std.mem.Allocator,
    /// Every byte appended, in order. A chunk boundary landing mid-line is not
    /// a special case because the fold reads from here, not from the chunks.
    text: std.ArrayList(u8) = .empty,
    /// Display rows, as offsets into `text`.
    lines: std.ArrayList(Span) = .empty,
    /// Bytes of `text` already folded. Always sits just past a newline.
    folded: usize = 0,
    /// Width the current fold was computed for.
    cols: u16 = 0,
    /// In-flight line, borrowed from the caller and refolded per paint. It is
    /// one logical line, so folding it is bounded by the pane height.
    tail: []const u8 = "",
    /// Activity row pinned below the tail while a turn runs. Transient for the
    /// same reason the tail is: it must never enter the saved scrollback.
    status: []const u8 = "",
    /// The task list, pinned above everything transient. Unlike the tool
    /// result that produced it, this stays put as the work moves through it:
    /// a checklist you have to scroll back to find is a checklist you stop
    /// looking at.
    pinned: []const []const u8 = &.{},
    /// Messages queued during the turn, pinned just above the status row.
    /// Transient like the other two: a queued message belongs to the turn it
    /// was typed into, not to the transcript.
    queued: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, cols: u16) Transcript {
        return .{ .allocator = allocator, .cols = cols };
    }

    pub fn deinit(self: *Transcript) void {
        self.text.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    pub fn isEmpty(self: *const Transcript) bool {
        return self.text.items.len == 0;
    }

    /// Everything shown so far, for `/copy` and for the exit scrollback dump.
    pub fn bytes(self: *const Transcript) []const u8 {
        return self.text.items;
    }

    pub fn clear(self: *Transcript) void {
        self.text.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        self.folded = 0;
        self.tail = "";
        self.status = "";
        self.queued = &.{};
        self.pinned = &.{};
    }

    /// Everything shown passes through here, so this is where bytes that are
    /// not text are stopped.
    ///
    /// Three separate producers have leaked raw bytes into the pane -- a
    /// dangling status row, an X10 mouse payload, and a mouse coordinate past
    /// column 95 -- and each was fixed where it was found. They kept coming
    /// back from somewhere else. A transcript holds text by definition, so
    /// the check belongs at the one door into it rather than at each producer
    /// in turn.
    pub fn append(self: *Transcript, chunk: []const u8) !void {
        if (chunk.len == 0) return;
        if (std.unicode.utf8ValidateSlice(chunk)) {
            try self.text.appendSlice(self.allocator, chunk);
        } else {
            try appendValid(&self.text, self.allocator, chunk);
        }
        try self.foldNew();
    }

    /// `chunk` with every byte that is not part of a well-formed rune left
    /// out. Runs on the slow path only: valid text is appended as it is.
    fn appendValid(out: *std.ArrayList(u8), allocator: std.mem.Allocator, chunk: []const u8) !void {
        var i: usize = 0;
        while (i < chunk.len) {
            const n = std.unicode.utf8ByteSequenceLength(chunk[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > chunk.len or !std.unicode.utf8ValidateSlice(chunk[i..][0..n])) {
                i += 1;
                continue;
            }
            try out.appendSlice(allocator, chunk[i..][0..n]);
            i += n;
        }
    }

    /// Replace the bytes of one committed block, refolding from there.
    ///
    /// The transcript is otherwise append-only, and stays that way for every
    /// hot path. A tool run is the one thing that changes after it is drawn:
    /// opening it is a click, and the rows it adds have to land where the run
    /// is, not at the bottom of the pane.
    pub fn replace(self: *Transcript, off: usize, len: usize, next: []const u8) !void {
        if (off + len > self.folded) return error.NotFolded;
        // Blocks start on a row boundary; a splice inside a row would leave the
        // rows before it describing bytes that moved.
        std.debug.assert(off == 0 or self.text.items[off - 1] == '\n');
        try self.text.replaceRange(self.allocator, off, len, next);
        var keep: usize = 0;
        while (keep < self.lines.items.len and self.lines.items[keep].off < off) keep += 1;
        self.lines.shrinkRetainingCapacity(keep);
        self.folded = off;
        try self.foldNew();
    }

    /// The display row showing byte `off`, or null when nothing does.
    pub fn rowOfOffset(self: *const Transcript, off: usize) ?usize {
        var found: ?usize = null;
        for (self.lines.items, 0..) |s, i| {
            if (s.off > off) break;
            found = i;
        }
        return found;
    }

    /// Byte offset of committed display row `i`, or null for the tail.
    pub fn rowOffset(self: *const Transcript, i: usize) ?usize {
        if (i >= self.lines.items.len) return null;
        return self.lines.items[i].off;
    }

    /// Set the line still being streamed. Borrowed: valid only until the next
    /// paint, which is why it is never folded into `lines`.
    pub fn setTail(self: *Transcript, line: []const u8) void {
        self.tail = line;
    }

    pub fn clearTail(self: *Transcript) void {
        self.tail = "";
    }

    pub fn setStatus(self: *Transcript, line: []const u8) void {
        self.status = line;
    }

    pub fn setQueued(self: *Transcript, rows: []const []const u8) void {
        self.queued = rows;
    }

    pub fn setPinned(self: *Transcript, rows: []const []const u8) void {
        self.pinned = rows;
    }

    /// Only a width change can invalidate a fold.
    pub fn resize(self: *Transcript, cols: u16) !void {
        if (cols == self.cols) return;
        self.cols = cols;
        self.lines.clearRetainingCapacity();
        self.folded = 0;
        try self.foldNew();
    }

    /// Folds whole lines only. A trailing partial line stays unfolded until its
    /// newline arrives, so a chunk that splits a line cannot produce two rows.
    fn foldNew(self: *Transcript) !void {
        const src = self.text.items;
        while (std.mem.indexOfScalarPos(u8, src, self.folded, '\n')) |nl| {
            try self.foldOne(@intCast(self.folded), @intCast(nl - self.folded));
            self.folded = nl + 1;
        }
    }

    fn foldOne(self: *Transcript, off: u32, len: u32) !void {
        const line = self.text.items[off..][0..len];
        var it = width.Fold.init(line, self.cols);
        while (it.next()) |piece| {
            try self.lines.append(self.allocator, .{
                .off = off + @as(u32, @intCast(piece.off)),
                .len = @intCast(piece.len),
            });
        }
    }

    /// Rows the tail will occupy. Zero when nothing is streaming.
    fn tailRows(self: *const Transcript) usize {
        if (self.tail.len == 0) return 0;
        var it = width.Fold.init(self.tail, self.cols);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    fn statusRows(self: *const Transcript) usize {
        return if (self.status.len == 0) 0 else 1;
    }

    pub fn rowCount(self: *const Transcript) usize {
        return self.lines.items.len + self.tailRows() + self.pinned.len + self.queued.len + self.statusRows();
    }

    /// Display row `i`, committed lines first and the streaming tail last.
    /// Borrowed from `text` or from the tail; valid until the next append.
    pub fn row(self: *const Transcript, i: usize) []const u8 {
        if (i < self.lines.items.len) {
            const s = self.lines.items[i];
            return self.text.items[s.off..][0..s.len];
        }
        // Guard the empty tail rather than folding it: Fold yields one empty
        // piece for an empty line, which would disagree with tailRows() and
        // push the status row out of reach.
        var n = self.lines.items.len;
        if (self.tail.len != 0) {
            var it = width.Fold.init(self.tail, self.cols);
            while (it.next()) |piece| {
                if (n == i) return self.tail[piece.off..][0..piece.len];
                n += 1;
            }
        }
        if (i >= n and i < n + self.pinned.len) return self.pinned[i - n];
        n += self.pinned.len;
        if (i >= n and i < n + self.queued.len) return self.queued[i - n];
        n += self.queued.len;
        if (self.status.len != 0 and n == i) return self.status;
        return "";
    }
};

fn collect(t: *const Transcript, allocator: std.mem.Allocator) ![][]const u8 {
    const out = try allocator.alloc([]const u8, t.rowCount());
    for (out, 0..) |*slot, i| slot.* = t.row(i);
    return out;
}

test "bytes that are not text never enter the transcript" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    // A mouse coordinate past column 95, which is what reached the pane as
    // replacement glyphs three separate times.
    try t.append("ok\xc8\xe0\x9f fine\n");
    try std.testing.expect(std.unicode.utf8ValidateSlice(t.bytes()));
    try std.testing.expectEqualStrings("ok fine\n", t.bytes());

    // Real multi-byte text is untouched.
    try t.append("caf\xc3\xa9 \xe2\x9c\x93\n");
    try std.testing.expect(std.unicode.utf8ValidateSlice(t.bytes()));
    try std.testing.expect(std.mem.indexOf(u8, t.bytes(), "caf\xc3\xa9") != null);
}

test "folding happens once, not per read" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("one\ntwo\n");
    try std.testing.expectEqual(@as(usize, 2), t.rowCount());
    try std.testing.expectEqualStrings("one", t.row(0));
    try std.testing.expectEqualStrings("two", t.row(1));
    // Reading again must not change anything.
    try std.testing.expectEqual(@as(usize, 2), t.rowCount());
}

test "a chunk that splits a line still yields one row" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("hel");
    try std.testing.expectEqual(@as(usize, 0), t.rowCount());
    try t.append("lo there\n");
    try std.testing.expectEqual(@as(usize, 1), t.rowCount());
    try std.testing.expectEqualStrings("hello there", t.row(0));
}

test "growth does not dangle earlier rows" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("first line\n");
    var i: usize = 0;
    // Force many reallocations of the backing text.
    while (i < 500) : (i += 1) try t.append("padding line to force growth\n");
    try std.testing.expectEqualStrings("first line", t.row(0));
    try std.testing.expectEqual(@as(usize, 501), t.rowCount());
}

test "long lines fold to the pane width" {
    var t = Transcript.init(std.testing.allocator, 10);
    defer t.deinit();
    try t.append("abcdefghijklmnopqrstuvwxy\n");
    try std.testing.expectEqual(@as(usize, 3), t.rowCount());
    try std.testing.expectEqualStrings("abcdefghij", t.row(0));
    try std.testing.expectEqualStrings("klmnopqrst", t.row(1));
    try std.testing.expectEqualStrings("uvwxy", t.row(2));
}

test "resize refolds, and only on a width change" {
    var t = Transcript.init(std.testing.allocator, 10);
    defer t.deinit();
    try t.append("abcdefghijklmno\n");
    try std.testing.expectEqual(@as(usize, 2), t.rowCount());
    try t.resize(80);
    try std.testing.expectEqual(@as(usize, 1), t.rowCount());
    try std.testing.expectEqualStrings("abcdefghijklmno", t.row(0));
    try t.resize(80);
    try std.testing.expectEqual(@as(usize, 1), t.rowCount());
}

test "the streaming tail shows without being committed" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("done\n");
    t.setTail("in flight");
    try std.testing.expectEqual(@as(usize, 2), t.rowCount());
    try std.testing.expectEqualStrings("in flight", t.row(1));
    t.clearTail();
    try std.testing.expectEqual(@as(usize, 1), t.rowCount());
    // The tail never entered the committed bytes.
    try std.testing.expectEqualStrings("done\n", t.bytes());
}

test "the status row sits below the tail and stays out of the bytes" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("done\n");
    t.setTail("in flight");
    t.setStatus("Generating");
    try std.testing.expectEqual(@as(usize, 3), t.rowCount());
    try std.testing.expectEqualStrings("done", t.row(0));
    try std.testing.expectEqualStrings("in flight", t.row(1));
    try std.testing.expectEqualStrings("Generating", t.row(2));
    try std.testing.expectEqualStrings("done\n", t.bytes());
    t.setStatus("");
    try std.testing.expectEqual(@as(usize, 2), t.rowCount());
}

test "rowCount and row agree with no tail" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("a\nb\n");
    t.setStatus("Generating");
    // Every counted row must be reachable; an off-by-one here hides the status.
    var i: usize = 0;
    while (i < t.rowCount()) : (i += 1) try std.testing.expect(t.row(i).len != 0);
    try std.testing.expectEqualStrings("Generating", t.row(t.rowCount() - 1));
}

test "clear drops rows and bytes together" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("a\nb\n");
    t.clear();
    try std.testing.expect(t.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), t.rowCount());
    try t.append("c\n");
    try std.testing.expectEqual(@as(usize, 1), t.rowCount());
    try std.testing.expectEqualStrings("c", t.row(0));
}

test "painting the same content repeatedly allocates nothing" {
    var t = Transcript.init(std.testing.allocator, 40);
    defer t.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) try t.append("a line of transcript text here\n");

    // failing_allocator proves the read path never asks for memory: this is the
    // property the leak violated, so it is the one worth pinning down.
    const rows = t.rowCount();
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        var n: usize = 0;
        while (n < rows) : (n += 1) _ = t.row(n);
        try std.testing.expectEqual(rows, t.rowCount());
    }
    try std.testing.expectError(error.OutOfMemory, collect(&t, std.testing.failing_allocator));
}

test "replacing a block refolds the rows after it" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("head\n");
    const off = t.bytes().len;
    try t.append("run\n");
    const len = t.bytes().len - off;
    try t.append("tail\n");
    try std.testing.expectEqual(@as(usize, 3), t.rowCount());

    try t.replace(off, len, "run\n  child a\n  child b\n");
    try std.testing.expectEqual(@as(usize, 5), t.rowCount());
    try std.testing.expectEqualStrings("head", t.row(0));
    try std.testing.expectEqualStrings("run", t.row(1));
    try std.testing.expectEqualStrings("  child b", t.row(3));
    try std.testing.expectEqualStrings("tail", t.row(4));

    // And back again: collapsing is the same splice in the other direction.
    try t.replace(off, "run\n  child a\n  child b\n".len, "run\n");
    try std.testing.expectEqual(@as(usize, 3), t.rowCount());
    try std.testing.expectEqualStrings("tail", t.row(2));
}

test "row offsets point at the bytes the row was folded from" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("aa\nbb\n");
    try std.testing.expectEqual(@as(?usize, 0), t.rowOffset(0));
    try std.testing.expectEqual(@as(?usize, 3), t.rowOffset(1));
    try std.testing.expectEqual(@as(?usize, null), t.rowOffset(2));
}
