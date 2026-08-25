const std = @import("std");
const Io = std.Io;
const compact = @import("compact.zig");
const ids = @import("ids.zig");
const recall = @import("recall.zig");

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

/// Permanently removes one saved session and the workspace sidecars it owns.
///
/// Always drops `{id}.jsonl` and `.omfx/handoff/{id}.md`, plus any recall/run
/// this session (or its handoff packet) names. Then sweeps recall/run entries
/// that no remaining session or handoff still cites — so emptying the resume
/// list also clears orphaned e2e residue, without wiping cites still in use.
pub fn remove(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
    id: []const u8,
) void {
    if (id.len == 0) return;
    const path = sessionPath(allocator, home, resolveId(id)) catch return;
    defer allocator.free(path);
    const blob = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512_000)) catch "";
    defer if (blob.len != 0) allocator.free(blob);

    if (workspace.len != 0) cascadeWorkspace(allocator, io, workspace, id, blob);

    Io.Dir.cwd().deleteFile(io, path) catch |err| {
        log.debug("remove {s}: {s}", .{ id, @errorName(err) });
    };

    if (workspace.len != 0) sweepOrphans(allocator, io, home, workspace);
}

fn cascadeWorkspace(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    id: []const u8,
    blob: []const u8,
) void {
    const handoff_name = std.fmt.allocPrint(allocator, "{s}.md", .{id}) catch return;
    defer allocator.free(handoff_name);
    const handoff = std.fs.path.join(allocator, &.{ workspace, ".omfx", "handoff", handoff_name }) catch return;
    defer allocator.free(handoff);
    const packet = Io.Dir.cwd().readFileAlloc(io, handoff, allocator, .limited(64_000)) catch "";
    defer if (packet.len != 0) allocator.free(packet);

    var recall_ids: [recall.max_items]recall.Id = undefined;
    var recall_n: usize = 0;
    recall_n = mergeRecallIds(&recall_ids, recall_n, blob);
    recall_n = mergeRecallIds(&recall_ids, recall_n, packet);

    var i: usize = 0;
    while (i < recall_n) : (i += 1) {
        deleteRecallFile(allocator, io, workspace, recall_ids[i]);
    }

    deleteRunDir(allocator, io, workspace, id);
    var run_buf: [32][40]u8 = undefined;
    var run_lens: [32]usize = undefined;
    var run_n: usize = 0;
    run_n = collectRunIds(blob, &run_buf, &run_lens, run_n);
    run_n = collectRunIds(packet, &run_buf, &run_lens, run_n);
    var r: usize = 0;
    while (r < run_n) : (r += 1) {
        deleteRunDir(allocator, io, workspace, run_buf[r][0..run_lens[r]]);
    }

    Io.Dir.cwd().deleteFile(io, handoff) catch {};
}

