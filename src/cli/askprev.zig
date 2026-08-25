//! Ask-time preview for permission modals. Edit/patch show a short unified
//! diff; bash shows the command; everything else is empty (detail is enough).

const std = @import("std");
const sse = @import("../providers/sse.zig");
const Tool = @import("../core/tool.zig");

/// Caller frees. Empty when detail alone is enough.
pub fn build(allocator: std.mem.Allocator, name: []const u8, args: []const u8) ![]u8 {
    const tool = Tool.Name.fromSlice(name) orelse return allocator.dupe(u8, "");
    var path_buf: [240]u8 = undefined;
    var a_buf: [4 * 1024]u8 = undefined;
    var b_buf: [4 * 1024]u8 = undefined;
    const path = sse.argStringInto(&path_buf, args, "path") orelse "";
    return switch (tool) {
        .edit, .patch => blk: {
            const old = sse.argStringInto(&a_buf, args, "old_string") orelse
                sse.argStringInto(&a_buf, args, "old") orelse "";
            const new = sse.argStringInto(&b_buf, args, "new_string") orelse
                sse.argStringInto(&b_buf, args, "new") orelse
                sse.argStringInto(&b_buf, args, "contents") orelse "";
            if (old.len == 0 and new.len == 0) {
                const patch = sse.argStringInto(&a_buf, args, "patch") orelse "";
                if (patch.len != 0) break :blk try clip(allocator, patch, 24);
                break :blk try allocator.dupe(u8, "");
            }
            break :blk try syntheticDiff(allocator, path, old, new);
        },
        .write => blk: {
            const body = sse.argStringInto(&a_buf, args, "contents") orelse
                sse.argStringInto(&a_buf, args, "content") orelse "";
            if (body.len == 0) break :blk try allocator.dupe(u8, "");
            break :blk try syntheticDiff(allocator, path, "", body);
        },
        .bash => blk: {
            const cmd = sse.argStringInto(&a_buf, args, "command") orelse "";
            break :blk try clip(allocator, cmd, 12);
        },
        else => try allocator.dupe(u8, ""),
    };
}

fn clip(allocator: std.mem.Allocator, src: []const u8, max_lines: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (n >= max_lines) {
            try out.appendSlice(allocator, "…\n");
            break;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        n += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn syntheticDiff(allocator: std.mem.Allocator, path: []const u8, old: []const u8, new: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const file = if (path.len != 0) path else "file";
    try out.print(allocator, "--- a/{s}\n+++ b/{s}\n@@\n", .{ file, file });
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |line| {
        if (n >= 10) break;
        if (old.len == 0) break;
        try out.print(allocator, "-{s}\n", .{line});
        n += 1;
    }
    n = 0;
    it = std.mem.splitScalar(u8, new, '\n');
    while (it.next()) |line| {
        if (n >= 10) {
            try out.appendSlice(allocator, "…\n");
            break;
        }
        try out.print(allocator, "+{s}\n", .{line});
        n += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "edit args become a unified preview" {
    const src =
        \\{"path":"a.zig","old_string":"old","new_string":"new"}
    ;
    const s = try build(std.testing.allocator, "edit", src);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "+new") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "a.zig") != null);
}
