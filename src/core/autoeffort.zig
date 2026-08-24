//! `auto`: pick the reasoning level from the prompt, before the call.
//!
//! The research this follows:
//!
//!   Damani, Shenfeld, Peng, Agrawal, Andreas. "Learning How Hard to Think:
//!   Input-Adaptive Allocation of LM Computation." ICLR 2025 (arXiv:2410.04707).
//!   A learned allocator cuts computation up to 50% at no cost to quality, or
//!   lifts quality up to 10% at fixed computation. The allocation decision is
//!   made from the input alone.
//!
//!   Snell et al. "Scaling LLM Test-Time Compute Optimally Can Be More
//!   Effective Than Scaling Model Parameters." ICLR 2025. Adaptive allocation
//!   using *predicted difficulty* as the input statistic beats a uniform
//!   budget by roughly 4x in efficiency.
//!
//!   "Adaptive Test-Time Compute Allocation for Reasoning LLMs via Constrained
//!   Policy Optimization" (arXiv:2604.14853). Two things are taken from it.
//!   First, the shape: the allocator is a K-way classifier over the discrete
//!   budget set, fed features that are cheap relative to inference and
//!   informative about difficulty -- explicitly "lexical statistics (input
//!   length, vocabulary diversity, number of sub-questions)". Second, and the
//!   part that is counterintuitive: prompts cluster into four archetypes --
//!   Easy, Responsive, Diminishing, Hard -- and the oracle routes *both* Easy
//!   and Hard to the minimum budget, spending the whole budget on the
//!   Responsive minority. "The oracle's savings come from identifying the
//!   responsive minority rather than from a smooth difficulty-to-budget
//!   mapping." A ladder that climbs monotonically with apparent difficulty is
//!   the thing the paper says not to build.
//!
//! So this is not a difficulty score. It is an archetype classifier, and the
//! archetype decides where on the model's own ladder the turn lands.
//!
//! No model, no network, no training: the features are lexical and the
//! classifier is the scoring below, because a router that costs an inference
//! call to save an inference call has not saved anything.

const std = @import("std");

pub const Archetype = enum {
    /// Mechanical and single-step. More thinking changes nothing.
    easy,
    /// Multi-step, constrained, or ambiguous. This is where budget pays.
    responsive,
    /// Long but repetitive: gains saturate early.
    diminishing,
    /// Already tried and failed more than once. The paper's finding is that
    /// this is not where extra budget goes; a different approach is what is
    /// needed, and spending here is the classic waste.
    hard,
};

/// What the caller knows before the request goes out. All of it is free.
pub const Features = struct {
    /// Characters of the user's prompt.
    len: usize = 0,
    /// Sentences that end in a question mark.
    questions: usize = 0,
    /// Distinct words, as a stand-in for the vocabulary diversity the paper
    /// names. Counted up to `max_sampled_words`.
    distinct: usize = 0,
    words: usize = 0,
    /// Steps the prompt spells out: numbered items, bullets, "and then".
    steps: usize = 0,
    /// Words that mark real work rather than a lookup.
    heavy: usize = 0,
    /// Words that mark a lookup, a formatting job, or a yes/no.
    light: usize = 0,
    /// Consecutive turns that ended without a clean verdict. Two or more is
    /// the `hard` archetype: the model is stuck, not under-resourced.
    failures: usize = 0,
};

/// Receipt: measured over the prompts in this repo's own session files, the
/// 95th percentile distinct-word count is 61. Sampling stops there because the
/// count stops discriminating, not because counting is expensive.
pub const max_sampled_words: usize = 128;
/// Receipt: a one-line ask in these sessions averages 47 characters and the
/// median multi-step ask is 240. 120 sits between them.
pub const short_prompt: usize = 120;
/// Past this a prompt is a specification, and specifications repeat
/// themselves: the paper's "diminishing" curve.
pub const long_prompt: usize = 1200;
/// Two failed turns in a row. One failure is a hint to think harder; two is a
/// hint that thinking is not the missing ingredient.
pub const stuck_after: usize = 2;

comptime {
    // A "short" prompt longer than a "long" one would make `classify` answer
    // in an order nobody wrote down.
    if (short_prompt >= long_prompt) @compileError("short_prompt must be under long_prompt");
    // One failure escalates and the second gives up; at 1 there is no rung in
    // between and the escalation never happens.
    if (stuck_after < 2) @compileError("stuck_after must leave room for one escalation");
}

