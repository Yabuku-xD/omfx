const std = @import("std");
const Io = std.Io;
const compact = @import("compact.zig");
const ids = @import("ids.zig");

const log = std.log.scoped(.session);

pub const Kind = enum { user, assistant, tool, verify, outcome, summary };

pub fn encode(allocator: std.mem.Allocator, kind: Kind, body: []const u8) ![]u8 {
    const safe = try allocator.alloc(u8, body.len);
    defer allocator.free(safe);
    for (body, 0..) |c, i| {
        safe[i] = switch (c) {
            '"', '\\', '\n', '\r' => ' ',
            else => c,
        };
    }
    return std.fmt.allocPrint(allocator, "{{\"kind\":\"{s}\",\"body\":\"{s}\"}}\n", .{ @tagName(kind), safe });
}

pub const Store = struct {
    lines: std.ArrayList([]const u8) = .empty,
    path: []const u8 = "",

    pub fn append(self: *Store, allocator: std.mem.Allocator, kind: Kind, body: []const u8) !void {
        const line = try encode(allocator, kind, body);
        try self.lines.append(allocator, line);
    }

    pub fn persist(self: Store, allocator: std.mem.Allocator, dir: Io.Dir, io: Io) !void {
        if (self.path.len == 0) return;
        const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{self.path});
        defer allocator.free(tmp);
        {
            var file = try dir.createFile(io, tmp, .{ .truncate = true });
            defer file.close(io);
            var buf: [1024]u8 = undefined;
            var w = file.writer(io, &buf);
            for (self.lines.items) |line| try w.interface.writeAll(line);
            try w.interface.flush();
        }
        dir.rename(tmp, dir, self.path, io) catch |err| {
            log.warn("rename {s}.tmp: {s}", .{ self.path, @errorName(err) });
            var file = try dir.createFile(io, self.path, .{ .truncate = true });
            defer file.close(io);
            var buf: [1024]u8 = undefined;
            var w = file.writer(io, &buf);
            for (self.lines.items) |line| try w.interface.writeAll(line);
            try w.interface.flush();
        };
    }

    pub fn dump(self: Store, allocator: std.mem.Allocator) ![]u8 {
        var total: usize = 0;
        for (self.lines.items) |line| total += line.len;
        var out = try allocator.alloc(u8, total);
        var off: usize = 0;
        for (self.lines.items) |line| {
            @memcpy(out[off..][0..line.len], line);
            off += line.len;
        }
        return out;
    }

    pub fn load(self: *Store, allocator: std.mem.Allocator, blob: []const u8) !void {
        var it = std.mem.splitScalar(u8, blob, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (!std.mem.startsWith(u8, line, "{\"kind\"")) break;
            try self.lines.append(allocator, try allocator.dupe(u8, line));
        }
    }

    fn applyCompact(self: *Store, allocator: std.mem.Allocator, kept_from: usize) !void {
        var turns: std.ArrayList(compact.Turn) = .empty;
        defer turns.deinit(allocator);
        for (self.lines.items) |line| {
            try turns.append(allocator, .{ .role = "turn", .text = line });
        }
        const summary = try compact.summarizePrefix(allocator, turns.items, kept_from);
        defer allocator.free(summary);
        const encoded = try encode(allocator, .summary, summary);
        var kept: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (kept.items) |line| allocator.free(line);
            kept.deinit(allocator);
        }
        try kept.append(allocator, encoded);
        for (self.lines.items[kept_from..]) |line| {
            try kept.append(allocator, line);
        }
        for (self.lines.items[0..kept_from]) |line| allocator.free(line);
        self.lines.deinit(allocator);
        self.lines = kept;
    }

    pub fn compactIfNeeded(self: *Store, allocator: std.mem.Allocator) !void {
        switch (compact.plan(self.lines.items.len)) {
            .keep => return,
            .drop => |from| try self.applyCompact(allocator, from),
        }
    }

    /// Compact even under the auto threshold. Keeps the last `keep_last` lines.
    pub fn compactNow(self: *Store, allocator: std.mem.Allocator) !bool {
        if (self.lines.items.len <= compact.keep_last) return false;
        const from = self.lines.items.len - compact.keep_last;
        try self.applyCompact(allocator, from);
        return true;
    }

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line);
        self.lines.deinit(allocator);
    }
};

