//! Thin three-file specs on disk; orientation gets only a pointer, never the bodies.

const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.spec);

pub const specs_dir = ".omfx/specs";
const active_name = ".omfx/specs/.active";

pub const Phase = enum {
    requirements,
    design,
    tasks,
    execute,

    pub fn fromSlice(s: []const u8) ?Phase {
        return std.meta.stringToEnum(Phase, s);
    }

    pub fn asSlice(self: Phase) []const u8 {
        return @tagName(self);
    }

    pub fn next(self: Phase) ?Phase {
        return switch (self) {
            .requirements => .design,
            .design => .tasks,
            .tasks => .execute,
            .execute => null,
        };
    }
};

pub const Active = struct {
    name: []const u8,
    phase: Phase,
};

fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

pub fn dirPath(allocator: std.mem.Allocator, workspace: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace, specs_dir, name });
}

pub fn filePath(allocator: std.mem.Allocator, workspace: []const u8, name: []const u8, file: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace, specs_dir, name, file });
}

const req_stub =
    \\# Requirements
    \\
    \\## Goal
    \\
    \\(describe the feature)
    \\
    \\## Acceptance (EARS)
    \\
    \\- WHEN … THE SYSTEM SHALL …
    \\
;

const design_stub =
    \\# Design
    \\
    \\## Approach
    \\
    \\(architecture and key decisions)
    \\
    \\## Files
    \\
    \\- path — why
    \\
;

const tasks_stub =
    \\# Tasks
    \\
    \\- [ ] 1. …
    \\- [ ] 2. …
    \\
;

pub fn create(allocator: std.mem.Allocator, io: Io, workspace: []const u8, name: []const u8) ![]u8 {
    if (!safeName(name)) return error.BadName;
    const dir = try dirPath(allocator, workspace, name);
    defer allocator.free(dir);
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.warn("mkdir spec: {s}", .{@errorName(err)});
        return err;
    };
    try writeIfMissing(allocator, io, workspace, name, "requirements.md", req_stub);
    try writeIfMissing(allocator, io, workspace, name, "design.md", design_stub);
    try writeIfMissing(allocator, io, workspace, name, "tasks.md", tasks_stub);
    try setActive(allocator, io, workspace, .{ .name = name, .phase = .requirements });
    return std.fmt.allocPrint(allocator, "spec {s}\nphase=requirements\n{s}/{s}/\n", .{ name, specs_dir, name });
}

fn writeIfMissing(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    name: []const u8,
    file: []const u8,
    body: []const u8,
) !void {
    const p = try filePath(allocator, workspace, name, file);
    defer allocator.free(p);
    if (Io.Dir.cwd().openFile(io, p, .{ .mode = .read_only })) |f| {
        f.close(io);
        return;
    } else |_| {}
    var out = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
    defer out.close(io);
    var buf: [512]u8 = undefined;
    var w = out.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

pub fn setActive(allocator: std.mem.Allocator, io: Io, workspace: []const u8, active: Active) !void {
    if (!safeName(active.name)) return error.BadName;
    const full = try std.fs.path.join(allocator, &.{ workspace, active_name });
    defer allocator.free(full);
    if (std.fs.path.dirname(full)) |d| {
        Io.Dir.cwd().createDirPath(io, d) catch {};
    }
    const body = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ active.name, active.phase.asSlice() });
    defer allocator.free(body);
    var file = try Io.Dir.cwd().createFile(io, full, .{ .truncate = true });
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

pub fn loadActive(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ?Active {
    const full = std.fs.path.join(allocator, &.{ workspace, active_name }) catch return null;
    defer allocator.free(full);
    const raw = Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(256)) catch return null;
    defer allocator.free(raw);
    var it = std.mem.splitScalar(u8, raw, '\n');
    const name = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    const phase_s = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    if (!safeName(name)) return null;
    const phase = Phase.fromSlice(phase_s) orelse return null;
    return .{ .name = allocator.dupe(u8, name) catch return null, .phase = phase };
}

