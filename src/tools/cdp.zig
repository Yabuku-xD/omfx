const std = @import("std");
const Io = std.Io;
const web = @import("web.zig");
const relay = @import("relay.zig");
const sse = @import("../providers/sse.zig");

/// Localhost only (SSRF gate). Chrome 136+ default profile: use the relay.
pub fn isLocalhost(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://127.0.0.1:") or
        std.mem.startsWith(u8, url, "http://localhost:") or
        std.mem.startsWith(u8, url, "http://[::1]:");
}

pub fn listUrl(allocator: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/json/list", .{port});
}

fn getLocal(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    if (!isLocalhost(url)) {
        return allocator.dupe(u8, "cdp: denied (not localhost); not a clean verdict\n");
    }
    return web.fetchLocal(allocator, io, url) catch {
        return allocator.dupe(u8, "cdp: unavailable; not a clean verdict\n");
    };
}

pub fn list(allocator: std.mem.Allocator, io: Io, port: u16) ![]u8 {
    const url = try listUrl(allocator, port);
    defer allocator.free(url);
    const body = try getLocal(allocator, io, url);
    defer allocator.free(body);
    if (std.mem.indexOf(u8, body, "unavailable") != null or std.mem.indexOf(u8, body, "denied") != null) {
        return allocator.dupe(u8, body);
    }
    if (std.mem.indexOf(u8, body, "fetch failed") != null or std.mem.startsWith(u8, body, "http ")) {
        return std.fmt.allocPrint(
            allocator,
            "cdp: unavailable (nothing on 127.0.0.1:{d}); not a clean verdict\n",
            .{port},
        );
    }
    const clip = body[0..@min(body.len, 8_000)];
    return std.fmt.allocPrint(allocator, "cdp: tabs\n{s}", .{clip});
}

fn postJson(allocator: std.mem.Allocator, io: Io, url: []const u8, payload: []const u8) ![]u8 {
    if (!isLocalhost(url)) {
        return allocator.dupe(u8, "cdp: denied (not localhost); not a clean verdict\n");
    }
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &aw.writer,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "cdp: unavailable ({s}); not a clean verdict\n", .{@errorName(err)});
    };
    const status: u16 = @intFromEnum(result.status);
    const raw = aw.written();
    if (status < 200 or status >= 300) {
        return std.fmt.allocPrint(allocator, "cdp: http {d}; not a clean verdict\n", .{status});
    }
    return allocator.dupe(u8, raw[0..@min(raw.len, 8_000)]);
}

fn rpc(allocator: std.mem.Allocator, io: Io, port: u16, payload: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/rpc", .{port});
    defer allocator.free(url);
    return postJson(allocator, io, url, payload);
}

/// Prefer the extension relay (9224), then Chrome's own 9222.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    args_json: []const u8,
    port: u16,
) ![]u8 {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = args_arena.allocator();
    const action = sse.argString(args, args_json, "action") orelse "list";
    const relay_port = if (port == 0) relay.default_port else port;
    relay.ensure(allocator, io, relay_port);
    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "tabs")) {
        const a = try list(allocator, io, relay_port);
        if (std.mem.indexOf(u8, a, "unavailable") == null) return a;
        allocator.free(a);
        if (relay_port != 9222) return list(allocator, io, 9222);
        return allocator.dupe(u8, "cdp: unavailable (load the omfx browser-relay extension, run omfx browser-relay); not a clean verdict\n");
    }
    if (std.mem.eql(u8, action, "eval")) {
        const expr = sse.argString(args, args_json, "expression") orelse sse.argString(args, args_json, "js") orelse {
            return allocator.dupe(u8, "cdp: eval needs expression; not a clean verdict\n");
        };
        const tab_s = sse.jsonAtom(args_json, "tabId") orelse {
            return allocator.dupe(u8, "cdp: eval needs tabId from list; not a clean verdict\n");
        };
        const enc = try encodeJsonString(allocator, expr);
        defer allocator.free(enc);
        const attach = try std.fmt.allocPrint(allocator, "{{\"op\":\"attach\",\"tabId\":{s}}}", .{tab_s});
        defer allocator.free(attach);
        const attached = try rpc(allocator, io, relay_port, attach);
        allocator.free(attached);
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"op\":\"send\",\"tabId\":{s},\"method\":\"Runtime.evaluate\",\"params\":{{\"expression\":{s},\"returnByValue\":true}}}}",
            .{ tab_s, enc },
        );
        defer allocator.free(payload);
        return rpc(allocator, io, relay_port, payload);
    }
    if (std.mem.eql(u8, action, "navigate")) {
        const url = sse.argString(args, args_json, "url") orelse {
            return allocator.dupe(u8, "cdp: navigate needs url; not a clean verdict\n");
        };
        const tab_s = sse.jsonAtom(args_json, "tabId") orelse {
            return allocator.dupe(u8, "cdp: navigate needs tabId from list; not a clean verdict\n");
        };
        const enc = try encodeJsonString(allocator, url);
        defer allocator.free(enc);
        const attach = try std.fmt.allocPrint(allocator, "{{\"op\":\"attach\",\"tabId\":{s}}}", .{tab_s});
        defer allocator.free(attach);
        const attached = try rpc(allocator, io, relay_port, attach);
        allocator.free(attached);
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"op\":\"send\",\"tabId\":{s},\"method\":\"Page.navigate\",\"params\":{{\"url\":{s}}}}}",
            .{ tab_s, enc },
        );
        defer allocator.free(payload);
        return rpc(allocator, io, relay_port, payload);
    }
    if (std.mem.eql(u8, action, "create")) {
        const url = sse.argString(args, args_json, "url") orelse "about:blank";
        const enc = try encodeJsonString(allocator, url);
        defer allocator.free(enc);
        const payload = try std.fmt.allocPrint(allocator, "{{\"op\":\"createTab\",\"url\":{s}}}", .{enc});
        defer allocator.free(payload);
        return rpc(allocator, io, relay_port, payload);
    }
    return std.fmt.allocPrint(allocator, "cdp: unknown action {s}; not a clean verdict\n", .{action});
}

fn encodeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

test "cdp url is localhost" {
    const u = try listUrl(std.testing.allocator, 9224);
    defer std.testing.allocator.free(u);
    try std.testing.expect(isLocalhost(u));
    try std.testing.expect(!isLocalhost("http://example.com/json/list"));
}

test "missing chrome is not a clean verdict" {
    const s = try list(std.testing.allocator, std.testing.io, 1);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean verdict") != null);
}

test "eval without expression is honest" {
    const s = try run(std.testing.allocator, std.testing.io, "{\"action\":\"eval\"}", 9224);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "expression") != null);
}

test "eval without tabId is honest" {
    const s = try run(std.testing.allocator, std.testing.io, "{\"action\":\"eval\",\"expression\":\"1+1\"}", 9224);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "tabId") != null);
}

test "eval expression unescapes json newlines" {
    const json = "{\"action\":\"eval\",\"expression\":\"1\\n2\"}";
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("1\n2", sse.argStringInto(&buf, json, "expression").?);
}

test "numeric tabId is not dropped" {
    const s = try run(std.testing.allocator, std.testing.io, "{\"action\":\"eval\",\"expression\":\"1\",\"tabId\":7}", 1);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "needs tabId") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "unavailable") != null);
}
