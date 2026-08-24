const std = @import("std");
const Io = std.Io;

pub const max_verify: usize = 4;
pub const max_never: usize = 8;
/// Longest command or rule a deny check will normalize. Past this the check
/// blocks rather than judging a truncated string.
pub const max_normalized: usize = 16_384;
pub const max_always: usize = 8;
pub const max_scoped: usize = 16;
pub const max_rules: usize = max_verify + max_never + max_always + max_scoped;
pub const line_max: usize = 160;
/// Receipt: this repo's own AGENTS.md is 8.5 KB and has grown with the code
/// it describes; 8,000 forced real rules out of the file to fit. The prefix
/// this sits in is cached from the second turn on (see `client.cacheJson`), so
/// the standing cost of another few hundred bytes is a cache read, not a fresh
/// prompt. 16,000 is a tripwire for a file that has stopped being rules.
///
/// Passing it is not a truncation: `readFileAlloc` errors, and the contract
/// loader drops the file whole. Anything near the cap should be trimmed
/// deliberately rather than discovered missing.
pub const file_max: usize = 16_000;

comptime {
    if (max_verify == 0) @compileError("max_verify must run at least one command");
    if (max_never == 0) @compileError("max_never must hold a blocked command");
    if (max_always == 0) @compileError("max_always must hold a style rule");
    if (max_scoped == 0) @compileError("max_scoped must hold a path-scoped rule");
    if (line_max == 0) @compileError("line_max must hold a rule");
    if (file_max == 0) @compileError("file_max must hold one AGENTS.md");
}

pub const Glob = union(enum) {
    all,
    dir: []const u8,
    ext: []const u8,
    literal: []const u8,
    contains: []const u8,

    pub fn parse(pat: []const u8) Glob {
        if (pat.len == 0 or std.mem.eql(u8, pat, "*")) return .all;
        if (std.mem.endsWith(u8, pat, "/**")) return .{ .dir = pat[0 .. pat.len - 3] };
        if (std.mem.startsWith(u8, pat, "*.")) return .{ .ext = pat[1..] };
        if (std.mem.indexOfScalar(u8, pat, '*') == null) return .{ .literal = pat };
        return .{ .contains = std.mem.trim(u8, pat, "*") };
    }

    pub fn matches(self: Glob, path: []const u8) bool {
        return switch (self) {
            .all => true,
            .dir => |prefix| std.mem.eql(u8, path, prefix) or
                (std.mem.startsWith(u8, path, prefix) and (path.len == prefix.len or path[prefix.len] == '/')),
            .ext => |e| std.mem.endsWith(u8, path, e),
            .literal => |p| std.mem.eql(u8, path, p) or std.mem.startsWith(u8, path, p),
            .contains => |needle| std.mem.indexOf(u8, path, needle) != null,
        };
    }
};

pub const Scoped = struct {
    glob: []const u8,
    text: []const u8,
};

pub const Rule = union(enum) {
    verify: []const u8,
    never: []const u8,
    always: []const u8,
    scoped: Scoped,

    fn deinit(self: Rule, allocator: std.mem.Allocator) void {
        switch (self) {
            .verify, .never, .always => |s| allocator.free(s),
            .scoped => |s| {
                allocator.free(s.glob);
                allocator.free(s.text);
            },
        }
    }

    fn dupe(self: Rule, allocator: std.mem.Allocator) !Rule {
        return switch (self) {
            .verify => |s| .{ .verify = try allocator.dupe(u8, s) },
            .never => |s| .{ .never = try allocator.dupe(u8, s) },
            .always => |s| .{ .always = try allocator.dupe(u8, s) },
            .scoped => |s| blk: {
                const glob = try allocator.dupe(u8, s.glob);
                errdefer allocator.free(glob);
                const text = try allocator.dupe(u8, s.text);
                break :blk .{ .scoped = .{ .glob = glob, .text = text } };
            },
        };
    }
};

fn capOf(tag: std.meta.Tag(Rule)) usize {
    return switch (tag) {
        .verify => max_verify,
        .never => max_never,
        .always => max_always,
        .scoped => max_scoped,
    };
}

