const std = @import("std");
const Io = std.Io;
const langs = @import("langs.zig");
const lex = @import("lex.zig");

/// PEEK-lite orientation cache (arXiv:2605.19932): a small prompt-resident
/// map, no embeddings, no extra model. Signatures only.
///
/// The map is ranked, not walk-ordered. RepoGraph (arXiv:2410.14684) measured
/// a 32.8% average relative gain on SWE-bench-Lite from giving a model
/// repository structure rather than a flat listing, and the ordering is where
/// that lives: the budget below holds roughly 80 files, so on any real repo
/// most of the tree is cut. Which 80 survive is the entire question, and
/// readdir order is not an answer to it.
pub const max_chars: usize = 4_000;
pub const max_files: usize = 80;
pub const max_sigs: usize = 6;

/// How many files may be examined to choose those `max_files`.
///
/// Receipt: omfx is 84 source files, the largest checkout on this machine is
/// 7,749, and reading 1,500 of them took 258 ms. 4,096 is a tripwire for a
/// working copy that has stopped being one repository, not a budget a project
/// is meant to reach; whatever is dropped is named in the map's own header.
pub const max_scan_files: usize = 4_096;
/// Receipt: 4,096 files of that same checkout is about 9 MB. 64 MB is the
/// tripwire.
pub const max_scan_bytes: usize = 64 * 1024 * 1024;
/// Files bigger than this are generated or vendored far more often than they
/// are worth a map entry.
const max_file_bytes: usize = 512 * 1024;
/// One-letter names carry no signal and appear everywhere.
const min_ident: usize = 3;

comptime {
    if (max_chars == 0) @compileError("max_chars must hold an orientation map");
    if (max_scan_files < max_files) @compileError("the scan must see at least what it emits");
}

const skip = [_][]const u8{
    ".git/",   "zig-cache/",   ".zig-cache/", "node_modules/", "zig-out/",
    "target/", "dist/",        "build/",      ".omfx/",        "vendor/",
    ".venv/",  "__pycache__/", ".next/",      "coverage/",     "Pods/",
};

fn skipped(path: []const u8) bool {
    for (skip) |s| {
        if (std.mem.indexOf(u8, path, s) != null) return true;
    }
    return false;
}

const File = struct {
    path: []const u8,
    sigs: []const u8,
    /// Hashes of the names this file declares. Hashes rather than strings
    /// because the map only ever compares them, and 4,096 files of identifiers
    /// is a lot of bytes to keep for equality tests.
    names: []const u64,
    score: u64 = 0,
};

fn hash(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Every identifier in the file, counted repo-wide.
///
/// ponytail: occurrence count, not PageRank. Counting is one pass over bytes
/// already in hand; PageRank needs the graph built and then iterated. If the
/// ranking ever looks wrong on a real repo, the upgrade is to weight each
/// reference by the referring file's own score and iterate to a fixed point.
fn countIdents(src: []const u8, counts: *std.AutoHashMap(u64, u32)) void {
    var i: usize = 0;
    while (i < src.len) {
        if (!isIdentByte(src[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < src.len and isIdentByte(src[i])) i += 1;
        const w = src[start..i];
        if (w.len < min_ident) continue;
        if (w[0] >= '0' and w[0] <= '9') continue;
        const gop = counts.getOrPut(hash(w)) catch return;
        if (gop.found_existing) gop.value_ptr.* +|= 1 else gop.value_ptr.* = 1;
    }
}

const Scan = struct {
    files: std.ArrayList(File),
    counts: std.AutoHashMap(u64, u32),
    seen: usize = 0,
    bytes: usize = 0,
    truncated: bool = false,
};

fn walk(
    arena: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    rel: []const u8,
    s: *Scan,
) void {
    if (skipped(rel)) return;
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (s.seen >= max_scan_files or s.bytes >= max_scan_bytes) {
            s.truncated = true;
            return;
        }
        if (ent.name.len == 0 or ent.name[0] == '.') continue;
        const child_rel = if (rel.len == 0)
            ent.name
        else
            std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, ent.name }) catch continue;
        switch (ent.kind) {
            .directory => {
                var sub = dir.openDir(io, ent.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                walk(arena, sub, io, child_rel, s);
            },
            .file => {
                if (!langs.isSource(ent.name)) continue;
                const l = langs.byPath(ent.name) orelse continue;
                const body = dir.readFileAlloc(io, ent.name, arena, .limited(max_file_bytes)) catch continue;
                defer arena.free(body);
                s.seen += 1;
                s.bytes += body.len;
                countIdents(body, &s.counts);
                addFile(arena, s, child_rel, l, body);
            },
            else => {},
        }
    }
}

fn addFile(arena: std.mem.Allocator, s: *Scan, rel: []const u8, l: *const langs.Lang, body: []const u8) void {
    var names: std.ArrayList(u64) = .empty;
    var sigs: std.ArrayList(u8) = .empty;
    var weak: std.ArrayList([]const u8) = .empty;
    var n: usize = 0;

    // Definitions first, bindings only if room is left. A file's `const`s come
    // before its functions, so taking lines in order fills the whole budget
    // with the top of the file.
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const d = lex.decl(l, line) orelse continue;
        names.append(arena, hash(d.name)) catch break;
        if (!d.strong) {
            if (weak.items.len < max_sigs) weak.append(arena, line) catch {};
            continue;
        }
        if (n >= max_sigs) continue;
        appendSig(arena, &sigs, line);
        n += 1;
    }
    for (weak.items) |line| {
        if (n >= max_sigs) break;
        appendSig(arena, &sigs, line);
        n += 1;
    }

    if (names.items.len == 0) return;
    const path = arena.dupe(u8, rel) catch return;
    s.files.append(arena, .{
        .path = path,
        .sigs = sigs.items,
        .names = names.items,
    }) catch {};
}

