const std = @import("std");
const types = @import("types.zig");
const sse = @import("sse.zig");
const env = @import("../core/env.zig");
const tool = @import("../core/tool.zig");

pub const PostError = error{ OutOfMemory, Transport };

pub fn wireProtocol(endpoint: types.Endpoint) types.Protocol {
    if (endpoint.vendor == .anthropic and endpoint.protocol != .openai_responses) return .anthropic;
    return endpoint.protocol;
}

pub fn chatCompletionsUrl(allocator: std.mem.Allocator, endpoint: types.Endpoint) std.mem.Allocator.Error![]u8 {
    const base = std.mem.trimEnd(u8, endpoint.base_url, "/");
    if (endpoint.path.len > 0) {
        if (endpoint.path[0] == '/') {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, endpoint.path });
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, endpoint.path });
    }
    return switch (wireProtocol(endpoint)) {
        .openai_compat => std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base}),
        .anthropic => if (std.mem.endsWith(u8, base, "/v1"))
            std.fmt.allocPrint(allocator, "{s}/messages", .{base})
        else
            std.fmt.allocPrint(allocator, "{s}/v1/messages", .{base}),
        .openai_responses => std.fmt.allocPrint(allocator, "{s}/responses", .{base}),
    };
}

pub fn authErrorMessage(vendor: types.Vendor, status: u16) []const u8 {
    _ = status;
    return switch (vendor) {
        .openai => "openai authentication failed",
        .anthropic => "anthropic authentication failed",
        .google => "google authentication failed",
        .xai => "xAI rejected the credentials. Fix: omfx login xai-oauth",
        .custom => "custom provider authentication failed",
    };
}

pub fn isAuthFailure(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "rejected the credentials") != null or
        std.mem.indexOf(u8, text, "authentication failed") != null;
}

fn isBadKeyBody(status: u16, raw: []const u8) bool {
    if (status != 400) return false;
    return std.mem.indexOf(u8, raw, "Incorrect API key") != null or std.mem.indexOf(u8, raw, "invalid_api_key") != null;
}

pub const ExtraCall = struct {
    name: []u8,
    args: []u8,
};

pub const ChatResult = struct {
    status: u16,
    outcome: types.ChatOutcome,
    extra: []ExtraCall = &.{},

    pub fn deinit(self: ChatResult, allocator: std.mem.Allocator) void {
        self.outcome.deinit(allocator);
        for (self.extra) |e| {
            allocator.free(e.name);
            allocator.free(e.args);
        }
        if (self.extra.len > 0) allocator.free(self.extra);
    }

    pub fn textSlice(self: ChatResult) []const u8 {
        return self.outcome.textSlice();
    }
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    images: []const types.Image = &.{},
};

pub fn defaultModel(vendor: types.Vendor) []const u8 {
    return switch (vendor) {
        .openai => "gpt-4o-mini",
        .anthropic => "claude-sonnet-4-5",
        .google => "gemini-2.5-flash",
        .xai => "grok-3",
        .custom => "gpt-4o-mini",
    };
}

pub fn resolveVendor(lookup: env.Lookup) ?types.Vendor {
    const catalog = @import("catalog.zig");
    const resolved = catalog.resolve(lookup) orelse return null;
    return catalog.vendorOf(resolved.spec);
}

pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn requestMaxOutputTokens(max_output_tokens: u32, context_window: u32) ?u32 {
    if (max_output_tokens == 0) return null;
    if (context_window > 0 and max_output_tokens >= context_window) return null;
    return max_output_tokens;
}

fn limitAndEffortJson(allocator: std.mem.Allocator, endpoint: types.Endpoint, max_key: []const u8) ![]u8 {
    const tokens = requestMaxOutputTokens(endpoint.max_output_tokens, endpoint.context_window);
    const effort = if (endpoint.effort.len == 0 or std.mem.eql(u8, endpoint.effort, "none"))
        ""
    else
        endpoint.effort;
    if (tokens == null and effort.len == 0) return allocator.dupe(u8, "");
    if (tokens) |n| {
        if (effort.len == 0) return std.fmt.allocPrint(allocator, "\"{s}\":{d},", .{ max_key, n });
        return std.fmt.allocPrint(allocator, "\"{s}\":{d},\"reasoning_effort\":\"{s}\",", .{ max_key, n, effort });
    }
    return std.fmt.allocPrint(allocator, "\"reasoning_effort\":\"{s}\",", .{effort});
}

pub fn buildOpenAiBody(allocator: std.mem.Allocator, model: []const u8, user: []const u8, system: []const u8) ![]u8 {
    return buildOpenAiBodyEx(allocator, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = model,
    }, user, system);
}

pub fn buildOpenAiBodyEx(allocator: std.mem.Allocator, endpoint: types.Endpoint, user: []const u8, system: []const u8) ![]u8 {
    const msgs = [_]Message{.{ .role = "user", .content = user }};
    return buildOpenAiBodyMsgs(allocator, endpoint, &msgs, system);
}

