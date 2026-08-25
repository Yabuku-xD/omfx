const std = @import("std");
const Io = std.Io;
const config = @import("../config.zig");
const permissions = @import("../permissions.zig");
const prompt = @import("../prompt.zig");
const skills = @import("../skills.zig");
const compact = @import("../compact.zig");
const context = @import("../context.zig");
const env = @import("../env.zig");
const peer_router = @import("../peer_router.zig");
const board = @import("../board.zig");
const ssvp = @import("../ssvp.zig");
const spec_mod = @import("../spec.zig");
const playbook = @import("../playbook.zig");
const contract_mod = @import("../contract.zig");
const types = @import("../../providers/types.zig");
const pclient = @import("../../providers/client.zig");
const memory_mod = @import("../../tools/memory.zig");
const repomap = @import("../repomap.zig");
const sink = @import("../sink.zig");
const pathing = @import("../../tools/pathing.zig");
const todos = @import("../todos.zig");

pub const max_read_paths: usize = 64;

/// What a stopped turn leaves in the transcript. Named so the CLI can style it
/// rather than string-matching a sentence.
pub const interrupted_text = "Interrupted by user.\n";

pub fn stripPath(path: []const u8) []const u8 {
    var p = path;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return p;
}

pub const Guard = struct {
    allocator: std.mem.Allocator,
    paths: [max_read_paths][]u8 = undefined,
    n: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Guard {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Guard) void {
        for (self.paths[0..self.n]) |p| self.allocator.free(p);
        self.n = 0;
    }

    pub fn record(self: *Guard, path: []const u8) void {
        const k = stripPath(path);
        if (k.len == 0) return;
        if (self.contains(k)) return;
        if (self.n >= max_read_paths) return;
        self.paths[self.n] = self.allocator.dupe(u8, k) catch return;
        self.n += 1;
    }

    pub fn contains(self: Guard, path: []const u8) bool {
        const k = stripPath(path);
        for (self.paths[0..self.n]) |p| {
            if (std.mem.eql(u8, p, k)) return true;
        }
        return false;
    }

    pub fn mayEdit(self: Guard, path: []const u8) bool {
        return self.contains(path);
    }

    pub fn blockMessage(allocator: std.mem.Allocator, tool_s: []const u8, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "blocked: {s} without read\nhonesty: not a clean {s}\nRead the file first, then retry: read path=\"{s}\"\n",
            .{ tool_s, tool_s, stripPath(path) },
        );
    }
};

pub const Reads = struct {
    guard: Guard,

    pub fn init(allocator: std.mem.Allocator) Reads {
        return .{ .guard = .init(allocator) };
    }

    pub fn deinit(self: *Reads) void {
        self.guard.deinit();
    }
};

pub const max_peer_depth: u8 = 1;
pub const max_peer_depth_cap: u8 = 8;

pub const Verify = enum { none, clean, fail, unavailable };

pub const Trace = struct {
    const tool_cap: usize = 24;

    tool: [tool_cap]u8 = [_]u8{0} ** tool_cap,
    tool_len: usize = 0,
    args_tag: u32 = 0,
    verify: Verify = .none,
    denied: bool = false,
    tools: u16 = 0,
    sys_bytes: u32 = 0,
    tools_bytes: u32 = 0,

    pub fn setTool(self: *Trace, name: []const u8, args: []const u8) void {
        self.tools +|= 1;
        const n = @min(name.len, self.tool.len);
        @memcpy(self.tool[0..n], name[0..n]);
        self.tool_len = n;
        self.args_tag = @as(u32, @truncate(std.hash.Wyhash.hash(0, args)));
    }

    pub fn toolName(self: *const Trace) []const u8 {
        return self.tool[0..self.tool_len];
    }
};

pub const Plan = enum {
    off,
    on,

    pub fn asSlice(self: Plan) []const u8 {
        return switch (self) {
            .off => "off",
            .on => "on",
        };
    }
};

pub const Run = struct {
    mode: config.PermissionMode,
    mode_live: ?*config.PermissionMode = null,
    has_tty: bool,
    home: []const u8,
    reads: *Reads,
    depth: u8 = 0,
    trace: ?*Trace = null,
    plan: Plan = .off,
    host: sink.Host = .{},
    max_peer_depth: u8 = max_peer_depth,
    prior_user: []const u8 = "",
    prior_assistant: []const u8 = "",
    lookup: env.Lookup = env.emptyLookup(),
    auth_json: []const u8 = "",
    session_rules: []const permissions.Rule = &.{},
    failures: usize = 0,
    path_access: pathing.Access = .{ .workspace = "" },
    tasks: ?*todos.List = null,
};

