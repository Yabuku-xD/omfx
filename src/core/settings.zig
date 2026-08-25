const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.settings);
const Io = std.Io;
const permissions = @import("permissions.zig");

pub const path_name = "settings.json";

pub fn path(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".omfx", path_name });
}

pub const max_ids: usize = 24;

pub const Toggle = enum {
    off,
    on,

    pub fn fromSlice(s: []const u8) Toggle {
        return if (std.mem.eql(u8, s, "on")) .on else .off;
    }

    pub fn asSlice(self: Toggle) []const u8 {
        return switch (self) {
            .on => "on",
            .off => "off",
        };
    }
};

pub const Web = struct {
    order: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    searxng_endpoint: []const u8 = "",
};

pub const max_rules: usize = 32;
/// Tripwire for a settings file that stopped being configuration.
pub const max_mcp: usize = 128;
pub const max_mcp_args: usize = 32;
pub const max_provider_models: usize = 24;

pub const McpServer = struct {
    name: []const u8 = "",
    command: []const u8 = "",
    /// Remote Streamable HTTP endpoint. When set, `command` is unused.
    url: []const u8 = "",
    argv: [max_mcp_args][]const u8 = undefined,
    argv_n: usize = 0,
};

pub const ProviderPref = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
};

pub const File = struct {
    raw: []u8 = &.{},
    web: Web = .{},
    rules: []const permissions.Rule = &.{},
    review: []const u8 = "",
    /// OS sandbox on bash. Empty or anything but `"on"` is off (opt-in).
    sandbox: []const u8 = "",
    cdp_port: []const u8 = "",
    sound: []const u8 = "",
    statusline: []const u8 = "",
    /// Where the status fields are drawn: "footer", "header", or "both".
    /// Empty means footer, which is what omfx has always done.
    statusline_place: []const u8 = "",
    /// Comma-separated field names, in order. Empty means the default set.
    statusline_fields: []const u8 = "",
    composer: []const u8 = "",
    thinking: Toggle = .off,
    /// Optional headers that name omfx to the provider: OpenRouter's public
    /// app leaderboard and xAI's conversation tag. Off unless asked for --
    /// they change nothing about the reply, and identifying the client is the
    /// user's call to make, not the default.
    telemetry: Toggle = .off,
    /// When on, the model may invoke the peer tool. Manual `/peers` always works.
    peer: Toggle = .off,
    git_auto: Toggle = .off,
    /// With git_auto: snapshot a dirty tree before the first AI edit.
    git_dirty: Toggle = .on,
    workspace_dirs: []const []const u8 = &.{},
    mcp: []const McpServer = &.{},
    max_peer_depth: u8 = 1,
    /// Reasoning level a new session starts on. Empty means `auto`, which
    /// picks per prompt; see `core/autoeffort.zig`.
    effort: []const u8 = "",
    /// Editor for ctrl-g. Empty follows $VISUAL then $EDITOR then vi.
    editor: []const u8 = "",
    /// Graphical IDE for `/ide open`. Empty means the first one found on PATH.
    ide: []const u8 = "",
    /// GitHub owner/repo or URL entries for `/plugin marketplace add`.
    plugin_marketplaces: []const []const u8 = &.{},
    /// Seconds a bash command may run. Zero means `deadline.default_secs`.
    bash_timeout: u32 = 0,
    /// Saved sessions kept on disk. Zero means keep every one.
    keep_sessions: u32 = 0,

    last_model: []const u8 = "",
    last_provider: []const u8 = "",
    last_mode: []const u8 = "",
    /// Preferred model per provider so switching providers does not clobber.
    provider_models: [max_provider_models]ProviderPref = [_]ProviderPref{.{}} ** max_provider_models,
    provider_models_n: usize = 0,

    pub fn providerModels(self: *const File) []const ProviderPref {
        return self.provider_models[0..self.provider_models_n];
    }

    pub fn deinit(self: *File, allocator: std.mem.Allocator) void {
        if (self.web.order.len > 0) allocator.free(self.web.order);
        if (self.web.exclude.len > 0) allocator.free(self.web.exclude);
        if (self.rules.len > 0) allocator.free(self.rules);
        if (self.workspace_dirs.len > 0) allocator.free(self.workspace_dirs);
        if (self.plugin_marketplaces.len > 0) allocator.free(self.plugin_marketplaces);
        if (self.raw.len > 0) {
            allocator.free(self.mcp);
            allocator.free(self.raw);
        } else if (self.mcp.len > 0) {
            allocator.free(self.mcp);
        }
        self.* = .{};
    }
};