pub fn sessionPath(allocator: std.mem.Allocator, home: []const u8, id: ids.SessionId) ![]u8 {
    const raw = id.bytes;
    const name = if (std.mem.endsWith(u8, raw, ".jsonl")) raw else try std.fmt.allocPrint(allocator, "{s}.jsonl", .{raw});
    defer if (!std.mem.endsWith(u8, raw, ".jsonl")) allocator.free(name);
    return std.fs.path.join(allocator, &.{ home, ".omfx", "sessions", name });
}

pub fn resolveId(raw: []const u8) ids.SessionId {
    return ids.parseSession(raw);
}

pub fn appendTurn(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    user: []const u8,
    assistant: []const u8,
    tool_body: []const u8,
    verify: []const u8,
    outcome: []const u8,
) !void {
    const root = try @import("config.zig").profileRoot(gpa, home);
    defer gpa.free(root);
    var home_dir = Io.Dir.cwd();
    home_dir.createDirPath(io, root) catch |err| {
        log.warn("mkdir {s}: {s}", .{ root, @errorName(err) });
    };
    const dir_path = try std.fs.path.join(gpa, &.{ root, "sessions" });
    defer gpa.free(dir_path);
    home_dir.createDirPath(io, dir_path) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir_path, @errorName(err) });
    };
    const file_path = try std.fs.path.join(gpa, &.{ dir_path, "last.jsonl" });
    defer gpa.free(file_path);
    var store: Store = .{};
    defer store.deinit(gpa);
    if (Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1_000_000))) |blob| {
        defer gpa.free(blob);
        try store.load(gpa, blob);
    } else |_| {}
    if (user.len > 0) try store.append(gpa, .user, user);
    if (tool_body.len > 0) try store.append(gpa, .tool, tool_body);
    if (verify.len > 0) try store.append(gpa, .verify, verify);
    if (outcome.len > 0) try store.append(gpa, .outcome, outcome);
    if (assistant.len > 0) try store.append(gpa, .assistant, assistant);
    try store.compactIfNeeded(gpa);
    store.path = file_path;
    store.persist(gpa, home_dir, io) catch |err| {
        log.warn("persist {s}: {s}", .{ file_path, @errorName(err) });
    };
}

pub fn rotateLast(allocator: std.mem.Allocator, io: Io, home: []const u8) void {
    const src = sessionPath(allocator, home, resolveId("last")) catch return;
    defer allocator.free(src);
    const dest = sessionPath(allocator, home, resolveId("last-prev")) catch return;
    defer allocator.free(dest);
    Io.Dir.copyFile(Io.Dir.cwd(), src, Io.Dir.cwd(), dest, io, .{}) catch |err| {
        log.warn("rotate last: {s}", .{@errorName(err)});
    };
}

pub fn truncateLast(allocator: std.mem.Allocator, io: Io, home: []const u8) void {
    const p = sessionPath(allocator, home, resolveId("last")) catch return;
    defer allocator.free(p);
    var file = Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch |err| {
        log.warn("truncate last: {s}", .{@errorName(err)});
        return;
    };
    file.close(io);
}

pub fn lastBody(blob: []const u8, kind: Kind) []const u8 {
    const needle = switch (kind) {
        .user => "\"kind\":\"user\"",
        .assistant => "\"kind\":\"assistant\"",
        .tool => "\"kind\":\"tool\"",
        .verify => "\"kind\":\"verify\"",
        .outcome => "\"kind\":\"outcome\"",
        .summary => "\"kind\":\"summary\"",
    };
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        const key = "\"body\":\"";
        const start = std.mem.indexOf(u8, line, key) orelse continue;
        var i = start + key.len;
        const from = i;
        while (i < line.len and line[i] != '"') i += 1;
        last = line[from..i];
    }
    return last;
}

