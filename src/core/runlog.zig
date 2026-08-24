//! One append-only JSONL record per turn.
//!
//! The smallest thing that answers "is it getting worse": tokens, latency,
//! tool count and verdict, one line each, greppable with `jq` and shaped like
//! the OpenTelemetry GenAI fields so moving to a platform later changes where
//! the records go, not what they say.
//!
//! No prompt or reply text is written. An operational log you can read freely
//! is worth more than one you have to treat as radioactive, and the full
//! transcript already lives in the session file next to it.

const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");

const log = std.log.scoped(.runlog);

pub const file_name = "turns.jsonl";
/// Receipt: a record is ~130 bytes, so this is ~1.3 MB of history. Past that
/// the oldest turns are dropped on the next write rather than growing forever.
pub const max_records: usize = 10_000;
/// Turns a summary reads back. More than this and the average stops describing
/// what the tool is doing now.
pub const window: usize = 20;
/// The read cap that matches `max_records` at ~130 bytes a record, with room
/// for a long model name.
pub const max_bytes: usize = 4_000_000;

pub const Record = struct {
    at_ms: i64,
    model: []const u8,
    ms: i64,
    tokens: u32,
    tools: u16,
    /// "continued", "denied", "interrupted", "failed".
    verdict: []const u8,
    chars: usize,
};

fn path(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const root = try config.profileRoot(allocator, home);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, file_name });
}

/// Best effort: a turn that happened is worth more than a log of it, so a
/// failure here is logged and swallowed.
pub fn append(allocator: std.mem.Allocator, io: Io, home: []const u8, rec: Record) void {
    const p = path(allocator, home) catch return;
    defer allocator.free(p);
    const dir = std.fs.path.dirname(p) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.debug("mkdir {s}: {s}", .{ dir, @errorName(err) });
        return;
    };
    const line = std.fmt.allocPrint(
        allocator,
        "{{\"at\":{d},\"model\":\"{s}\",\"ms\":{d},\"tokens\":{d},\"tools\":{d},\"verdict\":\"{s}\",\"chars\":{d}}}\n",
        .{ rec.at_ms, rec.model, rec.ms, rec.tokens, rec.tools, rec.verdict, rec.chars },
    ) catch return;
    defer allocator.free(line);

    // Read, extend, write. `Io.File` has no append mode here, and rewriting is
    // also what keeps the file bounded: the oldest turns fall off the front.
    const old = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_bytes)) catch "";
    defer if (old.len > 0) allocator.free(old);
    const next = trimTo(allocator, old, line) catch return;
    defer allocator.free(next);

    var file = Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch |err| {
        log.debug("open {s}: {s}", .{ p, @errorName(err) });
        return;
    };
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(next) catch {};
    w.interface.flush() catch {};
}

/// `old` plus `line`, holding at most `max_records` records.
fn trimTo(allocator: std.mem.Allocator, old: []const u8, line: []const u8) ![]u8 {
    var count: usize = 0;
    for (old) |c| {
        if (c == '\n') count += 1;
    }
    var from: usize = 0;
    while (count >= max_records) : (count -= 1) {
        const nl = std.mem.indexOfScalarPos(u8, old, from, '\n') orelse break;
        from = nl + 1;
    }
    return std.mem.concat(allocator, u8, &.{ old[from..], line });
}

pub const Stat = struct {
    turns: usize = 0,
    tokens: u64 = 0,
    ms: i64 = 0,
    tools: u32 = 0,
    denied: usize = 0,

    fn note(self: *Stat, rec: Parsed) void {
        self.turns += 1;
        self.tokens += rec.tokens;
        self.ms += rec.ms;
        self.tools += rec.tools;
        if (!std.mem.eql(u8, rec.verdict, "continued")) self.denied += 1;
    }

    pub fn avgMs(self: Stat) i64 {
        return if (self.turns == 0) 0 else @divTrunc(self.ms, @as(i64, @intCast(self.turns)));
    }

    pub fn avgTokens(self: Stat) u64 {
        return if (self.turns == 0) 0 else self.tokens / self.turns;
    }
};

const Parsed = struct {
    ms: i64 = 0,
    tokens: u32 = 0,
    tools: u16 = 0,
    verdict: []const u8 = "continued",
};

