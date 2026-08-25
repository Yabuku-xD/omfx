const std = @import("std");
const pclient = @import("../../providers/client.zig");
const sink = @import("../sink.zig");

/// Explicit phases for one iteration of the tool-turn loop in `chatTurn`.
pub const Phase = enum {
    poll_boundary,
    classify_outcome,
    admit_tool,
    execute_tool,
    append_follow_up,
    repost,
};

/// Mutable counters carried across tool rounds within one user turn.
pub const Counters = struct {
    turns: usize = 0,
    tool_rounds: usize = 0,
    explored: bool = false,
    same: usize = 0,
    malformed: usize = 0,
    orient_streak: usize = 0,
    prev_name: []u8,
    prev_args: []u8,
};

/// Pause points where cancel and permission mode can apply.
pub fn pollBoundary(host: sink.Host) void {
    host.pollCancel();
    host.pollModeCycle();
}

/// Returns owned text when the model finished with prose instead of a tool call.
pub fn finishIfText(
    allocator: std.mem.Allocator,
    last: *pclient.ChatResult,
    tool_rounds: usize,
    ensure_nl: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
) !?[]u8 {
    const body = switch (last.outcome) {
        .text => |t| t,
        .tool => return null,
    };
    const raw = if (body.len == 0 and tool_rounds != 0)
        "Turn finished after tools with no further reply. Say if you want the next step.\n"
    else
        body;
    const out = try ensure_nl(allocator, raw);
    last.deinit(allocator);
    return out;
}

test "finishIfText returns null for tool outcomes" {
    var last = pclient.ChatResult{
        .status = 200,
        .outcome = .{ .tool = .{
            .preamble = try std.testing.allocator.dupe(u8, ""),
            .name = try std.testing.allocator.dupe(u8, "read"),
            .args = try std.testing.allocator.dupe(u8, "{}"),
        } },
    };
    defer last.deinit(std.testing.allocator);
    const out = try finishIfText(std.testing.allocator, &last, 0, struct {
        fn f(a: std.mem.Allocator, s: []const u8) ![]u8 {
            return a.dupe(u8, s);
        }
    }.f);
    try std.testing.expect(out == null);
}

test "finishIfText copies text outcomes" {
    var last = pclient.ChatResult{
        .status = 200,
        .outcome = .{ .text = try std.testing.allocator.dupe(u8, "done") },
    };
    const out = (try finishIfText(std.testing.allocator, &last, 0, struct {
        fn f(a: std.mem.Allocator, s: []const u8) ![]u8 {
            return a.dupe(u8, s);
        }
    }.f)).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("done", out);
}
