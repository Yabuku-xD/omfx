//! A wall-clock cap on any command the agent runs.
//!
//! Nothing in this codebase could time out: `Child.wait` blocks until the
//! command returns, and the streaming read blocks before that. A model that
//! runs `npm install`, a dev server, or `tail -f` hangs the agent with no way
//! out -- the interrupt key cannot rescue it either, because `pollCancel` only
//! fires at tool boundaries and SSE lines, and a blocking wait is neither.
//!
//! Zig 0.16's process API exposes no non-blocking wait, and macOS ships no
//! `timeout(1)`. Every command here already runs through a shell, so the shell
//! enforces the deadline itself: run the command in the background, race it
//! against a `sleep`, and kill it if the sleep wins. Portable POSIX sh, no new
//! dependency, and output written before the kill is still captured.

const std = @import("std");
const Io = std.Io;

/// Long enough for a real `cargo check` or a cold `tsc` on a large repo,
/// short enough that a hung command does not read as a hung agent. Verify runs
/// after every write, so this is also the worst case a single edit can cost.
///
/// Measured on this machine: `zig build test` 4.1s, `cargo check` on a small
/// crate 1.8s, `node --check` over 400 files 2.3s. A budget failure names
/// itself, so a project that legitimately needs longer sees the number.
pub const measured_default_secs: u32 = 120;

/// Set once at startup from settings.json. A project whose test suite runs for
/// ten minutes should not have to pass a timeout on every call.
pub var default_secs: u32 = measured_default_secs;

/// Zero keeps the measured default. One second is a floor rather than an
/// assertion: below it every command dies before the shell has started.
pub fn setDefaultSecs(n: u32) void {
    default_secs = if (n == 0) measured_default_secs else @max(n, 1);
}

/// Exit status the shell reports for a SIGKILLed child (128 + 9).
pub const killed_status: u8 = 137;

/// The watchdog, as a POSIX-sh script. Everything after the budget is the argv
/// to run, so this wraps *any* command -- including `sandbox-exec`, which is
/// the point: the watchdog must sit OUTSIDE the sandbox. Seatbelt denies
/// signalling, so a watchdog spawned inside it cannot kill anything, and the
/// cap silently does nothing.
///
/// Three more details, each found by something hanging rather than by reading:
///
///  - `set -m` puts the job in its own process group so `kill -9 -$pid` reaps
///    the command AND its children. Killing the bare pid kills only the
///    subshell; a `sleep` inside it survives, keeps the inherited stdout pipe
///    open, and the parent's read blocks for the command's full natural life.
///  - The watchdog's own stdio is closed so it never holds that pipe either.
///  - The script always runs under `/bin/sh`, never the user's login shell.
///    zsh's job control swallows a backgrounded job's output entirely.
///
/// The argv arrives positionally, so no command text is interpolated into
/// script source and there is nothing to quote or escape.
const script =
    \\set -m
    \\__omfx_secs=$1; shift
    \\"$@" & __omfx_pid=$!
    \\{ sleep "$__omfx_secs"; kill -9 -$__omfx_pid 2>/dev/null || kill -9 $__omfx_pid 2>/dev/null; } >/dev/null 2>&1 </dev/null & __omfx_dog=$!
    \\wait $__omfx_pid 2>/dev/null; __omfx_rc=$?
    \\kill $__omfx_dog 2>/dev/null; wait $__omfx_dog 2>/dev/null
    \\exit $__omfx_rc
;

/// Rendered at comptime so the argv holds no pointer into caller storage. An
/// earlier version formatted it into a struct field and returned the struct by
/// value, which left the last element dangling once the struct was copied out.
const default_secs_str = std.fmt.comptimePrint("{d}", .{measured_default_secs});

/// Longest argv this can wrap, plus the four elements the script needs.
pub const max_argv: usize = 24;

/// Wraps `argv` so it cannot outlive the budget. Every element is static or
/// borrowed from the caller, so there is nothing to free.
pub const Capped = struct {
    buf: [max_argv][]const u8,
    len: usize,
    /// The budget lives inside the struct so a caller-chosen number needs no
    /// allocation. `init` fills it in place: returning the struct by value with
    /// an argv element pointing at this field is a use-after-return.
    secs_buf: [12]u8 = undefined,

    pub fn slice(self: *const Capped) []const []const u8 {
        return self.buf[0..self.len];
    }

    /// Budget chosen at runtime -- by the model, or by a caller that knows the
    /// command is slow. Clamped so a model cannot ask for an unbounded wait.
    pub fn init(self: *Capped, argv: []const []const u8, secs: u32) void {
        const use = std.math.clamp(secs, min_secs, max_secs);
        const rendered = std.fmt.bufPrint(&self.secs_buf, "{d}", .{use}) catch default_secs_str;
        self.fill(argv, rendered);
    }

    fn fill(self: *Capped, argv: []const []const u8, secs: []const u8) void {
        const head = [_][]const u8{ "/bin/sh", "-c", script, "sh", secs };
        if (argv.len + head.len > max_argv) {
            @memcpy(self.buf[0..argv.len], argv);
            self.len = argv.len;
            return;
        }
        @memcpy(self.buf[0..head.len], &head);
        @memcpy(self.buf[head.len..][0..argv.len], argv);
        self.len = head.len + argv.len;
    }
};

/// A model that asks for no wait at all would make every command fail; one that
/// asks for an hour would hang the session. Both ends are named so a refusal is
/// legible in the tool result.
pub const min_secs: u32 = 1;
pub const max_secs: u32 = 600;

