const std = @import("std");
const Io = std.Io;

pub const max_redirect_hops: usize = 10;

pub fn isRedirectStatus(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

pub fn joinLocation(allocator: std.mem.Allocator, current: []const u8, location: []const u8) ![]u8 {
    const loc = std.mem.trim(u8, location, " \t");
    if (std.mem.startsWith(u8, loc, "https://") or std.mem.startsWith(u8, loc, "http://")) {
        return allocator.dupe(u8, loc);
    }
    const scheme_end = std.mem.indexOf(u8, current, "://") orelse return error.InvalidUrl;
    const after = current[scheme_end + 3 ..];
    const host_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const origin = current[0 .. scheme_end + 3 + host_end];
    if (loc.len > 0 and loc[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, loc });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ origin, loc });
}

pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(originOf(a), originOf(b));
}

fn originOf(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const after = url[scheme_end + 3 ..];
    const host_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    return url[0 .. scheme_end + 3 + host_end];
}

pub const scrape_cap: usize = 12_000;
pub const fetch_cap: usize = 24_000;

pub fn fetch(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) {
        return error.InvalidUrl;
    }
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var loc_buf: [4096]u8 = undefined;
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .redirect_buffer = &loc_buf,
        .redirect_behavior = @enumFromInt(max_redirect_hops),
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "fetch failed: {s}", .{@errorName(err)});
    };
    const status: u16 = @intFromEnum(result.status);
    const raw = aw.written();
    if (status < 200 or status >= 300) {
        return std.fmt.allocPrint(allocator, "http {d}: {s}", .{ status, raw[0..@min(raw.len, 200)] });
    }
    const body = raw[0..@min(raw.len, fetch_cap)];
    if (looksHtml(body)) {
        // Raw markup is rarely useful in context; point at scrape and keep a short prefix.
        const prefix = body[0..@min(body.len, 1_500)];
        return std.fmt.allocPrint(allocator, "URL: {s}\nkind: html ({d} bytes; prefer web_scrape for readable text)\n\n{s}\n", .{ url, raw.len, prefix });
    }
    return std.fmt.allocPrint(allocator, "URL: {s}\nkind: text ({d} bytes)\n\n{s}", .{ url, body.len, body });
}

/// Fetch a URL and return readable main text (nav/chrome stripped).
pub fn scrape(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) {
        return error.InvalidUrl;
    }
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var loc_buf: [4096]u8 = undefined;
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .redirect_buffer = &loc_buf,
        .redirect_behavior = @enumFromInt(max_redirect_hops),
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "scrape failed: {s}", .{@errorName(err)});
    };
    const status: u16 = @intFromEnum(result.status);
    const raw = aw.written();
    if (status < 200 or status >= 300) {
        return std.fmt.allocPrint(allocator, "http {d}: {s}", .{ status, raw[0..@min(raw.len, 200)] });
    }
    if (!looksHtml(raw)) {
        const body = raw[0..@min(raw.len, scrape_cap)];
        return std.fmt.allocPrint(allocator, "Title: (none)\nURL: {s}\n\n{s}", .{ url, body });
    }
    return readablePage(allocator, url, raw);
}

fn looksHtml(body: []const u8) bool {
    const head = body[0..@min(body.len, 512)];
    if (std.ascii.indexOfIgnoreCase(head, "<html") != null) return true;
    if (std.ascii.indexOfIgnoreCase(head, "<!doctype html") != null) return true;
    if (std.ascii.indexOfIgnoreCase(head, "<head") != null) return true;
    if (std.ascii.indexOfIgnoreCase(head, "<body") != null) return true;
    return false;
}

fn readablePage(allocator: std.mem.Allocator, url: []const u8, html: []const u8) ![]u8 {
    const title = try extractTitle(allocator, html);
    defer allocator.free(title);
    const region = mainRegion(html);
    const body = try htmlToText(allocator, region);
    defer allocator.free(body);
    const clipped = body[0..@min(body.len, scrape_cap)];
    return std.fmt.allocPrint(allocator, "Title: {s}\nURL: {s}\n\n{s}", .{
        if (title.len > 0) title else "(none)",
        url,
        clipped,
    });
}

fn extractTitle(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const open = std.ascii.indexOfIgnoreCase(html, "<title") orelse return allocator.dupe(u8, "");
    const gt = std.mem.indexOfScalarPos(u8, html, open, '>') orelse return allocator.dupe(u8, "");
    const start = gt + 1;
    const close = std.ascii.indexOfIgnoreCase(html[start..], "</title>") orelse return allocator.dupe(u8, "");
    return collapseWs(allocator, html[start .. start + close], 160);
}