/// One record of a stored session.
pub const Entry = struct { kind: Kind, body: []const u8 };

/// Walks a session file record by record.
///
/// `/resume` used to `emit` the raw blob, so resuming pasted a wall of JSONL --
/// escaped source, tool bodies and all -- into the transcript. Replay needs the
/// records, not the file.
pub const Walk = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn init(blob: []const u8) Walk {
        return .{ .it = std.mem.splitScalar(u8, blob, '\n') };
    }

    pub fn next(self: *Walk) ?Entry {
        while (self.it.next()) |line| {
            if (line.len == 0) continue;
            const kind = kindOf(line) orelse continue;
            const key = "\"body\":\"";
            const start = std.mem.indexOf(u8, line, key) orelse continue;
            var i = start + key.len;
            const from = i;
            // Body is JSON-escaped; the closing quote is the first unescaped one.
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (line[i] == '"') break;
            }
            return .{ .kind = kind, .body = line[from..@min(i, line.len)] };
        }
        return null;
    }
};

/// Needles built once at comptime: they are a property of the tag, not of the
/// line, so formatting one per record would allocate on every entry.
const kind_needles = blk: {
    const tags = std.meta.tags(Kind);
    var out: [tags.len]struct { kind: Kind, needle: []const u8 } = undefined;
    for (tags, 0..) |k, i| {
        out[i] = .{ .kind = k, .needle = "\"kind\":\"" ++ @tagName(k) ++ "\"" };
    }
    break :blk out;
};

fn kindOf(line: []const u8) ?Kind {
    for (kind_needles) |n| {
        if (std.mem.indexOf(u8, line, n.needle) != null) return n.kind;
    }
    return null;
}

pub fn firstUser(blob: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"kind\":\"user\"") == null) continue;
        const key = "\"body\":\"";
        const start = std.mem.indexOf(u8, line, key) orelse continue;
        var i = start + key.len;
        const from = i;
        while (i < line.len and line[i] != '"') i += 1;
        const s = line[from..i];
        return if (s.len > 40) s[0..40] else s;
    }
    return "";
}

pub fn slugTitle(raw: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var dash = false;
    for (raw) |c| {
        if (n >= buf.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            buf[n] = std.ascii.toLower(c);
            n += 1;
            dash = false;
        } else if (n > 0 and !dash) {
            buf[n] = '-';
            n += 1;
            dash = true;
        }
    }
    if (n > 0 and buf[n - 1] == '-') n -= 1;
    if (n == 0) return "session";
    return buf[0..n];
}

pub fn nonEmptyCount(blob: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

pub fn prefixNonEmpty(blob: []const u8, n: usize) []const u8 {
    if (n == 0) return blob[0..0];
    var kept: usize = 0;
    var i: usize = 0;
    while (i < blob.len) {
        const nl = std.mem.indexOfScalar(u8, blob[i..], '\n');
        const line_end = if (nl) |off| i + off else blob.len;
        const line = blob[i..line_end];
        const next = if (nl) |_| line_end + 1 else blob.len;
        if (line.len > 0) {
            kept += 1;
            if (kept >= n) return blob[0..next];
        }
        i = next;
    }
    return blob;
}

fn writePath(io: Io, path: []const u8, blob: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
        };
    }
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(blob);
    try w.interface.flush();
}

pub fn rewriteLast(allocator: std.mem.Allocator, io: Io, home: []const u8, blob: []const u8) !void {
    const p = try sessionPath(allocator, home, resolveId("last"));
    defer allocator.free(p);
    try writePath(io, p, blob);
}

