const std = @import("std");
const board = @import("board.zig");

/// Rodrigues arXiv:2606.21666, calibrated: 1.1% false positives at 0.25,
/// 5.6% at 0.22, 0% at 0.28. Sync only above this; 2-3 steps of lag is intended.
pub const tau: f64 = 0.25;
/// Paper ContextSummary is 3 sentences. One board note ≈ one sentence.
pub const summary_notes: usize = 3;
pub const max_tokens: usize = 96;

comptime {
    if (!(tau > 0 and tau < 1)) @compileError("divergence tau must be in (0, 1)");
    if (summary_notes == 0) @compileError("summary_notes must keep a gist");
    if (max_tokens == 0) @compileError("max_tokens must hold a bag");
}

pub const Role = enum { self, peer };

pub const Adopt = union(enum) {
    none,
    merge: []u8,
};

pub fn summary(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var notes: [board.max_notes]board.Note = undefined;
    const n = board.parseAll(text, &notes);
    if (n == 0) return allocator.dupe(u8, "");
    const start = if (n > summary_notes) n - summary_notes else 0;
    return board.format(allocator, notes[start..n]);
}

const Bin = struct { hash: u64, n: f64 };

const Bag = struct {
    bins: [max_tokens]Bin = undefined,
    len: usize = 0,

    fn add(self: *Bag, token: []const u8) void {
        const h = std.hash.Wyhash.hash(0, token);
        for (self.bins[0..self.len]) |*bin| {
            if (bin.hash == h) {
                bin.n += 1;
                return;
            }
        }
        if (self.len >= max_tokens) return;
        self.bins[self.len] = .{ .hash = h, .n = 1 };
        self.len += 1;
    }
};

fn fillBag(text: []const u8) Bag {
    var bag = Bag{};
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
        if (start == i) break;
        const raw = text[start..i];
        const n = @min(raw.len, buf.len);
        for (raw[0..n], 0..) |c, k| buf[k] = std.ascii.toLower(c);
        bag.add(buf[0..n]);
    }
    return bag;
}

/// Lexical divergence: 1 − cosine over token-count vectors. Range 0..1.
///
/// This is a **proxy** for the paper's CDS, not the paper's CDS. Rodrigues
/// (arXiv:2606.21666) computes cosine over an *embedding* of a 3-sentence
/// summary; this compares word bags, which needs no model call and no network.
///
/// The failure modes differ, so do not read a score here as the paper's metric:
/// different words for the same meaning score as divergence, and the same words
/// rearranged score as agreement. It catches the paper's own worked example
/// (Barcelona vs Lisbon) because those are literally different tokens.
///
/// `tau` is still the paper's calibrated threshold; only the distance changed.
pub fn lexicalDivergence(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 and b.len == 0) return 0;
    if (a.len == 0 or b.len == 0) return 1;
    const ba = fillBag(a);
    const bb = fillBag(b);
    var dot: f64 = 0;
    for (ba.bins[0..ba.len]) |left| {
        for (bb.bins[0..bb.len]) |right| {
            if (left.hash == right.hash) {
                dot += left.n * right.n;
                break;
            }
        }
    }
    var na: f64 = 0;
    for (ba.bins[0..ba.len]) |bin| na += bin.n * bin.n;
    var nb: f64 = 0;
    for (bb.bins[0..bb.len]) |bin| nb += bin.n * bin.n;
    const denom = @sqrt(na) * @sqrt(nb);
    if (denom == 0) return 1;
    return 1.0 - (dot / denom);
}

pub fn needsMerge(mine: []const u8, incoming: []const u8) bool {
    if (mine.len == 0 or incoming.len == 0) return false;
    if (std.mem.eql(u8, mine, incoming)) return false;
    return lexicalDivergence(mine, incoming) > tau;
}

pub fn mergePrompt(allocator: std.mem.Allocator, mine: []const u8, incoming: []const u8) ![]u8 {
    const score = lexicalDivergence(mine, incoming);
    return std.fmt.allocPrint(
        allocator,
        \\Note (kept):
        \\ContextMerge CDS={d:.2} exceeds tau={d:.2}.
        \\Your last gist:
        \\{s}
        \\Incoming gist:
        \\{s}
        \\Identify any beliefs you hold that directly contradict the incoming context. State which source is more likely authoritative given the timestamps and information quality involved. Do not silently overwrite. Then continue.
        \\
    ,
        .{ score, tau, mine, incoming },
    );
}

