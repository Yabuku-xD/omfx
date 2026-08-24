const std = @import("std");
const Io = std.Io;
const auth = @import("../providers/auth.zig");
const settings = @import("../core/settings.zig");

pub const Kind = enum {
    api_key,
    chat_login,
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

pub const all = [_]Spec{
    .{ .id = "perplexity", .name = "Perplexity", .env_keys = &.{"PERPLEXITY_API_KEY"}, .kind = .api_key, .auth_ids = &.{"perplexity"}, .keyless_explicit = true },
    .{ .id = "gemini", .name = "Gemini grounding", .env_keys = &.{ "GEMINI_API_KEY", "GOOGLE_API_KEY" }, .kind = .chat_login, .auth_ids = &.{ "google-gemini-cli", "google-antigravity", "google" } },
    .{ .id = "anthropic", .name = "Anthropic web search", .env_keys = &.{ "ANTHROPIC_SEARCH_API_KEY", "ANTHROPIC_API_KEY" }, .kind = .chat_login, .auth_ids = &.{"anthropic"} },
    .{ .id = "codex", .name = "ChatGPT search", .env_keys = &.{"OPENAI_CODEX_OAUTH_TOKEN"}, .kind = .chat_login, .auth_ids = &.{ "openai-codex", "openai-codex-device" } },
    .{ .id = "xai", .name = "xAI web search", .env_keys = &.{ "XAI_OAUTH_TOKEN", "XAI_API_KEY" }, .kind = .chat_login, .auth_ids = &.{ "xai", "xai-oauth" } },
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
        .api_key, .chat_login => credential(auth_json, spec) != null or (explicit and spec.keyless_explicit),
    };
}

