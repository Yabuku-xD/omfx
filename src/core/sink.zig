const std = @import("std");
const builtin = @import("builtin");
const types = @import("../providers/types.zig");
const config = @import("config.zig");
const permissions = @import("permissions.zig");

const log = std.log.scoped(.sink);

/// Harness callbacks. Null fields mean silent/default (stderr Y/N, no stream).
pub const Ask = enum { allow, deny, always };

pub const Channel = enum { text, think };

pub const Host = struct {
    ctx: ?*anyopaque = null,
    on_text: ?*const fn (ctx: ?*anyopaque, chunk: []const u8) void = null,
    on_think: ?*const fn (ctx: ?*anyopaque, chunk: []const u8) void = null,
    on_tool: ?*const fn (ctx: ?*anyopaque, name: []const u8, detail: []const u8, done: bool, body: []const u8) void = null,
    on_json: ?*const fn (ctx: ?*anyopaque, line: []const u8) void = null,
    ask: ?*const fn (ctx: ?*anyopaque, name: []const u8, detail: []const u8, args: []const u8) Ask = null,
    /// Real token counts from the provider, as they arrive.
    on_usage: ?*const fn (ctx: ?*anyopaque, input: u32, output: u32, read: u32, write: u32) void = null,
    on_tick: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Shift+Tab mid-turn: cycle ask→auto→yolo for later tool calls.
    mode_live: ?*config.PermissionMode = null,
    on_mode: ?*const fn (ctx: ?*anyopaque, label: []const u8) void = null,
    cancel: ?*std.atomic.Value(bool) = null,
    /// Transcript pane height for PageUp/Down while the turn owns stdin.
    page_rows: u16 = 20,

    pub fn cancelled(self: Host) bool {
        return if (self.cancel) |c| c.load(.acquire) else false;
    }

    pub fn push(self: Host, channel: Channel, chunk: []const u8) void {
        if (chunk.len == 0) return;
        switch (channel) {
            .text => {
                if (self.on_text) |f| f(self.ctx, chunk);
                if (self.on_json) |f| f(self.ctx, chunk);
            },
            .think => {
                if (self.on_think) |f| f(self.ctx, chunk);
            },
        }
    }

    pub fn text(self: Host, chunk: []const u8) void {
        self.push(.text, chunk);
    }

    pub fn think(self: Host, chunk: []const u8) void {
        self.push(.think, chunk);
    }

    pub fn tool(self: Host, name: []const u8, detail: []const u8, done: bool) void {
        self.toolOut(name, detail, done, "");
    }

    pub fn toolOut(self: Host, name: []const u8, detail: []const u8, done: bool, body: []const u8) void {
        if (self.on_tool) |f| f(self.ctx, name, detail, done, body);
    }

    /// `read` is the prompt the provider served from its cache and `write` is
    /// the part it had to process and store. Both occupy the context window
    /// exactly as fresh input does, so both are reported alongside rather than
    /// folded into `input`, which the wire sets to 1 on a fully cached turn.
    pub fn usage(self: Host, input: u32, output: u32, read: u32, write: u32) void {
        if (self.on_usage) |f| f(self.ctx, input, output, read, write);
    }

    pub fn decide(self: Host, name: []const u8, detail: []const u8, args: []const u8) ?Ask {
        if (self.ask) |f| return f(self.ctx, name, detail, args);
        return null;
    }

    /// Called wherever a turn can pause: every SSE line, every tool boundary.
    pub fn pollCancel(self: Host) void {
        const flag = self.cancel orelse {
            _ = drainKeys();
            return;
        };
        if (drainKeys()) flag.store(true, .release);
    }

    /// Apply a pending Shift+Tab permission cycle to `mode_live`.
    pub fn pollModeCycle(self: Host) void {
        if (!mode_cycle_pending.swap(false, .acq_rel)) return;
        const slot = self.mode_live orelse return;
        slot.* = permissions.cycleMode(slot.*);
        if (self.on_mode) |f| f(self.ctx, @tagName(slot.*));
    }

    pub fn stream(self: Host) types.Stream {
        return .{
            .ctx = self.ctx,
            .on_text = self.on_text,
            .on_think = self.on_think,
            .on_usage = self.on_usage,
            .on_tick = self.on_tick,
            .cancel = self.cancel,
            .poll_key = pollCancelKey,
            .page_rows = self.page_rows,
        };
    }
};

/// Bytes read in one non-blocking drain. A terminal delivers a whole escape
/// sequence in a single read, so this only has to hold the largest of those.
pub const cancel_drain_bytes: usize = 512;

/// Words both surfaces show when a stop is requested. The TUI paints this
/// through the activity line; stream/ask wraps it in CSI.
pub const stopping_phrase = "Stopping...";

