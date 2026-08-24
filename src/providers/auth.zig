const std = @import("std");
const Io = std.Io;
const catalog = @import("catalog.zig");
const env = @import("../core/env.zig");
const types = @import("types.zig");
const oauth = @import("oauth.zig");

const log = std.log.scoped(.auth);

/// ~/.omfx/auth.json, mode 0600.
/// { "groq": { "type": "api_key", "key": "..." }, "github-copilot": { "type": "oauth", "access_token": "..." } }
/// Receipt: a store with all three providers logged in measured 2.1 KB.
/// 256 KB is a tripwire for a file that is no longer a credential store.
pub const max_auth_bytes: usize = 256_000;

pub fn path(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".omfx", "auth.json" });
}

/// Empty on miss or read failure. Cap is `max_auth_bytes`. Caller owns a non-empty result.
pub fn readJson(allocator: std.mem.Allocator, io: Io, home: []const u8) []const u8 {
    const p = path(allocator, home) catch return "";
    defer allocator.free(p);
    return Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_auth_bytes)) catch "";
}

pub const Source = union(enum) {
    oauth_env: []const u8,
    oauth_file: []const u8,
    api_env: []const u8,
    api_file: []const u8,

    pub fn token(self: Source) []const u8 {
        return switch (self) {
            inline else => |k| k,
        };
    }

    pub fn kind(self: Source) types.Credential.Kind {
        return switch (self) {
            .oauth_env, .oauth_file => .oauth,
            .api_env, .api_file => .api_key,
        };
    }
};

pub fn extract(json: []const u8, provider: []const u8) ?types.Credential {
    const p = findPair(json, provider) orelse return null;
    return parseCred(p.value);
}

pub fn extractKey(json: []const u8, provider: []const u8) ?[]const u8 {
    const cred = extract(json, provider) orelse return null;
    return cred.token();
}

pub const max_listed: usize = 24;

pub fn listIds(json: []const u8, out: *[max_listed][]const u8) usize {
    const obj = asObject(json) orelse return 0;
    var cur = Cursor{ .s = obj, .i = 1 };
    var n: usize = 0;
    while (n < max_listed) {
        const p = cur.nextPair() orelse break;
        out[n] = p.key;
        n += 1;
    }
    return n;
}

fn asObject(json: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, json, " \n\r\t");
    if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return null;
    return t;
}

const Pair = struct {
    key: []const u8,
    value: []const u8,
    from: usize,
    to: usize,
};

const Cursor = struct {
    s: []const u8,
    i: usize,

    fn skipWs(self: *Cursor) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(self: Cursor) ?u8 {
        if (self.i >= self.s.len) return null;
        return self.s[self.i];
    }

    fn string(self: *Cursor) ?[]const u8 {
        self.skipWs();
        if (self.peek() != '"') return null;
        const start = self.i + 1;
        self.i += 1;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (c == '\\') {
                self.i += 1;
                continue;
            }
            if (c == '"') {
                const body = self.s[start..self.i];
                self.i += 1;
                return body;
            }
        }
        return null;
    }

    fn object(self: *Cursor) ?[]const u8 {
        self.skipWs();
        if (self.peek() != '{') return null;
        const from = self.i;
        const slice = objectSlice(self.s[from..]) orelse return null;
        self.i = from + slice.len;
        return slice;
    }

    fn nextPair(self: *Cursor) ?Pair {
        self.skipWs();
        if (self.peek() == ',') self.i += 1;
        self.skipWs();
        if (self.peek() == null or self.peek() == '}') return null;
        const from = self.i;
        const key = self.string() orelse return null;
        self.skipWs();
        if (self.peek() != ':') return null;
        self.i += 1;
        const value = self.object() orelse return null;
        return .{ .key = key, .value = value, .from = from, .to = self.i };
    }
};

