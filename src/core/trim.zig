const std = @import("std");
const compact = @import("compact.zig");

/// Observation trim. Not trajectory compact (see compact.zig).
/// CoACT (arXiv:2607.02911, Jul 2026): compress the newest tool result
/// before it enters the thread, under next-action preservation. No extra
/// model. Executor is TACO's conservative seed schema (arXiv:2604.19572):
/// strip noise, keep first/last plus error lines, leave unique short
/// output alone.
///
/// keep_first / keep_last: TACO Appendix C defaults (keep_first_n=5,
/// keep_last_n=10). progress_min: TACO seed_openssl `[.+]{20,}`.
pub const keep_first: usize = 5;
pub const keep_last: usize = 10;
pub const progress_min: usize = 20;

comptime {
    if (keep_first == 0) @compileError("keep_first must keep the observation head");
    if (keep_last == 0) @compileError("keep_last must keep the observation tail");
    if (progress_min == 0) @compileError("progress_min must skip only long progress lines");
}

const keep_needles = [_][]const u8{
    "error",
    "fatal",
    "traceback",
    "exception",
    "panic",
    "fail",
    "warning",
    "assert",
    "denied",
};

pub fn apply(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    const stripped = try stripControls(allocator, s);
    defer allocator.free(stripped);
    const cleaned = try dropProgressAndRuns(allocator, stripped);
    defer allocator.free(cleaned);
    if (cleaned.len <= compact.result_budget) return allocator.dupe(u8, cleaned);
    return window(allocator, cleaned);
}

fn stripControls(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            i += 1;
            if (i >= s.len) break;
            switch (s[i]) {
                '[' => {
                    i += 1;
                    while (i < s.len) {
                        const d = s[i];
                        i += 1;
                        if (d >= 0x40 and d <= 0x7E) break;
                    }
                },
                ']' => {
                    i += 1;
                    while (i < s.len) {
                        const d = s[i];
                        i += 1;
                        if (d == 0x07) break;
                        if (d == 0x1b and i < s.len and s[i] == '\\') {
                            i += 1;
                            break;
                        }
                    }
                },
                '(', ')' => i += 2,
                else => i += 1,
            }
            continue;
        }
        if (c == '\r') {
            if (i + 1 < s.len and s[i + 1] == '\n') {
                try out.append(allocator, '\n');
                i += 2;
                continue;
            }
            var j = out.items.len;
            while (j > 0) : (j -= 1) {
                if (out.items[j - 1] == '\n') break;
            }
            out.shrinkRetainingCapacity(j);
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn isProgress(line: []const u8) bool {
    if (line.len < progress_min) return false;
    for (line) |c| {
        switch (c) {
            '.', '+', '*', '=', '#', '-', '|', '/', '\\', ' ', '\t', '[', ']', '>' => {},
            else => return false,
        }
    }
    return true;
}

fn keepLine(line: []const u8) bool {
    for (keep_needles) |n| {
        if (containsIgnoreCase(line, n)) return true;
    }
    return false;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn flushRun(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    count: usize,
) std.mem.Allocator.Error!void {
    if (list.items.len > 0) try list.append(allocator, '\n');
    try list.appendSlice(allocator, line);
    if (count > 1) {
        var buf: [32]u8 = undefined;
        const extra = std.fmt.bufPrint(&buf, " (x{d})", .{count}) catch unreachable;
        try list.appendSlice(allocator, extra);
    }
}

fn dropProgressAndRuns(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    var prev: ?[]const u8 = null;
    var count: usize = 0;
    while (it.next()) |line| {
        if (isProgress(line)) continue;
        if (prev) |p| {
            if (std.mem.eql(u8, p, line)) {
                count += 1;
                continue;
            }
            try flushRun(&out, allocator, p, count);
        }
        prev = line;
        count = 1;
    }
    if (prev) |p| try flushRun(&out, allocator, p, count);
    return out.toOwnedSlice(allocator);
}

fn window(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    const n = lines.items.len;
    if (n <= keep_first + keep_last) return allocator.dupe(u8, s);

    const keep = try allocator.alloc(bool, n);
    defer allocator.free(keep);
    @memset(keep, false);
    for (0..keep_first) |i| keep[i] = true;
    var t = n - keep_last;
    while (t < n) : (t += 1) keep[t] = true;
    for (lines.items, 0..) |line, i| {
        if (keepLine(line)) keep[i] = true;
    }

    var dropped: usize = 0;
    for (keep) |k| {
        if (!k) dropped += 1;
    }
    if (dropped == 0) return allocator.dupe(u8, s);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var noticed = false;
    for (lines.items, 0..) |line, i| {
        if (!keep[i]) {
            if (noticed) continue;
            if (out.items.len > 0) try out.append(allocator, '\n');
            var buf: [128]u8 = undefined;
            const notice = std.fmt.bufPrint(
                &buf,
                "dropped {d} middle lines (keep_first={d} keep_last={d} byte_budget={d})",
                .{ dropped, keep_first, keep_last, compact.result_budget },
            ) catch unreachable;
            try out.appendSlice(allocator, notice);
            noticed = true;
            continue;
        }
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

test "ansi csi is stripped" {
    const s = try apply(std.testing.allocator, "\x1b[31mred\x1b[0m ok\n");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("red ok\n", s);
}

test "carriage return keeps last frame" {
    const s = try apply(std.testing.allocator, "Downloading 10%\rDownloading 100%\ndone\n");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("Downloading 100%\ndone\n", s);
}

test "unique compile lines stay" {
    const s = try apply(std.testing.allocator, "Compiling foo v1\nCompiling bar v2\nCompiling baz v3\n");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("Compiling foo v1\nCompiling bar v2\nCompiling baz v3\n", s);
}

test "identical runs collapse" {
    const s = try apply(std.testing.allocator, "ok\nok\nok\n");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("ok (x3)\n", s);
}

test "progress-only line drops" {
    const s = try apply(std.testing.allocator, "....................\nreal\n");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("real\n", s);
}

test "over-budget window keeps edges and error lines" {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(std.testing.allocator);
    var i: usize = 0;
    while (raw.items.len < compact.result_budget + 200) : (i += 1) {
        if (i == 80) {
            try raw.appendSlice(std.testing.allocator, "error: boom\n");
            continue;
        }
        var buf: [32]u8 = undefined;
        const piece = std.fmt.bufPrint(&buf, "n={d:0>5}\n", .{i}) catch unreachable;
        try raw.appendSlice(std.testing.allocator, piece);
    }
    const s = try apply(std.testing.allocator, raw.items);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "n=00000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "error: boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "dropped ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "keep_first=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "byte_budget=12000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "n=00040") == null);
    try std.testing.expect(s.len < raw.items.len);
}
