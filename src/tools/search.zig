const std = @import("std");
const Io = std.Io;
const pathing = @import("pathing.zig");

fn listing(dir: Io.Dir, io: Io) !Io.Dir {
    return dir.openDir(io, ".", .{ .iterate = true });
}

const ignore = @import("ignore.zig");

/// Tripwires, not guesses. A walk that hits one says so in its own output, so
/// the model can narrow `path` or `glob` instead of trusting a short answer.
pub const max_depth: usize = 16;
pub const max_files: usize = 20_000;
pub const max_glob_hits: usize = 400;
pub const max_grep_lines: usize = 300;
pub const max_file_bytes: usize = 2 * 1024 * 1024;
pub const max_line_bytes: usize = 400;

/// NUL in the head is the same binary test grep(1) uses.
fn binary(body: []const u8) bool {
    return std.mem.indexOfScalar(u8, body[0..@min(body.len, 8000)], 0) != null;
}

/// Depth-first walk rooted at `root` (a workspace-relative dir, "" for the
/// whole workspace). Yields workspace-relative file paths owned by `allocator`.
pub const Walk = struct {
    allocator: std.mem.Allocator,
    io: Io,
    base: Io.Dir,
    /// Directories still to open, workspace-relative. Owned.
    pending: std.ArrayList([]u8) = .empty,
    /// The directory currently being iterated, and its relative prefix.
    open: ?Io.Dir = null,
    it: Io.Dir.Iterator = undefined,
    prefix: []u8 = &.{},
    depth_of_prefix: usize = 0,
    files: usize = 0,
    truncated: bool = false,
    /// The workspace's own `.gitignore`, or the built-in list if it has none.
    ignore: ignore.Ignore = .{},

    pub fn init(allocator: std.mem.Allocator, io: Io, base: Io.Dir, root: []const u8) !Walk {
        var w = Walk{ .allocator = allocator, .io = io, .base = base };
        w.ignore = ignore.Ignore.load(allocator, base, io);
        errdefer w.deinit();
        const clean = std.mem.trim(u8, root, "/ ");
        const start = if (clean.len == 0 or std.mem.eql(u8, clean, ".")) "" else clean;
        try w.pending.append(allocator, try allocator.dupe(u8, start));
        return w;
    }

    pub fn deinit(self: *Walk) void {
        if (self.open) |*d| d.close(self.io);
        self.open = null;
        for (self.pending.items) |p| self.allocator.free(p);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.prefix);
    }

    fn openNext(self: *Walk) bool {
        while (self.pending.pop()) |rel| {
            const path: []const u8 = if (rel.len == 0) "." else rel;
            const d = self.base.openDir(self.io, path, .{ .iterate = true }) catch {
                self.allocator.free(rel);
                continue;
            };
            if (self.open) |*old| old.close(self.io);
            self.allocator.free(self.prefix);
            self.open = d;
            self.prefix = rel;
            self.depth_of_prefix = if (rel.len == 0) 0 else std.mem.count(u8, rel, "/") + 1;
            self.it = self.open.?.iterate();
            return true;
        }
        return false;
    }

    fn join(self: *Walk, name: []const u8) ![]u8 {
        if (self.prefix.len == 0) return self.allocator.dupe(u8, name);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.prefix, name });
    }

    /// Caller owns the returned path.
    pub fn next(self: *Walk) !?[]u8 {
        while (true) {
            if (self.open == null and !self.openNext()) return null;
            const entry = (self.it.next(self.io) catch null) orelse {
                if (self.open) |*d| d.close(self.io);
                self.open = null;
                self.allocator.free(self.prefix);
                self.prefix = &.{};
                continue;
            };
            switch (entry.kind) {
                .directory => {
                    if (self.depth_of_prefix + 1 >= max_depth) {
                        self.truncated = true;
                        continue;
                    }
                    const child = try self.join(entry.name);
                    errdefer self.allocator.free(child);
                    // Pruning here, not at the file, is what keeps an ignored
                    // tree from costing anything at all.
                    if (self.ignore.ignored(child, true)) {
                        self.allocator.free(child);
                        continue;
                    }
                    try self.pending.append(self.allocator, child);
                },
                .file, .sym_link => {
                    if (self.files >= max_files) {
                        self.truncated = true;
                        return null;
                    }
                    const rel = try self.join(entry.name);
                    errdefer self.allocator.free(rel);
                    if (self.ignore.ignored(rel, false)) {
                        self.allocator.free(rel);
                        continue;
                    }
                    self.files += 1;
                    return rel;
                },
                else => {},
            }
        }
    }
};

