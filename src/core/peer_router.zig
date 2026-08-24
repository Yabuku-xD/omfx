const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.peer_router);

const env = @import("env.zig");
const autoeffort = @import("autoeffort.zig");
const catalog = @import("../providers/catalog.zig");
const auth = @import("../providers/auth.zig");
const models = @import("../providers/models.zig");
const model_signals = @import("../providers/model_signals.zig");
const types = @import("../providers/types.zig");

pub const RouterError = error{ OutOfMemory, NoCredential };

pub const max_candidates: usize = 64;
pub const catalog_max: usize = 12;

const Candidate = struct {
    spec: catalog.Spec,
    model: models.Model,
};

const Hint = struct {
    provider: []const u8,
    model: []const u8,
};

const Goal = struct {
    coding: bool = false,
    research: bool = false,
    quick: bool = false,
    min_context: u32 = 32_000,
    cost_weight: f64 = 1,
    bench_weight: f64 = 1,
};

fn classifyGoal(goal: []const u8) Goal {
    const feats = autoeffort.extract(goal, 0);
    var g = Goal{
        .min_context = @intCast(@min(200_000, @max(32_000, feats.len * 4))),
        .cost_weight = if (feats.light > feats.heavy) 1.5 else 1,
        .bench_weight = if (feats.heavy > 0) 1.4 else 1,
    };
    var lower_buf: [4096]u8 = undefined;
    const n = @min(goal.len, lower_buf.len);
    for (goal[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..n];
    g.coding = std.mem.indexOf(u8, lower, "code") != null or
        std.mem.indexOf(u8, lower, "bug") != null or
        std.mem.indexOf(u8, lower, "fix") != null or
        std.mem.indexOf(u8, lower, "test") != null or
        std.mem.indexOf(u8, lower, "implement") != null or
        feats.heavy > 0;
    g.research = std.mem.indexOf(u8, lower, "research") != null or
        std.mem.indexOf(u8, lower, "compare") != null or
        feats.questions > 1;
    g.quick = feats.light > 0 and feats.heavy == 0 and goal.len < autoeffort.short_prompt;
    return g;
}

fn providerMatches(model_provider: []const u8, spec: catalog.Spec) bool {
    const store = catalog.storeId(spec);
    return std.mem.eql(u8, model_provider, spec.id) or
        std.mem.eql(u8, model_provider, store);
}

fn collectCandidates(
    lookup: env.Lookup,
    auth_json: []const u8,
    out: *[max_candidates]Candidate,
) usize {
    var n: usize = 0;
    for (catalog.all) |spec| {
        if (auth.resolveKey(lookup, auth_json, spec) == null) continue;
        for (models.all) |m| {
            if (!providerMatches(m.provider, spec)) continue;
            if (n >= max_candidates) return n;
            out[n] = .{ .spec = spec, .model = m };
            n += 1;
        }
    }
    return n;
}

fn idChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

fn tokenLeft(s: []const u8, slash: usize) []const u8 {
    var start = slash;
    while (start > 0 and idChar(s[start - 1])) start -= 1;
    return s[start..slash];
}

fn tokenRight(s: []const u8, slash: usize) []const u8 {
    var end = slash + 1;
    while (end < s.len and idChar(s[end])) end += 1;
    return s[slash + 1 .. end];
}

fn goalSlashHint(goal: []const u8) ?Hint {
    var i: usize = 0;
    while (i < goal.len) : (i += 1) {
        if (goal[i] != '/') continue;
        const left = tokenLeft(goal, i);
        const right = tokenRight(goal, i);
        if (left.len == 0 or right.len == 0) continue;
        const spec = catalog.byId(left) orelse continue;
        return .{ .provider = spec.id, .model = right };
    }
    return null;
}

fn goalModelHint(
    goal: []const u8,
    lookup: env.Lookup,
    auth_json: []const u8,
) ?Hint {
    var buf: [max_candidates]Candidate = undefined;
    const n = collectCandidates(lookup, auth_json, &buf);
    var best: ?Candidate = null;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const id = buf[i].model.id;
        if (id.len < 4) continue;
        if (std.mem.indexOf(u8, goal, id) == null) continue;
        if (id.len > best_len) {
            best = buf[i];
            best_len = id.len;
        }
    }
    if (best) |c| return .{ .provider = c.spec.id, .model = c.model.id };
    return null;
}