fn encodeMessages(allocator: std.mem.Allocator, messages: []const Message, protocol: types.Protocol) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (messages, 0..) |m, i| {
        if (i != 0) try out.append(allocator, ',');
        const piece = try encodeOneMessage(allocator, m, protocol);
        defer allocator.free(piece);
        try out.appendSlice(allocator, piece);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn encodeOneMessage(allocator: std.mem.Allocator, m: Message, protocol: types.Protocol) ![]u8 {
    const esc_role = try jsonEscape(allocator, m.role);
    defer allocator.free(esc_role);
    const esc_text = try jsonEscape(allocator, m.content);
    defer allocator.free(esc_text);
    if (m.images.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\",\"content\":\"{s}\"}}", .{ esc_role, esc_text });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"role\":\"");
    try out.appendSlice(allocator, esc_role);
    try out.appendSlice(allocator, "\",\"content\":[");
    switch (protocol) {
        .openai_responses => {
            try out.appendSlice(allocator, "{\"type\":\"input_text\",\"text\":\"");
            try out.appendSlice(allocator, esc_text);
            try out.appendSlice(allocator, "\"}");
        },
        .openai_compat, .anthropic => {
            try out.appendSlice(allocator, "{\"type\":\"text\",\"text\":\"");
            try out.appendSlice(allocator, esc_text);
            try out.appendSlice(allocator, "\"}");
        },
    }
    for (m.images) |im| {
        try out.append(allocator, ',');
        switch (im) {
            .url => |raw_url| {
                const esc_url = try jsonEscape(allocator, raw_url);
                defer allocator.free(esc_url);
                switch (protocol) {
                    .anthropic => {
                        try out.appendSlice(allocator, "{\"type\":\"image\",\"source\":{\"type\":\"url\",\"url\":\"");
                        try out.appendSlice(allocator, esc_url);
                        try out.appendSlice(allocator, "\"}}");
                    },
                    .openai_compat => {
                        try out.appendSlice(allocator, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"");
                        try out.appendSlice(allocator, esc_url);
                        try out.appendSlice(allocator, "\"}}");
                    },
                    .openai_responses => {
                        try out.appendSlice(allocator, "{\"type\":\"input_image\",\"image_url\":\"");
                        try out.appendSlice(allocator, esc_url);
                        try out.appendSlice(allocator, "\"}");
                    },
                }
            },
            .file => |f| {
                const mime = f.mime.asSlice();
                switch (protocol) {
                    .anthropic => {
                        try out.appendSlice(allocator, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
                        try out.appendSlice(allocator, mime);
                        try out.appendSlice(allocator, "\",\"data\":\"");
                        try out.appendSlice(allocator, f.b64);
                        try out.appendSlice(allocator, "\"}}");
                    },
                    .openai_compat => {
                        try out.appendSlice(allocator, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                        try out.appendSlice(allocator, mime);
                        try out.appendSlice(allocator, ";base64,");
                        try out.appendSlice(allocator, f.b64);
                        try out.appendSlice(allocator, "\"}}");
                    },
                    .openai_responses => {
                        try out.appendSlice(allocator, "{\"type\":\"input_image\",\"image_url\":\"data:");
                        try out.appendSlice(allocator, mime);
                        try out.appendSlice(allocator, ";base64,");
                        try out.appendSlice(allocator, f.b64);
                        try out.appendSlice(allocator, "\"}");
                    },
                }
            },
        }
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn encodeMessagesWithSystem(allocator: std.mem.Allocator, system: []const u8, messages: []const Message, protocol: types.Protocol) ![]u8 {
    var all: std.ArrayList(Message) = .empty;
    defer all.deinit(allocator);
    try all.append(allocator, .{ .role = "system", .content = system });
    for (messages) |m| try all.append(allocator, m);
    return encodeMessages(allocator, all.items, protocol);
}

pub fn buildOpenAiBodyMsgs(
    allocator: std.mem.Allocator,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
) ![]u8 {
    return buildOpenAiBodyFiltered(allocator, endpoint, messages, system, true);
}

pub fn buildOpenAiBodyFiltered(
    allocator: std.mem.Allocator,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
    allow_peer: bool,
) ![]u8 {
    return buildOpenAiBodyFlags(allocator, endpoint, messages, system, .{ .allow_peer = allow_peer });
}

pub const ChatFlags = struct {
    allow_peer: bool = true,
    tools: bool = true,
    host: types.Stream = .{},
    /// Routes every request in one workspace to the machine holding that
    /// workspace's cached prefix. OpenAI hashes it together with the prefix,
    /// and GPT-5.6 needs it before it will use its more reliable matching at
    /// all. Empty means the field is omitted.
    ///
    /// Keyed by workspace rather than by session so a resumed session reads
    /// the cache the previous one wrote. Correctness never depends on it --
    /// the prefix hash still decides what matches -- so a collision costs a
    /// miss, not a wrong answer.
    cache_key: []const u8 = "",
    /// Send the optional headers that name omfx to the provider. Off unless
    /// the user turns it on in settings: they change nothing about the reply.
    telemetry: bool = false,
};

/// Whether this endpoint's model takes `prompt_cache_retention`, which raises
/// the idle window from five-to-ten minutes to twenty-four hours.
///
/// An allowlist rather than a guess: the field is rejected outright by models
/// that do not know it, and a 400 in the middle of a turn is a worse outcome
/// than a cold cache. Only first-party OpenAI is asked, because a proxy in
/// front of it may reject fields it does not recognize.
fn extendedRetention(endpoint: types.Endpoint) bool {
    if (endpoint.vendor != .openai) return false;
    if (!std.mem.eql(u8, endpoint.id, "openai") and
        !std.mem.startsWith(u8, endpoint.id, "openai-codex")) return false;
    const models = [_][]const u8{
        "gpt-5.5", "gpt-5.4", "gpt-5.2",     "gpt-5.1-codex-max", "gpt-5.1-codex-mini",
        "gpt-5.1", "gpt-5",   "gpt-5-codex", "gpt-4.1",
    };
    for (models) |m| {
        if (std.mem.eql(u8, endpoint.model, m)) return true;
        // `gpt-5.1-codex` and `gpt-5.1-chat-latest` are the same family.
        if (std.mem.startsWith(u8, endpoint.model, m) and
            endpoint.model.len > m.len and endpoint.model[m.len] == '-') return true;
    }
    return false;
}

/// The caching fields an OpenAI-shaped request carries, already comma-tailed.
fn cacheJson(allocator: std.mem.Allocator, endpoint: types.Endpoint, flags: ChatFlags) ![]u8 {
    const keep: []const u8 = if (extendedRetention(endpoint)) "\"prompt_cache_retention\":\"24h\"," else "";
    if (flags.cache_key.len == 0) return allocator.dupe(u8, keep);
    const esc = try jsonEscape(allocator, flags.cache_key);
    defer allocator.free(esc);
    return std.fmt.allocPrint(allocator, "\"prompt_cache_key\":\"{s}\",{s}", .{ esc, keep });
}

fn buildOpenAiBodyFlags(
    allocator: std.mem.Allocator,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
    flags: ChatFlags,
) std.mem.Allocator.Error![]u8 {
    const esc_model = try jsonEscape(allocator, endpoint.model);
    defer allocator.free(esc_model);
    const extra = try limitAndEffortJson(allocator, endpoint, "max_tokens");
    defer allocator.free(extra);
    const tools = if (flags.tools) try toolsJson(allocator, flags.allow_peer, .chat) else try allocator.dupe(u8, "[]");
    defer allocator.free(tools);
    const msgs_json = try encodeMessagesWithSystem(allocator, system, messages, .openai_compat);
    defer allocator.free(msgs_json);
    const cache = try cacheJson(allocator, endpoint, flags);
    defer allocator.free(cache);
    return std.fmt.allocPrint(allocator,
        \\{{"model":"{s}",{s}{s}"stream":true,"messages":{s},"tools":{s}}}
    , .{ esc_model, extra, cache, msgs_json, tools });
}

const ToolDef = struct { name: []const u8, description: []const u8, parameters: []const u8 };

/// Bytes the advertised tool schemas add to every request.
///
/// Counted rather than estimated: the schemas are string literals in this
/// file, and a number the user is shown about their context window should not
/// be a guess when the truth is a sum.
pub fn advertisedBytes(endpoint: types.Endpoint) usize {
    _ = endpoint;
    var n: usize = 0;
    for (tool_defs) |t| n += t.name.len + t.description.len + t.parameters.len;
    return n;
}

const tool_defs = [_]ToolDef{
    .{ .name = "read", .description = "Read a workspace file as numbered lines. `offset` (1-based line) and `limit` page through a long file; the numbers are a display gutter, never part of edit strings", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"path\"]}" },
    .{ .name = "write", .description = "Create a new workspace file. Prefer patch for existing files", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"contents\":{\"type\":\"string\"}},\"required\":[\"path\",\"contents\"]}" },
    .{ .name = "edit", .description = "Edit one file. Either one unique old_string/new_string, or `edits`: an array of {old_string,new_string} applied in order, all-or-nothing, each seeing the previous result. Or splice a named symbol (action before|after|inside|replace|delete) without breaking braces", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"},\"edits\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"}},\"required\":[\"old_string\",\"new_string\"]}},\"symbol\":{\"type\":\"string\"},\"action\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
    .{ .name = "bash", .description = "Run a shell command in the workspace. `timeout` is seconds to wait (default 120, max 600) -- raise it for a slow build rather than letting it be cut off. `background: true` starts it detached and returns at once; dev servers and watchers do that by default. A detached command streams to .omfx/jobs/<id>.log and is polled with the job tool", .parameters = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"timeout\":{\"type\":\"integer\"},\"background\":{\"type\":\"boolean\"}},\"required\":[\"command\"]}" },
    .{ .name = "job", .description = "Check a background command: status plus the tail of its output. `kill: true` stops it", .parameters = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"},\"kill\":{\"type\":\"boolean\"}},\"required\":[\"id\"]}" },
    .{ .name = "glob", .description = "Find workspace files by glob, recursively. `*` and `?` stay inside one path segment, `**` spans them; a pattern with no `/` matches the basename. `path` roots the search", .parameters = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}}}" },
    .{ .name = "grep", .description = "Search file contents for a literal string, recursively. Returns path:line: text. `glob` filters filenames, `path` roots the search", .parameters = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"glob\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}" },
    .{ .name = "list", .description = "List one directory level", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}" },
    .{ .name = "copy", .description = "Copy a file", .parameters = "{\"type\":\"object\",\"properties\":{\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"}},\"required\":[\"from\",\"to\"]}" },
    .{ .name = "mkdir", .description = "Create a directory", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
    .{ .name = "delete", .description = "Delete a file or empty directory", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
    .{ .name = "rename", .description = "Rename or move a file", .parameters = "{\"type\":\"object\",\"properties\":{\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"}},\"required\":[\"from\",\"to\"]}" },
    .{ .name = "file_info", .description = "File or directory metadata", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
    .{ .name = "open_file", .description = "Open a local file in the OS default app", .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
    .{ .name = "semantic_search", .description = "Hybrid repo search: reference rank, symbols, and tokens (no embeddings)", .parameters = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}" },
    .{ .name = "web_fetch", .description = "Fetch text from a public HTTP URL", .parameters = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]}" },
    .{ .name = "web_search", .description = "Search the web using the user fallback providers", .parameters = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}" },
    .{ .name = "ask_user", .description = "Ask the user a question", .parameters = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"}},\"required\":[\"question\"]}" },
    .{ .name = "memory", .description = "Save, list, or clear durable user preferences", .parameters = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"fact\":{\"type\":\"string\"}},\"required\":[\"action\"]}" },
    .{ .name = "browser", .description = "Drive existing Chrome tabs through the omfx browser-relay (list|eval|navigate|create)", .parameters = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"tabId\":{\"type\":\"string\"},\"expression\":{\"type\":\"string\"},\"url\":{\"type\":\"string\"}}}" },
    .{ .name = "peer", .description = "Spawn a full-capability teammate. Same tools as you. Isolated thread. Communicate via board (FACT/FAIL/PATH). Do not nest peers. The user can also type /peers <goal>.", .parameters = "{\"type\":\"object\",\"properties\":{\"goal\":{\"type\":\"string\"}},\"required\":[\"goal\"]}" },
    .{ .name = "board", .description = "Shared verified notes. action read|post. post line: FACT path=rel/path claim | FAIL hypothesis | PATH path=rel/path why.", .parameters = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"line\":{\"type\":\"string\"}}}" },
    .{ .name = "mcp", .description = "MCP client. action list|call. call needs name (server/tool) and optional arguments JSON object.", .parameters = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"arguments\":{\"type\":\"string\"}}}" },
    .{ .name = "todo", .description = "Show the user your task list for this request. Send the whole list every time: `todos` is an array of {content, status} where status is pending, in_progress, or completed. Keep exactly one task in_progress. Use it for multi-step work, never for a single obvious step", .parameters = "{\"type\":\"object\",\"properties\":{\"todos\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"completed\"]}},\"required\":[\"content\",\"status\"]}}},\"required\":[\"todos\"]}" },
    .{ .name = "patch", .description = "Apply unique file hunks. *** Update File: path then old text, *** To, then new text. Optional *** Hash: 8 hex chars of the old text.", .parameters = "{\"type\":\"object\",\"properties\":{\"patch\":{\"type\":\"string\"}},\"required\":[\"patch\"]}" },
    .{ .name = "compact", .description = "Drop older turns now. Fire when a sub-task resolved or you are looping; never mid-derivation. Local cites, never an LLM summary, never encrypt.", .parameters = "{\"type\":\"object\",\"properties\":{}}" },
};