fn extractArray(json: []const u8, key: []const u8, out: *[max_ids][]const u8) usize {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return 0;
    const start = std.mem.indexOf(u8, json, needle) orelse return 0;
    const rest = json[start..];
    const lb = std.mem.indexOfScalar(u8, rest, '[') orelse return 0;
    const rb = std.mem.indexOfScalar(u8, rest[lb..], ']') orelse return 0;
    const inner = rest[lb + 1 .. lb + rb];
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len and n < max_ids) {
        const q1 = std.mem.indexOfScalarPos(u8, inner, i, '"') orelse break;
        var q2 = q1 + 1;
        while (q2 < inner.len and inner[q2] != '"') : (q2 += 1) {}
        if (q2 >= inner.len) break;
        out[n] = inner[q1 + 1 .. q2];
        n += 1;
        i = q2 + 1;
    }
    return n;
}

fn extractString(json: []const u8, key: []const u8) []const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return "";
    const start = std.mem.indexOf(u8, json, needle) orelse return "";
    var i = start + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n')) i += 1;
    if (i >= json.len or json[i] != '"') return "";
    i += 1;
    const from = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') return json[from..i];
    }
    return "";
}

pub fn parse(allocator: std.mem.Allocator, json: []const u8) !File {
    const raw = try allocator.dupe(u8, json);
    errdefer allocator.free(raw);
    var order_store: [max_ids][]const u8 = undefined;
    var exclude_store: [max_ids][]const u8 = undefined;
    const order_n = extractArray(raw, "order", &order_store);
    const exclude_n = extractArray(raw, "exclude", &exclude_store);
    const order = try allocator.dupe([]const u8, order_store[0..order_n]);
    errdefer allocator.free(order);
    const exclude = try allocator.dupe([]const u8, exclude_store[0..exclude_n]);
    var rule_store: [max_rules]permissions.Rule = undefined;
    const rule_n = extractPermRules(raw, &rule_store);
    const rules = try allocator.dupe(permissions.Rule, rule_store[0..rule_n]);
    errdefer allocator.free(rules);
    const mcp = try extractMcp(allocator, raw);
    errdefer allocator.free(mcp);
    var dirs_store: [max_ids][]const u8 = undefined;
    const dirs_n = extractArray(raw, "workspace_dirs", &dirs_store);
    const workspace_dirs = try allocator.dupe([]const u8, dirs_store[0..dirs_n]);
    var market_store: [max_ids][]const u8 = undefined;
    const market_n = extractArray(raw, "plugin_marketplaces", &market_store);
    const plugin_marketplaces = try allocator.dupe([]const u8, market_store[0..market_n]);
    errdefer allocator.free(plugin_marketplaces);
    var provider_models: [max_provider_models]ProviderPref = [_]ProviderPref{.{}} ** max_provider_models;
    const provider_models_n = fillProviderModels(raw, &provider_models);
    return .{
        .raw = raw,
        .web = .{
            .order = order,
            .exclude = exclude,
            .searxng_endpoint = extractString(raw, "searxng_endpoint"),
        },
        .rules = rules,
        .review = extractString(raw, "review"),
        .sandbox = extractString(raw, "sandbox"),
        .cdp_port = extractString(raw, "cdp_port"),
        .sound = extractString(raw, "sound"),
        .statusline = extractString(raw, "statusline"),
        .statusline_place = extractString(raw, "statusline_place"),
        .statusline_fields = extractString(raw, "statusline_fields"),
        .composer = extractString(raw, "composer"),
        .thinking = Toggle.fromSlice(extractString(raw, "thinking")),
        .telemetry = Toggle.fromSlice(extractString(raw, "telemetry")),
        .peer = Toggle.fromSlice(extractString(raw, "peer")),
        .git_auto = Toggle.fromSlice(extractString(raw, "git_auto")),
        .git_dirty = blk: {
            const s = extractString(raw, "git_dirty");
            if (s.len == 0) break :blk Toggle.on;
            break :blk Toggle.fromSlice(s);
        },
        .workspace_dirs = workspace_dirs,
        .plugin_marketplaces = plugin_marketplaces,
        .mcp = mcp,
        .max_peer_depth = extractU8(raw, "max_peer_depth", 1),
        .effort = extractString(raw, "effort"),
        .editor = extractString(raw, "editor"),
        .ide = extractString(raw, "ide"),
        .bash_timeout = extractU32(raw, "bash_timeout"),
        .keep_sessions = extractU32(raw, "keep_sessions"),

        .last_model = extractString(raw, "last_model"),
        .last_provider = extractString(raw, "last_provider"),
        .last_mode = extractString(raw, "last_mode"),
        .provider_models = provider_models,
        .provider_models_n = provider_models_n,
    };
}