fn objectSlice(from_brace: []const u8) ?[]const u8 {
    if (from_brace.len == 0 or from_brace[0] != '{') return null;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    for (from_brace, 0..) |c, i| {
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                esc = true;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return from_brace[0 .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn findPair(json: []const u8, id: []const u8) ?Pair {
    const obj = asObject(json) orelse return null;
    var cur = Cursor{ .s = obj, .i = 1 };
    while (cur.nextPair()) |p| {
        if (std.mem.eql(u8, p.key, id)) return p;
    }
    return null;
}

fn parseCred(obj: []const u8) ?types.Credential {
    const access = jsonString(obj, "access_token") orelse jsonString(obj, "access");
    const typ = jsonString(obj, "type") orelse "";
    if (std.mem.eql(u8, typ, "oauth") or access != null) {
        const a = access orelse return null;
        if (a.len == 0) return null;
        return .{ .oauth = .{
            .access = a,
            .refresh = jsonString(obj, "refresh_token") orelse jsonString(obj, "refresh") orelse "",
            .expires_at = oauth.jsonInt(obj, "expires_at") orelse 0,
            .token_endpoint = jsonString(obj, "token_endpoint") orelse "",
        } };
    }
    const key = jsonString(obj, "key") orelse return null;
    if (key.len == 0) return null;
    return .{ .api_key = key };
}

fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = start + needle.len;
    while (i < json.len and json[i] == ' ') i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const from = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') return json[from..i];
    }
    return null;
}

pub fn encodeApiKey(allocator: std.mem.Allocator, provider: []const u8, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"{s}\":{{\"type\":\"api_key\",\"key\":\"{s}\"}}}}\n", .{ provider, key });
}

pub fn encodeOAuth(allocator: std.mem.Allocator, provider: []const u8, access: []const u8, refresh: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"{s}\":{{\"type\":\"oauth\",\"access_token\":\"{s}\",\"refresh_token\":\"{s}\"}}}}\n",
        .{ provider, access, refresh },
    );
}

pub fn extractOAuth(json: []const u8, provider: []const u8) ?types.OAuth {
    const cred = extract(json, provider) orelse return null;
    return switch (cred) {
        .oauth => |o| o,
        .api_key => null,
    };
}

fn storedOAuth(json: []const u8, spec: catalog.Spec) ?types.OAuth {
    if (extractOAuth(json, catalog.storeId(spec))) |o| return o;
    if (!std.mem.eql(u8, catalog.storeId(spec), spec.id)) {
        return extractOAuth(json, spec.id);
    }
    return null;
}

pub fn encodeOAuthObject(allocator: std.mem.Allocator, rec: types.OAuth) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"oauth\",\"access_token\":\"{s}\",\"refresh_token\":\"{s}\",\"token_type\":\"bearer\",\"token_endpoint\":\"{s}\",\"expires_at\":{d}}}",
        .{ rec.access, rec.refresh, rec.token_endpoint, rec.expires_at },
    );
}

pub fn upsertFile(allocator: std.mem.Allocator, io: Io, home: []const u8, id: []const u8, object_json: []const u8) !void {
    const p = try path(allocator, home);
    defer allocator.free(p);
    // Only a missing file is an empty file. Merging into "" after a failed read
    // would write back a store holding this one credential and drop the rest.
    const cwd = Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, p, allocator, .limited(max_auth_bytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (existing.len > 0) allocator.free(existing);
    const merged = try upsertRaw(allocator, existing, id, object_json);
    defer allocator.free(merged);
    try writeFile(allocator, io, home, merged);
}

pub const EnsureError = oauth.RefreshError;

pub const Live = union(enum) {
    missing,
    ready: []u8,

    pub fn deinit(self: Live, allocator: std.mem.Allocator) void {
        switch (self) {
            .missing => {},
            .ready => |t| allocator.free(t),
        }
    }
};

fn ready(allocator: std.mem.Allocator, token: []const u8) EnsureError!Live {
    return .{ .ready = try allocator.dupe(u8, token) };
}

/// Live access token for this spec. `.ready` is owned; caller `deinit`s.
pub fn ensure(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    lookup: env.Lookup,
    spec: catalog.Spec,
    now: i64,
    force: bool,
) EnsureError!Live {
    const p = try path(allocator, home);
    defer allocator.free(p);
    const json = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_auth_bytes)) catch "";
    defer if (json.len > 0) allocator.free(json);

    const src = resolveSource(lookup, json, spec) orelse return .missing;
    switch (src) {
        .api_env, .api_file, .oauth_env => return ready(allocator, src.token()),
        .oauth_file => {},
    }

    const rec = storedOAuth(json, spec) orelse return ready(allocator, src.token());
    const grant = oauth.Grant.fromLogin(spec.login);
    if (grant == .none or rec.refresh.len == 0 or (!force and !rec.stale(now))) {
        return ready(allocator, rec.access);
    }

    const http = oauth.Http{ .allocator = allocator, .io = io };
    var tok = oauth.refreshStored(http, grant, rec.refresh, rec.token_endpoint) catch |err| {
        log.warn("refresh {s}: {s}", .{ spec.id, @errorName(err) });
        // An expired subscription is not a dead session. A key in the
        // environment or in auth.json still authenticates, and failing here
        // would hide it behind a login the user does not need.
        if (apiKey(lookup, json, spec)) |k| return ready(allocator, k);
        return err;
    };
    defer tok.deinit(allocator);

    const rec_out = types.OAuth{
        .access = tok.access,
        .refresh = rec.keepRefresh(tok.refresh),
        .expires_at = tok.expires_at,
        .token_endpoint = if (tok.token_endpoint.len > 0) tok.token_endpoint else rec.token_endpoint,
    };
    const obj = try encodeOAuthObject(allocator, rec_out);
    defer allocator.free(obj);
    upsertFile(allocator, io, home, catalog.storeId(spec), obj) catch |err| {
        log.warn("persist refresh {s}: {s}", .{ spec.id, @errorName(err) });
    };
    return ready(allocator, tok.access);
}

