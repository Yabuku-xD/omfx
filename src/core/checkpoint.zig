//! Local run checkpoint / sleep: pointers + pinned mode/plan on disk, thin wake
//! stub — zero compute while parked, no transcript dump into the next turn.
//! Layout: `.omfx/runs/<id>/{checkpoint.md,meta.json}`

const std = @import("std");
const Io = std.Io;
const board = @import("board.zig");
const snip = @import("packet_snip.zig");

const log = std.log.scoped(.checkpoint);

pub const runs_dir = ".omfx/runs";
const active_rel = ".omfx/runs/.active";

pub const max_note: usize = 200;

pub const Status = enum {
    ready,
    sleeping,
    done,

    pub fn fromSlice(s: []const u8) ?Status {
        return std.meta.stringToEnum(Status, s);
    }

    pub fn asSlice(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const Input = struct {
    goal: []const u8,
    note: []const u8 = "",
    last_tool: []const u8 = "",
    last_reply: []const u8 = "",
    /// Re-injected on wake (Constraint Pinning); not summarized.
    mode: []const u8 = "ask",
    plan: []const u8 = "off",
    git_sha: []const u8 = "",
};

pub const Built = struct {
    id: []u8,
    stub: []u8,
    packet: []u8,
    meta: []u8,
    rel_dir: []u8,
};

fn nextId(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    var n: usize = 1;
    while (n < 10_000) : (n += 1) {
        const cand = try std.fmt.allocPrint(allocator, "r{d}", .{n});
        errdefer allocator.free(cand);
        const full = try std.fs.path.join(allocator, &.{ workspace, runs_dir, cand });
        defer allocator.free(full);
        var d = Io.Dir.cwd().openDir(io, full, .{}) catch {
            return cand;
        };
        d.close(io);
        allocator.free(cand);
    }
    return allocator.dupe(u8, "r1");
}

pub fn build(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    status: Status,
    input: Input,
) !Built {
    const id = try nextId(allocator, io, workspace);
    errdefer allocator.free(id);

    const goal = snip.clip(input.goal, snip.max_goal);
    const note = snip.clip(input.note, max_note);
    const goal_s = if (goal.len == 0) "(none)" else goal;

    const tail = board.loadTail(allocator, io, workspace);
    defer if (tail.len > 0) allocator.free(tail);
    var notes: [board.max_notes]board.Note = undefined;
    const note_n = board.parseAll(tail, &notes);

    var path_buf: std.ArrayList(u8) = .empty;
    errdefer path_buf.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    _ = try snip.appendPaths(allocator, notes[0..note_n], &path_buf, &seen);

    var board_buf: std.ArrayList(u8) = .empty;
    defer board_buf.deinit(allocator);
    try snip.appendBoardLines(allocator, notes[0..note_n], &board_buf);

    var todo_buf: std.ArrayList(u8) = .empty;
    defer todo_buf.deinit(allocator);
    try snip.appendTodos(allocator, &todo_buf);

    var recall_buf: std.ArrayList(u8) = .empty;
    defer recall_buf.deinit(allocator);
    const recall_n = try snip.appendRecallIds(allocator, input.last_reply, &recall_buf);

    const rel_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runs_dir, id });
    errdefer allocator.free(rel_dir);
    const packet_rel = try std.fmt.allocPrint(allocator, "{s}/checkpoint.md", .{rel_dir});
    defer allocator.free(packet_rel);

    var packet: std.ArrayList(u8) = .empty;
    errdefer packet.deinit(allocator);
    try packet.print(allocator,
        \\# run {s}
        \\
        \\## status
        \\{s}
        \\
        \\## goal
        \\{s}
        \\
        \\## note
        \\{s}
        \\
        \\## pinned (Constraint Pinning)
        \\mode={s}
        \\plan={s}
        \\
        \\## last_tool
        \\{s}
        \\
        \\## git_sha
        \\{s}
        \\
        \\## board
        \\{s}
        \\## paths
        \\{s}
        \\
        \\## recall
        \\{s}
        \\
        \\## open_todos
        \\{s}
        \\
        \\Effects live in the tree. Do not dump prior transcript. Open cites/paths only if needed.
        \\
    , .{
        id,
        status.asSlice(),
        goal_s,
        if (note.len == 0) "(none)" else note,
        if (input.mode.len == 0) "ask" else input.mode,
        if (input.plan.len == 0) "off" else input.plan,
        if (input.last_tool.len == 0) "(none)" else input.last_tool,
        if (input.git_sha.len == 0) "(none)" else input.git_sha,
        board_buf.items,
        if (path_buf.items.len == 0) "(none)" else path_buf.items,
        if (recall_n == 0) "(none)" else recall_buf.items,
        todo_buf.items,
    });

    var stub: std.ArrayList(u8) = .empty;
    errdefer stub.deinit(allocator);
    try stub.print(allocator,
        \\WAKE run={s} status={s}
        \\goal={s}
        \\paths: {s}
        \\recall: {s}
        \\pinned: mode={s} plan={s}
        \\packet: {s}
        \\Do not replay prior turns. Use read on the packet or recall cites only if needed; continue with the usual tools. Honor pinned plan=on (read-only until /plan go) and any active /spec pointer.
        \\
    , .{
        id,
        status.asSlice(),
        goal_s,
        if (path_buf.items.len == 0) "(none)" else path_buf.items,
        if (recall_n == 0) "(none)" else recall_buf.items,
        if (input.mode.len == 0) "ask" else input.mode,
        if (input.plan.len == 0) "off" else input.plan,
        packet_rel,
    });

    var meta: std.ArrayList(u8) = .empty;
    errdefer meta.deinit(allocator);
    try meta.print(allocator,
        \\{{"id":"{s}","status":"{s}","goal":"{s}","mode":"{s}","plan":"{s}","packet":"{s}"}}
        \\
    , .{
        id,
        status.asSlice(),
        goal_s,
        if (input.mode.len == 0) "ask" else input.mode,
        if (input.plan.len == 0) "off" else input.plan,
        packet_rel,
    });

    path_buf.deinit(allocator);
    return .{
        .id = id,
        .stub = try stub.toOwnedSlice(allocator),
        .packet = try packet.toOwnedSlice(allocator),
        .meta = try meta.toOwnedSlice(allocator),
        .rel_dir = rel_dir,
    };
}