pub fn rewindLast(allocator: std.mem.Allocator, io: Io, home: []const u8, keep_lines: usize) !void {
    const p = try sessionPath(allocator, home, resolveId("last"));
    defer allocator.free(p);
    const blob = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(1_000_000)) catch {
        try rewriteLast(allocator, io, home, "");
        return;
    };
    defer allocator.free(blob);
    try rewriteLast(allocator, io, home, prefixNonEmpty(blob, keep_lines));
}

/// Which half of the session a summarize replaces.
pub const Half = enum {
    /// Everything after the chosen point, compressed into one record. The
    /// early turns that set the task up are the ones worth keeping verbatim.
    from,
    /// Everything before it. Useful when the setup is long and the recent
    /// work is what matters.
    upto,
};

/// Replace half the session with one summary record, in place.
///
/// The rewind menu offers this next to restoring, because the reason to go
/// back is often "this got long" rather than "this went wrong": a summarize
/// frees the window without losing the thread. The summary is built locally
/// from the turns themselves -- `compact.summarizePrefix` counts them and
/// cites the archived bodies -- so it costs no tokens and cannot invent
/// anything that was not there.
pub fn summarizeAt(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    keep_lines: usize,
    half: Half,
) !usize {
    const p = try sessionPath(allocator, home, resolveId("last"));
    defer allocator.free(p);
    const blob = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(1_000_000)) catch return 0;
    defer allocator.free(blob);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len != 0) try lines.append(allocator, line);
    }
    const at = @min(keep_lines, lines.items.len);
    // Nothing on the side being compressed: say so rather than write a
    // summary of no turns over turns that are already short.
    const span = switch (half) {
        .from => lines.items.len - at,
        .upto => at,
    };
    if (span < 2) return 0;

    var turns: std.ArrayList(compact.Turn) = .empty;
    defer turns.deinit(allocator);
    const src = switch (half) {
        .from => lines.items[at..],
        .upto => lines.items[0..at],
    };
    for (src) |line| try turns.append(allocator, .{ .role = "turn", .text = line });
    const summary = try compact.summarizePrefix(allocator, turns.items, turns.items.len);
    defer allocator.free(summary);
    const encoded = try encode(allocator, .summary, summary);
    defer allocator.free(encoded);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const head = switch (half) {
        .from => lines.items[0..at],
        .upto => &[_][]const u8{},
    };
    const tail = switch (half) {
        .from => &[_][]const u8{},
        .upto => lines.items[at..],
    };
    for (head) |line| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, encoded);
    try out.append(allocator, '\n');
    for (tail) |line| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    try rewriteLast(allocator, io, home, out.items);
    return span;
}

pub fn forkLast(allocator: std.mem.Allocator, io: Io, home: []const u8, dest_id: []const u8) ![]u8 {
    const src = try sessionPath(allocator, home, resolveId("last"));
    defer allocator.free(src);
    const dest = try sessionPath(allocator, home, resolveId(dest_id));
    Io.Dir.copyFile(Io.Dir.cwd(), src, Io.Dir.cwd(), dest, io, .{}) catch |err| {
        log.warn("fork last: {s}", .{@errorName(err)});
        const blob = Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(1_000_000)) catch return dest;
        defer allocator.free(blob);
        try writePath(io, dest, blob);
    };
    return dest;
}