pub fn clearActive(allocator: std.mem.Allocator, io: Io, workspace: []const u8) void {
    const full = std.fs.path.join(allocator, &.{ workspace, active_name }) catch return;
    defer allocator.free(full);
    Io.Dir.cwd().deleteFile(io, full) catch {};
}

pub fn advance(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    const cur = loadActive(allocator, io, workspace) orelse
        return allocator.dupe(u8, "No active spec. /spec new <name> or /spec <name>.\n");
    defer allocator.free(cur.name);
    const n = cur.phase.next() orelse {
        return std.fmt.allocPrint(allocator, "spec {s} already in execute\n", .{cur.name});
    };
    try setActive(allocator, io, workspace, .{ .name = cur.name, .phase = n });
    return std.fmt.allocPrint(allocator, "spec {s}\nphase={s}\n", .{ cur.name, n.asSlice() });
}

pub fn list(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    const root = try std.fs.path.join(allocator, &.{ workspace, specs_dir });
    defer allocator.free(root);
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        return allocator.dupe(u8, "No specs yet. /spec new <name>\n");
    };
    defer dir.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        try out.print(allocator, "{s}\n", .{entry.name});
        n += 1;
    }
    if (n == 0) return allocator.dupe(u8, "No specs yet. /spec new <name>\n");
    return out.toOwnedSlice(allocator);
}

fn firstOpenTask(allocator: std.mem.Allocator, io: Io, workspace: []const u8, name: []const u8) []u8 {
    const p = filePath(allocator, workspace, name, "tasks.md") catch return allocator.dupe(u8, "") catch return &.{};
    defer allocator.free(p);
    const body = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(16_000)) catch return allocator.dupe(u8, "") catch return &.{};
    defer allocator.free(body);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len < 5 or t[0] != '-') continue;
        const open = std.mem.indexOf(u8, t, "[ ]") orelse continue;
        const rest = std.mem.trim(u8, t[open + 3 ..], " \t");
        if (rest.len == 0) continue;
        const clip = if (rest.len > 120) rest[0..120] else rest;
        return allocator.dupe(u8, clip) catch return &.{};
    }
    return allocator.dupe(u8, "") catch return &.{};
}

pub fn orientationLine(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    const cur = loadActive(allocator, io, workspace) orelse return allocator.dupe(u8, "");
    defer allocator.free(cur.name);
    const task = firstOpenTask(allocator, io, workspace, cur.name);
    defer if (task.len > 0) allocator.free(task);
    if (task.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "spec={s} phase={s} (read .{s}/{s}/; do not dump full docs into chat)\n",
            .{ cur.name, cur.phase.asSlice(), specs_dir, cur.name },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "spec={s} phase={s} task={s}\n",
        .{ cur.name, cur.phase.asSlice(), task },
    );
}

pub fn resumeNamed(allocator: std.mem.Allocator, io: Io, workspace: []const u8, name: []const u8) ![]u8 {
    if (!safeName(name)) return error.BadName;
    const dir = try dirPath(allocator, workspace, name);
    defer allocator.free(dir);
    var d = Io.Dir.cwd().openDir(io, dir, .{}) catch {
        return std.fmt.allocPrint(allocator, "no such spec: {s}\n", .{name});
    };
    d.close(io);
    try setActive(allocator, io, workspace, .{ .name = name, .phase = .requirements });
    return std.fmt.allocPrint(allocator, "spec {s}\nphase=requirements\n", .{name});
}

test "safeName rejects path tricks" {
    try std.testing.expect(safeName("auth"));
    try std.testing.expect(!safeName("../x"));
    try std.testing.expect(!safeName("a b"));
}

test "phase next walks to execute" {
    try std.testing.expectEqual(Phase.design, Phase.requirements.next().?);
    try std.testing.expectEqual(Phase.execute, Phase.tasks.next().?);
    try std.testing.expect(Phase.execute.next() == null);
}
