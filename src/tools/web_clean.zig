//! Shared cleanup for web tool output: tracking-stripped URLs, capped snippets,
//! deduped hits, and source-numbered blocks the model can cite.

const std = @import("std");

pub const max_hits: usize = 8;
pub const max_snippet: usize = 280;
pub const max_title: usize = 120;

pub const Hit = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    snippet: []const u8 = "",
};

/// Drop common tracking query params; leave the path and useful query alone.
pub fn cleanUrl(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    const qmark = std.mem.indexOfScalar(u8, trimmed, '?') orelse return allocator.dupe(u8, trimmed);
    const base = trimmed[0..qmark];
    const query = trimmed[qmark + 1 ..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, base);
    var first = true;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const key = if (std.mem.indexOfScalar(u8, pair, '=')) |eq| pair[0..eq] else pair;
        if (isTrackingKey(key)) continue;
        if (first) {
            try out.append(allocator, '?');
            first = false;
        } else {
            try out.append(allocator, '&');
        }
        try out.appendSlice(allocator, pair);
    }
    return out.toOwnedSlice(allocator);
}

fn isTrackingKey(key: []const u8) bool {
    const lower_buf_len = 48;
    var buf: [lower_buf_len]u8 = undefined;
    if (key.len > lower_buf_len) return false;
    for (key, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const k = buf[0..key.len];
    return std.mem.eql(u8, k, "utm_source") or
        std.mem.eql(u8, k, "utm_medium") or
        std.mem.eql(u8, k, "utm_campaign") or
        std.mem.eql(u8, k, "utm_term") or
        std.mem.eql(u8, k, "utm_content") or
        std.mem.eql(u8, k, "gclid") or
        std.mem.eql(u8, k, "fbclid") or
        std.mem.eql(u8, k, "mc_cid") or
        std.mem.eql(u8, k, "mc_eid") or
        std.mem.eql(u8, k, "ref") or
        std.mem.startsWith(u8, k, "utm_");
}

pub fn cleanText(allocator: std.mem.Allocator, raw: []const u8, cap: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_space = true;
    for (raw) |c| {
        if (c == '\r') continue;
        if (c == '\n' or c == '\t' or c == ' ') {
            if (!last_space and out.items.len < cap) {
                try out.append(allocator, ' ');
                last_space = true;
            }
            continue;
        }
        if (c < 0x20) continue;
        if (out.items.len >= cap) break;
        try out.append(allocator, c);
        last_space = false;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(allocator);
}

fn urlKey(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.startsWith(u8, s, "https://")) s = s[8..] else if (std.mem.startsWith(u8, s, "http://")) s = s[7..];
    if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
    if (std.mem.indexOfScalar(u8, s, '#')) |h| s = s[0..h];
    if (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

pub fn sameHit(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(urlKey(a), urlKey(b));
}

/// Source-numbered blocks: title, URL, snippet. Snippets are data, not instructions.
pub fn formatHits(
    allocator: std.mem.Allocator,
    provider: []const u8,
    query: []const u8,
    hits: []const Hit,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[");
    try out.appendSlice(allocator, provider);
    try out.appendSlice(allocator, "] ");
    const q = try cleanText(allocator, query, 160);
    defer allocator.free(q);
    try out.appendSlice(allocator, q);
    try out.appendSlice(allocator, "\n");
    if (hits.len == 0) {
        try out.appendSlice(allocator, "(no results)\n");
        return out.toOwnedSlice(allocator);
    }
    for (hits, 0..) |hit, i| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.print(allocator, "{d}. ", .{i + 1});
        const title = if (hit.title.len > 0) hit.title else hit.url;
        try line.appendSlice(allocator, title);
        try line.append(allocator, '\n');
        try line.appendSlice(allocator, "   ");
        try line.appendSlice(allocator, hit.url);
        try line.append(allocator, '\n');
        if (hit.snippet.len > 0) {
            try line.appendSlice(allocator, "   ");
            try line.appendSlice(allocator, hit.snippet);
            try line.append(allocator, '\n');
        }
        try out.appendSlice(allocator, line.items);
    }
    return out.toOwnedSlice(allocator);
}

/// Pull title/url/snippet objects out of JSON SERP bodies.
pub fn hitsFromJson(allocator: std.mem.Allocator, body: []const u8, limit: usize) ![]Hit {
    var list: std.ArrayList(Hit) = .empty;
    errdefer {
        for (list.items) |h| freeHit(allocator, h);
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (list.items.len < limit and i < body.len) {
        const u_key = std.mem.indexOfPos(u8, body, i, "\"url\"") orelse
            std.mem.indexOfPos(u8, body, i, "\"href\"") orelse
            std.mem.indexOfPos(u8, body, i, "\"link\"") orelse break;
        const url_raw = jsonStringAfter(body, u_key) orelse {
            i = u_key + 5;
            continue;
        };
        if (!std.mem.startsWith(u8, url_raw, "http")) {
            i = u_key + 5;
            continue;
        }
        const window_start = if (u_key > 800) u_key - 800 else 0;
        const window_end = @min(body.len, u_key + 800);
        const window = body[window_start..window_end];
        const title_raw = jsonField(window, "title") orelse jsonField(window, "name") orelse "";
        const snip_raw = jsonField(window, "snippet") orelse
            jsonField(window, "description") orelse
            jsonField(window, "content") orelse
            jsonField(window, "text") orelse "";

        const url = try cleanUrl(allocator, url_raw);
        errdefer allocator.free(url);
        var dup = false;
        for (list.items) |prev| {
            if (sameHit(prev.url, url)) {
                dup = true;
                break;
            }
        }
        if (dup or isNoiseUrl(url)) {
            allocator.free(url);
            i = u_key + 5;
            continue;
        }
        const title = try cleanText(allocator, title_raw, max_title);
        errdefer allocator.free(title);
        const snippet = try cleanText(allocator, snip_raw, max_snippet);
        errdefer allocator.free(snippet);
        try list.append(allocator, .{ .title = title, .url = url, .snippet = snippet });
        i = u_key + 5;
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeHits(allocator: std.mem.Allocator, hits: []Hit) void {
    for (hits) |h| freeHit(allocator, h);
    allocator.free(hits);
}

fn freeHit(allocator: std.mem.Allocator, h: Hit) void {
    if (h.title.len > 0) allocator.free(h.title);
    if (h.url.len > 0) allocator.free(h.url);
    if (h.snippet.len > 0) allocator.free(h.snippet);
}

fn jsonField(window: []const u8, name: []const u8) ?[]const u8 {
    var key_buf: [32]u8 = undefined;
    if (name.len + 2 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1..][0..name.len], name);
    key_buf[1 + name.len] = '"';
    const key = key_buf[0 .. name.len + 2];
    const at = std.mem.indexOf(u8, window, key) orelse return null;
    return jsonStringAfter(window, at);
}

fn jsonStringAfter(s: []const u8, key_at: usize) ?[]const u8 {
    const after_key = s[key_at..];
    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var p = colon + 1;
    while (p < after_key.len and (after_key[p] == ' ' or after_key[p] == '\t' or after_key[p] == '\n')) p += 1;
    if (p >= after_key.len or after_key[p] != '"') return null;
    p += 1;
    const start = p;
    while (p < after_key.len) : (p += 1) {
        if (after_key[p] == '\\' and p + 1 < after_key.len) {
            p += 1;
            continue;
        }
        if (after_key[p] == '"') return after_key[start..p];
    }
    return null;
}

pub fn hitsFromHtml(allocator: std.mem.Allocator, body: []const u8, limit: usize) ![]Hit {
    var list: std.ArrayList(Hit) = .empty;
    errdefer {
        for (list.items) |h| freeHit(allocator, h);
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (list.items.len < limit and i < body.len) {
        const href_at = std.mem.indexOfPos(u8, body, i, "href=\"http") orelse
            std.mem.indexOfPos(u8, body, i, "href='http") orelse break;
        const quote = body[href_at + 5];
        const url_start = href_at + 6;
        const url_end = std.mem.indexOfScalarPos(u8, body, url_start, quote) orelse {
            i = href_at + 6;
            continue;
        };
        const url_raw = body[url_start..url_end];
        i = url_end + 1;
        if (isNoiseUrl(url_raw)) continue;
        const url = try cleanUrl(allocator, url_raw);
        errdefer allocator.free(url);
        var dup = false;
        for (list.items) |prev| {
            if (sameHit(prev.url, url)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            allocator.free(url);
            continue;
        }
        // Anchor text between > and </a>
        var title: []u8 = &.{};
        if (std.mem.indexOfPos(u8, body, url_end, ">")) |gt| {
            const t0 = gt + 1;
            if (std.mem.indexOfPos(u8, body, t0, "</a>") orelse std.mem.indexOfPos(u8, body, t0, "</A>")) |close| {
                if (close > t0 and close - t0 < 400) {
                    title = try stripTagsBrief(allocator, body[t0..close], max_title);
                }
            }
        }
        errdefer if (title.len > 0) allocator.free(title);
        try list.append(allocator, .{ .title = title, .url = url, .snippet = "" });
    }
    return list.toOwnedSlice(allocator);
}

fn stripTagsBrief(allocator: std.mem.Allocator, raw: []const u8, cap: usize) ![]u8 {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '<') {
            i = (std.mem.indexOfScalarPos(u8, raw, i + 1, '>') orelse raw.len - 1) + 1;
            continue;
        }
        try tmp.append(allocator, raw[i]);
        i += 1;
    }
    return cleanText(allocator, tmp.items, cap);
}

fn isNoiseUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "duckduckgo.com") != null or
        std.mem.indexOf(u8, url, "google.com/search") != null or
        std.mem.indexOf(u8, url, "google.com/url") != null or
        std.mem.indexOf(u8, url, "startpage.com") != null or
        std.mem.indexOf(u8, url, "bing.com/search") != null or
        std.mem.indexOf(u8, url, "javascript:") != null or
        std.mem.indexOf(u8, url, "/cdn-cgi/") != null;
}

test "cleanUrl drops utm params" {
    const u = try cleanUrl(std.testing.allocator, "https://ex.com/a?utm_source=x&id=1&gclid=zz");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("https://ex.com/a?id=1", u);
}

test "formatHits is source-numbered" {
    const hits = [_]Hit{
        .{ .title = "Zig", .url = "https://ziglang.org", .snippet = "A general-purpose language." },
    };
    const s = try formatHits(std.testing.allocator, "duckduckgo", "zig language", &hits);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "[duckduckgo] zig language") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "1. Zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "https://ziglang.org") != null);
}

test "hitsFromJson dedupes and reads title" {
    const body =
        \\{"results":[{"title":"One","url":"https://a.example/x?utm_source=t","snippet":"Alpha"},
        \\{"title":"Two","url":"https://a.example/x","description":"Beta"},
        \\{"title":"Three","url":"https://b.example/y","snippet":"Gamma"}]}
    ;
    const hits = try hitsFromJson(std.testing.allocator, body, 8);
    defer freeHits(std.testing.allocator, hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("One", hits[0].title);
    try std.testing.expectEqualStrings("https://a.example/x", hits[0].url);
    try std.testing.expectEqualStrings("Alpha", hits[0].snippet);
}
