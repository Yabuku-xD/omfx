const std = @import("std");
const pathing = @import("pathing.zig");
const Io = std.Io;

const log = std.log.scoped(.relay);

/// Chrome 136+ refuses --remote-debugging-port on the default profile;
/// the extension dials this loopback relay instead.
pub const default_port: u16 = 9224;
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const manifest_json = @embedFile("browser_relay/manifest.json");
pub const background_js = @embedFile("browser_relay/background.js");
pub const options_html = @embedFile("browser_relay/options.html");
pub const options_js = @embedFile("browser_relay/options.js");

pub fn installDir(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".omfx", "browser-relay", "extension" });
}

pub fn install(allocator: std.mem.Allocator, io: Io, home: []const u8) ![]u8 {
    const dir_path = try installDir(allocator, home);
    defer allocator.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    try writeAsset(io, dir_path, "manifest.json", manifest_json);
    try writeAsset(io, dir_path, "background.js", background_js);
    try writeAsset(io, dir_path, "options.html", options_html);
    try writeAsset(io, dir_path, "options.js", options_js);
    return std.fmt.allocPrint(
        allocator,
        "wrote {s}\n1. chrome://extensions -> Developer mode -> Load unpacked (or Reload if already loaded)\n2. In another terminal keep this running: omfx browser-relay\nThe extension badge turns on when that process is listening on 127.0.0.1:9224.\n",
        .{dir_path},
    );
}

fn writeAsset(io: Io, dir_path: []const u8, name: []const u8, body: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

/// RFC 6455 Sec-WebSocket-Accept.
pub fn wsAcceptKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var concat = try allocator.alloc(u8, key.len + ws_guid.len);
    defer allocator.free(concat);
    @memcpy(concat[0..key.len], key);
    @memcpy(concat[key.len..], ws_guid);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &digest, .{});
    var out: [28]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&out, &digest);
    return allocator.dupe(u8, encoded);
}

const Hub = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    allocator: std.mem.Allocator,
    tabs: []u8,
    ready: bool = false,
    next_id: u32 = 1,
    results: std.AutoHashMap(u32, []u8),
    ext_stream: ?Io.net.Stream = null,
    ext_io: Io,
    token: []const u8,

    fn init(allocator: std.mem.Allocator, io: Io, token: []const u8) Hub {
        return .{
            .allocator = allocator,
            .tabs = &.{},
            .results = .init(allocator),
            .ext_io = io,
            .token = token,
        };
    }

    fn deinit(self: *Hub) void {
        self.mutex.lockUncancelable(self.ext_io);
        defer self.mutex.unlock(self.ext_io);
        if (self.tabs.len > 0) self.allocator.free(self.tabs);
        var it = self.results.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.results.deinit();
    }
};

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r");
        if (line.len < name.len + 1) continue;
        if (!std.ascii.startsWithIgnoreCase(line, name)) continue;
        const rest = std.mem.trim(u8, line[name.len..], " :");
        return rest;
    }
    return null;
}

fn sendAll(stream: Io.net.Stream, io: Io, bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn wsWriteText(stream: Io.net.Stream, io: Io, payload: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x81;
    var n: usize = 2;
    if (payload.len < 126) {
        hdr[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        hdr[1] = 126;
        hdr[2] = @intCast(payload.len >> 8);
        hdr[3] = @intCast(payload.len & 0xff);
        n = 4;
    } else return error.FrameTooBig;
    var buf: [1024]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(hdr[0..n]);
    try w.interface.writeAll(payload);
    try w.interface.flush();
}

fn wsReadText(allocator: std.mem.Allocator, r: *Io.net.Stream.Reader) ![]u8 {
    const b0 = r.interface.takeByte() catch return error.EndOfStream;
    const b1 = r.interface.takeByte() catch return error.EndOfStream;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) != 0;
    var len: usize = b1 & 0x7f;
    if (len == 126) {
        const hi = r.interface.takeByte() catch return error.EndOfStream;
        const lo = r.interface.takeByte() catch return error.EndOfStream;
        len = (@as(usize, hi) << 8) | lo;
    } else if (len == 127) return error.FrameTooBig;
    if (len > 64_000) return error.FrameTooBig;
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            mask[i] = r.interface.takeByte() catch return error.EndOfStream;
        }
    }
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const b = r.interface.takeByte() catch return error.EndOfStream;
        payload[i] = if (masked) b ^ mask[i % 4] else b;
    }
    if (opcode == 0x8) {
        allocator.free(payload);
        return error.EndOfStream;
    }
    if (opcode == 0x9) {
        allocator.free(payload);
        return allocator.dupe(u8, "");
    }
    return payload;
}

