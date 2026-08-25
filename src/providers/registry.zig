//! Model metadata read from the provider, not from a table in this repo.
//!
//! The built-in list in `models.zig` goes stale the moment a vendor ships a
//! model, and it cannot be right about the things that differ per model per
//! vendor: one Grok takes 2M of context, one Claude takes 1M only behind a
//! beta header, and the reasoning vocabulary is `low|medium|high` for one
//! vendor, `none..max` for another, and nothing at all for a third. So
//! the list is asked for.
//!
//! What each provider actually publishes, which is not the same thing:
//!
//!   Anthropic  /v1/models          id, display_name, max_input_tokens,
//!                                  capabilities.effort.{low,medium,high,
//!                                  xhigh,max}.supported
//!   xAI        /v1/models          id, aliases, context_length
//!   OpenAI     /v1/models          id only
//!   Groq       /openai/v1/models   id, context_window, max_completion_tokens
//!   Copilot    /models             id, capabilities.limits.max_context_window_tokens
//!   Command Code /provider/v1/models  id, name, context_length only —
//!                                  vision/reasoning/protocol are fetched from
//!                                  their published model docs and cached under
//!                                  `cache/caps-{provider}.json`.
//!
//! Only Anthropic publishes effort levels on /models. For the rest the built-in
//! table seeds the cache once, then the cache (and docs fetch) win. Everything
//! a provider does publish wins over the table.
//!
//! One thing a provider will not tell you: the same model gives a
//! subscription and an API key different context windows. GPT-5.5 is 1M on an
//! API key and 400K through a ChatGPT login, because the login routes via the
//! Codex backend; Claude is 200K on a Pro/Max token and 1M on an API key that
//! sends the 1M beta header. The `/models` response carries the API number in
//! both cases, so trusting it on a subscription row overstates the window and
//! the session runs past the limit before compaction fires. `authCap` holds
//! the documented ceiling per login route and clamps whatever was fetched.

const std = @import("std");
const Io = std.Io;

const types = @import("types.zig");
const models = @import("models.zig");
const catalog = @import("catalog.zig");
const config = @import("../core/config.zig");

const log = std.log.scoped(.registry);

pub const file_name = "models.json";
/// Receipt: Anthropic returns ~40 models with capability blocks at ~1.5 KB
/// each, so 512 KB is a tripwire for a response nobody meant to send.
pub const max_body: usize = 512 * 1024;
/// Command Code's model docs page is ~400 KB of HTML; leave headroom.
pub const max_docs_body: usize = 2 * 1024 * 1024;
pub const max_models: usize = 128;
/// Longest effort vocabulary seen: none,low,medium,high,xhigh,max.
pub const max_efforts: usize = 64;

pub const commandcode_caps_url = "https://commandcode.ai/docs/reference/cli/models";

/// A capability the /models route may omit. Cached once known.
pub const Tri = enum { unknown, no, yes };

comptime {
    // `anthropicEfforts` writes the joined level names into a buffer of this
    // size; too small and a model silently loses its top level.
    const longest = "none,low,medium,high,xhigh,max";
    if (max_efforts < longest.len) @compileError("max_efforts must hold the longest vocabulary");
    if (max_models == 0) @compileError("max_models must hold at least one model");
}

pub const Entry = struct {
    id_buf: [96]u8 = undefined,
    id_len: usize = 0,
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    efforts_buf: [max_efforts]u8 = undefined,
    efforts_len: usize = 0,
    context_window: u32 = 0,
    max_tokens: u32 = 0,
    vision: Tri = .unknown,
    reasoning: Tri = .unknown,
    has_protocol: bool = false,
    protocol: types.Protocol = .openai_compat,

    pub fn id(self: *const Entry) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn efforts(self: *const Entry) []const u8 {
        return self.efforts_buf[0..self.efforts_len];
    }

    fn setId(self: *Entry, s: []const u8) void {
        self.id_len = copyInto(&self.id_buf, s);
    }

    fn setName(self: *Entry, s: []const u8) void {
        self.name_len = copyInto(&self.name_buf, s);
    }

    fn setEfforts(self: *Entry, s: []const u8) void {
        self.efforts_len = copyInto(&self.efforts_buf, s);
    }

    fn setVision(self: *Entry, yes: bool) void {
        self.vision = if (yes) .yes else .no;
    }

    fn setReasoning(self: *Entry, yes: bool) void {
        self.reasoning = if (yes) .yes else .no;
    }

    fn setProtocol(self: *Entry, p: types.Protocol) void {
        self.has_protocol = true;
        self.protocol = p;
    }
};