pub const Contract = struct {
    items: [max_rules]Rule = undefined,
    n: usize = 0,

    pub fn slice(self: *const Contract) []const Rule {
        return self.items[0..self.n];
    }

    pub fn deinit(self: *Contract, allocator: std.mem.Allocator) void {
        for (self.slice()) |r| r.deinit(allocator);
        self.* = .{};
    }

    pub fn count(self: Contract, tag: std.meta.Tag(Rule)) usize {
        var n: usize = 0;
        for (self.slice()) |r| {
            if (std.meta.activeTag(r) == tag) n += 1;
        }
        return n;
    }

    pub fn firstVerify(self: Contract) ?[]const u8 {
        for (self.slice()) |r| {
            switch (r) {
                .verify => |s| return s,
                .never, .always, .scoped => {},
            }
        }
        return null;
    }

    fn push(self: *Contract, rule: Rule) bool {
        if (self.n >= max_rules) return false;
        if (self.count(std.meta.activeTag(rule)) >= capOf(std.meta.activeTag(rule))) return false;
        self.items[self.n] = rule;
        self.n += 1;
        return true;
    }

    fn pushText(self: *Contract, allocator: std.mem.Allocator, comptime tag: std.meta.Tag(Rule), s: []const u8) !void {
        if (s.len == 0) return;
        if (self.n >= max_rules) return;
        if (self.count(tag) >= capOf(tag)) return;
        const clip = if (s.len > line_max) s[0..line_max] else s;
        const dupe = try allocator.dupe(u8, clip);
        const rule: Rule = switch (tag) {
            .verify => .{ .verify = dupe },
            .never => .{ .never = dupe },
            .always => .{ .always = dupe },
            .scoped => unreachable,
        };
        if (!self.push(rule)) allocator.free(dupe);
    }

    /// A deny rule must not be evadable by spacing. `rm -rf` has to match
    /// `rm  -rf` and `rm\t-rf`, which a raw substring search does not: both
    /// sides are collapsed to single spaces first.
    ///
    /// Over-matching is the safe direction for a `never` rule; under-matching
    /// is the one that ships a bypass.
    pub fn blocksBash(self: Contract, command: []const u8) bool {
        var cmd_buf: [max_normalized]u8 = undefined;
        // Too long to normalize is unjudgeable, so it is blocked, not allowed.
        const cmd = normalizeWs(&cmd_buf, command) orelse return true;
        for (self.slice()) |r| {
            switch (r) {
                .never => |n| {
                    var rule_buf: [max_normalized]u8 = undefined;
                    const rule = normalizeWs(&rule_buf, n) orelse continue;
                    if (rule.len == 0) continue;
                    if (std.mem.indexOf(u8, cmd, rule) != null) return true;
                },
                .verify, .always, .scoped => {},
            }
        }
        return false;
    }

    pub fn promptBlock(self: Contract, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "AGENTS.md contract (harness-enforced):\n");
        if (self.count(.verify) > 0) {
            try out.appendSlice(allocator, "Verify (run after writes):");
            for (self.slice()) |r| {
                switch (r) {
                    .verify => |c| {
                        try out.appendSlice(allocator, " `");
                        try out.appendSlice(allocator, c);
                        try out.append(allocator, '`');
                    },
                    .never, .always, .scoped => {},
                }
            }
            try out.append(allocator, '\n');
        }
        if (self.count(.never) > 0) {
            try out.appendSlice(allocator, "Never (blocked):");
            for (self.slice()) |r| {
                switch (r) {
                    .never => |c| {
                        try out.appendSlice(allocator, " `");
                        try out.appendSlice(allocator, c);
                        try out.append(allocator, '`');
                    },
                    .verify, .always, .scoped => {},
                }
            }
            try out.append(allocator, '\n');
        }
        for (self.slice()) |r| {
            switch (r) {
                .always => |c| {
                    try out.appendSlice(allocator, "- ");
                    try out.appendSlice(allocator, c);
                    try out.append(allocator, '\n');
                },
                .verify, .never, .scoped => {},
            }
        }
        if (self.count(.scoped) > 0) {
            try out.appendSlice(allocator, "Path-scoped rules load when a matching file is read.\n");
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Runs of whitespace collapse to one space, and the ends are trimmed, so a
/// rule and a command differing only in spacing compare equal. Null when the
/// input does not fit -- callers treat that as unjudgeable.
fn normalizeWs(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var prev_space = true;
    for (s) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (prev_space) continue;
            if (n == buf.len) return null;
            buf[n] = ' ';
            n += 1;
            prev_space = true;
        } else {
            if (n == buf.len) return null;
            buf[n] = c;
            n += 1;
            prev_space = false;
        }
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

const Section = enum { none, verify, never, always, other };

fn heading(line: []const u8) ?Section {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, "#")) return null;
    var i: usize = 0;
    while (i < t.len and t[i] == '#') i += 1;
    const name = std.mem.trim(u8, t[i..], " \t");
    if (std.ascii.eqlIgnoreCase(name, "verify")) return .verify;
    if (std.ascii.eqlIgnoreCase(name, "never")) return .never;
    if (std.ascii.eqlIgnoreCase(name, "always")) return .always;
    if (std.ascii.eqlIgnoreCase(name, "style")) return .always;
    return .other;
}

