const std = @import("std");
const Io = std.Io;
const langs = @import("langs.zig");
const lex = @import("lex.zig");

/// Personalized file-graph orientation map: signatures only, hard char budget.
/// No embeddings, no tree-sitter, no extra model.
///
/// Ranking aims at task-relevant spine inside `max_chars`:
///   1. Cross-file reference credit (self-hits do not count).
///   2. Rarity + name-length specificity (ubiquitous idents are downweighted).
///   3. Personalized propagation on the file graph (query tokens bias restart).
///   4. Per-file signature packing into the budget (not whole-file blocks).
///
/// RepoGraph (arXiv:2410.14684) measured a 32.8% average relative gain on
/// SWE-bench-Lite from structure over a flat listing; which 80 files and which
/// few signatures survive the budget is the entire question.
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
/// Unique identifier hashes kept per file for the reference graph. Caps the
/// adjacency build; the long tail of local temporaries is not load-bearing.
const max_refs_per_file: usize = 128;
/// Personalized propagation passes. Three is enough for one-hop importance to
/// reach neighbors of neighbors without the cost of a full eigen-solve.
const rank_iters: usize = 3;
const damp: f64 = 0.85;

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

const Sig = struct {
    line: []const u8,
    name: u64,
    name_len: u8,
};

const File = struct {
    path: []const u8,
    sigs: []const Sig,
    /// Declared name hashes (definitions).
    names: []const u64,
    /// Unique identifier hashes observed in the file (references + defs).
    refs: []const u64,
    /// Occurrences of each declared name inside this file (parallel to names).
    self_hits: []const u32,
    score: f64 = 0,
};

fn hash(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Occurrence count, repo-wide. Feeds rarity weights; propagation uses the
/// per-file ref lists built alongside.
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

fn collectRefs(arena: std.mem.Allocator, src: []const u8) []const u64 {
    var seen = std.AutoHashMap(u64, void).init(arena);
    var out: std.ArrayList(u64) = .empty;
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
        const h = hash(w);
        const gop = seen.getOrPut(h) catch break;
        if (gop.found_existing) continue;
        out.append(arena, h) catch break;
        if (out.items.len >= max_refs_per_file) break;
    }
    return out.items;
}

fn countDeclaredHits(src: []const u8, names: []const u64, out: []u32) void {
    @memset(out, 0);
    if (names.len == 0) return;
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
        const h = hash(w);
        for (names, 0..) |n, j| {
            if (n == h) out[j] +|= 1;
        }
    }
}

/// Specificity: long names and rare names matter more than `data` / `i`.
fn nameWeight(name_len: u8, global_count: u32) f64 {
    const len_boost: f64 = 1.0 + @as(f64, @floatFromInt(@min(name_len, 40))) / 10.0;
    const rare: f64 = 1.0 / @sqrt(@as(f64, @floatFromInt(global_count)) + 1.0);
    return len_boost * rare;
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
    var sigs: std.ArrayList(Sig) = .empty;
    var weak: std.ArrayList(Sig) = .empty;
    var n: usize = 0;

    // Definitions first, bindings only if room is left. A file's `const`s come
    // before its functions, so taking lines in order fills the whole budget
    // with the top of the file.
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const d = lex.decl(l, line) orelse continue;
        names.append(arena, hash(d.name)) catch break;
        const name_len: u8 = @intCast(@min(d.name.len, 255));
        const t = std.mem.trim(u8, line, " \t\r");
        const clip = if (t.len > 80) t[0..80] else t;
        const owned = arena.dupe(u8, clip) catch continue;
        const sig: Sig = .{ .line = owned, .name = hash(d.name), .name_len = name_len };
        if (!d.strong) {
            if (weak.items.len < max_sigs) weak.append(arena, sig) catch {};
            continue;
        }
        if (n >= max_sigs) continue;
        sigs.append(arena, sig) catch continue;
        n += 1;
    }
    for (weak.items) |sig| {
        if (n >= max_sigs) break;
        sigs.append(arena, sig) catch break;
        n += 1;
    }

    if (names.items.len == 0) return;
    const self_hits = arena.alloc(u32, names.items.len) catch return;
    countDeclaredHits(body, names.items, self_hits);
    const path = arena.dupe(u8, rel) catch return;
    s.files.append(arena, .{
        .path = path,
        .sigs = sigs.items,
        .names = names.items,
        .refs = collectRefs(arena, body),
        .self_hits = self_hits,
    }) catch {};
}

