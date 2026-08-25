const std = @import("std");
const sse = @import("../../providers/sse.zig");

/// Tool arguments arrive as JSON *string values*: after the provider layer
/// decodes the arguments-as-a-string envelope, `\n` inside a value is still two
/// characters. Decoding it is this type's whole job, and it happens once per
/// argument read so no call site can forget.
///
/// Backed by a scratch arena that dies with the call, so reads stay `?[]const u8`
/// and nothing here has to be freed by hand.
pub const Args = struct {
    arena: std.mem.Allocator,
    json: []const u8,

    pub fn str(self: Args, key: []const u8) ?[]const u8 {
        return sse.argString(self.arena, self.json, key);
    }

    pub fn usize_(self: Args, key: []const u8) ?usize {
        return sse.jsonUsize(self.json, key);
    }

    /// Models send booleans as `true`, `"true"`, or `1`; take all three.
    ///
    /// Scanned here rather than via `jsonAtom`, which only understands quoted
    /// strings and numbers -- a bare `false` came back null, so an explicit
    /// `background: false` silently fell through to the default and detached
    /// the command the model was waiting on.
    pub fn flag(self: Args, key: []const u8) ?bool {
        if (self.str(key)) |quoted| return wordFlag(quoted);
        var needle_buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
        const at = std.mem.indexOf(u8, self.json, needle) orelse return null;
        var i = at + needle.len;
        while (i < self.json.len and self.json[i] == ' ') i += 1;
        const rest = self.json[i..];
        return wordFlag(rest);
    }

    fn wordFlag(v: []const u8) ?bool {
        if (std.mem.startsWith(u8, v, "true") or std.mem.startsWith(u8, v, "1")) return true;
        if (std.mem.startsWith(u8, v, "false") or std.mem.startsWith(u8, v, "0")) return false;
        return null;
    }
};

test "flag reads bare, quoted, and numeric booleans" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = Args{ .arena = scratch.allocator(), .json =
        \\{"a":true,"b":false,"c":"true","d":0,"e":1}
    };
    try std.testing.expectEqual(@as(?bool, true), a.flag("a"));
    try std.testing.expectEqual(@as(?bool, false), a.flag("b"));
    try std.testing.expectEqual(@as(?bool, true), a.flag("c"));
    try std.testing.expectEqual(@as(?bool, false), a.flag("d"));
    try std.testing.expectEqual(@as(?bool, true), a.flag("e"));
    try std.testing.expectEqual(@as(?bool, null), a.flag("missing"));
}