/// HTTP failures collapse here. A peer re-enters `chatOnce` from `chatTurn`, so
/// this set is named rather than inferred.
pub const ChatError = error{ OutOfMemory, Transport };

/// Prior user+assistant first so a follow-up like "continue" attaches to the
/// interrupted turn instead of looking like a new repo task.
pub fn seedThread(
    allocator: std.mem.Allocator,
    prior_user: []const u8,
    prior_assistant: []const u8,
    user: []const u8,
    images: []const types.Image,
) !std.ArrayList(pclient.Message) {
    var thread: std.ArrayList(pclient.Message) = .empty;
    errdefer {
        for (thread.items) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        thread.deinit(allocator);
    }
    if (prior_user.len != 0) {
        try thread.append(allocator, .{
            .role = try allocator.dupe(u8, "user"),
            .content = try allocator.dupe(u8, prior_user),
        });
        const asst = if (prior_assistant.len != 0) prior_assistant else interrupted_text;
        try thread.append(allocator, .{
            .role = try allocator.dupe(u8, "assistant"),
            .content = try allocator.dupe(u8, asst),
        });
    }
    try thread.append(allocator, .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, user),
        .images = images,
    });
    return thread;
}

/// What the workspace looks like right now: the git status and the repo map.
pub fn workspaceState(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    workspace: []const u8,
    query: []const u8,
    depth: context.OrientDepth,
) ![]u8 {
    if (depth == .none) return allocator.dupe(u8, "");

    const git_block = try context.gitSnapshot(allocator, io, workspace);
    defer allocator.free(git_block);

    if (depth == .git) {
        if (git_block.len == 0) return allocator.dupe(u8, "");
        return std.fmt.allocPrint(allocator, "git:\n{s}", .{git_block});
    }

    const map_block = try repomap.buildFor(allocator, dir, io, query);
    defer allocator.free(map_block);
    if (git_block.len == 0 and map_block.len == 0) return allocator.dupe(u8, "");
    if (git_block.len == 0) return allocator.dupe(u8, map_block);
    return std.fmt.allocPrint(allocator, "git:\n{s}{s}", .{ git_block, map_block });
}

pub fn assembleSystem(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    workspace: []const u8,
    home: []const u8,
    allow_peer: bool,
    plan: bool,
    lookup: env.Lookup,
    auth_json: []const u8,
    main: types.Endpoint,
) ![]u8 {
    const names = try skills.listAllNames(allocator, io, dir, home, workspace);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    const skill_names = try skills.promptBlock(allocator, names);
    defer allocator.free(skill_names);
    const play_cat = try playbook.catalog(allocator, io, workspace);
    defer allocator.free(play_cat);
    const mem_block = try memory_mod.promptBlock(allocator, io, home, dir);
    defer allocator.free(mem_block);
    const peer_block = try peer_router.promptBlock(allocator, lookup, auth_json, main);
    defer allocator.free(peer_block);
    const skill_block = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ skill_names, play_cat, mem_block, peer_block });
    defer allocator.free(skill_block);

    var con = try contract_mod.load(allocator, dir, io, home);
    defer con.deinit(allocator);
    const agents_block = try con.promptBlock(allocator);
    defer allocator.free(agents_block);
    const sys_base = try prompt.withFlags(allocator, skill_block, agents_block, "", allow_peer);
    defer allocator.free(sys_base);
    const board_tail = board.loadTail(allocator, io, workspace);
    defer if (board_tail.len > 0) allocator.free(board_tail);
    const last_summary = try ssvp.summary(allocator, board_tail);
    defer allocator.free(last_summary);
    const sys_mid = if (last_summary.len == 0)
        try allocator.dupe(u8, sys_base)
    else
        try std.fmt.allocPrint(allocator, "{s}Board gist (board read for more; FACT needs path=):\n{s}\n", .{ sys_base, last_summary });
    defer allocator.free(sys_mid);
    const spec_line = try spec_mod.orientationLine(allocator, io, workspace);
    defer if (spec_line.len > 0) allocator.free(spec_line);
    const sys_spec = if (spec_line.len == 0)
        try allocator.dupe(u8, sys_mid)
    else
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ sys_mid, spec_line, prompt.spec_text });
    defer allocator.free(sys_spec);
    if (plan) return std.fmt.allocPrint(allocator, "{s}{s}", .{ sys_spec, prompt.plan_text });
    return allocator.dupe(u8, sys_spec);
}

