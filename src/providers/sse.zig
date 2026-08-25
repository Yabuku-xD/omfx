const std = @import("std");
const types = @import("types.zig");

pub const Parsed = union(enum) {
    text: []const u8,
    think: []const u8,
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        args: []const u8,
        index: usize = 0,
    },
    /// Real counts from the provider, never an estimate.
    ///
    /// Every wire spells this differently: OpenAI-compat sends
    /// `usage.prompt_tokens` / `completion_tokens`, Responses sends
    /// `usage.input_tokens` / `output_tokens`, Anthropic sends
    /// `message_start.message.usage.input_tokens` then `message_delta.usage`
    /// with the running output count. All three land here.
    usage: Usage,
    done,
    ignore,
};

pub const Usage = struct {
    input: u32 = 0,
    output: u32 = 0,
    /// Anthropic splits the prompt across three fields when caching is on.
    /// All three occupy the context window -- "all three count toward the
    /// window", platform.claude.com/docs/en/build-with-claude/context-windows
    /// -- and on a cached turn `input_tokens` can be 1 while the conversation
    /// actually sitting in the window is a hundred thousand cache-read
    /// tokens. Counting input alone reports an almost empty window right up
    /// until the request is refused.
    cache_read: u32 = 0,
    cache_write: u32 = 0,

    /// Everything the window is holding.
    ///
    /// Output is included deliberately. Some UIs omit output from the displayed
    /// percentage while the refusal check includes it — that mismatch can show
    /// ~20% on a session that has already been refused.
    pub fn total(self: Usage) u32 {
        return self.input +| self.output +| self.cache_read +| self.cache_write;
    }

    pub fn merge(self: *Usage, other: Usage) void {
        // Anthropic re-sends input once and grows output; taking the max keeps
        // a late zero from wiping a count that already arrived.
        self.input = @max(self.input, other.input);
        self.output = @max(self.output, other.output);
        self.cache_read = @max(self.cache_read, other.cache_read);
        self.cache_write = @max(self.cache_write, other.cache_write);
    }
};

/// Reads whichever spelling the payload uses. Null when there is no usage in
/// this event, which is most of them.
pub fn usageOf(json: []const u8) ?Usage {
    if (std.mem.indexOf(u8, json, "\"usage\"") == null) return null;
    const in = jsonUsize(json, "input_tokens") orelse jsonUsize(json, "prompt_tokens");
    const out = jsonUsize(json, "output_tokens") orelse jsonUsize(json, "completion_tokens");
    const cr = jsonUsize(json, "cache_read_input_tokens") orelse jsonUsize(json, "cached_tokens");
    const cw = jsonUsize(json, "cache_creation_input_tokens");
    if (in == null and out == null and cr == null and cw == null) return null;
    return .{
        .input = @intCast(@min(in orelse 0, std.math.maxInt(u32))),
        .output = @intCast(@min(out orelse 0, std.math.maxInt(u32))),
        .cache_read = @intCast(@min(cr orelse 0, std.math.maxInt(u32))),
        .cache_write = @intCast(@min(cw orelse 0, std.math.maxInt(u32))),
    };
}

const Class = enum { answer, think, stop, other };

pub const Extract = struct {
    /// Real counts, merged across every event that carried any.
    usage: Usage = .{},
    text: []const u8 = "",
    think: []const u8 = "",
};

const json_key_max: usize = 32;
const type_name_max: usize = 32;