fn take(allocator: std.mem.Allocator, last: *[]u8, now: []const u8) !void {
    const next = try allocator.dupe(u8, now);
    allocator.free(last.*);
    last.* = next;
}

/// Keep `last` unchanged while CDS ≤ τ (lag is allowed). On trip, return ContextMerge and adopt `now`.
pub fn adopt(
    allocator: std.mem.Allocator,
    last: *[]u8,
    now: []const u8,
    role: Role,
) !Adopt {
    if (now.len == 0) return .none;
    if (last.*.len == 0) {
        try take(allocator, last, now);
        return .none;
    }
    return switch (role) {
        .self => blk: {
            if (!std.mem.eql(u8, last.*, now)) try take(allocator, last, now);
            break :blk .none;
        },
        .peer => blk: {
            if (!needsMerge(last.*, now)) break :blk .none;
            const msg = try mergePrompt(allocator, last.*, now);
            errdefer allocator.free(msg);
            try take(allocator, last, now);
            break :blk .{ .merge = msg };
        },
    };
}

test "identical gists do not merge" {
    const a = "Note (kept):\n[FACT] path=src/a.zig printer bypasses join\n";
    try std.testing.expect(!needsMerge(a, a));
    try std.testing.expect(lexicalDivergence(a, a) < 0.01);
}

test "Barcelona vs Lisbon exceeds tau" {
    const planner = "Planner destination Barcelona dates May budget 2000";
    const booking = "Booking destination Lisbon airport LIS budget 2000";
    try std.testing.expect(lexicalDivergence(planner, booking) > tau);
    try std.testing.expect(needsMerge(planner, booking));
}

test "one extra FAIL on a shared FACT stays under tau" {
    const a = "Note (kept):\n[FACT] path=src/a.zig printer bypasses join\n";
    const b = "Note (kept):\n[FACT] path=src/a.zig printer bypasses join\n[FAIL] changing StrPrinter did not affect output\n";
    try std.testing.expect(lexicalDivergence(a, b) <= tau);
    try std.testing.expect(!needsMerge(a, b));
}

test "empty last gist bootstraps without merge" {
    var last = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(last);
    const now = "Note (kept):\n[FACT] path=a.zig x\n";
    try std.testing.expectEqual(Adopt.none, try adopt(std.testing.allocator, &last, now, .peer));
    try std.testing.expectEqualStrings(now, last);
}

test "peer adopt merges when CDS exceeds tau and then stays quiet" {
    var last = try std.testing.allocator.dupe(u8, "Planner destination Barcelona dates May budget 2000");
    defer std.testing.allocator.free(last);
    const incoming = "Booking destination Lisbon airport LIS budget 2000";
    const first = try adopt(std.testing.allocator, &last, incoming, .peer);
    try std.testing.expect(first == .merge);
    defer std.testing.allocator.free(first.merge);
    try std.testing.expect(std.mem.indexOf(u8, first.merge, "ContextMerge") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.merge, "Do not silently overwrite") != null);
    try std.testing.expectEqualStrings(incoming, last);
    try std.testing.expectEqual(Adopt.none, try adopt(std.testing.allocator, &last, incoming, .peer));
}

test "self adopt never ContextMerges" {
    var last = try std.testing.allocator.dupe(u8, "Planner destination Barcelona dates May budget 2000");
    defer std.testing.allocator.free(last);
    const incoming = "Booking destination Lisbon airport LIS budget 2000";
    try std.testing.expectEqual(Adopt.none, try adopt(std.testing.allocator, &last, incoming, .self));
    try std.testing.expectEqualStrings(incoming, last);
}

test "summary is the last three notes" {
    const text =
        \\FACT path=a.zig one
        \\FAIL two
        \\PATH path=b.zig three
        \\FACT path=c.zig four
        \\
    ;
    const s = try summary(std.testing.allocator, text);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "four") != null);
}

test "tau is the paper value" {
    try std.testing.expectEqual(@as(f64, 0.25), tau);
}