fn appendSig(arena: std.mem.Allocator, sigs: *std.ArrayList(u8), line: []const u8) void {
    const t = std.mem.trim(u8, line, " \t\r");
    const clip = if (t.len > 80) t[0..80] else t;
    sigs.appendSlice(arena, "  ") catch return;
    sigs.appendSlice(arena, clip) catch return;
    sigs.append(arena, '\n') catch return;
}

fn byScore(_: void, a: File, b: File) bool {
    if (a.score != b.score) return a.score > b.score;
    // Ties broken by path so the same repo always produces the same map; an
    // orientation aid that reshuffles between turns reads as a change.
    return std.mem.lessThan(u8, a.path, b.path);
}

pub fn build(allocator: std.mem.Allocator, dir: Io.Dir, io: Io) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = Scan{
        .files = .empty,
        .counts = std.AutoHashMap(u64, u32).init(arena),
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var root = dir.openDir(io, ".", .{ .iterate = true }) catch {
        try out.appendSlice(allocator, "Repo map (signatures, not bodies):\n");
        return out.toOwnedSlice(allocator);
    };
    defer root.close(io);
    walk(arena, root, io, "", &s);

    for (s.files.items) |*f| {
        for (f.names) |h| f.score +|= s.counts.get(h) orelse 0;
    }
    std.mem.sort(File, s.files.items, {}, byScore);

    if (s.truncated) {
        try out.print(allocator, "Repo map ({d} most-referenced files; the scan stopped at {d}):\n", .{
            @min(s.files.items.len, max_files),
            max_scan_files,
        });
    } else if (s.files.items.len > max_files) {
        try out.print(allocator, "Repo map ({d} most-referenced of {d} files, signatures only):\n", .{
            max_files,
            s.files.items.len,
        });
    } else {
        try out.appendSlice(allocator, "Repo map (signatures, not bodies):\n");
    }

    var emitted: usize = 0;
    for (s.files.items) |f| {
        if (emitted >= max_files or out.items.len >= max_chars) break;
        try out.appendSlice(allocator, f.path);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, f.sigs);
        emitted += 1;
    }
    if (out.items.len > max_chars) out.shrinkRetainingCapacity(max_chars);
    return out.toOwnedSlice(allocator);
}

test "the map ranks by how often a file's names are used elsewhere" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `hot` is referenced by both other files; `cold` by nobody.
    try writeFile(tmp.dir, io, "hot.zig", "pub fn sharedHelper() void {}\n");
    try writeFile(tmp.dir, io, "cold.zig", "pub fn lonelyThing() void {}\n");
    try writeFile(tmp.dir, io, "one.zig", "pub fn useA() void { sharedHelper(); }\n");
    try writeFile(tmp.dir, io, "two.zig", "pub fn useB() void { sharedHelper(); }\n");

    const map = try build(a, tmp.dir, io);
    defer a.free(map);
    const hot = std.mem.indexOf(u8, map, "hot.zig").?;
    const cold = std.mem.indexOf(u8, map, "cold.zig").?;
    try std.testing.expect(hot < cold);
}

test "the map covers languages beyond zig" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, "svc.go", "func StartServer() error { return nil }\n");
    try writeFile(tmp.dir, io, "app.rb", "class Application\nend\n");
    try writeFile(tmp.dir, io, "main.c", "int runEverything(int n) {\n  return n;\n}\n");
    try writeFile(tmp.dir, io, "lib.ex", "defmodule Widget do\nend\n");

    const map = try build(a, tmp.dir, io);
    defer a.free(map);
    try std.testing.expect(std.mem.indexOf(u8, map, "svc.go") != null);
    try std.testing.expect(std.mem.indexOf(u8, map, "app.rb") != null);
    try std.testing.expect(std.mem.indexOf(u8, map, "main.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, map, "lib.ex") != null);
}

test "prose and data files stay out of the map" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, "keep.zig", "pub fn keepMe() void {}\n");
    try writeFile(tmp.dir, io, "README.md", "# title\n\npub fn notCode() void {}\n");
    try writeFile(tmp.dir, io, "ci.yml", "jobs:\n  build:\n");

    const map = try build(a, tmp.dir, io);
    defer a.free(map);
    try std.testing.expect(std.mem.indexOf(u8, map, "keep.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, map, "README.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, map, "ci.yml") == null);
}

test "the map stays inside its budget" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var name: [32]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "f{d}.zig", .{i});
        try writeFile(tmp.dir, io, n, "pub fn someFunction() void {}\n");
    }
    const map = try build(a, tmp.dir, io);
    defer a.free(map);
    try std.testing.expect(map.len <= max_chars);
    try std.testing.expect(std.mem.indexOf(u8, map, "most-referenced of 200 files") != null);
}

fn writeFile(dir: Io.Dir, io: Io, name: []const u8, body: []const u8) !void {
    var f = try dir.createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    var buf: [512]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}
