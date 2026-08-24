const std = @import("std");
const Io = std.Io;
const auth = @import("../providers/auth.zig");
const settings = @import("../core/settings.zig");
const clean = @import("web_clean.zig");

pub const Kind = enum {
    api_key,
    endpoint,
    free,
};

pub const Spec = struct {
    id: []const u8,
    name: []const u8,
    env_keys: []const []const u8,
    kind: Kind,
    /// Only used when present in `order`.
    explicit_only: bool = false,
    /// Extra auth.json keys (model logins) that also unlock this search backend.
    auth_ids: []const []const u8 = &.{},
    /// Listed in `order` without a key (Exa MCP, Firecrawl, Perplexity anonymous).
    keyless_explicit: bool = false,
};

/// Pick-list id for the guided "set search order" row. Not a real backend.
pub const order_pick_id = "_order";
/// Pick-list id to drop a custom order and use the catalog default chain.
pub const default_pick_id = "_default";

pub const all = [_]Spec{
    .{ .id = "perplexity", .name = "Perplexity", .env_keys = &.{"PERPLEXITY_API_KEY"}, .kind = .api_key, .auth_ids = &.{"perplexity"}, .keyless_explicit = true },
    .{ .id = "zai", .name = "Z.AI web_search_prime", .env_keys = &.{"ZAI_API_KEY"}, .kind = .api_key, .auth_ids = &.{"zai"} },
    .{ .id = "exa", .name = "Exa", .env_keys = &.{"EXA_API_KEY"}, .kind = .api_key, .keyless_explicit = true },
    .{ .id = "tinyfish", .name = "TinyFish", .env_keys = &.{"TINYFISH_API_KEY"}, .kind = .api_key },
    .{ .id = "jina", .name = "Jina", .env_keys = &.{"JINA_API_KEY"}, .kind = .api_key },
    .{ .id = "kagi", .name = "Kagi", .env_keys = &.{"KAGI_API_KEY"}, .kind = .api_key },
    .{ .id = "tavily", .name = "Tavily", .env_keys = &.{"TAVILY_API_KEY"}, .kind = .api_key },
    .{ .id = "firecrawl", .name = "Firecrawl", .env_keys = &.{"FIRECRAWL_API_KEY"}, .kind = .api_key, .keyless_explicit = true },
    .{ .id = "brave", .name = "Brave Search", .env_keys = &.{"BRAVE_API_KEY"}, .kind = .api_key },
    .{ .id = "kimi", .name = "Kimi search", .env_keys = &.{ "MOONSHOT_SEARCH_API_KEY", "KIMI_SEARCH_API_KEY" }, .kind = .api_key, .auth_ids = &.{"kimi-code"} },
    .{ .id = "parallel", .name = "Parallel", .env_keys = &.{"PARALLEL_API_KEY"}, .kind = .api_key },
    .{ .id = "synthetic", .name = "Synthetic search", .env_keys = &.{"SYNTHETIC_API_KEY"}, .kind = .api_key },
    .{ .id = "searxng", .name = "SearXNG", .env_keys = &.{ "SEARXNG_ENDPOINT", "SEARXNG_TOKEN" }, .kind = .endpoint },
    .{ .id = "startpage", .name = "Startpage", .env_keys = &.{}, .kind = .free },
    .{ .id = "duckduckgo", .name = "DuckDuckGo", .env_keys = &.{}, .kind = .free },
    .{ .id = "ecosia", .name = "Ecosia", .env_keys = &.{}, .kind = .free },
    .{ .id = "google", .name = "Google SERP", .env_keys = &.{}, .kind = .free },
    .{ .id = "mojeek", .name = "Mojeek", .env_keys = &.{}, .kind = .free },
    .{ .id = "public", .name = "Public Web (fan-out)", .env_keys = &.{}, .kind = .free, .explicit_only = true },
};

