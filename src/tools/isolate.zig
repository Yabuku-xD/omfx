const std = @import("std");
const deadline = @import("deadline.zig");

const log = std.log.scoped(.isolate);

/// A worktree on a large repo is slow, but not minutes-slow.
pub const worktree_secs: u32 = 60;
const Io = std.Io;

/// Lazy git worktree for a peer. No .git → parent. git worktree fail → parent.
pub const max_slot: u8 = 8;

comptime {
    if (max_slot == 0) @compileError("max_slot must name at least one peer tree");
}

pub const Place = union(enum) {
    parent,
    tree: []u8,

    pub fn workspace(self: Place, parent: []const u8) []const u8 {
        return switch (self) {
            .parent => parent,
            .tree => |p| p,
        };
    }

    pub fn deinit(self: Place, allocator: std.mem.Allocator) void {
        switch (self) {
            .parent => {},
            .tree => |p| allocator.free(p),
        }
    }
};

pub const Open = union(enum) {
    borrow: Io.Dir,
    owned: Io.Dir,

    pub fn dir(self: Open) Io.Dir {
        return switch (self) {
            .borrow, .owned => |d| d,
        };
    }

    pub fn deinit(self: Open, io: Io) void {
        switch (self) {
            .borrow => {},
            .owned => |d| d.close(io),
        }
    }
};

const Git = union(enum) {
    none,
    repo,
};

fn gitOf(dir: Io.Dir, io: Io) Git {
    if (dir.openDir(io, ".git", .{})) |d| {
        d.close(io);
        return .repo;
    } else |_| {}
    if (dir.openFile(io, ".git", .{ .mode = .read_only })) |f| {
        f.close(io);
        return .repo;
    } else |_| {}
    return .none;
}

fn drain(io: Io, file: Io.File) void {
    var buf: [256]u8 = undefined;
    var reader = Io.File.Reader.initStreaming(file, io, &buf);
    while (reader.interface.takeByte()) |_| {} else |_| {}
}

fn waitQuiet(io: Io, child: *std.process.Child) void {
    if (child.stdout) |f| drain(io, f);
    if (child.stderr) |f| drain(io, f);
    _ = child.wait(io) catch child.kill(io);
}

pub fn forPeer(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    slot: u8,
) !Place {
    switch (gitOf(dir, io)) {
        .none => return .parent,
        .repo => {},
    }
    const n = if (slot == 0 or slot > max_slot) @as(u8, 1) else slot;
    dir.createDirPath(io, ".omfx/peers") catch |err| {
        log.warn("mkdir .omfx/peers: {s}", .{@errorName(err)});
    };
    const rel = try std.fmt.allocPrint(allocator, ".omfx/peers/p{d}", .{n});
    defer allocator.free(rel);
    const joined = try std.fs.path.join(allocator, &.{ workspace, rel });
    errdefer allocator.free(joined);
    if (dir.openDir(io, rel, .{})) |d| {
        d.close(io);
        return .{ .tree = joined };
    } else |_| {}
    var cap: deadline.Capped = undefined;
    cap.init(&.{ "git", "-C", workspace, "worktree", "add", "--detach", joined }, worktree_secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        allocator.free(joined);
        return .parent;
    };
    waitQuiet(io, &child);
    if (dir.openDir(io, rel, .{})) |d| {
        d.close(io);
        return .{ .tree = joined };
    } else |_| {
        allocator.free(joined);
        return .parent;
    }
}

pub fn forFork(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    id: []const u8,
) !Place {
    switch (gitOf(dir, io)) {
        .none => return .parent,
        .repo => {},
    }
    dir.createDirPath(io, ".omfx/forks") catch |err| {
        log.warn("mkdir .omfx/forks: {s}", .{@errorName(err)});
    };
    const rel = try std.fmt.allocPrint(allocator, ".omfx/forks/{s}", .{id});
    defer allocator.free(rel);
    const joined = try std.fs.path.join(allocator, &.{ workspace, rel });
    errdefer allocator.free(joined);
    if (dir.openDir(io, rel, .{})) |d| {
        d.close(io);
        return .{ .tree = joined };
    } else |_| {}
    var cap: deadline.Capped = undefined;
    cap.init(&.{ "git", "-C", workspace, "worktree", "add", "--detach", joined }, worktree_secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        allocator.free(joined);
        return .parent;
    };
    waitQuiet(io, &child);
    if (dir.openDir(io, rel, .{})) |d| {
        d.close(io);
        return .{ .tree = joined };
    } else |_| {
        allocator.free(joined);
        return .parent;
    }
}

pub fn open(place: Place, io: Io, parent: Io.Dir) Open {
    return switch (place) {
        .parent => .{ .borrow = parent },
        .tree => |p| blk: {
            const d = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch break :blk .{ .borrow = parent };
            break :blk .{ .owned = d };
        },
    };
}

test "no git stays parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try forPeer(std.testing.allocator, tmp.dir, std.testing.io, "ws", 1);
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(p == .parent);
    const opened = open(p, std.testing.io, tmp.dir);
    defer opened.deinit(std.testing.io);
    try std.testing.expect(opened == .borrow);
}