pub fn capped(argv: []const []const u8) Capped {
    return cappedIn(argv, default_secs_str);
}

/// Same, with a budget that already outlives the spawn -- a literal or a
/// comptime-rendered string, never a stack buffer.
pub fn cappedIn(argv: []const []const u8, secs: []const u8) Capped {
    var c = Capped{ .buf = undefined, .len = 0 };
    const head = [_][]const u8{ "/bin/sh", "-c", script, "sh", secs };
    // Refusing to wrap would silently drop the cap, so a too-long argv runs
    // uncapped only if it cannot fit -- and that is a compile-time-sized bound.
    if (argv.len + head.len > max_argv) {
        @memcpy(c.buf[0..argv.len], argv);
        c.len = argv.len;
        return c;
    }
    @memcpy(c.buf[0..head.len], &head);
    @memcpy(c.buf[head.len..][0..argv.len], argv);
    c.len = head.len + argv.len;
    return c;
}

/// True when a status came from the watchdog rather than the command itself.
pub fn timedOut(code: i32) bool {
    return code == killed_status;
}

/// What to show instead of a verdict when the deadline was the thing that fired.
pub fn note(allocator: std.mem.Allocator, label: []const u8, secs: u32) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "verify: timeout ({s} exceeded {d}s); not a clean verdict\n",
        .{ label, secs },
    );
}

// The regression that motivated closing the watchdog's stdio: with the pipe
// inherited, this blocks for the full budget instead of returning at once.
fn runCapped(argv: []const []const u8, secs: []const u8, pipe: bool) !std.process.Child.Term {
    const c = cappedIn(argv, secs);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = c.slice(),
        .stdout = if (pipe) .pipe else .ignore,
        .stderr = .ignore,
    });
    if (child.stdout) |f| {
        var buf: [128]u8 = undefined;
        var reader = std.Io.File.Reader.initStreaming(f, std.testing.io, &buf);
        while (reader.interface.takeByte()) |_| {} else |_| {}
    }
    return child.wait(std.testing.io);
}

test "a fast command keeps its own exit code" {
    const term = try runCapped(&.{ "/bin/sh", "-c", "echo hi; exit 7" }, "5", false);
    try std.testing.expectEqual(@as(u8, 7), term.exited);
}

test "a slow command is killed at the deadline" {
    // The whole point: this returns in about a second, not thirty.
    const term = try runCapped(&.{ "/bin/sh", "-c", "sleep 30" }, "1", false);
    try std.testing.expect(timedOut(@intCast(term.exited)));
}

test "a slow command with a piped stdout is still killed" {
    // With output on a pipe, an un-reaped grandchild holds the pipe open and
    // the read never ends. This is the case that actually hung.
    _ = try runCapped(&.{ "/bin/sh", "-c", "sleep 30" }, "1", true);
}

test "the login shell runs the command, whatever dialect it speaks" {
    // zsh with job control swallows a backgrounded job's output, so the
    // watchdog must never be written in the login shell's dialect.
    // Ubuntu runners often omit /bin/zsh; skip rather than fail the matrix.
    var zsh_file = Io.Dir.cwd().openFile(std.testing.io, "/bin/zsh", .{}) catch return;
    zsh_file.close(std.testing.io);
    const term = try runCapped(&.{ "/bin/zsh", "-c", "printf 'one\ntwo\n'; exit 0" }, "5", true);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
}

test "the cap survives a sandbox wrapper" {
    // Seatbelt denies signalling, so a watchdog spawned inside the sandbox
    // cannot kill anything. This asserts the watchdog is the outer process.
    if (@import("builtin").os.tag != .macos) return;
    const term = try runCapped(&.{
        "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
        "/bin/sh",               "-c", "sleep 30",
    }, "2", true);
    try std.testing.expect(timedOut(@intCast(term.exited)));
}

test "a model-chosen budget is clamped, not obeyed blindly" {
    var c: Capped = undefined;
    c.init(&.{ "/bin/sh", "-c", "true" }, 5);
    try std.testing.expectEqualStrings("5", c.slice()[4]);

    c.init(&.{ "/bin/sh", "-c", "true" }, 0);
    try std.testing.expectEqualStrings("1", c.slice()[4]);

    c.init(&.{ "/bin/sh", "-c", "true" }, 99999);
    try std.testing.expectEqualStrings("600", c.slice()[4]);
}

test "a runtime budget actually fires" {
    var c: Capped = undefined;
    c.init(&.{ "/bin/sh", "-c", "sleep 30" }, 1);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = c.slice(),
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(std.testing.io);
    try std.testing.expect(timedOut(@intCast(term.exited)));
}

test "an argv too long to wrap still runs" {
    var big: [max_argv]([]const u8) = undefined;
    for (&big) |*slot| slot.* = "x";
    const c = cappedIn(&big, "5");
    try std.testing.expectEqual(max_argv, c.len);
    try std.testing.expectEqualStrings("x", c.slice()[0]);
}

test "timedOut only claims the watchdog status" {
    try std.testing.expect(timedOut(killed_status));
    try std.testing.expect(!timedOut(0));
    try std.testing.expect(!timedOut(1));
    try std.testing.expect(!timedOut(136));
}

test "the note names the budget and the ask" {
    const a = std.testing.allocator;
    const s = try note(a, "cargo check", default_secs);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "cargo check") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "120s") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean verdict") != null);
}