fn ends(hay: []const u8, needle: []const u8) bool {
    return std.mem.endsWith(u8, hay, needle);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn isThinkType(typ: []const u8) bool {
    return ends(typ, "reasoning_summary_text.delta") or
        ends(typ, "reasoning.delta") or
        ends(typ, "thinking_delta") or
        ends(typ, "summary_text") or
        eql(typ, "reasoning") or
        eql(typ, "thinking");
}

fn classOpenAi(typ: []const u8, json: []const u8) Class {
    if (ends(typ, "output_text.delta") or eql(typ, "output_text")) return .answer;
    if (isThinkType(typ) or has(json, "thinking_delta") or has(json, "reasoning_content") or has(json, "\"reasoning\":") or has(json, "reasoning_details")) return .think;
    return .other;
}

fn classAnthropic(typ: []const u8, json: []const u8) Class {
    if (eql(typ, "message_stop")) return .stop;
    if (eql(typ, "thinking_delta") or eql(typ, "thinking") or has(json, "thinking_delta")) return .think;
    if (eql(typ, "text_delta") or eql(typ, "content_block_delta")) return .answer;
    return .other;
}

fn firstString(json: []const u8, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (jsonString(json, key)) |v| {
            if (v.len > 0) return v;
        }
    }
    return null;
}

fn asThink(json: []const u8) Parsed {
    // Command Code / DeepSeek / Gemini-via-CC stream thinking as `reasoning`
    // (sometimes `reasoning_content`). Never prefer bare `text` first: that
    // key also appears inside `reasoning_details` and would mis-route.
    if (firstString(json, &.{ "reasoning_content", "reasoning", "delta", "thinking" })) |c| return .{ .think = c };
    // Typed thinking blocks (Anthropic / Responses) carry the body under text.
    if (firstString(json, &.{"text"})) |c| return .{ .think = c };
    return .ignore;
}

/// Narrow field reads to the streaming `delta` object when present so nested
/// payloads (`reasoning_details`, tool args) cannot leak as the answer.
fn deltaScope(json: []const u8) []const u8 {
    if (std.mem.indexOf(u8, json, "\"delta\":{")) |i| return json[i..];
    if (std.mem.indexOf(u8, json, "\"delta\": {")) |i| return json[i..];
    return json;
}

fn asText(json: []const u8, key: []const u8) Parsed {
    if (jsonString(json, key)) |c| {
        if (c.len > 0) return .{ .text = c };
    }
    return .ignore;
}

pub fn dataLine(line: []const u8) []const u8 {
    const t = std.mem.trim(u8, line, " \r");
    if (std.mem.startsWith(u8, t, "data:")) return std.mem.trim(u8, t["data:".len..], " ");
    return t;
}

pub fn parseOpenAiData(data: []const u8) Parsed {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return .ignore;
    if (eql(trimmed, "[DONE]")) return .done;
    // Checked before the type switch: a usage event carries no delta, so the
    // switch below would classify it as `.other` and drop the counts.
    if (usageOf(trimmed)) |u| return .{ .usage = u };

    if (jsonString(trimmed, "type")) |typ| {
        switch (classOpenAi(typ, trimmed)) {
            .answer => return asText(trimmed, "delta"),
            .think => return asThink(trimmed),
            .stop => return .done,
            .other => {},
        }
    }

    const scope = deltaScope(trimmed);
    // Visible answer first when a delta carries both (rare).
    if (jsonString(scope, "content")) |content| {
        if (content.len > 0) return .{ .text = content };
    }
    if (jsonString(scope, "reasoning_content")) |c| {
        if (c.len > 0) return .{ .think = c };
    }
    if (jsonString(scope, "reasoning")) |c| {
        if (c.len > 0) return .{ .think = c };
    }
    // Chat.completions streams tools under `tool_calls`; Responses uses
    // `function_call`. Require one so a random `"name"` elsewhere is ignored.
    if (has(trimmed, "tool_calls") or has(trimmed, "\"type\":\"function_call\"")) {
        const name = jsonString(trimmed, "name");
        const args = jsonString(trimmed, "arguments");
        const id = jsonString(trimmed, "id");
        if (name != null or args != null) {
            return .{ .tool_call = .{
                .id = id orelse "",
                .name = name orelse "",
                .args = args orelse "",
                .index = jsonUsize(trimmed, "index") orelse 0,
            } };
        }
    }
    return .ignore;
}

