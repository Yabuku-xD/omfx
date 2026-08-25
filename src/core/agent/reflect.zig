const std = @import("std");
const Io = std.Io;
const types = @import("../../providers/types.zig");
const pclient = @import("../../providers/client.zig");

pub const Reflect = union(enum) {
    task,
    pushback: []const u8,
};

pub const reflect_sys =
    \\Reply with one line: PUSHBACK <lesson> or TASK.
    \\PUSHBACK means the user is rejecting the last action. The lesson is what not to repeat.
    \\TASK means a new or continued request. No other words.
;

fn clip80(s: []const u8) []const u8 {
    return if (s.len <= 80) s else s[0..80];
}

/// Lesson slice into `body`. Junk and TASK are `.task` (fail open).
pub fn parseReflect(body: []const u8) Reflect {
    const t = std.mem.trim(u8, body, " \t\r\n");
    if (t.len == 0) return .task;
    if (t.len >= 4 and std.ascii.eqlIgnoreCase(t[0..4], "task")) return .task;
    if (t.len < 8 or !std.ascii.eqlIgnoreCase(t[0..8], "pushback")) return .task;
    var i: usize = 8;
    if (i < t.len and (t[i] == ':' or t[i] == ' ')) i += 1;
    while (i < t.len and t[i] == ' ') i += 1;
    const lesson = std.mem.trim(u8, t[i..], " \t\r\n");
    return .{ .pushback = lesson };
}

/// Tiny no-tool call. Returns an owned lesson or null. Never blocks the turn on failure.
pub fn reflectFollowup(
    allocator: std.mem.Allocator,
    io: Io,
    endpoint: types.Endpoint,
    last_goal: []const u8,
    last_tool: []const u8,
    now: []const u8,
) !?[]u8 {
    const user = try std.fmt.allocPrint(
        allocator,
        "last={s}\ntool={s}\nnow={s}",
        .{ clip80(last_goal), clip80(last_tool), clip80(now) },
    );
    defer allocator.free(user);
    var ep = endpoint;
    ep.effort = "none";
    const msgs = [_]pclient.Message{.{ .role = "user", .content = user }};
    var out = pclient.postChatFiltered(allocator, io, ep, &msgs, reflect_sys, .{ .tools = false, .allow_peer = false }) catch return null;
    defer out.deinit(allocator);
    return switch (parseReflect(out.textSlice())) {
        .task => null,
        .pushback => |lesson| try allocator.dupe(u8, clip80(if (lesson.len == 0) now else lesson)),
    };
}

pub fn peerTask(allocator: std.mem.Allocator, goal: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Peer task: {s}\nSame tools as the main agent. Talk through board (FACT/FAIL/PATH). Do not spawn peer.",
        .{goal},
    );
}

test "parseReflect reads PUSHBACK lessons and ignores TASK" {
    try std.testing.expectEqualStrings("do not rewrite auth", parseReflect("PUSHBACK do not rewrite auth").pushback);
    try std.testing.expectEqualStrings("stop adding files", parseReflect("pushback: stop adding files\n").pushback);
    try std.testing.expect(parseReflect("TASK") == .task);
    try std.testing.expect(parseReflect("thats not what i want you to do") == .task);
}

test "peerTask names the goal" {
    const s = try peerTask(std.testing.allocator, "fix auth");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "fix auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Do not spawn peer") != null);
}