fn httpOk(stream: Io.net.Stream, io: Io, content_type: []const u8, body: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{ content_type, body.len });
    try sendAll(stream, io, hdr);
    try sendAll(stream, io, body);
}

fn httpStatus(stream: Io.net.Stream, io: Io, code: u16, reason: []const u8, body: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {d} {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{ code, reason, body.len });
    try sendAll(stream, io, hdr);
    try sendAll(stream, io, body);
}

fn handleExtMessage(hub: *Hub, raw: []const u8) void {
    if (std.mem.indexOf(u8, raw, "\"t\":\"hello\"") != null) {
        const tabs = jsonArray(raw, "tabs") orelse "[]";
        hub.mutex.lockUncancelable(hub.ext_io);
        defer hub.mutex.unlock(hub.ext_io);
        if (hub.allocator.dupe(u8, tabs)) |copy| {
            if (hub.tabs.len > 0) hub.allocator.free(hub.tabs);
            hub.tabs = copy;
        } else |_| {}
        hub.ready = true;
        hub.cond.broadcast(hub.ext_io);
        return;
    }
    if (std.mem.indexOf(u8, raw, "\"t\":\"rpcResult\"") != null) {
        const id = jsonU32(raw, "id") orelse return;
        hub.mutex.lockUncancelable(hub.ext_io);
        defer hub.mutex.unlock(hub.ext_io);
        const copy = hub.allocator.dupe(u8, raw) catch return;
        hub.results.put(id, copy) catch {
            hub.allocator.free(copy);
            return;
        };
        hub.cond.broadcast(hub.ext_io);
        return;
    }
    if (std.mem.indexOf(u8, raw, "\"t\":\"ping\"") != null) {
        hub.mutex.lockUncancelable(hub.ext_io);
        defer hub.mutex.unlock(hub.ext_io);
        if (hub.ext_stream) |s| {
            wsWriteText(s, hub.ext_io, "{\"t\":\"pong\"}") catch |err| {
                log.debug("{s}", .{@errorName(err)});
            };
        }
    }
}

fn jsonArray(raw: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, raw, needle) orelse return null;
    const rest = raw[start + needle.len ..];
    const lb = std.mem.indexOfScalar(u8, rest, '[') orelse return null;
    var depth: usize = 0;
    var i = lb;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '[') depth += 1;
        if (rest[i] == ']') {
            depth -= 1;
            if (depth == 0) return rest[lb .. i + 1];
        }
    }
    return null;
}

fn jsonU32(raw: []const u8, key: []const u8) ?u32 {
    var needle_buf: [24]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, raw, needle) orelse return null;
    var i = start + needle.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
    var n: u32 = 0;
    var any = false;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {
        n = n * 10 + (raw[i] - '0');
        any = true;
    }
    if (!any) return null;
    return n;
}

const Conn = struct {
    stream: Io.net.Stream,
    io: Io,
    hub: *Hub,
    port: u16,
};

