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
    return allocator.dupe(u8, raw[0..@min(raw.len, 32_000)]);
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