/// Wildcards inside a single path segment: `*` any run, `?` one byte.
fn matchSegment(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            mark = n;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

const max_segments: usize = 40;

fn segments(path: []const u8, out: *[max_segments][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (n == out.len) break;
        out[n] = seg;
        n += 1;
    }
    return n;
}

/// A pattern with no `/` matches the basename, the way `*.zig` is always meant.
/// Otherwise it matches the whole relative path, with `**` spanning separators.
pub fn matchPath(pattern: []const u8, path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        if (pattern.len == 0 or std.mem.eql(u8, pattern, "*") or std.mem.eql(u8, pattern, "**")) return true;
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
        return matchSegment(pattern, base);
    }
    return matchRelative(pattern, path);
}

/// Segment-wise against the whole path, with no basename shortcut. A rooted
/// rule like `/only-root.md` must not match `docs/only-root.md`.
pub fn matchRelative(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0 or std.mem.eql(u8, pattern, "*") or std.mem.eql(u8, pattern, "**")) return true;
    var pbuf: [max_segments][]const u8 = undefined;
    var sbuf: [max_segments][]const u8 = undefined;
    const pn = segments(pattern, &pbuf);
    const sn = segments(path, &sbuf);
    var pi: usize = 0;
    var si: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (si < sn) {
        if (pi < pn and std.mem.eql(u8, pbuf[pi], "**")) {
            star_p = pi;
            star_s = si;
            pi += 1;
        } else if (pi < pn and matchSegment(pbuf[pi], sbuf[si])) {
            pi += 1;
            si += 1;
        } else if (star_p) |sp| {
            star_s += 1;
            si = star_s;
            pi = sp + 1;
        } else return false;
    }
    while (pi < pn and std.mem.eql(u8, pbuf[pi], "**")) pi += 1;
    return pi == pn;
}

/// Kept for callers that only ever pass a basename pattern.
pub fn match(pattern: []const u8, name: []const u8) bool {
    return matchPath(pattern, name);
}

/// Recursive. `root` is a workspace-relative directory ("" for the workspace).
pub fn glob(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    pattern: []const u8,
    root: []const u8,
) ![]u8 {
    var w = Walk.init(allocator, io, dir, root) catch
        return allocator.dupe(u8, "(no matches)");
    defer w.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    while (try w.next()) |rel| {
        defer allocator.free(rel);
        if (!matchPath(pattern, rel)) continue;
        pathing.assertInside(workspace, rel) catch continue;
        try out.appendSlice(allocator, rel);
        try out.append(allocator, '\n');
        n += 1;
        if (n >= max_glob_hits) {
            try out.print(allocator, "truncated at {d} files; narrow `pattern` or set `path`\n", .{max_glob_hits});
            break;
        }
    }
    if (out.items.len == 0) {
        return std.fmt.allocPrint(allocator, "(no matches for {s} under {s})", .{
            pattern,
            if (root.len == 0) "." else root,
        });
    }
    if (w.truncated and n < max_glob_hits) {
        try out.print(allocator, "walk stopped early ({d} files or depth {d}); set `path` to narrow it\n", .{ max_files, max_depth });
    }
    return out.toOwnedSlice(allocator);
}

