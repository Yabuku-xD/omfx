const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const pathing = @import("pathing.zig");
const langs = @import("../core/langs.zig");
const lex = @import("../core/lex.zig");

const max_symbols: usize = 40;

const Item = struct {
    name: []const u8,
    kind: []const u8,
    start: u32,
    end: u32,
};

/// Outlines whatever `langs.table` describes, which is every language omfx
/// reads rather than the handful this file used to name itself.
fn scan(rel: []const u8, src: []const u8, out: *[max_symbols]Item) usize {
    const l = langs.byPath(rel) orelse return 0;
    var n: usize = 0;
    var line_no: u32 = 1;
    var i: usize = 0;
    while (i < src.len and n < max_symbols) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = src[i..nl];
        if (lex.decl(l, line)) |hit| {
            if (n > 0) out[n - 1].end = line_no - 1;
            out[n] = .{ .name = hit.name, .kind = hit.kind, .start = line_no, .end = line_no };
            n += 1;
        }
        line_no += 1;
        i = if (nl < src.len) nl + 1 else src.len;
    }
    if (n > 0) out[n - 1].end = line_no - 1;
    return n;
}

pub const Action = enum { before, after, inside, replace, delete };

pub fn parseAction(s: []const u8) ?Action {
    if (std.mem.eql(u8, s, "before") or std.mem.eql(u8, s, "insert_before")) return .before;
    if (std.mem.eql(u8, s, "after") or std.mem.eql(u8, s, "insert_after")) return .after;
    if (std.mem.eql(u8, s, "inside") or std.mem.eql(u8, s, "insert_inside")) return .inside;
    if (std.mem.eql(u8, s, "replace")) return .replace;
    if (std.mem.eql(u8, s, "delete")) return .delete;
    return null;
}

pub fn outlinePrefix(allocator: std.mem.Allocator, rel: []const u8, src: []const u8) ![]u8 {
    var items: [max_symbols]Item = undefined;
    const n = scan(rel, src, &items);
    if (n == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[outline ");
    try out.appendSlice(allocator, rel);
    try out.appendSlice(allocator, "]\n");
    for (items[0..n]) |it| {
        var line_buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s} {s} L{d}-{d}\n", .{ it.kind, it.name, it.start, it.end }) catch continue;
        try out.appendSlice(allocator, line);
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

pub fn splice(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    access: pathing.Access,
    rel: []const u8,
    symbol: []const u8,
    action: Action,
    text: []const u8,
) !void {
    const src = try fs.read(dir, io, allocator, access, rel);
    defer allocator.free(src);
    if (!bracesOk(src)) return error.StructureBroken;
    var items: [max_symbols]Item = undefined;
    const n = scan(rel, src, &items);
    const item = for (items[0..n]) |it| {
        if (std.mem.eql(u8, it.name, symbol)) break it;
    } else return error.SymbolNotFound;
    const payload = try unescape(allocator, text);
    defer allocator.free(payload);
    const next = try applySplice(allocator, src, item, action, payload);
    defer allocator.free(next);
    if (!bracesOk(next)) return error.StructureBroken;
    try fs.write(dir, io, allocator, access, rel, next);
}

fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                else => {
                    try out.append(allocator, '\\');
                    try out.append(allocator, s[i]);
                },
            }
        } else {
            try out.append(allocator, s[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn applySplice(allocator: std.mem.Allocator, src: []const u8, item: Item, action: Action, text: []const u8) ![]u8 {
    var start_off: usize = 0;
    var end_off: usize = src.len;
    offsets(src, item.start, item.end, &start_off, &end_off);
    if (action == .delete) {
        return std.mem.concat(allocator, u8, &.{ src[0..start_off], src[end_off..] });
    }
    const chunk = try ensureNlOwned(allocator, text);
    defer allocator.free(chunk);
    return switch (action) {
        .delete => unreachable,
        .before => std.mem.concat(allocator, u8, &.{ src[0..start_off], chunk, src[start_off..] }),
        .after => std.mem.concat(allocator, u8, &.{ src[0..end_off], chunk, src[end_off..] }),
        .replace => std.mem.concat(allocator, u8, &.{ src[0..start_off], chunk, src[end_off..] }),
        .inside => blk: {
            const close_at = closingLineOff(src, item.start, item.end) orelse return error.StructureBroken;
            break :blk std.mem.concat(allocator, u8, &.{ src[0..close_at], chunk, src[close_at..] });
        },
    };
}

fn ensureNlOwned(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0 or s[s.len - 1] == '\n') return allocator.dupe(u8, s);
    return std.fmt.allocPrint(allocator, "{s}\n", .{s});
}

fn offsets(src: []const u8, start: u32, end: u32, from: *usize, to: *usize) void {
    var line_no: u32 = 1;
    var i: usize = 0;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        if (line_no == start) from.* = i;
        if (line_no == end) {
            to.* = if (nl < src.len) nl + 1 else src.len;
            return;
        }
        line_no += 1;
        i = if (nl < src.len) nl + 1 else src.len;
    }
}

fn closingLineOff(src: []const u8, start: u32, end: u32) ?usize {
    var line_no: u32 = 1;
    var i: usize = 0;
    var last: ?usize = null;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        if (line_no >= start and line_no <= end) {
            const t = std.mem.trim(u8, src[i..nl], " \t\r");
            if (std.mem.eql(u8, t, "}") or std.mem.eql(u8, t, "};") or std.mem.eql(u8, t, "},")) {
                last = i;
            }
        }
        if (line_no == end) break;
        line_no += 1;
        i = if (nl < src.len) nl + 1 else src.len;
    }
    return last;
}

fn bracesOk(src: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '"' or c == '\'') {
            const q = c;
            i += 1;
            while (i < src.len and src[i] != q) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) i += 1;
            }
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth < 0) return false;
        }
    }
    return depth == 0;
}