/// Messages typed while a turn runs. Held here rather than dropped: a sentence
/// written during a long turn is the user steering, and throwing it away makes
/// the pane feel dead and costs them what they just wrote.
///
/// Enter commits the line being typed as one queued message and leaves the
/// composer empty for the next, so a turn can be steered more than once.
///
/// Receipt: a typed line is well under 200 bytes; 4 KB is a tripwire for a
/// paste, which is the only way one line fills.
pub const max_steer: usize = 4096;
/// Past this the user is not steering, they are writing the next session. The
/// oldest queued message is kept and further Enters are ignored.
pub const max_queued: usize = 8;

/// Stdin is one resource and the watcher thread and the SSE loop both drain it,
/// so what they find has to land somewhere both can reach.
var steer_buf: [max_steer]u8 = undefined;
var steer_len: usize = 0;
var queued: [max_queued][max_steer]u8 = undefined;
var queued_len: [max_queued]usize = @splat(0);
var queued_n: usize = 0;
/// Spin lock, matching how the paint path guards its own two threads: the
/// critical section is a memcpy of a few hundred bytes.
var steer_lock: std.atomic.Value(u32) = .init(0);

fn steerLock() void {
    while (steer_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn steerUnlock() void {
    steer_lock.store(0, .release);
}

/// Caller holds the lock.
fn commitLine() void {
    if (steer_len == 0) return;
    if (queued_n == max_queued) {
        steer_len = 0;
        return;
    }
    @memcpy(queued[queued_n][0..steer_len], steer_buf[0..steer_len]);
    queued_len[queued_n] = steer_len;
    queued_n += 1;
    steer_len = 0;
}

/// Typed bytes that are not a stop request. Control bytes are dropped: only
/// what a composer would have accepted is worth keeping.
/// Escape sequences arrive split across reads, so where one ended is state.
///
/// `x10` counts out the three bytes that follow an `ESC [ M` mouse report.
/// They are raw coordinates offset by 32, not part of the CSI, so ending the
/// sequence at the `M` left them to land in the message as text -- and past
/// column 95 they are not even valid UTF-8, which is what put replacement
/// glyphs in the transcript.
var esc_state: enum { none, esc, seq, x10 } = .none;
var x10_left: u8 = 0;
/// True once a `<` has been seen in this CSI: an SGR mouse report carries its
/// coordinates as parameters, so nothing follows the final byte.
var esc_sgr: bool = false;

fn steerPush(bytes: []const u8) void {
    steerLock();
    defer steerUnlock();
    for (bytes) |c| {
        // An arrow key is ESC [ B. Dropping only the ESC leaves "[B" in the
        // message, which is how a keypress became text nobody typed.
        switch (esc_state) {
            .none => {},
            .esc => {
                esc_state = if (c == '[' or c == 'O') .seq else .none;
                continue;
            },
            .seq => {
                if (c == '<') esc_sgr = true;
                if (c >= 0x40 and c <= 0x7e) {
                    if ((c == 'M' or c == 'm') and !esc_sgr) {
                        esc_state = .x10;
                        x10_left = 3;
                    } else {
                        esc_state = .none;
                    }
                }
                continue;
            },
            .x10 => {
                x10_left -= 1;
                if (x10_left == 0) esc_state = .none;
                continue;
            },
        }
        if (c == 0x1b) {
            esc_state = .esc;
            esc_sgr = false;
            continue;
        }
        if (c == '\r' or c == '\n') {
            // Bare `/cmd` mid-turn: defer as a slash command, do not queue as
            // a user message (Claude keeps slash UX live while generating).
            if (slashTypingLocked() and steer_len > 1) {
                setPendingCmdLocked(steer_buf[0..steer_len]);
                steer_len = 0;
                continue;
            }
            commitLine();
            continue;
        }
        if (c == 0x09) {
            // Tab: live paint path completes via slash_sel; mark request.
            if (slashTypingLocked()) {
                // Selection stays; live.paintTty applies completeSlashName.
                slash_tab.store(true, .release);
            }
            continue;
        }
        if (c == 0x7f or c == 0x08) {
            if (steer_len != 0) steer_len -= 1;
            continue;
        }
        if (c < 0x20) continue;
        if (steer_len == steer_buf.len) continue;
        if (!acceptRuneByte(c)) continue;
        steer_buf[steer_len] = c;
        steer_len += 1;
    }
}

/// One queued message. Borrowed from the queue, so it is read before the next
/// `takeSteer`; the caller copies what it keeps.
/// Bytes still expected to finish the rune being read, and where it started.
var utf8_need: usize = 0;
var utf8_start: usize = 0;

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
fn acceptRuneByte(c: u8) bool {
    const continuation = c & 0xc0 == 0x80;
    if (utf8_need != 0) {
        if (continuation) {
            utf8_need -= 1;
            return true;
        }
        // The rune never finished, so what was written is not text. Drop it
        // and judge this byte on its own.
        steer_len = utf8_start;
        utf8_need = 0;
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
    utf8_need = want;
    utf8_start = steer_len;
    return true;
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

/// What is queued right now, without clearing it. The pane draws this while the
/// turn runs, so typing mid-turn is visible instead of silent.
pub fn peekSteer() Queued {
    steerLock();
    defer steerUnlock();
    var out = Queued{ .rows = undefined, .n = queued_n, .typing = steer_buf[0..steer_len] };
    for (0..queued_n) |i| out.rows[i] = queued[i][0..queued_len[i]];
    return out;
}

/// Everything typed during the turn, copied out and cleared. A line that was
/// never committed with Enter comes back as the last message: it is what the
/// user was writing, and dropping it would cost them the words.
pub fn takeSteer(out: []u8) Steer {
    steerLock();
    defer steerUnlock();
    var w: usize = 0;
    var msgs: usize = 0;
    for (0..queued_n) |i| {
        const n = @min(queued_len[i], out.len - w);
        if (n == 0) break;
        if (w != 0) {
            if (w == out.len) break;
            out[w] = '\n';
            w += 1;
        }
        @memcpy(out[w..][0..n], queued[i][0..n]);
        w += n;
        msgs += 1;
    }
    const tail = @min(steer_len, out.len - w);
    if (tail != 0) {
        if (w != 0 and w < out.len) {
            out[w] = '\n';
            w += 1;
        }
        @memcpy(out[w..][0..@min(tail, out.len - w)], steer_buf[0..@min(tail, out.len - w)]);
        w += @min(tail, out.len - w);
    }
    steer_len = 0;
    queued_n = 0;
    // Only a committed line asks to be sent; an unfinished one parks in the
    // composer for the user to finish.
    return .{ .text = out[0..w], .ready = msgs != 0 and tail == 0 };
}

pub const Steer = struct {
    text: []const u8,
    /// Enter was pressed: the caller sends rather than parks it in the composer.
    ready: bool,
};

/// Feeds the queue as if it had been typed. Tests only: the real path reads
/// stdin, which a test has no way to write to.
pub fn pushSteerForTest(bytes: []const u8) void {
    steerPush(bytes);
}

/// Drops whatever was typed. Used when the turn was interrupted: the words
/// were aimed at a turn that no longer exists.
pub fn dropSteer() void {
    steerLock();
    defer steerUnlock();
    steer_len = 0;
    queued_n = 0;
    esc_state = .none;
    esc_sgr = false;
    x10_left = 0;
    utf8_need = 0;
    utf8_start = 0;
    ctx_peek.store(false, .release);
    pending_cmd_len.store(0, .release);
    slash_tab.store(false, .release);
}

/// True if the user asked to stop: ctrl-c, a bare Esc, or kitty CSI-u Esc (27).
/// Arrow keys, SS3, and mouse reports are not a stop.
///
/// This cannot peek. `recv(MSG_PEEK)` fails with ENOTSOCK on a TTY, which is
/// what made the previous version of this function never fire.
fn pollCancelKey() bool {
    return drainKeys();
}

var mode_cycle_pending: std.atomic.Value(bool) = .init(false);

/// Wheel / PageUp deltas queued by the cancel watcher while a turn owns stdin.
/// Positive = older transcript (scroll up); negative = toward the live tail.
var scroll_delta: std.atomic.Value(i32) = .init(0);

/// Rows one mouse-wheel notch moves. Kept here (not in the TUI module) so the
/// watcher thread can apply the same step without importing the CLI layer.
pub const wheel_step: i32 = 3;

pub fn takeScrollDelta() i32 {
    return scroll_delta.swap(0, .acq_rel);
}

fn noteScroll(delta: i32) void {
    if (delta == 0) return;
    _ = scroll_delta.fetchAdd(delta, .monotonic);
}

/// Hit box for the jump-to-bottom pill while a turn owns stdin (1-based cells).
var jump_active: std.atomic.Value(bool) = .init(false);
var jump_row: std.atomic.Value(u32) = .init(0);
var jump_col0: std.atomic.Value(u32) = .init(0);
var jump_col1: std.atomic.Value(u32) = .init(0);
var jump_pending: std.atomic.Value(bool) = .init(false);

/// Header context meter hit box (1-based cells) while a turn owns stdin.
var ctx_active: std.atomic.Value(bool) = .init(false);
var ctx_row: std.atomic.Value(u32) = .init(0);
var ctx_col0: std.atomic.Value(u32) = .init(0);
var ctx_col1: std.atomic.Value(u32) = .init(0);
var ctx_peek: std.atomic.Value(bool) = .init(false);

/// Slash palette selection while typing `/…` mid-turn.
var slash_sel: std.atomic.Value(u32) = .init(0);
var slash_count: std.atomic.Value(u32) = .init(0);
var slash_tab: std.atomic.Value(bool) = .init(false);

/// Deferred slash command to run when the turn ends (e.g. `/settings`).
var pending_cmd: [64]u8 = undefined;
var pending_cmd_len: std.atomic.Value(u32) = .init(0);

pub fn setJumpHit(active: bool, row: u16, col0: u16, col1: u16) void {
    jump_active.store(active, .release);
    jump_row.store(row, .release);
    jump_col0.store(col0, .release);
    jump_col1.store(col1, .release);
    if (!active) jump_pending.store(false, .release);
}

pub fn takeJumpToBottom() bool {
    return jump_pending.swap(false, .acq_rel);
}

pub fn setContextHit(active: bool, row: u16, col0: u16, col1: u16) void {
    ctx_active.store(active, .release);
    ctx_row.store(row, .release);
    ctx_col0.store(col0, .release);
    ctx_col1.store(col1, .release);
}

pub fn contextPeekOn() bool {
    return ctx_peek.load(.acquire);
}

pub fn setSlashPalette(sel: usize, count: usize) void {
    slash_sel.store(@intCast(@min(sel, std.math.maxInt(u32))), .release);
    slash_count.store(@intCast(@min(count, std.math.maxInt(u32))), .release);
}

pub fn slashSel() usize {
    return slash_sel.load(.acquire);
}

pub fn takeSlashTab() bool {
    return slash_tab.swap(false, .acq_rel);
}

fn noteJumpIfHit(row: u16, col: u16) void {
    if (!jump_active.load(.acquire)) return;
    if (row != @as(u16, @truncate(jump_row.load(.acquire)))) return;
    const c0: u16 = @truncate(jump_col0.load(.acquire));
    const c1: u16 = @truncate(jump_col1.load(.acquire));
    if (col >= c0 and col <= c1) jump_pending.store(true, .release);
}

fn noteContextIfHit(row: u16, col: u16) void {
    if (!ctx_active.load(.acquire)) return;
    if (row != @as(u16, @truncate(ctx_row.load(.acquire)))) return;
    const c0: u16 = @truncate(ctx_col0.load(.acquire));
    const c1: u16 = @truncate(ctx_col1.load(.acquire));
    if (col >= c0 and col <= c1) {
        const on = ctx_peek.load(.acquire);
        ctx_peek.store(!on, .release);
    }
}

/// Copy a deferred slash command out and clear it.
pub fn takePendingCmd(out: []u8) []const u8 {
    steerLock();
    defer steerUnlock();
    const n: usize = pending_cmd_len.swap(0, .acq_rel);
    if (n == 0) return "";
    const take = @min(n, out.len);
    @memcpy(out[0..take], pending_cmd[0..take]);
    return out[0..take];
}

fn setPendingCmdLocked(cmd: []const u8) void {
    const n = @min(cmd.len, pending_cmd.len);
    @memcpy(pending_cmd[0..n], cmd[0..n]);
    pending_cmd_len.store(@intCast(n), .release);
}

fn slashTypingLocked() bool {
    if (steer_len == 0 or steer_buf[0] != '/') return false;
    return std.mem.indexOfScalar(u8, steer_buf[0..steer_len], ' ') == null;
}

fn replaceSteerLocked(text: []const u8) void {
    const n = @min(text.len, steer_buf.len);
    @memcpy(steer_buf[0..n], text[0..n]);
    steer_len = n;
    utf8_need = 0;
}

/// Complete the highlighted slash into the steer buffer. `name` includes `/`.
pub fn completeSlashName(name: []const u8) void {
    steerLock();
    defer steerUnlock();
    if (!slashTypingLocked()) return;
    var buf: [max_steer]u8 = undefined;
    const filled = std.fmt.bufPrint(&buf, "{s} ", .{name}) catch return;
    replaceSteerLocked(filled);
}

fn bumpSlashSel(delta: i32) void {
    const count = slash_count.load(.acquire);
    if (count == 0) return;
    var sel: i64 = @intCast(slash_sel.load(.acquire));
    sel += delta;
    if (sel < 0) sel = @intCast(count - 1);
    if (sel >= count) sel = 0;
    slash_sel.store(@intCast(sel), .release);
}

fn wantsModeCycle(bytes: []const u8) bool {
    // Shift+Tab is CSI Z (`\x1b[Z`).
    return std.mem.indexOf(u8, bytes, "\x1b[Z") != null;
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
fn takeScrollSeq(bytes: []const u8, page_rows: u16) ?struct { n: usize, delta: i32 } {
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
                noteJumpIfHit(row, col);
                noteContextIfHit(row, col);
            }
        }
    }
    // Clicks / drags must not become steer text.
    return .{ .n = end, .delta = 0 };
}

/// Drain stdin: stop keys cancel, Shift+Tab queues a permission cycle, wheel
/// and page keys scroll the transcript, else steer.
fn drainKeys() bool {
    return drainKeysTimeout(0, 20);
}

fn drainKeysTimeout(wait_ms: i32, page_rows: u16) bool {
    if (builtin.os.tag == .windows) return false;
    var stop = false;
    while (true) {
        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, wait_ms) catch return stop;
        if (n == 0) return stop;
        var buf: [cancel_drain_bytes]u8 = undefined;
        const got = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return stop;
        if (got == 0) return stop;
        if (wantsModeCycle(buf[0..got])) {
            mode_cycle_pending.store(true, .release);
            continue;
        }
        if (routeTurnKeys(buf[0..got], page_rows)) stop = true;
    }
}

/// Split a stdin chunk into scroll deltas vs steer/stop. Returns true when a
/// stop key was present.
fn routeTurnKeys(bytes: []const u8, page_rows: u16) bool {
    var stop = false;
    var i: usize = 0;
    while (i < bytes.len) {
        if (takeScrollSeq(bytes[i..], page_rows)) |s| {
            noteScroll(s.delta);
            i += s.n;
            continue;
        }
        // Slash picker: Up/Down move the highlight while typing `/…`.
        if (bytes.len >= i + 3 and bytes[i] == 0x1b and bytes[i + 1] == '[') {
            const key = bytes[i + 2];
            if (key == 'A' or key == 'B') {
                steerLock();
                const in_slash = slashTypingLocked();
                steerUnlock();
                if (in_slash) {
                    bumpSlashSel(if (key == 'A') -1 else 1);
                    i += 3;
                    continue;
                }
            }
        }
        if (std.mem.startsWith(u8, bytes[i..], "\x1b[<") and sgrMouseEnd(bytes[i..]) == null) break;
        // Next mouse/page CSI, or the end of the buffer.
        const next = findScrollAt(bytes, i + 1) orelse bytes.len;
        const chunk = bytes[i..next];
        if (chunk.len != 0) {
            if (wantsStop(chunk)) stop = true else steerPush(chunk);
        }
        i = next;
    }
    return stop;
}

fn findScrollAt(bytes: []const u8, from: usize) ?usize {
    var i = from;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != 0x1b) continue;
        if (takeScrollSeq(bytes[i..], 1) != null) return i;
        if (std.mem.startsWith(u8, bytes[i..], "\x1b[<")) return i;
        if (std.mem.startsWith(u8, bytes[i..], "\x1b[5~") or std.mem.startsWith(u8, bytes[i..], "\x1b[6~")) return i;
    }
    return null;
}

