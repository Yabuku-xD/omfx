//! Optional auto-commit after successful writes. Never injects git log into the model prompt.
//! SHAs live under `.omfx/` for SHA-gated `/undo` only.

const std = @import("std");
const Io = std.Io;
const deadline = @import("deadline.zig");
const settings = @import("../core/settings.zig");

const log = std.log.scoped(.git_work);

pub const git_secs: u32 = 30;
const sha_rel = ".omfx/git_last_sha";
const trailer = "\n\nCo-authored-by: omfx <omfx@local>\n";

fn hasGit(io: Io, workspace: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.git", .{workspace}) catch return false;
    var d = Io.Dir.cwd().openDir(io, p, .{}) catch {
        var f = Io.Dir.cwd().openFile(io, p, .{ .mode = .read_only }) catch return false;
        f.close(io);
        return true;
    };
    d.close(io);
    return true;
}

fn runGit(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    argv: []const []const u8,
) !struct { ok: bool, out: []u8 } {
    var cap: deadline.Capped = undefined;
    cap.init(argv, git_secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return .{ .ok = false, .out = try allocator.dupe(u8, "") };
    var out_buf: [1024]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    errdefer {
        collected.deinit(allocator);
        child.kill(io);
    }
    if (child.stdout) |f| {
        var reader = Io.File.Reader.initStreaming(f, io, &out_buf);
        while (reader.interface.takeByte()) |b| {
            try collected.append(allocator, b);
            if (collected.items.len >= 8_000) break;
        } else |_| {}
    }
    const term = child.wait(io) catch {
        collected.deinit(allocator);
        return .{ .ok = false, .out = try allocator.dupe(u8, "") };
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .out = try collected.toOwnedSlice(allocator) };
}

fn porcelainDirty(allocator: std.mem.Allocator, io: Io, workspace: []const u8) !bool {
    const r = try runGit(allocator, io, workspace, &.{ "git", "status", "--porcelain" });
    defer allocator.free(r.out);
    if (!r.ok) return false;
    return std.mem.trim(u8, r.out, " \t\r\n").len != 0;
}

fn headSha(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    const r = try runGit(allocator, io, workspace, &.{ "git", "rev-parse", "HEAD" });
    if (!r.ok) {
        allocator.free(r.out);
        return allocator.dupe(u8, "");
    }
    const t = std.mem.trim(u8, r.out, " \t\r\n");
    const copy = try allocator.dupe(u8, t);
    allocator.free(r.out);
    return copy;
}

fn writeSha(allocator: std.mem.Allocator, io: Io, workspace: []const u8, sha: []const u8) void {
    if (sha.len == 0) return;
    const full = std.fs.path.join(allocator, &.{ workspace, sha_rel }) catch return;
    defer allocator.free(full);
    if (std.fs.path.dirname(full)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch return;
    }
    var file = Io.Dir.cwd().createFile(io, full, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(sha) catch return;
    w.interface.writeAll("\n") catch return;
    w.interface.flush() catch return;
}

fn readSha(allocator: std.mem.Allocator, io: Io, workspace: []const u8) []u8 {
    const full = std.fs.path.join(allocator, &.{ workspace, sha_rel }) catch return allocator.dupe(u8, "") catch return &.{};
    defer allocator.free(full);
    return Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(80)) catch allocator.dupe(u8, "") catch return &.{};
}

fn clearSha(allocator: std.mem.Allocator, io: Io, workspace: []const u8) void {
    const full = std.fs.path.join(allocator, &.{ workspace, sha_rel }) catch return;
    defer allocator.free(full);
    Io.Dir.cwd().deleteFile(io, full) catch {};
}

fn commitAll(allocator: std.mem.Allocator, io: Io, workspace: []const u8, message: []const u8) !bool {
    const add = try runGit(allocator, io, workspace, &.{ "git", "add", "-A" });
    defer allocator.free(add.out);
    if (!add.ok) return false;
    const msg = try std.fmt.allocPrint(allocator, "{s}{s}", .{ message, trailer });
    defer allocator.free(msg);
    const c = try runGit(allocator, io, workspace, &.{ "git", "commit", "-m", msg });
    defer allocator.free(c.out);
    if (!c.ok) return false;
    const sha = try headSha(allocator, io, workspace);
    defer allocator.free(sha);
    writeSha(allocator, io, workspace, sha);
    return true;
}

var dirty_done: bool = false;

/// Reset per process when settings flip; dirty snapshot once per enablement window.
pub fn resetDirtyFlag() void {
    dirty_done = false;
}

/// Call before a mutating tool writes. Snapshots a dirty tree once (dirty-commit).
pub fn beforeMutate(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    home: []const u8,
) void {
    if (!hasGit(io, workspace)) return;
    var cfg = settings.load(allocator, io, home);
    defer cfg.deinit(allocator);
    if (!settings.gitAutoOn(cfg)) return;
    if (!settings.gitDirtyOn(cfg)) return;
    if (dirty_done) return;
    dirty_done = true;
    const dirty = porcelainDirty(allocator, io, workspace) catch false;
    if (!dirty) return;
    _ = commitAll(allocator, io, workspace, "omfx: snapshot dirty tree") catch |err| {
        log.warn("dirty commit: {s}", .{@errorName(err)});
    };
}

/// Call after a successful mutating tool. Commits the AI edit when git_auto is on.
pub fn afterMutate(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    home: []const u8,
    paths_hint: []const u8,
) void {
    if (!hasGit(io, workspace)) return;
    var cfg = settings.load(allocator, io, home);
    defer cfg.deinit(allocator);
    if (!settings.gitAutoOn(cfg)) return;

    const dirty_now = porcelainDirty(allocator, io, workspace) catch false;
    if (!dirty_now) return;
    const hint = if (paths_hint.len == 0) "edit" else paths_hint;
    var msg_buf: [200]u8 = undefined;
    const clipped = if (hint.len > 160) hint[0..160] else hint;
    const msg = std.fmt.bufPrint(&msg_buf, "omfx: {s}", .{clipped}) catch "omfx: edit";
    _ = commitAll(allocator, io, workspace, msg) catch |err| {
        log.warn("auto commit: {s}", .{@errorName(err)});
    };
}

/// If HEAD is the last omfx auto-commit, reset it. Returns a short note or "".
pub fn undoOmfxCommit(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    if (!hasGit(io, workspace)) return allocator.dupe(u8, "");
    const recorded = readSha(allocator, io, workspace);
    defer if (recorded.len > 0) allocator.free(recorded);
    const want = std.mem.trim(u8, recorded, " \t\r\n");
    if (want.len == 0) return allocator.dupe(u8, "");
    const head = try headSha(allocator, io, workspace);
    defer allocator.free(head);
    if (!std.mem.eql(u8, head, want)) return allocator.dupe(u8, "");
    const r = try runGit(allocator, io, workspace, &.{ "git", "reset", "--hard", "HEAD~1" });
    defer allocator.free(r.out);
    if (!r.ok) return allocator.dupe(u8, "");
    clearSha(allocator, io, workspace);
    return allocator.dupe(u8, "git: reset last omfx commit\n");
}

test "hasGit false for empty path" {
    try std.testing.expect(!hasGit(std.testing.io, "/no/such/omfx/git/work"));
}