fn extractU8(json: []const u8, key: []const u8, default: u8) u8 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return default;
    const start = std.mem.indexOf(u8, json, needle) orelse return default;
    var i = start + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '"')) i += 1;
    var j = i;
    while (j < json.len and json[j] >= '0' and json[j] <= '9') j += 1;
    if (j == i) return default;
    const n = std.fmt.parseInt(u8, json[i..j], 10) catch return default;
    if (n == 0) return 1;
    return n;
}

/// Zero for missing or unparseable: every caller reads zero as "use the
/// default", so a typo falls back instead of clamping to something arbitrary.
fn extractU32(json: []const u8, key: []const u8) u32 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return 0;
    const start = std.mem.indexOf(u8, json, needle) orelse return 0;
    var i = start + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '"')) i += 1;
    var j = i;
    while (j < json.len and json[j] >= '0' and json[j] <= '9') j += 1;
    if (j == i) return 0;
    return std.fmt.parseInt(u32, json[i..j], 10) catch 0;
}

fn extractMcp(allocator: std.mem.Allocator, json: []const u8) ![]McpServer {
    const key = std.mem.indexOf(u8, json, "\"mcp\"") orelse return try allocator.alloc(McpServer, 0);
    const rest = json[key..];
    const lb = std.mem.indexOfScalar(u8, rest, '[') orelse return try allocator.alloc(McpServer, 0);
    var depth: i32 = 0;
    var rb: usize = lb;
    for (rest[lb..], lb..) |c, idx| {
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) {
                rb = idx;
                break;
            }
        }
    }
    if (rb <= lb) return try allocator.alloc(McpServer, 0);

    const inner = rest[lb + 1 .. rb];
    var list: std.ArrayList(McpServer) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len and list.items.len < max_mcp) {
        const ob = std.mem.indexOfScalarPos(u8, inner, i, '{') orelse break;
        const cb = std.mem.indexOfScalarPos(u8, inner, ob, '}') orelse break;
        const obj = inner[ob .. cb + 1];
        var server: McpServer = .{
            .name = extractString(obj, "name"),
            .command = extractString(obj, "command"),
            .url = extractString(obj, "url"),
        };
        var args_store: [max_ids][]const u8 = undefined;
        const args_n = extractArray(obj, "args", &args_store);
        var a: usize = 0;
        while (a < args_n and a < max_mcp_args) : (a += 1) server.argv[a] = args_store[a];
        server.argv_n = @min(args_n, max_mcp_args);
        if (server.name.len != 0 and (server.command.len != 0 or server.url.len != 0)) try list.append(allocator, server);
        i = cb + 1;
    }
    return list.toOwnedSlice(allocator);
}

fn fillProviderModels(json: []const u8, out: *[max_provider_models]ProviderPref) usize {
    const key = std.mem.indexOf(u8, json, "\"models\"") orelse return 0;
    const rest = json[key..];
    const lb = std.mem.indexOfScalar(u8, rest, '{') orelse return 0;
    var depth: i32 = 0;
    var rb: usize = lb;
    for (rest[lb..], lb..) |c, idx| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                rb = idx;
                break;
            }
        }
    }
    if (rb <= lb) return 0;
    const inner = rest[lb + 1 .. rb];
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len and n < max_provider_models) {
        const q1 = std.mem.indexOfScalarPos(u8, inner, i, '"') orelse break;
        const q2 = std.mem.indexOfScalarPos(u8, inner, q1 + 1, '"') orelse break;
        const provider = inner[q1 + 1 .. q2];
        const colon = std.mem.indexOfScalarPos(u8, inner, q2 + 1, ':') orelse break;
        const q3 = std.mem.indexOfScalarPos(u8, inner, colon + 1, '"') orelse break;
        const q4 = std.mem.indexOfScalarPos(u8, inner, q3 + 1, '"') orelse break;
        const model = inner[q3 + 1 .. q4];
        if (provider.len != 0 and model.len != 0) {
            out[n] = .{ .provider = provider, .model = model };
            n += 1;
        }
        i = q4 + 1;
    }
    return n;
}

pub fn modelForProvider(file: File, provider: []const u8) []const u8 {
    for (file.providerModels()) |p| {
        if (std.mem.eql(u8, p.provider, provider)) return p.model;
    }
    if (std.mem.eql(u8, file.last_provider, provider) and file.last_model.len > 0) return file.last_model;
    return "";
}