/// `wait_ms` 0 polls and returns; a positive value blocks that long, which is
/// what lets the watcher thread idle instead of spinning.
fn pollCancelKeyTimeout(wait_ms: i32, page_rows: u16) bool {
    return drainKeysTimeout(wait_ms, page_rows);
}

/// In-flight chat socket. Esc/timeout shuts it down so a blocked
/// `Reader.stream` returns instead of waiting forever for the first byte.
var abort_fd: std.atomic.Value(i64) = .init(-1);
var stall_flag: std.atomic.Value(bool) = .init(false);

/// How long to wait for any provider bytes before aborting. Reasoning models
/// can think for a while; this is a network/API hang tripwire, not a token budget.
pub const stall_timeout_ms: i64 = 120_000;

pub fn armAbort(fd: std.posix.fd_t) void {
    stall_flag.store(false, .release);
    abort_fd.store(@intCast(fd), .release);
}

pub fn disarmAbort() void {
    abort_fd.store(-1, .release);
}

/// Unblock a hung chat read. Safe if nothing is armed. Leaves the fd armed so
/// a late Esc (before connect) still aborts once `armAbort` runs.
pub fn fireAbort() void {
    const raw = abort_fd.load(.acquire);
    if (raw < 0) return;
    const fd: std.posix.fd_t = @intCast(raw);
    const rc = std.posix.system.shutdown(fd, std.posix.SHUT.RDWR);
    log.debug("fireAbort fd={d} rc={d}", .{ fd, rc });
}

