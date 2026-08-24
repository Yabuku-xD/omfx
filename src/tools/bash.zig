const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const confine = @import("confine.zig");
const deadline = @import("deadline.zig");
const jobs = @import("jobs.zig");

const log = std.log.scoped(.bash);

pub const SandboxKind = enum { landlock, seatbelt, bwrap, none };

pub fn macProfile(allocator: std.mem.Allocator, workspace: []const u8) ![]u8 {
    return confine.macSeatbelt(allocator, workspace);
}

pub fn describeSandbox(kind: SandboxKind) []const u8 {
    return switch (kind) {
        .landlock => "sandbox: landlock net-deny",
        .seatbelt => "sandbox: seatbelt net-deny",
        .bwrap => "sandbox: bwrap net-deny",
        .none => "sandbox: unavailable (no seatbelt/bwrap/landlock); not a clean isolation",
    };
}

pub fn fallbackLoginShell() []const u8 {
    return if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash";
}

pub fn resolveLoginShell(configured: ?[]const u8) []const u8 {
    const path = configured orelse return fallbackLoginShell();
    if (path.len == 0 or path[0] != '/') return fallbackLoginShell();
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "bash") or std.mem.eql(u8, base, "zsh")) return path;
    return fallbackLoginShell();
}

pub const Policy = enum { confined, open };

pub fn run(allocator: std.mem.Allocator, io: Io, workspace: []const u8, command: []const u8) ![]u8 {
    return runPolicy(allocator, io, workspace, command, .confined, deadline.default_secs);
}

pub fn runEx(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    command: []const u8,
    net_deny: bool,
) ![]u8 {
    return runFor(allocator, io, workspace, command, net_deny, deadline.default_secs);
}

/// Same, with the budget the caller (usually the model) asked for. The value is
/// clamped in `deadline`, so an absent or absurd number still runs bounded.
pub fn runFor(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    command: []const u8,
    net_deny: bool,
    secs: u32,
) ![]u8 {
    return runPolicy(allocator, io, workspace, command, if (net_deny) .confined else .open, secs);
}

/// Commands that are meant to keep running. Backgrounding these by default is
/// the difference between "the agent started your dev server" and "the agent
/// waited two minutes and reported a timeout".
///
/// Deliberately a short, literal list rather than a clever heuristic: a false
/// positive silently detaches a command whose output the model was waiting for,
/// which is worse than the wait. Anything not listed still runs in the
/// foreground, and `background: true` forces the issue either way.
const unbounded = [_][]const u8{
    "npm run dev",            "npm start",    "yarn dev",          "pnpm dev",
    "bun run dev",            "vite",         "next dev",          "nodemon",
    "npm run watch",          "cargo watch",  "zig build watch",   "python -m http.server",
    "python3 -m http.server", "rails server", "rails s",           "flask run",
    "uvicorn",                "gunicorn",     "docker compose up", "docker-compose up",
    "tail -f",                "watch ",       "serve",             "http-server",
};

pub fn looksUnbounded(command: []const u8) bool {
    const t = std.mem.trim(u8, command, " \t\n");
    // Only the head of the line: `echo "npm run dev"` is not a dev server, and
    // a pipeline that ends in something else is the user's business.
    for (unbounded) |u| {
        if (std.mem.startsWith(u8, t, u)) return true;
    }
    return false;
}

/// Runs `command` detached. Returns as soon as it has started, so a dev server
/// or a long build never blocks the turn.
pub fn runBackground(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    command: []const u8,
) ![]u8 {
    return jobs.start(allocator, io, workspace, resolveLoginShell(null), command);
}

fn runPolicy(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    command: []const u8,
    policy: Policy,
    secs: u32,
) ![]u8 {
    if (command.len == 0) return error.EmptyCommand;
    const shell = resolveLoginShell(null);
    return switch (policy) {
        .open => spawnShell(allocator, io, workspace, shell, command, null, secs),
        .confined => spawnConfined(allocator, io, workspace, shell, command, secs),
    };
}

fn spawnShell(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    shell: []const u8,
    command: []const u8,
    kind: ?SandboxKind,
    secs: u32,
) ![]u8 {
    // Every command the model runs reaches a spawn through here or through
    // spawnConfined, so the wall-clock cap is applied at both.
    var cap: deadline.Capped = undefined;
    cap.init(&.{ shell, "-c", command }, secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        return std.fmt.allocPrint(allocator, "bash spawn failed: {s}", .{command});
    };
    const body = try collect(allocator, io, &child);
    return if (kind) |k| prefixKind(allocator, k, body) else body;
}