fn extractPermRules(json: []const u8, out: *[max_rules]permissions.Rule) usize {
    const key = std.mem.indexOf(u8, json, "\"permissions\"") orelse return 0;
    const rest = json[key..];
    const lb = std.mem.indexOfScalar(u8, rest, '{') orelse return 0;
    const rb = std.mem.indexOfScalar(u8, rest[lb..], '}') orelse return 0;
    const inner = rest[lb + 1 .. lb + rb];
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len and n < max_rules) {
        const q1 = std.mem.indexOfScalarPos(u8, inner, i, '"') orelse break;
        var q2 = q1 + 1;
        while (q2 < inner.len and inner[q2] != '"') : (q2 += 1) {}
        if (q2 >= inner.len) break;
        const pattern = inner[q1 + 1 .. q2];
        i = q2 + 1;
        const q3 = std.mem.indexOfScalarPos(u8, inner, i, '"') orelse break;
        var q4 = q3 + 1;
        while (q4 < inner.len and inner[q4] != '"') : (q4 += 1) {}
        if (q4 >= inner.len) break;
        const action_s = inner[q3 + 1 .. q4];
        i = q4 + 1;
        const action = permissions.parseAction(action_s) orelse continue;
        const parsed = permissions.parsePattern(pattern);
        out[n] = .{ .pattern = parsed.pattern, .action = action, .fallback = parsed.fallback };
        n += 1;
    }
    return n;
}

pub fn cdpPort(file: File) u16 {
    if (file.cdp_port.len == 0) return 9224;
    return std.fmt.parseInt(u16, file.cdp_port, 10) catch 9224;
}

/// Empty means off: the OS sandbox is opt-in so a fresh install does not trap
/// bash behind seatbelt/landlock until the user asks for it.
pub fn sandboxOff(file: File) bool {
    return !std.mem.eql(u8, file.sandbox, "on");
}

pub fn reviewLlm(file: File) bool {
    return std.mem.eql(u8, file.review, "llm");
}

pub fn load(allocator: std.mem.Allocator, io: Io, home: []const u8) File {
    const p = path(allocator, home) catch return .{};
    defer allocator.free(p);
    const json = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(64_000)) catch return .{};
    defer allocator.free(json);
    return parse(allocator, json) catch .{};
}

fn writeQuotedList(w: *std.Io.Writer, ids: []const []const u8) !void {
    try w.writeByte('[');
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{id});
    }
    try w.writeByte(']');
}

