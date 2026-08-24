const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const sse = @import("sse.zig");

const log = std.log.scoped(.oauth);

fn writePrompt(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    w.interface.print(fmt, args) catch |err| {
        log.warn("login prompt: {s}", .{@errorName(err)});
        return;
    };
    w.interface.flush() catch |err| {
        log.warn("login prompt: {s}", .{@errorName(err)});
    };
}

pub const FetchError = error{ Transport, OutOfMemory };
pub const RefreshError = error{ Transport, OutOfMemory, OAuthFailed };

pub const Token = struct {
    access: []u8,
    refresh: []u8,
    expires_at: i64 = 0,
    token_endpoint: []u8,

    pub fn deinit(self: Token, allocator: std.mem.Allocator) void {
        allocator.free(self.access);
        allocator.free(self.refresh);
        allocator.free(self.token_endpoint);
    }
};

pub const Device = enum { xai, github_copilot, kimi, chatgpt };
pub const PkceKind = enum { anthropic, chatgpt, gemini_cli, antigravity };

pub const Login = union(enum) {
    api_key,
    device: Device,
    pkce: PkceKind,
};

pub const Grant = enum {
    none,
    xai,
    kimi,
    chatgpt,
    anthropic,
    gemini_cli,
    antigravity,

    pub fn fromLogin(login: Login) Grant {
        return switch (login) {
            .api_key => .none,
            .device => |d| switch (d) {
                .xai => .xai,
                .kimi => .kimi,
                .chatgpt => .chatgpt,
                .github_copilot => .none,
            },
            .pkce => |p| switch (p) {
                .anthropic => .anthropic,
                .chatgpt => .chatgpt,
                .gemini_cli => .gemini_cli,
                .antigravity => .antigravity,
            },
        };
    }
};

pub const Http = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn fetch(
        self: Http,
        method: std.http.Method,
        url: []const u8,
        content_type: []const u8,
        body: ?[]const u8,
        extra: []const std.http.Header,
    ) FetchError!struct { status: u16, body: []u8 } {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        const headers: std.http.Client.Request.Headers = .{
            .content_type = if (content_type.len > 0) .{ .override = content_type } else .omit,
        };
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .headers = headers,
            .extra_headers = extra,
            .response_writer = &aw.writer,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Transport,
        };
        return .{ .status = @intFromEnum(result.status), .body = try aw.toOwnedSlice() };
    }
};

const Pair = struct { k: []const u8, v: []const u8 };

fn formEncode(allocator: std.mem.Allocator, pairs: []const Pair) FetchError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeForm(&aw.writer, pairs) catch return error.Transport;
    return aw.toOwnedSlice();
}

fn writeForm(w: *std.Io.Writer, pairs: []const Pair) !void {
    for (pairs, 0..) |p, i| {
        if (i != 0) try w.writeByte('&');
        try (std.Uri.Component{ .raw = p.k }).formatQuery(w);
        try w.writeByte('=');
        try (std.Uri.Component{ .raw = p.v }).formatQuery(w);
    }
}

pub fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    return sse.jsonString(json, key);
}

pub fn jsonInt(json: []const u8, key: []const u8) ?i64 {
    const n = jsonNumber(json, key) orelse return null;
    return std.math.cast(i64, n);
}

fn jsonNumber(json: []const u8, key: []const u8) ?u64 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = start + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    const from = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == from) return null;
    return std.fmt.parseInt(u64, json[from..i], 10) catch null;
}

pub fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch |err| {
        log.debug("browser wait: {s}", .{@errorName(err)});
    };
}

pub const Pkce = struct {
    verifier: []u8,
    challenge: []u8,
    state: []u8,

    pub fn deinit(self: Pkce, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
        allocator.free(self.state);
    }
};