pub fn takeStall() bool {
    return stall_flag.swap(false, .acq_rel);
}

fn wallMs() i64 {
    const posix = std.posix;
    const id: posix.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => posix.CLOCK.UPTIME_RAW,
        else => posix.CLOCK.MONOTONIC,
    };
    var ts: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(id, &ts))) {
        .SUCCESS => return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000),
        else => return 0,
    }
}

/// Watches the keyboard while the main thread is blocked reading the socket.
///
/// `pollCancel` only runs at SSE lines and tool boundaries. Before the first
/// token there are neither, so an Esc pressed during a long reasoning pause sat
/// in the stdin buffer with no acknowledgement -- indistinguishable, from the
/// user's side, from a broken key.
///
/// Esc also shuts down the armed chat socket (`fireAbort`) so the blocked HTTP
/// read returns. Without that, cancel only took effect after the first byte.
///
/// The watcher owns stdin for the duration of the request. That is safe
/// precisely because the main thread is blocked elsewhere: the two never read
/// it at once.
pub const Watch = struct {
    cancel: *std.atomic.Value(bool),
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Painted on the first stop request (stream/ask without a TUI tick).
    ack: []const u8 = "",
    tick: ?*const fn (ctx: ?*anyopaque) void = null,
    tick_ctx: ?*anyopaque = null,
    /// PageUp/Down step while the turn owns stdin (transcript pane height).
    page_rows: u16 = 20,
    /// Override for tests; 0 disables the stall timer.
    stall_ms: i64 = stall_timeout_ms,
    /// Cooked stdin buffers Esc until Enter. Drop ICANON for the watch only
    /// when the terminal is still line-buffered (ask/stream). TUI is already
    /// raw, so this is a no-op there and must not fight `tty.Raw`.
    termios_saved: bool = false,
    termios_old: std.posix.system.termios = undefined,

    pub fn start(self: *Watch) void {
        if (builtin.os.tag == .windows) return;
        self.stop.store(false, .release);
        stall_flag.store(false, .release);
        self.enterKeyMode();
        self.thread = std.Thread.spawn(.{}, loop, .{self}) catch |err| blk: {
            log.warn("cancel watch: {s}", .{@errorName(err)});
            break :blk null;
        };
    }

    pub fn finish(self: *Watch) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.leaveKeyMode();
        disarmAbort();
    }

    fn enterKeyMode(self: *Watch) void {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        const fd = std.posix.STDIN_FILENO;
        const old = std.posix.tcgetattr(fd) catch return;
        if (!old.lflag.ICANON) return;
        var next = old;
        next.lflag.ECHO = false;
        next.lflag.ICANON = false;
        if (@hasField(@TypeOf(next.lflag), "ECHOCTL")) next.lflag.ECHOCTL = false;
        if (@hasField(std.posix.system.V, "MIN")) {
            next.cc[@intFromEnum(std.posix.system.V.MIN)] = 1;
            next.cc[@intFromEnum(std.posix.system.V.TIME)] = 0;
        }
        std.posix.tcsetattr(fd, .FLUSH, next) catch return;
        self.termios_old = old;
        self.termios_saved = true;
    }

    fn leaveKeyMode(self: *Watch) void {
        if (!self.termios_saved) return;
        self.termios_saved = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios_old) catch {};
    }

    fn loop(self: *Watch) void {
        var told = false;
        var stalled = false;
        const started = wallMs();
        while (!self.stop.load(.acquire)) {
            const hit = pollCancelKeyTimeout(60, self.page_rows);
            if (hit) {
                self.cancel.store(true, .release);
                log.debug("watch: stop key", .{});
            }
            // Re-fire while cancelled: Esc may arrive before the socket is armed.
            if (self.cancel.load(.acquire)) fireAbort();
            if (!stalled and self.stall_ms > 0) {
                const now = wallMs();
                if (now != 0 and started != 0 and now -| started >= self.stall_ms) {
                    stalled = true;
                    stall_flag.store(true, .release);
                    self.cancel.store(true, .release);
                    fireAbort();
                    log.debug("watch: stall timeout", .{});
                }
            }
            if (self.tick) |f| f(self.tick_ctx);
            if (!hit) continue;
            if (told or self.ack.len == 0) continue;
            told = true;
            // Stream/ask only. The TUI paints through `tick`; a raw `\r\n`
            // here races the spinner and leaks CSI into the pane.
            _ = std.c.write(std.posix.STDOUT_FILENO, self.ack.ptr, self.ack.len);
        }
    }
};

