const std = @import("std");
const pathing = @import("../tools/pathing.zig");
const Io = std.Io;

const log = std.log.scoped(.playbook);

/// ACE: incremental items, never a rewritten paragraph. Catalog is names only.
pub const catalog_max: usize = 8;
pub const text_max: usize = 80;
pub const slug_max: usize = 24;
pub const max_items: usize = 64;
pub const skill_after: u32 = 2;

comptime {
    if (catalog_max == 0) @compileError("catalog_max must show at least one name");
    if (text_max == 0) @compileError("text_max must hold a lesson");
    if (skill_after < 2) @compileError("skill_after is two verified repeats");
}

pub const Kind = enum { helpful, harmful };

pub const Error = error{
    Empty,
    Full,
} || std.mem.Allocator.Error;

const Text = struct {
    bytes: [text_max]u8 = undefined,
    len: usize = 0,

    fn fromRaw(raw: []const u8) Text {
        var t = Text{};
        var space = true;
        for (raw) |c| {
            if (t.len >= text_max) break;
            if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') {
                if (!space) {
                    t.bytes[t.len] = ' ';
                    t.len += 1;
                    space = true;
                }
                continue;
            }
            if (c == ' ') {
                if (space) continue;
                space = true;
            } else space = false;
            t.bytes[t.len] = std.ascii.toLower(c);
            t.len += 1;
        }
        while (t.len > 0 and t.bytes[t.len - 1] == ' ') t.len -= 1;
        return t;
    }

    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    fn eql(self: Text, other: Text) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    fn slug(self: Text, buf: *[slug_max]u8) []const u8 {
        var n: usize = 0;
        var dash = false;
        for (self.slice()) |c| {
            if (n >= buf.len) break;
            if (std.ascii.isAlphanumeric(c)) {
                buf[n] = c;
                n += 1;
                dash = false;
            } else if (n > 0 and !dash) {
                buf[n] = '-';
                n += 1;
                dash = true;
            }
        }
        if (n > 0 and buf[n - 1] == '-') n -= 1;
        if (n == 0) {
            const fallback = "item";
            @memcpy(buf[0..fallback.len], fallback);
            return buf[0..fallback.len];
        }
        return buf[0..n];
    }
};

const Item = struct {
    kind: Kind,
    n: u32,
    text: Text,
};

pub fn path(allocator: std.mem.Allocator, workspace: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace, ".omfx", "playbook.jsonl" });
}

pub fn skillsDir(allocator: std.mem.Allocator, workspace: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace, ".omfx", "skills" });
}

pub fn slug(text: []const u8, buf: *[slug_max]u8) []const u8 {
    return Text.fromRaw(text).slug(buf);
}

fn parseLine(line: []const u8, item: *Item) bool {
    const raw = std.mem.trim(u8, line, " \t\r");
    if (raw.len == 0) return false;
    if (raw[0] == '{') return parseJson(raw, item);
    return parseTsv(raw, item);
}