/// Recursive, literal, case-sensitive. Reports `path:line: text` so the model
/// can read the hit without a second `read` call.
pub fn grep(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    needle: []const u8,
    file_glob: []const u8,
    root: []const u8,
) ![]u8 {
    if (needle.len == 0) return error.EmptyNeedle;
    var w = Walk.init(allocator, io, dir, root) catch
        return allocator.dupe(u8, "(no matches)");
    defer w.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines: usize = 0;
    var files: usize = 0;
    while (try w.next()) |rel| {
        defer allocator.free(rel);
        if (file_glob.len > 0 and !matchPath(file_glob, rel)) continue;
        pathing.assertInside(workspace, rel) catch continue;
        const body = dir.readFileAlloc(io, rel, allocator, .limited(max_file_bytes)) catch continue;
        defer allocator.free(body);
        if (binary(body)) continue;
        if (std.mem.indexOf(u8, body, needle) == null) continue;
        files += 1;

        var no: usize = 0;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            no += 1;
            if (std.mem.indexOf(u8, line, needle) == null) continue;
            const text = std.mem.trim(u8, line, " \t\r");
            try out.print(allocator, "{s}:{d}: {s}\n", .{ rel, no, text[0..@min(text.len, max_line_bytes)] });
            lines += 1;
            if (lines >= max_grep_lines) break;
        }
        if (lines >= max_grep_lines) {
            try out.print(allocator, "truncated at {d} lines; narrow `pattern`, `glob`, or `path`\n", .{max_grep_lines});
            break;
        }
    }
    if (out.items.len == 0) {
        return std.fmt.allocPrint(allocator, "(no matches for {s} under {s})", .{
            needle,
            if (root.len == 0) "." else root,
        });
    }
    if (w.truncated and lines < max_grep_lines) {
        try out.print(allocator, "walk stopped early ({d} files or depth {d}); set `path` to narrow it\n", .{ max_files, max_depth });
    }
    return out.toOwnedSlice(allocator);
}

pub fn delete(dir: Io.Dir, io: Io, workspace: []const u8, rel: []const u8) !void {
    try pathing.assertInside(workspace, rel);
    try dir.deleteFile(io, rel);
}

pub fn rename(dir: Io.Dir, io: Io, workspace: []const u8, from: []const u8, to: []const u8) !void {
    try pathing.assertInside(workspace, from);
    try pathing.assertInside(workspace, to);
    try Io.Dir.rename(dir, from, dir, to, io);
}

pub fn semanticSearch(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    query: []const u8,
) ![]u8 {
    if (query.len == 0) return error.EmptyNeedle;
    var child = listing(dir, io) catch return allocator.dupe(u8, "(no matches; lexical search, not embeddings)\n");
    defer child.close(io);
    var it = child.iterate();
    const Hit = struct { name: []const u8, score: usize };
    var hits: [32]Hit = undefined;
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        pathing.assertInside(workspace, entry.name) catch continue;
        const body = dir.readFileAlloc(io, entry.name, allocator, .limited(80_000)) catch continue;
        defer allocator.free(body);
        var score: usize = 0;
        var words = std.mem.splitAny(u8, query, " \t");
        while (words.next()) |w| {
            if (w.len < 2) continue;
            if (std.mem.indexOf(u8, body, w) != null) score += 1;
            if (std.mem.indexOf(u8, entry.name, w) != null) score += 2;
        }
        if (score == 0) continue;
        if (n < hits.len) {
            hits[n] = .{ .name = try allocator.dupe(u8, entry.name), .score = score };
            n += 1;
        }
    }
    defer {
        var i: usize = 0;
        while (i < n) : (i += 1) allocator.free(hits[i].name);
    }
    if (n == 0) return allocator.dupe(u8, "(no matches; lexical search, not embeddings)\n");
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            if (hits[j].score > hits[i].score) {
                const tmp = hits[i];
                hits[i] = hits[j];
                hits[j] = tmp;
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "semantic_search (lexical, not embeddings)\n");
    for (hits[0..n]) |h| {
        var line_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{d} {s}\n", .{ h.score, h.name }) catch continue;
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

test "glob matches basenames, paths, and **" {
    try std.testing.expect(matchPath("*.zig", "src/cli/main.zig"));
    try std.testing.expect(!matchPath("*.zig", "src/cli/main.ts"));
    try std.testing.expect(matchPath("src/**/*.zig", "src/cli/main.zig"));
    try std.testing.expect(matchPath("src/**/*.zig", "src/main.zig"));
    try std.testing.expect(!matchPath("src/**/*.zig", "docs/main.zig"));
    try std.testing.expect(matchPath("src/*/main.zig", "src/cli/main.zig"));
    try std.testing.expect(!matchPath("src/*/main.zig", "src/a/b/main.zig"));
    try std.testing.expect(matchPath("m?in.zig", "main.zig"));
    try std.testing.expect(matchPath("*", "anything/at/all"));
}

test "glob names its hit cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    var i: usize = 0;
    var name_buf: [16]u8 = undefined;
    while (i < max_glob_hits + 1) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i});
        try fs.write(tmp.dir, io, std.testing.allocator, "ws", name, "x");
    }
    const got = try glob(tmp.dir, io, std.testing.allocator, "ws", "*.txt", "");
    defer std.testing.allocator.free(got);
    var cap_buf: [64]u8 = undefined;
    const cap = try std.fmt.bufPrint(&cap_buf, "truncated at {d} files", .{max_glob_hits});
    try std.testing.expect(std.mem.indexOf(u8, got, cap) != null);
}