/// Split out so the classification is testable without a terminal.
pub fn wantsStop(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == 0x03) return true;
        if (c != 0x1b) {
            i += 1;
            continue;
        }
        if (i + 1 == bytes.len) return true;
        const next = bytes[i + 1];
        if (next == '[') {
            if (csiIsKittyEsc(bytes[i + 2 ..])) return true;
            i = skipCsi(bytes, i);
            continue;
        }
        if (next == 'O') {
            i += if (i + 2 < bytes.len) 3 else 2;
            continue;
        }
        return true;
    }
    return false;
}

fn skipCsi(bytes: []const u8, esc_at: usize) usize {
    var j = esc_at + 2;
    while (j < bytes.len and (bytes[j] < 0x40 or bytes[j] > 0x7E)) j += 1;
    if (j < bytes.len) return j + 1;
    return bytes.len;
}

const kitty_esc_code: u32 = 27;

fn csiIsKittyEsc(after_bracket: []const u8) bool {
    var j: usize = 0;
    while (j < after_bracket.len) : (j += 1) {
        if (after_bracket[j] >= 0x40 and after_bracket[j] <= 0x7E) {
            if (after_bracket[j] != 'u') return false;
            return csiFirstNum(after_bracket[0..j]) == kitty_esc_code;
        }
    }
    // Split `\x1b[27` / `u` would otherwise be drained and lost.
    return csiFirstNum(after_bracket) == kitty_esc_code;
}