fn parseTsv(raw: []const u8, item: *Item) bool {
    const sp1 = std.mem.indexOfScalar(u8, raw, ' ') orelse return false;
    item.kind = std.meta.stringToEnum(Kind, raw[0..sp1]) orelse return false;
    const rest = raw[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return false;
    var n: u32 = 0;
    for (rest[0..sp2]) |c| {
        if (c < '0' or c > '9') return false;
        n = n * 10 + (c - '0');
    }
    if (n == 0) n = 1;
    item.n = n;
    const ts = rest[sp2 + 1 ..];
    if (ts.len == 0) return false;
    item.text = Text.fromRaw(ts);
    return item.text.len > 0;
}

fn parseJson(raw: []const u8, item: *Item) bool {
    const kpos = std.mem.indexOf(u8, raw, "\"k\":\"") orelse return false;
    const k0 = kpos + "\"k\":\"".len;
    const k1 = std.mem.indexOfScalarPos(u8, raw, k0, '"') orelse return false;
    item.kind = std.meta.stringToEnum(Kind, raw[k0..k1]) orelse return false;
    const npos = std.mem.indexOf(u8, raw, "\"n\":") orelse return false;
    var i = npos + "\"n\":".len;
    while (i < raw.len and raw[i] == ' ') i += 1;
    var n: u32 = 0;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {
        n = n * 10 + (raw[i] - '0');
    }
    if (n == 0) n = 1;
    item.n = n;
    const tpos = std.mem.indexOf(u8, raw, ",\"t\":\"") orelse return false;
    const t0 = tpos + ",\"t\":\"".len;
    const t1 = std.mem.indexOfScalarPos(u8, raw, t0, '"') orelse return false;
    item.text = Text.fromRaw(raw[t0..t1]);
    return item.text.len > 0;
}

fn loadItems(text: []const u8, out: *[max_items]Item) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (n >= max_items) break;
        if (!parseLine(line, &out[n])) continue;
        n += 1;
    }
    return n;
}

fn byCountDesc(items: []const Item, a: usize, b: usize) bool {
    return items[a].n > items[b].n;
}

fn writeItems(allocator: std.mem.Allocator, io: Io, p: []const u8, items: []const Item) Error!void {
    const dir = std.fs.path.dirname(p) orelse return error.Empty;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
        return error.Empty;
    };
    var file = Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch |err| {
        log.warn("write {s}: {s}", .{ p, @errorName(err) });
        return error.Empty;
    };
    defer file.close(io);
    var buf: [512]u8 = undefined;
    var w = file.writer(io, &buf);
    for (items) |item| {
        const k = @tagName(item.kind);
        const line = try std.fmt.allocPrint(
            allocator,
            "{{\"k\":\"{s}\",\"n\":{d},\"t\":\"{s}\"}}\n",
            .{ k, item.n, item.text.slice() },
        );
        defer allocator.free(line);
        w.interface.writeAll(line) catch return error.Empty;
    }
    w.interface.flush() catch return error.Empty;
}

pub fn bump(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    kind: Kind,
    raw: []const u8,
) u32 {
    const t = Text.fromRaw(raw);
    if (t.len == 0) return 0;
    const p = path(allocator, workspace) catch return 0;
    defer allocator.free(p);
    const existing = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(16_000)) catch "";
    defer if (existing.len > 0) allocator.free(existing);
    var items: [max_items]Item = undefined;
    var n = loadItems(existing, &items);
    for (items[0..n], 0..) |*item, i| {
        if (item.kind == kind and item.text.eql(t)) {
            if (items[i].n < 10_000) items[i].n += 1;
            writeItems(allocator, io, p, items[0..n]) catch return 0;
            return items[i].n;
        }
    }
    if (n >= max_items) return 0;
    items[n] = .{ .kind = kind, .n = 1, .text = t };
    n += 1;
    writeItems(allocator, io, p, items[0..n]) catch return 0;
    return 1;
}

pub fn catalog(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    const p = path(allocator, workspace) catch return allocator.dupe(u8, "");
    defer allocator.free(p);
    const existing = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(16_000)) catch {
        return allocator.dupe(u8, "");
    };
    defer allocator.free(existing);
    var items: [max_items]Item = undefined;
    const n = loadItems(existing, &items);
    if (n == 0) return allocator.dupe(u8, "");
    var order: [max_items]usize = undefined;
    for (0..n) |i| order[i] = i;
    std.mem.sort(usize, order[0..n], items[0..n], byCountDesc);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Playbook (read .omfx/playbook.jsonl): ");
    const take = @min(n, catalog_max);
    for (0..take) |i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        var sbuf: [slug_max]u8 = undefined;
        try out.appendSlice(allocator, items[order[i]].text.slug(&sbuf));
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

pub fn noteHarmful(allocator: std.mem.Allocator, io: Io, workspace: []const u8, raw: []const u8) void {
    _ = bump(allocator, io, workspace, .harmful, raw);
}

