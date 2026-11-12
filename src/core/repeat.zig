//! Compile-time string repetition. Zig 0.17 removed the `**` array repeat
//! operator; `@splat` covers a single repeated element, and this covers a
//! repeated multi-byte unit such as `"word "` or a CJK rune.

const std = @import("std");

/// `s` repeated `n` times, built at compile time.
pub fn str(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A container-level decl is static memory, so the pointer outlives the call.
    return &struct {
        const value = blk: {
            @setEvalBranchQuota(1000 + 4 * n);
            var out: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
            break :blk out;
        };
    }.value;
}

test "str repeats a unit" {
    try std.testing.expectEqualStrings("abab", str("ab", 2));
    try std.testing.expectEqualStrings("", str("x", 0));
    try std.testing.expectEqual(@as(usize, 30_000), str("x", 30_000).len);
    try std.testing.expectEqualStrings("\u{4e00}\u{4e00}", str("\u{4e00}", 2));
}