fn mainRegion(html: []const u8) []const u8 {
    if (taggedRegion(html, "article")) |r| return r;
    if (taggedRegion(html, "main")) |r| return r;
    // role="main"
    if (std.ascii.indexOfIgnoreCase(html, "role=\"main\"")) |at| {
        const open = std.mem.lastIndexOfScalar(u8, html[0..at], '<') orelse 0;
        if (std.mem.indexOfScalarPos(u8, html, at, '>')) |gt| {
            const start = gt + 1;
            // crude: until next landmark close is hard; take a generous slice
            return html[start..@min(html.len, start + 80_000)];
        }
        _ = open;
    }
    if (taggedRegion(html, "body")) |r| return r;
    return html;
}

fn taggedRegion(html: []const u8, name: []const u8) ?[]const u8 {
    var open_pat: [24]u8 = undefined;
    if (name.len + 1 > open_pat.len) return null;
    open_pat[0] = '<';
    @memcpy(open_pat[1..][0..name.len], name);
    const open_s = open_pat[0 .. name.len + 1];
    const open_at = std.ascii.indexOfIgnoreCase(html, open_s) orelse return null;
    // must be <name or <name ...>
    const after = open_at + open_s.len;
    if (after < html.len and std.ascii.isAlphanumeric(html[after])) return null;
    const gt = std.mem.indexOfScalarPos(u8, html, open_at, '>') orelse return null;
    const start = gt + 1;
    var close_pat: [24]u8 = undefined;
    close_pat[0] = '<';
    close_pat[1] = '/';
    @memcpy(close_pat[2..][0..name.len], name);
    close_pat[2 + name.len] = '>';
    const close_s = close_pat[0 .. name.len + 3];
    const close_rel = std.ascii.indexOfIgnoreCase(html[start..], close_s) orelse return html[start..];
    return html[start .. start + close_rel];
}

fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var skip_depth: usize = 0;
    var last_space = true;
    var newline_run: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse html.len;
            const tag = html[i + 1 .. end];
            const name_start: usize = if (tag.len > 0 and tag[0] == '/') 1 else 0;
            var name_end = name_start;
            while (name_end < tag.len and std.ascii.isAlphanumeric(tag[name_end])) name_end += 1;
            const name = tag[name_start..name_end];
            const closing = name_start == 1;
            if (isSkipTag(name)) {
                if (closing) {
                    if (skip_depth > 0) skip_depth -= 1;
                } else if (tag.len > 0 and tag[tag.len - 1] != '/') {
                    skip_depth += 1;
                }
            } else if (skip_depth == 0 and isBlockTag(name)) {
                if (!last_space or newline_run < 2) {
                    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                        try out.append(allocator, '\n');
                        newline_run += 1;
                        last_space = true;
                    }
                }
            }
            i = if (end < html.len) end + 1 else html.len;
            continue;
        }
        if (skip_depth > 0) {
            i += 1;
            continue;
        }
        if (html[i] == '&') {
            const decoded = decodeEntity(html[i..]);
            if (decoded.len > 0) {
                for (decoded.bytes[0..decoded.len]) |c| {
                    if (std.ascii.isWhitespace(c)) {
                        if (!last_space) {
                            try out.append(allocator, ' ');
                            last_space = true;
                            newline_run = 0;
                        }
                    } else {
                        try out.append(allocator, c);
                        last_space = false;
                        newline_run = 0;
                    }
                }
                i += decoded.skip;
                continue;
            }
        }
        const c = html[i];
        if (std.ascii.isWhitespace(c)) {
            if (!last_space) {
                try out.append(allocator, ' ');
                last_space = true;
                newline_run = 0;
            }
        } else if (c >= 0x20) {
            try out.append(allocator, c);
            last_space = false;
            newline_run = 0;
        }
        i += 1;
        if (out.items.len >= scrape_cap + 512) break;
    }
    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

fn collapseWs(allocator: std.mem.Allocator, raw: []const u8, cap: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_space = true;
    for (raw) |c| {
        if (c == '<') break; // stop if nested junk
        if (std.ascii.isWhitespace(c)) {
            if (!last_space and out.items.len < cap) {
                try out.append(allocator, ' ');
                last_space = true;
            }
            continue;
        }
        if (out.items.len >= cap) break;
        try out.append(allocator, c);
        last_space = false;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(allocator);
}

fn isSkipTag(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "script") or
        std.ascii.eqlIgnoreCase(name, "style") or
        std.ascii.eqlIgnoreCase(name, "noscript") or
        std.ascii.eqlIgnoreCase(name, "svg") or
        std.ascii.eqlIgnoreCase(name, "template") or
        std.ascii.eqlIgnoreCase(name, "nav") or
        std.ascii.eqlIgnoreCase(name, "header") or
        std.ascii.eqlIgnoreCase(name, "footer") or
        std.ascii.eqlIgnoreCase(name, "aside") or
        std.ascii.eqlIgnoreCase(name, "form") or
        std.ascii.eqlIgnoreCase(name, "iframe") or
        std.ascii.eqlIgnoreCase(name, "button") or
        std.ascii.eqlIgnoreCase(name, "input") or
        std.ascii.eqlIgnoreCase(name, "select") or
        std.ascii.eqlIgnoreCase(name, "option") or
        std.ascii.eqlIgnoreCase(name, "label");
}