pub fn byId(id: []const u8) ?Spec {
    for (all) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

pub fn byIndex(n: usize) ?Spec {
    if (n == 0 or n > all.len) return null;
    return all[n - 1];
}

fn processEnv(key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (key.len + 1 > buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const z = buf[0..key.len :0];
    const p = std.c.getenv(z) orelse return null;
    const s = std.mem.span(p);
    if (s.len == 0) return null;
    return s;
}

pub fn storeKey(id: []const u8, buf: *[48]u8) []const u8 {
    return std.fmt.bufPrint(buf, "web_search.{s}", .{id}) catch id;
}

pub fn credential(auth_json: []const u8, spec: Spec) ?[]const u8 {
    var buf: [48]u8 = undefined;
    if (auth.extractKey(auth_json, storeKey(spec.id, &buf))) |k| return k;
    if (auth.extractKey(auth_json, spec.id)) |k| return k;
    for (spec.auth_ids) |id| {
        if (auth.extractKey(auth_json, id)) |k| return k;
    }
    for (spec.env_keys) |key| {
        if (processEnv(key)) |k| return k;
    }
    return null;
}

pub fn isAvailable(spec: Spec, auth_json: []const u8, web: settings.Web, explicit: bool) bool {
    if (settings.excluded(web, spec.id) and !explicit) return false;
    return switch (spec.kind) {
        .free => if (spec.explicit_only) explicit else true,
        .endpoint => web.searxng_endpoint.len > 0 or processEnv("SEARXNG_ENDPOINT") != null,
        .api_key => credential(auth_json, spec) != null or (explicit and spec.keyless_explicit),
    };
}

/// True when a key or endpoint has been set up for this backend.
pub fn isConfigured(spec: Spec, auth_json: []const u8, web: settings.Web) bool {
    return switch (spec.kind) {
        .free => false,
        .endpoint => web.searxng_endpoint.len > 0 or processEnv("SEARXNG_ENDPOINT") != null,
        .api_key => credential(auth_json, spec) != null,
    };
}

pub const HomeCmd = union(enum) {
    cancel,
    pick: Spec,
    /// Guided flow: pick providers one by one, empty line saves.
    begin_order,
    /// Clear a custom order; the catalog default chain runs again.
    use_default,
    off: []const u8,
    on: []const u8,
    test_query: []const u8,
    unknown,
};

pub fn resolveToken(tok: []const u8) ?Spec {
    const t = std.mem.trim(u8, tok, " \t");
    if (t.len == 0) return null;
    if (std.fmt.parseInt(usize, t, 10)) |n| {
        if (byIndex(n)) |s| return s;
    } else |_| {}
    return byId(t);
}

pub fn parseOrder(text: []const u8, out: *[settings.max_ids][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitAny(u8, text, ", \t");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        const spec = resolveToken(tok) orelse continue;
        var seen = false;
        for (out[0..n]) |id| {
            if (std.mem.eql(u8, id, spec.id)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (n >= out.len) break;
        out[n] = spec.id;
        n += 1;
    }
    return n;
}

pub fn parseHome(line: []const u8) HomeCmd {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0) return .cancel;
    if (std.mem.eql(u8, t, "order") or std.mem.eql(u8, t, order_pick_id)) return .begin_order;
    if (std.mem.eql(u8, t, "default") or std.mem.eql(u8, t, default_pick_id)) return .use_default;
    if (std.mem.startsWith(u8, t, "off ")) {
        const spec = resolveToken(t[4..]) orelse return .unknown;
        return .{ .off = spec.id };
    }
    if (std.mem.startsWith(u8, t, "on ")) {
        const spec = resolveToken(t[3..]) orelse return .unknown;
        return .{ .on = spec.id };
    }
    if (std.mem.startsWith(u8, t, "test ")) {
        const q = std.mem.trim(u8, t[5..], " \t");
        if (q.len == 0) return .unknown;
        return .{ .test_query = q };
    }
    if (resolveToken(t)) |spec| return .{ .pick = spec };
    return .unknown;
}

pub fn prependOrder(web: settings.Web, id: []const u8, out: *[settings.max_ids][]const u8) usize {
    out[0] = id;
    var n: usize = 1;
    for (web.order) |oid| {
        if (std.mem.eql(u8, oid, id)) continue;
        if (n >= out.len) break;
        out[n] = oid;
        n += 1;
    }
    return n;
}

pub fn dropId(ids: []const []const u8, id: []const u8, out: *[settings.max_ids][]const u8) usize {
    var n: usize = 0;
    for (ids) |oid| {
        if (std.mem.eql(u8, oid, id)) continue;
        if (n >= out.len) break;
        out[n] = oid;
        n += 1;
    }
    return n;
}

pub fn addId(ids: []const []const u8, id: []const u8, out: *[settings.max_ids][]const u8) usize {
    const n = dropId(ids, id, out);
    if (n >= out.len) return n;
    out[n] = id;
    return n + 1;
}

pub fn resolveChain(web: settings.Web, out: *[settings.max_ids][]const u8) usize {
    var n: usize = 0;
    var seen: [all.len]bool = @splat(false);
    const listed = web.order;
    for (listed) |id| {
        const spec = byId(id) orelse continue;
        const idx = indexOf(spec.id) orelse continue;
        if (seen[idx]) continue;
        if (settings.excluded(web, spec.id)) continue;
        out[n] = spec.id;
        n += 1;
        seen[idx] = true;
    }
    if (listed.len == 0) {
        for (all) |spec| {
            if (spec.explicit_only) continue;
            if (settings.excluded(web, spec.id)) continue;
            out[n] = spec.id;
            n += 1;
        }
        return n;
    }
    for (all) |spec| {
        const idx = indexOf(spec.id) orelse continue;
        if (seen[idx]) continue;
        if (spec.explicit_only) continue;
        if (settings.excluded(web, spec.id)) continue;
        out[n] = spec.id;
        n += 1;
    }
    return n;
}

fn indexOf(id: []const u8) ?usize {
    for (all, 0..) |s, i| {
        if (std.mem.eql(u8, s.id, id)) return i;
    }
    return null;
}

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn formEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try (std.Uri.Component{ .raw = s }).formatQuery(&aw.writer);
    return aw.toOwnedSlice();
}

const HttpResult = struct { status: u16, body: []u8 };

const browser_headers = [_]std.http.Header{
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" },
    .{ .name = "accept", .value = "text/html,application/xhtml+xml" },
};

fn http(
    allocator: std.mem.Allocator,
    io: Io,
    method: std.http.Method,
    url: []const u8,
    content_type: []const u8,
    body: ?[]const u8,
    extra: []const std.http.Header,
) !HttpResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var loc_buf: [2048]u8 = undefined;
    const headers: std.http.Client.Request.Headers = .{
        .content_type = if (content_type.len > 0) .{ .override = content_type } else .omit,
        .authorization = .omit,
    };
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .headers = headers,
        .extra_headers = extra,
        .response_writer = &aw.writer,
        .redirect_buffer = &loc_buf,
        .redirect_behavior = @enumFromInt(5),
    }) catch |err| {
        return .{ .status = 0, .body = try std.fmt.allocPrint(allocator, "transport {s}", .{@errorName(err)}) };
    };
    return .{ .status = @intFromEnum(result.status), .body = try aw.toOwnedSlice() };
}