pub fn encodeFile(allocator: std.mem.Allocator, file: File) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\n  \"web_search\": {\n    \"order\": ");
    try writeQuotedList(w, file.web.order);
    try w.writeAll(",\n    \"exclude\": ");
    try writeQuotedList(w, file.web.exclude);
    try w.print(",\n    \"searxng_endpoint\": \"{s}\"\n  }}", .{file.web.searxng_endpoint});
    if (file.rules.len > 0) {
        try w.writeAll(",\n  \"permissions\": {");
        for (file.rules, 0..) |r, i| {
            if (i != 0) try w.writeAll(",");
            var key_buf: [256]u8 = undefined;
            const key = permissions.formatPattern(&key_buf, r.pattern, r.fallback);
            try w.print("\"{s}\":\"{s}\"", .{ key, @tagName(r.action) });
        }
        try w.writeAll("}");
    }
    if (file.review.len > 0) try w.print(",\n  \"review\": \"{s}\"", .{file.review});
    if (file.sandbox.len > 0) try w.print(",\n  \"sandbox\": \"{s}\"", .{file.sandbox});
    if (file.cdp_port.len > 0) try w.print(",\n  \"cdp_port\": \"{s}\"", .{file.cdp_port});
    if (file.mcp.len > 0) {
        try w.writeAll(",\n  \"mcp\": [");
        for (file.mcp, 0..) |s, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("{\"name\":\"");
            try w.writeAll(s.name);
            if (s.url.len > 0) {
                try w.writeAll("\",\"url\":\"");
                try w.writeAll(s.url);
                try w.writeAll("\"");
            } else {
                try w.writeAll("\",\"command\":\"");
                try w.writeAll(s.command);
                try w.writeAll("\",\"args\":");
                try writeQuotedList(w, s.argv[0..s.argv_n]);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]");
    }
    if (file.sound.len > 0) try w.print(",\n  \"sound\": \"{s}\"", .{file.sound});
    if (file.statusline.len > 0) try w.print(",\n  \"statusline\": \"{s}\"", .{file.statusline});
    if (file.statusline_place.len > 0) try w.print(",\n  \"statusline_place\": \"{s}\"", .{file.statusline_place});
    if (file.statusline_fields.len > 0) try w.print(",\n  \"statusline_fields\": \"{s}\"", .{file.statusline_fields});
    if (file.composer.len > 0) try w.print(",\n  \"composer\": \"{s}\"", .{file.composer});
    if (file.thinking == .on) try w.writeAll(",\n  \"thinking\": \"on\"");
    if (file.telemetry == .on) try w.writeAll(",\n  \"telemetry\": \"on\"");
    if (file.peer == .on) try w.writeAll(",\n  \"peer\": \"on\"");
    if (file.git_auto == .on) try w.writeAll(",\n  \"git_auto\": \"on\"");
    if (file.git_dirty == .off) try w.writeAll(",\n  \"git_dirty\": \"off\"");
    if (file.workspace_dirs.len > 0) {
        try w.writeAll(",\n  \"workspace_dirs\": ");
        try writeQuotedList(w, file.workspace_dirs);
    }
    if (file.max_peer_depth != 1) try w.print(",\n  \"max_peer_depth\": {d}", .{file.max_peer_depth});
    if (file.effort.len > 0) try w.print(",\n  \"effort\": \"{s}\"", .{file.effort});
    if (file.editor.len > 0) try w.print(",\n  \"editor\": \"{s}\"", .{file.editor});
    if (file.ide.len > 0) try w.print(",\n  \"ide\": \"{s}\"", .{file.ide});
    if (file.plugin_marketplaces.len > 0) {
        try w.writeAll(",\n  \"plugin_marketplaces\": ");
        try writeQuotedList(w, file.plugin_marketplaces);
    }
    if (file.bash_timeout != 0) try w.print(",\n  \"bash_timeout\": {d}", .{file.bash_timeout});
    if (file.keep_sessions != 0) try w.print(",\n  \"keep_sessions\": {d}", .{file.keep_sessions});

    if (file.last_model.len > 0) try w.print(",\n  \"last_model\": \"{s}\"", .{file.last_model});
    if (file.last_provider.len > 0) try w.print(",\n  \"last_provider\": \"{s}\"", .{file.last_provider});
    if (file.last_mode.len > 0) try w.print(",\n  \"last_mode\": \"{s}\"", .{file.last_mode});
    if (file.provider_models_n > 0) {
        try w.writeAll(",\n  \"models\": {");
        for (file.providerModels(), 0..) |p, i| {
            if (i != 0) try w.writeAll(",");
            try w.print("\"{s}\":\"{s}\"", .{ p.provider, p.model });
        }
        try w.writeAll("}");
    }
    try w.writeAll("\n}\n");
    return aw.toOwnedSlice();
}

pub const NumPref = enum {
    max_peer_depth,
    bash_timeout,
    keep_sessions,

    pub fn fromSlice(s: []const u8) ?NumPref {
        return std.meta.stringToEnum(NumPref, s);
    }
};

pub fn setNumber(allocator: std.mem.Allocator, io: Io, home: []const u8, key: NumPref, n: u32) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    switch (key) {
        // Depth zero would mean a peer that cannot do anything, so it reads as
        // the default rather than as a setting nobody meant.
        .max_peer_depth => file.max_peer_depth = if (n == 0) 1 else @intCast(@min(n, 255)),
        // Zero is "the default" for both, so it is stored as written.
        .bash_timeout => file.bash_timeout = n,
        .keep_sessions => file.keep_sessions = n,
    }
    const encoded = try encodeFile(allocator, file);
    defer allocator.free(encoded);
    const p = try path(allocator, home);
    defer allocator.free(p);
    var f = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(encoded);
    try w.interface.flush();
}

pub fn encode(allocator: std.mem.Allocator, web: Web) ![]u8 {
    return encodeFile(allocator, .{ .web = web });
}

fn writePath(allocator: std.mem.Allocator, io: Io, home: []const u8, body: []const u8) !void {
    const p = try path(allocator, home);
    defer allocator.free(p);
    const dir = std.fs.path.dirname(p) orelse home;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
    };
    var file = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    var buf: [512]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

pub fn save(allocator: std.mem.Allocator, io: Io, home: []const u8, web: Web) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    const merged = copyMeta(file, web);
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

