const std = @import("std");
const types = @import("types.zig");

/// The fallback when a provider will not describe its own models.
///
/// `registry.zig` asks the provider first; this is what is left when the ask
/// fails, when the provider publishes nothing (OpenAI's /v1/models is ids
/// only), or when it publishes everything except the field wanted (only
/// Anthropic publishes effort levels).
///
/// Effort vocabularies are per vendor and per model, and a level the model
/// does not take is a rejected request, so these are transcribed from the
/// vendor docs rather than inferred:
///
///   xAI      low|medium|high|xhigh, default high, reasoning cannot be
///            disabled. `xhigh` is grok-4.6 and later; on grok-4.5 it is
///            silently treated as `high`. There is no `minimal`.
///            docs.x.ai/developers/model-capabilities/text/reasoning
///   OpenAI   per model, and there is no `minimal` on anything current:
///              gpt-5.6 (sol/terra/luna)  none|low|medium|high|xhigh|max
///              gpt-5.5                   none|low|medium|high|xhigh
///              gpt-5.x-codex             low|medium|high|xhigh
///            `max` is gpt-5.6 and later. `ultra` is not an effort value at
///            all -- it is a Codex mode that fans work out to subagents.
///            developers.openai.com/api/docs/guides/latest-model
///   Anthropic  published per model in the models endpoint; see registry.zig.
///
/// Context windows are per auth route as well as per model: see
/// `registry.authCap`. Checked 2026-08-22.
pub const Model = @import("models/model.zig").Model;

/// Catalog rows live in `models/table.zig`; lookup stays here.
pub const all = @import("models/table.zig").all;

pub fn lookup(provider: []const u8, id: []const u8) ?Model {
    for (all) |m| {
        if (std.mem.eql(u8, m.provider, provider) and std.mem.eql(u8, m.id, id)) return m;
    }
    for (all) |m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

pub fn forProvider(provider: []const u8, out: []Model) usize {
    var n: usize = 0;
    for (all) |m| {
        if (!std.mem.eql(u8, m.provider, provider)) continue;
        if (n >= out.len) break;
        out[n] = m;
        n += 1;
    }
    return n;
}

test "no model offers a level its vendor does not have" {
    for (all) |m| {
        var it = std.mem.splitScalar(u8, m.efforts, ',');
        while (it.next()) |level| {
            if (level.len == 0) continue;
            const known = std.mem.eql(u8, level, "none") or
                std.mem.eql(u8, level, "low") or
                std.mem.eql(u8, level, "medium") or
                std.mem.eql(u8, level, "high") or
                std.mem.eql(u8, level, "xhigh") or
                std.mem.eql(u8, level, "max");
            try std.testing.expect(known);
            // Nothing current takes `minimal`: xAI never had it, and OpenAI
            // spells its floor `none`. A request carrying it is rejected.
            try std.testing.expect(!std.mem.eql(u8, level, "minimal"));
            // `ultra` is a Codex mode, not an effort value.
            try std.testing.expect(!std.mem.eql(u8, level, "ultra"));
        }
        // A model with levels reasons, and one that reasons is not zero-window.
        if (m.efforts.len != 0) try std.testing.expect(m.reasoning);
        try std.testing.expect(m.context_window > 0);
    }
}

test "a subscription row carries the subscription window, not the API one" {
    const sub = lookup("openai-codex", "gpt-5.6-sol").?;
    try std.testing.expectEqual(@as(u32, 400_000), sub.context_window);
    const api = lookup("openai", "gpt-5.6").?;
    try std.testing.expect(api.context_window > sub.context_window);

    const pro = lookup("anthropic", "claude-opus-4-8").?;
    const key = lookup("anthropic-api", "claude-opus-4-8").?;
    // 1M needs the context-1m beta header, which a Pro/Max token cannot send.
    try std.testing.expectEqual(@as(u32, 200_000), pro.context_window);
    try std.testing.expectEqual(@as(u32, 1_000_000), key.context_window);
}

test "a provider string that is not a catalog id makes its rows unreachable" {
    for (all) |m| {
        if (@import("catalog.zig").byId(m.provider) == null) {
            std.debug.print("{s} is not a provider id\n", .{m.provider});
            return error.UnknownProvider;
        }
    }
}

test "every catalog default model is in the table" {
    for (@import("catalog.zig").all) |spec| {
        if (lookup(spec.id, spec.model) == null) {
            std.debug.print("no row for {s}/{s}\n", .{ spec.id, spec.model });
            return error.MissingModelRow;
        }
    }
}

test "grok-4.6 oauth has window and efforts" {
    const m = lookup("xai-oauth", "grok-4.6").?;
    try std.testing.expectEqual(@as(u32, 500_000), m.context_window);
    try std.testing.expectEqual(@as(u32, 500_000), m.max_tokens);
    try std.testing.expect(m.reasoning);
    try std.testing.expect(std.mem.indexOf(u8, m.efforts, "high") != null);
    try std.testing.expectEqual(types.Protocol.openai_responses, m.protocol);
}

test "xai-oauth lists nine models" {
    var buf: [16]Model = undefined;
    const n = forProvider("xai-oauth", &buf);
    try std.testing.expectEqual(@as(usize, 9), n);
}

test "command code vision is carried here, because the catalog does not publish it" {
    // Their /models route returns id, name and context_length only. If this
    // table says text-only, the picker says text-only, and a model that reads
    // images looks like one that cannot.
    var vision: usize = 0;
    var total: usize = 0;
    for (all) |m| {
        if (!std.mem.eql(u8, m.provider, "commandcode")) continue;
        total += 1;
        if (m.vision) vision += 1;
    }
    try std.testing.expectEqual(@as(usize, 58), total);
    try std.testing.expectEqual(@as(usize, 40), vision);

    try std.testing.expect(lookup("commandcode", "claude-opus-5").?.vision);
    try std.testing.expect(lookup("commandcode", "google/gemini-3.7-flash").?.vision);
    try std.testing.expect(lookup("commandcode", "Qwen/Qwen3.8-27B").?.vision);
    // Named for vision and still text-only upstream: taken from their table,
    // not from the id.
    try std.testing.expect(!lookup("commandcode", "deepseek/deepseek-v4-flash").?.vision);
}