fn collectSources(allocator: std.mem.Allocator, provider: []const u8, body: []const u8, limit: usize, query: []const u8) ![]u8 {
    const hits = try clean.hitsFromJson(allocator, body, @min(limit, clean.max_hits));
    defer clean.freeHits(allocator, hits);
    if (hits.len == 0) {
        // Last resort: no structured hits — do not dump raw JSON into context.
        return std.fmt.allocPrint(allocator, "[{s}] {s}\n(no structured results)\n", .{ provider, query });
    }
    return clean.formatHits(allocator, provider, query, hits);
}

fn htmlLinks(allocator: std.mem.Allocator, provider: []const u8, body: []const u8, limit: usize, query: []const u8) ![]u8 {
    const hits = try clean.hitsFromHtml(allocator, body, @min(limit, clean.max_hits));
    defer clean.freeHits(allocator, hits);
    if (hits.len == 0) return error.EmptyResults;
    return clean.formatHits(allocator, provider, query, hits);
}

fn bearer(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
}

fn searchOne(
    allocator: std.mem.Allocator,
    io: Io,
    spec: Spec,
    query: []const u8,
    key: []const u8,
    web: settings.Web,
) ![]u8 {
    const qesc = try jsonEscape(allocator, query);
    defer allocator.free(qesc);
    const qform = try formEncode(allocator, query);
    defer allocator.free(qform);

    if (std.mem.eql(u8, spec.id, "tavily")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"api_key\":\"{s}\",\"query\":\"{s}\",\"max_results\":5,\"include_answer\":true}}", .{ key, qesc });
        defer allocator.free(body);
        const res = try http(allocator, io, .POST, "https://api.tavily.com/search", "application/json", body, &.{});
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 8, query);
    }
    if (std.mem.eql(u8, spec.id, "brave")) {
        const url = try std.fmt.allocPrint(allocator, "https://api.search.brave.com/res/v1/web/search?q={s}&count=10", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &.{
            .{ .name = "x-subscription-token", .value = key },
            .{ .name = "accept", .value = "application/json" },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "exa")) {
        if (key.len == 0) {
            const body = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"web_search_exa\",\"arguments\":{{\"query\":\"{s}\"}}}}}}", .{qesc});
            defer allocator.free(body);
            const res = try http(allocator, io, .POST, "https://mcp.exa.ai/mcp", "application/json", body, &.{});
            defer allocator.free(res.body);
            if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
            return collectSources(allocator, spec.id, res.body, 10, query);
        }
        const body = try std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\",\"numResults\":10}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .POST, "https://api.exa.ai/search", "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "jina")) {
        const url = try std.fmt.allocPrint(allocator, "https://s.jina.ai/{s}", .{qform});
        defer allocator.free(url);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .GET, url, "", null, &.{
            .{ .name = "authorization", .value = authz },
            .{ .name = "accept", .value = "application/json" },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "kagi")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\",\"limit\":10}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .POST, "https://kagi.com/api/v1/search", "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "firecrawl")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\",\"limit\":10}}", .{qesc});
        defer allocator.free(body);
        var extra_buf: [2]std.http.Header = undefined;
        var extra_len: usize = 0;
        var authz_buf: []u8 = &.{};
        if (key.len > 0) {
            authz_buf = try bearer(allocator, key);
            extra_buf[0] = .{ .name = "authorization", .value = authz_buf };
            extra_len = 1;
        }
        defer if (authz_buf.len > 0) allocator.free(authz_buf);
        const res = try http(allocator, io, .POST, "https://api.firecrawl.dev/v2/search", "application/json", body, extra_buf[0..extra_len]);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "tinyfish")) {
        const url = try std.fmt.allocPrint(allocator, "https://api.search.tinyfish.ai?query={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &.{.{ .name = "x-api-key", .value = key }});
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "parallel")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"objective\":\"{s}\",\"search_queries\":[\"{s}\"],\"mode\":\"fast\"}}", .{ qesc, qesc });
        defer allocator.free(body);
        const res = try http(allocator, io, .POST, "https://api.parallel.ai/v1beta/search", "application/json", body, &.{
            .{ .name = "x-api-key", .value = key },
            .{ .name = "parallel-beta", .value = "search-extract-2025-10-10" },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "synthetic")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\"}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .POST, "https://api.synthetic.new/v2/search", "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "perplexity")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"model\":\"sonar-pro\",\"search_mode\":\"web\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .POST, "https://api.perplexity.ai/chat/completions", "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 8, query);
    }
    if (std.mem.eql(u8, spec.id, "kimi")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"text_query\":\"{s}\",\"limit\":10,\"enable_page_crawling\":false}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .POST, "https://api.kimi.com/coding/v1/search", "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "zai")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"web_search_prime\",\"arguments\":{{\"query\":\"{s}\",\"count\":10}}}}}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .POST, "https://api.z.ai/api/mcp/web_search_prime/mcp", "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "searxng")) {
        const endpoint = if (web.searxng_endpoint.len > 0) web.searxng_endpoint else (processEnv("SEARXNG_ENDPOINT") orelse return error.ProviderFailed);
        const base = std.mem.trimEnd(u8, endpoint, "/");
        const url = try std.fmt.allocPrint(allocator, "{s}/search?format=json&q={s}", .{ base, qform });
        defer allocator.free(url);
        var extra: [1]std.http.Header = undefined;
        var extra_len: usize = 0;
        var authz_buf: []u8 = &.{};
        if (key.len > 0) {
            authz_buf = try bearer(allocator, key);
            extra[0] = .{ .name = "authorization", .value = authz_buf };
            extra_len = 1;
        }
        defer if (authz_buf.len > 0) allocator.free(authz_buf);
        const res = try http(allocator, io, .GET, url, "", null, extra[0..extra_len]);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "public")) {
        const engines = [_][]const u8{ "startpage", "duckduckgo", "ecosia", "google", "mojeek" };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "[public]\n");
        var hits: usize = 0;
        for (engines) |eid| {
            if (settings.excluded(web, eid)) continue;
            const engine = byId(eid) orelse continue;
            if (searchOne(allocator, io, engine, query, "", web)) |text| {
                defer allocator.free(text);
                try out.appendSlice(allocator, text);
                hits += 1;
                if (hits >= 3) break;
            } else |_| {}
        }
        if (hits == 0) return error.ProviderFailed;
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.eql(u8, spec.id, "duckduckgo")) {
        const body = try std.fmt.allocPrint(allocator, "q={s}&kl=us-en", .{qform});
        defer allocator.free(body);
        const res = try http(allocator, io, .POST, "https://html.duckduckgo.com/html/", "application/x-www-form-urlencoded", body, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        if (std.mem.indexOf(u8, res.body, "anomaly-modal") != null) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "startpage")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.startpage.com/sp/search?query={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "ecosia")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.ecosia.org/search?q={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "google")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.google.com/search?q={s}&hl=en", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10, query);
    }
    if (std.mem.eql(u8, spec.id, "mojeek")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.mojeek.com/search?q={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10, query);
    }
    return error.ProviderFailed;
}

