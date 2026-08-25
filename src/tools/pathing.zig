const std = @import("std");

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