fn wordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn hasWord(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) continue;
        const left_ok = i == 0 or !wordChar(hay[i - 1]);
        const right_ok = i + needle.len == hay.len or !wordChar(hay[i + needle.len]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

const families = [_][]const u8{
    "sonnet", "opus", "haiku", "fable", "codex", "grok", "luna", "terra", "sol", "flash", "mini", "gpt", "claude",
};

fn goalFamily(lower: []const u8) ?[]const u8 {
    for (families) |f| {
        if (hasWord(lower, f)) return f;
    }
    return null;
}

fn familyInModel(family: []const u8, model: models.Model) bool {
    return hasWord(model.id, family) or hasWord(model.name, family);
}

fn collectNums(s: []const u8, out: *[8][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) {
        if (s[i] < '0' or s[i] > '9') {
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        out[n] = s[start..i];
        n += 1;
    }
    return n;
}

fn numsCovered(want: []const []const u8, have: []const []const u8) bool {
    for (want) |w| {
        var ok = false;
        for (have) |h| {
            if (std.mem.eql(u8, w, h)) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    return true;
}

fn versionRank(nums: []const []const u8) i32 {
    var v: i32 = 0;
    for (nums) |n| {
        const d = std.fmt.parseInt(i32, n, 10) catch 0;
        v = v * 100 + @min(d, 99);
    }
    return v;
}

fn providerSpoken(lower: []const u8, spec: catalog.Spec) bool {
    if (hasWord(lower, spec.id)) return true;
    if (std.mem.indexOf(u8, spec.id, "anthropic") != null) return hasWord(lower, "anthropic");
    if (std.mem.indexOf(u8, spec.id, "openai") != null) {
        return hasWord(lower, "openai") or hasWord(lower, "chatgpt");
    }
    if (std.mem.indexOf(u8, spec.id, "xai") != null) return hasWord(lower, "xai");
    if (std.mem.indexOf(u8, spec.id, "commandcode") != null) {
        return hasWord(lower, "commandcode") or hasWord(lower, "command");
    }
    return false;
}

fn lowerInto(dst: *[4096]u8, src: []const u8) []u8 {
    const n = @min(src.len, dst.len);
    for (src[0..n], 0..) |c, i| dst[i] = std.ascii.toLower(c);
    return dst[0..n];
}

fn phraseScore(lower: []const u8, spec: catalog.Spec, model: models.Model) i32 {
    const family = goalFamily(lower) orelse return 0;
    if (!familyInModel(family, model)) return 0;
    var want_n: [8][]const u8 = undefined;
    var have_n: [8][]const u8 = undefined;
    const nw = collectNums(lower, &want_n);
    const nh = collectNums(model.id, &have_n);
    if (nw > 0 and !numsCovered(want_n[0..nw], have_n[0..nh])) return 0;
    var s: i32 = 40;
    if (nw > 0) s += 30;
    if (providerSpoken(lower, spec)) s += 25;
    s += @divTrunc(versionRank(have_n[0..nh]), 20);
    return s;
}

fn goalPhraseHint(
    goal: []const u8,
    lookup: env.Lookup,
    auth_json: []const u8,
) ?Hint {
    var lower_buf: [4096]u8 = undefined;
    const lower = lowerInto(&lower_buf, goal);
    if (goalFamily(lower) == null) return null;
    var buf: [max_candidates]Candidate = undefined;
    const n = collectCandidates(lookup, auth_json, &buf);
    var best_i: ?usize = null;
    var best_score: i32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const sc = phraseScore(lower, buf[i].spec, buf[i].model);
        if (sc > best_score) {
            best_score = sc;
            best_i = i;
        }
    }
    if (best_score < 40) return null;
    const c = buf[best_i.?];
    return .{ .provider = c.spec.id, .model = c.model.id };
}

fn goalHint(
    goal: []const u8,
    lookup: env.Lookup,
    auth_json: []const u8,
) ?Hint {
    return goalSlashHint(goal) orelse
        goalModelHint(goal, lookup, auth_json) orelse
        goalPhraseHint(goal, lookup, auth_json);
}

fn ladderHas(ladder: []const u8, level: []const u8) bool {
    var it = std.mem.splitScalar(u8, ladder, ',');
    while (it.next()) |item| {
        if (std.mem.eql(u8, item, level)) return true;
    }
    return false;
}

fn effortFrom(goal: []const u8) ?[]const u8 {
    var lower_buf: [4096]u8 = undefined;
    const lower = lowerInto(&lower_buf, goal);
    if (hasWord(lower, "xhigh") or std.mem.indexOf(u8, lower, "x-high") != null or
        std.mem.indexOf(u8, lower, "extra high") != null or
        std.mem.indexOf(u8, lower, "extra-high") != null) return "xhigh";
    if (hasWord(lower, "max") or hasWord(lower, "maximum")) return "max";
    if (hasWord(lower, "medium") or hasWord(lower, "mid")) return "medium";
    if (hasWord(lower, "high")) return "high";
    if (hasWord(lower, "low")) return "low";
    if (hasWord(lower, "none") or hasWord(lower, "minimal")) return "none";
    return null;
}

fn applyPeerEffort(ep: *types.Endpoint, goal: []const u8, explicit_model: bool) void {
    const ladder = if (models.lookup(ep.id, ep.model)) |m| m.efforts else "";
    ep.effort = "";
    if (explicit_model) {
        if (effortFrom(goal)) |want| {
            if (ladderHas(ladder, want)) {
                ep.effort = want;
                return;
            }
        }
    }
    ep.effort = autoeffort.resolve(ladder, goal, 0);
}

fn scoreCandidate(goal: Goal, c: Candidate, main_model: []const u8) f64 {
    if (c.model.context_window != 0 and c.model.context_window < goal.min_context) return -1e9;
    var s = model_signals.benchTier(c.model.id) * goal.bench_weight;
    if (goal.coding and c.model.reasoning) s += 8;
    if (goal.coding and std.mem.indexOf(u8, c.model.id, "codex") != null) s += 12;
    if (goal.quick and (std.mem.indexOf(u8, c.model.id, "flash") != null or
        std.mem.indexOf(u8, c.model.id, "fast") != null)) s += 15;
    if (goal.research and c.model.reasoning) s += 6;
    if (model_signals.priceFor(c.model.id)) |p| {
        s -= (p.prompt + p.completion) * 0.02 * goal.cost_weight;
    }
    const is_main = std.mem.eql(u8, c.model.id, main_model);
    const main_tier = model_signals.benchTier(main_model);
    if (is_main) {
        if (goal.quick) s += 14;
        if (goal.research and !goal.coding) s += 10;
        if (!goal.coding and !goal.quick and goal.bench_weight <= 1) s += 6;
    } else if (goal.quick and main_tier > 80) {
        s += 10;
    }
    return s;
}

fn pickCandidate(
    lookup: env.Lookup,
    auth_json: []const u8,
    main_model: []const u8,
    goal: []const u8,
) ?Candidate {
    var buf: [max_candidates]Candidate = undefined;
    const n = collectCandidates(lookup, auth_json, &buf);
    if (n == 0) return null;
    const g = classifyGoal(goal);
    var best_i: usize = 0;
    var best_score = scoreCandidate(g, buf[0], main_model);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const sc = scoreCandidate(g, buf[i], main_model);
        if (sc > best_score) {
            best_score = sc;
            best_i = i;
        }
    }
    if (best_score < -1e8) return null;
    return buf[best_i];
}

fn dupEndpoint(allocator: std.mem.Allocator, ep: types.Endpoint) RouterError!types.Endpoint {
    var out = ep;
    out.base_url = try allocator.dupe(u8, ep.base_url);
    out.api_key = try allocator.dupe(u8, ep.api_key);
    out.model = try allocator.dupe(u8, ep.model);
    return out;
}

pub fn deinitEndpoint(allocator: std.mem.Allocator, ep: *types.Endpoint) void {
    allocator.free(ep.base_url);
    allocator.free(ep.api_key);
    allocator.free(ep.model);
    ep.* = .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "",
    };
}

pub fn promptBlock(
    allocator: std.mem.Allocator,
    lookup: env.Lookup,
    auth_json: []const u8,
    main: types.Endpoint,
) ![]u8 {
    var buf: [max_candidates]Candidate = undefined;
    const n = collectCandidates(lookup, auth_json, &buf);
    if (n == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Peer catalog (signed-in). Pin in the goal in plain words, e.g. sonnet 5 from anthropic. Thinking is auto unless you name a level: ");
    var listed_n: usize = 0;
    var seen_main = false;
    if (models.lookup(main.id, main.model)) |m| {
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, " (");
        try out.appendSlice(allocator, main.id);
        try out.append(allocator, ')');
        listed_n = 1;
        seen_main = true;
    }
    var i: usize = 0;
    while (i < n and listed_n < catalog_max) : (i += 1) {
        if (seen_main and std.mem.eql(u8, buf[i].spec.id, main.id) and
            std.mem.eql(u8, buf[i].model.id, main.model)) continue;
        var j: usize = 0;
        var dup = false;
        while (j < i) : (j += 1) {
            if (std.mem.eql(u8, buf[j].spec.id, buf[i].spec.id) and
                std.mem.eql(u8, buf[j].model.id, buf[i].model.id))
            {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (listed_n != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, buf[i].model.name);
        try out.appendSlice(allocator, " (");
        try out.appendSlice(allocator, buf[i].spec.id);
        try out.append(allocator, ')');
        listed_n += 1;
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn finish(allocator: std.mem.Allocator, ep: types.Endpoint, goal: []const u8, explicit_model: bool) types.Endpoint {
    _ = allocator;
    var out = ep;
    applyPeerEffort(&out, goal, explicit_model);
    return out;
}

pub fn endpoint(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    lookup: env.Lookup,
    auth_json: []const u8,
    main: types.Endpoint,
    goal: []const u8,
) RouterError!types.Endpoint {
    if (goalHint(goal, lookup, auth_json)) |hint| {
        if (auth.resolveStored(lookup, auth_json, hint.provider, hint.model)) |resolved| {
            const ep = catalog.ownedEndpoint(allocator, resolved) orelse return error.OutOfMemory;
            return finish(allocator, ep, goal, true);
        }
    }

    model_signals.ensure(allocator, io, home);
    const picked = pickCandidate(lookup, auth_json, main.model, goal) orelse {
        log.debug("peer router: no candidate; using main model", .{});
        return finish(allocator, try dupEndpoint(allocator, main), goal, false);
    };
    const resolved = auth.resolveStored(lookup, auth_json, picked.spec.id, picked.model.id) orelse
        return RouterError.NoCredential;
    const ep = catalog.ownedEndpoint(allocator, resolved) orelse return error.OutOfMemory;
    return finish(allocator, ep, goal, false);
}

test "classifyGoal marks coding tasks" {
    const g = classifyGoal("fix the failing unit test in agent.zig");
    try std.testing.expect(g.coding);
    try std.testing.expect(g.min_context >= 32_000);
}

test "goal slash hint parses provider model" {
    const h = goalSlashHint("please use anthropic-api/claude-sonnet-4-6 on the tests").?;
    try std.testing.expectEqualStrings("anthropic-api", h.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", h.model);
}

test "goal phrase hint matches plain words" {
    const h = goalPhraseHint(
        "use sonnet 5 from anthropic to fix this",
        (env.Table{
            .pairs = &.{.{ .key = "COMMANDCODE_API_KEY", .value = "sk-cc" }},
        }).lookup(),
        "{}",
    ).?;
    try std.testing.expectEqualStrings("commandcode-anthropic", h.provider);
    try std.testing.expectEqualStrings("claude-sonnet-5", h.model);
}

test "named level only applies with explicit model ask" {
    var ep = types.Endpoint{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-5.6-sol",
        .id = "openai",
    };
    applyPeerEffort(&ep, "fix the tests at high effort", false);
    try std.testing.expect(!std.mem.eql(u8, ep.effort, "high"));

    ep.effort = "xhigh";
    applyPeerEffort(&ep, "use gpt 5.6 sol from openai at high effort", true);
    try std.testing.expectEqualStrings("high", ep.effort);
}

test "quick goals favor the main model" {
    const main = "claude-opus-4-8";
    var buf: [max_candidates]Candidate = undefined;
    buf[0] = .{
        .spec = catalog.byId("anthropic-api").?,
        .model = .{
            .id = main,
            .name = main,
            .provider = "anthropic-api",
            .protocol = .anthropic,
            .base_url = "",
            .reasoning = true,
            .context_window = 200_000,
            .max_tokens = 8192,
            .efforts = "",
            .vision = false,
        },
    };
    buf[1] = .{
        .spec = catalog.byId("openai").?,
        .model = .{
            .id = "gpt-5.6-sol",
            .name = "GPT 5.6 Sol",
            .provider = "openai",
            .protocol = .openai_compat,
            .base_url = "",
            .reasoning = false,
            .context_window = 128_000,
            .max_tokens = 8192,
            .efforts = "",
            .vision = false,
        },
    };
    const g = classifyGoal("list the test files");
    try std.testing.expect(g.quick);
    const main_score = scoreCandidate(g, buf[0], main);
    const alt_score = scoreCandidate(g, buf[1], main);
    try std.testing.expect(main_score > alt_score);
}
