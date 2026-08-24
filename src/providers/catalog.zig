const std = @import("std");
const types = @import("types.zig");
const oauth = @import("oauth.zig");
const models = @import("models.zig");
const env_mod = @import("../core/env.zig");

/// One named backend.
///
/// Scoped deliberately to three vendors and their subscription logins, ported
/// from `oh-my-pi/packages/ai/src/registry/oauth` (Anthropic PKCE, OpenAI Codex
/// PKCE + device, xAI device). Every constant below matches that source; the
/// flows themselves live in `oauth.zig`.
///
/// A row is either an API key you paste, or a subscription you already pay for.
/// Both land in the same `~/.omfx/auth.json`, and `auth.zig` prefers a stored
/// OAuth token over a leftover `*_API_KEY` in the environment.
pub const Spec = struct {
    id: []const u8,
    /// Shown in `/login`. The vendor's own wording for what you are signing in to.
    name: []const u8,
    /// Checked before `env_key`, so a subscription beats a stray API key.
    oauth_env: []const u8 = "",
    env_key: []const u8 = "",
    base_url: []const u8,
    model: []const u8,
    protocol: types.Protocol,
    login: oauth.Login = .api_key,
    /// Non-default request path (Codex speaks Responses at its own route).
    path: []const u8 = "",
    /// Local or subscription hosts are not auto-detected from the environment.
    explicit: bool = false,
    /// A subscription row has no API key to find; presence of a token is enough.
    keyless_explicit: bool = false,

    /// The first non-empty of `oauth_env` then `env_key`, by class.
    pub fn envValue(self: Spec, env: env_mod.Lookup, class: types.Credential.Kind) ?[]const u8 {
        const key = switch (class) {
            .oauth => self.oauth_env,
            .api_key => self.env_key,
        };
        if (key.len == 0) return null;
        const v = env.get(key) orelse return null;
        return if (v.len == 0) null else v;
    }
};

/// Anthropic, OpenAI, and xAI: an API-key row and a subscription row each.
///
/// Subscription rows come first so `resolve` prefers them when both are
/// present -- a Claude Pro token should win over a leftover ANTHROPIC_API_KEY.
pub const all = [_]Spec{
    .{
        .id = "anthropic",
        .name = "Anthropic (Claude Pro/Max)",
        .oauth_env = "ANTHROPIC_OAUTH_TOKEN",
        .env_key = "ANTHROPIC_API_KEY",
        .base_url = "https://api.anthropic.com",
        .model = "claude-opus-4-8",
        .protocol = .anthropic,
        .login = .{ .pkce = .anthropic },
        .keyless_explicit = true,
    },
    .{
        .id = "anthropic-api",
        .name = "Anthropic API key",
        .env_key = "ANTHROPIC_API_KEY",
        .base_url = "https://api.anthropic.com",
        .model = "claude-opus-4-8",
        .protocol = .anthropic,
    },
    .{
        .id = "openai-codex",
        .name = "ChatGPT Plus/Pro",
        .oauth_env = "OPENAI_CODEX_OAUTH_TOKEN",
        // Codex talks to its own backend, not api.openai.com.
        .base_url = "https://chatgpt.com/backend-api",
        .path = "/codex/responses",
        .model = "gpt-5.6-sol",
        .protocol = .openai_responses,
        .login = .{ .pkce = .chatgpt },
        .keyless_explicit = true,
    },
    .{
        .id = "openai-codex-device",
        .name = "ChatGPT Plus/Pro (device code)",
        .oauth_env = "OPENAI_CODEX_OAUTH_TOKEN",
        .base_url = "https://chatgpt.com/backend-api",
        .path = "/codex/responses",
        .model = "gpt-5.6-sol",
        .protocol = .openai_responses,
        .login = .{ .device = .chatgpt },
        .keyless_explicit = true,
    },
    .{
        .id = "openai",
        .name = "OpenAI API key",
        .env_key = "OPENAI_API_KEY",
        .base_url = "https://api.openai.com/v1",
        .model = "gpt-5.5",
        .protocol = .openai_compat,
    },
    .{
        .id = "xai-oauth",
        .name = "xAI Grok (SuperGrok or X Premium+)",
        .oauth_env = "XAI_OAUTH_TOKEN",
        .base_url = "https://api.x.ai/v1",
        .model = "grok-4.6",
        .protocol = .openai_compat,
        .login = .{ .device = .xai },
        .keyless_explicit = true,
    },
    .{
        // One key, every vendor's models, at the vendor's own rates. Claude
        // models take the Anthropic shape and everything else takes the
        // OpenAI one, at two different routes on the same host -- sending a
        // Claude model to /chat/completions returns a 400 pointing at
        // /messages -- so this row speaks OpenAI and the Anthropic models are
        // reached through `commandcode-anthropic`.
        .id = "commandcode",
        .name = "Command Code",
        .env_key = "COMMANDCODE_API_KEY",
        .base_url = "https://api.commandcode.ai/provider/v1",
        .model = "deepseek/deepseek-v4-flash",
        .protocol = .openai_compat,
    },
    .{
        .id = "commandcode-anthropic",
        .name = "Command Code (Claude models)",
        .env_key = "COMMANDCODE_API_KEY",
        .base_url = "https://api.commandcode.ai/provider/v1",
        .model = "claude-sonnet-4-6",
        .protocol = .anthropic,
        .explicit = true,
    },
    .{
        .id = "xai-api",
        .name = "xAI API key",
        .env_key = "XAI_API_KEY",
        .base_url = "https://api.x.ai/v1",
        .model = "grok-4.6",
        .protocol = .openai_compat,
    },
};

