const std = @import("std");
const Io = std.Io;
const fs = @import("../fs.zig");
const git_work = @import("../git_work.zig");
const search = @import("../search.zig");
const pathing = @import("../pathing.zig");
const tool = @import("../../core/tool.zig");
const Args = @import("args.zig").Args;

pub fn run(
    kind: tool.Name,
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    home: []const u8,
    args: Args,
    args_json: []const u8,
) ![]u8 {
    return switch (kind) {
        .semantic_search => blk: {
            const q = args.str("query") orelse args.str("q") orelse return error.EmptyNeedle;
            if (q.len == 0) return error.EmptyNeedle;
            break :blk try search.semanticSearch(dir, io, allocator, workspace, q);
        },
        .open_file => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            try pathing.assertInside(workspace, path);
            const abs = try pathing.joinWorkspace(allocator, workspace, path);
            defer allocator.free(abs);
            fs.openPath(io, abs);
            break :blk try std.fmt.allocPrint(allocator, "opened {s}", .{path});
        },
        .memory => blk: {
            const action = args.str("action") orelse "list";
            const fact = args.str("fact") orelse args.str("text") orelse "";
            const memory = @import("../memory.zig");
            break :blk try memory.run(allocator, io, home, action, fact);
        },
        .ask_user => allocator.dupe(u8, "ask_user: harness waits on the TTY; not available via dispatch\n"),
        .peer => allocator.dupe(u8, "peer: harness spawns the teammate; not available via dispatch\n"),
        .board => blk: {
            const action = args.str("action") orelse "read";
            const line = args.str("line") orelse args.str("text") orelse "";
            const b = @import("../../core/board.zig");
            break :blk try b.run(allocator, io, workspace, action, line);
        },
        .todo => blk: {
            const todos = @import("../../core/todos.zig");
            break :blk try todos.set(allocator, args_json);
        },
        .patch => blk: {
            const spec = args.str("patch") orelse args.str("spec") orelse return error.EmptyPatch;
            const patch = @import("../patch.zig");
            git_work.beforeMutate(allocator, io, workspace, home);
            const out = try patch.apply(allocator, dir, io, workspace, spec);
            git_work.afterMutate(allocator, io, workspace, home, "patch");
            break :blk out;
        },
        .mcp => blk: {
            const action = args.str("action") orelse "list";
            const n = args.str("name") orelse "";
            const arguments = args.str("arguments") orelse "{}";
            const mcp = @import("../mcp.zig");
            break :blk try mcp.run(allocator, io, home, action, n, arguments);
        },
        .compact => allocator.dupe(u8, "compact: harness ARC; cites at .omfx/recall; never encrypted\n"),
        else => unreachable,
    };
}