fn b64url(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

pub fn generatePkce(allocator: std.mem.Allocator, io: Io) !Pkce {
    var src = std.Random.IoSource{ .io = io };
    const rng = src.interface();
    var raw: [32]u8 = undefined;
    rng.bytes(&raw);
    const verifier = try b64url(allocator, &raw);
    errdefer allocator.free(verifier);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
    const challenge = try b64url(allocator, &hash);
    errdefer allocator.free(challenge);
    var state_raw: [16]u8 = undefined;
    rng.bytes(&state_raw);
    const state = try b64url(allocator, &state_raw);
    return .{ .verifier = verifier, .challenge = challenge, .state = state };
}

pub fn codeFromInput(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \r\t\n");
    if (std.mem.indexOf(u8, trimmed, "code=")) |idx| {
        const rest = trimmed[idx + "code=".len ..];
        const end = std.mem.indexOfAny(u8, rest, "&#") orelse rest.len;
        return rest[0..end];
    }
    return trimmed;
}

fn nowSeconds(io: Io) i64 {
    return Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
}

fn expiresAt(io: Io, expires_in: u64) i64 {
    return nowSeconds(io) + @as(i64, @intCast(expires_in)) - 5 * 60;
}

fn tokenFromJson(http: Http, body: []const u8, token_endpoint: []const u8) RefreshError!Token {
    const access = jsonString(body, "access_token") orelse return error.OAuthFailed;
    const refresh = jsonString(body, "refresh_token") orelse "";
    const exp = jsonNumber(body, "expires_in") orelse 0;
    return .{
        .access = try http.allocator.dupe(u8, access),
        .refresh = try http.allocator.dupe(u8, refresh),
        .expires_at = if (exp > 0) expiresAt(http.io, exp) else 0,
        .token_endpoint = try http.allocator.dupe(u8, token_endpoint),
    };
}

fn sleepNs(io: Io, ns: u64) void {
    Io.sleep(io, .{ .nanoseconds = @intCast(ns) }, .awake) catch |err| {
        log.debug("sleep: {s}", .{@errorName(err)});
    };
}

/// RFC 8628 device-code poll. `poll_body` is form-encoded.
pub fn pollDeviceToken(
    http: Http,
    token_url: []const u8,
    form_body: []const u8,
    extra: []const std.http.Header,
    interval_s: u64,
    expires_s: u64,
) !Token {
    const interval_ns: u64 = @max(1, interval_s) * std.time.ns_per_s;
    const max_polls: usize = @intCast(@max(6, expires_s / @max(1, interval_s) + 2));
    var wait_ns = interval_ns;
    var n: usize = 0;
    while (n < max_polls) : (n += 1) {
        sleepNs(http.io, wait_ns);
        const res = try http.fetch(.POST, token_url, "application/x-www-form-urlencoded", form_body, extra);
        defer http.allocator.free(res.body);
        if (jsonString(res.body, "access_token")) |_| {
            return tokenFromJson(http, res.body, token_url);
        }
        const errn = jsonString(res.body, "error") orelse "";
        if (std.mem.eql(u8, errn, "authorization_pending")) continue;
        if (std.mem.eql(u8, errn, "slow_down")) {
            wait_ns = @min(wait_ns + std.time.ns_per_s, 30 * std.time.ns_per_s);
            continue;
        }
        if (errn.len > 0) return error.OAuthFailed;
        if (res.status < 200 or res.status >= 300) return error.OAuthFailed;
    }
    return error.OAuthTimeout;
}

pub const xai_client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const xai_issuer = "https://auth.x.ai";
const xai_discovery = xai_issuer ++ "/.well-known/openid-configuration";
const xai_device = xai_issuer ++ "/oauth2/device/code";
const xai_scope = "openid profile email offline_access grok-cli:access api:access";

fn hostAllowed(url: []const u8, root: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const host = switch (uri.host orelse return false) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    if (std.mem.eql(u8, host, root)) return true;
    var buf: [64]u8 = undefined;
    const dotted = std.fmt.bufPrint(&buf, ".{s}", .{root}) catch return false;
    return std.mem.endsWith(u8, host, dotted);
}

pub fn loginXaiDevice(http: Http) !Token {
    const disc = try http.fetch(.GET, xai_discovery, "", null, &.{.{ .name = "accept", .value = "application/json" }});
    defer http.allocator.free(disc.body);
    if (disc.status < 200 or disc.status >= 300) return error.OAuthFailed;
    const token_endpoint = jsonString(disc.body, "token_endpoint") orelse return error.OAuthFailed;
    if (!hostAllowed(token_endpoint, "x.ai")) return error.OAuthFailed;
    const token_url = try http.allocator.dupe(u8, token_endpoint);
    defer http.allocator.free(token_url);

    const code_body = try formEncode(http.allocator, &.{
        .{ .k = "client_id", .v = xai_client_id },
        .{ .k = "scope", .v = xai_scope },
    });
    defer http.allocator.free(code_body);
    const code_res = try http.fetch(.POST, xai_device, "application/x-www-form-urlencoded", code_body, &.{
        .{ .name = "accept", .value = "application/json" },
    });
    defer http.allocator.free(code_res.body);
    const device_code = jsonString(code_res.body, "device_code") orelse return error.OAuthFailed;
    const user_code = jsonString(code_res.body, "user_code") orelse return error.OAuthFailed;
    const verify = jsonString(code_res.body, "verification_uri_complete") orelse
        jsonString(code_res.body, "verification_uri") orelse return error.OAuthFailed;
    if (!hostAllowed(verify, "x.ai")) return error.OAuthFailed;

    writePrompt(http.io, "omfx: SuperGrok / X Premium+ login\nOpen {s}\nEnter code: {s}\n", .{ verify, user_code });
    openBrowser(http.io, verify);

    const poll_body = try formEncode(http.allocator, &.{
        .{ .k = "grant_type", .v = "urn:ietf:params:oauth:grant-type:device_code" },
        .{ .k = "client_id", .v = xai_client_id },
        .{ .k = "device_code", .v = device_code },
    });
    defer http.allocator.free(poll_body);
    const interval = jsonNumber(code_res.body, "interval") orelse 5;
    const expires = jsonNumber(code_res.body, "expires_in") orelse 600;
    var tok = try pollDeviceToken(http, token_url, poll_body, &.{.{ .name = "accept", .value = "application/json" }}, interval, expires);
    http.allocator.free(tok.token_endpoint);
    tok.token_endpoint = try http.allocator.dupe(u8, token_url);
    return tok;
}

pub fn refreshXai(http: Http, refresh_token: []const u8, token_url_opt: []const u8) RefreshError!Token {
    const token_url = if (token_url_opt.len > 0 and hostAllowed(token_url_opt, "x.ai"))
        token_url_opt
    else
        "https://auth.x.ai/oauth/token";
    const body = try formEncode(http.allocator, &.{
        .{ .k = "grant_type", .v = "refresh_token" },
        .{ .k = "refresh_token", .v = refresh_token },
        .{ .k = "client_id", .v = xai_client_id },
    });
    defer http.allocator.free(body);
    const res = try http.fetch(.POST, token_url, "application/x-www-form-urlencoded", body, &.{.{ .name = "accept", .value = "application/json" }});
    defer http.allocator.free(res.body);
    if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
    return tokenFromJson(http, res.body, token_url);
}

const copilot_client_id = "Ov23li8tweQw6odWQebz";

pub fn loginGithubCopilot(http: Http) !Token {
    const extra = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "user-agent", .value = "omfx/0.0.1" },
    };
    const start_body = try std.fmt.allocPrint(http.allocator, "{{\"client_id\":\"{s}\",\"scope\":\"read:user\"}}", .{copilot_client_id});
    defer http.allocator.free(start_body);
    const start = try http.fetch(.POST, "https://github.com/login/device/code", "application/json", start_body, &extra);
    defer http.allocator.free(start.body);
    const device_code = jsonString(start.body, "device_code") orelse return error.OAuthFailed;
    const user_code = jsonString(start.body, "user_code") orelse return error.OAuthFailed;
    const verify = jsonString(start.body, "verification_uri") orelse "https://github.com/login/device";
    writePrompt(http.io, "omfx: GitHub Copilot login\nOpen {s}\nEnter code: {s}\n", .{ verify, user_code });
    openBrowser(http.io, verify);

    const poll_json = try std.fmt.allocPrint(
        http.allocator,
        "{{\"client_id\":\"{s}\",\"device_code\":\"{s}\",\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\"}}",
        .{ copilot_client_id, device_code },
    );
    defer http.allocator.free(poll_json);
    const interval = jsonNumber(start.body, "interval") orelse 5;
    const expires = jsonNumber(start.body, "expires_in") orelse 900;
    const max_polls: usize = @intCast(@max(6, expires / @max(1, interval) + 2));
    var wait_ns: u64 = @max(1, interval) * std.time.ns_per_s;
    var n: usize = 0;
    while (n < max_polls) : (n += 1) {
        sleepNs(http.io, wait_ns);
        const res = try http.fetch(.POST, "https://github.com/login/oauth/access_token", "application/json", poll_json, &extra);
        defer http.allocator.free(res.body);
        if (jsonString(res.body, "access_token")) |tok| {
            const access = try http.allocator.dupe(u8, tok);
            return .{
                .access = access,
                .refresh = try http.allocator.dupe(u8, tok),
                .expires_at = nowSeconds(http.io) + 10 * 365 * 24 * 3600,
                .token_endpoint = try http.allocator.dupe(u8, ""),
            };
        }
        const errn = jsonString(res.body, "error") orelse "";
        if (std.mem.eql(u8, errn, "authorization_pending")) continue;
        if (std.mem.eql(u8, errn, "slow_down")) {
            wait_ns += 5 * std.time.ns_per_s;
            continue;
        }
        if (errn.len > 0) return error.OAuthFailed;
    }
    return error.OAuthTimeout;
}