fn copyMeta(file: File, web: Web) File {
    return .{
        .web = web,
        .rules = file.rules,
        .review = file.review,
        .sandbox = file.sandbox,
        .cdp_port = file.cdp_port,
        .sound = file.sound,
        .statusline = file.statusline,
        .statusline_place = file.statusline_place,
        .statusline_fields = file.statusline_fields,
        .composer = file.composer,
        .thinking = file.thinking,
        .telemetry = file.telemetry,
        .peer = file.peer,
        .git_auto = file.git_auto,
        .git_dirty = file.git_dirty,
        .workspace_dirs = file.workspace_dirs,
        .mcp = file.mcp,
        .max_peer_depth = file.max_peer_depth,
        .effort = file.effort,
        .editor = file.editor,
        .ide = file.ide,
        .plugin_marketplaces = file.plugin_marketplaces,
        .bash_timeout = file.bash_timeout,
        .keep_sessions = file.keep_sessions,

        .last_model = file.last_model,
        .last_provider = file.last_provider,
        .last_mode = file.last_mode,
        .provider_models = file.provider_models,
        .provider_models_n = file.provider_models_n,
    };
}

pub fn appendRule(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    pattern: []const u8,
    action: permissions.DslAction,
) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    var store: [max_rules]permissions.Rule = undefined;
    const n = @min(file.rules.len, max_rules - 1);
    if (file.rules.len > 0) @memcpy(store[0..n], file.rules[0..n]);
    store[n] = blk: {
        const parsed = permissions.parsePattern(pattern);
        break :blk .{ .pattern = parsed.pattern, .action = action, .fallback = parsed.fallback };
    };
    var merged = copyMeta(file, file.web);
    merged.rules = store[0 .. n + 1];
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

pub fn setSandbox(allocator: std.mem.Allocator, io: Io, home: []const u8, value: []const u8) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    var merged = copyMeta(file, file.web);
    merged.sandbox = value;
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

pub fn removeRule(allocator: std.mem.Allocator, io: Io, home: []const u8, pattern: []const u8) !bool {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    var store: [max_rules]permissions.Rule = undefined;
    var n: usize = 0;
    var removed = false;
    for (file.rules) |r| {
        if (std.mem.eql(u8, r.pattern, pattern)) {
            removed = true;
            continue;
        }
        if (n < max_rules) {
            store[n] = r;
            n += 1;
        }
    }
    if (!removed) return false;
    var merged = copyMeta(file, file.web);
    merged.rules = store[0..n];
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
    return true;
}

pub const Pref = enum {
    sound,
    effort,
    editor,
    ide,
    statusline,
    composer,
    review,
    cdp_port,
    thinking,
    telemetry,
    peer,
    git_auto,
    git_dirty,
    statusline_place,
    statusline_fields,

    pub fn fromSlice(s: []const u8) ?Pref {
        return std.meta.stringToEnum(Pref, s);
    }
};

pub fn thinkingOn(file: File) bool {
    return file.thinking == .on;
}

pub fn telemetryOn(file: File) bool {
    return file.telemetry == .on;
}

pub fn peerAutoOn(file: File) bool {
    return file.peer == .on;
}

pub fn gitAutoOn(file: File) bool {
    return file.git_auto == .on;
}

pub fn gitDirtyOn(file: File) bool {
    return file.git_dirty == .on;
}

/// Unset follows the host: a real player exists on macOS, so the chime is on
/// there and off elsewhere until the user writes an explicit value.
pub fn soundOn(file: File) bool {
    if (file.sound.len == 0) return builtin.os.tag == .macos;
    return std.mem.eql(u8, file.sound, "on");
}

pub fn setPref(allocator: std.mem.Allocator, io: Io, home: []const u8, key: Pref, value: []const u8) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    var merged = copyMeta(file, file.web);
    switch (key) {
        .sound => merged.sound = value,
        .effort => merged.effort = value,
        .editor => merged.editor = value,
        .ide => merged.ide = value,
        .statusline => merged.statusline = value,
        .composer => merged.composer = value,
        .review => merged.review = value,
        .cdp_port => merged.cdp_port = value,
        .thinking => merged.thinking = Toggle.fromSlice(value),
        .telemetry => merged.telemetry = Toggle.fromSlice(value),
        .peer => merged.peer = Toggle.fromSlice(value),
        .git_auto => merged.git_auto = Toggle.fromSlice(value),
        .git_dirty => merged.git_dirty = Toggle.fromSlice(value),
        .statusline_place => merged.statusline_place = value,
        .statusline_fields => merged.statusline_fields = value,
    }
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

pub fn rememberProvider(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    provider: []const u8,
    fallback_model: []const u8,
) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    const preferred = modelForProvider(file, provider);
    const model = if (preferred.len > 0) preferred else fallback_model;
    try setLastChat(allocator, io, home, provider, model, file.last_mode);
}