fn byScore(_: void, a: File, b: File) bool {
    if (a.score != b.score) return a.score > b.score;
    // Ties broken by path so the same repo always produces the same map; an
    // orientation aid that reshuffles between turns reads as a change.
    return std.mem.lessThan(u8, a.path, b.path);
}

fn pathMentions(path: []const u8, tokens: []const []const u8) bool {
    for (tokens) |tok| {
        if (tok.len < 2) continue;
        if (std.ascii.indexOfIgnoreCase(path, tok) != null) return true;
    }
    return false;
}

fn namesMention(names: []const u64, tokens: []const []const u8) bool {
    for (tokens) |tok| {
        if (tok.len < min_ident) continue;
        const h = hash(tok);
        for (names) |n| {
            if (n == h) return true;
        }
    }
    return false;
}

/// Cross-file credit + rarity, then a few personalized propagation passes.
fn rankFiles(arena: std.mem.Allocator, files: []File, counts: *const std.AutoHashMap(u64, u32), query: []const u8) void {
    if (files.len == 0) return;

    var tokens: [32][]const u8 = undefined;
    const tok_n = queryTokens(query, &tokens);
    const toks = tokens[0..tok_n];

    var pers = arena.alloc(f64, files.len) catch return;
    @memset(pers, 1.0);
    for (files, 0..) |f, i| {
        if (pathMentions(f.path, toks)) pers[i] *= 50.0;
        if (namesMention(f.names, toks)) pers[i] *= 10.0;
        // Long declared names are structural anchors in the personalization vector.
        for (f.sigs) |sig| {
            if (sig.name_len >= 12) pers[i] *= 1.15;
        }
    }
    var pers_sum: f64 = 0;
    for (pers) |p| pers_sum += p;
    if (pers_sum > 0) {
        for (pers) |*p| p.* /= pers_sum;
    }

    // Base mass: cross-file references to this file's declarations.
    var base = arena.alloc(f64, files.len) catch return;
    @memset(base, 0);
    for (files, 0..) |f, i| {
        var s: f64 = 0;
        for (f.names, 0..) |h, j| {
            const global = counts.get(h) orelse 0;
            const self_n = if (j < f.self_hits.len) f.self_hits[j] else 0;
            const cross = if (global > self_n) global - self_n else 0;
            const len: u8 = blk: {
                for (f.sigs) |sig| {
                    if (sig.name == h) break :blk sig.name_len;
                }
                break :blk min_ident;
            };
            s += @as(f64, @floatFromInt(cross)) * nameWeight(len, global);
        }
        base[i] = s;
    }

    // Invert declarations → defining file indices.
    var definers = std.AutoHashMap(u64, std.ArrayList(u32)).init(arena);
    for (files, 0..) |f, i| {
        for (f.names) |h| {
            const gop = definers.getOrPut(h) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.*.append(arena, @intCast(i)) catch {};
        }
    }

    const Edge = struct { to: u32, w: f64 };
    var outs = arena.alloc(std.ArrayList(Edge), files.len) catch return;
    var out_sum = arena.alloc(f64, files.len) catch return;
    @memset(out_sum, 0);
    for (outs) |*o| o.* = .empty;

    for (files, 0..) |f, r| {
        for (f.refs) |h| {
            const defs = definers.getPtr(h) orelse continue;
            const global = counts.get(h) orelse 1;
            const w = 1.0 / @sqrt(@as(f64, @floatFromInt(global)) + 1.0);
            for (defs.items) |d| {
                if (d == r) continue;
                outs[r].append(arena, .{ .to = d, .w = w }) catch {};
                out_sum[r] += w;
            }
        }
    }

    // Seed with normalized base blended into personalization so a cold query
    // still surfaces the structural spine.
    const score = arena.alloc(f64, files.len) catch return;
    var base_sum: f64 = 0;
    for (base) |b| base_sum += b;
    for (score, 0..) |*sc, i| {
        const b = if (base_sum > 0) base[i] / base_sum else 1.0 / @as(f64, @floatFromInt(files.len));
        sc.* = 0.5 * pers[i] + 0.5 * b;
    }

    const next = arena.alloc(f64, files.len) catch return;
    var iter: usize = 0;
    while (iter < rank_iters) : (iter += 1) {
        @memset(next, 0);
        var dangling: f64 = 0;
        for (outs, 0..) |o, r| {
            if (out_sum[r] <= 0 or o.items.len == 0) {
                dangling += score[r];
                continue;
            }
            for (o.items) |e| {
                next[e.to] += damp * score[r] * (e.w / out_sum[r]);
            }
        }
        for (next, 0..) |*n, i| {
            n.* += (1.0 - damp) * pers[i];
            n.* += damp * dangling * pers[i];
        }
        @memcpy(score, next);
    }

    for (files, 0..) |*f, i| f.score = score[i];
}