fn csiFirstNum(params: []const u8) u32 {
    var n: u32 = 0;
    var any = false;
    for (params) |c| {
        if (c >= '0' and c <= '9') {
            any = true;
            n = n *| 10 + (c - '0');
        } else break;
    }
    return if (any) n else 0;
}

test "wantsStop separates an Esc press from an escape sequence" {
    try std.testing.expect(wantsStop(&[_]u8{0x03}));
    try std.testing.expect(wantsStop("\x1b"));
    try std.testing.expect(wantsStop("ab\x1b"));
    try std.testing.expect(!wantsStop("\x1b[A"));
    try std.testing.expect(!wantsStop("\x1bOP"));
    try std.testing.expect(!wantsStop("hello"));
    try std.testing.expect(!wantsStop(""));
    try std.testing.expect(wantsStop("\x1b[<0;1;1M\x1b"));
}

test "wantsStop treats kitty CSI-u Esc as a stop" {
    try std.testing.expect(wantsStop("\x1b[27u"));
    try std.testing.expect(wantsStop("\x1b[27;1u"));
    try std.testing.expect(wantsStop("\x1b[27;1:1u"));
    try std.testing.expect(wantsStop("\x1b[27"));
    try std.testing.expect(!wantsStop("\x1b[13u"));
    try std.testing.expect(!wantsStop("\x1b[<64;1;1M"));
}