fn copyInto(dst: []u8, s: []const u8) usize {
    const n = @min(dst.len, s.len);
    @memcpy(dst[0..n], s[0..n]);
    return n;
}

pub const List = struct {
    items: [max_models]Entry = undefined,
    n: usize = 0,

    pub fn slice(self: *const List) []const Entry {
        return self.items[0..self.n];
    }

    pub fn find(self: *const List, want: []const u8) ?*const Entry {
        for (self.items[0..self.n]) |*e| {
            if (std.mem.eql(u8, e.id(), want)) return e;
        }
        return null;
    }

    fn push(self: *List) ?*Entry {
        if (self.n == max_models) return null;
        self.items[self.n] = .{};
        self.n += 1;
        return &self.items[self.n - 1];
    }
};

/// Which shape a provider's model list comes back in. Named after what it
/// carries rather than after the vendor, because Groq and Copilot ship the
/// same OpenAI envelope with different capability fields.
pub const Shape = enum { anthropic, openai_like, none };

pub fn shapeFor(provider: []const u8) Shape {
    if (std.mem.startsWith(u8, provider, "anthropic")) return .anthropic;
    if (std.mem.startsWith(u8, provider, "xai")) return .openai_like;
    if (std.mem.eql(u8, provider, "openai")) return .openai_like;
    if (std.mem.eql(u8, provider, "groq")) return .openai_like;
    if (std.mem.eql(u8, provider, "github-copilot")) return .openai_like;
    if (std.mem.eql(u8, provider, "openrouter")) return .openai_like;
    // Command Code publishes one catalog for every vendor it fronts, at
    // /provider/v1/models, in the OpenAI envelope.
    if (std.mem.startsWith(u8, provider, "commandcode")) return .openai_like;
    // Codex speaks Responses at its own route and publishes no model list.
    return .none;
}

/// The path a provider serves its model list from, relative to its base url.
pub fn pathFor(provider: []const u8) []const u8 {
    _ = provider;
    return "/models";
}

// -- parsing -----------------------------------------------------------------
//
// Hand-rolled rather than a JSON tree: the responses are large, only six
// fields are wanted, and the objects nest differently per vendor. Scanning for
// the keys inside each model's own object keeps this to one pass and no
// allocation.

/// The bounds of the `i`th top-level object inside `arr`, which starts at the
/// opening bracket of an array.
fn objectAt(arr: []const u8, from: usize) ?struct { start: usize, end: usize } {
    var i = from;
    while (i < arr.len and arr[i] != '{') : (i += 1) {
        if (arr[i] == ']') return null;
    }
    if (i >= arr.len) return null;
    const start = i;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    while (i < arr.len) : (i += 1) {
        const c = arr[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .start = start, .end = i + 1 };
            },
            else => {},
        }
    }
    return null;
}

fn stringField(obj: []const u8, key: []const u8) []const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return "";
    const at = std.mem.indexOf(u8, obj, needle) orelse return "";
    var i = at + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\n')) i += 1;
    if (i >= obj.len or obj[i] != '"') return "";
    i += 1;
    const end = std.mem.indexOfScalarPos(u8, obj, i, '"') orelse return "";
    return obj[i..end];
}

fn numberField(obj: []const u8, key: []const u8) u32 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return 0;
    const at = std.mem.indexOf(u8, obj, needle) orelse return 0;
    var i = at + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\n')) i += 1;
    var j = i;
    while (j < obj.len and obj[j] >= '0' and obj[j] <= '9') j += 1;
    if (j == i) return 0;
    return std.fmt.parseInt(u32, obj[i..j], 10) catch 0;
}

/// The first number among `keys` that the object carries. Vendors spell the
/// same quantity differently and some ship the key set to zero, so a zero is
/// treated as absent and the next spelling is tried.
fn firstNumber(obj: []const u8, keys: []const []const u8) u32 {
    for (keys) |k| {
        const n = numberField(obj, k);
        if (n != 0) return n;
    }
    return 0;
}

/// The levels Anthropic marks supported, in the order a user steps through
/// them. Read out of `capabilities.effort`, whose per-level objects each carry
/// their own `supported` flag.
fn anthropicEfforts(obj: []const u8, out: []u8) usize {
    const at = std.mem.indexOf(u8, obj, "\"effort\"") orelse return 0;
    const block = obj[at..];
    const order = [_][]const u8{ "none", "low", "medium", "high", "xhigh", "max" };
    var w: usize = 0;
    for (order) |level| {
        var needle_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{level}) catch continue;
        const lat = std.mem.indexOf(u8, block, needle) orelse continue;
        // The flag has to be read out of this level's own object: the effort
        // block carries a `supported` of its own, and a window that overran
        // into it reported every level as available.
        const own = objectAt(block, lat + needle.len) orelse continue;
        if (std.mem.indexOf(u8, block[own.start..own.end], "\"supported\":true") == null) continue;
        if (w != 0) {
            if (w == out.len) break;
            out[w] = ',';
            w += 1;
        }
        const n = @min(level.len, out.len - w);
        if (n != level.len) break;
        @memcpy(out[w..][0..n], level);
        w += n;
    }
    return w;
}