const kimi_client_id = "17e5f671-d194-4dfb-9706-5516cb48c098";
const kimi_device_url = "https://auth.kimi.com/api/oauth/device_authorization";
const kimi_token_url = "https://auth.kimi.com/api/oauth/token";

pub fn loginKimiDevice(http: Http) !Token {
    const extra = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "user-agent", .value = "KimiCLI/omfx" },
        .{ .name = "x-msh-platform", .value = "kimi_cli" },
    };
    const body = try formEncode(http.allocator, &.{.{ .k = "client_id", .v = kimi_client_id }});
    defer http.allocator.free(body);
    const start = try http.fetch(.POST, kimi_device_url, "application/x-www-form-urlencoded", body, &extra);
    defer http.allocator.free(start.body);
    const device_code = jsonString(start.body, "device_code") orelse return error.OAuthFailed;
    const user_code = jsonString(start.body, "user_code") orelse return error.OAuthFailed;
    const verify = jsonString(start.body, "verification_uri_complete") orelse
        jsonString(start.body, "verification_uri") orelse return error.OAuthFailed;
    writePrompt(http.io, "omfx: Kimi Code login\nOpen {s}\nEnter code: {s}\n", .{ verify, user_code });
    openBrowser(http.io, verify);
    const poll_body = try formEncode(http.allocator, &.{
        .{ .k = "grant_type", .v = "urn:ietf:params:oauth:grant-type:device_code" },
        .{ .k = "client_id", .v = kimi_client_id },
        .{ .k = "device_code", .v = device_code },
    });
    defer http.allocator.free(poll_body);
    const interval = jsonNumber(start.body, "interval") orelse 5;
    const expires = jsonNumber(start.body, "expires_in") orelse 900;
    return pollDeviceToken(http, kimi_token_url, poll_body, &extra, interval, expires);
}

