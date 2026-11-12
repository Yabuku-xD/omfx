const std = @import("std");
const Io = std.Io;

pub const Access = struct {
    workspace: []const u8,
    /// Full read/write roots (e.g. `/workspace add`).
    extra: []const []const u8 = &.{},
    /// Read-only roots (home skill dirs). Writes still need workspace/extra.
    read_extra: []const []const u8 = &.{},

    pub fn allows(self: Access, requested: []const u8) error{PathEscape}!void {
        if (requested.len == 0) return error.PathEscape;
        if (std.fs.path.isAbsolute(requested)) {
            if (isPrefix(self.workspace, requested)) return;
            for (self.extra) |root| {
                if (isPrefix(root, requested)) return;
            }
            return error.PathEscape;
        }
        var it = std.mem.splitScalar(u8, requested, '/');
        var depth: i32 = 0;
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                depth -= 1;
                if (depth < 0) return error.PathEscape;
            } else {
                depth += 1;
            }
        }
    }

    /// Workspace / extra writes, plus skill roots for following `/skill`.
    pub fn allowsRead(self: Access, requested: []const u8) error{PathEscape}!void {
        if (self.allows(requested)) |_| return else |_| {}
        if (requested.len == 0 or !std.fs.path.isAbsolute(requested)) return error.PathEscape;
        for (self.read_extra) |root| {
            if (isPrefix(root, requested)) return;
        }
        return error.PathEscape;
    }
};

pub fn assertInside(access: Access, requested: []const u8) error{PathEscape}!void {
    return access.allows(requested);
}

pub const Need = enum { read, write };

/// The lexical checks above see `notes.txt`; the kernel follows the symlink
/// it names to `~/.ssh/id_ed25519`. This resolves what the path actually
/// reaches and holds it to the same roots and secret rules. A path that does
/// not exist yet (a new file) is judged by its deepest existing ancestor, and
/// a dangling symlink is refused outright: creating through it would write
/// wherever it points.
///
/// One exception keeps skills working: a read under a skill root that lives
/// outside the workspace (`~/.claude/skills`, `~/.codex/skills`, ...) may follow
/// links anywhere except to a secret. Those roots belong to the user, who
/// commonly links them into `~/.agents`. A link inside the workspace -- one a
/// cloned repository could have planted -- gets no such trust.
pub fn assertResolved(dir: Io.Dir, io: Io, access: Access, requested: []const u8, need: Need) error{ PathEscape, SymlinkEscape }!void {
    if (need == .read) try access.allowsRead(requested) else try access.allows(requested);
    const open_dir = if (std.fs.path.isAbsolute(requested)) Io.Dir.cwd() else dir;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var probe: []const u8 = requested;
    const real = while (true) {
        const sub = if (probe.len == 0) "." else probe;
        if (open_dir.realPathFile(io, sub, &buf)) |n| break buf[0..n] else |err| switch (err) {
            error.FileNotFound => {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (open_dir.readLink(io, sub, &link_buf)) |_| return error.SymlinkEscape else |_| {}
                if (probe.len == 0) return;
                probe = std.fs.path.dirname(probe) orelse "";
            },
            // Anything else (permissions, name too long) fails the real open
            // that follows with a clearer error than an escape would give.
            else => return,
        }
    };

    if (isSecret(real) and !isSecret(requested)) return error.SymlinkEscape;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.realPath(io, &root_buf)) |n| {
        if (isPrefix(root_buf[0..n], real)) return;
    } else |_| {}
    if (std.fs.path.isAbsolute(access.workspace) and resolvedUnder(io, access.workspace, real)) return;
    for (access.extra) |root| {
        if (resolvedUnder(io, root, real)) return;
    }
    if (need == .read) for (access.read_extra) |root| {
        if (resolvedUnder(io, root, real)) return;
        const user_root = std.fs.path.isAbsolute(root) and
            !(std.fs.path.isAbsolute(access.workspace) and isPrefix(access.workspace, root));
        if (user_root and isPrefix(root, requested)) return;
    };
    return error.SymlinkEscape;
}

