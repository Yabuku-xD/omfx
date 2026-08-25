const std = @import("std");
const Io = std.Io;
const fs = @import("../fs.zig");
const undo = @import("../undo.zig");
const git_work = @import("../git_work.zig");
const search = @import("../search.zig");
const pathing = @import("../pathing.zig");
const recall = @import("../../core/recall.zig");
const hooks = @import("../../core/hooks.zig");
const tool = @import("../../core/tool.zig");
const Args = @import("args.zig").Args;

pub fn run(
    kind: tool.Name,
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    home: []const u8,
    args: Args,
    args_json: []const u8,
) ![]u8 {
    const workspace = access.workspace;
    return switch (kind) {
        .read => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            const offset = args.usize_("offset") orelse 0;
            const limit = args.usize_("limit") orelse 0;
            if (recall.idFromPath(path)) |rid| {
                const raw = recall.load(allocator, dir, io, rid) catch
                    break :blk try std.fmt.allocPrint(allocator, "missing {s}\n", .{path});
                defer allocator.free(raw);
                if (hooks.hasSecret(raw)) {
                    break :blk try allocator.dupe(u8, "read_result: sensitive; not shown\n");
                }
                const masked = try hooks.mask(allocator, raw);
                defer allocator.free(masked);
                break :blk try fs.numberLines(allocator, path, masked, offset, limit);
            }
            const raw = fs.read(dir, io, allocator, access, path) catch |err| switch (err) {
                error.NotAFile => break :blk try fs.readDirHint(dir, io, allocator, access, path),
                else => return err,
            };
            defer allocator.free(raw);
            const body = try fs.numberLines(allocator, path, raw, offset, limit);
            errdefer allocator.free(body);
            const symbols = @import("../symbols.zig");
            const prefix = try symbols.outlinePrefix(allocator, path, raw);
            if (prefix.len == 0) break :blk body;
            defer allocator.free(prefix);
            const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, body });
            allocator.free(body);
            break :blk joined;
        },
        .write => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            const contents = args.str("contents") orelse "";
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordWrite(allocator, dir, io, access, path);
            try fs.write(dir, io, allocator, access, path, contents);
            git_work.afterMutate(allocator, io, workspace, home, path);
            break :blk try std.fmt.allocPrint(allocator, "wrote {s}", .{path});
        },
        .edit => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            git_work.beforeMutate(allocator, io, workspace, home);
            if (std.mem.indexOf(u8, args_json, "\"edits\"") != null) {
                const out = try editsFromJson(allocator, dir, io, access, path, args_json);
                git_work.afterMutate(allocator, io, workspace, home, path);
                break :blk out;
            }
            undo.recordWrite(allocator, dir, io, access, path);
            if (args.str("symbol")) |symbol| {
                const symbols = @import("../symbols.zig");
                const action = symbols.parseAction(args.str("action") orelse "replace") orelse return error.MissingOld;
                const text = args.str("text") orelse args.str("new_string") orelse "";
                try symbols.splice(dir, io, allocator, access, path, symbol, action, text);
                git_work.afterMutate(allocator, io, workspace, home, path);
                break :blk try std.fmt.allocPrint(allocator, "edited {s} ({s} {s})", .{ path, @tagName(action), symbol });
            }
            const old = args.str("old_string") orelse return error.MissingOld;
            const new = args.str("new_string") orelse "";
            try fs.edit(dir, io, allocator, access, path, old, new);
            git_work.afterMutate(allocator, io, workspace, home, path);
            break :blk try std.fmt.allocPrint(allocator, "edited {s}", .{path});
        },
        .glob => search.glob(
            dir,
            io,
            allocator,
            access,
            args.str("pattern") orelse "*",
            args.str("path") orelse "",
        ),
        .grep => blk: {
            const needle = args.str("pattern") orelse args.str("needle") orelse return error.EmptyNeedle;
            const g = args.str("glob") orelse "*";
            const root = args.str("path") orelse "";
            break :blk try search.grep(dir, io, allocator, access, needle, g, root);
        },
        .delete => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            try pathing.assertInside(access, path);
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordDelete(allocator, dir, io, access, path);
            dir.deleteFile(io, path) catch try dir.deleteDir(io, path);
            git_work.afterMutate(allocator, io, workspace, home, path);
            break :blk try std.fmt.allocPrint(allocator, "deleted {s}", .{path});
        },
        .rename => blk: {
            const from = args.str("from") orelse args.str("path") orelse return error.MissingPath;
            const to = args.str("to") orelse return error.MissingPath;
            if (from.len == 0 or to.len == 0) return error.MissingPath;
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordRename(allocator, dir, io, access, from, to);
            try search.rename(dir, io, access, from, to);
            git_work.afterMutate(allocator, io, workspace, home, to);
            break :blk try std.fmt.allocPrint(allocator, "renamed {s} -> {s}", .{ from, to });
        },
        .list => fs.list(dir, io, allocator, access, args.str("path") orelse "."),
        .copy => blk: {
            const from = args.str("from") orelse args.str("path") orelse return error.MissingPath;
            const to = args.str("to") orelse return error.MissingPath;
            if (from.len == 0 or to.len == 0) return error.MissingPath;
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordWrite(allocator, dir, io, access, to);
            try fs.copy(dir, io, access, from, to);
            git_work.afterMutate(allocator, io, workspace, home, to);
            break :blk try std.fmt.allocPrint(allocator, "copied {s} -> {s}", .{ from, to });
        },
        .mkdir => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            try fs.mkdir(dir, io, access, path);
            break :blk try std.fmt.allocPrint(allocator, "mkdir {s}", .{path});
        },
        .file_info => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            break :blk try fs.info(dir, io, allocator, access, path);
        },
        else => unreachable,
    };
}

fn editsFromJson(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    access: pathing.Access,
    path: []const u8,
    args_json: []const u8,
) ![]u8 {
    const patch = @import("../patch.zig");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch
        return error.BadEdits;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadEdits,
    };
    const arr = switch (root.get("edits") orelse return error.BadEdits) {
        .array => |a| a,
        else => return error.BadEdits,
    };
    if (arr.items.len == 0) return error.BadEdits;
    if (arr.items.len > patch.max_ops) return error.TooManyEdits;

    var list: [patch.max_ops]patch.Edit = undefined;
    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.BadEdits,
        };
        const old = switch (obj.get("old_string") orelse obj.get("old") orelse return error.BadEdits) {
            .string => |v| v,
            else => return error.BadEdits,
        };
        const new = switch (obj.get("new_string") orelse obj.get("new") orelse std.json.Value{ .string = "" }) {
            .string => |v| v,
            else => return error.BadEdits,
        };
        list[i] = .{ .old = old, .new = new };
    }
    return patch.applyEdits(allocator, dir, io, access, path, list[0..arr.items.len]);
}