pub fn refreshKimi(http: Http, refresh_token: []const u8) RefreshError!Token {
    const body = try formEncode(http.allocator, &.{
        .{ .k = "grant_type", .v = "refresh_token" },
        .{ .k = "refresh_token", .v = refresh_token },
        .{ .k = "client_id", .v = kimi_client_id },
    });
    defer http.allocator.free(body);
    const res = try http.fetch(.POST, kimi_token_url, "application/x-www-form-urlencoded", body, &.{.{ .name = "accept", .value = "application/json" }});
    defer http.allocator.free(res.body);
    if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
    return tokenFromJson(http, res.body, kimi_token_url);
}

pub const chatgpt_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const openai_token_url = "https://auth.openai.com/oauth/token";
const openai_device_usercode = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const openai_device_token = "https://auth.openai.com/api/accounts/deviceauth/token";
const openai_device_redirect = "https://auth.openai.com/deviceauth/callback";
const openai_device_auth = "https://auth.openai.com/codex/device";

pub fn loginChatGptDevice(http: Http) !Token {
    const start_body = try std.fmt.allocPrint(http.allocator, "{{\"client_id\":\"{s}\"}}", .{chatgpt_client_id});
    defer http.allocator.free(start_body);
    const start = try http.fetch(.POST, openai_device_usercode, "application/json", start_body, &.{.{ .name = "accept", .value = "application/json" }});
    defer http.allocator.free(start.body);
    const device_auth_id = jsonString(start.body, "device_auth_id") orelse return error.OAuthFailed;
    const user_code = jsonString(start.body, "user_code") orelse return error.OAuthFailed;
    writePrompt(http.io, "omfx: ChatGPT device login\nOpen {s}\nEnter code: {s}\n", .{ openai_device_auth, user_code });
    openBrowser(http.io, openai_device_auth);

    const poll_json = try std.fmt.allocPrint(
        http.allocator,
        "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}",
        .{ device_auth_id, user_code },
    );
    defer http.allocator.free(poll_json);
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        sleepNs(http.io, 5 * std.time.ns_per_s);
        const res = try http.fetch(.POST, openai_device_token, "application/json", poll_json, &.{.{ .name = "accept", .value = "application/json" }});
        defer http.allocator.free(res.body);
        if (res.status == 403 or res.status == 404) continue;
        const auth_code = jsonString(res.body, "authorization_code") orelse continue;
        const verifier = jsonString(res.body, "code_verifier") orelse continue;
        return exchangeChatGpt(http, auth_code, verifier, openai_device_redirect);
    }
    return error.OAuthTimeout;
}