fn serveConn(c: Conn) void {
    defer c.stream.close(c.io);
    var rbuf: [4096]u8 = undefined;
    var reader = c.stream.reader(c.io, &rbuf);
    var head_buf: [8192]u8 = undefined;
    var head_n: usize = 0;
    while (true) {
        const b = reader.interface.takeByte() catch return;
        if (head_n >= head_buf.len) return;
        head_buf[head_n] = b;
        head_n += 1;
        if (head_n >= 4 and std.mem.endsWith(u8, head_buf[0..head_n], "\r\n\r\n")) break;
    }
    const req = head_buf[0..head_n];
    const first = std.mem.indexOf(u8, req, "\r\n") orelse return;
    const line = req[0..first];
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return;
    const target = it.next() orelse return;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "";

    const upgrade = headerValue(req, "upgrade") orelse "";
    if (std.ascii.eqlIgnoreCase(upgrade, "websocket") and std.mem.eql(u8, path, "/ext")) {
        if (c.hub.token.len > 0) {
            var want_buf: [80]u8 = undefined;
            const want = std.fmt.bufPrint(&want_buf, "token={s}", .{c.hub.token}) catch return;
            if (std.mem.indexOf(u8, query, want) == null) {
                httpStatus(c.stream, c.io, 401, "Unauthorized", "{\"error\":\"bad token\"}") catch |err| {
                    log.debug("{s}", .{@errorName(err)});
                };
                return;
            }
        }
        const origin = headerValue(req, "origin") orelse "";
        if (origin.len > 0 and !std.mem.startsWith(u8, origin, "chrome-extension://")) {
            httpStatus(c.stream, c.io, 403, "Forbidden", "{\"error\":\"origin\"}") catch |err| {
                log.debug("{s}", .{@errorName(err)});
            };
            return;
        }
        const key = headerValue(req, "sec-websocket-key") orelse return;
        c.hub.mutex.lockUncancelable(c.io);
        const accept = wsAcceptKey(c.hub.allocator, key) catch {
            c.hub.mutex.unlock(c.io);
            return;
        };
        c.hub.mutex.unlock(c.io);
        defer {
            c.hub.mutex.lockUncancelable(c.io);
            c.hub.allocator.free(accept);
            c.hub.mutex.unlock(c.io);
        }
        var up_buf: [256]u8 = undefined;
        const up = std.fmt.bufPrint(&up_buf, "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: {s}\r\n\r\n", .{accept}) catch return;
        sendAll(c.stream, c.io, up) catch return;
        c.hub.mutex.lockUncancelable(c.io);
        c.hub.ext_stream = c.stream;
        c.hub.ext_io = c.io;
        c.hub.mutex.unlock(c.io);
        while (true) {
            const msg = wsReadText(c.hub.allocator, &reader) catch break;
            defer c.hub.allocator.free(msg);
            if (msg.len == 0) continue;
            handleExtMessage(c.hub, msg);
        }
        c.hub.mutex.lockUncancelable(c.io);
        c.hub.ext_stream = null;
        c.hub.ready = false;
        c.hub.mutex.unlock(c.io);
        return;
    }

    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) {
        httpStatus(c.stream, c.io, 405, "Method Not Allowed", "{\"error\":\"method\"}") catch |err| {
            log.debug("{s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, path, "/json/version") or std.mem.eql(u8, path, "/json") or std.mem.eql(u8, path, "/json/list")) {
        c.hub.mutex.lockUncancelable(c.io);
        const ready = c.hub.ready;
        const tabs = c.hub.allocator.dupe(u8, c.hub.tabs) catch {
            c.hub.mutex.unlock(c.io);
            return;
        };
        c.hub.mutex.unlock(c.io);
        defer c.hub.allocator.free(tabs);
        if (!ready) {
            httpStatus(c.stream, c.io, 503, "Service Unavailable", "{\"error\":\"relay extension is not connected\"}") catch |err| {
                log.debug("{s}", .{@errorName(err)});
            };
            return;
        }
        if (std.mem.eql(u8, path, "/json/version")) {
            httpOk(c.stream, c.io, "application/json", "{\"Browser\":\"omfx-relay\",\"Protocol-Version\":\"1.3\"}") catch |err| {
                log.debug("{s}", .{@errorName(err)});
            };
            return;
        }
        const live = dispatchRpc(c.hub, "{\"op\":\"listTabs\"}") catch {
            const body = if (tabs.len > 0) tabs else "[]";
            httpOk(c.stream, c.io, "application/json", body) catch |err| {
                log.debug("{s}", .{@errorName(err)});
            };
            return;
        };
        defer c.hub.allocator.free(live);
        const extracted = jsonArray(live, "tabs") orelse (if (tabs.len > 0) tabs else "[]");
        httpOk(c.stream, c.io, "application/json", extracted) catch |err| {
            log.debug("{s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/rpc")) {
        if (c.hub.token.len > 0) {
            var want_buf: [80]u8 = undefined;
            const want = std.fmt.bufPrint(&want_buf, "token={s}", .{c.hub.token}) catch return;
            if (std.mem.indexOf(u8, query, want) == null) {
                httpStatus(c.stream, c.io, 401, "Unauthorized", "{\"error\":\"bad token\"}") catch |err| {
                    log.debug("{s}", .{@errorName(err)});
                };
                return;
            }
        }
        const clen_s = headerValue(req, "content-length") orelse "0";
        const clen = std.fmt.parseInt(usize, clen_s, 10) catch 0;
        c.hub.mutex.lockUncancelable(c.io);
        var body = c.hub.allocator.alloc(u8, clen) catch {
            c.hub.mutex.unlock(c.io);
            return;
        };
        c.hub.mutex.unlock(c.io);
        defer {
            c.hub.mutex.lockUncancelable(c.io);
            c.hub.allocator.free(body);
            c.hub.mutex.unlock(c.io);
        }
        var i: usize = 0;
        while (i < clen) : (i += 1) {
            body[i] = reader.interface.takeByte() catch 0;
        }
        const reply = dispatchRpc(c.hub, body) catch {
            httpStatus(c.stream, c.io, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"rpc failed\"}") catch |err| {
                log.debug("{s}", .{@errorName(err)});
            };
            return;
        };
        defer c.hub.allocator.free(reply);
        httpOk(c.stream, c.io, "application/json", reply) catch |err| {
            log.debug("{s}", .{@errorName(err)});
        };
        return;
    }

    httpStatus(c.stream, c.io, 404, "Not Found", "{\"error\":\"not found\"}") catch |err| {
        log.debug("{s}", .{@errorName(err)});
    };
}

fn dispatchRpc(hub: *Hub, body: []const u8) ![]u8 {
    if (body.len < 2 or body[0] != '{') return hub.allocator.dupe(u8, "{\"ok\":false,\"error\":\"bad json\"}");
    hub.mutex.lockUncancelable(hub.ext_io);
    const id = hub.next_id;
    hub.next_id += 1;
    const stream = hub.ext_stream;
    const io = hub.ext_io;
    hub.mutex.unlock(io);
    if (stream == null) return hub.allocator.dupe(u8, "{\"ok\":false,\"error\":\"extension not connected\"}");
    const framed = try std.fmt.allocPrint(hub.allocator, "{{\"t\":\"rpc\",\"id\":{d},{s}", .{ id, body[1..] });
    defer hub.allocator.free(framed);
    hub.mutex.lockUncancelable(io);
    wsWriteText(stream.?, io, framed) catch {
        hub.mutex.unlock(io);
        return hub.allocator.dupe(u8, "{\"ok\":false,\"error\":\"ws write\"}");
    };
    var spins: usize = 0;
    while (spins < 50) : (spins += 1) {
        if (hub.results.get(id)) |got| {
            _ = hub.results.remove(id);
            hub.mutex.unlock(io);
            return got;
        }
        hub.mutex.unlock(io);
        Io.sleep(io, .fromMilliseconds(200), .real) catch |err| {
            log.debug("{s}", .{@errorName(err)});
        };
        hub.mutex.lockUncancelable(io);
    }
    hub.mutex.unlock(io);
    return hub.allocator.dupe(u8, "{\"ok\":false,\"error\":\"timeout\"}");
}

/// True when something accepts TCP on the relay port. Used to be a full HTTP
/// GET to `/json/version`; a process that accepts and never replies hung
/// forever (`Io.Timeout = .none`) and made interactive start look blank.
pub fn listening(allocator: std.mem.Allocator, io: Io, port: u16) bool {
    _ = allocator;
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    // No connect timeout: Zig 0.16 Threaded Io panics on timed connect
    // ("TODO implement netConnectIpPosix with timeout"). ECONNREFUSED is
    // fast when the port is closed; a live accept returns immediately.
    const stream = addr.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

/// Spawn `omfx browser-relay` if nothing is on the port. No-op inside unit tests.
pub fn ensure(allocator: std.mem.Allocator, io: Io, port: u16) void {
    if (listening(allocator, io, port)) return;
    const exe = std.process.executablePathAlloc(io, allocator) catch return;
    defer allocator.free(exe);
    const base = std.fs.path.basename(exe);
    if (!std.mem.eql(u8, base, "omfx")) return;
    _ = std.process.spawn(io, .{
        .argv = &.{ exe, "browser-relay" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (listening(allocator, io, port)) return;
        Io.sleep(io, .fromMilliseconds(50), .real) catch |err| {
            log.debug("{s}", .{@errorName(err)});
        };
    }
}

pub fn serve(allocator: std.mem.Allocator, io: Io, port: u16, token: []const u8) !void {
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var hub = Hub.init(allocator, io, token);
    defer hub.deinit();
    while (true) {
        const stream = try server.accept(io);
        const conn = Conn{ .stream = stream, .io = io, .hub = &hub, .port = port };
        const t = try std.Thread.spawn(.{}, serveConn, .{conn});
        t.detach();
    }
}

test "ws accept key matches RFC 6455 sample" {
    const s = try wsAcceptKey(std.testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", s);
}

test "default relay port is 9224" {
    try std.testing.expectEqual(@as(u16, 9224), default_port);
}

test "listening is false when nothing is bound" {
    try std.testing.expect(!listening(std.testing.allocator, std.testing.io, 1));
}

test "embedded extension is omfx" {
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "omfx browser relay") != null);
    try std.testing.expect(std.mem.indexOf(u8, background_js, "/ext") != null);
}

test "install writes manifest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try pathing.testWorkspace(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(home);
    const msg = try install(std.testing.allocator, io, home);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "chrome://extensions") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "omfx browser-relay") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "127.0.0.1:9224") != null);
}