pub fn ensureResolved(
    gpa: std.mem.Allocator,
    keep: std.mem.Allocator,
    io: Io,
    home: []const u8,
    lookup: env.Lookup,
    resolved: catalog.Resolved,
    now: i64,
    force: bool,
) EnsureError!catalog.Resolved {
    var copy = resolved;
    switch (try ensure(gpa, io, home, lookup, resolved.spec, now, force)) {
        .missing => {},
        .ready => |tok| {
            defer gpa.free(tok);
            copy.api_key = try keep.dupe(u8, tok);
        },
    }
    return copy;
}

fn storedCred(auth_json: []const u8, spec: catalog.Spec) ?types.Credential {
    if (extract(auth_json, catalog.storeId(spec))) |c| return c;
    if (!std.mem.eql(u8, catalog.storeId(spec), spec.id)) {
        return extract(auth_json, spec.id);
    }
    return null;
}

fn storedToken(auth_json: []const u8, spec: catalog.Spec, class: types.Credential.Kind) ?[]const u8 {
    const cred = storedCred(auth_json, spec) orelse return null;
    if (cred.kind() != class) return null;
    const tok = cred.token();
    return if (tok.len > 0) tok else null;
}

/// The key half of the credentials, ignoring any OAuth record.
fn apiKey(lookup: env.Lookup, auth_json: []const u8, spec: catalog.Spec) ?[]const u8 {
    if (spec.envValue(lookup, .api_key)) |k| return k;
    return storedToken(auth_json, spec, .api_key);
}

pub fn resolveSource(lookup: env.Lookup, auth_json: []const u8, spec: catalog.Spec) ?Source {
    if (spec.envValue(lookup, .oauth)) |k| return .{ .oauth_env = k };
    if (storedToken(auth_json, spec, .oauth)) |k| return .{ .oauth_file = k };
    if (spec.envValue(lookup, .api_key)) |k| return .{ .api_env = k };
    if (storedToken(auth_json, spec, .api_key)) |k| return .{ .api_file = k };
    return null;
}

pub fn resolveKey(lookup: env.Lookup, auth_json: []const u8, spec: catalog.Spec) ?[]const u8 {
    return if (resolveSource(lookup, auth_json, spec)) |s| s.token() else null;
}

pub fn upsertRaw(allocator: std.mem.Allocator, existing: []const u8, id: []const u8, object_json: []const u8) ![]u8 {
    const t = asObject(existing) orelse {
        return std.fmt.allocPrint(allocator, "{{\n  \"{s}\": {s}\n}}\n", .{ id, object_json });
    };
    if (findPair(t, id)) |p| {
        return std.fmt.allocPrint(allocator, "{s}\"{s}\": {s}{s}\n", .{ t[0..p.from], id, object_json, t[p.to..] });
    }
    const inner = std.mem.trim(u8, t[1 .. t.len - 1], " \n\r\t");
    if (inner.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\n  \"{s}\": {s}\n}}\n", .{ id, object_json });
    }
    return std.fmt.allocPrint(allocator, "{{{s},\n  \"{s}\": {s}\n}}\n", .{ inner, id, object_json });
}