/// Parse a provider's model list. Unknown fields are left at zero so the
/// caller can fall back rather than record a confident wrong number.
pub fn parse(shape: Shape, body: []const u8, out: *List) void {
    out.n = 0;
    if (shape == .none) return;
    // Anthropic and OpenAI both wrap in "data"; xAI's language-models route
    // wraps in "models". Start at whichever appears.
    const key = std.mem.indexOf(u8, body, "\"data\"") orelse
        std.mem.indexOf(u8, body, "\"models\"") orelse return;
    var at = key;
    while (objectAt(body, at)) |obj| {
        at = obj.end;
        const o = body[obj.start..obj.end];
        const id = stringField(o, "id");
        if (id.len == 0) continue;
        const e = out.push() orelse return;
        e.setId(id);
        const display = stringField(o, "display_name");
        e.setName(if (display.len != 0) display else id);
        e.context_window = firstNumber(o, &.{
            "max_input_tokens",
            "context_length",
            "context_window",
            "max_context_window_tokens",
        });
        e.max_tokens = firstNumber(o, &.{ "max_tokens", "max_completion_tokens", "max_output_tokens" });
        if (shape == .anthropic) e.efforts_len = anthropicEfforts(o, &e.efforts_buf);
    }
}

// -- cache -------------------------------------------------------------------

fn cachePath(allocator: std.mem.Allocator, home: []const u8, provider: []const u8) ![]u8 {
    const root = try config.profileRoot(allocator, home);
    defer allocator.free(root);
    const name = try std.fmt.allocPrint(allocator, "models-{s}.json", .{provider});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ root, "cache", name });
}

/// The cached body for a provider, or "" when there is none. Age is not
/// checked here: a stale list still beats no list when the network is gone.
pub fn readCache(allocator: std.mem.Allocator, io: Io, home: []const u8, provider: []const u8) []u8 {
    const p = cachePath(allocator, home, provider) catch return "";
    defer allocator.free(p);
    return Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_body)) catch "";
}

pub fn writeCache(allocator: std.mem.Allocator, io: Io, home: []const u8, provider: []const u8, body: []const u8) void {
    const p = cachePath(allocator, home, provider) catch return;
    defer allocator.free(p);
    writeFile(allocator, io, p, body);
}

fn writeFile(allocator: std.mem.Allocator, io: Io, path: []const u8, body: []const u8) void {
    _ = allocator;
    const dir = std.fs.path.dirname(path) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.debug("mkdir {s}: {s}", .{ dir, @errorName(err) });
        return;
    };
    var f = Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch |err| {
        log.debug("open {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    w.interface.writeAll(body) catch {};
    w.interface.flush() catch {};
}

fn capsPath(allocator: std.mem.Allocator, home: []const u8, provider: []const u8) ![]u8 {
    const root = try config.profileRoot(allocator, home);
    defer allocator.free(root);
    const name = try std.fmt.allocPrint(allocator, "caps-{s}.json", .{provider});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ root, "cache", name });
}

pub fn readCapsCache(allocator: std.mem.Allocator, io: Io, home: []const u8, provider: []const u8) []u8 {
    const p = capsPath(allocator, home, provider) catch return "";
    defer allocator.free(p);
    return Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_body)) catch "";
}

fn protocolName(p: types.Protocol) []const u8 {
    return switch (p) {
        .openai_compat => "openai_compat",
        .anthropic => "anthropic",
        .openai_responses => "openai_responses",
    };
}

fn protocolFromName(s: []const u8) ?types.Protocol {
    if (std.mem.eql(u8, s, "openai_compat")) return .openai_compat;
    if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, s, "openai_responses")) return .openai_responses;
    return null;
}

