const std = @import("std");

const autoeffort = @import("autoeffort.zig");

// Gate whether the main agent should even see the peer tool for this turn.
// The task-shape signal is reused from `autoeffort`, which already follows the
// lexical-feature literature it cites. The rest stays cheap and observable:
// explicit user intent plus recent execution context, with a threshold gate
// rather than an always-on policy.

pub const Input = struct {
    prompt: []const u8,
    prior_user: []const u8 = "",
    prior_assistant: []const u8 = "",
    board_summary: []const u8 = "",
    plan: bool = false,
};

pub const Decision = struct {
    offer: bool,
    score: i32,
    reason: []const u8,
};

const allow_threshold: i32 = 4;

const delegate_words = [_][]const u8{
    "parallel", "delegate", "delegat", "teammate", "peer", "split this", "in parallel",
};

const tool_words = [_][]const u8{
    "bash", "read", "grep", "glob", "edit", "write", "browser", "web", "mcp",
};

const blocker_words = [_][]const u8{
    "fail", "blocked", "stuck", "retry", "again", "error", "denied",
};

fn lowerInto(dst: *[4096]u8, src: []const u8) []u8 {
    const n = @min(src.len, dst.len);
    for (src[0..n], 0..) |c, i| dst[i] = std.ascii.toLower(c);
    return dst[0..n];
}

fn countHits(lower: []const u8, words: []const []const u8) usize {
    var n: usize = 0;
    for (words) |word| {
        if (std.mem.indexOf(u8, lower, word) != null) n += 1;
    }
    return n;
}

pub fn decide(input: Input) Decision {
    if (input.plan) {
        return .{ .offer = false, .score = -99, .reason = "plan-mode" };
    }

    var prompt_buf: [4096]u8 = undefined;
    const prompt = lowerInto(&prompt_buf, input.prompt);

    var score: i32 = 0;
    const arch = autoeffort.classify(autoeffort.extract(input.prompt, 0));
    switch (arch) {
        .easy => score -= 3,
        .responsive => score += 2,
        .diminishing => score += 1,
        .hard => score += 2,
    }

    const delegate_hits = countHits(prompt, &delegate_words);
    if (delegate_hits > 0) score += 4;

    var recent_buf: [4096]u8 = undefined;
    const recent = lowerInto(&recent_buf, input.prior_user);
    var assist_buf: [4096]u8 = undefined;
    const prior_assistant = lowerInto(&assist_buf, input.prior_assistant);
    var board_buf: [4096]u8 = undefined;
    const board = lowerInto(&board_buf, input.board_summary);

    const recent_tools = countHits(recent, &tool_words) +
        countHits(prior_assistant, &tool_words) +
        countHits(board, &tool_words);
    if (recent_tools >= 1) score += 1;
    if (recent_tools >= 5) score += 1;

    const blockers = countHits(recent, &blocker_words) +
        countHits(prior_assistant, &blocker_words) +
        countHits(board, &blocker_words);
    if (blockers > 0) score += 3;
    if (blockers > 0 and recent_tools > 0) score += 2;

    if (input.board_summary.len != 0) score += 1;
    if (input.prompt.len > 280) score += 1;

    if (score >= allow_threshold) {
        return .{ .offer = true, .score = score, .reason = "threshold-met" };
    }
    return .{ .offer = false, .score = score, .reason = "below-threshold" };
}

test "easy asks do not advertise peers" {
    const d = decide(.{ .prompt = "rename this variable to n" });
    try std.testing.expect(!d.offer);
}

test "explicit parallel coding work advertises peers" {
    const d = decide(.{ .prompt = "split this in parallel: fix the parser, update tests, and investigate the failure" });
    try std.testing.expect(d.offer);
    try std.testing.expect(d.score >= allow_threshold);
}

test "recent blockers can lift a hard task over the threshold" {
    const d = decide(.{
        .prompt = "try another approach to fix the failing build",
        .prior_assistant = "bash failed again after edit and retry",
        .board_summary = "FAIL build still broken\nPATH inspect parser\n",
    });
    try std.testing.expect(d.offer);
}

test "plan mode suppresses automatic peers" {
    const d = decide(.{
        .prompt = "compare two migration strategies",
        .plan = true,
    });
    try std.testing.expect(!d.offer);
    try std.testing.expectEqualStrings("plan-mode", d.reason);
}