test "glob after grep on the same dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.txt", "hello");
    const g1 = try grep(tmp.dir, io, std.testing.allocator, "ws", "hello", "*", "");
    defer std.testing.allocator.free(g1);
    const g2 = try glob(tmp.dir, io, std.testing.allocator, "ws", "*.txt", "");
    defer std.testing.allocator.free(g2);
    try std.testing.expect(std.mem.indexOf(u8, g2, "a.txt") != null);
}

test "grep finds needle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.txt", "hello world");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "b.txt", "nope");
    const got = try grep(tmp.dir, io, std.testing.allocator, "ws", "hello", "*.txt", "");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "b.txt") == null);
}

test "grep reports path, line number, and the matching text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.txt", "one\ntwo\n  needle here\nfour\n");
    const got = try grep(tmp.dir, io, std.testing.allocator, "ws", "needle", "*", "");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a.txt:3: needle here\n", got);
}

test "grep and glob descend into subdirectories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    try fs.mkdir(tmp.dir, io, "ws", "src");
    try fs.mkdir(tmp.dir, io, "ws", "src/cli");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "src/cli/tui.zig", "pub const Layout = 1;\n");
    const hit = try grep(tmp.dir, io, std.testing.allocator, "ws", "Layout", "*", "");
    defer std.testing.allocator.free(hit);
    try std.testing.expect(std.mem.indexOf(u8, hit, "src/cli/tui.zig:1:") != null);
    const found = try glob(tmp.dir, io, std.testing.allocator, "ws", "**/*.zig", "");
    defer std.testing.allocator.free(found);
    try std.testing.expect(std.mem.indexOf(u8, found, "src/cli/tui.zig") != null);
}

test "grep honours a path root and says where it looked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    try fs.mkdir(tmp.dir, io, "ws", "src");
    try fs.mkdir(tmp.dir, io, "ws", "docs");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "src/a.zig", "Layout\n");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "docs/b.md", "Layout\n");
    const only = try grep(tmp.dir, io, std.testing.allocator, "ws", "Layout", "*", "src");
    defer std.testing.allocator.free(only);
    try std.testing.expect(std.mem.indexOf(u8, only, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, "docs/b.md") == null);
    const miss = try grep(tmp.dir, io, std.testing.allocator, "ws", "Layout", "*", "docs/nested");
    defer std.testing.allocator.free(miss);
    try std.testing.expect(std.mem.indexOf(u8, miss, "docs/nested") != null);
}

test "walk skips generated trees and binaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    try fs.mkdir(tmp.dir, io, "ws", "node_modules");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "node_modules/dep.js", "needle\n");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "blob.bin", "needle\x00\n");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "keep.txt", "needle\n");
    const got = try grep(tmp.dir, io, std.testing.allocator, "ws", "needle", "*", "");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("keep.txt:1: needle\n", got);
}

test "semantic search ranks by tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fs = @import("fs.zig");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "alpha.txt", "workspace agent loop");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "beta.txt", "unrelated");
    const got = try semanticSearch(tmp.dir, io, std.testing.allocator, "ws", "agent loop");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "alpha.txt") != null);
}
