const std = @import("std");

/// Receipt: a typed line is well under 200 bytes; 4 KB is a tripwire for a
/// paste, which is the only way one line fills.
pub const max_steer: usize = 4096;
/// Past this the user is not steering, they are writing the next session. The
/// oldest queued message is kept and further Enters are ignored.
pub const max_queued: usize = 8;

/// Bytes read in one non-blocking drain. A terminal delivers a whole escape
/// sequence in a single read, so this only has to hold the largest of those.
pub const cancel_drain_bytes: usize = 512;

/// Rows one mouse-wheel notch moves.
pub const wheel_step: i32 = 3;

pub const InputSession = struct {
    steer_buf: [max_steer]u8 = undefined,
    steer_len: usize = 0,
    queued: [max_queued][max_steer]u8 = undefined,
    queued_len: [max_queued]usize = @splat(0),
    queued_n: usize = 0,
    /// Spin lock, matching how the paint path guards its own two threads: the
    /// critical section is a memcpy of a few hundred bytes.
    steer_lock: std.atomic.Value(u32) = .init(0),

    /// Escape sequences arrive split across reads, so where one ended is state.
    ///
    /// `x10` counts out the three bytes that follow an `ESC [ M` mouse report.
    /// They are raw coordinates offset by 32, not part of the CSI, so ending the
    /// sequence at the `M` left them to land in the message as text -- and past
    /// column 95 they are not even valid UTF-8, which is what put replacement
    /// glyphs in the transcript.
    esc_state: enum { none, esc, seq, x10 } = .none,
    x10_left: u8 = 0,
    /// True once a `<` has been seen in this CSI: an SGR mouse report carries its
    /// coordinates as parameters, so nothing follows the final byte.
    esc_sgr: bool = false,

    /// Bytes still expected to finish the rune being read, and where it started.
    utf8_need: usize = 0,
    utf8_start: usize = 0,

    /// Incomplete SGR/CSI from the previous stdin read, prepended to the next.
    /// Mouse reports often arrive as `\x1b[<` then `64;col;rowM`; dropping the
    /// prefix left `64;col;rowM` to land in the composer as text nobody typed.
    key_hold: [64]u8 = undefined,
    key_hold_len: usize = 0,

    /// Hit box for the jump-to-bottom pill while a turn owns stdin (1-based cells).
    jump_active: std.atomic.Value(bool) = .init(false),
    jump_row: std.atomic.Value(u32) = .init(0),
    jump_col0: std.atomic.Value(u32) = .init(0),
    jump_col1: std.atomic.Value(u32) = .init(0),
    jump_pending: std.atomic.Value(bool) = .init(false),

    /// Left click in the transcript while a turn owns stdin. The live painter
    /// resolves it to a tool run and toggles expand, same as idle clickRun.
    run_click_row: std.atomic.Value(u32) = .init(0),
    run_click_col: std.atomic.Value(u32) = .init(0),

    /// Header context meter hit box (1-based cells) while a turn owns stdin.
    ctx_active: std.atomic.Value(bool) = .init(false),
    ctx_row: std.atomic.Value(u32) = .init(0),
    ctx_col0: std.atomic.Value(u32) = .init(0),
    ctx_col1: std.atomic.Value(u32) = .init(0),
    ctx_peek: std.atomic.Value(bool) = .init(false),

    /// Slash palette selection while typing `/…` mid-turn.
    slash_sel: std.atomic.Value(u32) = .init(0),
    slash_count: std.atomic.Value(u32) = .init(0),
    slash_tab: std.atomic.Value(bool) = .init(false),

    /// Deferred slash command to run when the turn ends (e.g. `/settings`).
    pending_cmd: [64]u8 = undefined,
    pending_cmd_len: std.atomic.Value(u32) = .init(0),

    fn steerLock(self: *InputSession) void {
        while (self.steer_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn steerUnlock(self: *InputSession) void {
        self.steer_lock.store(0, .release);
    }

    /// Caller holds the lock.
    fn commitLine(self: *InputSession) void {
        if (self.steer_len == 0) return;
        if (self.queued_n == max_queued) {
            self.steer_len = 0;
            return;
        }
        @memcpy(self.queued[self.queued_n][0..self.steer_len], self.steer_buf[0..self.steer_len]);
        self.queued_len[self.queued_n] = self.steer_len;
        self.queued_n += 1;
        self.steer_len = 0;
    }

    /// Whether `c` can be appended as text.
    ///
    /// The escape filters above catch the sequences omfx knows about, but a
    /// terminal can report the mouse in a shape nobody anticipated, and its
    /// coordinates are raw bytes: past column 95 they are not valid UTF-8, and
    /// they reached the transcript as replacement glyphs. A composer cannot hold
    /// invalid UTF-8 either way, so it is rejected at the door rather than
    /// guarded against one report shape at a time.
    ///
    /// Multi-byte text still goes through, including split across reads, because
    /// what is tracked is the rune in progress rather than one byte at a time.
    fn acceptRuneByte(self: *InputSession, c: u8) bool {
        const continuation = c & 0xc0 == 0x80;
        if (self.utf8_need != 0) {
            if (continuation) {
                self.utf8_need -= 1;
                return true;
            }
            // The rune never finished, so what was written is not text. Drop it
            // and judge this byte on its own.
            self.steer_len = self.utf8_start;
            self.utf8_need = 0;
        }
        if (c < 0x80) return true;
        if (continuation) return false;
        const want: usize = if (c & 0xe0 == 0xc0)
            1
        else if (c & 0xf0 == 0xe0)
            2
        else if (c & 0xf8 == 0xf0)
            3
        else
            return false;
        self.utf8_need = want;
        self.utf8_start = self.steer_len;
        return true;
    }

    fn steerPush(self: *InputSession, bytes: []const u8) void {
        self.steerLock();
        defer self.steerUnlock();
        for (bytes) |c| {
            // An arrow key is ESC [ B. Dropping only the ESC leaves "[B" in the
            // message, which is how a keypress became text nobody typed.
            switch (self.esc_state) {
                .none => {},
                .esc => {
                    self.esc_state = if (c == '[' or c == 'O') .seq else .none;
                    continue;
                },
                .seq => {
                    if (c == '<') self.esc_sgr = true;
                    if (c >= 0x40 and c <= 0x7e) {
                        if ((c == 'M' or c == 'm') and !self.esc_sgr) {
                            self.esc_state = .x10;
                            self.x10_left = 3;
                        } else {
                            self.esc_state = .none;
                        }
                    }
                    continue;
                },
                .x10 => {
                    self.x10_left -= 1;
                    if (self.x10_left == 0) self.esc_state = .none;
                    continue;
                },
            }
            if (c == 0x1b) {
                self.esc_state = .esc;
                self.esc_sgr = false;
                continue;
            }
            if (c == '\r' or c == '\n') {
                // Bare `/cmd` mid-turn: defer as a slash command, do not queue as
                // a user message (Claude keeps slash UX live while generating).
                if (self.slashTypingLocked() and self.steer_len > 1) {
                    self.setPendingCmdLocked(self.steer_buf[0..self.steer_len]);
                    self.steer_len = 0;
                    continue;
                }
                self.commitLine();
                continue;
            }
            if (c == 0x09) {
                // Tab: live paint path completes via slash_sel; mark request.
                if (self.slashTypingLocked()) {
                    // Selection stays; live.paintTty applies completeSlashName.
                    self.slash_tab.store(true, .release);
                }
                continue;
            }
            if (c == 0x7f or c == 0x08) {
                if (self.steer_len != 0) self.steer_len -= 1;
                continue;
            }
            if (c < 0x20) continue;
            if (self.steer_len == self.steer_buf.len) continue;
            if (!self.acceptRuneByte(c)) continue;
            self.steer_buf[self.steer_len] = c;
            self.steer_len += 1;
        }
    }

    pub const Queued = struct {
        rows: [max_queued][]const u8,
        n: usize,
        /// The line still being typed, which the composer draws.
        typing: []const u8,

        pub fn slice(self: *const Queued) []const []const u8 {
            return self.rows[0..self.n];
        }
    };

    pub const Steer = struct {
        text: []const u8,
        /// Enter was pressed: the caller sends rather than parks it in the composer.
        ready: bool,
    };

    pub fn peekSteer(self: *InputSession) Queued {
        self.steerLock();
        defer self.steerUnlock();
        var out = Queued{ .rows = undefined, .n = self.queued_n, .typing = self.steer_buf[0..self.steer_len] };
        for (0..self.queued_n) |i| out.rows[i] = self.queued[i][0..self.queued_len[i]];
        return out;
    }

    pub fn peekSteerCopy(self: *InputSession, typing_buf: []u8) Queued {
        self.steerLock();
        defer self.steerUnlock();
        const n = @min(self.steer_len, typing_buf.len);
        @memcpy(typing_buf[0..n], self.steer_buf[0..n]);
        var out = Queued{ .rows = undefined, .n = self.queued_n, .typing = typing_buf[0..n] };
        for (0..self.queued_n) |i| out.rows[i] = self.queued[i][0..self.queued_len[i]];
        return out;
    }

    pub fn takeSteer(self: *InputSession, out: []u8) Steer {
        self.steerLock();
        defer self.steerUnlock();
        var w: usize = 0;
        var msgs: usize = 0;
        for (0..self.queued_n) |i| {
            const n = @min(self.queued_len[i], out.len - w);
            if (n == 0) break;
            if (w != 0) {
                if (w == out.len) break;
                out[w] = '\n';
                w += 1;
            }
            @memcpy(out[w..][0..n], self.queued[i][0..n]);
            w += n;
            msgs += 1;
        }
        const tail = @min(self.steer_len, out.len - w);
        if (tail != 0) {
            if (w != 0 and w < out.len) {
                out[w] = '\n';
                w += 1;
            }
            @memcpy(out[w..][0..@min(tail, out.len - w)], self.steer_buf[0..@min(tail, out.len - w)]);
            w += @min(tail, out.len - w);
        }
        self.steer_len = 0;
        self.queued_n = 0;
        // Only a committed line asks to be sent; an unfinished one parks in the
        // composer for the user to finish.
        return .{ .text = out[0..w], .ready = msgs != 0 and tail == 0 };
    }

    pub fn pushSteerForTest(self: *InputSession, bytes: []const u8) void {
        self.steerPush(bytes);
    }

    pub fn dropSteer(self: *InputSession) void {
        self.steerLock();
        defer self.steerUnlock();
        self.steer_len = 0;
        self.queued_n = 0;
        self.esc_state = .none;
        self.esc_sgr = false;
        self.x10_left = 0;
        self.utf8_need = 0;
        self.utf8_start = 0;
        self.key_hold_len = 0;
        self.ctx_peek.store(false, .release);
        self.pending_cmd_len.store(0, .release);
        self.slash_tab.store(false, .release);
    }

    pub fn setJumpHit(self: *InputSession, active: bool, row: u16, col0: u16, col1: u16) void {
        self.jump_active.store(active, .release);
        self.jump_row.store(row, .release);
        self.jump_col0.store(col0, .release);
        self.jump_col1.store(col1, .release);
        if (!active) self.jump_pending.store(false, .release);
    }

    pub fn takeJumpToBottom(self: *InputSession) bool {
        return self.jump_pending.swap(false, .acq_rel);
    }

    pub fn takeRunClick(self: *InputSession) ?struct { row: u16, col: u16 } {
        const row = self.run_click_row.swap(0, .acq_rel);
        if (row == 0) return null;
        const col: u16 = @truncate(self.run_click_col.swap(0, .acq_rel));
        return .{ .row = @truncate(row), .col = col };
    }

    pub fn setContextHit(self: *InputSession, active: bool, row: u16, col0: u16, col1: u16) void {
        self.ctx_active.store(active, .release);
        self.ctx_row.store(row, .release);
        self.ctx_col0.store(col0, .release);
        self.ctx_col1.store(col1, .release);
    }

    pub fn contextPeekOn(self: *InputSession) bool {
        return self.ctx_peek.load(.acquire);
    }

    pub fn setSlashPalette(self: *InputSession, sel: usize, count: usize) void {
        self.slash_sel.store(@intCast(@min(sel, std.math.maxInt(u32))), .release);
        self.slash_count.store(@intCast(@min(count, std.math.maxInt(u32))), .release);
    }

    pub fn slashSel(self: *InputSession) usize {
        return self.slash_sel.load(.acquire);
    }

    pub fn takeSlashTab(self: *InputSession) bool {
        return self.slash_tab.swap(false, .acq_rel);
    }

    pub fn takePendingCmd(self: *InputSession, out: []u8) []const u8 {
        self.steerLock();
        defer self.steerUnlock();
        const n: usize = self.pending_cmd_len.swap(0, .acq_rel);
        if (n == 0) return "";
        const take = @min(n, out.len);
        @memcpy(out[0..take], self.pending_cmd[0..take]);
        return out[0..take];
    }

    fn setPendingCmdLocked(self: *InputSession, cmd: []const u8) void {
        const n = @min(cmd.len, self.pending_cmd.len);
        @memcpy(self.pending_cmd[0..n], cmd[0..n]);
        self.pending_cmd_len.store(@intCast(n), .release);
    }

    fn slashTypingLocked(self: *InputSession) bool {
        if (self.steer_len == 0 or self.steer_buf[0] != '/') return false;
        return std.mem.indexOfScalar(u8, self.steer_buf[0..self.steer_len], ' ') == null;
    }

    fn replaceSteerLocked(self: *InputSession, text: []const u8) void {
        const n = @min(text.len, self.steer_buf.len);
        @memcpy(self.steer_buf[0..n], text[0..n]);
        self.steer_len = n;
        self.utf8_need = 0;
    }

    /// Complete the highlighted slash into the steer buffer. `name` includes `/`.
    pub fn completeSlashName(self: *InputSession, name: []const u8) void {
        self.steerLock();
        defer self.steerUnlock();
        if (!self.slashTypingLocked()) return;
        var buf: [max_steer]u8 = undefined;
        const filled = std.fmt.bufPrint(&buf, "{s} ", .{name}) catch return;
        self.replaceSteerLocked(filled);
    }

    fn bumpSlashSel(self: *InputSession, delta: i32) void {
        const count = self.slash_count.load(.acquire);
        if (count == 0) return;
        var sel: i64 = @intCast(self.slash_sel.load(.acquire));
        sel += delta;
        if (sel < 0) sel = @intCast(count - 1);
        if (sel >= count) sel = 0;
        self.slash_sel.store(@intCast(sel), .release);
    }

    fn noteJumpIfHit(self: *InputSession, row: u16, col: u16) void {
        if (!self.jump_active.load(.acquire)) return;
        if (row != @as(u16, @truncate(self.jump_row.load(.acquire)))) return;
        const c0: u16 = @truncate(self.jump_col0.load(.acquire));
        const c1: u16 = @truncate(self.jump_col1.load(.acquire));
        if (col >= c0 and col <= c1) self.jump_pending.store(true, .release);
    }

    fn jumpWouldHit(self: *InputSession, row: u16, col: u16) bool {
        if (!self.jump_active.load(.acquire)) return false;
        if (row != @as(u16, @truncate(self.jump_row.load(.acquire)))) return false;
        const c0: u16 = @truncate(self.jump_col0.load(.acquire));
        const c1: u16 = @truncate(self.jump_col1.load(.acquire));
        return col >= c0 and col <= c1;
    }

    fn ctxWouldHit(self: *InputSession, row: u16, col: u16) bool {
        if (!self.ctx_active.load(.acquire)) return false;
        if (row != @as(u16, @truncate(self.ctx_row.load(.acquire)))) return false;
        const c0: u16 = @truncate(self.ctx_col0.load(.acquire));
        const c1: u16 = @truncate(self.ctx_col1.load(.acquire));
        return col >= c0 and col <= c1;
    }

    fn noteRunClick(self: *InputSession, row: u16, col: u16) void {
        self.run_click_row.store(row, .release);
        self.run_click_col.store(col, .release);
    }

    fn noteContextIfHit(self: *InputSession, row: u16, col: u16) void {
        if (!self.ctx_active.load(.acquire)) return;
        if (row != @as(u16, @truncate(self.ctx_row.load(.acquire)))) return;
        const c0: u16 = @truncate(self.ctx_col0.load(.acquire));
        const c1: u16 = @truncate(self.ctx_col1.load(.acquire));
        if (col >= c0 and col <= c1) {
            const on = self.ctx_peek.load(.acquire);
            self.ctx_peek.store(!on, .release);
        }
    }

    /// End of an SGR mouse report (`…M` or `…m`), or null if the CSI is incomplete.
    fn sgrMouseEnd(bytes: []const u8) ?usize {
        if (!std.mem.startsWith(u8, bytes, "\x1b[<")) return null;
        var j: usize = 3;
        while (j < bytes.len) : (j += 1) {
            if (bytes[j] == 'M' or bytes[j] == 'm') return j + 1;
        }
        return null;
    }

    /// Consume one mouse / page-scroll sequence. Returns how many bytes to skip and
    /// a scroll delta (0 for clicks that should not enter the steer queue).
    fn takeScrollSeq(self: *InputSession, bytes: []const u8, page_rows: u16) ?struct { n: usize, delta: i32 } {
        if (bytes.len == 0) return null;
        if (std.mem.startsWith(u8, bytes, "\x1b[5~")) {
            return .{ .n = 4, .delta = @as(i32, @intCast(@max(page_rows, 1))) };
        }
        if (std.mem.startsWith(u8, bytes, "\x1b[6~")) {
            return .{ .n = 4, .delta = -@as(i32, @intCast(@max(page_rows, 1))) };
        }
        // Ctrl-Up / Ctrl-Down (CSI 1;5A / 1;5B) — same as page in the idle loop.
        if (std.mem.startsWith(u8, bytes, "\x1b[1;5A")) {
            return .{ .n = 6, .delta = @as(i32, @intCast(@max(page_rows, 1))) };
        }
        if (std.mem.startsWith(u8, bytes, "\x1b[1;5B")) {
            return .{ .n = 6, .delta = -@as(i32, @intCast(@max(page_rows, 1))) };
        }
        const end = sgrMouseEnd(bytes) orelse return null;
        const params = bytes[3 .. end - 1];
        const semi = std.mem.indexOfScalar(u8, params, ';') orelse return .{ .n = end, .delta = 0 };
        const btn = std.fmt.parseInt(u32, params[0..semi], 10) catch return .{ .n = end, .delta = 0 };
        if (btn & 64 != 0) {
            // Release reports and tilt wheels do nothing.
            if (bytes[end - 1] == 'm') return .{ .n = end, .delta = 0 };
            if ((btn & 3) == 2 or (btn & 3) == 3) return .{ .n = end, .delta = 0 };
            return .{ .n = end, .delta = if ((btn & 1) == 0) wheel_step else -wheel_step };
        }
        // Left release on the jump pill re-pins to the live tail; header context
        // toggles the live peek overlay.
        if ((btn & 3) == 0 and (btn & 32) == 0 and bytes[end - 1] == 'm') {
            const rest = params[semi + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, ';')) |semi2| {
                const col = std.fmt.parseInt(u16, rest[0..semi2], 10) catch 0;
                const row = std.fmt.parseInt(u16, rest[semi2 + 1 ..], 10) catch 0;
                if (row != 0 and col != 0) {
                    const on_jump = self.jumpWouldHit(row, col);
                    const on_ctx = self.ctxWouldHit(row, col);
                    self.noteJumpIfHit(row, col);
                    self.noteContextIfHit(row, col);
                    if (!on_jump and !on_ctx) self.noteRunClick(row, col);
                }
            }
        }
        // Clicks / drags must not become steer text.
        return .{ .n = end, .delta = 0 };
    }

    fn stashKeys(self: *InputSession, bytes: []const u8) void {
        self.steerLock();
        defer self.steerUnlock();
        const n = @min(bytes.len, self.key_hold.len);
        @memcpy(self.key_hold[0..n], bytes[0..n]);
        self.key_hold_len = n;
    }

    fn joinHeld(self: *InputSession, bytes: []const u8, buf: *[cancel_drain_bytes + 64]u8) []const u8 {
        self.steerLock();
        defer self.steerUnlock();
        if (self.key_hold_len == 0) return bytes;
        const held = self.key_hold_len;
        self.key_hold_len = 0;
        const n = @min(bytes.len, buf.len - held);
        @memcpy(buf[0..held], self.key_hold[0..held]);
        @memcpy(buf[held..][0..n], bytes[0..n]);
        return buf[0 .. held + n];
    }

    fn findScrollAt(self: *InputSession, bytes: []const u8, from: usize) ?usize {
        var i = from;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] != 0x1b) continue;
            if (self.takeScrollSeq(bytes[i..], 1) != null) return i;
            if (std.mem.startsWith(u8, bytes[i..], "\x1b[<")) return i;
            if (std.mem.startsWith(u8, bytes[i..], "\x1b[5~") or std.mem.startsWith(u8, bytes[i..], "\x1b[6~")) return i;
        }
        return null;
    }

    /// Split a stdin chunk into scroll deltas vs steer/stop. Returns true when a
    /// stop key was present.
    pub fn routeTurnKeys(
        self: *InputSession,
        bytes: []const u8,
        page_rows: u16,
        noteScroll: *const fn (delta: i32) void,
        wantsStop: *const fn (bytes: []const u8) bool,
    ) bool {
        var join_buf: [cancel_drain_bytes + 64]u8 = undefined;
        const src = self.joinHeld(bytes, &join_buf);
        var stop = false;
        var i: usize = 0;
        while (i < src.len) {
            if (self.takeScrollSeq(src[i..], page_rows)) |s| {
                noteScroll(s.delta);
                i += s.n;
                continue;
            }
            // Slash picker: Up/Down move the highlight while typing `/…`.
            if (src.len >= i + 3 and src[i] == 0x1b and src[i + 1] == '[') {
                const key = src[i + 2];
                if (key == 'A' or key == 'B') {
                    self.steerLock();
                    const in_slash = self.slashTypingLocked();
                    self.steerUnlock();
                    if (in_slash) {
                        self.bumpSlashSel(if (key == 'A') -1 else 1);
                        i += 3;
                        continue;
                    }
                }
            }
            if (std.mem.startsWith(u8, src[i..], "\x1b[<") and sgrMouseEnd(src[i..]) == null) {
                self.stashKeys(src[i..]);
                break;
            }
            // Next mouse/page CSI, or the end of the buffer.
            const next = self.findScrollAt(src, i + 1) orelse src.len;
            const chunk = src[i..next];
            if (chunk.len != 0) {
                if (wantsStop(chunk)) stop = true else self.steerPush(chunk);
            }
            i = next;
        }
        return stop;
    }
};
