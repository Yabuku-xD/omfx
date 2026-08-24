//! Which facts the status line shows, and where it draws them.
//!
//! omfx put model and permission mode in the footer and nothing anywhere else.
//! That is one opinion about what matters; a user watching cost wants tokens, a
//! user in a worktree wants the branch, and a user on a 30-row terminal wants
//! the footer back.
//!
//! Every field here is something the harness already knows -- no extra work, no
//! model tokens. A field that would need a subprocess on every paint does not
//! belong in this list.

const std = @import("std");

const paint = @import("../core/ansi.zig");

/// Where the fields are drawn. The header is one row that is otherwise mostly
/// empty; the footer is next to what you are typing.
pub const Place = enum {
    footer,
    header,
    both,

    pub fn fromSlice(s: []const u8) Place {
        if (std.mem.eql(u8, s, "header")) return .header;
        if (std.mem.eql(u8, s, "both")) return .both;
        return .footer;
    }

    pub fn asSlice(self: Place) []const u8 {
        return @tagName(self);
    }

    pub fn showsHeader(self: Place) bool {
        return self != .footer;
    }

    pub fn showsFooter(self: Place) bool {
        return self != .header;
    }
};

/// One fact the status line can show.
pub const Field = enum {
    model,
    mode,
    workspace,
    branch,
    tokens,
    session,
    peers,
    jobs,

    pub fn fromSlice(s: []const u8) ?Field {
        return std.meta.stringToEnum(Field, s);
    }

    pub fn label(self: Field) []const u8 {
        return @tagName(self);
    }
};

pub const max_fields: usize = 8;

comptime {
    if (max_fields < std.meta.tags(Field).len) {
        @compileError("max_fields must hold every Field");
    }
}

/// What omfx showed before this file existed, so an unconfigured user sees no
/// change.
pub const default_fields = [_]Field{ .model, .mode };

pub const Config = struct {
    place: Place = .footer,
    fields: [max_fields]Field = undefined,
    n: usize = 0,

    pub fn items(self: *const Config) []const Field {
        return self.fields[0..self.n];
    }

    pub fn has(self: *const Config, f: Field) bool {
        for (self.items()) |x| {
            if (x == f) return true;
        }
        return false;
    }

    pub fn add(self: *Config, f: Field) void {
        if (self.n == max_fields or self.has(f)) return;
        self.fields[self.n] = f;
        self.n += 1;
    }

    pub fn remove(self: *Config, f: Field) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.fields[i] != f) continue;
            var j = i;
            while (j + 1 < self.n) : (j += 1) self.fields[j] = self.fields[j + 1];
            self.n -= 1;
            return;
        }
    }

    /// Comma-separated, for `settings.json`. Order is the draw order.
    pub fn encode(self: *const Config, buf: []u8) []const u8 {
        var w: usize = 0;
        for (self.items(), 0..) |f, i| {
            if (i != 0 and w < buf.len) {
                buf[w] = ',';
                w += 1;
            }
            const name = f.label();
            const n = @min(buf.len - w, name.len);
            @memcpy(buf[w..][0..n], name[0..n]);
            w += n;
        }
        return buf[0..w];
    }
};

/// Parses the stored settings. Unknown names are skipped rather than rejected,
/// so a config written by a newer omfx still works in an older one.
pub fn parse(place_s: []const u8, fields_s: []const u8) Config {
    var c = Config{ .place = Place.fromSlice(place_s) };
    if (std.mem.trim(u8, fields_s, " ").len == 0) {
        for (default_fields) |f| c.add(f);
        return c;
    }
    var it = std.mem.splitScalar(u8, fields_s, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        if (Field.fromSlice(name)) |f| c.add(f);
    }
    // An explicit empty list still has to render something identifying.
    if (c.n == 0) c.add(.model);
    return c;
}

/// The live values behind each field, gathered by the caller from what it
/// already has. Nothing here runs a command.
pub const Values = struct {
    model: []const u8 = "",
    mode: []const u8 = "",
    workspace: []const u8 = "",
    branch: []const u8 = "",
    tokens: []const u8 = "",
    session: []const u8 = "",
    peers: []const u8 = "",
    jobs: []const u8 = "",

    pub fn get(self: Values, f: Field) []const u8 {
        return switch (f) {
            .model => self.model,
            .mode => self.mode,
            .workspace => self.workspace,
            .branch => self.branch,
            .tokens => self.tokens,
            .session => self.session,
            .peers => self.peers,
            .jobs => self.jobs,
        };
    }
};