pub fn removeId(allocator: std.mem.Allocator, existing: []const u8, id: []const u8) ![]u8 {
    const t = asObject(existing) orelse return allocator.dupe(u8, "{}\n");
    const p = findPair(t, id) orelse return allocator.dupe(u8, existing);
    const prefix = std.mem.trimEnd(u8, t[1..p.from], " \n\r\t,");
    const suffix = std.mem.trimStart(u8, t[p.to .. t.len - 1], " \n\r\t,");
    if (prefix.len == 0 and suffix.len == 0) return allocator.dupe(u8, "{}\n");
    if (prefix.len == 0) return std.fmt.allocPrint(allocator, "{{{s}}}\n", .{suffix});
    if (suffix.len == 0) return std.fmt.allocPrint(allocator, "{{{s}}}\n", .{prefix});
    return std.fmt.allocPrint(allocator, "{{{s},{s}}}\n", .{ prefix, suffix });
}

pub fn writeFile(allocator: std.mem.Allocator, io: Io, home: []const u8, json: []const u8) !void {
    const p = try path(allocator, home);
    defer allocator.free(p);
    const dir = std.fs.path.dirname(p) orelse home;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
    };
    // Written beside the target and renamed over it: a crash or a full disk
    // half-way through leaves the old credentials, not a truncated file that
    // logs everyone out.
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{p});
    defer allocator.free(tmp);
    {
        var file = try Io.Dir.cwd().createFile(io, tmp, .{
            .truncate = true,
            .permissions = .fromMode(0o600),
        });
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(json);
        try w.interface.flush();
    }
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), p, io);
}

fn finishStored(
    lookup: env.Lookup,
    auth_json: []const u8,
    spec: catalog.Spec,
    flag_model: ?[]const u8,
) ?catalog.Resolved {
    const key = resolveKey(lookup, auth_json, spec) orelse return null;
    const base = lookup.get("OMFX_BASE_URL") orelse spec.base_url;
    if (base.len == 0) return null;
    return .{
        .spec = spec,
        .api_key = key,
        .base_url = base,
        .model = flag_model orelse lookup.get("OMFX_MODEL") orelse spec.model,
    };
}

fn firstStored(
    lookup: env.Lookup,
    auth_json: []const u8,
    flag_model: ?[]const u8,
    class: types.Credential.Kind,
) ?catalog.Resolved {
    for (catalog.all) |spec| {
        if (spec.explicit) continue;
        const cred = storedCred(auth_json, spec) orelse continue;
        if (cred.kind() != class) continue;
        if (finishStored(lookup, auth_json, spec, flag_model)) |r| return r;
    }
    return null;
}

pub fn resolveStored(
    lookup: env.Lookup,
    auth_json: []const u8,
    flag_provider: ?[]const u8,
    flag_model: ?[]const u8,
) ?catalog.Resolved {
    if (flag_provider) |id| {
        const spec = catalog.byId(id) orelse return null;
        const key = resolveKey(lookup, auth_json, spec) orelse
            (if (spec.explicit) "" else return null);
        const base = lookup.get("OMFX_BASE_URL") orelse spec.base_url;
        if (base.len == 0 and !spec.explicit) return null;
        return .{
            .spec = spec,
            .api_key = key,
            .base_url = if (base.len == 0) spec.base_url else base,
            .model = flag_model orelse lookup.get("OMFX_MODEL") orelse spec.model,
        };
    }
    if (auth_json.len > 0) {
        if (firstStored(lookup, auth_json, flag_model, .oauth)) |r| return r;
        if (firstStored(lookup, auth_json, flag_model, .api_key)) |r| return r;
    }
    if (catalog.resolve(lookup)) |r| {
        if (flag_model) |m| {
            var copy = r;
            copy.model = m;
            return copy;
        }
        return r;
    }
    return null;
}

test "extract api key and oauth token" {
    const blob =
        \\{"groq":{"type":"api_key","key":"gsk"},"github-copilot":{"type":"oauth","access_token":"ghu","refresh_token":"r"}}
    ;
    try std.testing.expectEqualStrings("gsk", extractKey(blob, "groq").?);
    try std.testing.expectEqualStrings("ghu", extractKey(blob, "github-copilot").?);
    switch (extract(blob, "groq").?) {
        .api_key => |k| try std.testing.expectEqualStrings("gsk", k),
        .oauth => unreachable,
    }
    switch (extract(blob, "github-copilot").?) {
        .oauth => |o| try std.testing.expectEqualStrings("r", o.refresh),
        .api_key => unreachable,
    }
}

