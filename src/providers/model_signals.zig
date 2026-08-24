const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.model_signals);
const config = @import("../core/config.zig");

pub const file_name = "model_signals.json";
const openrouter_url = "https://openrouter.ai/api/v1/models";
pub const max_body: usize = 8 * 1024 * 1024;
pub const max_entries: usize = 512;

pub const Price = struct {
    prompt: f64 = 0,
    completion: f64 = 0,
    context: u32 = 0,
};

const Entry = struct {
    id: [96]u8 = [_]u8{0} ** 96,
    id_len: usize = 0,
    price: Price = .{},

    fn idSlice(self: *const Entry) []const u8 {
        return self.id[0..self.id_len];
    }

    fn setId(self: *Entry, s: []const u8) void {
        const n = @min(s.len, self.id.len);
        @memcpy(self.id[0..n], s[0..n]);
        self.id_len = n;
    }
};

const Cache = struct {
    entries: [max_entries]Entry = undefined,
    n: usize = 0,
};

var loaded: Cache = .{ .n = 0 };

fn cachePath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const root = try config.profileRoot(allocator, home);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "cache", file_name });
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

fn floatField(obj: []const u8, key: []const u8) f64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return 0;
    const at = std.mem.indexOf(u8, obj, needle) orelse return 0;
    var i = at + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\n')) i += 1;
    if (i < obj.len and obj[i] == '"') {
        i += 1;
        const from = i;
        while (i < obj.len and obj[i] != '"') i += 1;
        if (i <= from) return 0;
        return std.fmt.parseFloat(f64, obj[from..i]) catch 0;
    }
    var j = i;
    while (j < obj.len and ((obj[j] >= '0' and obj[j] <= '9') or obj[j] == '.')) j += 1;
    if (j == i) return 0;
    return std.fmt.parseFloat(f64, obj[i..j]) catch 0;
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

fn objectAt(body: []const u8, from: usize) ?struct { start: usize, end: usize } {
    const start = std.mem.indexOfScalarPos(u8, body, from, '{') orelse return null;
    var depth: i32 = 0;
    for (body[start..], start..) |c, i| {
        switch (c) {
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

fn parseOpenRouter(body: []const u8, out: *Cache) void {
    out.n = 0;
    const key = std.mem.indexOf(u8, body, "\"data\"") orelse return;
    const rest = body[key..];
    const lb = std.mem.indexOfScalar(u8, rest, '[') orelse return;
    var at = key + lb + 1;
    while (objectAt(body, at)) |obj| {
        at = obj.end;
        const o = body[obj.start..obj.end];
        const id = stringField(o, "id");
        if (id.len == 0) continue;
        const pricing_at = std.mem.indexOf(u8, o, "\"pricing\"") orelse continue;
        const pricing = objectAt(o, pricing_at) orelse continue;
        const pobj = o[pricing.start..pricing.end];
        const prompt = floatField(pobj, "prompt");
        const completion = floatField(pobj, "completion");
        if (prompt == 0 and completion == 0) continue;
        if (out.n >= max_entries) return;
        const e = &out.entries[out.n];
        e.* = .{};
        e.setId(id);
        e.price = .{
            .prompt = prompt * 1_000_000,
            .completion = completion * 1_000_000,
            .context = numberField(o, "context_length"),
        };
        out.n += 1;
    }
}

fn writeCache(allocator: std.mem.Allocator, io: Io, home: []const u8, body: []const u8) void {
    const p = cachePath(allocator, home) catch return;
    defer allocator.free(p);
    const dir = std.fs.path.dirname(p) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.debug("mkdir {s}: {s}", .{ dir, @errorName(err) });
        return;
    };
    var f = Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch |err| {
        log.debug("open {s}: {s}", .{ p, @errorName(err) });
        return;
    };
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    w.interface.writeAll(body) catch {};
    w.interface.flush() catch {};
}

fn readCache(allocator: std.mem.Allocator, io: Io, home: []const u8) []u8 {
    const p = cachePath(allocator, home) catch return "";
    defer allocator.free(p);
    return Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_body)) catch "";
}

fn fetchOpenRouter(allocator: std.mem.Allocator, io: Io) []u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = openrouter_url },
        .method = .GET,
        .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .response_writer = &aw.writer,
    }) catch |err| {
        log.debug("openrouter fetch: {s}", .{@errorName(err)});
        return "";
    };
    if (@intFromEnum(result.status) != 200) {
        log.debug("openrouter fetch: http {d}", .{@intFromEnum(result.status)});
        return "";
    }
    if (aw.written().len > max_body) return "";
    return aw.toOwnedSlice() catch "";
}