const ToolShape = enum { chat, responses };

const activity_field =
    \\"activity":{"type":"string","description":"Few words naming what this call is doing now"}
;

/// Every tool spends a few tokens on `activity` so the status line is the
/// model's words, not a harness verb table.
fn injectActivityParam(allocator: std.mem.Allocator, parameters: []const u8) ![]u8 {
    const props_open = "\"properties\":{";
    const start = std.mem.indexOf(u8, parameters, props_open) orelse return allocator.dupe(u8, parameters);
    const inner_at = start + props_open.len;

    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);
    try tmp.appendSlice(allocator, parameters[0..inner_at]);
    try tmp.appendSlice(allocator, activity_field);
    if (inner_at < parameters.len) {
        if (parameters[inner_at] != '}') try tmp.append(allocator, ',');
    }
    try tmp.appendSlice(allocator, parameters[inner_at..]);

    const req_open = "\"required\":[";
    // Last match: `edit` nests a required array on each hunk.
    if (std.mem.lastIndexOf(u8, tmp.items, req_open)) |r| {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, tmp.items[0 .. r + req_open.len]);
        try out.appendSlice(allocator, "\"activity\",");
        try out.appendSlice(allocator, tmp.items[r + req_open.len ..]);
        return out.toOwnedSlice(allocator);
    }
    const last = std.mem.lastIndexOfScalar(u8, tmp.items, '}') orelse return tmp.toOwnedSlice(allocator);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, tmp.items[0..last]);
    try out.appendSlice(allocator, ",\"required\":[\"activity\"]");
    try out.appendSlice(allocator, tmp.items[last..]);
    return out.toOwnedSlice(allocator);
}