fn spawnArgv(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    argv: []const []const u8,
    kind: SandboxKind,
) ?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return null;
    const body = collect(allocator, io, &child) catch |err| {
        log.warn("collect {s}: {s}", .{ @tagName(kind), @errorName(err) });
        return null;
    };
    return prefixKind(allocator, kind, body) catch |err| {
        log.warn("prefix {s}: {s}", .{ @tagName(kind), @errorName(err) });
        return null;
    };
}

fn spawnConfined(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    shell: []const u8,
    command: []const u8,
    secs: u32,
) ![]u8 {
    switch (builtin.os.tag) {
        .macos => {
            const profile = try macProfile(allocator, workspace);
            defer allocator.free(profile);
            // The cap wraps sandbox-exec rather than living inside it:
            // seatbelt denies signalling, so an inner watchdog cannot kill.
            var cap: deadline.Capped = undefined;
            cap.init(&.{
                "/usr/bin/sandbox-exec", "-p", profile, shell, "-c", command,
            }, secs);
            if (spawnArgv(allocator, io, workspace, cap.slice(), .seatbelt)) |body| return body;
        },
        .linux => {
            switch (confine.runLinux(allocator, workspace, shell, command)) {
                .body => |body| return prefixKind(allocator, .landlock, body),
                .skip => {},
            }
            if (spawnArgv(allocator, io, workspace, &.{
                "bwrap",   "--unshare-net", "--die-with-parent",
                "--bind",  workspace,       workspace,
                "--chdir", workspace,       "--proc",
                "/proc",   "--dev",         "/dev",
                "--tmpfs", "/tmp",          "--ro-bind-try",
                "/usr",    "/usr",          "--ro-bind-try",
                "/bin",    "/bin",          "--ro-bind-try",
                "/lib",    "/lib",          "--ro-bind-try",
                "/lib64",  "/lib64",        "--ro-bind-try",
                "/etc",    "/etc",          shell,
                "-c",      command,
            }, .bwrap)) |body| return body;
            if (spawnArgv(allocator, io, workspace, &.{
                "bwrap", "--unshare-net", "--die-with-parent", shell, "-c", command,
            }, .bwrap)) |body| return body;
        },
        else => {},
    }
    return spawnShell(allocator, io, workspace, shell, command, .none, secs);
}

fn prefixKind(allocator: std.mem.Allocator, kind: SandboxKind, body: []u8) ![]u8 {
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ describeSandbox(kind), body });
}

/// Receipt: a `zig build` failure is ~4 KB, a failing pytest run ~8 KB. 32 KB
/// is a tripwire for a command that is printing rather than reporting.
const collect_cap: usize = 32_000;

/// Everything the command said, on both streams.
///
/// stderr used to be piped and never read, so every compiler error, stack
/// trace and test failure -- the whole reason the agent runs a command -- was
/// dropped on the floor and the model saw an empty result with a bad exit code.
/// Both streams are read through one `MultiReader` because reading them in
/// sequence deadlocks the moment the unread one fills its pipe buffer.
pub const Collected = struct {
    body: []u8,
    term: std.process.Child.Term,
};

/// Both streams and the exit code, for callers that report a verdict.
pub fn collectWithTerm(
    allocator: std.mem.Allocator,
    io: Io,
    child: *std.process.Child,
) !Collected {
    var term: std.process.Child.Term = .{ .exited = 0 };
    const body = try collectInner(allocator, io, child, &term);
    return .{ .body = body, .term = term };
}

fn collect(allocator: std.mem.Allocator, io: Io, child: *std.process.Child) ![]u8 {
    var term: std.process.Child.Term = .{ .exited = 0 };
    return collectInner(allocator, io, child, &term);
}