pub fn writeRun(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    built: Built,
) !void {
    const full_dir = try std.fs.path.join(allocator, &.{ workspace, built.rel_dir });
    defer allocator.free(full_dir);
    Io.Dir.cwd().createDirPath(io, full_dir) catch |err| {
        log.warn("mkdir run: {s}", .{@errorName(err)});
        return err;
    };

    const pkt = try std.fs.path.join(allocator, &.{ full_dir, "checkpoint.md" });
    defer allocator.free(pkt);
    try writeFile(io, pkt, built.packet);

    const meta_p = try std.fs.path.join(allocator, &.{ full_dir, "meta.json" });
    defer allocator.free(meta_p);
    try writeFile(io, meta_p, built.meta);

    const active = try std.fs.path.join(allocator, &.{ workspace, active_rel });
    defer allocator.free(active);
    if (std.fs.path.dirname(active)) |d| {
        Io.Dir.cwd().createDirPath(io, d) catch {};
    }
    try writeFile(io, active, built.id);
}

fn writeFile(io: Io, path: []const u8, body: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

pub fn setStatus(allocator: std.mem.Allocator, io: Io, workspace: []const u8, id: []const u8, status: Status) !void {
    const meta_p = try std.fs.path.join(allocator, &.{ workspace, runs_dir, id, "meta.json" });
    defer allocator.free(meta_p);
    const raw = Io.Dir.cwd().readFileAlloc(io, meta_p, allocator, .limited(4_000)) catch return error.MissingRun;
    defer allocator.free(raw);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (std.mem.indexOf(u8, raw, "\"status\":\"")) |at| {
        const start = at + "\"status\":\"".len;
        const end = std.mem.indexOfScalarPos(u8, raw, start, '"') orelse raw.len;
        try out.appendSlice(allocator, raw[0..start]);
        try out.appendSlice(allocator, status.asSlice());
        try out.appendSlice(allocator, raw[end..]);
    } else {
        try out.appendSlice(allocator, raw);
    }
    try writeFile(io, meta_p, out.items);

    const pkt = try std.fs.path.join(allocator, &.{ workspace, runs_dir, id, "checkpoint.md" });
    defer allocator.free(pkt);
    const body = Io.Dir.cwd().readFileAlloc(io, pkt, allocator, .limited(32_000)) catch return;
    defer allocator.free(body);
    var rewritten: std.ArrayList(u8) = .empty;
    defer rewritten.deinit(allocator);
    var it = std.mem.splitScalar(u8, body, '\n');
    var i: usize = 0;
    var after_status_hdr = false;
    while (it.next()) |line| {
        if (i > 0) try rewritten.append(allocator, '\n');
        if (after_status_hdr) {
            try rewritten.appendSlice(allocator, status.asSlice());
            after_status_hdr = false;
        } else if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "## status")) {
            try rewritten.appendSlice(allocator, line);
            after_status_hdr = true;
        } else {
            try rewritten.appendSlice(allocator, line);
        }
        i += 1;
    }
    if (i > 0) try rewritten.append(allocator, '\n');
    try writeFile(io, pkt, rewritten.items);
}