fn toolsJson(allocator: std.mem.Allocator, allow_peer: bool, shape: ToolShape) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (tool_defs) |d| {
        if (!allow_peer and std.mem.eql(u8, d.name, "peer")) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        const params = try injectActivityParam(allocator, d.parameters);
        defer allocator.free(params);
        switch (shape) {
            .chat => {
                try out.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
                try out.appendSlice(allocator, d.name);
                try out.appendSlice(allocator, "\",\"description\":\"");
                try out.appendSlice(allocator, d.description);
                try out.appendSlice(allocator, "\",\"parameters\":");
                try out.appendSlice(allocator, params);
                try out.appendSlice(allocator, "}}");
            },
            .responses => {
                try out.appendSlice(allocator, "{\"type\":\"function\",\"name\":\"");
                try out.appendSlice(allocator, d.name);
                try out.appendSlice(allocator, "\",\"description\":\"");
                try out.appendSlice(allocator, d.description);
                try out.appendSlice(allocator, "\",\"parameters\":");
                try out.appendSlice(allocator, params);
                try out.append(allocator, '}');
            },
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn buildAnthropicBody(allocator: std.mem.Allocator, model: []const u8, user: []const u8, system: []const u8) ![]u8 {
    return buildAnthropicBodyEx(allocator, .{
        .vendor = .anthropic,
        .protocol = .anthropic,
        .base_url = "",
        .api_key = "",
        .model = model,
    }, user, system);
}

pub fn buildAnthropicBodyEx(allocator: std.mem.Allocator, endpoint: types.Endpoint, user: []const u8, system: []const u8) ![]u8 {
    const msgs = [_]Message{.{ .role = "user", .content = user }};
    return buildAnthropicBodyMsgs(allocator, endpoint, &msgs, system);
}

/// Anthropic caching is opt-in: without this field nothing is cached, and the
/// whole conversation is reprocessed on every turn.
///
/// The top-level form asks the API to place the breakpoint on the last
/// cacheable block and move it forward as the thread grows, which is exactly
/// what an append-only conversation wants and needs no bookkeeping here.
///
/// A subscription is billed by usage rather than per token, so the hour-long
/// TTL costs nothing extra and carries the cache across a coffee break; an API
/// key pays 2x for the write, so it keeps the cheaper five minutes.
fn anthropicCacheJson(api_key: []const u8) []const u8 {
    const subscription = std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
    return if (subscription)
        "\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"},"
    else
        "\"cache_control\":{\"type\":\"ephemeral\"},";
}

pub fn buildAnthropicBodyMsgs(
    allocator: std.mem.Allocator,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
) std.mem.Allocator.Error![]u8 {
    const esc_model = try jsonEscape(allocator, endpoint.model);
    defer allocator.free(esc_model);
    const esc_sys = try jsonEscape(allocator, system);
    defer allocator.free(esc_sys);
    const extra = try limitAndEffortJson(allocator, endpoint, "max_tokens");
    defer allocator.free(extra);
    const msgs_json = try encodeMessages(allocator, messages, .anthropic);
    defer allocator.free(msgs_json);
    return std.fmt.allocPrint(allocator,
        \\{{"model":"{s}",{s}{s}"stream":true,"system":"{s}","messages":{s}}}
    , .{ esc_model, extra, anthropicCacheJson(endpoint.api_key), esc_sys, msgs_json });
}

pub fn buildResponsesBody(allocator: std.mem.Allocator, model: []const u8, user: []const u8, system: []const u8) ![]u8 {
    return buildResponsesBodyEx(allocator, .{
        .vendor = .openai,
        .protocol = .openai_responses,
        .base_url = "",
        .api_key = "",
        .model = model,
    }, user, system);
}

pub fn buildResponsesBodyEx(allocator: std.mem.Allocator, endpoint: types.Endpoint, user: []const u8, system: []const u8) ![]u8 {
    const msgs = [_]Message{.{ .role = "user", .content = user }};
    return buildResponsesBodyMsgs(allocator, endpoint, &msgs, system);
}

pub fn buildResponsesBodyMsgs(
    allocator: std.mem.Allocator,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
) ![]u8 {
    return buildResponsesBodyFlags(allocator, endpoint, messages, system, .{});
}

fn buildResponsesBodyFlags(
    allocator: std.mem.Allocator,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
    flags: ChatFlags,
) std.mem.Allocator.Error![]u8 {
    const esc_model = try jsonEscape(allocator, endpoint.model);
    defer allocator.free(esc_model);
    const esc_sys = try jsonEscape(allocator, system);
    defer allocator.free(esc_sys);
    const extra = try limitAndEffortJson(allocator, endpoint, "max_output_tokens");
    defer allocator.free(extra);
    const tools = if (flags.tools) try toolsJson(allocator, flags.allow_peer, .responses) else try allocator.dupe(u8, "[]");
    defer allocator.free(tools);
    const msgs_json = try encodeMessages(allocator, messages, .openai_responses);
    defer allocator.free(msgs_json);
    const cache = try cacheJson(allocator, endpoint, flags);
    defer allocator.free(cache);
    return std.fmt.allocPrint(allocator,
        \\{{"model":"{s}",{s}{s}"stream":true,"instructions":"{s}","input":{s},"tools":{s}}}
    , .{ esc_model, extra, cache, esc_sys, msgs_json, tools });
}

pub fn collectOutputText(body: []const u8) []const u8 {
    return sse.lastTypeText(body, "output_text");
}

pub fn collectText(protocol: types.Protocol, body: []const u8) []const u8 {
    return sse.extract(protocol, body).text;
}

pub fn collectThink(protocol: types.Protocol, body: []const u8) []const u8 {
    return sse.extract(protocol, body).think;
}

pub const max_calls: usize = 8;

pub const CallHit = struct { name: tool.Name, args: []const u8 };

pub fn collectCalls(body: []const u8, out: *[max_calls]CallHit) usize {
    const needle = "\"type\":\"function_call\"";
    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len and n < out.len) {
        const rest = body[i..];
        const at = std.mem.indexOf(u8, rest, needle) orelse break;
        const from = rest[at..];
        const name = sse.jsonString(from, "name") orelse {
            i += at + needle.len;
            continue;
        };
        const parsed = tool.Name.fromSlice(name) orelse {
            i += at + needle.len;
            continue;
        };
        const args = sse.jsonString(from, "arguments") orelse sse.jsonString(from, "input") orelse "";
        if (args.len == 0) {
            i += at + needle.len;
            continue;
        }
        out[n] = .{ .name = parsed, .args = args };
        n += 1;
        i += at + needle.len;
    }
    return n;
}

pub fn collectTool(body: []const u8) ?CallHit {
    var buf: [max_calls]CallHit = undefined;
    const n = collectCalls(body, &buf);
    if (n == 0) return null;
    return buf[0];
}

const Extra = struct {
    buf: [12]std.http.Header = undefined,
    len: usize = 0,

    fn add(self: *Extra, name: []const u8, value: []const u8) void {
        std.debug.assert(name.len != 0);
        std.debug.assert(!reservedHeader(name));
        self.buf[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    fn slice(self: *const Extra) []const std.http.Header {
        return self.buf[0..self.len];
    }
};

fn reservedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "host");
}

