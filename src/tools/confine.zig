const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.confine);

/// Cap on captured command output. Named so a hit is diagnosable.
pub const out_cap: usize = 32_000;

comptime {
    if (out_cap == 0) @compileError("out_cap must hold command output");
}

/// linux/landlock.h — write-side bits only. Reads stay unrestricted.
const FsWrite = packed struct(u64) {
    execute: bool = false,
    write_file: bool = true,
    read_file: bool = false,
    read_dir: bool = false,
    remove_dir: bool = true,
    remove_file: bool = true,
    make_char: bool = true,
    make_dir: bool = true,
    make_reg: bool = true,
    make_sock: bool = true,
    make_fifo: bool = true,
    make_block: bool = true,
    make_sym: bool = true,
    refer: bool = false,
    truncate: bool = true,
    ioctl_dev: bool = false,
    _pad: u48 = 0,

    fn bits(self: FsWrite) u64 {
        return @bitCast(self);
    }
};

const fs_write: FsWrite = .{};

const Sys = enum(usize) {
    create = 444,
    add = 445,
    restrict_self = 446,

    fn asLinux(self: Sys) std.os.linux.SYS {
        return @enumFromInt(@intFromEnum(self));
    }
};

const RulesetAttr = extern struct {
    handled_access_fs: u64,
    handled_access_net: u64 = 0,
};

const PathBeneath = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};

pub const EnvClass = enum { keep, secret };

pub fn envClass(name: []const u8) EnvClass {
    if (name.len == 0) return .keep;
    if (std.mem.eql(u8, name, "AUTHORIZATION")) return .secret;
    if (std.mem.endsWith(u8, name, "_API_KEY")) return .secret;
    if (std.mem.endsWith(u8, name, "_ACCESS_TOKEN")) return .secret;
    if (std.mem.endsWith(u8, name, "_OAUTH_TOKEN")) return .secret;
    if (std.mem.endsWith(u8, name, "_SECRET")) return .secret;
    return .keep;
}

pub fn secretEnv(name: []const u8) bool {
    return envClass(name) == .secret;
}

/// Seatbelt: allow-default, workspace-write, net-deny, secret-read deny.
pub fn macSeatbelt(allocator: std.mem.Allocator, workspace: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\(version 1)
        \\(allow default)
        \\(deny file-write*)
        \\(allow file-write* (subpath "{s}") (subpath "/tmp") (subpath "/private/tmp") (subpath "/var/tmp"))
        \\(deny file-read* (regex "\\.ssh/") (regex "\\.gnupg/") (regex "\\.omfx/auth\\.json"))
        \\(deny network*)
        \\
    ,
        .{workspace},
    );
}

fn linuxFd(rc: usize) ?i32 {
    const signed: i64 = @bitCast(rc);
    if (signed < 0) return null;
    return @intCast(signed);
}

pub fn landlockSupported() bool {
    if (builtin.os.tag != .linux) return false;
    var attr = RulesetAttr{ .handled_access_fs = fs_write.bits() };
    const fd = linuxFd(std.os.linux.syscall2(Sys.create.asLinux(), @intFromPtr(&attr), @sizeOf(RulesetAttr))) orelse return false;
    _ = std.os.linux.close(fd);
    return true;
}

fn addBeneath(ruleset: i32, path: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const z = posix.toPosixPath(path) catch return;
    const opened = linuxFd(std.os.linux.open(&z, .{ .ACCMODE = .RDONLY, .PATH = true, .DIRECTORY = true }, 0)) orelse return;
    defer _ = std.os.linux.close(opened);
    var beneath = PathBeneath{
        .allowed_access = fs_write.bits(),
        .parent_fd = opened,
    };
    _ = std.os.linux.syscall3(Sys.add.asLinux(), @intCast(ruleset), 1, @intFromPtr(&beneath));
}

/// Child-only, before exec. Best-effort: missing Landlock still unshares net.
pub fn applyLinux(workspace: []const u8) void {
    if (builtin.os.tag != .linux) return;
    var attr = RulesetAttr{ .handled_access_fs = fs_write.bits() };
    if (linuxFd(std.os.linux.syscall2(Sys.create.asLinux(), @intFromPtr(&attr), @sizeOf(RulesetAttr)))) |ruleset| {
        addBeneath(ruleset, workspace);
        addBeneath(ruleset, "/tmp");
        addBeneath(ruleset, "/var/tmp");
        _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
        _ = std.os.linux.syscall2(Sys.restrict_self.asLinux(), @intCast(ruleset), 0);
        _ = std.os.linux.close(ruleset);
    }
    _ = std.os.linux.unshare(std.os.linux.CLONE.NEWNET);
}