fn collectInner(
    allocator: std.mem.Allocator,
    io: Io,
    child: *std.process.Child,
    out_term: *std.process.Child.Term,
) ![]u8 {
    const out_file = child.stdout orelse return allocator.dupe(u8, "(no output)");
    const err_file = child.stderr orelse return allocator.dupe(u8, "(no output)");
    var streams: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(allocator, io, streams.toStreams(), &.{ out_file, err_file });
    defer multi.deinit();

    while (multi.fill(64, .none)) |_| {
        const seen = multi.reader(0).buffered().len + multi.reader(1).buffered().len;
        if (seen >= collect_cap) break;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {
            child.kill(io);
            _ = child.wait(io) catch |e| log.debug("wait: {s}", .{@errorName(e)});
            return std.fmt.allocPrint(allocator, "(read failed: {s})", .{@errorName(err)});
        },
    }

    const term = child.wait(io) catch {
        child.kill(io);
        return std.fmt.allocPrint(allocator, "(reaped)", .{});
    };
    out_term.* = term;

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, multi.reader(0).buffered());
    const errs = multi.reader(1).buffered();
    if (errs.len != 0) {
        if (body.items.len != 0 and body.items[body.items.len - 1] != '\n') {
            try body.append(allocator, '\n');
        }
        try body.appendSlice(allocator, errs);
    }
    if (body.items.len == 0) {
        return std.fmt.allocPrint(allocator, "(no output) {s}", .{@tagName(std.meta.activeTag(term))});
    }
    if (body.items.len >= collect_cap) {
        body.shrinkRetainingCapacity(collect_cap);
        try body.appendSlice(allocator, "\ntruncated at 32000 bytes\n");
    }
    return body.toOwnedSlice(allocator);
}

test "empty command fails" {
    try std.testing.expectError(error.EmptyCommand, run(std.testing.allocator, std.testing.io, "/tmp", ""));
}

test "unsupported login shell falls back" {
    const expected = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash";
    try std.testing.expectEqualStrings(expected, resolveLoginShell("/bin/fish"));
    try std.testing.expectEqualStrings(expected, resolveLoginShell("zsh"));
    try std.testing.expectEqualStrings("/bin/zsh", resolveLoginShell("/bin/zsh"));
    try std.testing.expectEqualStrings("/bin/bash", resolveLoginShell("/bin/bash"));
}

test "mac profile denies network writes and secret reads" {
    const p = try macProfile(std.testing.allocator, "/tmp/ws");
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "(deny network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "(deny file-write*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, ".ssh/") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "/tmp/ws") != null);
}

test "none is not a clean isolation" {
    try std.testing.expect(std.mem.indexOf(u8, describeSandbox(.none), "not a clean isolation") != null);
}

test "a runaway command cannot outlive the budget" {
    // Nothing here could time out before: Child.wait blocks until the command
    // returns, and the interrupt key cannot help because pollCancel only fires
    // at tool boundaries. Without the cap this blocks for 400 seconds.
    //
    // Driven through the same spawn the tool uses, with a short budget so the
    // suite does not wait out the production one.
    const cap = deadline.cappedIn(&.{
        resolveLoginShell(null), "-c", "sleep 400",
    }, "2");
    var child = try std.process.spawn(std.testing.io, .{
        .argv = cap.slice(),
        .stdout = .pipe,
        .stderr = .ignore,
    });
    if (child.stdout) |f| {
        var buf: [64]u8 = undefined;
        var reader = Io.File.Reader.initStreaming(f, std.testing.io, &buf);
        while (reader.interface.takeByte()) |_| {} else |_| {}
    }
    const term = try child.wait(std.testing.io);
    try std.testing.expect(deadline.timedOut(@intCast(term.exited)));
}

test "only real long-runners are detached by default" {
    try std.testing.expect(looksUnbounded("npm run dev"));
    try std.testing.expect(looksUnbounded("  tail -f app.log"));
    try std.testing.expect(looksUnbounded("docker compose up"));
    // A command that ends is a command the model is waiting on.
    try std.testing.expect(!looksUnbounded("npm test"));
    try std.testing.expect(!looksUnbounded("cargo build"));
    try std.testing.expect(!looksUnbounded("ls -la"));
    // The name has to lead the line, not merely appear in it.
    try std.testing.expect(!looksUnbounded("echo 'npm run dev'"));
    try std.testing.expect(!looksUnbounded("grep -r vite ."));
    try std.testing.expect(!looksUnbounded(""));
}

test "a command's errors come back, not just its output" {
    const a = std.testing.allocator;
    const out = try run(a, std.testing.io, ".", "echo out; echo err 1>&2");
    defer a.free(out);
    // Both streams, in that order: stderr is where every compiler puts the
    // thing the agent actually needs to read.
    try std.testing.expect(std.mem.indexOf(u8, out, "out") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "err") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "out").? < std.mem.indexOf(u8, out, "err").?);
}

test "a failing command reports what failed" {
    const a = std.testing.allocator;
    const out = try run(a, std.testing.io, ".", "ls /definitely/not/here");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(no output)") == null);
}