/// Persist vision/reasoning/protocol for models whose /models route omits them.
pub fn writeCapsCache(allocator: std.mem.Allocator, io: Io, home: []const u8, provider: []const u8, list: *const List) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, "{\"models\":{") catch return;
    var first = true;
    for (list.slice()) |e| {
        if (e.vision == .unknown and e.reasoning == .unknown and !e.has_protocol) continue;
        if (!first) out.append(allocator, ',') catch return;
        first = false;
        out.append(allocator, '"') catch return;
        out.appendSlice(allocator, e.id()) catch return;
        out.appendSlice(allocator, "\":{") catch return;
        var field = false;
        if (e.vision != .unknown) {
            out.appendSlice(allocator, "\"vision\":") catch return;
            out.appendSlice(allocator, if (e.vision == .yes) "true" else "false") catch return;
            field = true;
        }
        if (e.reasoning != .unknown) {
            if (field) out.append(allocator, ',') catch return;
            out.appendSlice(allocator, "\"reasoning\":") catch return;
            out.appendSlice(allocator, if (e.reasoning == .yes) "true" else "false") catch return;
            field = true;
        }
        if (e.has_protocol) {
            if (field) out.append(allocator, ',') catch return;
            out.appendSlice(allocator, "\"protocol\":\"") catch return;
            out.appendSlice(allocator, protocolName(e.protocol)) catch return;
            out.append(allocator, '"') catch return;
        }
        out.append(allocator, '}') catch return;
    }
    out.appendSlice(allocator, "}}") catch return;
    const p = capsPath(allocator, home, provider) catch return;
    defer allocator.free(p);
    writeFile(allocator, io, p, out.items);
}

/// Apply a previously cached caps file onto `list` without clobbering fields
/// already known from this session's fetch.
pub fn applyCapsCache(body: []const u8, list: *List) void {
    for (list.items[0..list.n]) |*e| {
        const id = e.id();
        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":{{", .{id}) catch continue;
        const at = std.mem.indexOf(u8, body, needle) orelse continue;
        const obj_start = at + needle.len - 1;
        const obj = objectAt(body, obj_start) orelse continue;
        const o = body[obj.start..obj.end];
        if (e.vision == .unknown) {
            if (std.mem.indexOf(u8, o, "\"vision\":true") != null) e.setVision(true) else if (std.mem.indexOf(u8, o, "\"vision\":false") != null) e.setVision(false);
        }
        if (e.reasoning == .unknown) {
            if (std.mem.indexOf(u8, o, "\"reasoning\":true") != null) e.setReasoning(true) else if (std.mem.indexOf(u8, o, "\"reasoning\":false") != null) e.setReasoning(false);
        }
        if (!e.has_protocol) {
            const pname = stringField(o, "protocol");
            if (pname.len != 0) {
                if (protocolFromName(pname)) |p| e.setProtocol(p);
            }
        }
    }
}

/// Fill gaps from the offline table — only fields still unknown.
pub fn seedFromBuiltin(provider: []const u8, list: *List) void {
    for (list.items[0..list.n]) |*e| {
        const m = models.lookup(provider, e.id()) orelse
            models.lookup("commandcode-anthropic", e.id()) orelse continue;
        if (e.vision == .unknown) e.setVision(m.vision);
        if (e.reasoning == .unknown) e.setReasoning(m.reasoning);
        if (!e.has_protocol) e.setProtocol(m.protocol);
        if (e.max_tokens == 0 and m.max_tokens != 0) e.max_tokens = m.max_tokens;
        if (e.efforts().len == 0 and m.efforts.len != 0) e.setEfforts(m.efforts);
    }
}

/// Deterministic wire shape when the catalog and docs are silent.
pub fn inferProtocols(provider: []const u8, list: *List) void {
    const cc = std.mem.startsWith(u8, provider, "commandcode");
    for (list.items[0..list.n]) |*e| {
        if (e.has_protocol) continue;
        if (cc and std.mem.startsWith(u8, e.id(), "claude")) {
            e.setProtocol(.anthropic);
        } else if (cc) {
            e.setProtocol(.openai_compat);
        }
    }
}

/// Parse Command Code's model docs: each row carries
/// `aria-label="Capabilities: Text input, Vision, Reasoning"`.
pub fn applyCommandCodeDocs(html: []const u8, list: *List) void {
    for (list.items[0..list.n]) |*e| {
        const label = findCapabilitiesLabel(html, e.id()) orelse continue;
        e.setVision(std.mem.indexOf(u8, label, "Vision") != null);
        e.setReasoning(std.mem.indexOf(u8, label, "Reasoning") != null);
        if (!e.has_protocol) {
            if (std.mem.startsWith(u8, e.id(), "claude")) e.setProtocol(.anthropic) else e.setProtocol(.openai_compat);
        }
    }
}

