//! Workspace-root `.gitignore`, for the tools that walk the tree.
//!
//! Covers what real repos use: comments, blank lines, `!` negation, a trailing
//! `/` for directory-only, a leading or embedded `/` for root-anchored, and
//! `*` / `?` / `**` through the same matcher `glob` uses.
//!
//! Deliberately NOT covered: `.gitignore` files in subdirectories, and
//! `[a-z]` character classes. Both are rare next to the cost of a real
//! implementation, and missing them can only ever include too much -- a file
//! that should have been hidden still shows up, which is a visible surprise
//! rather than a silent hole.

const std = @import("std");
const Io = std.Io;

/// Rules are read once per walk and never mutated after.
pub const max_rules: usize = 512;
pub const max_rule_bytes: usize = 200;
pub const max_file_bytes: usize = 256 * 1024;

/// Version control metadata is never a search result and is never listed in
/// `.gitignore`, so it is skipped whether or not one exists.
pub const always_skip = [_][]const u8{ ".git", ".hg", ".svn", ".jj" };

/// Used only when the workspace has no `.gitignore` to speak for it. A repo
/// that does ignore its build output should be believed over this list.
pub const fallback_skip = [_][]const u8{
    ".zig-cache", "zig-out",     "node_modules",  ".venv",
    "venv",       "__pycache__", ".mypy_cache",   ".pytest_cache",
    ".next",      ".turbo",      ".parcel-cache", "target",
    "dist",       ".cache",      ".gradle",       ".terraform",
};

pub fn alwaysSkipped(name: []const u8) bool {
    for (always_skip) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

const Rule = struct {
    text: [max_rule_bytes]u8 = undefined,
    len: usize = 0,
    negate: bool = false,
    dir_only: bool = false,
    anchored: bool = false,

    fn pattern(self: *const Rule) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Ignore = struct {
    rules: [max_rules]Rule = undefined,
    n: usize = 0,
    /// No `.gitignore` in the workspace root: fall back to the built-in list.
    loaded: bool = false,
    truncated: bool = false,

    /// Never fails: an unreadable or absent `.gitignore` just means "no rules".
    pub fn load(allocator: std.mem.Allocator, dir: Io.Dir, io: Io) Ignore {
        var self = Ignore{};
        const body = dir.readFileAlloc(io, ".gitignore", allocator, .limited(max_file_bytes)) catch return self;
        defer allocator.free(body);
        self.loaded = true;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (self.n == max_rules) {
                self.truncated = true;
                break;
            }
            var rule = Rule{};
            var t = line;
            if (t[0] == '!') {
                rule.negate = true;
                t = t[1..];
            }
            if (t.len == 0) continue;
            if (t[t.len - 1] == '/') {
                rule.dir_only = true;
                t = t[0 .. t.len - 1];
            }
            if (t.len == 0) continue;
            if (t[0] == '/') {
                rule.anchored = true;
                t = t[1..];
            } else if (std.mem.indexOfScalar(u8, t, '/')) |at| {
                // git anchors any pattern with an interior slash, `**/` aside.
                rule.anchored = at != t.len - 1 or !std.mem.startsWith(u8, t, "**");
            }
            if (t.len == 0 or t.len > max_rule_bytes) continue;
            @memcpy(rule.text[0..t.len], t);
            rule.len = t.len;
            self.rules[self.n] = rule;
            self.n += 1;
        }
        return self;
    }

    /// `rel` is workspace-relative with no leading slash. Last matching rule
    /// wins, which is what makes `!keep.txt` after `*.txt` work.
    pub fn ignored(self: *const Ignore, rel: []const u8, is_dir: bool) bool {
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
        if (alwaysSkipped(base)) return true;
        if (!self.loaded) {
            if (!is_dir) return false;
            for (fallback_skip) |d| {
                if (std.mem.eql(u8, d, base)) return true;
            }
            return false;
        }
        const search = @import("search.zig");
        var hit = false;
        for (self.rules[0..self.n]) |*rule| {
            if (rule.dir_only and !is_dir) continue;
            const pat = rule.pattern();
            const matched = if (rule.anchored)
                search.matchRelative(pat, rel) or prefixMatch(pat, rel)
            else
                search.matchPath(pat, base) or search.matchPath(pat, rel) or prefixMatch(pat, rel);
            if (matched) hit = !rule.negate;
        }
        return hit;
    }
};

/// `build/` must hide `build/x/y.o`, not just `build` itself. A walker that
/// prunes directories never asks, but `ignored` is also called on plain paths.
fn prefixMatch(pattern: []const u8, rel: []const u8) bool {
    if (!std.mem.startsWith(u8, rel, pattern)) return false;
    return rel.len > pattern.len and rel[pattern.len] == '/';
}

test "no gitignore falls back to the built-in list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ig = Ignore.load(std.testing.allocator, tmp.dir, std.testing.io);
    try std.testing.expect(!ig.loaded);
    try std.testing.expect(ig.ignored("node_modules", true));
    try std.testing.expect(ig.ignored(".git", true));
    try std.testing.expect(!ig.ignored("src", true));
    try std.testing.expect(!ig.ignored("main.zig", false));
}

fn writeFile(dir: Io.Dir, io: Io, name: []const u8, body: []const u8) !void {
    var f = try dir.createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    var buf: [512]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

test "gitignore replaces the fallback list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeFile(tmp.dir, io, ".gitignore", "# comment\n\n*.log\nbuild/\n");
    const ig = Ignore.load(std.testing.allocator, tmp.dir, io);
    try std.testing.expect(ig.loaded);
    try std.testing.expect(ig.ignored("a.log", false));
    try std.testing.expect(ig.ignored("deep/nested/a.log", false));
    try std.testing.expect(ig.ignored("build", true));
    try std.testing.expect(!ig.ignored("build", false));
    // The repo did not ignore node_modules, so we do not either.
    try std.testing.expect(!ig.ignored("node_modules", true));
    try std.testing.expect(ig.ignored(".git", true));
}

test "negation and anchoring follow last-match-wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeFile(tmp.dir, io, ".gitignore", "*.txt\n!keep.txt\n/only-root.md\n");
    const ig = Ignore.load(std.testing.allocator, tmp.dir, io);
    try std.testing.expect(ig.ignored("drop.txt", false));
    try std.testing.expect(!ig.ignored("keep.txt", false));
    try std.testing.expect(ig.ignored("only-root.md", false));
    try std.testing.expect(!ig.ignored("docs/only-root.md", false));
}

test "a directory rule hides everything under it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeFile(tmp.dir, io, ".gitignore", "out/\nsrc/gen/\n");
    const ig = Ignore.load(std.testing.allocator, tmp.dir, io);
    try std.testing.expect(ig.ignored("out", true));
    try std.testing.expect(ig.ignored("src/gen", true));
    try std.testing.expect(!ig.ignored("src", true));
}