fn backtick(line: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, line, '`') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '`') orelse return null;
    if (b <= a + 1) return null;
    const inner = std.mem.trim(u8, line[a + 1 .. b], " \t");
    return if (inner.len == 0) null else inner;
}

fn looksCmd(s: []const u8) bool {
    const heads = [_][]const u8{ "zig ", "npm ", "pnpm ", "yarn ", "bun ", "go ", "cargo ", "make ", "pytest", "python " };
    for (heads) |h| {
        if (std.mem.startsWith(u8, s, h) or std.mem.eql(u8, s, std.mem.trimEnd(u8, h, " "))) return true;
    }
    return false;
}

fn itemLine(line: []const u8) []const u8 {
    var t = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, t, "- ")) t = std.mem.trim(u8, t[2..], " \t");
    if (std.mem.startsWith(u8, t, "* ")) t = std.mem.trim(u8, t[2..], " \t");
    return t;
}

const Front = struct {
    paths: []const u8,
    body: []const u8,
};

fn frontmatter(src: []const u8) Front {
    if (!std.mem.startsWith(u8, src, "---")) return .{ .paths = "", .body = src };
    const after = src[3..];
    const nl = std.mem.indexOfScalar(u8, after, '\n') orelse return .{ .paths = "", .body = src };
    const rest = after[nl + 1 ..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return .{ .paths = "", .body = src };
    const fm = rest[0..end];
    var body = rest[end + 4 ..];
    if (body.len > 0 and body[0] == '\n') body = body[1..];
    var paths: []const u8 = "";
    var it = std.mem.splitScalar(u8, fm, '\n');
    var in_paths = false;
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "paths:") or std.mem.startsWith(u8, t, "paths:")) {
            in_paths = true;
            const same = std.mem.trim(u8, t["paths:".len..], " \t");
            if (same.len > 0) paths = stripFence(same);
            continue;
        }
        if (in_paths) {
            if (std.mem.startsWith(u8, t, "- ")) {
                paths = std.mem.trim(u8, t[2..], " \t\"'");
                break;
            }
            if (t.len > 0 and t[0] != ' ' and t[0] != '-') in_paths = false;
        }
    }
    return .{ .paths = paths, .body = body };
}

fn stripFence(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len >= 2 and ((t[0] == '"' and t[t.len - 1] == '"') or (t[0] == '\'' and t[t.len - 1] == '\'')))
        return t[1 .. t.len - 1];
    return t;
}

pub fn globMatch(pat: []const u8, path: []const u8) bool {
    return Glob.parse(pat).matches(path);
}

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Contract {
    const fm = frontmatter(src);
    var c = Contract{};
    errdefer c.deinit(allocator);
    var section: Section = .none;
    var it = std.mem.splitScalar(u8, fm.body, '\n');
    while (it.next()) |raw| {
        if (heading(raw)) |h| {
            section = h;
            continue;
        }
        const line = itemLine(raw);
        if (line.len == 0) continue;
        switch (section) {
            .verify => {
                const cmd = backtick(raw) orelse (if (looksCmd(line)) line else null);
                if (cmd) |x| try c.pushText(allocator, .verify, x);
            },
            .never => {
                const cmd = backtick(raw) orelse line;
                try c.pushText(allocator, .never, cmd);
            },
            .always => try c.pushText(allocator, .always, line),
            .none, .other => {},
        }
    }
    if (fm.paths.len > 0) {
        var sit = std.mem.splitScalar(u8, fm.body, '\n');
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        while (sit.next()) |l| {
            if (heading(l) != null) continue;
            const t = itemLine(l);
            if (t.len == 0) continue;
            if (buf.items.len > 0) try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, t);
            if (buf.items.len >= line_max) break;
        }
        if (buf.items.len > 0) {
            const glob = try allocator.dupe(u8, fm.paths);
            errdefer allocator.free(glob);
            const text = try allocator.dupe(u8, buf.items);
            errdefer allocator.free(text);
            const rule: Rule = .{ .scoped = .{ .glob = glob, .text = text } };
            if (!c.push(rule)) rule.deinit(allocator);
        }
    }
    return c;
}

