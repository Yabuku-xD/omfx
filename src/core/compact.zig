const std = @import("std");
const Io = std.Io;
const recall = @import("recall.zig");

pub const Turn = struct {
    role: []const u8,
    text: []const u8,
};

pub const Result = union(enum) {
    keep,
    drop: usize,
};

pub const Applied = enum { skipped, applied };

/// Summarize the dropped prefix. Never encrypt. Never rewrite the last `keep_last` turns.
pub const keep_last: usize = 4;
pub const compact_after: usize = 8;
const drop_placeholder: []const u8 = "earlier turns summarized";

comptime {
    if (keep_last == 0) @compileError("keep_last must keep a live tail");
    if (compact_after <= keep_last) @compileError("compact_after must exceed keep_last");
}

pub fn plan(turn_count: usize) Result {
    if (turn_count <= compact_after) return .keep;
    return .{ .drop = turn_count - keep_last };
}

pub fn summarizePrefix(allocator: std.mem.Allocator, turns: []const Turn, kept_from: usize) ![]u8 {
    var n: usize = 0;
    var chars: usize = 0;
    var last_role: []const u8 = "";
    var last_chars: usize = 0;
    var cites: [recall.max_items]recall.Id = undefined;
    var cite_n: usize = 0;
    for (turns[0..kept_from]) |t| {
        n += 1;
        chars += t.text.len;
        last_role = t.role;
        last_chars = t.text.len;
        var found: [recall.max_items]recall.Id = undefined;
        const got = recall.collectIds(t.text, &found);
        for (found[0..got]) |id| recall.take(&cites, &cite_n, id);
    }
    switch (cite_n) {
        0 => return std.fmt.allocPrint(
            allocator,
            "Dropped {d} earlier turns ({d} chars). Last role={s} ({d} chars). Bodies at .omfx/recall if cited. Continue from the kept tail.",
            .{ n, chars, last_role, last_chars },
        ),
        else => {
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(allocator);
            try list.appendSlice(allocator, "cites ");
            for (cites[0..cite_n], 0..) |id, i| {
                if (i != 0) try list.append(allocator, ',');
                var ibuf: [16]u8 = undefined;
                const piece = std.fmt.bufPrint(&ibuf, "r{d}", .{@intFromEnum(id)}) catch "r?";
                try list.appendSlice(allocator, piece);
            }
            const out = try std.fmt.allocPrint(
                allocator,
                "Dropped {d} earlier turns ({d} chars). Last role={s} ({d} chars). {s}. read .omfx/recall/rN.txt. Continue from the kept tail.",
                .{ n, chars, last_role, last_chars, list.items },
            );
            list.deinit(allocator);
            return out;
        },
    }
}

/// arXiv:2604.14228 five-layer compact, local and inspectable. Never encrypt.
/// L1 budget reduction: cap one tool result. L5 auto: also fire on char count.
pub const result_budget: usize = 12_000;
pub const char_budget: usize = 48_000;

pub fn charCount(turns: []const Turn) usize {
    var n: usize = 0;
    for (turns) |t| n += t.text.len;
    return n;
}

pub fn capResult(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len <= result_budget) return allocator.dupe(u8, s);
    return std.fmt.allocPrint(
        allocator,
        "{s}\ntruncated at {d} bytes (layer1 budget)\n",
        .{ s[0..result_budget], result_budget },
    );
}

pub const Stitched = union(enum) {
    copy: []Turn,
    compacted: struct {
        turns: []Turn,
        summary: []u8,
    },

    pub fn deinit(self: Stitched, allocator: std.mem.Allocator) void {
        switch (self) {
            .copy => |t| allocator.free(t),
            .compacted => |c| {
                allocator.free(c.turns);
                allocator.free(c.summary);
            },
        }
    }
};

/// Compact the HTTP thread: always keep turns[0] (the original user prompt),
/// replace the middle with a 2-turn summary so roles still alternate, keep the tail.
pub fn planKeepOriginalEx(count: usize, chars: usize) Result {
    if (count <= compact_after and chars <= char_budget) return .keep;
    var from: usize = if (count > keep_last) count - keep_last else 2;
    if (from < 2 or from >= count) return .keep;
    // Tail should start on assistant (odd index) so the inserted summary pair
    // (assistant, user) still alternates after the original user message.
    if (from % 2 == 0) from -= 1;
    // Re-checked after the parity step, not only before it. `from == 1` drops
    // `turns[1..1]` -- nothing -- while still inserting the placeholder and an
    // empty summary, so "compaction" handed back a *longer* thread than it was
    // given, every turn, forever.
    //
    // A short thread that is merely large still has to shrink, so clamp up to
    // the first valid point rather than giving up: dropping one more turn is
    // what the char budget is asking for.
    if (from < 2) {
        if (3 >= count) return .keep;
        from = 3;
    }
    return .{ .drop = from };
}