comptime {
    if (all.len == 0) @compileError("the catalog must offer at least one backend");
}

/// A vendor's short name points at the subscription row, so `--provider xai`
/// picks up a stored SuperGrok token instead of a leftover `XAI_API_KEY`.
/// The plain-key rows keep explicit `-api` ids for anyone who wants them.
const aliases = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "xai", .to = "xai-oauth" },
    .{ .from = "chatgpt", .to = "openai-codex" },
    .{ .from = "claude", .to = "anthropic" },
};

pub fn byId(id: []const u8) ?Spec {
    for (all) |spec| {
        if (std.mem.eql(u8, spec.id, id)) return spec;
    }
    for (aliases) |a| {
        if (!std.mem.eql(u8, a.from, id)) continue;
        for (all) |spec| {
            if (std.mem.eql(u8, spec.id, a.to)) return spec;
        }
    }
    return null;
}

/// Key under which a credential is stored in `~/.omfx/auth.json`.
///
/// Rows that share a login share a slot: signing in once through the Codex PKCE
/// flow also satisfies the device-code row. Exact, never a prefix -- `xai` must
/// not read `xai-oauth`'s token, which is the bug this function exists to stop.
pub fn storeId(spec: Spec) []const u8 {
    if (std.mem.eql(u8, spec.id, "openai-codex-device")) return "openai-codex";
    if (std.mem.eql(u8, spec.id, "anthropic-api")) return "anthropic";
    if (std.mem.eql(u8, spec.id, "xai-api")) return "xai-api";
    return spec.id;
}

pub fn vendorOf(spec: Spec) types.Vendor {
    if (std.mem.startsWith(u8, spec.id, "anthropic")) return .anthropic;
    if (std.mem.startsWith(u8, spec.id, "xai")) return .xai;
    return .openai;
}

pub const Resolved = struct {
    spec: Spec,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
};

fn finish(env: env_mod.Lookup, spec: Spec) ?Resolved {
    // OAuth first: a subscription token outranks a leftover API key.
    const key = spec.envValue(env, .oauth) orelse spec.envValue(env, .api_key) orelse
        (if (spec.keyless_explicit) "" else return null);
    const base = env.get("OMFX_BASE_URL") orelse spec.base_url;
    return .{
        .spec = spec,
        .api_key = key,
        .base_url = if (base.len == 0) spec.base_url else base,
        .model = env.get("OMFX_MODEL") orelse spec.model,
    };
}

