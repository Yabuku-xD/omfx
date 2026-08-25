const std = @import("std");
const builtin = @import("builtin");

/// Cooked stdin echoes CSI as caret text (`^[[C`) onto the footer.
/// Vim/Neovim/Ghostty also leave DECCKM, mouse, and kitty keyboard on;
/// those leak both into omfx and back out if we do not push/pop.
extern "c" fn tcflush(fd: std.c.fd_t, queue: c_int) c_int;

const Saved = struct {
    fd: std.posix.fd_t = 0,
    old: std.posix.system.termios = undefined,
    raw: std.posix.system.termios = undefined,
    active: bool = false,
    hooked: bool = false,
};

var saved: Saved = .{};
var resized: std.atomic.Value(bool) = .init(false);
/// Painters check this so a panic dump is not overwritten by the spinner.
var halted: std.atomic.Value(bool) = .init(false);

pub fn takeResize() bool {
    return resized.swap(false, .seq_cst);
}

pub fn halt() void {
    halted.store(true, .release);
}

pub fn isHalted() bool {
    return halted.load(.acquire);
}

/// Input queue only. Linux TCIFLUSH=0, Darwin TCIFLUSH=1.
const input_flush: c_int = if (builtin.os.tag == .linux) 0 else 1;

/// Drop queued input. Mouse reports that arrived while a turn owned stdin
/// would otherwise leak into the composer as leftover CSI bytes.
pub fn flushInput() void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    _ = tcflush(@intCast(std.posix.STDIN_FILENO), input_flush);
}

pub const Raw = struct {
    pub fn enter() Raw {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return .{};
        const fd = std.posix.STDIN_FILENO;
        const old = std.posix.tcgetattr(fd) catch return .{};
        var next = old;
        next.lflag.ECHO = false;
        next.lflag.ICANON = false;
        if (@hasField(@TypeOf(next.lflag), "ECHOCTL")) next.lflag.ECHOCTL = false;
        if (@hasField(@TypeOf(next.lflag), "IEXTEN")) next.lflag.IEXTEN = false;
        if (@hasField(@TypeOf(next.iflag), "IXON")) next.iflag.IXON = false;
        if (@hasField(std.posix.system.V, "MIN")) {
            next.cc[@intFromEnum(std.posix.system.V.MIN)] = 1;
            next.cc[@intFromEnum(std.posix.system.V.TIME)] = 0;
        }
        _ = tcflush(@intCast(fd), input_flush);
        std.posix.tcsetattr(fd, .FLUSH, next) catch return .{};
        saved = .{ .fd = fd, .old = old, .raw = next, .active = true, .hooked = saved.hooked };
        hookSignals();
        return .{};
    }

    pub fn leave(_: *Raw) void {
        restore();
    }
};

pub fn restore() void {
    if (!saved.active) return;
    saved.active = false;
    _ = std.c.write(std.posix.STDOUT_FILENO, restore_seq.ptr, restore_seq.len);
    std.posix.tcsetattr(saved.fd, .FLUSH, saved.old) catch {};
}

/// Written from the signal path too: no alloc, no stdio buffers.
pub const restore_seq: []const u8 =
    "\x1b[?2004l" ++
    "\x1b[<u" ++
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?1015l\x1b[?1016l" ++
    "\x1b[?2026l\x1b[?2048l" ++
    "\x1b[?1l\x1b>" ++
    // DECSCUSR 0 hands the cursor shape back to the terminal's own setting.
    "\x1b[0 q" ++
    "\x1b[?25h\x1b[?1049l\x1b[r\x1b[0m" ++
    // The tab title outlives the process; an exited session must not keep
    // labelling the tab someone reuses for something else.
    "\x1b]0;\x07" ++
    "\x1b]9;4;0\x07";

pub const enter_seq: []const u8 =
    "\x1b[?1049h" ++
    "\x1b[?1l\x1b>" ++
    "\x1b[?25h" ++
    "\x1b[?1004l\x1b[?1005l\x1b[?1015l\x1b[?1016l" ++
    // Press, release, and motion while a button is held, in SGR encoding.
    //
    // 1002 rather than 1003: the app needs the drag to draw a selection, but
    // not every idle pointer move. Once any reporting is on the terminal stops
    // making its own selection, so omfx has to make one -- which it does, and
    // copies it on release. 1003 would add hover events nothing reads.
    "\x1b[?1000h\x1b[?1002h\x1b[?1006h" ++
    // Alternate scroll off. With it on the terminal turns the wheel into arrow
    // keys, which the composer reads as history: scrolling the transcript
    // walked the prompt history instead. The wheel scrolls the pane through
    // mouse reporting or not at all.
    "\x1b[?1007l" ++
    "\x1b[?2026l\x1b[?2048l" ++
    "\x1b[>4;0m" ++
    "\x1b[>1u" ++
    "\x1b[?2004h" ++
    // DECSCUSR 5: a blinking bar. The block cursor a terminal defaults to sits
    // on top of the character under it, which in a one-line composer reads as
    // a selection rather than a caret.
    "\x1b[5 q" ++
    "\x1b[?7h\x1b[0m";

fn hookSignals() void {
    if (builtin.os.tag == .windows) return;
    if (saved.hooked) return;
    saved.hooked = true;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onFatal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.HUP, &act, null);
    const stop: std.posix.Sigaction = .{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TSTP, &stop, null);
    const cont: std.posix.Sigaction = .{
        .handler = .{ .handler = onCont },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CONT, &cont, null);
    const win: std.posix.Sigaction = .{
        .handler = .{ .handler = onWinch },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.WINCH, &win, null);
}

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    resized.store(true, .seq_cst);
}

fn onFatal(sig: std.posix.SIG) callconv(.c) void {
    restore();
    const dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = null },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    _ = std.c.raise(sig);
}

fn onStop(_: std.posix.SIG) callconv(.c) void {
    restore();
    const dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = null },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TSTP, &dfl, null);
    _ = std.c.raise(.TSTP);
}

fn onCont(_: std.posix.SIG) callconv(.c) void {
    if (saved.fd == 0) return;
    const stop: std.posix.Sigaction = .{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TSTP, &stop, null);
    std.posix.tcsetattr(saved.fd, .FLUSH, saved.raw) catch return;
    saved.active = true;
    _ = std.c.write(std.posix.STDOUT_FILENO, enter_seq.ptr, enter_seq.len);
    resized.store(true, .seq_cst);
}

test "raw enter is a no-op off tty" {
    var raw = Raw{};
    raw.leave();
    try std.testing.expect(!saved.active);
}

test "restore seq leaves alt screen and pops kitty keyboard" {
    try std.testing.expect(std.mem.indexOf(u8, restore_seq, "1049l") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_seq, "\x1b[<u") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_seq, "1000l") != null);
}

test "halt stops painters without restoring" {
    try std.testing.expect(!isHalted());
    halt();
    defer halted.store(false, .release);
    try std.testing.expect(isHalted());
}

test "the caret is a blinking bar, and the shape is handed back on exit" {
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "\x1b[5 q") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_seq, "\x1b[0 q") != null);
}

test "enter seq pushes kitty disambiguate and asks for clicks only" {
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "\x1b[>1u") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "2004h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "1000h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "1006h") != null);
    // Drag, so a selection can be drawn; not 1003, which reports every idle
    // pointer move and nothing reads those.
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "1002h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "1003h") == null);
}