pub fn search(
    allocator: std.mem.Allocator,
    io: Io,
    query: []const u8,
    auth_json: []const u8,
    web: settings.Web,
) ![]u8 {
    if (query.len == 0) return allocator.dupe(u8, "Error: empty query\n");
    var chain_buf: [settings.max_ids][]const u8 = undefined;
    const chain_n = resolveChain(web, &chain_buf);
    var fails: std.ArrayList(u8) = .empty;
    defer fails.deinit(allocator);
    var attempted: usize = 0;
    for (chain_buf[0..chain_n]) |id| {
        const spec = byId(id) orelse continue;
        const listed = for (web.order) |oid| {
            if (std.mem.eql(u8, oid, id)) break true;
        } else false;
        if (!isAvailable(spec, auth_json, web, listed)) continue;
        attempted += 1;
        const key = credential(auth_json, spec) orelse "";
        if (searchOne(allocator, io, spec, query, key, web)) |text| {
            return text;
        } else |_| {
            try fails.appendSlice(allocator, id);
            try fails.appendSlice(allocator, " failed; ");
        }
    }
    if (attempted == 0) return allocator.dupe(u8, "Error: No web search provider configured.\n");
    return std.fmt.allocPrint(allocator, "Error: All web search providers failed: {s}\n", .{fails.items});
}

