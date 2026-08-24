//! Tool runs that stay openable after they are drawn.
//!
//! A run is committed to the transcript as one summary row. Opening it has to
//! put the individual calls where the run is, which the append-only transcript
//! cannot do on its own -- so the bytes each run occupies are remembered here,
//! and a click re-renders that span in place.
//!
//! The details are copied into the session allocator on the way in. `live.Run`
//! holds them in the turn arena, which is gone by the time anyone clicks.

const std = @import("std");

const chat = @import("chat.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Rec) = .empty,

    pub const Rec = struct {
        /// Byte offset of the summary row in the transcript.
        off: usize,
        /// Bytes the run occupies right now: summary alone, or summary + calls.
        len: usize,
        expanded: bool = false,
        /// Whether the keyboard is on this run.
        selected: bool = false,
        name: []u8,
        details: [][]u8,
        /// Output of each call, parallel to `details`.
        bodies: [][]u8,
        /// Which children have their output open, one bit each.
        ///
        /// Any number at once: opening a second call is how you compare two
        /// results, and closing the first one for you is the tool deciding
        /// what you meant. The summary row is still there to collapse the
        /// whole run in one gesture when it gets long.
        open_bits: u64 = 0,

        pub fn childOpen(self: Rec, i: usize) bool {
            if (i >= 64) return false;
            return self.open_bits & (@as(u64, 1) << @intCast(i)) != 0;
        }

        pub fn toggleChildBit(self: *Rec, i: usize) void {
            // Receipt: `details` is bounded by the calls in one run, and a run
            // of more than 64 is a loop, not a task. Past that the summary row
            // is the only control, which is the right one at that size.
            if (i >= 64) return;
            self.open_bits ^= @as(u64, 1) << @intCast(i);
        }

        /// Only a run of two or more has anything the summary row does not show.
        pub fn openable(self: Rec) bool {
            return self.details.len >= 2;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *Store) void {
        for (self.items.items) |*r| {
            self.allocator.free(r.name);
            for (r.details) |d| self.allocator.free(d);
            self.allocator.free(r.details);
            for (r.bodies) |b| self.allocator.free(b);
            self.allocator.free(r.bodies);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn add(
        self: *Store,
        off: usize,
        len: usize,
        expanded: bool,
        name: []const u8,
        details: []const []const u8,
        bodies: []const []const u8,
    ) std.mem.Allocator.Error!void {
        const kept = try self.allocator.alloc([]u8, details.len);
        errdefer self.allocator.free(kept);
        var n: usize = 0;
        errdefer for (kept[0..n]) |d| self.allocator.free(d);
        while (n < details.len) : (n += 1) kept[n] = try self.allocator.dupe(u8, details[n]);

        // Parallel by construction, but a dropped body would silently shift
        // every later call's output onto the wrong row.
        const kept_bodies = try self.allocator.alloc([]u8, details.len);
        errdefer self.allocator.free(kept_bodies);
        var m: usize = 0;
        errdefer for (kept_bodies[0..m]) |b| self.allocator.free(b);
        while (m < details.len) : (m += 1) {
            const src = if (m < bodies.len) bodies[m] else "";
            kept_bodies[m] = try self.allocator.dupe(u8, src);
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.items.append(self.allocator, .{
            .off = off,
            .len = len,
            .expanded = expanded,
            .name = owned_name,
            .details = kept,
            .bodies = kept_bodies,
        });
    }

    /// The run whose bytes cover `off`, which is any row it drew.
    pub fn at(self: *Store, off: usize) ?*Rec {
        const i = self.indexAt(off) orelse return null;
        return &self.items.items[i];
    }

    pub fn indexAt(self: *const Store, off: usize) ?usize {
        for (self.items.items, 0..) |r, i| {
            if (off >= r.off and off < r.off + r.len) return i;
        }
        return null;
    }

    /// A splice moves every run below it. Signed: collapsing shrinks.
    pub fn shift(self: *Store, after: usize, delta: isize) void {
        if (delta == 0) return;
        for (self.items.items) |*r| {
            if (r.off <= after) continue;
            const moved = @as(isize, @intCast(r.off)) + delta;
            r.off = @intCast(@max(moved, 0));
        }
    }
};

/// Which part of a drawn run a byte offset falls in.
///
/// Offsets rather than row counts: a long command wraps to several display
/// rows, so "the third row of this run" is not "the third call".
pub const Part = union(enum) {
    summary,
    child: usize,
};

/// The part of `r` that byte `at` (relative to the run's start) belongs to.
pub fn partAt(allocator: std.mem.Allocator, cols: u16, r: Store.Rec, at: usize) chat.FormatError!?Part {
    const n = r.details.len;
    const row = try chat.formatGroup(allocator, cols, .{
        .name = r.name,
        .last_detail = if (n != 0) r.details[n - 1] else "",
        .count = n,
        .expanded = r.expanded,
        .selected = r.selected,
    });
    defer allocator.free(row);
    if (at < row.len) return .summary;
    if (!r.expanded or !r.openable()) return null;

    var seen = row.len;
    for (r.details, 0..) |d, i| {
        const open = r.childOpen(i);
        const child = try chat.formatGroupChild(allocator, cols, r.name, d, i + 1 == n, open);
        defer allocator.free(child);
        seen += child.len;
        if (at < seen) return .{ .child = i };
        if (!open) continue;
        // A click anywhere in an opened body closes it again, which is what
        // makes the gesture its own undo.
        const body = try chat.formatChildBody(allocator, cols, r.bodies[i], i + 1 == n);
        defer allocator.free(body);
        seen += body.len;
        if (at < seen) return .{ .child = i };
    }
    return null;
}

/// The bytes a run occupies in its current state.
pub fn render(allocator: std.mem.Allocator, cols: u16, r: Store.Rec) chat.FormatError![]u8 {
    const n = r.details.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const row = try chat.formatGroup(allocator, cols, .{
        .name = r.name,
        .last_detail = if (n != 0) r.details[n - 1] else "",
        .count = n,
        .expanded = r.expanded,
        .selected = r.selected,
    });
    defer allocator.free(row);
    try out.appendSlice(allocator, row);
    if (r.expanded and r.openable()) {
        for (r.details, 0..) |d, i| {
            const open = r.childOpen(i);
            const child = try chat.formatGroupChild(allocator, cols, r.name, d, i + 1 == n, open);
            defer allocator.free(child);
            try out.appendSlice(allocator, child);
            if (!open) continue;
            const body = try chat.formatChildBody(allocator, cols, r.bodies[i], i + 1 == n);
            defer allocator.free(body);
            try out.appendSlice(allocator, body);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "an opened call shows its output, truncated, and closes on the same key" {
    const a = std.testing.allocator;
    var s = Store.init(a);
    defer s.deinit();
    var body: [400]u8 = undefined;
    var w: usize = 0;
    var line: usize = 0;
    while (line < 30) : (line += 1) {
        const n = (std.fmt.bufPrint(body[w..], "line {d}\n", .{line}) catch break).len;
        w += n;
    }
    try s.add(0, 4, true, "bash", &.{ "zig build", "zig test" }, &.{ body[0..w], "ok\n" });
    var rec = &s.items.items[0];

    const shut = try render(a, 80, rec.*);
    defer a.free(shut);
    try std.testing.expect(std.mem.indexOf(u8, shut, "line 0") == null);

    rec.toggleChildBit(0);
    const open = try render(a, 80, rec.*);
    defer a.free(open);
    try std.testing.expect(std.mem.indexOf(u8, open, "line 0") != null);
    // Cut at the cap, and the row after says what was left out.
    try std.testing.expect(std.mem.indexOf(u8, open, "line 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "line 12") == null);
    try std.testing.expect(std.mem.indexOf(u8, open, "18 more lines") != null);
    // The other call's output is not drawn: it was not opened.
    try std.testing.expect(std.mem.indexOf(u8, open, "ok") == null);

    // Both at once: comparing two results is why you open a second one.
    rec.toggleChildBit(1);
    const two = try render(a, 80, rec.*);
    defer a.free(two);
    try std.testing.expect(std.mem.indexOf(u8, two, "line 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, two, "ok") != null);

    // And closing one leaves the other open.
    rec.toggleChildBit(0);
    const one = try render(a, 80, rec.*);
    defer a.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "line 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, one, "ok") != null);
}

test "a call that returned nothing says so rather than drawing a blank" {
    const a = std.testing.allocator;
    var s = Store.init(a);
    defer s.deinit();
    try s.add(0, 4, true, "bash", &.{ "true", "false" }, &.{ "", "" });
    var rec = &s.items.items[0];
    rec.toggleChildBit(1);
    const out = try render(a, 80, rec.*);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "no output") != null);
}

test "a store finds the run a row belongs to and moves the ones below it" {
    const a = std.testing.allocator;
    var s = Store.init(a);
    defer s.deinit();
    try s.add(0, 10, false, "bash", &.{ "one", "two" }, &.{});
    try s.add(40, 10, false, "read", &.{"a.zig"}, &.{});

    try std.testing.expect(s.at(5) != null);
    try std.testing.expect(s.at(20) == null);
    try std.testing.expectEqualStrings("read", s.at(45).?.name);

    s.shift(0, 30);
    try std.testing.expectEqual(@as(usize, 0), s.items.items[0].off);
    try std.testing.expectEqual(@as(usize, 70), s.items.items[1].off);
}

test "only a run of two or more has anything to open" {
    const a = std.testing.allocator;
    var s = Store.init(a);
    defer s.deinit();
    try s.add(0, 4, false, "read", &.{"a.zig"}, &.{});
    try std.testing.expect(!s.items.items[0].openable());
    const collapsed = try render(a, 80, s.items.items[0]);
    defer a.free(collapsed);
    s.items.items[0].expanded = true;
    const opened = try render(a, 80, s.items.items[0]);
    defer a.free(opened);
    // Nothing to show, so opening it must not add a row.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, collapsed, "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, opened, "\n"));
}

test "opening a run draws every call under it" {
    const a = std.testing.allocator;
    var s = Store.init(a);
    defer s.deinit();
    try s.add(0, 4, true, "bash", &.{ "zig build", "zig test" }, &.{});
    const opened = try render(a, 80, s.items.items[0]);
    defer a.free(opened);
    try std.testing.expect(std.mem.indexOf(u8, opened, "zig build") != null);
    try std.testing.expect(std.mem.indexOf(u8, opened, "zig test") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, opened, "\n"));
}