pub fn listIds(dir: Io.Dir, io: Io, allocator: std.mem.Allocator) ![][]const u8 {
    var it = dir.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    while (it.next(io) catch |err| blk: {
        log.warn("iterate sessions: {s}", .{@errorName(err)});
        break :blk null;
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (std.mem.endsWith(u8, entry.name, ".tmp")) continue;
        const stem = entry.name[0 .. entry.name.len - ".jsonl".len];
        try names.append(allocator, try allocator.dupe(u8, stem));
    }
    return names.toOwnedSlice(allocator);
}

/// Delete all but the newest `keep` sessions.
///
/// Session ids sort chronologically (they are timestamps), so "newest" is the
/// tail of a sorted list and no stat call is needed. Best effort: losing a
/// session file is not worth failing a launch over.
pub fn prune(allocator: std.mem.Allocator, io: Io, home: []const u8, keep: u32) void {
    if (keep == 0) return;
    const dir_path = std.fs.path.join(allocator, &.{ home, ".omfx", "sessions" }) catch return;
    defer allocator.free(dir_path);
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const saved = listIds(dir, io, allocator) catch return;
    defer {
        for (saved) |id| allocator.free(id);
        allocator.free(saved);
    }
    if (saved.len <= keep) return;
    std.mem.sort([]const u8, saved, {}, lessThanId);
    for (saved[0 .. saved.len - keep]) |id| {
        const name = std.fmt.allocPrint(allocator, "{s}.jsonl", .{id}) catch continue;
        defer allocator.free(name);
        dir.deleteFile(io, name) catch |err| {
            log.debug("prune {s}: {s}", .{ name, @errorName(err) });
        };
    }
}

fn lessThanId(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "prune keeps the newest and drops the rest" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(home);
    const dir_path = try std.fs.path.join(a, &.{ home, ".omfx", "sessions" });
    defer a.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    for ([_][]const u8{ "20260101-a.jsonl", "20260102-b.jsonl", "20260103-c.jsonl" }) |name| {
        var f = try dir.createFile(io, name, .{ .truncate = true });
        f.close(io);
    }
    prune(a, io, home, 2);
    const left = try listIds(dir, io, a);
    defer {
        for (left) |id| a.free(id);
        a.free(left);
    }
    try std.testing.expectEqual(@as(usize, 2), left.len);
    // Zero means keep everything, not delete everything.
    prune(a, io, home, 0);
    const still = try listIds(dir, io, a);
    defer {
        for (still) |id| a.free(id);
        a.free(still);
    }
    try std.testing.expectEqual(@as(usize, 2), still.len);
}

test "summarize replaces one half and keeps the other" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(home);

    var store: Store = .{};
    defer store.deinit(a);
    for ([_][]const u8{ "one", "two", "three", "four" }) |t| {
        try store.append(a, .user, t);
    }
    const blob0 = try store.dump(a);
    defer a.free(blob0);
    try rewriteLast(a, io, home, blob0);

    // Everything after the second turn, compressed; the first two survive.
    const span = try summarizeAt(a, io, home, 2, .from);
    try std.testing.expectEqual(@as(usize, 2), span);
    const p = try sessionPath(a, home, resolveId("last"));
    defer a.free(p);
    const blob = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(100_000));
    defer a.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "\"kind\":\"summary\"") != null);
    // "three" and "four" are gone as turns; the summary stands for them.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, blob, "\"kind\""));
}

test "summarizing a side with nothing on it does nothing" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(home);

    var store: Store = .{};
    defer store.deinit(a);
    try store.append(a, .user, "only");
    const blob0 = try store.dump(a);
    defer a.free(blob0);
    try rewriteLast(a, io, home, blob0);
    // One turn on either side is not worth a summary that says "1 turn".
    try std.testing.expectEqual(@as(usize, 0), try summarizeAt(a, io, home, 1, .from));
    try std.testing.expectEqual(@as(usize, 0), try summarizeAt(a, io, home, 1, .upto));
}

test "two turns persist" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try store.append(std.testing.allocator, .user, "hi");
    try store.append(std.testing.allocator, .assistant, "hello");
    try std.testing.expectEqual(@as(usize, 2), store.lines.items.len);
}

test "tool verify outcome kinds encode" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try store.append(std.testing.allocator, .tool, "edit:abcd1234");
    try store.append(std.testing.allocator, .verify, "clean");
    try store.append(std.testing.allocator, .outcome, "continued");
    try std.testing.expect(std.mem.indexOf(u8, store.lines.items[0], "\"kind\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.lines.items[1], "clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.lines.items[2], "continued") != null);
}

