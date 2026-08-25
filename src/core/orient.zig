//! Adaptive orientation depth: how much volatile workspace context to prepend.
//!
//! The research this follows:
//!
//!   Jeong et al. "Adaptive-RAG: Learning to Adapt Retrieval-Augmented LLMs
//!   through Question Complexity." NAACL 2024 (arXiv:2403.14403). Real queries
//!   are not one-size-fits-all. A classifier over query complexity picks among
//!   three strategies: no retrieval (A), single-step retrieval (B), multi-step
//!   / iterative retrieval (C). Uniform always-retrieve wastes tokens on A;
//!   never-retrieve fails on C. Our depths mirror that ladder:
//!     none  ↔ A (model-answerable / social / mechanical)
//!     git   ↔ B (one workspace pulse: status, not the file graph)
//!     full  ↔ C (personalized repo map + git — multi-hop code navigation)
//!
//!   Asai et al. "Self-RAG: Learning to Retrieve, Generate, and Critique
//!   through Self-Reflection." ICLR 2024 (arXiv:2310.11511). Retrieval is a
//!   per-turn decision. Always-on orientation is the coding-agent analogue of
//!   always-retrieve: expensive on turns that never touch the tree.
//!
//!   Damani et al. / Snell et al. / arXiv:2604.14853 (same family as
//!   `autoeffort.zig`): allocate from cheap lexical features of the input
//!   alone — no extra LLM call to decide the budget. Effort and orientation
//!   are *dual* under the Hard archetype: when the turn is stuck, reasoning
//!   budget goes to the floor (thinking harder at empty air does not help),
//!   while orientation goes to the ceiling (look at the tree). That is the
//!   Adaptive-RAG escalation on wrong answers, applied to workspace context.
//!
//! No model, no network, no training: features are lexical; the classifier is
//! below. A router that costs an inference call to save orientation tokens has
//! not saved anything.

const std = @import("std");
const autoeffort = @import("autoeffort.zig");

pub const Depth = enum {
    /// Adaptive-RAG A.
    none,
    /// Adaptive-RAG B.
    git,
    /// Adaptive-RAG C.
    full,
};

const path_exts = [_][]const u8{
    ".zig", ".ts", ".tsx", ".js", ".jsx", ".py", ".go", ".rs", ".c", ".h",
    ".cpp", ".hpp", ".md", ".json", ".toml", ".yaml", ".yml", ".swift", ".kt",
};

/// Elevates A→B without forcing C: short coding intents need a pulse, not a 4k map.
const work_intent = [_][]const u8{
    "fix", "bug", "error", "fail", "implement", "build", "ship", "break",
    "crash", "stack", "trace", "commit", "merge", "deploy", "patch",
};

pub const Features = struct {
    effort: autoeffort.Features = .{},
    /// Path, @mention, or CamelCase/snake_case symbol.
    anchored: bool = false,
    work_intent: bool = false,
    plan_on: bool = false,
};

fn countHits(lower: []const u8, table: []const []const u8) usize {
    var n: usize = 0;
    for (table) |w| {
        if (std.mem.indexOf(u8, lower, w) != null) n += 1;
    }
    return n;
}

fn lowerPrefix(prompt: []const u8, buf: *[4096]u8) []const u8 {
    const n = @min(prompt.len, buf.len);
    for (prompt[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

fn hasAnchor(prompt: []const u8, lower: []const u8) bool {
    if (std.mem.indexOfScalar(u8, prompt, '@') != null) return true;
    if (std.mem.indexOfScalar(u8, prompt, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, prompt, '\\') != null) return true;
    for (path_exts) |ext| {
        if (std.mem.indexOf(u8, lower, ext) != null) return true;
    }
    var it = std.mem.tokenizeAny(u8, prompt, " \t\n\r.,;:()[]{}\"'`");
    while (it.next()) |tok| {
        if (tok.len < 3) continue;
        var has_upper = false;
        var has_lower = false;
        var has_under = false;
        for (tok) |c| {
            if (c == '_') has_under = true;
            if (std.ascii.isUpper(c)) has_upper = true;
            if (std.ascii.isLower(c)) has_lower = true;
        }
        if (has_upper and has_lower) return true;
        if (has_under and (has_upper or has_lower)) return true;
    }
    return false;
}

pub fn extract(prompt: []const u8, failures: usize, plan_on: bool) Features {
    var lower_buf: [4096]u8 = undefined;
    const lower = lowerPrefix(prompt, &lower_buf);
    return .{
        .effort = autoeffort.extract(prompt, failures),
        .anchored = hasAnchor(prompt, lower),
        .work_intent = countHits(lower, &work_intent) > 0,
        .plan_on = plan_on,
    };
}

pub fn classify(f: Features) Depth {
    if (f.plan_on) return .full;

    // Stuck: escalate retrieval even though autoeffort floors reasoning.
    if (f.effort.failures >= 1) return .full;

    if (f.anchored) return .full;
    if (f.effort.heavy > 0 or f.effort.steps >= 2) return .full;

    const arch = autoeffort.classify(f.effort);
    return switch (arch) {
        // Unreachable when failures>=1 above; kept for exhaustiveness.
        .hard => .full,
        // No anchors/heavy/steps left → single-step pulse, not the graph.
        .responsive => .git,
        // Map saturates on long repetitive paste.
        .diminishing => .git,
        .easy => blk: {
            if (f.work_intent) break :blk .git;
            if (f.effort.len <= autoeffort.short_prompt and f.effort.words <= 4 and
                (f.effort.light > 0 or f.effort.words <= 2))
                break :blk .none;
            break :blk .git;
        },
    };
}

pub fn orientDepth(prompt: []const u8, failures: usize, plan_on: bool) Depth {
    return classify(extract(prompt, failures, plan_on));
}

test "class A: no retrieval on tiny or light asks" {
    try std.testing.expectEqual(Depth.none, orientDepth("yo", 0, false));
    try std.testing.expectEqual(Depth.none, orientDepth("thanks", 0, false));
    try std.testing.expectEqual(Depth.none, orientDepth("rename x to y", 0, false));
}

test "class B: single-step pulse on short work without a path" {
    try std.testing.expectEqual(Depth.git, orientDepth("fix the auth bug", 0, false));
}

test "class C: full map on anchors heavy plan failures" {
    try std.testing.expectEqual(Depth.full, orientDepth("why does src/auth.zig deadlock?", 0, false));
    try std.testing.expectEqual(Depth.full, orientDepth("yo", 0, true));
    try std.testing.expectEqual(Depth.full, orientDepth("yo", 1, false));
    try std.testing.expectEqual(Depth.full, orientDepth("startServer", 0, false));
    try std.testing.expectEqual(Depth.full, orientDepth("refactor the parser", 0, false));
    try std.testing.expectEqual(Depth.full, orientDepth("audit this for security holes", 0, false));
}

test "responsive without anchors stays class B" {
    try std.testing.expectEqual(Depth.git, orientDepth("please help me figure out the next small step for this feature", 0, false));
}

test "Hard effort and full orientation are dual" {
    try std.testing.expectEqual(autoeffort.Archetype.hard, autoeffort.classify(autoeffort.extract("fix it", autoeffort.stuck_after)));
    try std.testing.expectEqual(Depth.full, orientDepth("fix it", autoeffort.stuck_after, false));
}

test "diminishing long paste gets git not the full map" {
    var buf: [2000]u8 = undefined;
    var w: usize = 0;
    while (w + 20 < buf.len) : (w += 20) @memcpy(buf[w..][0..20], "make the same edit  ");
    try std.testing.expectEqual(Depth.git, orientDepth(buf[0..w], 0, false));
}