pub fn searchFromHome(allocator: std.mem.Allocator, io: Io, home: []const u8, query: []const u8) ![]u8 {
    const auth_path = try auth.path(allocator, home);
    defer allocator.free(auth_path);
    const auth_json = Io.Dir.cwd().readFileAlloc(io, auth_path, allocator, .limited(256_000)) catch "";
    defer if (auth_json.len > 0) allocator.free(auth_json);
    var file = settings.load(allocator, io, home);
    defer file.deinit(allocator);
    return search(allocator, io, query, auth_json, file.web);
}

pub fn statusLine(spec: Spec, auth_json: []const u8, web: settings.Web) []const u8 {
    if (settings.excluded(web, spec.id)) return "off";
    return switch (spec.kind) {
        .free => if (spec.explicit_only) "explicit" else "ready",
        .endpoint => if (isConfigured(spec, auth_json, web)) "✓ configured" else "need url",
        .api_key => if (isConfigured(spec, auth_json, web)) "✓ configured" else "need key",
    };
}

test "default chain skips public" {
    var buf: [settings.max_ids][]const u8 = undefined;
    const n = resolveChain(.{}, &buf);
    try std.testing.expect(n >= 16);
    try std.testing.expectEqualStrings("perplexity", buf[0]);
    try std.testing.expectEqualStrings("duckduckgo", buf[14]);
    var has_public = false;
    for (buf[0..n]) |id| {
        if (std.mem.eql(u8, id, "public")) has_public = true;
    }
    try std.testing.expect(!has_public);
}