fn findCapabilitiesLabel(html: []const u8, id: []const u8) ?[]const u8 {
    var aliases: [2][]const u8 = .{ id, id };
    var n: usize = 1;
    // Docs list `claude-haiku-4-5`; the API may append a date suffix.
    if (std.mem.startsWith(u8, id, "claude-haiku-") and id.len > 18) {
        aliases[n] = id[0 .. id.len - 9];
        n += 1;
    }
    for (aliases[0..n]) |alias| {
        var from: usize = 0;
        while (from < html.len) {
            const at = std.mem.indexOfPos(u8, html, from, alias) orelse break;
            const window_end = @min(html.len, at + 3500);
            const window = html[at..window_end];
            if (std.mem.indexOf(u8, window, "Capabilities:")) |cap_at| {
                const rest = window[cap_at + "Capabilities:".len ..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                return rest[0..end];
            }
            from = at + alias.len;
        }
    }
    return null;
}

fn fetchUrl(allocator: std.mem.Allocator, io: Io, url: []const u8, limit: usize) []u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var extra = [_]std.http.Header{
        .{ .name = "Accept", .value = "text/html,application/json" },
        .{ .name = "user-agent", .value = "omfx/0.0.1" },
    };
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &extra,
        .response_writer = &aw.writer,
    }) catch |err| {
        log.debug("fetch {s}: {s}", .{ url, @errorName(err) });
        return "";
    };
    if (@intFromEnum(result.status) != 200) {
        log.debug("fetch {s}: http {d}", .{ url, @intFromEnum(result.status) });
        return "";
    }
    if (aw.written().len > limit) return "";
    return aw.toOwnedSlice() catch "";
}

/// When /models omits vision/reasoning, ask the provider's published docs and
/// cache the answer. Command Code is the only router that needs this today.
pub fn fetchMissingCaps(
    allocator: std.mem.Allocator,
    io: Io,
    provider: []const u8,
    list: *List,
) void {
    if (!std.mem.startsWith(u8, provider, "commandcode")) return;
    var need = false;
    for (list.slice()) |e| {
        if (e.vision == .unknown or e.reasoning == .unknown) {
            need = true;
            break;
        }
    }
    if (!need) return;
    const html = fetchUrl(allocator, io, commandcode_caps_url, max_docs_body);
    if (html.len == 0) return;
    defer allocator.free(html);
    applyCommandCodeDocs(html, list);
}

/// Fill every gap: disk cache → live docs fetch → builtin seed → inference.
pub fn enrich(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    provider: []const u8,
    list: *List,
) void {
    if (list.n == 0) return;
    const cached = readCapsCache(allocator, io, home, provider);
    if (cached.len != 0) {
        defer allocator.free(cached);
        applyCapsCache(cached, list);
    }
    fetchMissingCaps(allocator, io, provider, list);
    seedFromBuiltin(provider, list);
    inferProtocols(provider, list);
    writeCapsCache(allocator, io, home, provider, list);
}

// -- merge -------------------------------------------------------------------

/// The documented context ceiling for a login route, or 0 when the route
/// imposes none beyond the model's own.
///
/// Sourced from the vendors, and dated, because these move:
///   openai-codex        400_000  ChatGPT login routes via the Codex backend,
///                                which caps at 400K while the same model on
///                                an API key is 1M (openai/codex#19464).
///   anthropic           200_000  A Pro/Max token cannot send the 1M beta
///                                header (context-1m-2025-08-07), which is
///                                what lifts an API key past 200K.
///   github-copilot      128_000  Copilot reports a large context_window but
///                                enforces a smaller max_prompt
///                                (community#186340).
/// Checked 2026-08-22.
pub fn authCap(provider: []const u8) u32 {
    if (std.mem.eql(u8, provider, "openai-codex")) return 400_000;
    if (std.mem.eql(u8, provider, "openai-codex-device")) return 400_000;
    if (std.mem.eql(u8, provider, "anthropic")) return 200_000;
    if (std.mem.eql(u8, provider, "github-copilot")) return 128_000;
    return 0;
}

/// `built` with every field the provider published written over it.
///
/// The table stays authoritative for effort on providers that publish none,
/// and for anything the response omitted: a zero / unknown from a provider
/// means "not said", never "zero" or "false".
pub fn merge(built: models.Model, e: *const Entry) models.Model {
    var out = built;
    if (e.name().len != 0) out.name = e.name();
    if (e.context_window != 0) out.context_window = e.context_window;
    const cap = authCap(built.provider);
    if (cap != 0 and out.context_window > cap) out.context_window = cap;
    if (e.max_tokens != 0) out.max_tokens = e.max_tokens;
    if (e.efforts().len != 0) {
        out.efforts = e.efforts();
        out.reasoning = true;
    }
    if (e.vision != .unknown) out.vision = e.vision == .yes;
    if (e.reasoning != .unknown) out.reasoning = e.reasoning == .yes;
    if (e.has_protocol) out.protocol = e.protocol;
    return out;
}

