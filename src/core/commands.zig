const std = @import("std");
const Io = std.Io;
const slash = @import("slash.zig");

const log = std.log.scoped(.commands);

pub const max_commands: usize = 32;
pub const max_bytes: usize = 32_000;
pub const max_name: usize = 32;

comptime {
    if (max_commands == 0) @compileError("max_commands must keep at least one user command");
    if (max_bytes == 0) @compileError("max_bytes must hold one command file");
    if (max_name == 0) @compileError("max_name must allow a command stem");
}

pub const Item = struct {
    name: []const u8,
    help: []const u8,
    body: []const u8,
};

pub const Table = struct {
    items: [max_commands]Item = undefined,
    n: usize = 0,

    pub fn slice(self: *const Table) []const Item {
        return self.items[0..self.n];
    }

    pub fn find(self: Table, token: []const u8) ?Item {
        const name = if (token.len > 0 and token[0] == '/') token[1..] else token;
        for (self.slice()) |it| {
            if (std.mem.eql(u8, it.name, name)) return it;
        }
        return null;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (self.slice()) |it| {
            allocator.free(it.name);
            allocator.free(it.help);
            allocator.free(it.body);
        }
        self.n = 0;
    }

    pub fn specs(self: Table, allocator: std.mem.Allocator) ![]slash.Spec {
        const out = try allocator.alloc(slash.Spec, self.n);
        for (self.slice(), 0..) |it, i| {
            out[i] = .{
                .name = try std.fmt.allocPrint(allocator, "/{s}", .{it.name}),
                .help = try allocator.dupe(u8, it.help),
            };
        }
        return out;
    }

    fn upsert(self: *Table, allocator: std.mem.Allocator, item: Item) void {
        for (self.items[0..self.n]) |*it| {
            if (!std.mem.eql(u8, it.name, item.name)) continue;
            allocator.free(it.name);
            allocator.free(it.help);
            allocator.free(it.body);
            it.* = item;
            return;
        }
        if (self.n >= max_commands) {
            allocator.free(item.name);
            allocator.free(item.help);
            allocator.free(item.body);
            return;
        }
        self.items[self.n] = item;
        self.n += 1;
    }
};

const Format = enum { md, toml };

const Parsed = struct { help: []const u8, body: []const u8 };

fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_name) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn stem(filename: []const u8) ?struct { name: []const u8, format: Format } {
    if (std.mem.endsWith(u8, filename, ".md"))
        return .{ .name = filename[0 .. filename.len - 3], .format = .md };
    if (std.mem.endsWith(u8, filename, ".toml"))
        return .{ .name = filename[0 .. filename.len - 5], .format = .toml };
    return null;
}

fn stripFence(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

fn yamlValue(block: []const u8, key: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, key)) continue;
        const rest = std.mem.trim(u8, t[key.len..], " \t");
        if (rest.len == 0 or rest[0] != ':') continue;
        return stripFence(rest[1..]);
    }
    return "";
}