pub fn stitch(allocator: std.mem.Allocator, turns: []const Turn) !Stitched {
    switch (planKeepOriginalEx(turns.len, charCount(turns))) {
        .keep => return .{ .copy = try allocator.dupe(Turn, turns) },
        .drop => |from| {
            if (turns.len == 0 or from >= turns.len) return .{ .copy = try allocator.dupe(Turn, turns) };
            const dropped = turns[1..from];
            const summary = try summarizePrefix(allocator, dropped, dropped.len);
            var out: std.ArrayList(Turn) = .empty;
            errdefer {
                out.deinit(allocator);
                allocator.free(summary);
            }
            try out.append(allocator, turns[0]);
            try out.append(allocator, .{ .role = "assistant", .text = drop_placeholder });
            try out.append(allocator, .{ .role = "user", .text = summary });
            for (turns[from..]) |t| {
                try out.append(allocator, t);
            }
            return .{
                .compacted = .{
                    .turns = try out.toOwnedSlice(allocator),
                    .summary = summary,
                },
            };
        },
    }
}

test "no compact under threshold" {
    try std.testing.expect(plan(8) == .keep);
}

test "compact keeps last four verbatim" {
    try std.testing.expectEqual(Result{ .drop = 8 }, plan(12));
}

test "summary does not include tail text" {
    const turns = [_]Turn{
        .{ .role = "user", .text = "old-a" },
        .{ .role = "assistant", .text = "old-b" },
        .{ .role = "user", .text = "keep-1" },
        .{ .role = "assistant", .text = "keep-2" },
        .{ .role = "user", .text = "keep-3" },
        .{ .role = "assistant", .text = "keep-4" },
    };
    const s = try summarizePrefix(std.testing.allocator, &turns, 2);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "old-a") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "keep-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "2 earlier") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Last role=") != null);
}

test "summary lists cite ids from dropped turns" {
    const turns = [_]Turn{
        .{ .role = "user", .text = "cite r3 tool=bash chars=12. read .omfx/recall/r3.txt for the body.\n" },
        .{ .role = "assistant", .text = "ok" },
        .{ .role = "user", .text = "keep-1" },
        .{ .role = "assistant", .text = "keep-2" },
    };
    const s = try summarizePrefix(std.testing.allocator, &turns, 2);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "cites r3") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "drop-secret") == null);
}

test "char budget fires compact under turn threshold" {
    try std.testing.expect(planKeepOriginalEx(4, char_budget + 1) == .drop);
}

test "capResult names the layer1 budget" {
    const buf = "x" ** 12_010;
    const s = try capResult(std.testing.allocator, buf);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "truncated at 12000 bytes (layer1 budget)") != null);
}