pub fn noteVerified(allocator: std.mem.Allocator, io: Io, workspace: []const u8, raw: []const u8) void {
    const n = bump(allocator, io, workspace, .helpful, raw);
    if (n == skill_after) writeSkill(allocator, io, workspace, raw);
}

fn writeSkill(allocator: std.mem.Allocator, io: Io, workspace: []const u8, raw: []const u8) void {
    const t = Text.fromRaw(raw);
    if (t.len == 0) return;
    var sbuf: [slug_max]u8 = undefined;
    const s = t.slug(&sbuf);
    const root = skillsDir(allocator, workspace) catch return;
    defer allocator.free(root);
    const dirp = std.fs.path.join(allocator, &.{ root, s }) catch return;
    defer allocator.free(dirp);
    const md = std.fs.path.join(allocator, &.{ dirp, "SKILL.md" }) catch return;
    defer allocator.free(md);
    if (Io.Dir.cwd().openFile(io, md, .{ .mode = .read_only })) |f| {
        f.close(io);
        return;
    } else |_| {}
    Io.Dir.cwd().createDirPath(io, dirp) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dirp, @errorName(err) });
        return;
    };
    var file = Io.Dir.cwd().createFile(io, md, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.print(
        \\---
        \\name: {s}
        \\description: {s}
        \\---
        \\{s}
        \\
    , .{ s, t.slice(), t.slice() }) catch return;
    w.interface.flush() catch return;
}

test "parseLine json and tsv" {
    var item: Item = undefined;
    try std.testing.expect(parseLine("harmful 2 denied bash", &item));
    try std.testing.expectEqual(Kind.harmful, item.kind);
    try std.testing.expectEqual(@as(u32, 2), item.n);
    try std.testing.expectEqualStrings("denied bash", item.text.slice());
    try std.testing.expect(parseLine("{\"k\":\"helpful\",\"n\":3,\"t\":\"fact src/a.zig\"}", &item));
    try std.testing.expectEqual(Kind.helpful, item.kind);
    try std.testing.expectEqual(@as(u32, 3), item.n);
    try std.testing.expectEqualStrings("fact src/a.zig", item.text.slice());
}

test "clip lowercases and strips quotes" {
    try std.testing.expectEqualStrings("denied bash", Text.fromRaw("Denied  \"bash\"").slice());
}

test "bump counts and catalog is names only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try pathing.testWorkspace(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(ws);
    try std.testing.expectEqual(@as(u32, 1), bump(std.testing.allocator, io, ws, .harmful, "denied bash"));
    try std.testing.expectEqual(@as(u32, 2), bump(std.testing.allocator, io, ws, .harmful, "Denied Bash"));
    const cat = try catalog(std.testing.allocator, io, ws);
    defer std.testing.allocator.free(cat);
    try std.testing.expect(std.mem.indexOf(u8, cat, "denied-bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, cat, "\"k\"") == null);
    try std.testing.expectEqual(@as(u32, 1), bump(std.testing.allocator, io, ws, .helpful, "FACT path=src/a.zig printer"));
    try std.testing.expectEqual(@as(u32, 2), bump(std.testing.allocator, io, ws, .helpful, "FACT path=src/a.zig printer"));
}

test "second verified note writes a skill" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try pathing.testWorkspace(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(ws);
    noteVerified(std.testing.allocator, io, ws, "FAIL changing printer did nothing");
    noteVerified(std.testing.allocator, io, ws, "FAIL changing printer did nothing");
    var sbuf: [slug_max]u8 = undefined;
    const s = slug("fail changing printer did nothing", &sbuf);
    const md = try std.fs.path.join(std.testing.allocator, &.{ ws, ".omfx", "skills", s, "SKILL.md" });
    defer std.testing.allocator.free(md);
    const body = try Io.Dir.cwd().readFileAlloc(io, md, std.testing.allocator, .limited(2000));
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fail changing printer") != null);
}
