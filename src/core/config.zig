const std = @import("std");

pub const PermissionMode = enum {
    ask,
    auto,
    yolo,

    pub fn fromSlice(s: []const u8) ?PermissionMode {
        if (std.mem.eql(u8, s, "normal") or std.mem.eql(u8, s, "ask")) return .ask;
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "yolo") or std.mem.eql(u8, s, "always") or std.mem.eql(u8, s, "always-approve")) return .yolo;
        return null;
    }

    pub fn asSlice(self: PermissionMode) []const u8 {
        return switch (self) {
            .ask => "normal",
            .auto => "auto",
            .yolo => "yolo",
        };
    }

    pub fn cycle(self: PermissionMode) PermissionMode {
        return switch (self) {
            .ask => .auto,
            .auto => .yolo,
            .yolo => .ask,
        };
    }
};

/// Shift+Tab exclusive state. `auto` stays a flag/slash, not this cycle.
pub const Surface = enum {
    normal,
    plan,
    yolo,

    pub fn fromSlice(s: []const u8) ?Surface {
        if (std.mem.eql(u8, s, "normal") or std.mem.eql(u8, s, "ask")) return .normal;
        if (std.mem.eql(u8, s, "plan")) return .plan;
        if (std.mem.eql(u8, s, "yolo") or std.mem.eql(u8, s, "always") or std.mem.eql(u8, s, "always-approve")) return .yolo;
        return null;
    }

    pub fn asSlice(self: Surface) []const u8 {
        return @tagName(self);
    }

    pub fn cycle(self: Surface) Surface {
        return switch (self) {
            .normal => .plan,
            .plan => .yolo,
            .yolo => .normal,
        };
    }

    pub fn hint(self: Surface) []const u8 {
        return switch (self) {
            .normal => "normal  ask before changes",
            .plan => "plan  look first; say go when ready",
            .yolo => "yolo  changes without asking",
        };
    }

    pub fn fromFlags(plan_on: bool, mode: PermissionMode) Surface {
        if (plan_on) return .plan;
        return switch (mode) {
            .yolo => .yolo,
            .ask, .auto => .normal,
        };
    }

    pub fn permission(self: Surface) PermissionMode {
        return switch (self) {
            .normal, .plan => .ask,
            .yolo => .yolo,
        };
    }

    pub fn planning(self: Surface) bool {
        return self == .plan;
    }
};

pub const Effort = enum {
    none,
    low,
    medium,
    high,

    pub fn fromSlice(s: []const u8) ?Effort {
        if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "off")) return .none;
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium") or std.mem.eql(u8, s, "med")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        return null;
    }

    pub fn asSlice(self: Effort) []const u8 {
        return switch (self) {
            .none => "none",
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

pub const config_dir_name = ".omfx";

pub fn profileRoot(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, config_dir_name });
}

pub const Config = struct {
    workspace: []const u8,
    profile_root: []const u8,
    permission_mode: PermissionMode = .ask,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace);
        allocator.free(self.profile_root);
    }
};

test "permission mode parses ask auto and yolo" {
    try std.testing.expectEqual(PermissionMode.ask, PermissionMode.fromSlice("ask").?);
    try std.testing.expectEqual(PermissionMode.ask, PermissionMode.fromSlice("normal").?);
    try std.testing.expectEqual(PermissionMode.auto, PermissionMode.fromSlice("auto").?);
    try std.testing.expectEqual(PermissionMode.yolo, PermissionMode.fromSlice("yolo").?);
    try std.testing.expectEqual(PermissionMode.yolo, PermissionMode.fromSlice("always").?);
    try std.testing.expect(PermissionMode.fromSlice("") == null);
    try std.testing.expectEqual(PermissionMode.auto, PermissionMode.ask.cycle());
    try std.testing.expectEqual(PermissionMode.yolo, PermissionMode.auto.cycle());
    try std.testing.expectEqual(PermissionMode.ask, PermissionMode.yolo.cycle());
}

test "Surface cycles normal plan yolo" {
    try std.testing.expectEqual(Surface.plan, Surface.normal.cycle());
    try std.testing.expectEqual(Surface.yolo, Surface.plan.cycle());
    try std.testing.expectEqual(Surface.normal, Surface.yolo.cycle());
    try std.testing.expectEqual(Surface.normal, Surface.fromSlice("ask").?);
    try std.testing.expectEqual(Surface.yolo, Surface.fromSlice("always").?);
    try std.testing.expectEqual(Surface.plan, Surface.fromFlags(true, .ask));
    try std.testing.expectEqual(Surface.yolo, Surface.fromFlags(false, .yolo));
    try std.testing.expect(Surface.plan.planning());
    try std.testing.expectEqual(PermissionMode.ask, Surface.plan.permission());
}

test "effort is independent of model id" {
    try std.testing.expectEqual(Effort.low, Effort.fromSlice("low").?);
    try std.testing.expectEqual(Effort.none, Effort.fromSlice("off").?);
    try std.testing.expect(Effort.fromSlice("max") == null);
}

test "profileRoot joins home and .omfx" {
    const got = try profileRoot(std.testing.allocator, "/Users/demo");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/Users/demo/.omfx", got);
}
