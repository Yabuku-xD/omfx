const std = @import("std");

fn Named(comptime tag: []const u8) type {
    return struct {
        bytes: []const u8,

        const Self = @This();

        pub fn init(bytes: []const u8) Self {
            return .{ .bytes = bytes };
        }

        pub fn eql(self: Self, other: Self) bool {
            return std.mem.eql(u8, self.bytes, other.bytes);
        }

        pub fn eqlSlice(self: Self, s: []const u8) bool {
            return std.mem.eql(u8, self.bytes, s);
        }

        comptime {
            if (tag.len == 0) @compileError("id tag must be non-empty");
        }
    };
}

pub const SessionId = Named("session");
pub const ProviderId = Named("provider");
pub const ToolCallId = Named("tool_call");

pub fn parseSession(raw: []const u8) SessionId {
    if (raw.len == 0 or std.mem.eql(u8, raw, "last") or std.mem.eql(u8, raw, "latest")) {
        return .init("last");
    }
    return .init(raw);
}

test "session aliases collapse to last" {
    try std.testing.expect(parseSession("").eqlSlice("last"));
    try std.testing.expect(parseSession("latest").eqlSlice("last"));
    try std.testing.expect(parseSession("abc").eqlSlice("abc"));
}

test "distinct id types do not coerce" {
    const s = SessionId.init("x");
    const p = ProviderId.init("x");
    try std.testing.expect(s.eqlSlice(p.bytes));
}
