const std = @import("std");
const tool = @import("tool.zig");

pub const advertised = tool.Name.slices;

pub const plan_text =
    \\Plan mode: research only. Do not write, edit, delete, or run mutating commands. git status/diff/log and ls/pwd/cat are allowed. Reply with a numbered plan and wait for /plan go.
    \\
;

pub const text =
    \\You are omfx, a small coding agent.
    \\Core tools: read, write, edit, bash. Search: grep, glob, list. Live web: web_search. Unique hunks: patch (add/delete/update, all-or-nothing).
    \\todo: post the task list for multi-step work and re-post it as each task lands. One task in_progress at a time. Skip it for a single obvious step.
    \\activity: few words on every tool call; it is the status line and the tab title while the call runs.
    \\The harness parses AGENTS.md from managed/user/project/local layers into behavior: Verify runs after writes; Never blocks; path-scoped rules attach on touch. Hard deny is settings.json, not AGENTS.md prose.
    \\Read a file before editing it. Do not invent paths. Prefer the smallest change.
    \\read shows `   12\tcode`: the number and tab are a gutter, not file text. Never put them in old_string. grep reports path:line: so read offset= lands on the hit.
    \\Prefer patch for existing files. write is for new files only.
    \\edit: unique old_string/new_string, or symbol+action (before|after|inside|replace|delete).
    \\After write/edit, diagnostics and verify labels appear in the same result. unavailable, timeout, and degraded are not a clean verdict.
    \\bash is OS-sandboxed with network denied; use web_fetch or web_search for the net.
    \\bash: set timeout for a slow build. Dev servers and watchers detach by default; poll them with job, do not wait on them.
    \\Dropped tool bodies become cite rN at .omfx/recall/rN.txt; compact never encrypts and never stops the loop.
    \\Call compact when a sub-task is done (verify clean) or you are stuck repeating; do not compact mid-derivation. compact is local ARC: cites, not an LLM rewrite.
    \\peer: isolated git worktree under .omfx/peers when git exists; else shared workspace. Talks through board, not nested peers. Post FACT/FAIL/PATH. User may type /peers <goal>.
    \\Diagrams: mermaid in fenced ```mermaid blocks. The harness saves them under .omfx/diagrams/ (svg if mmdc is on PATH). Markdown tables stay as text.
    \\
;

pub fn containsOnlyAdvertised(list: []const []const u8) bool {
    for (list) |name| {
        var ok = false;
        for (advertised) |allowed| {
            if (std.mem.eql(u8, name, allowed)) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    return true;
}

pub fn withSkills(allocator: std.mem.Allocator, skill_block: []const u8) ![]u8 {
    return withExtras(allocator, skill_block, "", "");
}

/// System prompt first (stable prefix), then AGENTS.md, git, skills.
pub fn withExtras(
    allocator: std.mem.Allocator,
    skill_block: []const u8,
    agents_block: []const u8,
    git_block: []const u8,
) ![]u8 {
    return withFlags(allocator, skill_block, agents_block, git_block, true);
}

pub fn withFlags(
    allocator: std.mem.Allocator,
    skill_block: []const u8,
    agents_block: []const u8,
    git_block: []const u8,
    allow_peer: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPostcard(&out, allocator, allow_peer);
    if (agents_block.len > 0) {
        try out.appendSlice(allocator, "AGENTS.md:\n");
        try out.appendSlice(allocator, agents_block);
        if (agents_block[agents_block.len - 1] != '\n') try out.append(allocator, '\n');
    }
    if (git_block.len > 0) {
        try out.appendSlice(allocator, "git:\n");
        try out.appendSlice(allocator, git_block);
        if (git_block[git_block.len - 1] != '\n') try out.append(allocator, '\n');
    }
    if (skill_block.len > 0) try out.appendSlice(allocator, skill_block);
    return out.toOwnedSlice(allocator);
}

fn appendPostcard(out: *std.ArrayList(u8), allocator: std.mem.Allocator, allow_peer: bool) !void {
    if (allow_peer) {
        try out.appendSlice(allocator, text);
        return;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "peer:")) continue;
        if (std.mem.startsWith(u8, line, "Tools:")) {
            var i: usize = 0;
            while (i < line.len) {
                if (std.mem.startsWith(u8, line[i..], "peer, ")) {
                    i += "peer, ".len;
                    continue;
                }
                try out.append(allocator, line[i]);
                i += 1;
            }
            try out.append(allocator, '\n');
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
}

test "plan postcard forbids writes" {
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "research only") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "/plan go") != null);
}

test "prompt has best-of core tools and no mcp dump" {
    try std.testing.expect(std.mem.indexOf(u8, text, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "glob") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not a clean verdict") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "harness parses") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cite rN") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "managed/user/project/local") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "peer") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "network denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "activate_tools") == null);
    try std.testing.expect(containsOnlyAdvertised(&advertised));
}

test "withSkills appends skill names" {
    const s = try withSkills(std.testing.allocator, "Skills: hello-omfx\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "hello-omfx") != null);
}

test "AGENTS.md is instructions not a tool filter" {
    const s = try withExtras(std.testing.allocator, "", "no subagents\n", "");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "no subagents") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "peer:") != null);
}

test "nested postcard can omit peer" {
    const s = try withFlags(std.testing.allocator, "", "", "", false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "peer:") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "read") != null);
}

test "bench: postcard and plan sizes" {
    std.debug.print(
        "BENCH postcard_bytes={d} plan_bytes={d} advertised_tools={d}\n",
        .{ text.len, plan_text.len, advertised.len },
    );
    try std.testing.expect(text.len > 400);
    try std.testing.expect(text.len < 8_000);
}

test "withExtras keeps postcard before AGENTS.md" {
    const s = try withExtras(std.testing.allocator, "", "see README.md\n", "## main\n");
    defer std.testing.allocator.free(s);
    const postcard = std.mem.indexOf(u8, s, "You are omfx") orelse {
        try std.testing.expect(false);
        return;
    };
    const agents = std.mem.indexOf(u8, s, "AGENTS.md:\nsee README.md") orelse {
        try std.testing.expect(false);
        return;
    };
    const git = std.mem.indexOf(u8, s, "git:\n## main") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(postcard < agents);
    try std.testing.expect(agents < git);
}