const Seen = packed struct {
    text: bool = false,
    think: bool = false,
};

/// Receipt: the largest live response recorded under docs/research is 38.7 KB.
/// 16 MB is four hundred times that -- a tripwire for a stream that has stopped
/// ending, not a budget any real reply can reach.
pub const max_response_bytes: usize = 16 << 20;

const HostWriter = struct {
    /// Running token totals for this request.
    usage: sse.Usage = .{},
    writer: std.Io.Writer,
    allocator: std.mem.Allocator,
    body: std.ArrayList(u8),
    line: std.ArrayList(u8),
    answer: std.ArrayList(u8),
    host: types.Stream,
    proto: types.Protocol,
    seen: Seen,
    /// Set when the response passed `max_response_bytes`. Sticky: a retry
    /// cannot make an endless stream end.
    overflow: bool = false,

    fn init(allocator: std.mem.Allocator, host: types.Stream, proto: types.Protocol) HostWriter {
        return .{
            .writer = .{ .vtable = &vtable, .buffer = &.{} },
            .allocator = allocator,
            .body = .empty,
            .line = .empty,
            .answer = .empty,
            .host = host,
            .proto = proto,
            .seen = .{},
        };
    }

    fn reset(self: *HostWriter) void {
        self.body.clearRetainingCapacity();
        self.line.clearRetainingCapacity();
        self.answer.clearRetainingCapacity();
        self.seen = .{};
    }

    fn emitPlain(self: *HostWriter, channel: types.Channel, raw: []const u8) error{WriteFailed}!void {
        const plain = sse.unescapeAlloc(self.allocator, raw) catch {
            try self.note(channel, raw);
            return;
        };
        defer self.allocator.free(plain);
        try self.note(channel, plain);
    }

    fn note(self: *HostWriter, channel: types.Channel, chunk: []const u8) error{WriteFailed}!void {
        if (chunk.len == 0) {
            self.host.push(channel, chunk);
            return;
        }
        switch (channel) {
            .text => {
                self.answer.appendSlice(self.allocator, chunk) catch return error.WriteFailed;
                self.seen.text = true;
            },
            .think => self.seen.think = true,
        }
        self.host.push(channel, chunk);
    }

    fn forward(self: *HostWriter, parsed: sse.Parsed) error{WriteFailed}!void {
        switch (parsed) {
            .text => |chunk| try self.emitPlain(.text, chunk),
            .think => |chunk| try self.emitPlain(.think, chunk),
            // Counts are reported as they arrive so the status line can show a
            // running total rather than one number at the end of the turn.
            .usage => |u| {
                self.usage.merge(u);
                self.host.usage(self.usage.input, self.usage.output, self.usage.cache_read, self.usage.cache_write);
            },
            .tool_call, .done, .ignore => {},
        }
    }

    fn deinit(self: *HostWriter) void {
        self.body.deinit(self.allocator);
        self.line.deinit(self.allocator);
        self.answer.deinit(self.allocator);
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.noopFlush,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *HostWriter = @alignCast(@fieldParentPtr("writer", w));
        // Failing the write is what actually tears down the HTTP read. Setting
        // the flag alone just lets the model finish talking to a closed ear.
        if (self.host.cancelled()) return error.WriteFailed;
        if (data.len == 0) return 0;
        const start = self.body.items.len;
        const pattern = data[data.len - 1];
        for (data) |bytes| {
            self.body.appendSlice(self.allocator, bytes) catch return error.WriteFailed;
            // Failing the write is what tears down the HTTP read, so this is
            // also how a stream that never ends is stopped before it is memory.
            if (self.body.items.len > max_response_bytes) {
                self.overflow = true;
                return error.WriteFailed;
            }
            try self.ingest(bytes);
        }
        if (splat == 0) {
            if (self.body.items.len >= pattern.len)
                self.body.shrinkRetainingCapacity(self.body.items.len - pattern.len);
        } else if (splat > 1) {
            var i: usize = 0;
            while (i < splat - 1) : (i += 1) {
                self.body.appendSlice(self.allocator, pattern) catch return error.WriteFailed;
                try self.ingest(pattern);
            }
        }
        return self.body.items.len - start;
    }

    fn ingest(self: *HostWriter, chunk: []const u8) error{WriteFailed}!void {
        for (chunk) |c| {
            if (c == '\n') {
                try self.flushLine();
            } else {
                self.line.append(self.allocator, c) catch return error.WriteFailed;
            }
        }
    }

    fn flushLine(self: *HostWriter) error{WriteFailed}!void {
        try self.forward(sse.parseData(self.proto, sse.dataLine(self.line.items)));
        self.host.pollCancel();
        self.line.clearRetainingCapacity();
    }
};

pub fn shouldRetry(status: u16, attempt: u8) bool {
    return status == 429 and attempt == 0;
}

pub fn postChat(
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: types.Endpoint,
    user: []const u8,
    system: []const u8,
) PostError!ChatResult {
    const msgs = [_]Message{.{ .role = "user", .content = user }};
    return postChatMsgs(allocator, io, endpoint, &msgs, system);
}

pub fn postChatMsgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
) PostError!ChatResult {
    return postChatFiltered(allocator, io, endpoint, messages, system, .{});
}