pub fn loadActiveId(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ?[]u8 {
    const p = std.fs.path.join(allocator, &.{ workspace, active_rel }) catch return null;
    defer allocator.free(p);
    const raw = Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(64)) catch return null;
    const id = std.mem.trim(u8, raw, " \t\r\n");
    if (id.len == 0) {
        allocator.free(raw);
        return null;
    }
    const copy = allocator.dupe(u8, id) catch {
        allocator.free(raw);
        return null;
    };
    allocator.free(raw);
    return copy;
}

pub fn wakeStub(allocator: std.mem.Allocator, io: Io, workspace: []const u8, id: []const u8) ![]u8 {
    const pkt = try std.fs.path.join(allocator, &.{ workspace, runs_dir, id, "checkpoint.md" });
    defer allocator.free(pkt);
    _ = Io.Dir.cwd().openFile(io, pkt, .{ .mode = .read_only }) catch return error.MissingRun;

    const meta_p = try std.fs.path.join(allocator, &.{ workspace, runs_dir, id, "meta.json" });
    defer allocator.free(meta_p);
    const meta = Io.Dir.cwd().readFileAlloc(io, meta_p, allocator, .limited(4_000)) catch "";
    defer if (meta.len > 0) allocator.free(meta);

    const goal = jsonStr(meta, "goal") orelse "(none)";
    const mode = jsonStr(meta, "mode") orelse "ask";
    const plan = jsonStr(meta, "plan") orelse "off";
    const packet = try std.fmt.allocPrint(allocator, "{s}/{s}/checkpoint.md", .{ runs_dir, id });
    defer allocator.free(packet);

    try setStatus(allocator, io, workspace, id, .ready);
    return std.fmt.allocPrint(allocator,
        \\WAKE run={s} status=ready
        \\goal={s}
        \\pinned: mode={s} plan={s}
        \\packet: {s}
        \\Do not replay prior turns. Use read on the packet or recall cites only if needed; continue with the usual tools. Honor pinned plan=on (read-only until /plan go) and any active /spec pointer.
        \\
    , .{ id, goal, mode, plan, packet });
}

fn jsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}

pub fn list(allocator: std.mem.Allocator, io: Io, workspace: []const u8) ![]u8 {
    const root = try std.fs.path.join(allocator, &.{ workspace, runs_dir });
    defer allocator.free(root);
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        return allocator.dupe(u8, "No runs yet. /checkpoint or /sleep.\n");
    };
    defer dir.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        const meta_p = try std.fs.path.join(allocator, &.{ root, entry.name, "meta.json" });
        defer allocator.free(meta_p);
        const meta = Io.Dir.cwd().readFileAlloc(io, meta_p, allocator, .limited(2_000)) catch "";
        defer if (meta.len > 0) allocator.free(meta);
        const st = jsonStr(meta, "status") orelse "?";
        const goal = jsonStr(meta, "goal") orelse "";
        try out.print(allocator, "{s}  {s}  {s}\n", .{ entry.name, st, goal });
        n += 1;
    }
    if (n == 0) return allocator.dupe(u8, "No runs yet. /checkpoint or /sleep.\n");
    return out.toOwnedSlice(allocator);
}

test "build stub has no last_reply dump" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const built = try build(a, io, "/tmp", .sleeping, .{
        .goal = "ship checkpoint",
        .note = "park",
        .last_tool = "write",
        .last_reply = "SECRET_SHOULD_NOT_APPEAR " ** 20,
        .mode = "ask",
        .plan = "off",
    });
    defer a.free(built.id);
    defer a.free(built.stub);
    defer a.free(built.packet);
    defer a.free(built.meta);
    defer a.free(built.rel_dir);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "SECRET_SHOULD_NOT_APPEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, built.packet, "SECRET_SHOULD_NOT_APPEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, built.stub, "WAKE run=") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.packet, "## pinned") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.meta, "\"status\":\"sleeping\"") != null);
}
