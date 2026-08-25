//! Background commands: started, still running, readable later.
//!
//! `/background` already existed as a UI over a list nothing ever appended to,
//! and its `kill` removed a string from an array without signalling anything.
//! This is the missing half: a real pid, a real log file, and a kill that kills.
//!
//! A job outlives the turn that started it, so its output cannot go to a pipe
//! the loop is waiting on -- that is the blocking this exists to avoid. Output
//! lands in `.omfx/jobs/<id>.log`, which the model reads with `read` like any
//! other file, and which survives the process that wrote it.

const std = @import("std");
const Io = std.Io;

const pathing = @import("pathing.zig");

const log = std.log.scoped(.jobs);

/// More than this many live jobs is a runaway loop, not a workflow. The cap is
/// named in the refusal so a model that hits it can stop rather than retry.
pub const max_jobs: usize = 8;
/// Tail returned inline when a job is polled. Enough to see a stack trace or a
/// test summary; the whole log is a `read` away.
pub const tail_bytes: usize = 4_000;

comptime {
    if (max_jobs == 0) @compileError("max_jobs must hold at least one job");
}

pub const Job = struct {
    id: usize,
    /// Non-optional: a job with no pid is nothing we can poll or kill, so a
    /// spawn that yields none is reported as unavailable rather than listed.
    pid: i32,
    /// Truncated for display. The log file holds the command in full.
    cmd: [160]u8 = undefined,
    cmd_len: usize = 0,

    pub fn command(self: *const Job) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
};

/// Process-lifetime, like `pathing`'s access rules: jobs belong to the session,
/// and a pid from a previous run is somebody else's process by now.
var locked: std.atomic.Value(u32) = .init(0);
var live: [max_jobs]Job = undefined;
var live_n: usize = 0;
var next_id: usize = 1;

fn lock() void {
    while (locked.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    locked.store(0, .release);
}

pub fn count() usize {
    lock();
    defer unlock();
    return live_n;
}

/// Copy under the lock so the caller never holds a slice into `live`.
pub fn snapshot(out: *[max_jobs]Job) []const Job {
    lock();
    defer unlock();
    const n = live_n;
    @memcpy(out[0..n], live[0..n]);
    return out[0..n];
}

pub fn logPath(allocator: std.mem.Allocator, workspace: []const u8, id: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.omfx/jobs/{d}.log", .{ workspace, id });
}

/// Workspace-relative, for telling the model where to look. `read` is rooted at
/// the workspace, so the absolute path would be rejected as an escape.
pub fn logRel(allocator: std.mem.Allocator, id: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, ".omfx/jobs/{d}.log", .{id});
}

/// Soft progress signal: how many bytes the job has written so far.
pub fn logBytes(io: Io, workspace: []const u8, id: usize) u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.omfx/jobs/{d}.log", .{ workspace, id }) catch return 0;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.size;
}

fn capRefused(allocator: std.mem.Allocator, n: usize) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "background: refused, {d} jobs already running (max_jobs={d}); /background kill one first\n",
        .{ n, max_jobs },
    );
}

/// Starts `command` detached and returns the note the model sees.
///
/// stdout and stderr both go to the log so a failing command explains itself;
/// stdin is closed so anything that prompts fails fast instead of hanging on a
/// terminal that is not there.
pub fn start(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    shell: []const u8,
    command: []const u8,
) ![]u8 {
    lock();
    if (live_n == max_jobs) {
        const n_live = live_n;
        unlock();
        return capRefused(allocator, n_live);
    }
    const id = next_id;
    next_id += 1;
    unlock();

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.omfx/jobs", .{workspace});
    defer allocator.free(dir_path);
    Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        return std.fmt.allocPrint(allocator, "background: unavailable (mkdir: {s})\n", .{@errorName(err)});
    };

    const path = try logPath(allocator, workspace, id);
    defer allocator.free(path);
    var file = Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "background: unavailable (log: {s})\n", .{@errorName(err)});
    };
    defer file.close(io);

    const child = std.process.spawn(io, .{
        .argv = &.{ shell, "-c", command },
        .cwd = .{ .path = workspace },
        .stdin = .close,
        .stdout = .{ .file = file },
        .stderr = .{ .file = file },
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "background: unavailable (spawn: {s})\n", .{@errorName(err)});
    };

    const pid = child.id orelse {
        return std.fmt.allocPrint(allocator, "background: unavailable (no pid from spawn)\n", .{});
    };
    lock();
    if (live_n == max_jobs) {
        const n_now = live_n;
        unlock();
        if (@import("builtin").os.tag != .windows) {
            std.posix.kill(pid, .KILL) catch {};
            _ = std.c.waitpid(pid, null, 0);
        }
        return capRefused(allocator, n_now);
    }
    live[live_n] = .{ .id = id, .pid = pid };
    const n = @min(command.len, live[live_n].cmd.len);
    @memcpy(live[live_n].cmd[0..n], command[0..n]);
    live[live_n].cmd_len = n;
    live_n += 1;
    unlock();

    const rel = try logRel(allocator, id);
    defer allocator.free(rel);
    return std.fmt.allocPrint(
        allocator,
        "background: started job {d}\noutput streams to {s}; read it, or /background list\n",
        .{ id, rel },
    );
}