pub fn postChatFiltered(
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: types.Endpoint,
    messages: []const Message,
    system: []const u8,
    flags: ChatFlags,
) PostError!ChatResult {
    const url = try chatCompletionsUrl(allocator, endpoint);
    defer allocator.free(url);
    const proto = wireProtocol(endpoint);
    const body = try switch (proto) {
        .openai_compat => buildOpenAiBodyFlags(allocator, endpoint, messages, system, flags),
        .anthropic => buildAnthropicBodyMsgs(allocator, endpoint, messages, system),
        .openai_responses => buildResponsesBodyFlags(allocator, endpoint, messages, system, flags),
    };
    defer allocator.free(body);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{endpoint.api_key});
    defer allocator.free(bearer);

    var tee = HostWriter.init(allocator, flags.host, proto);
    defer tee.deinit();

    var extra = Extra{};
    extra.add("Accept", "application/json");

    const oat = std.mem.indexOf(u8, endpoint.api_key, "sk-ant-oat") != null;
    var headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = "application/json" },
        .authorization = .{ .override = bearer },
    };

    if (proto == .anthropic and !oat) {
        headers.authorization = .omit;
        extra.add("x-api-key", endpoint.api_key);
        extra.add("anthropic-version", "2023-06-01");
    } else if (proto == .anthropic and oat) {
        extra.add("anthropic-version", "2023-06-01");
        extra.add("anthropic-beta", "oauth-2025-04-20");
    }

    // Attribution only: `http-referer` and `x-title` put the user on
    // OpenRouter's public app leaderboard, and `x-grok-conv-id` tags the
    // request. Neither changes the reply, so neither is sent unless asked for.
    if (flags.telemetry) {
        if (std.mem.eql(u8, endpoint.id, "openrouter") or std.mem.eql(u8, endpoint.id, "kilo")) {
            extra.add("http-referer", "https://github.com/omfx");
            extra.add("x-title", "Oh My Fx");
        }
        if (endpoint.vendor == .xai) extra.add("x-grok-conv-id", "omfx");
    }
    if (std.mem.eql(u8, endpoint.id, "github-copilot")) {
        // Copilot rejects a request with no user-agent at all.
        extra.add("user-agent", "omfx/0.0.1");
        extra.add("x-github-api-version", "2026-06-01");
    }
    if (std.mem.eql(u8, endpoint.id, "openai-codex") or std.mem.eql(u8, endpoint.id, "openai-codex-device")) {
        // The Codex backend gates on both of these; without them the ChatGPT
        // login route returns 400.
        extra.add("openai-beta", "responses=experimental");
        extra.add("originator", "omfx");
    }

    var attempt: u8 = 0;
    var result: std.http.Client.FetchResult = undefined;
    while (true) {
        result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = headers,
            .extra_headers = extra.slice(),
            .response_writer = &tee.writer,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const msg = try std.fmt.allocPrint(allocator, "transport error: {s}", .{@errorName(err)});
                return .{ .status = 0, .outcome = .{ .text = msg } };
            },
        };
        const try_status: u16 = @intFromEnum(result.status);
        if (!shouldRetry(try_status, attempt)) break;
        attempt += 1;
        tee.reset();
    }

    const raw = tee.body.items;
    const status: u16 = @intFromEnum(result.status);
    if (tee.overflow) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s} response passed max_response_bytes={d}; stopped reading, not a clean verdict",
            .{ endpoint.vendor.asSlice(), max_response_bytes },
        );
        return .{ .status = status, .outcome = .{ .text = msg } };
    }
    if (status == 429) {
        const msg = try std.fmt.allocPrint(allocator, "{s} http 429: retry once exhausted; not a clean verdict", .{endpoint.vendor.asSlice()});
        return .{ .status = status, .outcome = .{ .text = msg } };
    }
    if (status == 401 or status == 403 or isBadKeyBody(status, raw)) {
        const msg = try std.fmt.allocPrint(allocator, "{s}", .{authErrorMessage(endpoint.vendor, status)});
        return .{ .status = status, .outcome = .{ .text = msg } };
    }
    if (status < 200 or status >= 300) {
        const snippet = raw[0..@min(raw.len, 240)];
        const msg = try std.fmt.allocPrint(allocator, "{s} http {d}: {s}", .{ endpoint.vendor.asSlice(), status, snippet });
        return .{ .status = status, .outcome = .{ .text = msg } };
    }

    const extracted = sse.extract(proto, raw);
    const extracted_text = if (extracted.text.len > 0)
        try sse.unescapeAlloc(allocator, extracted.text)
    else
        "";
    defer if (extracted_text.len > 0) allocator.free(extracted_text);
    const extracted_think = if (extracted.think.len > 0)
        try sse.unescapeAlloc(allocator, extracted.think)
    else
        "";
    defer if (extracted_think.len > 0) allocator.free(extracted_think);
    const text_src: []const u8 = if (tee.answer.items.len > 0)
        tee.answer.items
    else if (extracted_text.len > 0)
        extracted_text
    else if (!tee.seen.text)
        raw[0..@min(raw.len, 2000)]
    else
        "";
    const text = try allocator.dupe(u8, text_src);
    if (!tee.seen.think and extracted_think.len > 0) flags.host.think(extracted_think);
    if (!tee.seen.text and extracted_text.len > 0) flags.host.text(extracted_text);
    var calls: [max_calls]CallHit = undefined;
    const n_calls = collectCalls(raw, &calls);
    if (n_calls > 0) {
        errdefer allocator.free(text);
        var more: []ExtraCall = &.{};
        if (n_calls > 1) {
            more = try allocator.alloc(ExtraCall, n_calls - 1);
            var i: usize = 0;
            errdefer {
                for (more[0..i]) |e| {
                    allocator.free(e.name);
                    allocator.free(e.args);
                }
                allocator.free(more);
            }
            while (i < n_calls - 1) : (i += 1) {
                more[i] = .{
                    .name = try allocator.dupe(u8, calls[i + 1].name.asSlice()),
                    .args = try sse.unescapeAlloc(allocator, calls[i + 1].args),
                };
            }
        }
        return .{
            .status = status,
            .outcome = .{ .tool = .{
                .preamble = text,
                .name = try allocator.dupe(u8, calls[0].name.asSlice()),
                .args = try sse.unescapeAlloc(allocator, calls[0].args),
            } },
            .extra = more,
        };
    }
    return .{ .status = status, .outcome = .{ .text = text } };
}

test "retry only the first 429" {
    try std.testing.expect(shouldRetry(429, 0));
    try std.testing.expect(!shouldRetry(429, 1));
    try std.testing.expect(!shouldRetry(500, 0));
}

test "json escape quotes" {
    const s = try jsonEscape(std.testing.allocator, "a\"b");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a\\\"b", s);
}

test "collect openai text from sse" {
    const body =
        \\data: {"choices":[{"delta":{"content":"hi"}}]}
        \\
        \\data: [DONE]
        \\
    ;
    try std.testing.expectEqualStrings("hi", collectText(.openai_compat, body));
}