test "oauth also reads access field" {
    const blob =
        \\{"xai-oauth":{"type":"oauth","access":"tok","refresh":"ref"}}
    ;
    try std.testing.expectEqualStrings("tok", extractKey(blob, "xai-oauth").?);
}

test "extract matches whole provider id" {
    const blob =
        \\{"xai-oauth":{"type":"oauth","access_token":"jwt"}}
    ;
    try std.testing.expect(extract(blob, "xai") == null);
    try std.testing.expectEqualStrings("jwt", extractKey(blob, "xai-oauth").?);
}

test "xai-oauth stored token beats leftover XAI_API_KEY" {
    const table = env.Table{ .pairs = &.{
        .{ .key = "XAI_API_KEY", .value = "sk-wrong" },
        .{ .key = "CEREBRAS_API_KEY", .value = "csk-wrong" },
    } };
    const spec = catalog.byId("xai-oauth").?;
    const blob =
        \\{"xai-oauth":{"type":"oauth","access_token":"jwt-ok","refresh_token":"r"}}
    ;
    try std.testing.expectEqual(types.Credential.Kind.oauth, resolveSource(table.lookup(), blob, spec).?.kind());
    try std.testing.expectEqualStrings("jwt-ok", resolveKey(table.lookup(), blob, spec).?);
    const got = resolveStored(table.lookup(), blob, "xai-oauth", null).?;
    try std.testing.expectEqualStrings("xai-oauth", got.spec.id);
    try std.testing.expectEqualStrings("jwt-ok", got.api_key);
    const via_xai = resolveStored(table.lookup(), blob, "xai", null).?;
    try std.testing.expectEqualStrings("xai-oauth", via_xai.spec.id);
    try std.testing.expectEqualStrings("jwt-ok", via_xai.api_key);
    const auto = resolveStored(table.lookup(), blob, null, null).?;
    try std.testing.expectEqualStrings("xai-oauth", auto.spec.id);
    try std.testing.expectEqualStrings("jwt-ok", auto.api_key);
}

test "xai-oauth env token beats stored" {
    const table = env.Table{ .pairs = &.{
        .{ .key = "XAI_OAUTH_TOKEN", .value = "from-env" },
        .{ .key = "XAI_API_KEY", .value = "sk-wrong" },
    } };
    const spec = catalog.byId("xai-oauth").?;
    const blob =
        \\{"xai-oauth":{"type":"oauth","access_token":"jwt-ok"}}
    ;
    try std.testing.expectEqual(.oauth_env, std.meta.activeTag(resolveSource(table.lookup(), blob, spec).?));
    try std.testing.expectEqualStrings("from-env", resolveKey(table.lookup(), blob, spec).?);
}

test "anthropic oauth then api key" {
    const spec = catalog.byId("anthropic").?;
    const blob =
        \\{"anthropic":{"type":"oauth","access_token":"oat","refresh_token":"r"}}
    ;
    const leftover = env.Table{ .pairs = &.{.{ .key = "ANTHROPIC_API_KEY", .value = "sk-ant" }} };
    try std.testing.expectEqualStrings("oat", resolveKey(leftover.lookup(), blob, spec).?);
    const oat_env = env.Table{ .pairs = &.{
        .{ .key = "ANTHROPIC_OAUTH_TOKEN", .value = "env-oat" },
        .{ .key = "ANTHROPIC_API_KEY", .value = "sk-ant" },
    } };
    try std.testing.expectEqualStrings("env-oat", resolveKey(oat_env.lookup(), blob, spec).?);
    const key_only = env.Table{ .pairs = &.{.{ .key = "ANTHROPIC_API_KEY", .value = "sk-ant" }} };
    try std.testing.expectEqualStrings("sk-ant", resolveKey(key_only.lookup(), "{}", spec).?);
}

test "auto pick prefers stored oauth over stored api key" {
    const table = env.Table{ .pairs = &.{.{ .key = "GROQ_API_KEY", .value = "gsk" }} };
    const blob =
        \\{"groq":{"type":"api_key","key":"gsk"},"xai-oauth":{"type":"oauth","access_token":"jwt-ok"}}
    ;
    const got = resolveStored(table.lookup(), blob, null, null).?;
    try std.testing.expectEqualStrings("xai-oauth", got.spec.id);
    try std.testing.expectEqualStrings("jwt-ok", got.api_key);
}