const test_port: u16 = 19224;

fn serveBg(io: Io) void {
    serve(std.heap.page_allocator, io, test_port, "") catch |err| {
        log.debug("{s}", .{@errorName(err)});
    };
}

fn wsMaskWrite(allocator: std.mem.Allocator, stream: Io.net.Stream, io: Io, payload: []const u8) !void {
    const mask = [_]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var hdr: [8]u8 = undefined;
    hdr[0] = 0x81;
    var n: usize = 2;
    if (payload.len < 126) {
        hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else {
        hdr[1] = 0x80 | 126;
        hdr[2] = @intCast(payload.len >> 8);
        hdr[3] = @intCast(payload.len & 0xff);
        n = 4;
    }
    const masked = try allocator.alloc(u8, payload.len);
    defer allocator.free(masked);
    for (payload, 0..) |b, i| masked[i] = b ^ mask[i % 4];
    try sendAll(stream, io, hdr[0..n]);
    try sendAll(stream, io, &mask);
    try sendAll(stream, io, masked);
}

const ExtLoop = struct { stream: Io.net.Stream, io: Io };

fn extLoop(el: ExtLoop) void {
    var rbuf: [4096]u8 = undefined;
    var reader = el.stream.reader(el.io, &rbuf);
    while (true) {
        const msg = wsReadText(std.heap.page_allocator, &reader) catch break;
        defer std.heap.page_allocator.free(msg);
        if (msg.len == 0) continue;
        const id = jsonU32(msg, "id") orelse continue;
        var buf: [256]u8 = undefined;
        const reply = std.fmt.bufPrint(&buf, "{{\"t\":\"rpcResult\",\"id\":{d},\"ok\":true,\"result\":{{\"tabs\":[{{\"tabId\":7,\"url\":\"https://example.com/\",\"title\":\"Example\"}}]}}}}", .{id}) catch continue;
        wsMaskWrite(std.heap.page_allocator, el.stream, el.io, reply) catch break;
    }
}

test "relay hello then list is live tabs" {
    const io = std.testing.io;
    const t = try std.Thread.spawn(.{}, serveBg, .{io});
    t.detach();
    var connected: ?Io.net.Stream = null;
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(test_port) };
        connected = addr.connect(io, .{ .mode = .stream }) catch {
            Io.sleep(io, .fromMilliseconds(50), .real) catch |err| {
                log.debug("{s}", .{@errorName(err)});
            };
            continue;
        };
        break;
    }
    var stream = connected orelse return error.RelayDidNotListen;
    const hs =
        "GET /ext HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Origin: chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef\r\n" ++
        "\r\n";
    try sendAll(stream, io, hs);
    var rbuf: [2048]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(std.testing.allocator);
    while (true) {
        const b = reader.interface.takeByte() catch return error.NoUpgrade;
        try head.append(std.testing.allocator, b);
        if (head.items.len >= 4 and std.mem.endsWith(u8, head.items, "\r\n\r\n")) break;
        if (head.items.len > 1500) return error.NoUpgrade;
    }
    try std.testing.expect(std.mem.indexOf(u8, head.items, "101") != null);
    const hello =
        \\{"t":"hello","userAgent":"test","browserVersion":"Chrome/1","tabs":[{"tabId":7,"url":"https://example.com/","title":"Example","active":true,"windowId":1,"pinned":false,"groupId":-1}],"attachedTabIds":[]}
    ;
    try wsMaskWrite(std.testing.allocator, stream, io, hello);
    const el = try std.Thread.spawn(.{}, extLoop, .{ExtLoop{ .stream = stream, .io = io }});
    el.detach();
    Io.sleep(io, .fromMilliseconds(150), .real) catch |err| {
        log.debug("{s}", .{@errorName(err)});
    };
    const web = @import("web.zig");
    const listed = try web.fetchLocal(std.testing.allocator, io, "http://127.0.0.1:19224/json/list");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "tabId") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "webSocketDebuggerUrl") == null);
}