/// Drop recall/run files that nothing left on disk still points at.
fn sweepOrphans(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
) void {
    var live_recall: [recall.max_items]recall.Id = undefined;
    var live_recall_n: usize = 0;
    var live_runs: [32][40]u8 = undefined;
    var live_run_lens: [32]usize = undefined;
    var live_run_n: usize = 0;

    // Remaining sessions (including `last`).
    const sess_dir_path = std.fs.path.join(allocator, &.{ home, ".omfx", "sessions" }) catch return;
    defer allocator.free(sess_dir_path);
    if (Io.Dir.cwd().openDir(io, sess_dir_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        if (listIds(dir, io, allocator)) |idlist| {
            defer {
                for (idlist) |sid| allocator.free(sid);
                allocator.free(idlist);
            }
            for (idlist) |sid| {
                const p = sessionPath(allocator, home, resolveId(sid)) catch continue;
                defer allocator.free(p);
                const blob = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(512_000)) catch continue;
                defer allocator.free(blob);
                live_recall_n = mergeRecallIds(&live_recall, live_recall_n, blob);
                live_run_n = collectRunIds(blob, &live_runs, &live_run_lens, live_run_n);
            }
        } else |_| {}
    } else |_| {}

    // Remaining handoff packets.
    const handoff_dir = std.fs.path.join(allocator, &.{ workspace, ".omfx", "handoff" }) catch return;
    defer allocator.free(handoff_dir);
    if (Io.Dir.cwd().openDir(io, handoff_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const full = std.fs.path.join(allocator, &.{ handoff_dir, entry.name }) catch continue;
            defer allocator.free(full);
            const packet = Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(64_000)) catch continue;
            defer allocator.free(packet);
            live_recall_n = mergeRecallIds(&live_recall, live_recall_n, packet);
            live_run_n = collectRunIds(packet, &live_runs, &live_run_lens, live_run_n);
        }
    } else |_| {}

    // Recall files not in the live set.
    const recall_dir = std.fs.path.join(allocator, &.{ workspace, ".omfx", "recall" }) catch return;
    defer allocator.free(recall_dir);
    if (Io.Dir.cwd().openDir(io, recall_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "r")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
            const num = entry.name[1 .. entry.name.len - ".txt".len];
            const id_n = std.fmt.parseInt(u16, num, 10) catch continue;
            if (id_n == 0) continue;
            const rid: recall.Id = @enumFromInt(id_n);
            var keep = false;
            for (live_recall[0..live_recall_n]) |live| {
                if (live == rid) {
                    keep = true;
                    break;
                }
            }
            if (!keep) deleteRecallFile(allocator, io, workspace, rid);
        }
    } else |_| {}

    // Run dirs not in the live set.
    const runs_dir = std.fs.path.join(allocator, &.{ workspace, ".omfx", "runs" }) catch return;
    defer allocator.free(runs_dir);
    if (Io.Dir.cwd().openDir(io, runs_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            var keep = false;
            for (0..live_run_n) |j| {
                if (std.mem.eql(u8, live_runs[j][0..live_run_lens[j]], entry.name)) {
                    keep = true;
                    break;
                }
            }
            if (!keep) deleteRunDir(allocator, io, workspace, entry.name);
        }
    } else |_| {}
}

fn deleteRecallFile(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    id: recall.Id,
) void {
    const name = std.fmt.allocPrint(allocator, "r{d}.txt", .{@intFromEnum(id)}) catch return;
    defer allocator.free(name);
    const full = std.fs.path.join(allocator, &.{ workspace, ".omfx", "recall", name }) catch return;
    defer allocator.free(full);
    Io.Dir.cwd().deleteFile(io, full) catch {};
}

fn mergeRecallIds(out: *[recall.max_items]recall.Id, n0: usize, src: []const u8) usize {
    var n = n0;
    var scratch: [recall.max_items]recall.Id = undefined;
    const from_cites = recall.collectIds(src, &scratch);
    var i: usize = 0;
    while (i < from_cites and n < out.len) : (i += 1) {
        n = takeRecall(out, n, scratch[i]);
    }
    n = collectRecallPaths(src, out, n);
    n = collectHandoffRecallLine(src, out, n);
    return n;
}

fn takeRecall(out: *[recall.max_items]recall.Id, n: usize, id: recall.Id) usize {
    if (@intFromEnum(id) == 0) return n;
    for (out[0..n]) |old| {
        if (old == id) return n;
    }
    if (n >= out.len) return n;
    out[n] = id;
    return n + 1;
}

fn collectRecallPaths(src: []const u8, out: *[recall.max_items]recall.Id, n0: usize) usize {
    const needle = ".omfx/recall/r";
    var n = n0;
    var i: usize = 0;
    while (i < src.len and n < out.len) {
        const rest = src[i..];
        const hit = std.mem.indexOf(u8, rest, needle) orelse break;
        i += hit + needle.len;
        const id = takeDigits(src, &i) orelse continue;
        n = takeRecall(out, n, id);
    }
    return n;
}

/// Handoff packets list bare `rN` tokens under `## recall`, not `cite rN`.
fn collectHandoffRecallLine(src: []const u8, out: *[recall.max_items]recall.Id, n0: usize) usize {
    const hdr = "## recall";
    const at = std.mem.indexOf(u8, src, hdr) orelse return n0;
    var i = at + hdr.len;
    while (i < src.len and (src[i] == '\r' or src[i] == '\n' or src[i] == ' ')) : (i += 1) {}
    var n = n0;
    while (i < src.len and n < out.len) {
        if (src[i] == '#') break;
        if (src[i] == '\n') {
            const line_start = i + 1;
            if (line_start < src.len and src[line_start] == '#') break;
            i += 1;
            continue;
        }
        if (src[i] == 'r' and i + 1 < src.len and src[i + 1] >= '0' and src[i + 1] <= '9') {
            i += 1;
            const id = takeDigits(src, &i) orelse continue;
            n = takeRecall(out, n, id);
            continue;
        }
        i += 1;
    }
    return n;
}