test "an api-key env var beats the stored copy of the same key" {
    const spec = catalog.byId("openai").?;
    const table = env.Table{ .pairs = &.{.{ .key = "OPENAI_API_KEY", .value = "sk-env" }} };
    const blob =
        \\{"openai":{"type":"api_key","key":"sk-stored"}}
    ;
    try std.testing.expectEqualStrings("sk-env", resolveKey(table.lookup(), blob, spec).?);
    const empty = env.Table{ .pairs = &.{} };
    try std.testing.expectEqualStrings("sk-stored", resolveKey(empty.lookup(), blob, spec).?);
}

test "encode api key json" {
    const s = try encodeApiKey(std.testing.allocator, "anthropic", "sk-ant");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("sk-ant", extractKey(s, "anthropic").?);
}

test "upsert adds and replaces provider objects" {
    const first = try upsertRaw(std.testing.allocator, "", "groq", "{\"type\":\"api_key\",\"key\":\"gsk\"}");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("gsk", extractKey(first, "groq").?);

    const second = try upsertRaw(std.testing.allocator, first, "xai-oauth", "{\"type\":\"oauth\",\"access_token\":\"tok\"}");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("gsk", extractKey(second, "groq").?);
    try std.testing.expectEqualStrings("tok", extractKey(second, "xai-oauth").?);

    const third = try upsertRaw(std.testing.allocator, second, "groq", "{\"type\":\"api_key\",\"key\":\"new\"}");
    defer std.testing.allocator.free(third);
    try std.testing.expectEqualStrings("new", extractKey(third, "groq").?);
    try std.testing.expectEqualStrings("tok", extractKey(third, "xai-oauth").?);
}

test "listIds walks stored providers" {
    const blob =
        \\{"groq":{"type":"api_key","key":"gsk"},"xai-oauth":{"type":"oauth","access_token":"tok"}}
    ;
    var ids: [max_listed][]const u8 = undefined;
    const n = listIds(blob, &ids);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("groq", ids[0]);
    try std.testing.expectEqualStrings("xai-oauth", ids[1]);
}

test "extractOAuth reads expires_at and token_endpoint" {
    const blob =
        \\{"xai-oauth":{"type":"oauth","access_token":"jwt","refresh_token":"r","token_type":"bearer","token_endpoint":"https://auth.x.ai/oauth/token","expires_at":1787333523}}
    ;
    const rec = extractOAuth(blob, "xai-oauth").?;
    try std.testing.expectEqualStrings("jwt", rec.access);
    try std.testing.expectEqualStrings("r", rec.refresh);
    try std.testing.expectEqualStrings("https://auth.x.ai/oauth/token", rec.token_endpoint);
    try std.testing.expectEqual(@as(i64, 1787333523), rec.expires_at);
    try std.testing.expect(rec.stale(1787333523));
    try std.testing.expect(!rec.stale(1787333522));
}

test "encodeOAuthObject roundtrips through extractOAuth" {
    const obj = try encodeOAuthObject(std.testing.allocator, .{
        .access = "jwt2",
        .refresh = "ref2",
        .expires_at = 42,
        .token_endpoint = "https://auth.x.ai/oauth/token",
    });
    defer std.testing.allocator.free(obj);
    const wrapped = try std.fmt.allocPrint(std.testing.allocator, "{{\"xai-oauth\":{s}}}", .{obj});
    defer std.testing.allocator.free(wrapped);
    const rec = extractOAuth(wrapped, "xai-oauth").?;
    try std.testing.expectEqualStrings("jwt2", rec.access);
    try std.testing.expectEqualStrings("ref2", rec.refresh);
    try std.testing.expectEqual(@as(i64, 42), rec.expires_at);
}

test "removeId drops one provider and keeps the rest" {
    const blob =
        \\{"groq":{"type":"api_key","key":"gsk"},"xai-oauth":{"type":"oauth","access_token":"tok"}}
    ;
    const gone = try removeId(std.testing.allocator, blob, "groq");
    defer std.testing.allocator.free(gone);
    try std.testing.expect(extractKey(gone, "groq") == null);
    try std.testing.expectEqualStrings("tok", extractKey(gone, "xai-oauth").?);

    const empty = try removeId(std.testing.allocator, gone, "xai-oauth");
    defer std.testing.allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "xai-oauth") == null);
}