pub const HomeCmd = union(enum) {
    cancel,
    pick: Spec,
    order: struct { ids: [settings.max_ids][]const u8, n: usize },
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
    if (std.mem.startsWith(u8, t, "order") and (t.len == 5 or t[5] == ' ' or t[5] == ':' or t[5] == '=')) {
        const rest = std.mem.trim(u8, t[5..], " \t:=");
        var ids: [settings.max_ids][]const u8 = undefined;
        const n = parseOrder(rest, &ids);
        return .{ .order = .{ .ids = ids, .n = n } };
    }
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

fn collectSources(allocator: std.mem.Allocator, provider: []const u8, body: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[");
    try out.appendSlice(allocator, provider);
    try out.appendSlice(allocator, "]\n");
    var n: usize = 0;
    var i: usize = 0;
    while (n < limit) {
        const u_key = std.mem.indexOfPos(u8, body, i, "\"url\"") orelse
            std.mem.indexOfPos(u8, body, i, "\"href\"") orelse break;
        const after = body[u_key..];
        const q1 = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const rest = after[q1 + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const from = colon + 1;
        var to = from;
        while (to < rest.len and rest[to] != '"') : (to += 1) {}
        const url = rest[from..to];
        if (std.mem.startsWith(u8, url, "http")) {
            n += 1;
            var line_buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{d}. {s}\n", .{ n, url }) catch continue;
            try out.appendSlice(allocator, line);
        }
        i = u_key + 8;
        if (i >= body.len) break;
    }
    if (n == 0) {
        const snippet = body[0..@min(body.len, 400)];
        try out.appendSlice(allocator, snippet);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn htmlLinks(allocator: std.mem.Allocator, provider: []const u8, body: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[");
    try out.appendSlice(allocator, provider);
    try out.appendSlice(allocator, "]\n");
    var n: usize = 0;
    var i: usize = 0;
    while (n < limit) {
        const href = std.mem.indexOfPos(u8, body, i, "http") orelse break;
        var end = href;
        while (end < body.len) : (end += 1) {
            const c = body[end];
            if (c == '"' or c == '\'' or c == ' ' or c == '<' or c == '\n') break;
        }
        const url = body[href..end];
        if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
            if (std.mem.indexOf(u8, url, "duckduckgo.com") == null and
                std.mem.indexOf(u8, url, "google.com/search") == null)
            {
                n += 1;
                var line_buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{d}. {s}\n", .{ n, url }) catch continue;
                try out.appendSlice(allocator, line);
            }
        }
        i = end + 1;
        if (i >= body.len) break;
    }
    if (n == 0) return error.EmptyResults;
    return out.toOwnedSlice(allocator);
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
        return collectSources(allocator, spec.id, res.body, 8);
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
        return collectSources(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "exa")) {
        if (key.len == 0) {
            const body = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"web_search_exa\",\"arguments\":{{\"query\":\"{s}\"}}}}}}", .{qesc});
            defer allocator.free(body);
            const res = try http(allocator, io, .POST, "https://mcp.exa.ai/mcp", "application/json", body, &.{});
            defer allocator.free(res.body);
            if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
            return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "tinyfish")) {
        const url = try std.fmt.allocPrint(allocator, "https://api.search.tinyfish.ai?query={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &.{.{ .name = "x-api-key", .value = key }});
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 8);
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
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
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
        return collectSources(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "gemini")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"contents\":[{{\"parts\":[{{\"text\":\"{s}\"}}]}}],\"tools\":[{{\"google_search\":{{}}}}]}}", .{qesc});
        defer allocator.free(body);
        var extra: [2]std.http.Header = undefined;
        var extra_len: usize = 0;
        var authz_buf: []u8 = &.{};
        if (std.mem.startsWith(u8, key, "AIza")) {
            extra[0] = .{ .name = "x-goog-api-key", .value = key };
            extra_len = 1;
        } else {
            authz_buf = try bearer(allocator, key);
            extra[0] = .{ .name = "authorization", .value = authz_buf };
            extra_len = 1;
        }
        defer if (authz_buf.len > 0) allocator.free(authz_buf);
        const res = try http(allocator, io, .POST, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent", "application/json", body, extra[0..extra_len]);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "anthropic")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"model\":\"claude-haiku-4-5\",\"max_tokens\":2048,\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}],\"tools\":[{{\"type\":\"web_search_20250305\",\"name\":\"web_search\"}}]}}", .{qesc});
        defer allocator.free(body);
        var extra: [4]std.http.Header = undefined;
        extra[0] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        extra[1] = .{ .name = "anthropic-beta", .value = "web-search-2025-03-05" };
        var extra_len: usize = 2;
        var authz_buf: []u8 = &.{};
        if (std.mem.startsWith(u8, key, "sk-ant")) {
            extra[extra_len] = .{ .name = "x-api-key", .value = key };
            extra_len += 1;
        } else {
            authz_buf = try bearer(allocator, key);
            extra[extra_len] = .{ .name = "authorization", .value = authz_buf };
            extra_len += 1;
        }
        defer if (authz_buf.len > 0) allocator.free(authz_buf);
        const res = try http(allocator, io, .POST, "https://api.anthropic.com/v1/messages", "application/json", body, extra[0..extra_len]);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "xai")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"model\":\"grok-4.6\",\"input\":\"{s}\",\"tools\":[{{\"type\":\"web_search\"}}]}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const res = try http(allocator, io, .POST, "https://api.x.ai/v1/responses", "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "codex")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"model\":\"gpt-5.5\",\"input\":\"{s}\",\"tools\":[{{\"type\":\"web_search\"}}]}}", .{qesc});
        defer allocator.free(body);
        const authz = try bearer(allocator, key);
        defer allocator.free(authz);
        const url: []const u8 = if (std.mem.startsWith(u8, key, "sk-"))
            "https://api.openai.com/v1/responses"
        else
            "https://chatgpt.com/backend-api/codex/responses";
        const res = try http(allocator, io, .POST, url, "application/json", body, &.{
            .{ .name = "authorization", .value = authz },
        });
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return collectSources(allocator, spec.id, res.body, 10);
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
        return htmlLinks(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "startpage")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.startpage.com/sp/search?query={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "ecosia")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.ecosia.org/search?q={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "google")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.google.com/search?q={s}&hl=en", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10);
    }
    if (std.mem.eql(u8, spec.id, "mojeek")) {
        const url = try std.fmt.allocPrint(allocator, "https://www.mojeek.com/search?q={s}", .{qform});
        defer allocator.free(url);
        const res = try http(allocator, io, .GET, url, "", null, &browser_headers);
        defer allocator.free(res.body);
        if (res.status < 200 or res.status >= 300) return error.ProviderFailed;
        return htmlLinks(allocator, spec.id, res.body, 10);
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
        .free => if (spec.explicit_only) "explicit" else "free",
        .endpoint => if (web.searxng_endpoint.len > 0 or processEnv("SEARXNG_ENDPOINT") != null) "endpoint" else "need url",
        .api_key, .chat_login => if (credential(auth_json, spec) != null) "key" else "need key",
    };
}

test "default chain skips public" {
    var buf: [settings.max_ids][]const u8 = undefined;
    const n = resolveChain(.{}, &buf);
    try std.testing.expect(n >= 20);
    try std.testing.expectEqualStrings("perplexity", buf[0]);
    try std.testing.expectEqualStrings("duckduckgo", buf[18]);
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

test "catalog has twenty three providers" {
    try std.testing.expectEqual(@as(usize, 23), all.len);
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
    try out.appendSlice(allocator, "\n\n");
    for (all, 0..) |spec, i| {
        const st = statusLine(spec, auth_json, web);
        var line_buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {d: >2}  {s: <14} {s}\n", .{ i + 1, spec.id, st }) catch continue;
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator,
        \\
        \\number/id     set key (or SearXNG URL)
        \\order a,b,c   fallback order
        \\off id        skip in the chain
        \\on id         include again
        \\test query    run the chain now
        \\empty         back
        \\
    );
    return out.toOwnedSlice(allocator);
}

test "web menu lists tavily and order command" {
    const text = try formatMenu(std.testing.allocator, "", .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "tavily") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "duckduckgo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "order a,b,c") != null);
}

test "parseHome order off and pick" {
    switch (parseHome("order exa, tavily, 19")) {
        .order => |o| {
            try std.testing.expectEqual(@as(usize, 3), o.n);
            try std.testing.expectEqualStrings("exa", o.ids[0]);
            try std.testing.expectEqualStrings("tavily", o.ids[1]);
            try std.testing.expectEqualStrings("duckduckgo", o.ids[2]);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parseHome("off google")) {
        .off => |id| try std.testing.expectEqualStrings("google", id),
        else => return error.TestUnexpectedResult,
    }
    switch (parseHome("11")) {
        .pick => |s| try std.testing.expectEqualStrings("tavily", s.id),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(parseHome("") == .cancel);
    try std.testing.expect(parseHome("nope") == .unknown);
}

test "credential prefers web_search store then chat login alias" {
    const json =
        \\{"web_search.tavily":{"type":"api_key","key":"tvly"},"xai-oauth":{"type":"oauth","access_token":"grok"}}
    ;
    try std.testing.expectEqualStrings("tvly", credential(json, byId("tavily").?).?);
    try std.testing.expectEqualStrings("grok", credential(json, byId("xai").?).?);
}