pub fn setLastChat(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    provider: []const u8,
    model: []const u8,
    mode: []const u8,
) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    var prefs = file.provider_models;
    var n = file.provider_models_n;
    var replaced = false;
    for (prefs[0..n]) |*p| {
        if (std.mem.eql(u8, p.provider, provider)) {
            p.* = .{ .provider = provider, .model = model };
            replaced = true;
            break;
        }
    }
    if (!replaced and n < prefs.len and provider.len > 0 and model.len > 0) {
        prefs[n] = .{ .provider = provider, .model = model };
        n += 1;
    }
    var merged = copyMeta(file, file.web);
    merged.last_provider = provider;
    merged.last_model = model;
    merged.last_mode = mode;
    merged.provider_models = prefs;
    merged.provider_models_n = n;
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

pub fn upsertMcp(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    server: McpServer,
) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    var store: [max_mcp]McpServer = undefined;
    var n: usize = 0;
    var replaced = false;
    for (file.mcp) |s| {
        if (n >= store.len) break;
        if (std.mem.eql(u8, s.name, server.name)) {
            store[n] = server;
            replaced = true;
        } else {
            store[n] = s;
        }
        n += 1;
    }
    if (!replaced) {
        if (n >= store.len) return error.Full;
        store[n] = server;
        n += 1;
    }
    var merged = copyMeta(file, file.web);
    merged.mcp = store[0..n];
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

pub fn addPluginMarketplace(allocator: std.mem.Allocator, io: Io, home: []const u8, id: []const u8) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    for (file.plugin_marketplaces) |m| {
        if (std.mem.eql(u8, m, id)) return;
    }
    var store: [max_ids][]const u8 = undefined;
    const n = @min(file.plugin_marketplaces.len, store.len - 1);
    @memcpy(store[0..n], file.plugin_marketplaces[0..n]);
    store[n] = id;
    var merged = copyMeta(file, file.web);
    merged.plugin_marketplaces = store[0 .. n + 1];
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

pub fn setWorkspaceDirs(allocator: std.mem.Allocator, io: Io, home: []const u8, dirs: []const []const u8) !void {
    var file = load(allocator, io, home);
    defer file.deinit(allocator);
    var merged = copyMeta(file, file.web);
    merged.workspace_dirs = dirs;
    const body = try encodeFile(allocator, merged);
    defer allocator.free(body);
    try writePath(allocator, io, home, body);
}

pub fn excluded(web: Web, id: []const u8) bool {
    for (web.exclude) |e| {
        if (std.mem.eql(u8, e, id)) return true;
    }
    return false;
}

test "encode and parse last chat" {
    var f = try parse(std.testing.allocator,
        \\{"web_search":{"order":[],"exclude":[],"searxng_endpoint":""},"last_model":"grok-4","last_provider":"xai","last_mode":"plan"}
    );
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("grok-4", f.last_model);
    try std.testing.expectEqualStrings("xai", f.last_provider);
    try std.testing.expectEqualStrings("plan", f.last_mode);
    const body = try encodeFile(std.testing.allocator, f);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "last_model") != null);
}

test "parse order exclude and searxng endpoint" {
    const json =
        \\{"web_search":{"order":["exa","tavily"],"exclude":["google"],"searxng_endpoint":"http://127.0.0.1:8888"}}
    ;
    var f = try parse(std.testing.allocator, json);
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), f.web.order.len);
    try std.testing.expectEqualStrings("exa", f.web.order[0]);
    try std.testing.expectEqualStrings("tavily", f.web.order[1]);
    try std.testing.expect(excluded(f.web, "google"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8888", f.web.searxng_endpoint);
}

test "parse permissions last-match fields" {
    const json =
        \\{"permissions":{"*":"ask","read":"allow","bash:rm *":"deny"},"review":"llm","sandbox":"off","cdp_port":"9333"}
    ;
    var f = try parse(std.testing.allocator, json);
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), f.rules.len);
    try std.testing.expectEqualStrings("*", f.rules[0].pattern);
    try std.testing.expect(reviewLlm(f));
    try std.testing.expect(sandboxOff(f));
    try std.testing.expectEqual(@as(u16, 9333), cdpPort(f));
}

test "parse mcp servers" {
    const json =
        \\{"mcp":[{"name":"fs","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","."]}]}
    ;
    var f = try parse(std.testing.allocator, json);
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), f.mcp.len);
    try std.testing.expectEqualStrings("fs", f.mcp[0].name);
    try std.testing.expectEqualStrings("npx", f.mcp[0].command);
    try std.testing.expectEqual(@as(usize, 3), f.mcp[0].argv_n);
}