fn isBlockTag(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "p") or
        std.ascii.eqlIgnoreCase(name, "div") or
        std.ascii.eqlIgnoreCase(name, "br") or
        std.ascii.eqlIgnoreCase(name, "li") or
        std.ascii.eqlIgnoreCase(name, "h1") or
        std.ascii.eqlIgnoreCase(name, "h2") or
        std.ascii.eqlIgnoreCase(name, "h3") or
        std.ascii.eqlIgnoreCase(name, "h4") or
        std.ascii.eqlIgnoreCase(name, "tr") or
        std.ascii.eqlIgnoreCase(name, "section") or
        std.ascii.eqlIgnoreCase(name, "article") or
        std.ascii.eqlIgnoreCase(name, "blockquote") or
        std.ascii.eqlIgnoreCase(name, "pre");
}

const Entity = struct { bytes: [8]u8, len: usize, skip: usize };

fn decodeEntity(s: []const u8) Entity {
    if (s.len < 3 or s[0] != '&') return .{ .bytes = undefined, .len = 0, .skip = 0 };
    const end = std.mem.indexOfScalarPos(u8, s, 1, ';') orelse return .{ .bytes = undefined, .len = 0, .skip = 0 };
    if (end > 10) return .{ .bytes = undefined, .len = 0, .skip = 0 };
    const name = s[1..end];
    var out: Entity = .{ .bytes = undefined, .len = 0, .skip = end + 1 };
    const ch: ?u8 = if (std.mem.eql(u8, name, "amp"))
        '&'
    else if (std.mem.eql(u8, name, "lt"))
        '<'
    else if (std.mem.eql(u8, name, "gt"))
        '>'
    else if (std.mem.eql(u8, name, "quot"))
        '"'
    else if (std.mem.eql(u8, name, "apos") or std.mem.eql(u8, name, "#39"))
        '\''
    else if (std.mem.eql(u8, name, "nbsp"))
        ' '
    else
        null;
    if (ch) |c| {
        out.bytes[0] = c;
        out.len = 1;
        return out;
    }
    return .{ .bytes = undefined, .len = 0, .skip = 0 };
}

test "htmlToText drops scripts and keeps body words" {
    const html =
        \\<html><head><title>Hi</title><script>evil()</script><style>.x{}</style></head>
        \\<body><nav>skip</nav><article><h1>Title</h1><p>Hello&nbsp;world &amp; zig.</p></article></body></html>
    ;
    const text = try htmlToText(std.testing.allocator, mainRegion(html));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "evil") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skip") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello world & zig.") != null);
}

test "readablePage includes title and url" {
    const html =
        \\<html><head><title>Example Domain</title></head>
        \\<body><h1>Example Domain</h1><p>This domain is for use in documentation.</p></body></html>
    ;
    const page = try readablePage(std.testing.allocator, "https://example.com/", html);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.startsWith(u8, page, "Title: Example Domain\nURL: https://example.com/\n"));
    try std.testing.expect(std.mem.indexOf(u8, page, "documentation") != null);
}

test "reject non http" {
    try std.testing.expectError(error.InvalidUrl, fetch(std.testing.allocator, std.testing.io, "file:///etc/passwd"));
}

test "303 See Other is a redirect status" {
    try std.testing.expect(isRedirectStatus(303));
    try std.testing.expect(isRedirectStatus(302));
    try std.testing.expect(isRedirectStatus(301));
    try std.testing.expect(isRedirectStatus(307));
    try std.testing.expect(!isRedirectStatus(200));
}

test "joinLocation resolves relative 303 targets" {
    const abs = try joinLocation(std.testing.allocator, "https://example.com/start", "https://example.com/next");
    defer std.testing.allocator.free(abs);
    try std.testing.expectEqualStrings("https://example.com/next", abs);

    const rel = try joinLocation(std.testing.allocator, "https://example.com/start", "/next");
    defer std.testing.allocator.free(rel);
    try std.testing.expectEqualStrings("https://example.com/next", rel);
}

test "same-origin rejects cross-host" {
    try std.testing.expect(sameOrigin("https://example.com/a", "https://example.com/next"));
    try std.testing.expect(!sameOrigin("https://example.com/a", "https://example.org/next"));
}