test "collectOutputText skips reasoning summary" {
    const body =
        \\{"output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"The user said ping"}]},{"type":"message","content":[{"type":"output_text","text":"pong"}]}]}
    ;
    try std.testing.expectEqualStrings("pong", collectOutputText(body));
    try std.testing.expectEqualStrings("pong", collectText(.openai_responses, body));
    try std.testing.expectEqualStrings("The user said ping", collectThink(.openai_responses, body));
}

test "collectThink reads reasoning_summary_text deltas" {
    const body =
        \\data: {"type":"response.reasoning_summary_text.delta","delta":"plan"}
        \\
        \\data: {"type":"response.output_text.delta","delta":"pong"}
        \\
    ;
    try std.testing.expectEqualStrings("pong", collectText(.openai_responses, body));
    try std.testing.expectEqualStrings("plan", collectThink(.openai_responses, body));
}

test "collectCalls finds two reads" {
    const body =
        \\{"output":[{"type":"function_call","name":"read","arguments":"{\"path\":\"a.zig\"}"},{"type":"function_call","name":"grep","arguments":"{\"pattern\":\"fn\"}"}]}
    ;
    var buf: [max_calls]CallHit = undefined;
    const n = collectCalls(body, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(tool.Name.read, buf[0].name);
    try std.testing.expectEqual(tool.Name.grep, buf[1].name);
}

test "collectCalls skips empty arguments stub" {
    const body =
        \\{"output":[{"type":"function_call","name":"write","arguments":""},{"type":"function_call","name":"write","arguments":"{\"path\":\"a.txt\",\"contents\":\"hi\"}"}]}
    ;
    var buf: [max_calls]CallHit = undefined;
    const n = collectCalls(body, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(tool.Name.write, buf[0].name);
    const args = try sse.unescapeAlloc(std.testing.allocator, buf[0].args);
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings("a.txt", sse.jsonString(args, "path").?);
}

test "omit full-window output limits" {
    try std.testing.expectEqual(@as(?u32, 32_000), requestMaxOutputTokens(32_000, 256_000));
    try std.testing.expectEqual(@as(?u32, null), requestMaxOutputTokens(1_048_576, 1_048_576));
    try std.testing.expectEqual(@as(?u32, null), requestMaxOutputTokens(256_000, 128_000));
    try std.testing.expectEqual(@as(?u32, 1024), requestMaxOutputTokens(1024, 0));
}

test "bench: tools json and grok-4.5 request body sizes" {
    const a = std.testing.allocator;
    const tools = try toolsJson(a, true, .chat);
    defer a.free(tools);
    const tools_no_peer = try toolsJson(a, false, .chat);
    defer a.free(tools_no_peer);
    const tools_resp = try toolsJson(a, true, .responses);
    defer a.free(tools_resp);
    const sys = "You are omfx, a small coding agent.\n";
    const resp = try buildResponsesBodyEx(a, .{
        .vendor = .xai,
        .protocol = .openai_responses,
        .base_url = "",
        .api_key = "",
        .model = "grok-4.5",
        .effort = "low",
        .context_window = 500_000,
        .max_output_tokens = 500_000,
    }, "ping", sys);
    defer a.free(resp);
    const openai = try buildOpenAiBodyFlags(a, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-4o-mini",
        .effort = "low",
    }, &.{.{ .role = "user", .content = "ping" }}, sys, .{});
    defer a.free(openai);
    std.debug.print(
        "BENCH tools_json_bytes={d} tools_no_peer_bytes={d} tools_responses_bytes={d} responses_body_bytes={d} openai_body_bytes={d} responses_has_tools={d} responses_has_effort={d}\n",
        .{
            tools.len,
            tools_no_peer.len,
            tools_resp.len,
            resp.len,
            openai.len,
            @intFromBool(std.mem.indexOf(u8, resp, "\"tools\"") != null),
            @intFromBool(std.mem.indexOf(u8, resp, "reasoning_effort") != null),
        },
    );
    try std.testing.expect(tools.len > 1_000);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"function\":{\"name\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "reasoning_effort") != null);
}

test "collectCalls ignores tool schema echo" {
    const body =
        \\{"tools":[{"type":"function","name":"read","description":"Read a workspace file","parameters":{"type":"object"}}]}
    ;
    var buf: [max_calls]CallHit = undefined;
    try std.testing.expectEqual(@as(usize, 0), collectCalls(body, &buf));
}

test "every tool asks the model for an activity phrase" {
    const tools = try toolsJson(std.testing.allocator, true, .responses);
    defer std.testing.allocator.free(tools);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"activity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "Few words naming what this call is doing now") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"required\":[\"activity\"") != null);
}

test "responses tools are flat not nested" {
    const tools = try toolsJson(std.testing.allocator, true, .responses);
    defer std.testing.allocator.free(tools);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"name\":\"grep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"function\":{\"name\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"type\":\"function\"") != null);
}

test "openai body has advertised tools only" {
    const body = try buildOpenAiBody(std.testing.allocator, "gpt-4o-mini", "hi", "sys");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"edit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"symbol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"browser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"peer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"board\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"mcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"activate_tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"module_report\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"terminal\"") == null);
}

test "openai body omits peer when banned" {
    const body = try buildOpenAiBodyFiltered(std.testing.allocator, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-4o-mini",
    }, &.{.{ .role = "user", .content = "hi" }}, "sys", false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"peer\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"board\"") != null);
}

test "openai body attaches image_url when the prompt has an image" {
    const img = types.Image{ .file = .{ .mime = .png, .b64 = "QQ==" } };
    const body = try buildOpenAiBodyMsgs(std.testing.allocator, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-4o-mini",
    }, &.{.{ .role = "user", .content = "look", .images = &.{img} }}, "sys");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/png;base64,QQ==") != null);
}

test "openai body passes image urls through" {
    const img: types.Image = .{ .url = "https://ex.com/a.png" };
    const body = try buildOpenAiBodyMsgs(std.testing.allocator, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-4o-mini",
    }, &.{.{ .role = "user", .content = "look", .images = &.{img} }}, "sys");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "https://ex.com/a.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "base64") == null);
}

test "anthropic body uses base64 image source" {
    const img = types.Image{ .file = .{ .mime = .png, .b64 = "QQ==" } };
    const body = try buildAnthropicBodyMsgs(std.testing.allocator, .{
        .vendor = .anthropic,
        .protocol = .anthropic,
        .base_url = "",
        .api_key = "",
        .model = "claude",
    }, &.{.{ .role = "user", .content = "look", .images = &.{img} }}, "sys");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
}

test "openai body can send no tools" {
    const body = try buildOpenAiBodyFlags(std.testing.allocator, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-4o-mini",
    }, &.{.{ .role = "user", .content = "hi" }}, "sys", .{ .tools = false });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"peer\"") == null);
}

test "effort does not replace model" {
    const body = try buildOpenAiBodyEx(std.testing.allocator, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-4o-mini",
        .effort = "low",
    }, "hi", "sys");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o-mini\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"low\"") != null);
}

test "openai thread keeps original user and follow-up" {
    const msgs = [_]Message{
        .{ .role = "user", .content = "original-prompt" },
        .{ .role = "assistant", .content = "calling read" },
        .{ .role = "user", .content = "Tool read result" },
    };
    const body = try buildOpenAiBodyMsgs(std.testing.allocator, .{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "gpt-4o-mini",
    }, &msgs, "sys");
    defer std.testing.allocator.free(body);
    const orig = std.mem.indexOf(u8, body, "original-prompt") orelse {
        try std.testing.expect(false);
        return;
    };
    const follow = std.mem.indexOf(u8, body, "Tool read result") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(orig < follow);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
}

test "anthropic thread has no system role in messages" {
    const msgs = [_]Message{
        .{ .role = "user", .content = "original-prompt" },
        .{ .role = "assistant", .content = "calling read" },
        .{ .role = "user", .content = "Tool read result" },
    };
    const body = try buildAnthropicBodyMsgs(std.testing.allocator, .{
        .vendor = .anthropic,
        .protocol = .anthropic,
        .base_url = "",
        .api_key = "",
        .model = "claude-sonnet-4-5",
    }, &msgs, "sys");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "original-prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Tool read result") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"sys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") == null);
}

