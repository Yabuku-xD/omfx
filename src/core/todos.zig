//! The turn's task list: what the model said it would do, and how far it got.
//!
//! Held per session and threaded explicitly through dispatch and the REPL.
//! It is a display of the model's stated plan, not a durable record -- nothing
//! reads it back after a restart, so persisting it would only invite someone to
//! trust a stale one.

const std = @import("std");
const paint = @import("ansi.zig");

/// A plan longer than this is not a plan. Overflow is reported, not dropped
/// silently, so an over-eager list is visible rather than mysteriously short.
pub const max_items: usize = 20;
pub const max_text: usize = 160;

pub const Status = enum {
    pending,
    in_progress,
    done,

    pub fn fromSlice(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "pending") or std.mem.eql(u8, s, "todo")) return .pending;
        if (std.mem.eql(u8, s, "in_progress") or std.mem.eql(u8, s, "active")) return .in_progress;
        if (std.mem.eql(u8, s, "completed") or std.mem.eql(u8, s, "done")) return .done;
        return null;
    }

    pub fn mark(self: Status) []const u8 {
        return switch (self) {
            .pending => "\u{25cb}",
            .in_progress => "\u{25d0}",
            .done => "\u{2713}",
        };
    }

    fn color(self: Status) []const u8 {
        return switch (self) {
            .pending => paint.muted,
            .in_progress => paint.accent,
            .done => paint.accent_dim,
        };
    }
};

const Item = struct {
    text: [max_text]u8 = undefined,
    len: usize = 0,
    status: Status = .pending,

    pub fn slice(self: *const Item) []const u8 {
        return self.text[0..self.len];
    }
};

pub const List = struct {
    items: [max_items]Item = undefined,
    n: usize = 0,
    dropped: usize = 0,

    pub fn clear(self: *List) void {
        self.n = 0;
        self.dropped = 0;
    }

    pub fn push(self: *List, text: []const u8, status: Status) void {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return;
        if (self.n == max_items) {
            self.dropped += 1;
            return;
        }
        const len = @min(t.len, max_text);
        @memcpy(self.items[self.n].text[0..len], t[0..len]);
        self.items[self.n].len = len;
        self.items[self.n].status = status;
        self.n += 1;
    }

    pub fn counts(self: *const List) struct { done: usize, total: usize } {
        var done: usize = 0;
        for (self.items[0..self.n]) |*it| {
            if (it.status == .done) done += 1;
        }
        return .{ .done = done, .total = self.n };
    }

    /// The task the model says it is on, for the activity line. Empty when the
    /// model has not posted a list, or has nothing in progress.
    pub fn inProgress(self: *const List) []const u8 {
        for (self.items[0..self.n]) |*item| {
            if (item.status == .in_progress) return item.slice();
        }
        return "";
    }

    /// The card shown in the transcript. Plain text plus SGR, no cursor moves:
    /// it scrolls with everything else rather than pinning itself anywhere.
    pub fn render(self: *const List, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (self.n == 0) {
            try out.print(allocator, "{s}no tasks{s}\n", .{ paint.muted, paint.reset });
            return out.toOwnedSlice(allocator);
        }
        const c = self.counts();
        try out.print(allocator, "{s}Tasks {d}/{d}{s}\n", .{ paint.label, c.done, c.total, paint.reset });
        for (self.items[0..self.n]) |*it| {
            try out.print(allocator, "{s}{s}{s} ", .{ it.status.color(), it.status.mark(), paint.reset });
            switch (it.status) {
                // A finished line is struck through: still readable as context,
                // no longer competing with what is left to do.
                .done => try out.print(allocator, "{s}\x1b[9m{s}{s}\n", .{ paint.muted, it.slice(), paint.reset }),
                .in_progress => try out.print(allocator, "{s}{s}{s}\n", .{ paint.asst_fg, it.slice(), paint.reset }),
                .pending => try out.print(allocator, "{s}{s}{s}\n", .{ paint.muted, it.slice(), paint.reset }),
            }
        }
        if (self.dropped != 0) {
            try out.print(allocator, "{s}{d} more dropped; max_items={d}{s}\n", .{
                paint.warn, self.dropped, max_items, paint.reset,
            });
        }
        return out.toOwnedSlice(allocator);
    }
    pub fn applyJson(self: *List, allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch
            return error.BadTodos;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.BadTodos,
        };
        const arr = switch (root.get("todos") orelse root.get("items") orelse return error.BadTodos) {
            .array => |a| a,
            else => return error.BadTodos,
        };

        var next: List = .{};
        for (arr.items) |item| {
            switch (item) {
                .string => |s| next.push(s, .pending),
                .object => |o| {
                    const text = switch (o.get("content") orelse o.get("task") orelse o.get("text") orelse continue) {
                        .string => |v| v,
                        else => continue,
                    };
                    const status = blk: {
                        const raw = o.get("status") orelse break :blk Status.pending;
                        const s = switch (raw) {
                            .string => |v| v,
                            else => break :blk Status.pending,
                        };
                        break :blk Status.fromSlice(s) orelse .pending;
                    };
                    next.push(text, status);
                },
                else => continue,
            }
        }
        self.* = next;
        return self.render(allocator);
    }
};