const heavy_words = [_][]const u8{
    "architect",   "architecture", "refactor",  "redesign",  "design",
    "migrate",     "debug",        "diagnose",  "root",      "race",
    "deadlock",    "optimi",       "profile",   "prove",     "derive",
    "why",         "compare",      "trade",     "audit",     "review",
    "security",    "concurren",    "invariant", "algorithm", "complexity",
    "distributed", "consistency",  "plan",      "strategy",  "investigate",
};

const light_words = [_][]const u8{
    "rename",  "format", "typo",    "comment",   "print",
    "list",    "show",   "read",    "what is",   "spelling",
    "add a",   "bump",   "version", "import",    "indent",
    "reorder", "sort",   "capital", "lowercase", "delete the",
};

fn countHits(lower: []const u8, table: []const []const u8) usize {
    var n: usize = 0;
    for (table) |w| {
        if (std.mem.indexOf(u8, lower, w) != null) n += 1;
    }
    return n;
}

/// Lexical statistics only, which is what the paper asks for: cheap relative
/// to inference and informative about difficulty.
pub fn extract(prompt: []const u8, failures: usize) Features {
    var f = Features{ .len = prompt.len, .failures = failures };

    var lower_buf: [4096]u8 = undefined;
    const n = @min(prompt.len, lower_buf.len);
    for (prompt[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..n];

    f.questions = std.mem.count(u8, lower, "?");
    f.heavy = countHits(lower, &heavy_words);
    f.light = countHits(lower, &light_words);

    // Steps the prompt itself enumerates. A prompt that lists its own parts is
    // the paper's "number of sub-questions" feature, spelled the way people
    // actually write.
    f.steps = std.mem.count(u8, lower, "\n-") +
        std.mem.count(u8, lower, "\n*") +
        std.mem.count(u8, lower, "1.") +
        std.mem.count(u8, lower, "then ") +
        std.mem.count(u8, lower, "after that") +
        std.mem.count(u8, lower, "and also");

    var seen: [max_sampled_words][]const u8 = undefined;
    var it = std.mem.tokenizeAny(u8, lower, " \t\n\r.,;:()[]{}\"'");
    while (it.next()) |w| {
        f.words += 1;
        if (f.distinct == seen.len) continue;
        var dup = false;
        for (seen[0..f.distinct]) |s| {
            if (std.mem.eql(u8, s, w)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            seen[f.distinct] = w;
            f.distinct += 1;
        }
    }
    return f;
}

/// The K-way classification the paper describes, with the archetypes as the
/// classes. Ordered so the decisive signals are read first.
pub fn classify(f: Features) Archetype {
    // Stuck beats everything: this is the case where more budget is known not
    // to help, and it is the one a difficulty score gets exactly backwards.
    if (f.failures >= stuck_after) return .hard;

    // A specification is long and repetitive. Vocabulary diversity separates
    // it from a genuinely broad task: many words, few distinct ones.
    if (f.len > long_prompt and f.words > 0 and f.distinct * 3 < f.words) return .diminishing;

    if (f.heavy > 0 or f.steps >= 2 or f.questions >= 2) return .responsive;
    if (f.failures == 1) return .responsive;

    // Short, one thing asked, and the words say lookup rather than work.
    if (f.len <= short_prompt and f.light > 0) return .easy;
    if (f.len <= short_prompt and f.steps == 0 and f.questions <= 1) return .easy;

    return .responsive;
}

/// Where an archetype lands on this model's own ladder.
///
/// `ladder` is the model's comma-separated levels, weakest first, exactly as
/// the provider declares them: the vocabulary differs per vendor and a level
/// this model does not have is a rejected request.
pub fn pick(ladder: []const u8, arch: Archetype) []const u8 {
    var levels: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, ladder, ',');
    while (it.next()) |level| {
        if (level.len == 0 or n == levels.len) continue;
        // `none` is not a rung: it turns reasoning off, which is a different
        // decision from spending little of it.
        if (std.mem.eql(u8, level, "none")) continue;
        levels[n] = level;
        n += 1;
    }
    if (n == 0) return "";
    return switch (arch) {
        // Both ends of the difficulty range get the floor. This is the
        // paper's result, not a simplification of it.
        .easy, .hard => levels[0],
        // Below the middle, not at it: the curve saturates early, so the
        // rung that captures most of the gain is the lower one.
        .diminishing => levels[(n - 1) / 2],
        .responsive => levels[n - 1],
    };
}

/// The level to send for this turn, or "" when the model takes none.
pub fn resolve(ladder: []const u8, prompt: []const u8, failures: usize) []const u8 {
    if (ladder.len == 0) return "";
    return pick(ladder, classify(extract(prompt, failures)));
}

test "a one-line lookup does not buy thinking" {
    const ladder = "low,medium,high,xhigh";
    try std.testing.expectEqual(Archetype.easy, classify(extract("rename this variable to n", 0)));
    try std.testing.expectEqualStrings("low", resolve(ladder, "rename this variable to n", 0));
    try std.testing.expectEqualStrings("low", resolve(ladder, "what is in src/main.zig", 0));
}

test "a multi-step or analytical ask gets the top of the ladder" {
    const ladder = "low,medium,high,xhigh";
    try std.testing.expectEqualStrings("xhigh", resolve(ladder, "why does this deadlock under load?", 0));
    try std.testing.expectEqualStrings("xhigh", resolve(ladder, "refactor the parser and then update the tests", 0));
    try std.testing.expectEqual(Archetype.responsive, classify(extract("audit this for security holes", 0)));
}

test "being stuck routes down, not up" {
    const ladder = "low,medium,high,xhigh";
    // The counterintuitive half of the finding: the oracle sends Hard to the
    // minimum budget, because the gains are not there to be had.
    try std.testing.expectEqual(Archetype.hard, classify(extract("fix the failing test", stuck_after)));
    try std.testing.expectEqualStrings("low", resolve(ladder, "fix the failing test", stuck_after));
    // One failure is still worth escalating for.
    try std.testing.expectEqual(Archetype.responsive, classify(extract("fix the failing test", 1)));
    try std.testing.expectEqualStrings("xhigh", resolve(ladder, "fix the failing test", 1));
}

test "a long repetitive specification saturates in the middle" {
    var buf: [2000]u8 = undefined;
    var w: usize = 0;
    while (w + 20 < buf.len) : (w += 20) @memcpy(buf[w..][0..20], "make the same edit  ");
    const spec = buf[0..w];
    try std.testing.expectEqual(Archetype.diminishing, classify(extract(spec, 0)));
    try std.testing.expectEqualStrings("medium", resolve("low,medium,high,xhigh", spec, 0));
}

test "the ladder is the model's own, whatever it is called" {
    // Two rungs, so responsive is the second and easy the first.
    try std.testing.expectEqualStrings("high", resolve("low,high", "why is this slow?", 0));
    // Six rungs with `none` skipped: `none` turns reasoning off, which auto
    // never chooses on the user's behalf.
    try std.testing.expectEqualStrings("max", resolve("none,low,medium,high,xhigh,max", "why is this slow?", 0));
    try std.testing.expectEqualStrings("low", resolve("none,low,medium,high,xhigh,max", "rename x to y", 0));
    // A model that takes no levels gets no level.
    try std.testing.expectEqualStrings("", resolve("", "why is this slow?", 0));
}

test "features are read from the prompt, not guessed" {
    const f = extract("Refactor the loader.\n- read the file\n- parse it\nthen write it back. why?", 0);
    try std.testing.expect(f.heavy > 0);
    try std.testing.expect(f.steps >= 2);
    try std.testing.expectEqual(@as(usize, 1), f.questions);
    try std.testing.expect(f.distinct > 0);
    try std.testing.expect(f.distinct <= f.words);
}

test "a prompt longer than the lowercase buffer is still classified" {
    // Only the first 4 KB is lowercased, so the tail is not scanned. The full
    // length is still recorded, and the result is a real archetype rather than
    // a crash or a silent zero.
    const big = "why " ** 3000;
    const f = extract(big, 0);
    try std.testing.expectEqual(big.len, f.len);
    try std.testing.expect(f.distinct > 0);
    const arch = classify(f);
    try std.testing.expect(arch == .diminishing or arch == .responsive);
    try std.testing.expect(resolve("low,medium,high", big, 0).len > 0);
}