test "wheel and page sequences become scroll deltas" {
    _ = takeScrollDelta();
    try std.testing.expect(!routeTurnKeys("\x1b[<64;10;5M", 20));
    try std.testing.expectEqual(@as(i32, wheel_step), takeScrollDelta());
    try std.testing.expect(!routeTurnKeys("\x1b[<65;10;5M", 20));
    try std.testing.expectEqual(@as(i32, -wheel_step), takeScrollDelta());
    try std.testing.expect(!routeTurnKeys("\x1b[5~", 12));
    try std.testing.expectEqual(@as(i32, 12), takeScrollDelta());
    try std.testing.expect(!routeTurnKeys("\x1b[6~", 12));
    try std.testing.expectEqual(@as(i32, -12), takeScrollDelta());
}

test "mouse clicks during a turn are not steered" {
    dropSteer();
    try std.testing.expect(!routeTurnKeys("\x1b[<0;10;5M", 20));
    var buf: [max_steer]u8 = undefined;
    const got = takeSteer(&buf);
    try std.testing.expectEqual(@as(usize, 0), got.text.len);
}

test "jump pill click while generating requests stick-to-bottom" {
    setJumpHit(true, 10, 20, 40);
    defer setJumpHit(false, 0, 0, 0);
    _ = takeJumpToBottom();
    try std.testing.expect(!routeTurnKeys("\x1b[<0;25;10m", 20));
    try std.testing.expect(takeJumpToBottom());
    // Beside the pill: no jump.
    try std.testing.expect(!routeTurnKeys("\x1b[<0;5;10m", 20));
    try std.testing.expect(!takeJumpToBottom());
}

test "cancelled is false without a flag" {
    const h = Host{};
    try std.testing.expect(!h.cancelled());
}

test "fireAbort is a no-op until armed" {
    disarmAbort();
    fireAbort();
    try std.testing.expect(!takeStall());
}

test "takeStall clears the flag" {
    stall_flag.store(true, .release);
    try std.testing.expect(takeStall());
    try std.testing.expect(!takeStall());
}

test "fireAbort unblocks a blocked read" {
    if (builtin.os.tag == .windows) return;
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(@intCast(std.c.AF.UNIX), @intCast(std.c.SOCK.STREAM), 0, &fds);
    try std.testing.expect(rc == 0);
    defer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }
    const Box = struct {
        var n: isize = -99;
        fn reader(fd: std.posix.fd_t) void {
            var buf: [8]u8 = undefined;
            const got = std.posix.read(fd, &buf) catch {
                n = -1;
                return;
            };
            n = @intCast(got);
        }
    };
    Box.n = -99;
    armAbort(fds[0]);
    defer disarmAbort();
    const t = try std.Thread.spawn(.{}, Box.reader, .{fds[0]});
    var wait = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&wait, null);
    fireAbort();
    t.join();
    try std.testing.expect(Box.n == 0 or Box.n == -1);
}

test "watch stall timer sets takeStall" {
    if (builtin.os.tag == .windows) return;
    var cancelled: std.atomic.Value(bool) = .init(false);
    var w = Watch{ .cancel = &cancelled, .stall_ms = 80 };
    w.start();
    var wait = std.c.timespec{ .sec = 0, .nsec = 250 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&wait, null);
    w.finish();
    try std.testing.expect(cancelled.load(.acquire));
    try std.testing.expect(takeStall());
}

test "toolOut forwards body to on_tool" {
    const Box = struct {
        var got: usize = 0;
        fn onTool(_: ?*anyopaque, name: []const u8, _: []const u8, done: bool, body: []const u8) void {
            if (std.mem.eql(u8, name, "bash") and done and std.mem.indexOf(u8, body, "ok") != null) got += 1;
        }
    };
    Box.got = 0;
    const h = Host{ .on_tool = Box.onTool };
    h.tool("bash", "ls", false);
    try std.testing.expectEqual(@as(usize, 0), Box.got);
    h.toolOut("bash", "ls", true, "ok\n");
    try std.testing.expectEqual(@as(usize, 1), Box.got);
}