fn parseMd(src: []const u8) Parsed {
    if (!std.mem.startsWith(u8, src, "---")) {
        return .{ .help = "", .body = std.mem.trim(u8, src, " \t\r\n") };
    }
    const after = src[3..];
    const nl = std.mem.indexOfScalar(u8, after, '\n') orelse
        return .{ .help = "", .body = std.mem.trim(u8, src, " \t\r\n") };
    const rest = after[nl + 1 ..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse
        return .{ .help = "", .body = std.mem.trim(u8, src, " \t\r\n") };
    var body = rest[end + 4 ..];
    if (body.len > 0 and body[0] == '\n') body = body[1..];
    return .{
        .help = yamlValue(rest[0..end], "description"),
        .body = std.mem.trim(u8, body, " \t\r\n"),
    };
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn tomlQuoted(src: []const u8, key: []const u8) []const u8 {
    var needle_buf: [40]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s} =", .{key}) catch return "";
    const start = std.mem.indexOf(u8, src, needle) orelse return "";
    var i = start + needle.len;
    while (i < src.len and isSpace(src[i])) i += 1;
    if (i + 3 <= src.len and std.mem.eql(u8, src[i .. i + 3], "\"\"\"")) {
        const from = i + 3;
        const close = std.mem.indexOf(u8, src[from..], "\"\"\"") orelse
            return std.mem.trim(u8, src[from..], " \t\r\n");
        return std.mem.trim(u8, src[from .. from + close], " \t\r\n");
    }
    if (i < src.len and src[i] == '"') {
        const from = i + 1;
        const close = std.mem.indexOfScalar(u8, src[from..], '"') orelse return "";
        return src[from .. from + close];
    }
    return "";
}

fn parseToml(src: []const u8) Parsed {
    const help = tomlQuoted(src, "description");
    const prompt = tomlQuoted(src, "prompt");
    const body = if (prompt.len > 0) prompt else std.mem.trim(u8, src, " \t\r\n");
    return .{ .help = help, .body = body };
}

fn parse(src: []const u8, format: Format) Parsed {
    return switch (format) {
        .md => parseMd(src),
        .toml => parseToml(src),
    };
}

fn loadDir(table: *Table, allocator: std.mem.Allocator, io: Io, dir: Io.Dir) void {
    var it = dir.iterate();
    while (it.next(io) catch |err| blk: {
        log.warn("iterate commands: {s}", .{@errorName(err)});
        break :blk null;
    }) |entry| {
        if (entry.kind != .file) continue;
        const file = stem(entry.name) orelse continue;
        if (!validName(file.name)) continue;
        var token_buf: [40]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "/{s}", .{file.name}) catch continue;
        if (slash.Name.fromToken(token) != null) continue;
        const raw = dir.readFileAlloc(io, entry.name, allocator, .limited(max_bytes)) catch |err| {
            log.warn("read {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        defer allocator.free(raw);
        const parsed = parse(raw, file.format);
        if (parsed.body.len == 0) continue;
        const help = if (parsed.help.len == 0) "user command" else parsed.help;
        const name_d = allocator.dupe(u8, file.name) catch continue;
        const help_d = allocator.dupe(u8, help) catch {
            allocator.free(name_d);
            continue;
        };
        const body_d = allocator.dupe(u8, parsed.body) catch {
            allocator.free(name_d);
            allocator.free(help_d);
            continue;
        };
        table.upsert(allocator, .{ .name = name_d, .help = help_d, .body = body_d });
    }
}

fn openCommands(io: Io, root: []const u8) ?Io.Dir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.omfx/commands", .{root}) catch return null;
    return Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch null;
}

pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
) Table {
    var table = Table{};
    if (openCommands(io, home)) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        loadDir(&table, allocator, io, dir);
    }
    if (openCommands(io, workspace)) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        loadDir(&table, allocator, io, dir);
    }
    return table;
}

pub fn loadDirItems(allocator: std.mem.Allocator, io: Io, dir: Io.Dir) Table {
    var table = Table{};
    loadDir(&table, allocator, io, dir);
    return table;
}

pub fn render(allocator: std.mem.Allocator, body: []const u8, args: []const u8) ![]u8 {
    const has_dollar = std.mem.indexOf(u8, body, "$ARGUMENTS") != null;
    const has_brace = std.mem.indexOf(u8, body, "{{args}}") != null;
    if (!has_dollar and !has_brace) {
        if (args.len == 0) return allocator.dupe(u8, body);
        return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ body, args });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], "$ARGUMENTS")) {
            try out.appendSlice(allocator, args);
            i += "$ARGUMENTS".len;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "{{args}}")) {
            try out.appendSlice(allocator, args);
            i += "{{args}}".len;
            continue;
        }
        try out.append(allocator, body[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "parseMd reads frontmatter and body" {
    const src =
        \\---
        \\description: Review the diff
        \\---
        \\Look at $ARGUMENTS
    ;
    const p = parse(src, .md);
    try std.testing.expectEqualStrings("Review the diff", p.help);
    try std.testing.expectEqualStrings("Look at $ARGUMENTS", p.body);
}

test "parseToml reads prompt triple quotes" {
    const src =
        \\description = "Ship it"
        \\prompt = """
        \\do the thing {{args}}
        \\"""
    ;
    const p = parse(src, .toml);
    try std.testing.expectEqualStrings("Ship it", p.help);
    try std.testing.expectEqualStrings("do the thing {{args}}", p.body);
}

test "render substitutes both placeholders" {
    const a = try render(std.testing.allocator, "X $ARGUMENTS Y", "pr 12");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("X pr 12 Y", a);
    const b = try render(std.testing.allocator, "go {{args}}", "now");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("go now", b);
    const c = try render(std.testing.allocator, "plain", "tail");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("plain\ntail", c);
}

test "load skips builtin names and keeps review" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, ".omfx/commands");
    var cmds = try tmp.dir.openDir(io, ".omfx/commands", .{ .iterate = true });
    defer cmds.close(io);
    {
        var f = try cmds.createFile(io, "help.md", .{ .truncate = true });
        defer f.close(io);
        var buf: [32]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("should not override /help\n");
        try w.interface.flush();
    }
    {
        var f = try cmds.createFile(io, "review.md", .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("---\ndescription: Review\n---\ncheck $ARGUMENTS\n");
        try w.interface.flush();
    }
    var table = loadDirItems(std.testing.allocator, io, cmds);
    defer table.deinit(std.testing.allocator);
    try std.testing.expect(table.find("/help") == null);
    const review = table.find("/review") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("Review", review.help);
    try std.testing.expect(std.mem.indexOf(u8, review.body, "check $ARGUMENTS") != null);
}