fn exchangeChatGpt(http: Http, code: []const u8, verifier: []const u8, redirect: []const u8) !Token {
    const body = try formEncode(http.allocator, &.{
        .{ .k = "grant_type", .v = "authorization_code" },
        .{ .k = "client_id", .v = chatgpt_client_id },
        .{ .k = "code", .v = code },
        .{ .k = "code_verifier", .v = verifier },
        .{ .k = "redirect_uri", .v = redirect },
    });
    defer http.allocator.free(body);
    const res = try http.fetch(.POST, openai_token_url, "application/x-www-form-urlencoded", body, &.{});
    defer http.allocator.free(res.body);
    if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
    return tokenFromJson(http, res.body, openai_token_url);
}

pub fn refreshChatGpt(http: Http, refresh_token: []const u8) RefreshError!Token {
    const body = try formEncode(http.allocator, &.{
        .{ .k = "grant_type", .v = "refresh_token" },
        .{ .k = "refresh_token", .v = refresh_token },
        .{ .k = "client_id", .v = chatgpt_client_id },
    });
    defer http.allocator.free(body);
    const res = try http.fetch(.POST, openai_token_url, "application/x-www-form-urlencoded", body, &.{});
    defer http.allocator.free(res.body);
    if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
    return tokenFromJson(http, res.body, openai_token_url);
}

pub const PkceFlow = struct {
    authorize_url: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8 = "",
    redirect_uri: []const u8,
    scope: []const u8,
    extra_query: []const u8 = "",
    /// Anthropic token endpoint wants JSON, not form.
    json_token: bool = false,
};

pub const anthropic_pkce = PkceFlow{
    .authorize_url = "https://claude.ai/oauth/authorize",
    .token_url = "https://api.anthropic.com/v1/oauth/token",
    .client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    .redirect_uri = "http://localhost:54545/callback",
    .scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
    .extra_query = "code=true&",
    .json_token = true,
};