test "set parses objects, bare strings, and status words" {
    const a = std.testing.allocator;
    var list: List = .{};
    const out = try list.applyJson(a,
        \\{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"in_progress"},"three"]}
    );
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 3), list.n);
    try std.testing.expectEqual(Status.done, list.items[0].status);
    try std.testing.expectEqual(Status.in_progress, list.items[1].status);
    try std.testing.expectEqual(Status.pending, list.items[2].status);
    try std.testing.expect(std.mem.indexOf(u8, out, "Tasks 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "three") != null);
}

test "set replaces rather than appends" {
    const a = std.testing.allocator;
    var list: List = .{};
    const first = try list.applyJson(a, "{\"todos\":[\"wire the parser\",\"drop the shim\"]}");
    a.free(first);
    const second = try list.applyJson(a, "{\"todos\":[\"ship it\"]}");
    defer a.free(second);
    try std.testing.expectEqual(@as(usize, 1), list.n);
    try std.testing.expect(std.mem.indexOf(u8, second, "wire the parser") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "ship it") != null);
}

test "an over-long list says what it dropped" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "{\"todos\":[");
    var i: usize = 0;
    while (i < max_items + 3) : (i += 1) {
        if (i != 0) try body.append(a, ',');
        try body.print(a, "\"task {d}\"", .{i});
    }
    try body.appendSlice(a, "]}");
    var list: List = .{};
    const out = try list.applyJson(a, body.items);
    defer a.free(out);
    try std.testing.expectEqual(max_items, list.n);
    try std.testing.expectEqual(@as(usize, 3), list.dropped);
    try std.testing.expect(std.mem.indexOf(u8, out, "max_items=20") != null);
}

test "bad json is an error, not an empty list" {
    const a = std.testing.allocator;
    var list: List = .{};
    const keep = try list.applyJson(a, "{\"todos\":[\"keep\"]}");
    a.free(keep);
    try std.testing.expectError(error.BadTodos, list.applyJson(a, "not json"));
    try std.testing.expectError(error.BadTodos, list.applyJson(a, "{\"nope\":1}"));
    try std.testing.expectEqual(@as(usize, 1), list.n);
}

test "inProgress names the active task, or nothing" {
    const a = std.testing.allocator;
    var list: List = .{};
    const out = try list.applyJson(a,
        \\{"todos":[{"content":"read the parser","status":"completed"},{"content":"wire the panel","status":"in_progress"},{"content":"ship","status":"pending"}]}
    );
    defer a.free(out);
    try std.testing.expectEqualStrings("wire the panel", list.inProgress());

    const none = try list.applyJson(a, "{\"todos\":[{\"content\":\"only pending\",\"status\":\"pending\"}]}");
    defer a.free(none);
    try std.testing.expectEqualStrings("", list.inProgress());
}
