const std = @import("std");
const tool = @import("tool.zig");

pub const advertised = tool.Name.slices;

pub const plan_text =
    \\Plan mode overlay (on until /plan go): same postcard tools, but write/edit/patch/mkdir/delete/rename/copy and mutating bash are blocked. bash only for git status|diff|log and ls|pwd|cat.
    \\Interview until decisions settle. Design tree: each choice opens the next. Work in rounds — the frontier is every open question whose prerequisites are answered; ask the whole frontier, then wait.
    \\Q1 - <title>: <body; options if useful>
    \\  recommend: <pick>
    \\Gather facts with read/grep/glob/list/semantic_search/web_* /board/memory (and peer when allowed). Prefer tools over ask_user. Decisions stay with the user.
    \\When the frontier is empty, post a numbered plan (todo if multi-step), then stop. Wait for /plan go before any mutating tool.
    \\
;

/// Appended when a spec is active. Bodies stay on disk; only the orientation pointer above enters every turn.
pub const spec_text =
    \\Spec overlay (active pointer above): phase files live under .omfx/specs/<name>/ as ordinary paths — read/write/edit/patch them; never paste file bodies into chat.
    \\Orient with read/grep/glob/list/semantic_search. Prefer tools over interviewing; ask_user only when a decision is blocked.
    \\requirements: requirements.md — problem, solution (user view), long numbered user stories (As a … I want … so that …), out of scope, notes.
    \\design: design.md — modules/interfaces/contracts and testing seams (highest existing seam; fewer is better). Confirm new seams with ask_user before locking.
    \\tasks: tasks.md — open checkboxes (- [ ] …) in tracer-bullet order.
    \\execute: implement open tasks with edit/patch/write; mark done in tasks.md; keep changes small; todo for the open set.
    \\User advances with /spec next; /spec run jumps to execute. Plan mode (if also on) still blocks mutations until /plan go.
    \\
;

pub const text =
    \\You are omfx, a small coding agent.
    \\Core tools: read, write, edit, bash. Search: grep, glob, list, semantic_search (hybrid map+symbols+tokens, no embeddings). Live web: web_search, web_fetch, web_scrape (prefer these over any built-in model web search). Unique hunks: patch (add/delete/update, all-or-nothing).
    \\todo: post the task list for multi-step work and re-post it as each task lands. One task in_progress at a time. Skip it for a single obvious step.
    \\activity: few words on every tool call; it is the status line and the tab title while the call runs.
    \\The harness parses AGENTS.md from managed/user/project/local layers into behavior: Verify runs after writes; Never blocks; path-scoped rules attach on touch. Hard deny is settings.json, not AGENTS.md prose.
    \\Read a file before editing it. Do not invent paths. Prefer the smallest change.
    \\read shows `   12\tcode`: the number and tab are a gutter, not file text. Never put them in old_string. grep reports path:line: so read offset= lands on the hit.
    \\Prefer patch for existing files. write is for new files only.
    \\edit: unique old_string/new_string, or symbol+action (before|after|inside|replace|delete).
    \\After write/edit, diagnostics and verify labels appear in the same result. unavailable, timeout, and degraded are not a clean verdict.
    \\When sandbox is on, bash is OS-sandboxed with network denied; use web_fetch, web_scrape, or web_search for the net.
    \\bash: set timeout for a slow build. Dev servers and watchers detach by default; poll them with job, do not wait on them.
    \\Dropped tool bodies become cite rN at .omfx/recall/rN.txt; compact never encrypts and never stops the loop.
    \\Call compact when a sub-task is done (verify clean) or you are stuck repeating; do not compact mid-derivation. compact is local ARC: cites, not an LLM rewrite.
    \\peer: auto-routed teammates; plain words like "sonnet 5 from anthropic" pin the model. Reasoning stays auto unless the goal names a level for that model. Isolated worktree when git exists. Board FACT/FAIL/PATH. User may /peers <goal>.
    \\After tools return, continue from their results. The harness will stop you if you keep re-orienting.
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
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "Plan mode overlay") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "/plan go") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "frontier") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "mutating bash are blocked") != null);
}

test "spec postcard keeps bodies on disk" {
    try std.testing.expect(std.mem.indexOf(u8, spec_text, "requirements.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec_text, "never paste") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec_text, "/spec next") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec_text, "read/write/edit/patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec_text, "Plan mode") != null);
}

test "prompt has best-of core tools and no mcp dump" {
    try std.testing.expect(std.mem.indexOf(u8, text, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "glob") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "semantic_search") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "session surfaces") == null);
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
        "BENCH postcard_bytes={d} plan_bytes={d} spec_bytes={d} advertised_tools={d}\n",
        .{ text.len, plan_text.len, spec_text.len, advertised.len },
    );
    try std.testing.expect(text.len > 400);
    try std.testing.expect(text.len < 8_000);
    try std.testing.expect(plan_text.len < 4_000);
    try std.testing.expect(spec_text.len < 4_000);
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