fn emitMap(
    allocator: std.mem.Allocator,
    files: []File,
    counts: *const std.AutoHashMap(u64, u32),
    truncated: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (truncated) {
        try out.print(allocator, "Repo map ({d} most-referenced files; the scan stopped at {d}):\n", .{
            @min(files.len, max_files),
            max_scan_files,
        });
    } else if (files.len > max_files) {
        try out.print(allocator, "Repo map ({d} most-referenced of {d} files, signatures only):\n", .{
            max_files,
            files.len,
        });
    } else {
        try out.appendSlice(allocator, "Repo map (signatures, not bodies):\n");
    }

    // Files are already score-sorted. Within each file, emit higher-specificity
    // signatures first and stop when the char budget is gone — so a mid-ranked
    // file can still contribute one sharp sig instead of losing the slot to a
    // hub file's sixth weak binding.
    var emitted: usize = 0;
    for (files) |f| {
        if (emitted >= max_files or out.items.len >= max_chars) break;

        var order: [max_sigs]Sig = undefined;
        const n = @min(f.sigs.len, max_sigs);
        @memcpy(order[0..n], f.sigs[0..n]);
        std.mem.sort(Sig, order[0..n], counts, struct {
            fn cmp(c: *const std.AutoHashMap(u64, u32), a: Sig, b: Sig) bool {
                const wa = nameWeight(a.name_len, c.get(a.name) orelse 0);
                const wb = nameWeight(b.name_len, c.get(b.name) orelse 0);
                if (wa != wb) return wa > wb;
                return std.mem.lessThan(u8, a.line, b.line);
            }
        }.cmp);

        const header_len = f.path.len + 1;
        if (out.items.len + header_len > max_chars) break;
        try out.appendSlice(allocator, f.path);
        try out.append(allocator, '\n');
        emitted += 1;

        for (order[0..n]) |sig| {
            const need = sig.line.len + 3;
            if (out.items.len + need > max_chars) break;
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, sig.line);
            try out.append(allocator, '\n');
        }
    }
    if (out.items.len > max_chars) out.shrinkRetainingCapacity(max_chars);
    return out.toOwnedSlice(allocator);
}

pub fn build(allocator: std.mem.Allocator, dir: Io.Dir, io: Io) ![]u8 {
    return buildFor(allocator, dir, io, "");
}

/// Same as `build`, but personalize ranking toward `query` tokens (paths and
/// identifier names). Empty query → structural spine only.
pub fn buildFor(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, query: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = Scan{
        .files = .empty,
        .counts = std.AutoHashMap(u64, u32).init(arena),
    };

    var root = dir.openDir(io, ".", .{ .iterate = true }) catch {
        return allocator.dupe(u8, "Repo map (signatures, not bodies):\n");
    };
    defer root.close(io);
    walk(arena, root, io, "", &s);

    rankFiles(arena, s.files.items, &s.counts, query);
    std.mem.sort(File, s.files.items, {}, byScore);

    return emitMap(allocator, s.files.items, &s.counts, s.truncated);
}

/// Hybrid retrieval: RepoGraph reference scores + lexical token hits + symbol
/// names, fused with reciprocal rank fusion. No embeddings, no index on disk.
pub const max_search_hits: usize = 32;
const rrf_k: usize = 60;