/// `OMFX_PROVIDER` names a row. Otherwise the first row with a usable
/// credential wins, in table order.
pub fn resolve(env: env_mod.Lookup) ?Resolved {
    if (env.get("OMFX_PROVIDER")) |name| {
        if (name.len > 0) {
            const spec = byId(name) orelse return null;
            return finish(env, spec);
        }
    }
    for (all) |spec| {
        if (spec.explicit) continue;
        if (spec.envValue(env, .oauth) != null or spec.envValue(env, .api_key) != null) {
            return finish(env, spec);
        }
    }
    return null;
}

/// The row says what the vendor speaks by default; the model table says what
/// *this* model speaks. A row-level protocol would send `grok-composer-2.5-fast`
/// (Responses) as a chat-completions request, and the model then answers in
/// prose without ever emitting a tool call.
pub fn toEndpoint(resolved: Resolved) types.Endpoint {
    const spec = resolved.spec;
    var ep = types.Endpoint{
        .id = spec.id,
        .vendor = vendorOf(spec),
        .protocol = spec.protocol,
        .base_url = resolved.base_url,
        .api_key = resolved.api_key,
        .model = resolved.model,
        .path = spec.path,
    };
    if (models.lookup(storeId(spec), resolved.model) orelse
        models.lookup(spec.id, resolved.model)) |m|
    {
        ep.protocol = m.protocol;
        ep.context_window = m.context_window;
        ep.max_output_tokens = m.max_tokens;
    }
    return ep;
}

/// Same, with every string owned by `allocator`: the session outlives the
/// environment slices `resolve` borrowed from.
///
/// Null on allocation failure rather than an error, because the callers turn a
/// missing endpoint into "no provider configured" either way.
pub fn ownedEndpoint(allocator: std.mem.Allocator, resolved: Resolved) ?types.Endpoint {
    var ep = toEndpoint(resolved);
    ep.base_url = allocator.dupe(u8, ep.base_url) catch return null;
    ep.api_key = allocator.dupe(u8, ep.api_key) catch return null;
    ep.model = allocator.dupe(u8, ep.model) catch return null;
    return ep;
}

pub fn idsComma(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (all, 0..) |spec, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, spec.id);
    }
    return out.toOwnedSlice(allocator);
}

test "every row is reachable by id and has a store slot" {
    for (all) |spec| {
        try std.testing.expect(byId(spec.id) != null);
        try std.testing.expect(storeId(spec).len > 0);
        try std.testing.expect(spec.base_url.len > 0);
        try std.testing.expect(spec.model.len > 0);
        // A row you cannot authenticate is a row that cannot work.
        try std.testing.expect(spec.oauth_env.len > 0 or spec.env_key.len > 0);
    }
}

test "a stored subscription token is preferred over a plain key row" {
    // `--provider xai` with a SuperGrok token must not fall back to a leftover
    // XAI_API_KEY, so the short name resolves to the subscription row.
    try std.testing.expectEqualStrings("xai-oauth", byId("xai").?.id);
    try std.testing.expectEqualStrings("anthropic", byId("claude").?.id);
    try std.testing.expectEqualStrings("openai-codex", byId("chatgpt").?.id);
    // The plain-key rows are still reachable, under their own slots.
    try std.testing.expectEqualStrings("xai-api", storeId(byId("xai-api").?));
    try std.testing.expect(!std.mem.eql(u8, storeId(byId("xai-api").?), storeId(byId("xai-oauth").?)));
}

test "rows that share a login share a store slot" {
    // Signing in once through Codex PKCE must satisfy the device-code row.
    try std.testing.expectEqualStrings("openai-codex", storeId(byId("openai-codex").?));
    try std.testing.expectEqualStrings("openai-codex", storeId(byId("openai-codex-device").?));
}