pub fn exploreBlock(allocator: std.mem.Allocator, tool: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "blocked: {s} before explore\nhonesty: not a clean {s}\nCall list, grep, glob, or read first.\n",
        .{ tool, tool },
    );
}

pub fn fileExists(dir: Io.Dir, io: Io, allocator: std.mem.Allocator, rel: []const u8) bool {
    const body = dir.readFileAlloc(io, rel, allocator, .limited(1)) catch return false;
    allocator.free(body);
    return true;
}

pub fn compactThread(allocator: std.mem.Allocator, thread: *std.ArrayList(pclient.Message)) !compact.Applied {
    var turns: std.ArrayList(compact.Turn) = .empty;
    defer turns.deinit(allocator);
    for (thread.items) |m| {
        try turns.append(allocator, .{ .role = m.role, .text = m.content });
    }
    const stitched = try compact.stitch(allocator, turns.items);
    defer stitched.deinit(allocator);
    const new_turns = switch (stitched) {
        .copy => return .skipped,
        .compacted => |c| c.turns,
    };

    var next: std.ArrayList(pclient.Message) = .empty;
    errdefer {
        for (next.items) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        next.deinit(allocator);
    }
    for (new_turns) |t| {
        try next.append(allocator, .{
            .role = try allocator.dupe(u8, t.role),
            .content = try allocator.dupe(u8, t.text),
        });
    }
    for (thread.items) |m| {
        allocator.free(m.role);
        allocator.free(m.content);
    }
    thread.deinit(allocator);
    thread.* = next;
    return .applied;
}

pub fn recordVerify(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    trace: ?*Trace,
    verify: []const u8,
) void {
    const v: Verify = if (std.mem.indexOf(u8, verify, "verify: clean") != null)
        .clean
    else if (std.mem.indexOf(u8, verify, "verify: findings") != null)
        .fail
    else if (std.mem.indexOf(u8, verify, "verify: unavailable") != null or std.mem.indexOf(u8, verify, "verify: timeout") != null)
        .unavailable
    else
        .none;
    if (trace) |t| t.verify = v;
    switch (v) {
        .fail => playbook.noteHarmful(allocator, io, workspace, "verify fail"),
        .clean => {
            const tail = board.loadTail(allocator, io, workspace);
            defer if (tail.len > 0) allocator.free(tail);
            var notes: [board.max_notes]board.Note = undefined;
            const n = board.parseAll(tail, &notes);
            if (n == 0) {
                if (trace) |t| {
                    if (t.toolName().len > 0) {
                        var line_buf: [playbook.text_max]u8 = undefined;
                        const line = std.fmt.bufPrint(
                            &line_buf,
                            "verified {s}",
                            .{t.toolName()},
                        ) catch t.toolName();
                        playbook.noteVerified(allocator, io, workspace, line);
                    }
                }
                return;
            }
            const start = if (n > 3) n - 3 else 0;
            for (notes[start..n]) |note| {
                const tag = switch (note.kind) {
                    .fact => "fact",
                    .fail => "fail",
                    .path => "path",
                };
                var line_buf: [playbook.text_max]u8 = undefined;
                const line = if (note.path.len > 0)
                    std.fmt.bufPrint(&line_buf, "{s} {s}", .{ tag, note.path }) catch note.path
                else
                    std.fmt.bufPrint(&line_buf, "{s} {s}", .{ tag, note.text }) catch tag;
                playbook.noteVerified(allocator, io, workspace, line);
            }
        },
        .none, .unavailable => {},
    }
}

test "seedThread keeps an interrupted turn in front of the follow-up" {
    const a = std.testing.allocator;
    var thread = try seedThread(a, "what are u good at", "I'm omfx", "continue", &.{});
    defer {
        for (thread.items) |m| {
            a.free(m.role);
            a.free(m.content);
        }
        thread.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), thread.items.len);
    try std.testing.expectEqualStrings("user", thread.items[0].role);
    try std.testing.expectEqualStrings("what are u good at", thread.items[0].content);
    try std.testing.expectEqualStrings("assistant", thread.items[1].role);
    try std.testing.expectEqualStrings("I'm omfx", thread.items[1].content);
    try std.testing.expectEqualStrings("user", thread.items[2].role);
    try std.testing.expectEqualStrings("continue", thread.items[2].content);
}