const SearchHit = struct {
    path: []const u8,
    sig: []const u8,
    lex: usize = 0,
    sym: usize = 0,
    ref_score: u64 = 0,
    rrf: f64 = 0,
};

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn pushToken(out: *[32][]const u8, n: *usize, tok: []const u8) void {
    if (tok.len < 2 or n.* >= out.len) return;
    for (out[0..n.*]) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, tok)) return;
    }
    out[n.*] = tok;
    n.* += 1;
}

/// Split query and identifiers into searchable tokens (camelCase / snake_case).
fn queryTokens(query: []const u8, out: *[32][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < query.len) {
        while (i < query.len and !isIdentByte(query[i])) i += 1;
        if (i >= query.len) break;
        const start = i;
        while (i < query.len and isIdentByte(query[i])) i += 1;
        const word = query[start..i];
        pushToken(out, &n, word);
        var j: usize = 0;
        while (j < word.len) {
            const c = word[j];
            if (c == '_' or c == '-') {
                j += 1;
                continue;
            }
            if (j + 1 < word.len and isLower(c) and isUpper(word[j + 1])) {
                pushToken(out, &n, word[0 .. j + 1]);
                j += 1;
                continue;
            }
            if (j + 1 < word.len and isUpper(c) and isUpper(word[j + 1]) and j + 2 < word.len and isLower(word[j + 2])) {
                pushToken(out, &n, word[0 .. j + 1]);
                j += 1;
                continue;
            }
            j += 1;
        }
        var words = std.mem.splitAny(u8, word, "_-");
        while (words.next()) |part| pushToken(out, &n, part);
    }
    var spaced = std.mem.splitAny(u8, query, " \t\r\n");
    while (spaced.next()) |w| {
        const t = std.mem.trim(u8, w, " \t");
        if (t.len >= 2) pushToken(out, &n, t);
    }
    return n;
}

fn rankBy(
    hits: []SearchHit,
    ranks: *[max_search_hits]usize,
    n: usize,
    comptime field: enum { lex, sym, ref },
) void {
    var order: [max_search_hits]usize = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) order[i] = i;
    std.mem.sort(usize, order[0..n], hits, struct {
        fn cmp(h: []SearchHit, a: usize, b: usize) bool {
            const ha = h[a];
            const hb = h[b];
            const va: u64 = switch (field) {
                .lex => ha.lex,
                .sym => ha.sym,
                .ref => ha.ref_score,
            };
            const vb: u64 = switch (field) {
                .lex => hb.lex,
                .sym => hb.sym,
                .ref => hb.ref_score,
            };
            if (va != vb) return va > vb;
            return std.mem.lessThan(u8, ha.path, hb.path);
        }
    }.cmp);
    i = 0;
    while (i < n) : (i += 1) ranks[order[i]] = i + 1;
}

fn scoreLex(tokens: []const []const u8, path: []const u8, sigs: []const Sig) usize {
    var score: usize = 0;
    for (tokens) |tok| {
        if (std.mem.indexOf(u8, path, tok) != null) score += 3;
        var count: usize = 0;
        for (sigs) |sig| {
            if (std.ascii.indexOfIgnoreCase(sig.line, tok) != null) count += 1;
        }
        score += @min(count, 4);
    }
    return score;
}

fn scoreSym(tokens: []const []const u8, names: []const u64) usize {
    var score: usize = 0;
    for (tokens) |tok| {
        if (tok.len < min_ident) continue;
        const h = hash(tok);
        for (names) |n| {
            if (n == h) score += 5;
        }
    }
    return score;
}