pub fn parseAnthropicData(data: []const u8) Parsed {
    if (usageOf(data)) |u| return .{ .usage = u };
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return .ignore;
    if (jsonString(trimmed, "type")) |typ| {
        switch (classAnthropic(typ, trimmed)) {
            .stop => return .done,
            .think => return asThink(trimmed),
            .answer => switch (asText(trimmed, "text")) {
                .text => |c| return .{ .text = c },
                else => {},
            },
            .other => {},
        }
    }
    return asText(trimmed, "text");
}

pub fn parseData(protocol: types.Protocol, data: []const u8) Parsed {
    return switch (protocol) {
        .openai_compat, .openai_responses => parseOpenAiData(data),
        .anthropic => parseAnthropicData(data),
    };
}

fn thinkBody(body: []const u8) bool {
    // `"type":"reasoning"` alone misses Command Code's `"type":"reasoning.text"`.
    return has(body, "\"type\":\"reasoning\"") or
        has(body, "reasoning.text") or
        has(body, "reasoning_details") or
        has(body, "\"reasoning\":") or
        has(body, "reasoning_content") or
        has(body, "summary_text");
}

pub fn lastTypeText(body: []const u8, type_name: []const u8) []const u8 {
    if (type_name.len > type_name_max) return "";
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"type\":\"{s}\"", .{type_name}) catch return "";
    var last: []const u8 = "";
    var i: usize = 0;
    while (i < body.len) {
        const rest = body[i..];
        const at = std.mem.indexOf(u8, rest, needle) orelse break;
        if (jsonString(rest[at..], "text")) |t| {
            if (t.len > 0) last = t;
        }
        i += at + needle.len;
    }
    return last;
}

pub fn extract(protocol: types.Protocol, body: []const u8) Extract {
    var out = Extract{};
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        switch (parseData(protocol, dataLine(line))) {
            .text => |c| if (c.len > 0) {
                out.text = c;
            },
            .think => |c| if (c.len > 0) {
                out.think = c;
            },
            .usage => |u| out.usage.merge(u),
            .tool_call, .done, .ignore => {},
        }
    }
    if (out.text.len == 0) out.text = lastTypeText(body, "output_text");
    if (out.think.len == 0) out.think = lastTypeText(body, "summary_text");
    // Never scan bare `"text"` / unscoped `"content"` as the answer: Command
    // Code (and other OpenAI-compat routers) put reasoning fragments under
    // `reasoning_details[].text`, which would leak as a one-word reply.
    if (out.text.len == 0 and std.mem.indexOf(u8, body, "data:") == null and !thinkBody(body)) {
        if (std.mem.indexOf(u8, body, "\"message\"") != null) {
            if (jsonString(body, "content")) |c| out.text = c;
        }
    }
    return out;
}

/// Unescape a JSON string body (`\"` `\\` `\n`). Allocator owns the result.
/// Decodes into a caller buffer, or null when it does not fit.
///
/// Security checks run before any allocator is in scope and must see the same
/// bytes the shell will. Null is a refusal, not an empty result: a caller that
/// cannot decode has to fail closed rather than judge the escaped form.
pub fn unescapeInto(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (n == buf.len) return null;
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            buf[n] = switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => s[i],
            };
        } else {
            buf[n] = s[i];
        }
        n += 1;
    }
    return buf[0..n];
}

/// Tool arguments arrive as JSON string values. Decode the field once so a
/// call site cannot judge or execute the escaped form.
pub fn argString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ?[]const u8 {
    const raw = jsonString(json, key) orelse return null;
    return unescapeAlloc(allocator, raw) catch null;
}

/// Same decode into a caller buffer. Null when the key is missing or the
/// decoded value does not fit — fail closed, never a truncated command.
pub fn argStringInto(buf: []u8, json: []const u8, key: []const u8) ?[]const u8 {
    const raw = jsonString(json, key) orelse return null;
    return unescapeInto(buf, raw);
}