fn merge(dst: *Contract, allocator: std.mem.Allocator, src: Contract) !void {
    for (src.slice()) |r| {
        const copy = try r.dupe(allocator);
        if (!dst.push(copy)) copy.deinit(allocator);
    }
}

const Layer = enum { managed, user, project, local, rules };

fn parseFile(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, rel: []const u8) ?Contract {
    const body = dir.readFileAlloc(io, rel, allocator, .limited(file_max)) catch return null;
    defer allocator.free(body);
    return parse(allocator, body) catch null;
}

fn parseAbs(allocator: std.mem.Allocator, io: Io, path: []const u8) ?Contract {
    const body = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(file_max)) catch return null;
    defer allocator.free(body);
    return parse(allocator, body) catch null;
}

fn mergeFile(dst: *Contract, allocator: std.mem.Allocator, parsed: ?Contract) !void {
    var p = parsed orelse return;
    defer p.deinit(allocator);
    try merge(dst, allocator, p);
}

fn loadLayer(dst: *Contract, allocator: std.mem.Allocator, dir: Io.Dir, io: Io, home: []const u8, layer: Layer) !void {
    switch (layer) {
        .managed => try mergeFile(dst, allocator, parseAbs(allocator, io, "/etc/omfx/AGENTS.md")),
        .user => {
            if (home.len == 0) return;
            const user_path = std.fs.path.join(allocator, &.{ home, ".omfx", "AGENTS.md" }) catch return;
            defer allocator.free(user_path);
            try mergeFile(dst, allocator, parseAbs(allocator, io, user_path));
        },
        .project => {
            if (parseFile(allocator, dir, io, "AGENTS.md")) |parsed| {
                try mergeFile(dst, allocator, parsed);
            } else {
                try mergeFile(dst, allocator, parseFile(allocator, dir, io, "CLAUDE.md"));
            }
        },
        .local => try mergeFile(dst, allocator, parseFile(allocator, dir, io, "AGENTS.local.md")),
        .rules => {
            var rules = dir.openDir(io, ".omfx/rules", .{ .iterate = true }) catch return;
            defer rules.close(io);
            var it = rules.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                const body = rules.readFileAlloc(io, entry.name, allocator, .limited(file_max)) catch continue;
                defer allocator.free(body);
                var parsed = parse(allocator, body) catch continue;
                defer parsed.deinit(allocator);
                try merge(dst, allocator, parsed);
            }
        },
    }
}

/// Layers, broadest first: managed / user / project / local / .omfx/rules.
/// Never unions (more blocks). Verify/Always fill remaining slots.
pub fn load(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, home: []const u8) !Contract {
    var out = Contract{};
    errdefer out.deinit(allocator);
    inline for (std.meta.tags(Layer)) |layer| {
        try loadLayer(&out, allocator, dir, io, home, layer);
    }
    return out;
}