/// WNOHANG: report the child's status without waiting for it.
const wnohang: c_int = 1;

/// Whether the job is still alive -- and reaps it if not.
///
/// Signal 0 is not enough on its own: a killed child that nobody has waited on
/// is a zombie, and signalling a zombie succeeds, so the job would read as
/// running forever. `waitpid` both answers the question and clears the entry.
pub fn running(job: Job) bool {
    if (@import("builtin").os.tag == .windows) return true;
    const rc = std.c.waitpid(job.pid, null, wnohang);
    // The child was reaped just now, or is already gone.
    if (rc == job.pid or rc < 0) return false;
    std.posix.kill(job.pid, @enumFromInt(0)) catch return false;
    return true;
}

fn find(id: usize) ?usize {
    for (live[0..live_n], 0..) |j, i| {
        if (j.id == id) return i;
    }
    return null;
}

fn drop(at: usize) void {
    var i = at;
    while (i + 1 < live_n) : (i += 1) live[i] = live[i + 1];
    live_n -= 1;
}

/// SIGKILL to the process group, so a shell's children die with it. Falls back
/// to the bare pid when the job never became a group leader.
fn killUnlocked(id: usize) bool {
    const at = find(id) orelse return false;
    const job = live[at];
    if (@import("builtin").os.tag != .windows) {
        std.posix.kill(-job.pid, .KILL) catch {
            std.posix.kill(job.pid, .KILL) catch {};
        };
        // Reap, so the pid is not left as a zombie that still answers signals.
        _ = std.c.waitpid(job.pid, null, 0);
    }
    drop(at);
    return true;
}

pub fn kill(id: usize) bool {
    lock();
    defer unlock();
    return killUnlocked(id);
}

pub fn killAll() usize {
    lock();
    defer unlock();
    const n = live_n;
    while (live_n > 0) _ = killUnlocked(live[live_n - 1].id);
    return n;
}

/// Status plus the tail of the log. A finished job is dropped from the list
/// here, once its output has been handed over.
pub fn poll(allocator: std.mem.Allocator, io: Io, workspace: []const u8, id: usize) ![]u8 {
    lock();
    const found: ?Job = if (find(id)) |i| live[i] else null;
    unlock();
    const job = found orelse {
        return std.fmt.allocPrint(allocator, "no job {d}\n", .{id});
    };
    const alive = running(job);

    const path = try logPath(allocator, workspace, id);
    defer allocator.free(path);
    const body = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1_000_000)) catch
        try allocator.dupe(u8, "");
    defer allocator.free(body);
    const tail = if (body.len > tail_bytes) body[body.len - tail_bytes ..] else body;

    if (!alive) {
        lock();
        defer unlock();
        if (find(id)) |i| drop(i);
    }
    return std.fmt.allocPrint(allocator, "job {d} {s}\n{s}", .{
        id,
        if (alive) "running" else "finished",
        tail,
    });
}

test "start rejects once the cap is reached" {
    live_n = max_jobs;
    defer live_n = 0;
    const a = std.testing.allocator;
    const s = try start(a, std.testing.io, ".", "/bin/sh", "true");
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "max_jobs=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "refused") != null);
}

test "a job runs detached, is listed, and its output is readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);

    _ = killAll();
    defer _ = killAll();
    const note = try start(a, io, ws, "/bin/sh", "echo hello-from-job");
    defer a.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "started job") != null);
    try std.testing.expectEqual(@as(usize, 1), count());

    var snap: [max_jobs]Job = undefined;
    const id = snapshot(&snap)[0].id;
    // The command is short; give it a moment to flush before polling.
    var spins: usize = 0;
    while (spins < 200) : (spins += 1) {
        const p = try poll(a, io, ws, id);
        defer a.free(p);
        if (std.mem.indexOf(u8, p, "hello-from-job") != null) return;
        if (std.mem.indexOf(u8, p, "finished") != null and spins > 100) break;
    }
    return error.JobOutputNeverAppeared;
}

test "a long job returns immediately instead of blocking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);

    _ = killAll();
    defer _ = killAll();
    // The whole point: this call returns now, not in 400 seconds.
    const note = try start(a, io, ws, "/bin/sh", "sleep 400");
    defer a.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "started job") != null);
    var snap: [max_jobs]Job = undefined;
    try std.testing.expect(running(snapshot(&snap)[0]));
}

test "kill stops the process and forgets the job" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);

    _ = killAll();
    defer _ = killAll();
    const note = try start(a, io, ws, "/bin/sh", "sleep 400");
    a.free(note);
    var snap: [max_jobs]Job = undefined;
    const job = snapshot(&snap)[0];
    try std.testing.expect(kill(job.id));
    try std.testing.expectEqual(@as(usize, 0), count());
    // The old /background kill only dropped a string; this must reap the pid.
    var spins: usize = 0;
    while (spins < 200) : (spins += 1) {
        if (!running(job)) return;
    }
    return error.ProcessSurvivedKill;
}

test "killing an unknown id is a no-op, not a crash" {
    live_n = 0;
    try std.testing.expect(!kill(9999));
    const a = std.testing.allocator;
    const s = try poll(a, std.testing.io, ".", 9999);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "no job 9999") != null);
}