pub fn unescapeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                else => try out.append(allocator, s[i]),
            }
        } else {
            try out.append(allocator, s[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Naive JSON string field extractor. Sufficient for fixture deltas; not a full parser.
pub fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    if (key.len > json_key_max) return null;
    var needle_buf: [json_key_max + 4]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = start + needle.len;
    while (i < json.len and (json[i] == ' ')) i += 1;
    if (i >= json.len) return null;
    if (json[i] == 'n') return null;
    if (json[i] != '"') return null;
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

/// String or number atom. Chrome tabId is a number; models send either.
pub fn jsonAtom(json: []const u8, key: []const u8) ?[]const u8 {
    if (jsonString(json, key)) |s| return s;
    if (key.len > json_key_max) return null;
    var needle_buf: [json_key_max + 4]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = start + needle.len;
    while (i < json.len and json[i] == ' ') i += 1;
    if (i >= json.len) return null;
    if (json[i] == '-' or (json[i] >= '0' and json[i] <= '9')) {
        const from = i;
        if (json[i] == '-') i += 1;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
        if (i == from or (i == from + 1 and json[from] == '-')) return null;
        return json[from..i];
    }
    return null;
}

/// Models send numeric args as either `12` or `"12"`; take both.
pub fn jsonUsize(json: []const u8, key: []const u8) ?usize {
    const atom = jsonAtom(json, key) orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, atom, " \""), 10) catch null;
}

test "jsonUsize takes bare and quoted numbers" {
    try std.testing.expectEqual(@as(?usize, 12), jsonUsize("{\"offset\":12}", "offset"));
    try std.testing.expectEqual(@as(?usize, 12), jsonUsize("{\"offset\":\"12\"}", "offset"));
    try std.testing.expectEqual(@as(?usize, null), jsonUsize("{\"offset\":\"x\"}", "offset"));
    try std.testing.expectEqual(@as(?usize, null), jsonUsize("{}", "offset"));
}

test "unescapeInto matches unescapeAlloc, and refuses to truncate" {
    var buf: [64]u8 = undefined;
    const got = unescapeInto(&buf, "ls\\t&&\\trm\\t-rf").?;
    try std.testing.expectEqualStrings("ls\t&&\trm\t-rf", got);

    const alloc = try unescapeAlloc(std.testing.allocator, "a\\nb\\\\c\\\"d");
    defer std.testing.allocator.free(alloc);
    var buf2: [64]u8 = undefined;
    try std.testing.expectEqualStrings(alloc, unescapeInto(&buf2, "a\\nb\\\\c\\\"d").?);

    // Too long to decode is null, never a truncated string a check could pass.
    var tiny: [4]u8 = undefined;
    try std.testing.expect(unescapeInto(&tiny, "aaaaaaaaaa") == null);
}

test "unescapeAlloc undoes jsonEscape slashes" {
    const s = try unescapeAlloc(std.testing.allocator, "{\\\"path\\\":\\\"a.txt\\\"}");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", s);
}

test "argString unescapes a tool argument once" {
    const json = "{\"path\":\"a\\nb.txt\",\"command\":\"ls\\t-la\"}";
    const path = argString(std.testing.allocator, json, "path").?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("a\nb.txt", path);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ls\t-la", argStringInto(&buf, json, "command").?);
    try std.testing.expect(argStringInto(&buf, json, "missing") == null);
}

test "unescapeAlloc turns json newlines into real ones" {
    const s = try unescapeAlloc(std.testing.allocator, "a\\n\\n### Title");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a\n\n### Title", s);
}

test "openai text delta" {
    const p = parseOpenAiData(
        \\{"choices":[{"delta":{"content":"hi"}}]}
    );
    try std.testing.expectEqualStrings("hi", p.text);
}

test "deepseek reasoning_content is think" {
    const p = parseOpenAiData(
        \\{"choices":[{"delta":{"reasoning_content":"plan"}}]}
    );
    try std.testing.expectEqualStrings("plan", p.think);
}

test "commandcode reasoning field is think" {
    const p = parseOpenAiData(
        \\{"choices":[{"delta":{"reasoning":"The","reasoning_details":[{"type":"reasoning.text","text":"The"}]}}]}
    );
    try std.testing.expectEqualStrings("The", p.think);
}

test "extract does not steal reasoning_details text as the answer" {
    const body =
        \\data: {"choices":[{"delta":{"reasoning":"The","reasoning_details":[{"type":"reasoning.text","text":"The"}]}}]}
        \\
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"glob","arguments":""}}]}}]}
        \\
        \\data: [DONE]
        \\
    ;
    const got = extract(.openai_compat, body);
    try std.testing.expectEqualStrings("", got.text);
    try std.testing.expectEqualStrings("The", got.think);
}