test "anthropic effort levels come from the capability block" {
    const body =
        \\{"data":[{"id":"claude-opus-5","display_name":"Claude Opus 5","max_input_tokens":1000000,
        \\"capabilities":{"effort":{"high":{"supported":true},"low":{"supported":true},
        \\"max":{"supported":true},"medium":{"supported":true},"supported":true,
        \\"xhigh":{"supported":true}}},"max_tokens":64000,"type":"model"}]}
    ;
    var list = List{};
    parse(.anthropic, body, &list);
    try std.testing.expectEqual(@as(usize, 1), list.n);
    const e = list.find("claude-opus-5").?;
    try std.testing.expectEqualStrings("Claude Opus 5", e.name());
    try std.testing.expectEqualStrings("low,medium,high,xhigh,max", e.efforts());
    try std.testing.expectEqual(@as(u32, 1_000_000), e.context_window);
    try std.testing.expectEqual(@as(u32, 64_000), e.max_tokens);
}

test "a level the vendor marks unsupported is not offered" {
    const body =
        \\{"data":[{"id":"claude-haiku","capabilities":{"effort":{"low":{"supported":true},
        \\"medium":{"supported":true},"high":{"supported":false},"supported":true}}}]}
    ;
    var list = List{};
    parse(.anthropic, body, &list);
    try std.testing.expectEqualStrings("low,medium", list.find("claude-haiku").?.efforts());
}

test "xai publishes a context length and no efforts" {
    const body =
        \\{"data":[{"id":"grok-420-reasoning","aliases":[],"context_length":256000,
        \\"created":1768003200,"object":"model","owned_by":"xai"},
        \\{"id":"grok-imagine-image","context_length":1024,"object":"model"}]}
    ;
    var list = List{};
    parse(.openai_like, body, &list);
    try std.testing.expectEqual(@as(usize, 2), list.n);
    const e = list.find("grok-420-reasoning").?;
    try std.testing.expectEqual(@as(u32, 256_000), e.context_window);
    // xAI says nothing about effort, so the table keeps that field.
    try std.testing.expectEqualStrings("", e.efforts());
}

test "groq and copilot spellings of the context window are both read" {
    var list = List{};
    parse(.openai_like, "{\"data\":[{\"id\":\"a\",\"context_window\":131072}]}", &list);
    try std.testing.expectEqual(@as(u32, 131_072), list.find("a").?.context_window);
    parse(.openai_like, "{\"data\":[{\"id\":\"b\",\"capabilities\":{\"limits\":{\"max_context_window_tokens\":400000}}}]}", &list);
    try std.testing.expectEqual(@as(u32, 400_000), list.find("b").?.context_window);
}

test "a subscription route is held to its own ceiling, not the API's" {
    const built = models.Model{
        .id = "gpt-5.5",
        .name = "GPT-5.5",
        .provider = "openai-codex",
        .protocol = .openai_responses,
        .base_url = "https://chatgpt.com/backend-api/codex",
        .reasoning = true,
        .context_window = 400_000,
        .max_tokens = 128_000,
        .efforts = "none,low,medium,high,xhigh,max",
        .vision = true,
    };
    var e = Entry{};
    e.setId("gpt-5.5");
    // What the API route publishes for the same model.
    e.context_window = 1_050_000;
    try std.testing.expectEqual(@as(u32, 400_000), merge(built, &e).context_window);

    // The same number on the API row is taken as published.
    var api = built;
    api.provider = "openai";
    try std.testing.expectEqual(@as(u32, 1_050_000), merge(api, &e).context_window);
}

test "the documented ceilings are the ones the vendors publish" {
    try std.testing.expectEqual(@as(u32, 400_000), authCap("openai-codex"));
    try std.testing.expectEqual(@as(u32, 200_000), authCap("anthropic"));
    // An API key has no route ceiling of its own.
    try std.testing.expectEqual(@as(u32, 0), authCap("anthropic-api"));
    try std.testing.expectEqual(@as(u32, 0), authCap("xai-api"));
}