test "openai compat url" {
    const ep = types.Endpoint{
        .vendor = .openai,
        .base_url = "https://api.openai.com/v1",
        .api_key = "k",
        .model = "gpt-4.1",
    };
    const url = try chatCompletionsUrl(std.testing.allocator, ep);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", url);
}

test "anthropic url" {
    const ep = types.Endpoint{
        .vendor = .anthropic,
        .protocol = .anthropic,
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
        .model = "claude-sonnet-4-5",
    };
    const url = try chatCompletionsUrl(std.testing.allocator, ep);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "openai responses url" {
    const ep = types.Endpoint{
        .vendor = .openai,
        .protocol = .openai_responses,
        .base_url = "https://api.openai.com/v1",
        .api_key = "k",
        .model = "gpt-5",
    };
    const url = try chatCompletionsUrl(std.testing.allocator, ep);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", url);
}

test "auth error names the vendor" {
    try std.testing.expect(std.mem.indexOf(u8, authErrorMessage(.xai, 400), "omfx login xai-oauth") != null);
    try std.testing.expect(std.mem.indexOf(u8, authErrorMessage(.anthropic, 401), "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, authErrorMessage(.openai, 401), "openai") != null);
    try std.testing.expect(std.mem.indexOf(u8, authErrorMessage(.openai, 401), "gateway") == null);
    try std.testing.expect(isAuthFailure(authErrorMessage(.xai, 400)));
    try std.testing.expect(isAuthFailure(authErrorMessage(.openai, 401)));
    try std.testing.expect(!isAuthFailure("hello"));
}

test "extra headers omit std Request.Headers names" {
    try std.testing.expect(reservedHeader("Content-Type"));
    try std.testing.expect(reservedHeader("authorization"));
    try std.testing.expect(!reservedHeader("Accept"));
    try std.testing.expect(!reservedHeader("x-grok-conv-id"));
}

test "chatgpt backend path is backend-api/codex/responses" {
    const ep = types.Endpoint{
        .id = "openai-codex",
        .vendor = .openai,
        .protocol = .openai_responses,
        .base_url = "https://chatgpt.com/backend-api",
        .api_key = "k",
        .model = "gpt-5.5",
        .path = "/codex/responses",
    };
    const url = try chatCompletionsUrl(std.testing.allocator, ep);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", url);
}

test "anthropic requests ask for caching, which is opt-in" {
    const a = std.testing.allocator;
    // An API key pays per token, so the cheap five-minute window.
    const keyed = try buildAnthropicBodyMsgs(a, .{
        .vendor = .anthropic,
        .protocol = .anthropic,
        .base_url = "",
        .api_key = "sk-ant-api03-xxx",
        .model = "claude-opus-5",
    }, &.{.{ .role = "user", .content = "hi" }}, "sys");
    defer a.free(keyed);
    try std.testing.expect(std.mem.indexOf(u8, keyed, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, keyed, "1h") == null);

    // A subscription is billed by usage, so the longer window is free.
    const oauth = try buildAnthropicBodyMsgs(a, .{
        .vendor = .anthropic,
        .protocol = .anthropic,
        .base_url = "",
        .api_key = "sk-ant-oat01-xxx",
        .model = "claude-opus-5",
    }, &.{.{ .role = "user", .content = "hi" }}, "sys");
    defer a.free(oauth);
    try std.testing.expect(std.mem.indexOf(u8, oauth, "\"ttl\":\"1h\"") != null);
}

test "a cache key rides along, and only openai is asked for long retention" {
    const a = std.testing.allocator;
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};

    const openai = try buildResponsesBodyFlags(a, .{
        .vendor = .openai,
        .id = "openai",
        .protocol = .openai_responses,
        .base_url = "",
        .api_key = "k",
        .model = "gpt-5.1-codex",
    }, &msgs, "sys", .{ .cache_key = "omfx-abc" });
    defer a.free(openai);
    try std.testing.expect(std.mem.indexOf(u8, openai, "\"prompt_cache_key\":\"omfx-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai, "\"prompt_cache_retention\":\"24h\"") != null);

    // A model that has never heard of the field would reject the request, so
    // it is never sent one.
    const other = try buildOpenAiBodyFlags(a, .{
        .vendor = .xai,
        .id = "xai",
        .protocol = .openai_compat,
        .base_url = "",
        .api_key = "k",
        .model = "grok-4.5",
    }, &msgs, "sys", .{ .cache_key = "omfx-abc" });
    defer a.free(other);
    try std.testing.expect(std.mem.indexOf(u8, other, "\"prompt_cache_key\":\"omfx-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "prompt_cache_retention") == null);
}

test "no cache key means no field, not an empty one" {
    const a = std.testing.allocator;
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const body = try buildOpenAiBodyFlags(a, .{
        .vendor = .xai,
        .id = "xai",
        .protocol = .openai_compat,
        .base_url = "",
        .api_key = "k",
        .model = "grok-4.5",
    }, &msgs, "sys", .{});
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "the same turn twice is the same bytes twice" {
    // Prompt caching matches an exact prefix, so anything nondeterministic in
    // the request -- map iteration order, a timestamp, a reordered tools array
    // -- costs a full reprocess on every turn rather than a visible bug.
    const a = std.testing.allocator;
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const ep = types.Endpoint{
        .vendor = .anthropic,
        .id = "anthropic",
        .protocol = .anthropic,
        .base_url = "",
        .api_key = "sk-ant-oat01-xxx",
        .model = "claude-opus-5",
    };
    const one = try buildAnthropicBodyMsgs(a, ep, &msgs, "sys");
    defer a.free(one);
    const two = try buildAnthropicBodyMsgs(a, ep, &msgs, "sys");
    defer a.free(two);
    try std.testing.expectEqualStrings(one, two);

    const t1 = try toolsJson(a, true, .chat);
    defer a.free(t1);
    const t2 = try toolsJson(a, true, .chat);
    defer a.free(t2);
    try std.testing.expectEqualStrings(t1, t2);
}

test "nothing names the client unless the user asked for it" {
    const a = std.testing.allocator;
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const ep = types.Endpoint{
        .vendor = .xai,
        .id = "openrouter",
        .protocol = .openai_compat,
        .base_url = "",
        .api_key = "k",
        .model = "grok-4.5",
    };
    // The body is the same either way; only the headers differ, and the
    // default path never adds them. Asserted here so a future edit that moves
    // an attribution header out of the `flags.telemetry` block is caught.
    const off = try buildOpenAiBodyFlags(a, ep, &msgs, "sys", .{});
    defer a.free(off);
    const on = try buildOpenAiBodyFlags(a, ep, &msgs, "sys", .{ .telemetry = true });
    defer a.free(on);
    try std.testing.expectEqualStrings(off, on);
    try std.testing.expect(!(ChatFlags{}).telemetry);
}