test "extract never leaks reasoning_details text even without reasoning key" {
    // Worst case: only reasoning_details (no top-level reasoning field).
    const body =
        \\data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"The"}]}}]}
        \\
        \\data: [DONE]
        \\
    ;
    const got = extract(.openai_compat, body);
    try std.testing.expectEqualStrings("", got.text);
}

test "gemini-style commandcode reasoning does not become the answer" {
    const body =
        \\data: {"choices":[{"delta":{"role":"assistant"}}]}
        \\
        \\data: {"choices":[{"delta":{"reasoning":"The","reasoning_details":[{"type":"reasoning.text","text":"The","format":"unknown","index":0}]}}]}
        \\
        \\data: {"choices":[{"delta":{"reasoning":" user","reasoning_details":[{"type":"reasoning.text","text":" user","format":"unknown","index":0}]}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"Hello there."}}]}
        \\
        \\data: [DONE]
        \\
    ;
    const got = extract(.openai_compat, body);
    try std.testing.expectEqualStrings("Hello there.", got.text);
    try std.testing.expectEqualStrings(" user", got.think);
}

test "deepseek content wins over reasoning_content in same delta" {
    const p = parseOpenAiData(
        \\{"choices":[{"delta":{"reasoning_content":"plan","content":"hi"}}]}
    );
    try std.testing.expectEqualStrings("hi", p.text);
}

test "openai done" {
    const p = parseOpenAiData("[DONE]");
    try std.testing.expectEqual(p, .done);
}

test "anthropic text delta" {
    const p = parseAnthropicData(
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"yo"}}
    );
    try std.testing.expectEqualStrings("yo", p.text);
}

test "responses output_text delta is text" {
    const p = parseOpenAiData(
        \\{"type":"response.output_text.delta","delta":"pong"}
    );
    try std.testing.expectEqualStrings("pong", p.text);
}

test "answer delta with the word reasoning stays text" {
    const p = parseOpenAiData(
        \\{"type":"response.output_text.delta","delta":"reasoning is hard"}
    );
    try std.testing.expectEqualStrings("reasoning is hard", p.text);
}

test "reasoning summary is think not text" {
    const p = parseOpenAiData(
        \\{"type":"reasoning","summary":[{"type":"summary_text","text":"The user said hi"}]}
    );
    try std.testing.expectEqualStrings("The user said hi", p.think);
}

test "reasoning_summary_text delta is think" {
    const p = parseOpenAiData(
        \\{"type":"response.reasoning_summary_text.delta","delta":"plan"}
    );
    try std.testing.expectEqualStrings("plan", p.think);
}

test "anthropic thinking_delta is think" {
    const p = parseAnthropicData(
        \\{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}
    );
    try std.testing.expectEqualStrings("hmm", p.think);
}

test "openai 401 body is not a text event" {
    const p = parseOpenAiData(
        \\{"error":{"message":"Incorrect API key","type":"invalid_request_error"}}
    );
    try std.testing.expectEqual(p, .ignore);
}