test "summary is not encrypted_content" {
    const turns = [_]Turn{
        .{ .role = "user", .text = "KEEP-ME" },
        .{ .role = "assistant", .text = "a" },
        .{ .role = "user", .text = "b" },
        .{ .role = "assistant", .text = "c" },
        .{ .role = "user", .text = "d" },
        .{ .role = "assistant", .text = "e" },
        .{ .role = "user", .text = "f" },
        .{ .role = "assistant", .text = "g" },
        .{ .role = "user", .text = "h" },
        .{ .role = "assistant", .text = "TAIL" },
        .{ .role = "user", .text = "TAIL" },
        .{ .role = "assistant", .text = "TAIL" },
    };
    const stitched = try stitch(std.testing.allocator, &turns);
    defer stitched.deinit(std.testing.allocator);
    const summary = stitched.compacted.summary;
    try std.testing.expect(std.mem.indexOf(u8, summary, "encrypted_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "earlier turns") != null);
}

test "stitch under threshold is a copy" {
    const turns = [_]Turn{
        .{ .role = "user", .text = "KEEP-ME" },
        .{ .role = "assistant", .text = "a" },
        .{ .role = "user", .text = "b" },
    };
    const stitched = try stitch(std.testing.allocator, &turns);
    defer stitched.deinit(std.testing.allocator);
    try std.testing.expect(stitched == .copy);
    try std.testing.expectEqual(@as(usize, 3), stitched.copy.len);
    try std.testing.expectEqualStrings("KEEP-ME", stitched.copy[0].text);
}

test "bench: compact stitch and capResult timings" {
    const a = std.testing.allocator;
    var fat: [13_000]u8 = undefined;
    @memset(&fat, 'x');

    var turns: [12]Turn = undefined;
    turns[0] = .{ .role = "user", .text = "orig" };
    var i: usize = 1;
    while (i < 12) : (i += 1) {
        turns[i] = .{
            .role = if (i % 2 == 0) "user" else "assistant",
            .text = "turn",
        };
    }

    const io = std.testing.io;
    var t0 = Io.Clock.Timestamp.now(io, .awake);
    {
        const st = try stitch(a, turns[0..8]);
        defer st.deinit(a);
        try std.testing.expect(st == .copy);
    }
    const keep_ns = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;

    t0 = Io.Clock.Timestamp.now(io, .awake);
    {
        const st = try stitch(a, &turns);
        defer st.deinit(a);
        try std.testing.expect(st == .compacted);
    }
    const turn_ns = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;

    var fat_turns: [12]Turn = undefined;
    fat_turns[0] = .{ .role = "user", .text = "orig" };
    i = 1;
    while (i < 12) : (i += 1) {
        fat_turns[i] = .{
            .role = if (i % 2 == 0) "user" else "assistant",
            .text = &fat,
        };
    }
    const fat_chars = charCount(&fat_turns);
    t0 = Io.Clock.Timestamp.now(io, .awake);
    {
        const st = try stitch(a, &fat_turns);
        defer st.deinit(a);
        try std.testing.expect(st == .compacted);
    }
    const fat_ns = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;

    t0 = Io.Clock.Timestamp.now(io, .awake);
    {
        const s = try capResult(a, &fat);
        defer a.free(s);
        try std.testing.expect(s.len > result_budget);
    }
    const cap_ns = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;

    std.debug.print(
        "BENCH compact keep_ns={d} turn_ns={d} fat_ns={d} cap_ns={d} fat_chars={d}\n",
        .{ keep_ns, turn_ns, fat_ns, cap_ns, fat_chars },
    );
    try std.testing.expect(fat_ns < 50_000_000);
}

test "stitch keeps original and tail, drops middle" {
    var turns: [12]Turn = undefined;
    turns[0] = .{ .role = "user", .text = "KEEP-ME" };
    var i: usize = 1;
    while (i < 7) : (i += 1) {
        turns[i] = .{
            .role = if (i % 2 == 0) "user" else "assistant",
            .text = "drop-secret",
        };
    }
    while (i < 12) : (i += 1) {
        turns[i] = .{
            .role = if (i % 2 == 0) "user" else "assistant",
            .text = "TAIL",
        };
    }
    const stitched = try stitch(std.testing.allocator, &turns);
    defer stitched.deinit(std.testing.allocator);
    const compacted = stitched.compacted;
    try std.testing.expectEqualStrings("KEEP-ME", compacted.turns[0].text);
    try std.testing.expectEqualStrings("user", compacted.turns[0].role);
    var saw_tail = false;
    for (compacted.turns) |t| {
        try std.testing.expect(std.mem.indexOf(u8, t.text, "drop-secret") == null);
        if (std.mem.eql(u8, t.text, "TAIL")) saw_tail = true;
    }
    try std.testing.expect(saw_tail);
    try std.testing.expect(std.mem.indexOf(u8, compacted.summary, "drop-secret") == null);
    var r: usize = 0;
    while (r + 1 < compacted.turns.len) : (r += 1) {
        try std.testing.expect(!std.mem.eql(u8, compacted.turns[r].role, compacted.turns[r + 1].role));
    }
}

test "compaction never returns a longer thread than it was given" {
    const a = std.testing.allocator;
    const big = "x" ** 30_000;
    // Four turns, well over char_budget: the case char-driven compaction exists
    // for, and the one that used to grow.
    var turns = [_]Turn{
        .{ .role = "user", .text = "q" },
        .{ .role = "assistant", .text = big },
        .{ .role = "user", .text = big },
        .{ .role = "assistant", .text = "a" },
    };
    var st = try stitch(a, &turns);
    defer st.deinit(a);
    const out = switch (st) {
        .copy => |c| c,
        .compacted => |c| c.turns,
    };
    try std.testing.expect(out.len <= turns.len);
    try std.testing.expect(charCount(out) <= charCount(&turns));
}

test "a drop point always leaves something to drop" {
    // Every count/char pair must either keep, or name a point with at least one
    // turn behind it. `from == 1` is the value that produced a no-op drop.
    var count: usize = 0;
    while (count < 64) : (count += 1) {
        for ([_]usize{ 0, 1_000, char_budget + 1, 10 * char_budget }) |chars| {
            switch (planKeepOriginalEx(count, chars)) {
                .keep => {},
                .drop => |from| {
                    try std.testing.expect(from >= 2);
                    try std.testing.expect(from < count);
                    // Odd, so the tail still starts on an assistant turn.
                    try std.testing.expect(from % 2 == 1);
                },
            }
        }
    }
}