/// Renders the configured fields, separated by a middle dot.
///
/// A field with no value is skipped rather than shown empty: "model · · yolo"
/// is worse than omitting the gap.
pub fn render(buf: []u8, c: *const Config, v: Values) []const u8 {
    var w: usize = 0;
    for (c.items()) |f| {
        const val = v.get(f);
        if (val.len == 0) continue;
        if (w != 0) w += copy(buf[w..], " \u{00b7} ");
        w += copy(buf[w..], val);
    }
    return buf[0..w];
}

fn copy(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

test "an unconfigured status line looks like it always did" {
    const c = parse("", "");
    try std.testing.expectEqual(Place.footer, c.place);
    try std.testing.expectEqual(@as(usize, 2), c.n);
    try std.testing.expect(c.has(.model));
    try std.testing.expect(c.has(.mode));
}

test "placement decides which rows draw" {
    try std.testing.expect(parse("footer", "").place.showsFooter());
    try std.testing.expect(!parse("footer", "").place.showsHeader());
    try std.testing.expect(parse("header", "").place.showsHeader());
    try std.testing.expect(!parse("header", "").place.showsFooter());
    const both = parse("both", "").place;
    try std.testing.expect(both.showsHeader() and both.showsFooter());
    // An unknown placement falls back rather than blanking the line.
    try std.testing.expectEqual(Place.footer, parse("sideways", "").place);
}

test "fields keep the order they were written in" {
    const c = parse("footer", "tokens,model,branch");
    const got = c.items();
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(Field.tokens, got[0]);
    try std.testing.expectEqual(Field.model, got[1]);
    try std.testing.expectEqual(Field.branch, got[2]);
}

test "unknown and duplicate names are dropped, not fatal" {
    // A config from a newer omfx must still load in an older one.
    const c = parse("footer", "model,not_a_field,model,mode");
    try std.testing.expectEqual(@as(usize, 2), c.n);
    try std.testing.expect(c.has(.model) and c.has(.mode));
}

test "an explicitly empty list still identifies the session" {
    const c = parse("footer", ",,,");
    try std.testing.expect(c.n >= 1);
    try std.testing.expect(c.has(.model));
}

test "render joins present values and skips absent ones" {
    var buf: [200]u8 = undefined;
    const c = parse("footer", "model,branch,mode");
    const s = render(&buf, &c, .{ .model = "grok-4.6", .mode = "yolo" });
    // branch is empty, so it leaves no gap behind.
    try std.testing.expectEqualStrings("grok-4.6 \u{00b7} yolo", s);
}

test "render of nothing is empty, not a stray separator" {
    var buf: [64]u8 = undefined;
    const c = parse("footer", "branch,tokens");
    try std.testing.expectEqualStrings("", render(&buf, &c, .{}));
}

test "encode round-trips through parse" {
    var c = Config{};
    c.add(.tokens);
    c.add(.branch);
    c.add(.model);
    var buf: [128]u8 = undefined;
    const encoded = c.encode(&buf);
    try std.testing.expectEqualStrings("tokens,branch,model", encoded);
    const back = parse("footer", encoded);
    try std.testing.expectEqual(c.n, back.n);
    for (c.items(), back.items()) |a, b| try std.testing.expectEqual(a, b);
}

test "add and remove keep the list consistent" {
    var c = Config{};
    c.add(.model);
    c.add(.mode);
    c.add(.model); // already present
    try std.testing.expectEqual(@as(usize, 2), c.n);
    c.remove(.model);
    try std.testing.expectEqual(@as(usize, 1), c.n);
    try std.testing.expect(!c.has(.model));
    c.remove(.branch); // not present
    try std.testing.expectEqual(@as(usize, 1), c.n);
}

test "render cannot overflow a small buffer" {
    var tiny: [8]u8 = undefined;
    const c = parse("footer", "model,mode,branch");
    const s = render(&tiny, &c, .{ .model = "a-very-long-model-name", .mode = "yolo", .branch = "main" });
    try std.testing.expect(s.len <= tiny.len);
}