test "truncated jsonl keeps valid prefix" {
    const blob =
        \\{"kind":"user","body":"a"}
        \\{"kind":"assistant","body":"b"}
        \\{not-json
    ;
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try store.load(std.testing.allocator, blob);
    try std.testing.expectEqual(@as(usize, 2), store.lines.items.len);
}

test "resolveId last aliases" {
    try std.testing.expectEqualStrings("last", resolveId("last").bytes);
    try std.testing.expectEqualStrings("last", resolveId("latest").bytes);
    try std.testing.expectEqualStrings("abc", resolveId("abc").bytes);
}

test "prefixNonEmpty keeps the first n turns" {
    const blob = "{\"kind\":\"user\",\"body\":\"a\"}\n{\"kind\":\"assistant\",\"body\":\"b\"}\n{\"kind\":\"user\",\"body\":\"c\"}\n";
    try std.testing.expectEqual(@as(usize, 3), nonEmptyCount(blob));
    const one = prefixNonEmpty(blob, 1);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"b\"") == null);
    const two = prefixNonEmpty(blob, 2);
    try std.testing.expect(std.mem.indexOf(u8, two, "\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, two, "\"c\"") == null);
}

test "compactIfNeeded keeps tail" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try store.append(std.testing.allocator, .user, "x");
    }
    try store.compactIfNeeded(std.testing.allocator);
    try std.testing.expect(store.lines.items.len <= 5);
}

test "compactNow fires under auto threshold" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try store.append(std.testing.allocator, .user, "x");
    }
    try std.testing.expect(try store.compactNow(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, compact.keep_last + 1), store.lines.items.len);
}

test "compactNow is a no-op on a short store" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try store.append(std.testing.allocator, .user, "x");
    try std.testing.expect(!(try store.compactNow(std.testing.allocator)));
    try std.testing.expectEqual(@as(usize, 1), store.lines.items.len);
}

test "lastBody and firstUser read jsonl" {
    const blob =
        \\{"kind":"user","body":"hello there"}
        \\{"kind":"assistant","body":"hi"}
        \\{"kind":"user","body":"again"}
        \\
    ;
    try std.testing.expectEqualStrings("again", lastBody(blob, .user));
    try std.testing.expectEqualStrings("hi", lastBody(blob, .assistant));
    try std.testing.expectEqualStrings("hello there", firstUser(blob));
}

test "slugTitle lowercases and dashes" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("fix-login", slugTitle("Fix login", &buf));
    try std.testing.expectEqualStrings("session", slugTitle("???", &buf));
}

test "walk yields every record, not the raw file" {
    const blob =
        \\{"kind":"user","body":"hello"}
        \\{"kind":"assistant","body":"hi there"}
        \\{"kind":"tool","body":"read:abc"}
        \\{"kind":"outcome","body":"continued"}
    ;
    var w = Walk.init(blob);
    const a = w.next().?;
    try std.testing.expectEqual(Kind.user, a.kind);
    try std.testing.expectEqualStrings("hello", a.body);
    const b = w.next().?;
    try std.testing.expectEqual(Kind.assistant, b.kind);
    try std.testing.expectEqualStrings("hi there", b.body);
    try std.testing.expectEqual(Kind.tool, w.next().?.kind);
    try std.testing.expectEqual(Kind.outcome, w.next().?.kind);
    try std.testing.expect(w.next() == null);
}

test "walk stops a body at its own closing quote" {
    // A body containing an escaped quote must not truncate early.
    const blob =
        \\{"kind":"user","body":"say \"hi\" twice"}
    ;
    var w = Walk.init(blob);
    try std.testing.expectEqualStrings("say \\\"hi\\\" twice", w.next().?.body);
}

test "walk skips blank and unrecognised lines" {
    const blob = "\n{\"kind\":\"nope\",\"body\":\"x\"}\n{\"kind\":\"user\",\"body\":\"real\"}\n";
    var w = Walk.init(blob);
    const e = w.next().?;
    try std.testing.expectEqualStrings("real", e.body);
    try std.testing.expect(w.next() == null);
}