fn number(line: []const u8, key: []const u8) i64 {
    const at = std.mem.indexOf(u8, line, key) orelse return 0;
    var i = at + key.len;
    var neg = false;
    if (i < line.len and line[i] == '-') {
        neg = true;
        i += 1;
    }
    var n: i64 = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {
        n = n * 10 + (line[i] - '0');
    }
    return if (neg) -n else n;
}

fn text(line: []const u8, key: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return "";
    const from = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, from, '"') orelse return "";
    return line[from..end];
}

fn parse(line: []const u8) ?Parsed {
    if (std.mem.indexOf(u8, line, "\"at\":") == null) return null;
    return .{
        .ms = number(line, "\"ms\":"),
        .tokens = @intCast(@max(0, number(line, "\"tokens\":"))),
        .tools = @intCast(@max(0, number(line, "\"tools\":"))),
        .verdict = text(line, "\"verdict\":\""),
    };
}

/// The last `window` turns, and the `window` before them. Two numbers side by
/// side is the smallest thing that shows a regression; one number shows only
/// that work happened.
pub const Compare = struct {
    now: Stat = .{},
    before: Stat = .{},
};

pub fn compare(allocator: std.mem.Allocator, io: Io, home: []const u8) Compare {
    const p = path(allocator, home) catch return .{};
    defer allocator.free(p);
    const blob = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(max_bytes)) catch return .{};
    defer allocator.free(blob);
    return compareBlob(blob);
}

pub fn compareBlob(blob: []const u8) Compare {
    var recent: [window * 2]Parsed = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        const rec = parse(line) orelse continue;
        if (n < recent.len) {
            recent[n] = rec;
            n += 1;
            continue;
        }
        // A ring of the last 2*window: the file is history, the summary is now.
        std.mem.copyForwards(Parsed, recent[0 .. recent.len - 1], recent[1..]);
        recent[recent.len - 1] = rec;
    }
    var out = Compare{};
    const split = if (n > window) n - window else 0;
    for (recent[0..n], 0..) |rec, i| {
        if (i < split) out.before.note(rec) else out.now.note(rec);
    }
    return out;
}

test "a record round-trips through the file and into a summary" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(home);

    append(a, io, home, .{
        .at_ms = 1,
        .model = "grok",
        .ms = 1000,
        .tokens = 100,
        .tools = 2,
        .verdict = "continued",
        .chars = 50,
    });
    append(a, io, home, .{
        .at_ms = 2,
        .model = "grok",
        .ms = 3000,
        .tokens = 300,
        .tools = 4,
        .verdict = "denied",
        .chars = 10,
    });

    const c = compare(a, io, home);
    try std.testing.expectEqual(@as(usize, 2), c.now.turns);
    try std.testing.expectEqual(@as(i64, 2000), c.now.avgMs());
    try std.testing.expectEqual(@as(u64, 200), c.now.avgTokens());
    try std.testing.expectEqual(@as(u32, 6), c.now.tools);
    try std.testing.expectEqual(@as(usize, 1), c.now.denied);
    try std.testing.expectEqual(@as(usize, 0), c.before.turns);
}

test "the window splits recent turns from the ones before them" {
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(std.testing.allocator);
    var i: usize = 0;
    // Older turns are slow, newer ones fast: the compare must show the change.
    while (i < window * 2) : (i += 1) {
        const ms: usize = if (i < window) 4000 else 1000;
        try blob.print(std.testing.allocator, "{{\"at\":{d},\"ms\":{d},\"tokens\":10,\"tools\":1,\"verdict\":\"continued\"}}\n", .{ i, ms });
    }
    const c = compareBlob(blob.items);
    try std.testing.expectEqual(@as(usize, window), c.now.turns);
    try std.testing.expectEqual(@as(usize, window), c.before.turns);
    try std.testing.expectEqual(@as(i64, 1000), c.now.avgMs());
    try std.testing.expectEqual(@as(i64, 4000), c.before.avgMs());
}

test "a truncated or foreign line is skipped, not counted" {
    const c = compareBlob("not json\n{\"at\":1,\"ms\":5,\"tokens\":1,\"tools\":0,\"verdict\":\"continued\"}\n{\"broken\":\n");
    try std.testing.expectEqual(@as(usize, 1), c.now.turns);
}