test "outline extracts zig fns" {
    const src =
        \\const std = @import("std");
        \\pub fn foo() void {
        \\    return;
        \\}
        \\fn bar() u8 {
        \\    return 1;
        \\}
        \\
    ;
    const text = try outlinePrefix(std.testing.allocator, "a.zig", src);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn bar") != null);
}

test "empty outline is empty not a report" {
    const text = try outlinePrefix(std.testing.allocator, "empty.txt", "hello\n");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "splice inserts inside a fn without breaking braces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const src =
        \\pub fn foo() void {
        \\    return;
        \\}
        \\
    ;
    try fs.write(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "a.zig", src);
    try splice(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "a.zig", "foo", .inside, "    bar();\n");
    const got = try fs.read(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "a.zig");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "bar();") != null);
    try std.testing.expect(bracesOk(got));
}

test "splice delete removes a whole fn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const src =
        \\pub fn foo() void {
        \\    return;
        \\}
        \\fn bar() void {
        \\    return;
        \\}
        \\
    ;
    try fs.write(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "a.zig", src);
    try splice(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "a.zig", "foo", .delete, "");
    const got = try fs.read(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "a.zig");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "fn bar") != null);
    try std.testing.expect(bracesOk(got));
}

test "the outline covers every language the table describes" {
    const a = std.testing.allocator;
    const cases = [_]struct { rel: []const u8, src: []const u8, want: []const u8 }{
        .{ .rel = "a.rs", .src = "pub fn parse_it(s: &str) {}\n", .want = "parse_it" },
        .{ .rel = "a.java", .src = "public void runTask(int n) {\n}\n", .want = "runTask" },
        .{ .rel = "a.rb", .src = "class Widget\nend\n", .want = "Widget" },
        .{ .rel = "a.kt", .src = "fun compute(x: Int) {}\n", .want = "compute" },
        .{ .rel = "a.swift", .src = "struct Point {}\n", .want = "Point" },
        .{ .rel = "a.ex", .src = "defmodule Thing do\nend\n", .want = "Thing" },
    };
    for (cases) |c| {
        const text = try outlinePrefix(a, c.rel, c.src);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, c.want) != null);
    }
}