test "a subscription token outranks a leftover api key" {
    const table = env_mod.Table{ .pairs = &.{
        .{ .key = "ANTHROPIC_API_KEY", .value = "sk-ant-leftover" },
        .{ .key = "ANTHROPIC_OAUTH_TOKEN", .value = "oauth-live" },
    } };
    const r = resolve(table.lookup()).?;
    try std.testing.expectEqualStrings("anthropic", r.spec.id);
    try std.testing.expectEqualStrings("oauth-live", r.api_key);
}

test "an api key alone still resolves" {
    const table = env_mod.Table{ .pairs = &.{
        .{ .key = "XAI_API_KEY", .value = "xai-key" },
    } };
    const r = resolve(table.lookup()).?;
    try std.testing.expectEqualStrings("xai-api", r.spec.id);
    try std.testing.expectEqualStrings("xai-key", r.api_key);
    try std.testing.expectEqualStrings("https://api.x.ai/v1", r.base_url);
}

test "an empty environment resolves to nothing" {
    const table = env_mod.Table{ .pairs = &.{} };
    try std.testing.expect(resolve(table.lookup()) == null);
}

test "OMFX_PROVIDER selects a row even when another has a key" {
    const table = env_mod.Table{ .pairs = &.{
        .{ .key = "XAI_API_KEY", .value = "xai-key" },
        .{ .key = "OPENAI_API_KEY", .value = "sk-openai" },
        .{ .key = "OMFX_PROVIDER", .value = "openai" },
    } };
    const r = resolve(table.lookup()).?;
    try std.testing.expectEqualStrings("openai", r.spec.id);
}

test "codex carries its own path and protocol" {
    const spec = byId("openai-codex").?;
    try std.testing.expectEqual(types.Protocol.openai_responses, spec.protocol);
    try std.testing.expectEqualStrings("/codex/responses", spec.path);
    // Codex is not api.openai.com; sending a subscription token there fails.
    try std.testing.expect(std.mem.indexOf(u8, spec.base_url, "chatgpt.com") != null);
}

test "each vendor maps to its own wire protocol" {
    try std.testing.expectEqual(types.Vendor.anthropic, vendorOf(byId("anthropic").?));
    try std.testing.expectEqual(types.Vendor.anthropic, vendorOf(byId("anthropic-api").?));
    try std.testing.expectEqual(types.Vendor.xai, vendorOf(byId("xai-oauth").?));
    try std.testing.expectEqual(types.Vendor.openai, vendorOf(byId("openai-codex").?));
    try std.testing.expectEqual(types.Protocol.anthropic, byId("anthropic").?.protocol);
}

test "every subscription row names a real login flow" {
    for (all) |spec| {
        if (!spec.keyless_explicit) continue;
        try std.testing.expect(spec.login != .api_key);
        try std.testing.expect(spec.oauth_env.len > 0);
    }
}

test "ids comma lists the table" {
    const s = try idsComma(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "openai-codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "xai-oauth") != null);
}

test "the model table overrides the row protocol" {
    // grok-composer-2.5-fast speaks Responses even though the xai row defaults
    // to chat-completions. Sending it as compat loses every tool call.
    const r = Resolved{
        .spec = byId("xai-oauth").?,
        .api_key = "tok",
        .base_url = "https://api.x.ai/v1",
        .model = "grok-composer-2.5-fast",
    };
    const ep = toEndpoint(r);
    try std.testing.expectEqual(types.Protocol.openai_responses, ep.protocol);
    try std.testing.expect(ep.context_window > 0);
    try std.testing.expect(ep.max_output_tokens > 1024);
}

test "an unknown model keeps the row default" {
    const r = Resolved{
        .spec = byId("openai").?,
        .api_key = "sk",
        .base_url = "https://api.openai.com/v1",
        .model = "some-model-not-in-the-table",
    };
    try std.testing.expectEqual(types.Protocol.openai_compat, toEndpoint(r).protocol);
}