test "parse missing mcp owns empty slice" {
    var f = try parse(std.testing.allocator, "{}");
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), f.mcp.len);
}

test "encode round-trips order" {
    const web = Web{ .order = &.{ "tavily", "duckduckgo" }, .exclude = &.{}, .searxng_endpoint = "" };
    const s = try encode(std.testing.allocator, web);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"tavily\"") != null);
    var f = try parse(std.testing.allocator, s);
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("duckduckgo", f.web.order[1]);
}

test "parse workspace_dirs and ui prefs" {
    const json =
        \\{"sound":"on","statusline":"off","composer":">> ","thinking":"on","workspace_dirs":["/tmp/a"]}
    ;
    var f = try parse(std.testing.allocator, json);
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("on", f.sound);
    try std.testing.expect(soundOn(f));
    try std.testing.expectEqualStrings("off", f.statusline);
    try std.testing.expectEqualStrings(">> ", f.composer);
    try std.testing.expect(thinkingOn(f));
    try std.testing.expectEqual(@as(usize, 1), f.workspace_dirs.len);
    try std.testing.expectEqualStrings("/tmp/a", f.workspace_dirs[0]);
}

test "the new preferences round-trip through the file" {
    const a = std.testing.allocator;
    const body = try encodeFile(a, .{
        .effort = "high",
        .editor = "nvim",
        .bash_timeout = 600,
        .keep_sessions = 50,
    });
    defer a.free(body);
    var f = try parse(a, body);
    defer f.deinit(a);
    try std.testing.expectEqualStrings("high", f.effort);
    try std.testing.expectEqualStrings("nvim", f.editor);
    try std.testing.expectEqual(@as(u32, 600), f.bash_timeout);
    try std.testing.expectEqual(@as(u32, 50), f.keep_sessions);
}

test "thinking defaults off and round-trips with max_peer_depth" {
    var missing = try parse(std.testing.allocator, "{}");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!thinkingOn(missing));
    const s = try encodeFile(std.testing.allocator, .{
        .thinking = .on,
        .max_peer_depth = 3,
    });
    defer std.testing.allocator.free(s);
    var f = try parse(std.testing.allocator, s);
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(thinkingOn(f));
    try std.testing.expectEqual(@as(u8, 3), f.max_peer_depth);
}

test "soundOn is explicit, else macos default" {
    var missing = try parse(std.testing.allocator, "{}");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(builtin.os.tag == .macos, soundOn(missing));
    var off = try parse(std.testing.allocator, "{\"sound\":\"off\"}");
    defer off.deinit(std.testing.allocator);
    try std.testing.expect(!soundOn(off));
}

test "encodeFile keeps permissions sandbox and mcp" {
    const rules = [_]permissions.Rule{.{ .pattern = "read", .action = .allow }};
    var server: McpServer = .{ .name = "fs", .command = "npx", .argv_n = 1 };
    server.argv[0] = "-y";
    const s = try encodeFile(std.testing.allocator, .{
        .rules = &rules,
        .sandbox = "off",
        .mcp = &.{server},
    });
    defer std.testing.allocator.free(s);
    var f = try parse(std.testing.allocator, s);
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), f.rules.len);
    try std.testing.expectEqualStrings("read", f.rules[0].pattern);
    try std.testing.expect(sandboxOff(f));
    try std.testing.expectEqual(@as(usize, 1), f.mcp.len);
    try std.testing.expectEqualStrings("fs", f.mcp[0].name);
}

test "peer defaults off and round-trips" {
    var missing = try parse(std.testing.allocator, "{}");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!peerAutoOn(missing));
    const s = try encodeFile(std.testing.allocator, .{ .peer = .on });
    defer std.testing.allocator.free(s);
    var f = try parse(std.testing.allocator, s);
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(peerAutoOn(f));
}

test "telemetry is off until the user says otherwise" {
    // The attribution headers name the client to the provider. Nothing about
    // them changes the reply, so the default has to be silence.
    const missing = File{};
    try std.testing.expect(!telemetryOn(missing));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("../tools/pathing.zig").testWorkspace(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(home);
    try setPref(std.testing.allocator, std.testing.io, home, .telemetry, "on");
    var f = load(std.testing.allocator, std.testing.io, home);
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(telemetryOn(f));
}

test "sandbox is off until the user turns it on" {
    try std.testing.expect(sandboxOff(.{}));
    try std.testing.expect(sandboxOff(.{ .sandbox = "off" }));
    try std.testing.expect(!sandboxOff(.{ .sandbox = "on" }));
}