pub const chatgpt_pkce = PkceFlow{
    .authorize_url = "https://auth.openai.com/oauth/authorize",
    .token_url = openai_token_url,
    .client_id = chatgpt_client_id,
    .redirect_uri = "http://localhost:1455/auth/callback",
    .scope = "openid profile email offline_access api.connectors.read api.connectors.invoke",
    .extra_query = "id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=omfx&",
};

pub const gemini_cli_pkce = PkceFlow{
    .authorize_url = "https://accounts.google.com/o/oauth2/v2/auth",
    .token_url = "https://oauth2.googleapis.com/token",
    .client_id = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
    .client_secret = "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",
    .redirect_uri = "http://localhost:8085/oauth2callback",
    .scope = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile",
    .extra_query = "access_type=offline&prompt=consent&",
};

pub const antigravity_pkce = PkceFlow{
    .authorize_url = "https://accounts.google.com/o/oauth2/v2/auth",
    .token_url = "https://oauth2.googleapis.com/token",
    .client_id = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
    .client_secret = "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",
    .redirect_uri = "http://localhost:51121/oauth-callback",
    .scope = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs",
    .extra_query = "access_type=offline&prompt=consent&",
};

pub fn authorizeUrl(allocator: std.mem.Allocator, flow: PkceFlow, pkce: Pkce) ![]u8 {
    const encoded = try formEncode(allocator, &.{
        .{ .k = "response_type", .v = "code" },
        .{ .k = "client_id", .v = flow.client_id },
        .{ .k = "redirect_uri", .v = flow.redirect_uri },
        .{ .k = "scope", .v = flow.scope },
        .{ .k = "code_challenge", .v = pkce.challenge },
        .{ .k = "code_challenge_method", .v = "S256" },
        .{ .k = "state", .v = pkce.state },
    });
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}?{s}{s}", .{ flow.authorize_url, flow.extra_query, encoded });
}

pub fn exchangePkce(http: Http, flow: PkceFlow, code: []const u8, verifier: []const u8, state: []const u8) !Token {
    if (flow.json_token) {
        const body = try std.fmt.allocPrint(
            http.allocator,
            "{{\"grant_type\":\"authorization_code\",\"client_id\":\"{s}\",\"code\":\"{s}\",\"state\":\"{s}\",\"redirect_uri\":\"{s}\",\"code_verifier\":\"{s}\"}}",
            .{ flow.client_id, code, state, flow.redirect_uri, verifier },
        );
        defer http.allocator.free(body);
        const res = try http.fetch(.POST, flow.token_url, "application/json", body, &.{});
        defer http.allocator.free(res.body);
        if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
        return tokenFromJson(http, res.body, flow.token_url);
    }
    var pairs_buf: [6]Pair = undefined;
    var n: usize = 0;
    pairs_buf[n] = .{ .k = "grant_type", .v = "authorization_code" };
    n += 1;
    pairs_buf[n] = .{ .k = "client_id", .v = flow.client_id };
    n += 1;
    pairs_buf[n] = .{ .k = "code", .v = code };
    n += 1;
    pairs_buf[n] = .{ .k = "code_verifier", .v = verifier };
    n += 1;
    pairs_buf[n] = .{ .k = "redirect_uri", .v = flow.redirect_uri };
    n += 1;
    if (flow.client_secret.len > 0) {
        pairs_buf[n] = .{ .k = "client_secret", .v = flow.client_secret };
        n += 1;
    }
    const body = try formEncode(http.allocator, pairs_buf[0..n]);
    defer http.allocator.free(body);
    const res = try http.fetch(.POST, flow.token_url, "application/x-www-form-urlencoded", body, &.{});
    defer http.allocator.free(res.body);
    if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
    return tokenFromJson(http, res.body, flow.token_url);
}

pub fn refreshAnthropic(http: Http, refresh_token: []const u8) RefreshError!Token {
    const body = try std.fmt.allocPrint(
        http.allocator,
        "{{\"grant_type\":\"refresh_token\",\"client_id\":\"{s}\",\"refresh_token\":\"{s}\"}}",
        .{ anthropic_pkce.client_id, refresh_token },
    );
    defer http.allocator.free(body);
    const res = try http.fetch(.POST, anthropic_pkce.token_url, "application/json", body, &.{});
    defer http.allocator.free(res.body);
    if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
    return tokenFromJson(http, res.body, anthropic_pkce.token_url);
}

