const std = @import("std");

/// Process or test environment. Concrete type — not `anytype`.
pub const Lookup = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, key: []const u8) ?[]const u8,

    pub fn get(self: Lookup, key: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, key);
    }

    pub fn fromProcess(map: *const std.process.Environ.Map) Lookup {
        return .{
            .ctx = @ptrCast(map),
            .getFn = processGet,
        };
    }

    fn processGet(ctx: *const anyopaque, key: []const u8) ?[]const u8 {
        const map: *const std.process.Environ.Map = @ptrCast(@alignCast(ctx));
        return map.get(key);
    }
};

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Table = struct {
    pairs: []const Pair,

    pub fn lookup(self: *const Table) Lookup {
        return .{
            .ctx = @ptrCast(self),
            .getFn = tableGet,
        };
    }

    fn tableGet(ctx: *const anyopaque, key: []const u8) ?[]const u8 {
        const table: *const Table = @ptrCast(@alignCast(ctx));
        for (table.pairs) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }
};

/// FORCE_COLOR overrides NO_COLOR. Empty / 0 disables. 1, 2, 3, true enable.
pub fn colorOn(lookup: Lookup) bool {
    if (lookup.get("FORCE_COLOR")) |v| {
        if (v.len == 0 or std.mem.eql(u8, v, "0")) return false;
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "2") or std.mem.eql(u8, v, "3") or std.mem.eql(u8, v, "true"))
            return true;
        return false;
    }
    if (lookup.get("NO_COLOR")) |v| {
        if (v.len > 0) return false;
    }
    if (lookup.get("TERM")) |t| {
        if (std.mem.eql(u8, t, "dumb")) return false;
    }
    return true;
}

test "table lookup finds keys" {
    const table = Table{ .pairs = &.{
        .{ .key = "HOME", .value = "/tmp" },
        .{ .key = "EMPTY", .value = "" },
    } };
    const env = table.lookup();
    try std.testing.expectEqualStrings("/tmp", env.get("HOME").?);
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
    try std.testing.expect(env.get("MISSING") == null);
}

test "colorOn respects FORCE_COLOR over NO_COLOR" {
    const force = Table{ .pairs = &.{
        .{ .key = "FORCE_COLOR", .value = "1" },
        .{ .key = "NO_COLOR", .value = "1" },
    } };
    try std.testing.expect(colorOn(force.lookup()));
    const none = Table{ .pairs = &.{.{ .key = "NO_COLOR", .value = "1" }} };
    try std.testing.expect(!colorOn(none.lookup()));
    const dumb = Table{ .pairs = &.{.{ .key = "TERM", .value = "dumb" }} };
    try std.testing.expect(!colorOn(dumb.lookup()));
    const empty = Table{ .pairs = &.{} };
    try std.testing.expect(colorOn(empty.lookup()));
}