test "seedThread uses interrupted_text when the partial reply is empty" {
    const a = std.testing.allocator;
    var thread = try seedThread(a, "what are u good at", "", "continue", &.{});
    defer {
        for (thread.items) |m| {
            a.free(m.role);
            a.free(m.content);
        }
        thread.deinit(a);
    }
    try std.testing.expectEqualStrings(interrupted_text, thread.items[1].content);
}

test "seedThread without a prior turn is just the new user line" {
    const a = std.testing.allocator;
    var thread = try seedThread(a, "", "", "yo", &.{});
    defer {
        for (thread.items) |m| {
            a.free(m.role);
            a.free(m.content);
        }
        thread.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), thread.items.len);
    try std.testing.expectEqualStrings("yo", thread.items[0].content);
}

test "bench: assembleSystem size in empty workspace" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var f = try tmp.dir.createFile(io, "AGENTS.md", .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("no subagents\n");
        try w.interface.flush();
    }
    const main = types.Endpoint{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "test-model",
    };
    const sys = try assembleSystem(a, io, tmp.dir, "/no-such-omfx-git-workspace", "/tmp", true, false, env.emptyLookup(), "", main);
    defer a.free(sys);
    const sys_plan = try assembleSystem(a, io, tmp.dir, "/no-such-omfx-git-workspace", "/tmp", true, true, env.emptyLookup(), "", main);
    defer a.free(sys_plan);
    std.debug.print(
        "BENCH assemble_sys_bytes={d} assemble_plan_bytes={d} has_postcard={d} has_agents={d}\n",
        .{
            sys.len,
            sys_plan.len,
            @intFromBool(std.mem.indexOf(u8, sys, "You are omfx") != null),
            @intFromBool(std.mem.indexOf(u8, sys, "no subagents") != null),
        },
    );
    try std.testing.expect(sys.len > prompt.text.len);
    try std.testing.expect(sys_plan.len > sys.len);
}

test "explore block names the tool" {
    const s = try exploreBlock(std.testing.allocator, "write");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "before explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean write") != null);
}

test "edit blocked until read" {
    var g = Guard.init(std.testing.allocator);
    defer g.deinit();
    try std.testing.expect(!g.mayEdit("src/a.zig"));
    g.record("src/a.zig");
    try std.testing.expect(g.mayEdit("src/a.zig"));
    try std.testing.expect(g.mayEdit("./src/a.zig"));
}

test "block message names the path" {
    const s = try Guard.blockMessage(std.testing.allocator, "edit", "./foo.zig");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean") != null);
}

test "the system prompt does not move when the workspace does" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const main = types.Endpoint{
        .vendor = .openai,
        .base_url = "",
        .api_key = "",
        .model = "test-model",
    };
    const before = try assembleSystem(a, io, tmp.dir, "/no-such-omfx-git-workspace", "/tmp", true, false, env.emptyLookup(), "", main);
    defer a.free(before);

    var f = try tmp.dir.createFile(io, "new.zig", .{ .truncate = true });
    var buf: [64]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll("pub fn appeared() void {}\n");
    try w.interface.flush();
    f.close(io);

    const after = try assembleSystem(a, io, tmp.dir, "/no-such-omfx-git-workspace", "/tmp", true, false, env.emptyLookup(), "", main);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "the workspace map still reaches the model, at the head of the turn" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "svc.zig", .{ .truncate = true });
    var buf: [64]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll("pub fn startServer() void {}\n");
    try w.interface.flush();
    f.close(io);

    const state = try workspaceState(a, io, tmp.dir, "/no-such-omfx-git-workspace", "startServer", .full);
    defer a.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "svc.zig") != null);
}

test "a clean verify records a playbook entry without a board" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try pathing.testWorkspace(a, &tmp);
    defer a.free(ws);

    var trace = Trace{};
    trace.setTool("edit", "{}");
    recordVerify(a, io, ws, &trace, "verify: clean (zig build test, exit 0)\n");

    const p = try playbook.path(a, ws);
    defer a.free(p);
    const body = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64_000));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "verified edit") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "helpful") != null);
}

test "a failed verify still records a harmful entry" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try pathing.testWorkspace(a, &tmp);
    defer a.free(ws);

    var trace = Trace{};
    trace.setTool("edit", "{}");
    recordVerify(a, io, ws, &trace, "verify: findings (zig build test, exit 1)\n");

    const path = try playbook.path(a, ws);
    defer a.free(path);
    const body = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64_000));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "verify fail") != null);
}