/// Nested AGENTS.md next to the file, plus scoped rules that match `path`.
pub fn attach(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, contract: Contract, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (contract.slice()) |r| {
        switch (r) {
            .scoped => |s| {
                if (!Glob.parse(s.glob).matches(path)) continue;
                try out.appendSlice(allocator, "rule ");
                try out.appendSlice(allocator, s.glob);
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, s.text);
                try out.append(allocator, '\n');
            },
            .verify, .never, .always => {},
        }
    }
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] != '/') continue;
        const dir_rel = path[0..i];
        if (dir_rel.len == 0) break;
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const nested = std.fmt.bufPrint(&name_buf, "{s}/AGENTS.md", .{dir_rel}) catch continue;
        if (parseFile(allocator, dir, io, nested)) |parsed| {
            var p = parsed;
            defer p.deinit(allocator);
            for (p.slice()) |r| {
                switch (r) {
                    .always => |a| {
                        try out.appendSlice(allocator, "nested: ");
                        try out.appendSlice(allocator, a);
                        try out.append(allocator, '\n');
                    },
                    .never => |n| {
                        try out.appendSlice(allocator, "nested-never: ");
                        try out.appendSlice(allocator, n);
                        try out.append(allocator, '\n');
                    },
                    .verify, .scoped => {},
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

test "parse extracts verify never always and ignores tool-ban prose" {
    const src =
        \\# AGENTS.md
        \\
        \\## Verify
        \\- `zig build test`
        \\- Run the project's existing tests.
        \\
        \\## Never
        \\- `rm -rf`
        \\
        \\## Style
        \\- Prefer the smallest change.
        \\no subagents
        \\
        \\## Layout
        \\- src/ is source.
    ;
    var c = try parse(std.testing.allocator, src);
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), c.count(.verify));
    try std.testing.expectEqualStrings("zig build test", c.firstVerify().?);
    try std.testing.expectEqual(@as(usize, 1), c.count(.never));
    try std.testing.expect(c.blocksBash("sudo rm -rf /tmp/x"));
    try std.testing.expect(!c.blocksBash("zig build test"));
    const block = try c.promptBlock(std.testing.allocator);
    defer std.testing.allocator.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "smallest change") != null);
}

test "frontmatter paths become scoped rules" {
    const src =
        \\---
        \\paths:
        \\- src/**
        \\---
        \\Always use zig fmt.
    ;
    var c = try parse(std.testing.allocator, src);
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), c.count(.scoped));
    try std.testing.expect(globMatch("src/**", "src/cli/cmds.zig"));
    try std.testing.expect(!globMatch("src/**", "docs/x.md"));
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(Glob.parse("src/**") == .dir);
    try std.testing.expect(Glob.parse("*.zig") == .ext);
    try std.testing.expect(Glob.parse("*") == .all);
}

test "local layer unions never onto project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    {
        var f = try tmp.dir.createFile(io, "AGENTS.md", .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("## Never\n- `rm -rf`\n");
        try w.interface.flush();
    }
    {
        var f = try tmp.dir.createFile(io, "AGENTS.local.md", .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("## Never\n- `sudo`\n");
        try w.interface.flush();
    }
    var c = try load(std.testing.allocator, tmp.dir, io, "");
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(c.blocksBash("rm -rf /tmp"));
    try std.testing.expect(c.blocksBash("sudo true"));
}

test "attach emits matching scoped rules" {
    var c = try parse(std.testing.allocator,
        \\---
        \\paths:
        \\- src/**
        \\---
        \\No unwrap in CLI.
    );
    defer c.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const got = try attach(std.testing.allocator, tmp.dir, std.testing.io, c, "src/cli/cmds.zig");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "No unwrap") != null);
    const miss = try attach(std.testing.allocator, tmp.dir, std.testing.io, c, "README.md");
    defer std.testing.allocator.free(miss);
    try std.testing.expectEqual(@as(usize, 0), miss.len);
}

test "a deny rule is not evadable by spacing" {
    var c = try parse(std.testing.allocator, "# Never\n- `rm -rf`\n");
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(c.blocksBash("rm -rf /tmp/x"));
    // Every spelling the shell treats identically must be blocked identically.
    try std.testing.expect(c.blocksBash("rm  -rf /tmp/x"));
    try std.testing.expect(c.blocksBash("rm\t-rf /tmp/x"));
    try std.testing.expect(c.blocksBash("echo a && rm   -rf /"));
    try std.testing.expect(c.blocksBash("rm\n-rf /tmp/x"));
    // And a command that merely looks similar is still allowed.
    try std.testing.expect(!c.blocksBash("git status"));
    try std.testing.expect(!c.blocksBash("rmdir -p a/b"));
}

test "normalizeWs collapses runs and trims ends" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a b c", normalizeWs(&buf, "  a \t\n b   c  ").?);
    try std.testing.expectEqualStrings("", normalizeWs(&buf, "   ").?);
    var tiny: [3]u8 = undefined;
    try std.testing.expect(normalizeWs(&tiny, "aaaaaa") == null);
}

test "an unnormalizable command is blocked, not allowed" {
    var c = try parse(std.testing.allocator, "# Never\n- `rm -rf`\n");
    defer c.deinit(std.testing.allocator);
    const long = "x" ** (max_normalized + 16);
    try std.testing.expect(c.blocksBash(long));
}