test "extract splits think from answer" {
    const body =
        \\data: {"type":"response.reasoning_summary_text.delta","delta":"plan"}
        \\
        \\data: {"type":"response.output_text.delta","delta":"pong"}
        \\
    ;
    const got = extract(.openai_responses, body);
    try std.testing.expectEqualStrings("pong", got.text);
    try std.testing.expectEqualStrings("plan", got.think);
}

test "jsonAtom accepts string or number tabId" {
    try std.testing.expectEqualStrings("12", jsonAtom("{\"tabId\":12}", "tabId").?);
    try std.testing.expectEqualStrings("12", jsonAtom("{\"tabId\":\"12\"}", "tabId").?);
}

test "cached prompt tokens count toward the window" {
    // The shape that made the old count wrong: one input token, and the whole
    // conversation sitting in the cache.
    const cached = usageOf(
        \\{"usage":{"input_tokens":1,"cache_read_input_tokens":190000,"cache_creation_input_tokens":4000,"output_tokens":500}}
    ).?;
    try std.testing.expectEqual(@as(u32, 190_000), cached.cache_read);
    try std.testing.expectEqual(@as(u32, 4_000), cached.cache_write);
    try std.testing.expectEqual(@as(u32, 194_501), cached.total());

    // OpenAI spells the cached half `cached_tokens` inside prompt details.
    const openai = usageOf(
        \\{"usage":{"prompt_tokens":1000,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":800}}}
    ).?;
    try std.testing.expectEqual(@as(u32, 800), openai.cache_read);
}

test "usage is read from every wire spelling" {
    const compat = usageOf(
        \\{"usage":{"prompt_tokens":120,"completion_tokens":45}}
    ).?;
    try std.testing.expectEqual(@as(u32, 120), compat.input);
    try std.testing.expectEqual(@as(u32, 45), compat.output);

    const responses = usageOf(
        \\{"usage":{"input_tokens":7,"output_tokens":9}}
    ).?;
    try std.testing.expectEqual(@as(u32, 7), responses.input);
    try std.testing.expectEqual(@as(u32, 9), responses.output);
    try std.testing.expectEqual(@as(u32, 16), responses.total());

    // Anthropic's message_delta carries output only.
    const delta = usageOf(
        \\{"type":"message_delta","usage":{"output_tokens":33}}
    ).?;
    try std.testing.expectEqual(@as(u32, 0), delta.input);
    try std.testing.expectEqual(@as(u32, 33), delta.output);

    // Anything without usage stays null rather than reporting zero.
    try std.testing.expect(usageOf("{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}") == null);
    try std.testing.expect(usageOf("{\"usage\":null}") == null);
}

test "merge keeps the highest count each side reported" {
    var u = Usage{};
    u.merge(.{ .input = 100, .output = 5 });
    u.merge(.{ .input = 0, .output = 40 });
    // A later event with no input must not wipe the input already counted.
    try std.testing.expectEqual(@as(u32, 100), u.input);
    try std.testing.expectEqual(@as(u32, 40), u.output);
    try std.testing.expectEqual(@as(u32, 140), u.total());
}

test "a usage event is classified as usage, not ignored" {
    const compat = parseOpenAiData(
        \\{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}
    );
    switch (compat) {
        .usage => |u| try std.testing.expectEqual(@as(u32, 12), u.total()),
        else => return error.UsageEventDropped,
    }
    const anth = parseAnthropicData(
        \\{"type":"message_delta","usage":{"output_tokens":8}}
    );
    switch (anth) {
        .usage => |u| try std.testing.expectEqual(@as(u32, 8), u.output),
        else => return error.UsageEventDropped,
    }
    // A normal delta is still text.
    switch (parseOpenAiData("{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}")) {
        .text => |t| try std.testing.expectEqualStrings("hi", t),
        else => return error.TextEventLost,
    }
}