fn collectFd(allocator: std.mem.Allocator, fd: posix.fd_t) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => |e| {
                log.warn("read: {s}", .{@errorName(e)});
                break;
            },
        };
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
        if (out.items.len >= out_cap) {
            const note = try std.fmt.allocPrint(allocator, "\ntruncated at {d} bytes (confine.out_cap)\n", .{out_cap});
            defer allocator.free(note);
            try out.appendSlice(allocator, note);
            break;
        }
    }
    if (out.items.len == 0) return allocator.dupe(u8, "(no output)");
    return out.toOwnedSlice(allocator);
}

pub const Run = union(enum) {
    body: []u8,
    skip,
};

/// Fork, Landlock+unshare in the child, exec shell -c. `.skip` means try bwrap.
/// std.posix lost the process-control wrappers in Zig 0.16. libc is linked, so
/// fork/exec here goes straight through it.
const c = std.c;

fn pipeFds() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

pub fn runLinux(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    shell: []const u8,
    command: []const u8,
) Run {
    if (builtin.os.tag != .linux) return .skip;
    if (!landlockSupported()) return .skip;

    const pipe_fds = pipeFds() catch |err| {
        log.warn("pipe: {s}", .{@errorName(err)});
        return .skip;
    };
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        log.warn("fork failed", .{});
        return .skip;
    }
    if (pid == 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.dup2(pipe_fds[1], posix.STDOUT_FILENO);
        _ = c.dup2(pipe_fds[1], posix.STDERR_FILENO);
        _ = c.close(pipe_fds[1]);
        applyLinux(workspace);
        const shell_z = allocator.dupeZ(u8, shell) catch c._exit(127);
        const cmd_z = allocator.dupeZ(u8, command) catch c._exit(127);
        const argv = [_:null]?[*:0]const u8{ shell_z.ptr, "-c", cmd_z.ptr, null };
        _ = c.execve(shell_z.ptr, &argv, c.environ);
        c._exit(127);
    }
    _ = c.close(pipe_fds[1]);
    const body = collectFd(allocator, pipe_fds[0]) catch |err| {
        _ = c.close(pipe_fds[0]);
        _ = c.waitpid(pid, null, 0);
        log.warn("collect: {s}", .{@errorName(err)});
        return .skip;
    };
    _ = c.close(pipe_fds[0]);
    _ = c.waitpid(pid, null, 0);
    return .{ .body = body };
}

test "secret env names" {
    try std.testing.expectEqual(EnvClass.secret, envClass("XAI_API_KEY"));
    try std.testing.expectEqual(EnvClass.secret, envClass("OPENAI_OAUTH_TOKEN"));
    try std.testing.expectEqual(EnvClass.secret, envClass("GITHUB_ACCESS_TOKEN"));
    try std.testing.expectEqual(EnvClass.keep, envClass("PATH"));
    try std.testing.expectEqual(EnvClass.keep, envClass("HOME"));
    try std.testing.expect(!secretEnv("TERM"));
}

test "seatbelt denies secrets and network" {
    const p = try macSeatbelt(std.testing.allocator, "/tmp/ws");
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "(deny network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, ".omfx/auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, ".ssh/") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "/tmp/ws") != null);
}

test "landlock probe is false on non-linux" {
    if (builtin.os.tag != .linux) {
        try std.testing.expect(!landlockSupported());
        try std.testing.expect(runLinux(std.testing.allocator, "/tmp", "/bin/sh", "true") == .skip);
    }
}

test "FsWrite write_file bit matches kernel ABI" {
    try std.testing.expectEqual(@as(u64, 1 << 1), (FsWrite{ .write_file = true, .remove_dir = false, .remove_file = false, .make_char = false, .make_dir = false, .make_reg = false, .make_sock = false, .make_fifo = false, .make_block = false, .make_sym = false, .truncate = false }).bits());
    try std.testing.expectEqual(@as(u64, 1 << 4), (FsWrite{ .write_file = false, .remove_dir = true, .remove_file = false, .make_char = false, .make_dir = false, .make_reg = false, .make_sock = false, .make_fifo = false, .make_block = false, .make_sym = false, .truncate = false }).bits());
}