pub fn search(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    query: []const u8,
) ![]u8 {
    if (query.len == 0) return error.EmptyNeedle;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = Scan{
        .files = .empty,
        .counts = std.AutoHashMap(u64, u32).init(arena),
    };

    var root = dir.openDir(io, ".", .{ .iterate = true }) catch {
        return allocator.dupe(u8, "(no matches)\n");
    };
    defer root.close(io);
    walk(arena, root, io, "", &s);

    rankFiles(arena, s.files.items, &s.counts, query);

    var tokens: [32][]const u8 = undefined;
    const tok_n = queryTokens(query, &tokens);
    if (tok_n == 0) return allocator.dupe(u8, "(no matches)\n");

    var hits: [max_search_hits]SearchHit = undefined;
    var n: usize = 0;
    for (s.files.items) |f| {
        if (n >= hits.len) break;
        const lex_score = scoreLex(tokens[0..tok_n], f.path, f.sigs);
        const sym = scoreSym(tokens[0..tok_n], f.names);
        const ref_u: u64 = @intFromFloat(@min(f.score * 1_000_000.0, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
        if (lex_score == 0 and sym == 0 and ref_u == 0) continue;
        const sig_line = if (f.sigs.len > 0) f.sigs[0].line else "";
        hits[n] = .{
            .path = try arena.dupe(u8, f.path),
            .sig = sig_line,
            .lex = lex_score,
            .sym = sym,
            .ref_score = ref_u,
        };
        n += 1;
    }
    if (n == 0) return allocator.dupe(u8, "(no matches)\n");

    var rank_lex: [max_search_hits]usize = undefined;
    var rank_sym: [max_search_hits]usize = undefined;
    var rank_ref: [max_search_hits]usize = undefined;
    @memset(&rank_lex, n + 1);
    @memset(&rank_sym, n + 1);
    @memset(&rank_ref, n + 1);
    rankBy(hits[0..n], &rank_lex, n, .lex);
    rankBy(hits[0..n], &rank_sym, n, .sym);
    rankBy(hits[0..n], &rank_ref, n, .ref);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rl = rank_lex[i];
        const rs = rank_sym[i];
        const rr = rank_ref[i];
        hits[i].rrf = 1.0 / @as(f64, @floatFromInt(rrf_k + rl)) +
            1.0 / @as(f64, @floatFromInt(rrf_k + rs)) +
            1.0 / @as(f64, @floatFromInt(rrf_k + rr));
    }

    std.mem.sort(SearchHit, hits[0..n], {}, struct {
        fn cmp(_: void, a: SearchHit, b: SearchHit) bool {
            if (a.rrf != b.rrf) return a.rrf > b.rrf;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.cmp);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "semantic_search (hybrid: repo rank + symbols + tokens)\n");
    for (hits[0..n]) |h| {
        if (h.sig.len > 0) {
            try out.print(allocator, "{s}\n  {s}\n", .{ h.path, std.mem.trim(u8, h.sig, " \t") });
        } else {
            try out.appendSlice(allocator, h.path);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "search finds files by symbol reference and token" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, "hot.zig", "pub fn sharedHelper() void {}\n");
    try writeFile(tmp.dir, io, "cold.zig", "pub fn lonelyThing() void {}\n");
    try writeFile(tmp.dir, io, "one.zig", "pub fn useA() void { sharedHelper(); }\n");
    try writeFile(tmp.dir, io, "two.zig", "pub fn useB() void { sharedHelper(); }\n");
    const got = try search(a, tmp.dir, io, "sharedHelper");
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "hot.zig") != null);
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

test "query tokens pull matching files ahead of global hubs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "hub.zig", "pub fn sharedHelper() void {}\n");
    try writeFile(tmp.dir, io, "auth_flow.zig", "pub fn verifySessionToken() void {}\n");
    try writeFile(tmp.dir, io, "one.zig", "pub fn useA() void { sharedHelper(); }\n");
    try writeFile(tmp.dir, io, "two.zig", "pub fn useB() void { sharedHelper(); }\n");
    try writeFile(tmp.dir, io, "three.zig", "pub fn useC() void { sharedHelper(); }\n");

    const plain = try build(a, tmp.dir, io);
    defer a.free(plain);
    const personalized = try buildFor(a, tmp.dir, io, "fix verifySessionToken");
    defer a.free(personalized);

    const auth_plain = std.mem.indexOf(u8, plain, "auth_flow.zig");
    const auth_pers = std.mem.indexOf(u8, personalized, "auth_flow.zig").?;
    const hub_pers = std.mem.indexOf(u8, personalized, "hub.zig").?;
    try std.testing.expect(auth_pers < hub_pers);
    // Without a query the hub of sharedHelper still leads; with one, auth rises.
    if (auth_plain) |ap| {
        const hub_plain = std.mem.indexOf(u8, plain, "hub.zig").?;
        try std.testing.expect(hub_plain < ap);
    }
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