fn takeDigits(src: []const u8, i: *usize) ?recall.Id {
    var v: u16 = 0;
    var saw = false;
    while (i.* < src.len and src[i.*] >= '0' and src[i.*] <= '9') : (i.* += 1) {
        saw = true;
        v = v *% 10 + (src[i.*] - '0');
    }
    if (!saw or v == 0) return null;
    return @enumFromInt(v);
}

fn collectRunIds(
    src: []const u8,
    buf: *[32][40]u8,
    lens: *[32]usize,
    n0: usize,
) usize {
    const needle = ".omfx/runs/";
    var n = n0;
    var i: usize = 0;
    while (i < src.len and n < buf.len) {
        const rest = src[i..];
        const hit = std.mem.indexOf(u8, rest, needle) orelse break;
        i += hit + needle.len;
        const start = i;
        while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '-' or src[i] == '_')) : (i += 1) {}
        const id = src[start..i];
        if (id.len == 0 or id.len >= buf[0].len) continue;
        if (std.mem.eql(u8, id, ".active")) continue;
        var dup = false;
        for (0..n) |j| {
            if (std.mem.eql(u8, buf[j][0..lens[j]], id)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        @memcpy(buf[n][0..id.len], id);
        lens[n] = id.len;
        n += 1;
    }
    return n;
}

fn deleteRunDir(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    run_id: []const u8,
) void {
    if (run_id.len == 0) return;
    const full = std.fs.path.join(allocator, &.{ workspace, ".omfx", "runs", run_id }) catch return;
    defer allocator.free(full);
    Io.Dir.cwd().deleteTree(io, full) catch {};

    // Drop .active when it pointed at the run we just removed.
    const active = std.fs.path.join(allocator, &.{ workspace, ".omfx", "runs", ".active" }) catch return;
    defer allocator.free(active);
    const cur = Io.Dir.cwd().readFileAlloc(io, active, allocator, .limited(64)) catch return;
    defer allocator.free(cur);
    if (std.mem.eql(u8, std.mem.trim(u8, cur, " \t\r\n"), run_id)) {
        Io.Dir.cwd().deleteFile(io, active) catch {};
    }
}

/// Wall-clock stamp for the resume list. Empty when unreadable.
pub fn formatWhen(buf: []u8, io: Io, path: []const u8) []const u8 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return "";
    return formatSecs(buf, st.mtime.toSeconds());
}