test "think does not call on_text" {
    const Box = struct {
        var texts: usize = 0;
        var thinks: usize = 0;
        fn onText(_: ?*anyopaque, _: []const u8) void {
            texts += 1;
        }
        fn onThink(_: ?*anyopaque, _: []const u8) void {
            thinks += 1;
        }
    };
    Box.texts = 0;
    Box.thinks = 0;
    const h = Host{ .on_text = Box.onText, .on_think = Box.onThink };
    h.think("plan");
    h.text("hi");
    try std.testing.expectEqual(@as(usize, 1), Box.texts);
    try std.testing.expectEqual(@as(usize, 1), Box.thinks);
}

test "a watcher with nothing to watch starts and stops cleanly" {
    var cancelled: std.atomic.Value(bool) = .init(false);
    var w = Watch{ .cancel = &cancelled };
    w.start();
    w.finish();
    try std.testing.expect(!cancelled.load(.acquire));
    // And finishing twice must not join a joined thread.
    w.finish();
}

test "the stop acknowledgement is a self-contained escape sequence" {
    // Written from the watcher thread while the main thread is blocked, so it
    // must not depend on cursor state it did not set itself.
    const ack = "\r\x1b[K\x1b[2m" ++ stopping_phrase ++ "\x1b[0m\r\n";
    try std.testing.expect(std.mem.startsWith(u8, ack, "\r"));
    try std.testing.expect(std.mem.endsWith(u8, ack, "\r\n"));
    // Ends with a reset, or the next paint inherits dim.
    try std.testing.expect(std.mem.indexOf(u8, ack, "\x1b[0m") != null);
}

test "enter commits a line and leaves the composer empty for the next" {
    dropSteer();
    pushSteerForTest("fix the test\r");
    pushSteerForTest("and commit");
    const q = peekSteer();
    try std.testing.expectEqual(@as(usize, 1), q.n);
    try std.testing.expectEqualStrings("fix the test", q.rows[0]);
    try std.testing.expectEqualStrings("and commit", q.typing);
    dropSteer();
}

test "an uncommitted tail comes back but does not ask to be sent" {
    dropSteer();
    var buf: [max_steer]u8 = undefined;
    pushSteerForTest("one\rtwo\rthree");
    const got = takeSteer(&buf);
    try std.testing.expectEqualStrings("one\ntwo\nthree", got.text);
    // "three" was never committed, so the caller parks it instead of sending.
    try std.testing.expect(!got.ready);
    dropSteer();
}

test "every committed line sends as one prompt" {
    dropSteer();
    var buf: [max_steer]u8 = undefined;
    pushSteerForTest("one\rtwo\r");
    const got = takeSteer(&buf);
    try std.testing.expectEqualStrings("one\ntwo", got.text);
    try std.testing.expect(got.ready);
    dropSteer();
}

test "a bare enter queues nothing" {
    dropSteer();
    pushSteerForTest("\r\r");
    try std.testing.expectEqual(@as(usize, 0), peekSteer().n);
    dropSteer();
}

test "control bytes and backspace never reach the queue" {
    dropSteer();
    pushSteerForTest("a\x1b[Bb");
    pushSteerForTest("c\x7f");
    try std.testing.expectEqualStrings("ab", peekSteer().typing);
    dropSteer();
}

test "a mouse report never becomes a queued message" {
    dropSteer();
    // X10: three raw coordinate bytes follow the final `M`, and past column
    // 95 they are not valid UTF-8. This is what leaked into the transcript.
    pushSteerForTest("ok\x1b[M\xc8\xe0\x20fine");
    try std.testing.expectEqualStrings("okfine", peekSteer().typing);
    dropSteer();

    // SGR: the coordinates are parameters, so the final byte ends it.
    pushSteerForTest("a\x1b[<0;10;5Mb\x1b[<32;12;5Mc\x1b[<0;12;5md");
    try std.testing.expectEqualStrings("abcd", peekSteer().typing);
    dropSteer();

    // Split across reads, which is how they actually arrive.
    pushSteerForTest("x\x1b[M");
    // All three payload bytes belong to the report, space included.
    pushSteerForTest("\xc8\xe0 y");
    try std.testing.expectEqualStrings("xy", peekSteer().typing);
    dropSteer();
}

test "no byte that is not text reaches the queue" {
    dropSteer();
    // A mouse coordinate past column 95, in a report shape the escape filter
    // does not recognise: it is not valid UTF-8, so it is not text.
    pushSteerForTest("ok\xc8\xe0\x9f fine");
    const typed = peekSteer().typing;
    try std.testing.expect(std.unicode.utf8ValidateSlice(typed));
    try std.testing.expectEqualStrings("ok fine", typed);
    dropSteer();

    // Real multi-byte text still goes through, including split across reads.
    pushSteerForTest("caf\xc3");
    pushSteerForTest("\xa9 \xe2\x9c\x93");
    try std.testing.expectEqualStrings("caf\xc3\xa9 \xe2\x9c\x93", peekSteer().typing);
    dropSteer();
}

test "the queue stops at its cap rather than growing" {
    dropSteer();
    var i: usize = 0;
    while (i < max_queued + 3) : (i += 1) pushSteerForTest("x\r");
    try std.testing.expectEqual(max_queued, peekSteer().n);
    dropSteer();
}