test "order puts exa first then remaining" {
    const web = settings.Web{ .order = &.{ "exa", "tavily" }, .exclude = &.{"google"} };
    var buf: [settings.max_ids][]const u8 = undefined;
    const n = resolveChain(web, &buf);
    try std.testing.expectEqualStrings("exa", buf[0]);
    try std.testing.expectEqualStrings("tavily", buf[1]);
    try std.testing.expect(n > 2);
    for (buf[0..n]) |id| {
        try std.testing.expect(!std.mem.eql(u8, id, "google"));
    }
}

test "public is explicit-only" {
    try std.testing.expect(all[all.len - 1].explicit_only);
    try std.testing.expect(!isAvailable(byId("public").?, "", .{}, false));
    try std.testing.expect(isAvailable(byId("public").?, "", .{}, true));
    try std.testing.expect(isAvailable(byId("duckduckgo").?, "", .{}, false));
}

test "catalog has nineteen providers" {
    try std.testing.expectEqual(@as(usize, 19), all.len);
    try std.testing.expect(byId("anthropic") == null);
    try std.testing.expect(byId("gemini") == null);
    try std.testing.expect(byId("codex") == null);
    try std.testing.expect(byId("xai") == null);
}

pub fn formatMenu(allocator: std.mem.Allocator, auth_json: []const u8, web: settings.Web) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "web search  first working provider in the order wins\n\nfallback: ");
    var chain: [settings.max_ids][]const u8 = undefined;
    const n = resolveChain(web, &chain);
    var shown: usize = 0;
    for (chain[0..n]) |id| {
        const spec = byId(id) orelse continue;
        const listed = for (web.order) |oid| {
            if (std.mem.eql(u8, oid, id)) break true;
        } else web.order.len == 0;
        if (!isAvailable(spec, auth_json, web, listed) and spec.kind != .free) continue;
        if (shown != 0) try out.appendSlice(allocator, " -> ");
        try out.appendSlice(allocator, id);
        shown += 1;
        if (shown >= 8) break;
    }
    if (shown == 0) try out.appendSlice(allocator, "(none ready)");
    try out.appendSlice(allocator, "\n\n  Set search order     pick first, then second, then third\n  Use built-in order    drop a custom list\n\n");
    for (all, 0..) |spec, i| {
        const st = statusLine(spec, auth_json, web);
        var line_buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {d: >2}  {s: <14} {s}\n", .{ i + 1, spec.id, st }) catch continue;
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator,
        \\
        \\Pick a provider to try it first.
        \\Pick "Set search order" to choose first, second, third… (pick again to remove one; start over to redo).
        \\Pick "Use built-in order" if a custom list went wrong.
        \\off id / on id   skip or include again
        \\test query       run a search now
        \\empty            back
        \\
    );
    return out.toOwnedSlice(allocator);
}

test "web menu lists tavily and set search order" {
    const text = try formatMenu(std.testing.allocator, "", .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "tavily") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "duckduckgo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Set search order") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Use built-in order") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gemini") == null);
}

test "parseHome begin_order off and pick" {
    try std.testing.expect(parseHome("order") == .begin_order);
    try std.testing.expect(parseHome(order_pick_id) == .begin_order);
    try std.testing.expect(parseHome("default") == .use_default);
    try std.testing.expect(parseHome(default_pick_id) == .use_default);
    switch (parseHome("off google")) {
        .off => |id| try std.testing.expectEqualStrings("google", id),
        else => return error.TestUnexpectedResult,
    }
    switch (parseHome("7")) {
        .pick => |s| try std.testing.expectEqualStrings("tavily", s.id),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(parseHome("") == .cancel);
    try std.testing.expect(parseHome("nope") == .unknown);
}

test "credential prefers web_search store then auth alias" {
    const json =
        \\{"web_search.tavily":{"type":"api_key","key":"tvly"},"perplexity":{"type":"api_key","key":"pplx"}}
    ;
    try std.testing.expectEqualStrings("tvly", credential(json, byId("tavily").?).?);
    try std.testing.expectEqualStrings("pplx", credential(json, byId("perplexity").?).?);
}