test "a merge takes what the provider said and keeps what it did not" {
    const built = models.Model{
        .id = "m",
        .name = "Built In",
        .provider = "xai-api",
        .protocol = .openai_compat,
        .base_url = "https://api.x.ai/v1",
        .reasoning = true,
        .context_window = 131072,
        .max_tokens = 8192,
        .efforts = "low,high",
        .vision = true,
    };
    var e = Entry{};
    e.setId("m");
    e.context_window = 2_000_000;
    const out = merge(built, &e);
    try std.testing.expectEqual(@as(u32, 2_000_000), out.context_window);
    // Not published, so the documented values survive.
    try std.testing.expectEqual(@as(u32, 8192), out.max_tokens);
    try std.testing.expectEqualStrings("low,high", out.efforts);
    try std.testing.expect(out.vision);
}

test "a truncated or foreign body yields nothing rather than junk" {
    var list = List{};
    parse(.anthropic, "{\"data\":[{\"id\":\"a\"", &list);
    try std.testing.expectEqual(@as(usize, 0), list.n);
    parse(.openai_like, "not json", &list);
    try std.testing.expectEqual(@as(usize, 0), list.n);
    parse(.none, "{\"data\":[{\"id\":\"a\"}]}", &list);
    try std.testing.expectEqual(@as(usize, 0), list.n);
}

test "command code fronts every vendor and publishes one catalog" {
    try std.testing.expectEqual(Shape.openai_like, shapeFor("commandcode"));
    try std.testing.expectEqual(Shape.openai_like, shapeFor("commandcode-anthropic"));
    // A router bills at the vendor's own rates and imposes no window of its
    // own, so nothing is clamped.
    try std.testing.expectEqual(@as(u32, 0), authCap("commandcode"));

    const body =
        \\{"data":[{"id":"deepseek/deepseek-v4-flash","context_window":128000},
        \\{"id":"claude-sonnet-4-6","max_input_tokens":200000}]}
    ;
    var list = List{};
    parse(.openai_like, body, &list);
    try std.testing.expectEqual(@as(usize, 2), list.n);
    try std.testing.expectEqual(@as(u32, 128_000), list.find("deepseek/deepseek-v4-flash").?.context_window);
    try std.testing.expectEqual(@as(u32, 200_000), list.find("claude-sonnet-4-6").?.context_window);
}

test "codex has no model list to ask for" {
    try std.testing.expectEqual(Shape.none, shapeFor("openai-codex"));
    try std.testing.expectEqual(Shape.anthropic, shapeFor("anthropic-api"));
    try std.testing.expectEqual(Shape.openai_like, shapeFor("xai-oauth"));
}

test "command code docs aria-label sets vision and reasoning" {
    const html =
        \\<td>deepseek/deepseek-v4-flash</td>
        \\<button aria-label="Capabilities: Text input, Reasoning"></button>
        \\<td>deepseek/deepseek-v4-flash-vision-exp</td>
        \\<button aria-label="Capabilities: Text input, Vision, Reasoning"></button>
        \\<td>claude-sonnet-5</td>
        \\<button aria-label="Capabilities: Text input, Vision, Reasoning"></button>
    ;
    var list = List{};
    const a = list.push().?;
    a.setId("deepseek/deepseek-v4-flash");
    const b = list.push().?;
    b.setId("deepseek/deepseek-v4-flash-vision-exp");
    const c = list.push().?;
    c.setId("claude-sonnet-5");
    applyCommandCodeDocs(html, &list);
    try std.testing.expectEqual(Tri.no, list.find("deepseek/deepseek-v4-flash").?.vision);
    try std.testing.expectEqual(Tri.yes, list.find("deepseek/deepseek-v4-flash").?.reasoning);
    try std.testing.expectEqual(Tri.yes, list.find("deepseek/deepseek-v4-flash-vision-exp").?.vision);
    try std.testing.expect(list.find("claude-sonnet-5").?.has_protocol);
    try std.testing.expectEqual(types.Protocol.anthropic, list.find("claude-sonnet-5").?.protocol);
}

test "inferProtocols routes commandcode claude to anthropic" {
    var list = List{};
    const a = list.push().?;
    a.setId("claude-opus-5");
    const b = list.push().?;
    b.setId("deepseek/deepseek-v4-flash");
    inferProtocols("commandcode", &list);
    try std.testing.expectEqual(types.Protocol.anthropic, list.find("claude-opus-5").?.protocol);
    try std.testing.expectEqual(types.Protocol.openai_compat, list.find("deepseek/deepseek-v4-flash").?.protocol);
}