pub fn formatSecs(buf: []u8, secs_raw: i64) []const u8 {
    const secs: u64 = @intCast(@max(secs_raw, 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    }) catch "";
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

test "remove deletes one session file permanently" {
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

    // Session body cites a recall archive and a run dir.
    {
        const keep_body =
            \\{"kind":"assistant","body":"cite r7 tool=read. .omfx/recall/r7.txt and .omfx/runs/r2/checkpoint.md"}
            \\
        ;
        var f = try dir.createFile(io, "keep-me.jsonl", .{ .truncate = true });
        defer f.close(io);
        var kbuf: [256]u8 = undefined;
        var kw = f.writer(io, &kbuf);
        try kw.interface.writeAll(keep_body);
        try kw.interface.flush();
        const body =
            \\{"kind":"assistant","body":"cite r3 tool=read path=a chars=1. read .omfx/recall/r3.txt. also .omfx/runs/r9/checkpoint.md"}
            \\
        ;
        var g = try dir.createFile(io, "drop-me.jsonl", .{ .truncate = true });
        defer g.close(io);
        var buf: [512]u8 = undefined;
        var w = g.writer(io, &buf);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }

    const handoff_dir = try std.fs.path.join(a, &.{ home, ".omfx", "handoff" });
    defer a.free(handoff_dir);
    try Io.Dir.cwd().createDirPath(io, handoff_dir);
    {
        const packet = try std.fs.path.join(a, &.{ handoff_dir, "drop-me.md" });
        defer a.free(packet);
        var h = try Io.Dir.cwd().createFile(io, packet, .{ .truncate = true });
        defer h.close(io);
        var buf: [256]u8 = undefined;
        var w = h.writer(io, &buf);
        try w.interface.writeAll("## recall\nr5\n");
        try w.interface.flush();
        const keep_packet = try std.fs.path.join(a, &.{ handoff_dir, "keep-me.md" });
        defer a.free(keep_packet);
        var k = try Io.Dir.cwd().createFile(io, keep_packet, .{ .truncate = true });
        k.close(io);
    }

    const recall_dir = try std.fs.path.join(a, &.{ home, ".omfx", "recall" });
    defer a.free(recall_dir);
    try Io.Dir.cwd().createDirPath(io, recall_dir);
    for ([_][]const u8{ "r3.txt", "r5.txt", "r7.txt" }) |name| {
        const p = try std.fs.path.join(a, &.{ recall_dir, name });
        defer a.free(p);
        var f = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
        f.close(io);
    }

    for ([_][]const u8{ "r9", "r2", "drop-me" }) |run_id| {
        const run_dir = try std.fs.path.join(a, &.{ home, ".omfx", "runs", run_id });
        defer a.free(run_dir);
        try Io.Dir.cwd().createDirPath(io, run_dir);
        const meta = try std.fs.path.join(a, &.{ run_dir, "meta.json" });
        defer a.free(meta);
        var f = try Io.Dir.cwd().createFile(io, meta, .{ .truncate = true });
        f.close(io);
    }
    {
        const active = try std.fs.path.join(a, &.{ home, ".omfx", "runs", ".active" });
        defer a.free(active);
        var f = try Io.Dir.cwd().createFile(io, active, .{ .truncate = true });
        defer f.close(io);
        var buf: [16]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("r9");
        try w.interface.flush();
    }

    remove(a, io, home, home, "drop-me");
    const left = try listIds(dir, io, a);
    defer {
        for (left) |id| a.free(id);
        a.free(left);
    }
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("keep-me", left[0]);

    // Handoff for this session is gone; the other stays.
    {
        const gone = try std.fs.path.join(a, &.{ handoff_dir, "drop-me.md" });
        defer a.free(gone);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, gone, .{}));
        const kept = try std.fs.path.join(a, &.{ handoff_dir, "keep-me.md" });
        defer a.free(kept);
        try Io.Dir.cwd().access(io, kept, .{});
    }
    // Cited recalls gone; r7 kept because keep-me still cites it.
    {
        const r3 = try std.fs.path.join(a, &.{ recall_dir, "r3.txt" });
        defer a.free(r3);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, r3, .{}));
        const r5 = try std.fs.path.join(a, &.{ recall_dir, "r5.txt" });
        defer a.free(r5);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, r5, .{}));
        const r7 = try std.fs.path.join(a, &.{ recall_dir, "r7.txt" });
        defer a.free(r7);
        try Io.Dir.cwd().access(io, r7, .{});
    }
    // Named + same-id runs gone; r2 kept by keep-me. .active cleared with r9.
    {
        const r9 = try std.fs.path.join(a, &.{ home, ".omfx", "runs", "r9" });
        defer a.free(r9);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, r9, .{}));
        const same = try std.fs.path.join(a, &.{ home, ".omfx", "runs", "drop-me" });
        defer a.free(same);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, same, .{}));
        const r2 = try std.fs.path.join(a, &.{ home, ".omfx", "runs", "r2" });
        defer a.free(r2);
        try Io.Dir.cwd().access(io, r2, .{});
        const active = try std.fs.path.join(a, &.{ home, ".omfx", "runs", ".active" });
        defer a.free(active);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, active, .{}));
    }
    // Missing ids are fine.
    remove(a, io, home, home, "drop-me");
}

test "formatWhen returns a stamped clock from mtime" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(home);
    const dir_path = try std.fs.path.join(a, &.{ home, ".omfx", "sessions" });
    defer a.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "stamp.jsonl" });
    defer a.free(path);
    {
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        f.close(io);
    }
    var buf: [32]u8 = undefined;
    const when = formatWhen(&buf, io, path);
    try std.testing.expect(when.len >= "YYYY-MM-DD HH:MM".len);
    try std.testing.expect(when[4] == '-' and when[7] == '-' and when[10] == ' ' and when[13] == ':');
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
