//! Ephemeral footer toasts. Status owns the activity line; toasts sit above it
//! so a menu confirmation does not fight the spinner.

const std = @import("std");
const paint = @import("../core/ansi.zig");
const width = @import("width.zig");

pub const hold_ms: i64 = 3_000;
pub const max_text: usize = 96;
pub const max_slots: usize = 2;

comptime {
    if (hold_ms <= 0) @compileError("toast must expire");
}

pub const Slot = struct {
    text: [max_text]u8 = undefined,
    len: usize = 0,
    until_ms: i64 = 0,

    pub fn slice(self: *const Slot) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Queue = struct {
    slots: [max_slots]Slot = @splat(.{}),
    n: usize = 0,

    pub fn push(self: *Queue, text: []const u8, now_ms: i64) void {
        self.tick(now_ms);
        const i = if (self.n < max_slots) self.n else max_slots - 1;
        if (self.n < max_slots) self.n += 1 else {
            var k: usize = 0;
            while (k + 1 < max_slots) : (k += 1) self.slots[k] = self.slots[k + 1];
        }
        const n = @min(text.len, max_text);
        @memcpy(self.slots[i].text[0..n], text[0..n]);
        self.slots[i].len = n;
        self.slots[i].until_ms = now_ms + hold_ms;
    }

    pub fn tick(self: *Queue, now_ms: i64) void {
        var w: usize = 0;
        var r: usize = 0;
        while (r < self.n) : (r += 1) {
            if (self.slots[r].until_ms > now_ms) {
                self.slots[w] = self.slots[r];
                w += 1;
            }
        }
        self.n = w;
    }

    pub fn line(self: *Queue, allocator: std.mem.Allocator, cols: u16, now_ms: i64) ![]u8 {
        self.tick(now_ms);
        if (self.n == 0) return allocator.dupe(u8, "");
        const raw = self.slots[self.n - 1].slice();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, paint.accent_dim);
        try out.appendSlice(allocator, "◉ ");
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.label);
        const room = if (cols > 4) cols - 4 else cols;
        const take = width.indexAtCell(raw, room);
        try out.appendSlice(allocator, raw[0..take]);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.el);
        return out.toOwnedSlice(allocator);
    }
};

test "toast expires" {
    var q: Queue = .{};
    q.push("saved", 1000);
    try std.testing.expectEqual(@as(usize, 1), q.n);
    q.tick(1000 + hold_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), q.n);
}

test "toast line paints" {
    var q: Queue = .{};
    q.push("mcp: saved", 0);
    const s = try q.line(std.testing.allocator, 40, 0);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "mcp: saved") != null);
}