/// What the model is told when a link is refused, so it picks a real path
/// instead of retrying the same one.
pub const symlink_escape_hint =
    "tool error: SymlinkEscape. That path is a symlink (or sits under one) that leads outside the workspace, " ++
    "to a secret, or nowhere. omfx does not follow it. Use the real path inside the workspace, or ask the user to add the target with /workspace add.";

fn resolvedUnder(io: Io, root: []const u8, real: []const u8) bool {
    if (!std.fs.path.isAbsolute(root)) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.realPathFileAbsolute(io, root, &buf) catch return isPrefix(root, real);
    return isPrefix(buf[0..n], real);
}

pub fn assertReadable(access: Access, requested: []const u8) error{PathEscape}!void {
    return access.allowsRead(requested);
}

fn isPrefix(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == std.fs.path.sep or path[root.len] == '/';
}

const SecretRule = union(enum) {
    allow_base: []const u8,
    base_exact: []const u8,
    base_prefix: []const u8,
    base_suffix: []const u8,
    path_has: []const u8,
    path_prefix: []const u8,
};

const secret_rules = [_]SecretRule{
    .{ .allow_base = ".env.example" },
    .{ .allow_base = ".env.sample" },
    .{ .base_exact = ".env" },
    .{ .base_prefix = ".env." },
    .{ .path_has = ".omfx/auth.json" },
    .{ .path_has = "/.ssh/" },
    .{ .path_prefix = ".ssh/" },
    .{ .path_has = "/.gnupg/" },
    .{ .base_exact = "id_rsa" },
    .{ .base_exact = "id_ed25519" },
    .{ .base_suffix = ".pem" },
};

/// `.env` is secret. `.env.example` is documentation.
pub fn isSecret(requested: []const u8) bool {
    const base = std.fs.path.basename(requested);
    var denied = false;
    for (secret_rules) |rule| {
        switch (rule) {
            .allow_base => |n| {
                if (std.mem.eql(u8, base, n)) return false;
            },
            .base_exact => |n| {
                if (std.mem.eql(u8, base, n)) denied = true;
            },
            .base_prefix => |n| {
                if (std.mem.startsWith(u8, base, n)) denied = true;
            },
            .base_suffix => |n| {
                if (std.mem.endsWith(u8, base, n)) denied = true;
            },
            .path_has => |n| {
                if (std.mem.indexOf(u8, requested, n) != null) denied = true;
            },
            .path_prefix => |n| {
                if (std.mem.startsWith(u8, requested, n)) denied = true;
            },
        }
    }
    return denied;
}

pub fn joinWorkspace(allocator: std.mem.Allocator, access: Access, requested: []const u8) ![]u8 {
    try assertInside(access, requested);
    if (std.fs.path.isAbsolute(requested)) return allocator.dupe(u8, requested);
    return std.fs.path.join(allocator, &.{ access.workspace, requested });
}

test "relative escape is denied" {
    const access: Access = .{ .workspace = "/tmp/ws" };
    try std.testing.expectError(error.PathEscape, assertInside(access, "../secret"));
    try std.testing.expectError(error.PathEscape, assertInside(access, "a/../../b"));
}

test "workspace relative is allowed" {
    const access: Access = .{ .workspace = "/tmp/ws" };
    try assertInside(access, "src/main.zig");
    try assertInside(access, "./foo");
}

test "extra roots allow an absolute path" {
    const access: Access = .{ .workspace = "/tmp/ws", .extra = &.{"/tmp/other"} };
    try assertInside(access, "/tmp/other/a.txt");
    try std.testing.expectError(error.PathEscape, assertInside(access, "/tmp/secret/a.txt"));
}

test "read_extra allows skill path without write" {
    const access: Access = .{
        .workspace = "/tmp/ws",
        .read_extra = &.{"/home/u/.agents/skills"},
    };
    try assertReadable(access, "/home/u/.agents/skills/deslop/SKILL.md");
    try std.testing.expectError(
        error.PathEscape,
        assertInside(access, "/home/u/.agents/skills/deslop/SKILL.md"),
    );
    try std.testing.expectError(error.PathEscape, assertReadable(access, "/home/u/.ssh/id"));
}