fn cacheStale(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return true;
    const now = Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    const age = now - stat.mtime.toSeconds();
    return age > 7 * 24 * 3600;
}

pub fn ensure(allocator: std.mem.Allocator, io: Io, home: []const u8) void {
    const p = cachePath(allocator, home) catch return;
    defer allocator.free(p);

    var body = readCache(allocator, io, home);
    defer if (body.len > 0) allocator.free(body);

    if (body.len == 0 or cacheStale(io, p)) {
        const fresh = fetchOpenRouter(allocator, io);
        if (fresh.len != 0) {
            writeCache(allocator, io, home, fresh);
            allocator.free(body);
            body = fresh;
        } else if (body.len == 0) {
            return;
        }
    }

    var tmp: Cache = .{ .n = 0 };
    parseOpenRouter(body, &tmp);
    loaded = tmp;
}

fn normLower(dst: []u8, src: []const u8) []const u8 {
    const n = @min(src.len, dst.len);
    for (src[0..n], 0..) |c, i| dst[i] = std.ascii.toLower(c);
    return dst[0..n];
}

fn idsMatch(model_id: []const u8, entry_id: []const u8) bool {
    if (std.mem.eql(u8, model_id, entry_id)) return true;
    var a_buf: [128]u8 = undefined;
    var b_buf: [128]u8 = undefined;
    const a = normLower(&a_buf, model_id);
    const b = normLower(&b_buf, entry_id);
    if (std.mem.endsWith(u8, a, b) or std.mem.endsWith(u8, b, a)) return true;
    const slash = std.mem.lastIndexOfScalar(u8, b, '/') orelse return false;
    const tail = b[slash + 1 ..];
    return std.mem.endsWith(u8, a, tail) or std.mem.indexOf(u8, a, tail) != null;
}

pub fn priceFor(model_id: []const u8) ?Price {
    var best: ?Price = null;
    var best_len: usize = 0;
    for (loaded.entries[0..loaded.n]) |e| {
        if (!idsMatch(model_id, e.idSlice())) continue;
        const len = e.id_len;
        if (best == null or len > best_len) {
            best = e.price;
            best_len = len;
        }
    }
    return best;
}

pub fn benchTier(model_id: []const u8) f64 {
    var lower_buf: [96]u8 = undefined;
    const lower = normLower(&lower_buf, model_id);
    if (std.mem.indexOf(u8, lower, "opus") != null) return 92;
    if (std.mem.indexOf(u8, lower, "gpt-5.6") != null or std.mem.indexOf(u8, lower, "gpt-5.5") != null) return 90;
    if (std.mem.indexOf(u8, lower, "sonnet") != null) return 78;
    if (std.mem.indexOf(u8, lower, "codex") != null) return 85;
    if (std.mem.indexOf(u8, lower, "deepseek") != null) return 76;
    if (std.mem.indexOf(u8, lower, "flash") != null or std.mem.indexOf(u8, lower, "fast") != null) return 62;
    if (std.mem.indexOf(u8, lower, "mini") != null or std.mem.indexOf(u8, lower, "nano") != null) return 55;
    if (std.mem.indexOf(u8, lower, "haiku") != null) return 68;
    return 70;
}

test "parse openrouter pricing snippet" {
    const body =
        \\{"data":[{"id":"anthropic/claude-opus-4","context_length":200000,"pricing":{"prompt":"0.000015","completion":"0.000075"}}]}
    ;
    var c: Cache = .{ .n = 0 };
    parseOpenRouter(body, &c);
    try std.testing.expectEqual(@as(usize, 1), c.n);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4", c.entries[0].idSlice());
    try std.testing.expect(c.entries[0].price.prompt > 10);
    try std.testing.expectEqual(@as(u32, 200_000), c.entries[0].price.context);
}

test "priceFor matches omfx model ids" {
    loaded = .{ .n = 1 };
    loaded.entries[0].setId("anthropic/claude-opus-4");
    loaded.entries[0].price = .{ .prompt = 15, .completion = 75, .context = 200_000 };
    const p = priceFor("claude-opus-4-8").?;
    try std.testing.expectEqual(@as(f64, 15), p.prompt);
}