pub fn refreshGoogle(http: Http, flow: PkceFlow, refresh_token: []const u8) RefreshError!Token {
    const body = try formEncode(http.allocator, &.{
        .{ .k = "grant_type", .v = "refresh_token" },
        .{ .k = "refresh_token", .v = refresh_token },
        .{ .k = "client_id", .v = flow.client_id },
        .{ .k = "client_secret", .v = flow.client_secret },
    });
    defer http.allocator.free(body);
    const res = try http.fetch(.POST, flow.token_url, "application/x-www-form-urlencoded", body, &.{});
    defer http.allocator.free(res.body);
    if (jsonString(res.body, "access_token") == null) return error.OAuthFailed;
    return tokenFromJson(http, res.body, flow.token_url);
}

pub fn pkceFlow(kind: PkceKind) PkceFlow {
    return switch (kind) {
        .anthropic => anthropic_pkce,
        .chatgpt => chatgpt_pkce,
        .gemini_cli => gemini_cli_pkce,
        .antigravity => antigravity_pkce,
    };
}

pub fn loginDevice(http: Http, kind: Device) !Token {
    return switch (kind) {
        .xai => loginXaiDevice(http),
        .github_copilot => loginGithubCopilot(http),
        .kimi => loginKimiDevice(http),
        .chatgpt => loginChatGptDevice(http),
    };
}

/// Refresh a stored grant. `.none` and empty refresh tokens fail closed.
pub fn refreshStored(http: Http, grant: Grant, refresh_token: []const u8, token_endpoint: []const u8) RefreshError!Token {
    if (refresh_token.len == 0) return error.OAuthFailed;
    return switch (grant) {
        .none => error.OAuthFailed,
        .xai => refreshXai(http, refresh_token, token_endpoint),
        .kimi => refreshKimi(http, refresh_token),
        .chatgpt => refreshChatGpt(http, refresh_token),
        .anthropic => refreshAnthropic(http, refresh_token),
        .gemini_cli => refreshGoogle(http, gemini_cli_pkce, refresh_token),
        .antigravity => refreshGoogle(http, antigravity_pkce, refresh_token),
    };
}

test "refreshStored fails closed without a refresh token" {
    const http = Http{ .allocator = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(error.OAuthFailed, refreshStored(http, .xai, "", "https://auth.x.ai/oauth/token"));
    try std.testing.expectError(error.OAuthFailed, refreshStored(http, .none, "r", ""));
}

test "Grant.fromLogin is exhaustive for device and pkce" {
    try std.testing.expectEqual(Grant.xai, Grant.fromLogin(.{ .device = .xai }));
    try std.testing.expectEqual(Grant.none, Grant.fromLogin(.{ .device = .github_copilot }));
    try std.testing.expectEqual(Grant.anthropic, Grant.fromLogin(.{ .pkce = .anthropic }));
    try std.testing.expectEqual(Grant.none, Grant.fromLogin(.api_key));
}

test "codeFromInput extracts query code" {
    try std.testing.expectEqualStrings("abc", codeFromInput("http://localhost:54545/callback?code=abc&state=x"));
    try std.testing.expectEqualStrings("plain", codeFromInput("  plain  "));
}

test "pkce verifier is base64url" {
    const p = try generatePkce(std.testing.allocator, std.testing.io);
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(p.verifier.len > 20);
    try std.testing.expect(p.challenge.len > 20);
    try std.testing.expect(std.mem.indexOfScalar(u8, p.verifier, '+') == null);
}

test "anthropic authorize url contains client id and pkce" {
    const p = try generatePkce(std.testing.allocator, std.testing.io);
    defer p.deinit(std.testing.allocator);
    const url = try authorizeUrl(std.testing.allocator, anthropic_pkce, p);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, anthropic_pkce.client_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "claude.ai/oauth/authorize") != null);
}