test "env files are secret except examples" {
    try std.testing.expect(isSecret(".env"));
    try std.testing.expect(isSecret("src/.env.local"));
    try std.testing.expect(!isSecret(".env.example"));
    try std.testing.expect(!isSecret("src/config.zig"));
    try std.testing.expect(isSecret("/home/u/.omfx/auth.json"));
    try std.testing.expect(isSecret("/home/u/.ssh/id_ed25519"));
    try std.testing.expect(!isSecret("src/auth.json"));
}

test "a symlink out of the workspace is refused even though its name is inside" {
    const io = std.testing.io;
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    var ws = std.testing.tmpDir(.{});
    defer ws.cleanup();
    {
        var f = try outside.dir.createFile(io, "private.txt", .{});
        f.close(io);
    }
    const target = try outside.dir.realPathFileAlloc(io, "private.txt", std.testing.allocator);
    defer std.testing.allocator.free(target);
    try ws.dir.symLink(io, target, "notes.txt", .{});
    try ws.dir.symLink(io, "/nonexistent/omfx-dangling", "dangling.txt", .{});
    {
        var f = try ws.dir.createFile(io, "real.txt", .{});
        f.close(io);
    }
    try ws.dir.symLink(io, "real.txt", "alias.txt", .{});
    try ws.dir.symLink(io, ".env", "harmless.txt", .{});
    {
        var f = try ws.dir.createFile(io, ".env", .{});
        f.close(io);
    }

    const access: Access = .{ .workspace = "ws" };
    try std.testing.expectError(error.SymlinkEscape, assertResolved(ws.dir, io, access, "notes.txt", .read));
    try std.testing.expectError(error.SymlinkEscape, assertResolved(ws.dir, io, access, "notes.txt", .write));
    try std.testing.expectError(error.SymlinkEscape, assertResolved(ws.dir, io, access, "dangling.txt", .write));
    try std.testing.expectError(error.SymlinkEscape, assertResolved(ws.dir, io, access, "harmless.txt", .read));
    try assertResolved(ws.dir, io, access, "alias.txt", .read);
    try assertResolved(ws.dir, io, access, "real.txt", .write);
    try assertResolved(ws.dir, io, access, "new/dir/file.txt", .write);
    try std.testing.expectError(error.PathEscape, assertResolved(ws.dir, io, access, "../x", .read));
}

test "a home skill root may link out; a workspace skill root may not" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var agents = std.testing.tmpDir(.{});
    defer agents.cleanup();
    var home_skills = std.testing.tmpDir(.{});
    defer home_skills.cleanup();
    var ws = std.testing.tmpDir(.{});
    defer ws.cleanup();
    try agents.dir.createDirPath(io, "deslop");
    {
        var f = try agents.dir.createFile(io, "deslop/SKILL.md", .{});
        f.close(io);
    }
    const target = try agents.dir.realPathFileAlloc(io, "deslop", a);
    defer a.free(target);
    const home_root = try home_skills.dir.realPathFileAlloc(io, ".", a);
    defer a.free(home_root);
    try home_skills.dir.symLink(io, target, "deslop", .{});
    const ws_root = try ws.dir.realPathFileAlloc(io, ".", a);
    defer a.free(ws_root);
    try ws.dir.createDirPath(io, ".claude/skills");
    try ws.dir.symLink(io, target, ".claude/skills/deslop", .{});
    const ws_skills = try std.fs.path.join(a, &.{ ws_root, ".claude/skills" });
    defer a.free(ws_skills);

    const access: Access = .{ .workspace = ws_root, .read_extra = &.{ ws_skills, home_root } };
    const via_home = try std.fs.path.join(a, &.{ home_root, "deslop/SKILL.md" });
    defer a.free(via_home);
    try assertResolved(ws.dir, io, access, via_home, .read);
    try std.testing.expectError(error.PathEscape, assertResolved(ws.dir, io, access, via_home, .write));
    try std.testing.expectError(
        error.SymlinkEscape,
        assertResolved(ws.dir, io, access, ".claude/skills/deslop/SKILL.md", .read),
    );
}

/// A scratch workspace unique to this test run.
///
/// Tests used to hard-code paths like `/tmp/omfx-skills-list-ws`, which two
/// concurrent suite runs share -- and which survive a crashed run as litter the
/// next one inherits. `tmpDir` is per-run and cleaned up by its own `deinit`.
///
/// Caller owns the returned path and must `tmp.cleanup()`.
pub fn testWorkspace(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}