test "caps cache round-trips vision and protocol" {
    const body =
        \\{"models":{"deepseek/deepseek-v4-flash":{"vision":false,"reasoning":true,"protocol":"openai_compat"},
        \\"claude-sonnet-5":{"vision":true,"reasoning":true,"protocol":"anthropic"}}}
    ;
    var list = List{};
    const a = list.push().?;
    a.setId("deepseek/deepseek-v4-flash");
    const b = list.push().?;
    b.setId("claude-sonnet-5");
    applyCapsCache(body, &list);
    try std.testing.expectEqual(Tri.no, list.find("deepseek/deepseek-v4-flash").?.vision);
    try std.testing.expectEqual(Tri.yes, list.find("deepseek/deepseek-v4-flash").?.reasoning);
    try std.testing.expectEqual(types.Protocol.anthropic, list.find("claude-sonnet-5").?.protocol);
}

test "merge takes vision and protocol from the live entry" {
    const built = models.Model{
        .id = "m",
        .name = "Built In",
        .provider = "commandcode",
        .protocol = .openai_compat,
        .base_url = "https://api.commandcode.ai/provider/v1",
        .reasoning = false,
        .context_window = 1000,
        .max_tokens = 0,
        .efforts = "",
        .vision = false,
    };
    var e = Entry{};
    e.setId("m");
    e.setVision(true);
    e.setReasoning(true);
    e.setProtocol(.anthropic);
    const out = merge(built, &e);
    try std.testing.expect(out.vision);
    try std.testing.expect(out.reasoning);
    try std.testing.expectEqual(types.Protocol.anthropic, out.protocol);
}

// -- live fetch --------------------------------------------------------------

/// GET a provider's model list. Returns the raw body, which the caller parses
/// and caches; an empty string means the provider did not answer.
///
/// Best effort by design: a coding session must start with no network, so a
/// failure here falls back to the cache and then to the built-in table.
pub fn fetch(
    allocator: std.mem.Allocator,
    io: Io,
    provider: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    vendor: types.Vendor,
) []u8 {
    if (shapeFor(provider) == .none or api_key.len == 0) return "";
    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{
        std.mem.trimEnd(u8, base_url, "/"),
        pathFor(provider),
    }) catch return "";
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch return "";
    defer allocator.free(bearer);

    var extra: [4]std.http.Header = undefined;
    var extra_n: usize = 0;
    extra[extra_n] = .{ .name = "Accept", .value = "application/json" };
    extra_n += 1;

    var headers: std.http.Client.Request.Headers = .{
        .authorization = .{ .override = bearer },
        // Avoid Zig 0.16 flate → writer rebase panics (zig#25021 class).
        .accept_encoding = .{ .override = "identity" },
    };
    const oat = std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
    if (vendor == .anthropic) {
        if (!oat) {
            headers.authorization = .omit;
            extra[extra_n] = .{ .name = "x-api-key", .value = api_key };
            extra_n += 1;
        }
        extra[extra_n] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        extra_n += 1;
    }
    if (std.mem.eql(u8, provider, "github-copilot")) {
        extra[extra_n] = .{ .name = "user-agent", .value = "omfx/0.0.1" };
        extra_n += 1;
    }

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = headers,
        .extra_headers = extra[0..extra_n],
        .response_writer = &aw.writer,
    }) catch |err| {
        log.debug("{s} models: {s}", .{ provider, @errorName(err) });
        return "";
    };
    if (@intFromEnum(result.status) != 200) {
        log.debug("{s} models: http {d}", .{ provider, @intFromEnum(result.status) });
        return "";
    }
    if (aw.written().len > max_body) return "";
    return aw.toOwnedSlice() catch "";
}

/// The provider's list: asked for once, then served from the cache when the
/// ask fails. Caps the list omits (vision, reasoning, protocol) are filled
/// from a sidecar cache, a docs fetch, the builtin seed, then inference.
///
/// Once per session rather than on a timer, because `Io.Clock` here has no
/// wall clock to compare a file mtime against, and because a session is short
/// next to how often a vendor ships a model. The caller holds the result for
/// the rest of the run.
pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    provider: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    vendor: types.Vendor,
    out: *List,
) void {
    out.n = 0;
    const shape = shapeFor(provider);
    if (shape == .none) return;
    const body = fetch(allocator, io, provider, base_url, api_key, vendor);
    if (body.len != 0) {
        defer allocator.free(body);
        writeCache(allocator, io, home, provider, body);
        parse(shape, body, out);
    }
    if (out.n == 0) {
        // Offline, unauthenticated, or a body we could not read: the last good
        // list is still better than a table that predates the binary.
        const cached = readCache(allocator, io, home, provider);
        if (cached.len == 0) return;
        defer allocator.free(cached);
        parse(shape, cached, out);
    }
    if (out.n == 0) return;
    enrich(allocator, io, home, provider, out);
}
