const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const permissions = @import("permissions.zig");
const prompt = @import("prompt.zig");
const skills = @import("skills.zig");
const compact = @import("compact.zig");
const context = @import("context.zig");
const settings = @import("settings.zig");
const env = @import("env.zig");
const peer_router = @import("peer_router.zig");
const peer_policy = @import("peer_policy.zig");
const board = @import("board.zig");
const pathing = @import("../tools/pathing.zig");
const ssvp = @import("ssvp.zig");
const spec_mod = @import("spec.zig");
const playbook = @import("playbook.zig");
const vision = @import("vision.zig");
const contract_mod = @import("contract.zig");
const hooks = @import("hooks.zig");
const types = @import("../providers/types.zig");
const pclient = @import("../providers/client.zig");
const dispatch = @import("../tools/dispatch.zig");
const diag = @import("../tools/diag.zig");
const gate = @import("../tools/gate.zig");
const undo = @import("../tools/undo.zig");
const sse = @import("../providers/sse.zig");
const Tool = @import("tool.zig");
const recall = @import("recall.zig");
const trim = @import("trim.zig");
const memory_mod = @import("../tools/memory.zig");
const isolate = @import("../tools/isolate.zig");
const sink = @import("sink.zig");
const repomap = @import("repomap.zig");

pub const max_read_paths: usize = 64;

/// What a stopped turn leaves in the transcript. Named so the CLI can style it
/// rather than string-matching a sentence.
pub const interrupted_text = "Interrupted by user.\n";

/// Printed the moment a stop is requested, because the request itself cannot be
/// torn down until the provider sends its first byte. Without it a long
/// reasoning pause makes the key look dead.
const stopping_ack = "\r\x1b[K\x1b[2m" ++ sink.stopping_phrase ++ "\x1b[0m\r\n";

/// A turn the user stopped surfaces as a torn-down read. That is the intended
/// outcome, not a failure, so it must not be reported as one.
fn postOrStop(
    allocator: std.mem.Allocator,
    io: Io,
    endpoint: types.Endpoint,
    messages: []const pclient.Message,
    sys: []const u8,
    flags: pclient.ChatFlags,
) !?pclient.ChatResult {
    // The main thread is about to block on the socket, where `pollCancel` can
    // never run. The watcher owns the keyboard until the response returns.
    var watch = sink.Watch{
        .cancel = flags.host.cancel orelse return blk: {
            break :blk pclient.postChatFiltered(allocator, io, endpoint, messages, sys, flags) catch |err| {
                if (flags.host.cancelled()) return null;
                return err;
            };
        },
        .ack = if (flags.host.on_tick != null) "" else stopping_ack,
        .tick = flags.host.on_tick,
        .tick_ctx = flags.host.ctx,
    };
    watch.start();
    defer watch.finish();
    return pclient.postChatFiltered(allocator, io, endpoint, messages, sys, flags) catch |err| {
        if (flags.host.cancelled()) return null;
        return err;
    };
}

const detail_keys = [_][]const u8{ "path", "command", "pattern", "query", "url", "name", "goal", "question", "id" };

/// What to show next to the verb. Tools name their subject differently, so try
/// each key rather than leaving grep/glob/web cards with a bare verb.
fn toolDetail(buf: []u8, args: []const u8) []const u8 {
    for (detail_keys) |key| {
        const s = sse.argStringInto(buf, args, key) orelse continue;
        if (s.len > 0) return s;
    }
    return "";
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

pub fn stripPath(path: []const u8) []const u8 {
    var p = path;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return p;
}

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
    /// Tool calls this turn made. One number per turn is what makes a run log
    /// comparable to the one before it.
    tools: u16 = 0,
    /// Bytes the system prompt and the advertised tool schemas took on the
    /// wire. Every turn resends both, so they are a fixed floor under the
    /// context window and the first thing worth seeing when it fills.
    sys_bytes: u32 = 0,
    tools_bytes: u32 = 0,

    pub fn setTool(self: *Trace, name: []const u8, args: []const u8) void {
        self.tools +|= 1;
        const n = @min(name.len, self.tool.len);
        @memcpy(self.tool[0..n], name[0..n]);
        self.tool_len = n;
        self.args_tag = @as(u32, @truncate(std.hash.Wyhash.hash(0, args)));
    }

    /// Borrowed from the trace, so `self` is a pointer: taking it by value
    /// returns a slice into the parameter copy, which dies at the return and
    /// leaves every caller reading whatever the stack holds next.
    pub fn toolName(self: *const Trace) []const u8 {
        return self.tool[0..self.tool_len];
    }
};

pub const Reflect = union(enum) {
    task,
    pushback: []const u8,
};

pub const reflect_sys =
    \\Reply with one line: PUSHBACK <lesson> or TASK.
    \\PUSHBACK means the user is rejecting the last action. The lesson is what not to repeat.
    \\TASK means a new or continued request. No other words.
;

fn clip80(s: []const u8) []const u8 {
    return if (s.len <= 80) s else s[0..80];
}

/// Lesson slice into `body`. Junk and TASK are `.task` (fail open).
pub fn parseReflect(body: []const u8) Reflect {
    const t = std.mem.trim(u8, body, " \t\r\n");
    if (t.len == 0) return .task;
    if (t.len >= 4 and std.ascii.eqlIgnoreCase(t[0..4], "task")) return .task;
    if (t.len < 8 or !std.ascii.eqlIgnoreCase(t[0..8], "pushback")) return .task;
    var i: usize = 8;
    if (i < t.len and (t[i] == ':' or t[i] == ' ')) i += 1;
    while (i < t.len and t[i] == ' ') i += 1;
    const lesson = std.mem.trim(u8, t[i..], " \t\r\n");
    return .{ .pushback = lesson };
}

/// Tiny no-tool call. Returns an owned lesson or null. Never blocks the turn on failure.
pub fn reflectFollowup(
    allocator: std.mem.Allocator,
    io: Io,
    endpoint: types.Endpoint,
    last_goal: []const u8,
    last_tool: []const u8,
    now: []const u8,
) !?[]u8 {
    const user = try std.fmt.allocPrint(
        allocator,
        "last={s}\ntool={s}\nnow={s}",
        .{ clip80(last_goal), clip80(last_tool), clip80(now) },
    );
    defer allocator.free(user);
    var ep = endpoint;
    ep.effort = "none";
    const msgs = [_]pclient.Message{.{ .role = "user", .content = user }};
    var out = pclient.postChatFiltered(allocator, io, ep, &msgs, reflect_sys, .{ .tools = false, .allow_peer = false }) catch return null;
    defer out.deinit(allocator);
    return switch (parseReflect(out.textSlice())) {
        .task => null,
        .pushback => |lesson| try allocator.dupe(u8, clip80(if (lesson.len == 0) now else lesson)),
    };
}

pub fn peerTask(allocator: std.mem.Allocator, goal: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Peer task: {s}\nSame tools as the main agent. Talk through board (FACT/FAIL/PATH). Do not spawn peer.",
        .{goal},
    );
}

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
    /// When set, each admit re-reads this so Shift+Tab mid-turn applies to
    /// later tool calls; in-flight work keeps the mode it was admitted under.
    mode_live: ?*config.PermissionMode = null,
    has_tty: bool,
    home: []const u8,
    reads: *Reads,
    depth: u8 = 0,
    trace: ?*Trace = null,
    plan: Plan = .off,
    host: sink.Host = .{},
    max_peer_depth: u8 = max_peer_depth,
    /// Interrupted turn still in play: the next follow-up attaches to this, not a fresh task.
    prior_user: []const u8 = "",
    prior_assistant: []const u8 = "",
    lookup: env.Lookup = env.emptyLookup(),
    auth_json: []const u8 = "",
    /// Ephemeral shrink-only rules; never injected into the system prompt.
    session_rules: []const permissions.Rule = &.{},
    /// Consecutive unclean turns; same counter autoeffort uses for Hard.
    failures: usize = 0,
};

fn liveMode(run: Run) config.PermissionMode {
    return if (run.mode_live) |p| p.* else run.mode;
}

/// HTTP failures collapse here. A peer re-enters `chatOnce` from `chatTurn`, so
/// this set is named rather than inferred.
pub const ChatError = error{ OutOfMemory, Transport };

/// Prior user+assistant first so a follow-up like "continue" attaches to the
/// interrupted turn instead of looking like a new repo task.
fn seedThread(
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
///
/// Deliberately not part of the system prompt. Both change the moment the
/// model edits a file, and a provider caches by exact prefix -- putting them
/// in front of the conversation means every turn after the first write
/// reprocesses the entire request. They ride at the head of the user message
/// instead, where they are the newest bytes rather than the oldest, and the
/// system prompt stays byte-identical for the life of the session.
///
/// Depth is lexical: greetings skip orientation; full map only when the ask
/// needs the tree (Adaptive-RAG A/B/C — see `orient.zig`).
fn workspaceState(
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

    // Personalize toward this turn's tokens; still capped at 4k chars.
    const map_block = try repomap.buildFor(allocator, dir, io, query);
    defer allocator.free(map_block);
    if (git_block.len == 0 and map_block.len == 0) return allocator.dupe(u8, "");
    if (git_block.len == 0) return allocator.dupe(u8, map_block);
    return std.fmt.allocPrint(allocator, "git:\n{s}{s}", .{ git_block, map_block });
}

/// Runs one turn and returns the reply, owned by `allocator`.
///
/// Everything a turn allocates dies with the turn, so the turn gets an arena
/// and the body stops hand-writing lifetimes. The ceiling is set by caps that
/// already exist: `max_tool_turns` (24) results of at most `result_budget`
/// (12_000 bytes) each, plus a thread bounded by `char_budget` (48_000) -- under
/// a megabyte in the worst case, against nineteen defers and the whole class of
/// use-after-free that comes with them.
pub fn chatOnce(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    workspace: []const u8,
    endpoint: types.Endpoint,
    user: []const u8,
    run: Run,
) ChatError![]u8 {
    var turn = std.heap.ArenaAllocator.init(allocator);
    defer turn.deinit();
    const reply = chatTurn(turn.allocator(), io, dir, workspace, endpoint, user, run) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Transport,
    };
    // The reply outlives the turn, so it is the one thing copied back out.
    return allocator.dupe(u8, reply);
}

fn chatTurn(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    workspace: []const u8,
    endpoint: types.Endpoint,
    user: []const u8,
    run: Run,
) ![]u8 {
    const has_tty = run.has_tty;
    const home = run.home;
    const reads = run.reads;
    const depth = run.depth;
    const trace = run.trace;
    const plan = run.plan == .on;
    var cfg = settings.load(allocator, io, home);
    defer cfg.deinit(allocator);
    const host = run.host;
    const depth_cap: u8 = if (run.max_peer_depth == 0) 1 else @min(run.max_peer_depth, max_peer_depth_cap);
    const peer_denied = (permissions.matchLast(cfg.rules, "peer", "{}") orelse .allow) == .deny;
    var always: [8][]const u8 = undefined;
    var always_n: usize = 0;
    // Prior tool bodies for "copied from untrusted output" checks. Capped so a
    // long turn cannot unbounded-grow the ring.
    var tool_blob: std.ArrayList(u8) = .empty;
    defer tool_blob.deinit(allocator);
    const tool_blob_cap: usize = 64 * 1024;
    var con = try contract_mod.load(allocator, dir, io, home);
    defer con.deinit(allocator);
    const board_tail0 = board.loadTail(allocator, io, workspace);
    var last_summary = try ssvp.summary(allocator, board_tail0);
    const base_allow_peer = depth == 0 and settings.peerAutoOn(cfg) and !peer_denied;
    const allow_peer = base_allow_peer and peer_policy.allow(.{
        .prompt = user,
        .prior_user = run.prior_user,
        .prior_assistant = run.prior_assistant,
        .board_summary = last_summary,
        .plan = plan,
    });
    const sys = try assembleSystem(allocator, io, dir, workspace, home, allow_peer, plan, run.lookup, run.auth_json, endpoint);
    if (trace) |t| {
        t.sys_bytes = @intCast(@min(sys.len, std.math.maxInt(u32)));
        t.tools_bytes = @intCast(@min(pclient.advertisedBytes(endpoint), std.math.maxInt(u32)));
    }

    const state_block = try workspaceState(
        allocator,
        io,
        dir,
        workspace,
        user,
        context.orientDepth(user, run.failures, plan),
    );
    defer allocator.free(state_block);
    const user_with_state = if (state_block.len == 0)
        try allocator.dupe(u8, user)
    else
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ state_block, user });
    defer allocator.free(user_with_state);

    var thread = try seedThread(
        allocator,
        run.prior_user,
        run.prior_assistant,
        user_with_state,
        try vision.attach(allocator, dir, io, workspace, user),
    );

    // One key per workspace, stable across turns and across restarts, so a
    // resumed session reads the cache the previous one wrote.
    var key_buf: [40]u8 = undefined;
    const cache_key = std.fmt.bufPrint(&key_buf, "omfx-{x}", .{
        std.hash.Wyhash.hash(0, workspace),
    }) catch "omfx";
    const flags = pclient.ChatFlags{
        .allow_peer = allow_peer,
        .host = host.stream(),
        .cache_key = cache_key,
        .telemetry = settings.telemetryOn(cfg),
    };
    var last = (try postOrStop(allocator, io, endpoint, thread.items, sys, flags)) orelse
        return allocator.dupe(u8, interrupted_text);
    var turns: usize = 0;
    var explored = false;
    var prev_name: []u8 = try allocator.dupe(u8, "");
    var prev_args: []u8 = try allocator.dupe(u8, "");
    var same: usize = 0;
    var malformed: usize = 0;
    while (true) {
        // A tool boundary is the other place a turn can pause; the SSE reader
        // covers the streaming half.
        host.pollCancel();
        host.pollModeCycle();
        if (host.cancelled()) {
            last.deinit(allocator);
            return allocator.dupe(u8, interrupted_text);
        }
        const call = switch (last.outcome) {
            .text => |body| {
                const out = try ensureNl(allocator, body);
                last.deinit(allocator);
                return out;
            },
            .tool => |t| t,
        };
        // A tool the harness does not have can only be echoed back as an error,
        // so a model inventing names trades turns without doing any work. The
        // doom-loop counter misses it: each invented name differs from the last.
        if (Tool.Name.fromSlice(call.name) == null) {
            malformed += 1;
            if (malformed >= max_malformed) {
                const said = if (call.preamble.len != 0) call.preamble else malformed_text;
                const out = try ensureNl(allocator, said);
                last.deinit(allocator);
                return out;
            }
        } else {
            malformed = 0;
        }
        const extras = last.extra;
        last.extra = &.{};
        if (plan and permissions.blockedByPlan(call.name, call.args)) {
            if (trace) |t| {
                t.denied = true;
                t.setTool(call.name, call.args);
            }
            last.deinit(allocator);
            return std.fmt.allocPrint(allocator, "plan mode: {s} blocked. /plan go to implement.\n", .{call.name});
        }
        const mode = liveMode(run);
        var decision = admitCall(mode, call.name, call.args, has_tty, cfg.rules, run.session_rules, always[0..always_n]);
        // Commands copied out of tool output stay blocked unless the user asked.
        if (decision == .allow or decision == .prompt) {
            var cmd_buf: [permissions.max_command]u8 = undefined;
            const cmd = permissions.shellCommand(&cmd_buf, call.args) orelse
                sse.argStringInto(&cmd_buf, call.args, "path") orelse "";
            if (permissions.derivedFromToolOutput(cmd, user, tool_blob.items)) {
                decision = if (has_tty) .prompt else .deny;
            }
        }
        var one_shot: ?[]u8 = null;
        if (decision == .prompt) {
            var detail_buf: [permissions.max_command]u8 = undefined;
            const detail0 = toolDetail(&detail_buf, call.args);
            const ans = if (host.decide(call.name, detail0)) |a| a else if (permissions.askHuman(io, call.name)) sink.Ask.allow else sink.Ask.deny;
            switch (ans) {
                .allow => {
                    // One-shot allow: exact action only, re-checked before run.
                    decision = .allow;
                    one_shot = try permissions.exactKey(allocator, call.name, call.args);
                },
                .always => {
                    decision = .allow;
                    if (always_n < always.len) {
                        always[always_n] = try permissions.exactKey(allocator, call.name, call.args);
                        always_n += 1;
                    }
                    one_shot = try permissions.exactKey(allocator, call.name, call.args);
                },
                .deny => decision = .deny,
            }
        }
        defer if (one_shot) |k| allocator.free(k);
        switch (decision) {
            .allow => {},
            .prompt => {},
            .need_tty, .deny => {
                if (trace) |t| {
                    t.denied = true;
                    t.setTool(call.name, call.args);
                }
                var deny_buf: [48]u8 = undefined;
                const deny_line = std.fmt.bufPrint(&deny_buf, "denied {s}", .{call.name}) catch "denied tool";
                playbook.noteHarmful(allocator, io, workspace, deny_line);
                var deny_detail_buf: [permissions.max_command]u8 = undefined;
                const deny_detail = toolDetail(&deny_detail_buf, call.args);
                const deny_body = if (deny_detail.len != 0)
                    try std.fmt.allocPrint(allocator, "permission denied: {s}\n", .{deny_detail})
                else
                    try allocator.dupe(u8, "permission denied\n");
                defer allocator.free(deny_body);
                host.toolOut(call.name, deny_detail, true, deny_body);
                last.deinit(allocator);
                return try allocator.dupe(u8, deny_body);
            },
        }
        const asst_text = try allocator.dupe(u8, call.preamble);
        const tool_name = try allocator.dupe(u8, call.name);
        var start_activity_buf: [120]u8 = undefined;
        const activity_label = sse.argStringInto(&start_activity_buf, call.args, "activity") orelse
            sse.argStringInto(&start_activity_buf, call.args, "description") orelse "";
        host.tool(call.name, activity_label, false);
        const tool_args = try allocator.dupe(u8, call.args);
        last.deinit(allocator);
        if (trace) |t| t.setTool(tool_name, tool_args);

        // Exact-action re-check: live mode may have changed; a human clear
        // covers only this frozen name+args. Prompt again if mode still wants it.
        host.pollModeCycle();
        const mode_run = liveMode(run);
        var recheck = admitCall(mode_run, tool_name, tool_args, has_tty, cfg.rules, run.session_rules, always[0..always_n]);
        if (one_shot) |k| {
            if (permissions.exactKeyHit(&.{k}, tool_name, tool_args)) recheck = .allow;
        }
        if (recheck == .prompt) {
            var detail_buf: [permissions.max_command]u8 = undefined;
            const detail0 = toolDetail(&detail_buf, tool_args);
            const ans = if (host.decide(tool_name, detail0)) |a| a else if (permissions.askHuman(io, tool_name)) sink.Ask.allow else sink.Ask.deny;
            recheck = if (ans == .deny) .deny else .allow;
        }
        if (recheck != .allow) {
            var deny_detail_buf: [permissions.max_command]u8 = undefined;
            const deny_detail = toolDetail(&deny_detail_buf, tool_args);
            const deny_body = if (deny_detail.len != 0)
                try std.fmt.allocPrint(allocator, "permission denied: {s}\n", .{deny_detail})
            else
                try allocator.dupe(u8, "permission denied\n");
            defer allocator.free(deny_body);
            host.toolOut(tool_name, deny_detail, true, deny_body);
            allocator.free(asst_text);
            allocator.free(tool_name);
            allocator.free(tool_args);
            return try allocator.dupe(u8, deny_body);
        }

        if (Tool.Name.fromSlice(tool_name)) |n| {
            if (n.isExplore()) explored = true;
        }
        // Re-posting an unchanged task list is the tool working as intended,
        // not a stuck model, so it must not feed the doom-loop counter.
        if (Tool.Name.fromSlice(tool_name) == .todo) {
            same = 0;
        } else {
            _ = bumpRepeat(&same, prev_name, prev_args, tool_name, tool_args);
        }
        if (!std.mem.eql(u8, prev_name, tool_name) or !std.mem.eql(u8, prev_args, tool_args)) {
            allocator.free(prev_name);
            allocator.free(prev_args);
            prev_name = try allocator.dupe(u8, tool_name);
            prev_args = try allocator.dupe(u8, tool_args);
        }

        const path = sse.argString(allocator, tool_args, "path");
        var result: []u8 = undefined;
        switch (hooks.pre(con, tool_name, tool_args)) {
            .deny => |blocked| {
                result = try allocator.dupe(u8, blocked);
            },
            .allow => switch (try executeAdmitted(.{
                .allocator = allocator,
                .io = io,
                .dir = dir,
                .workspace = workspace,
                .endpoint = endpoint,
                .home = home,
                .mode = mode_run,
                .has_tty = has_tty,
                .reads = reads,
                .depth = depth,
                .depth_cap = depth_cap,
                .allow_peer = allow_peer,
                .host = host,
                .trace = trace,
                .plan = run.plan,
                .cfg = cfg,
                .lookup = run.lookup,
                .auth_json = run.auth_json,
                .explored = explored,
                .same = same,
                .asst_text = asst_text,
                .tool_name = tool_name,
                .tool_args = tool_args,
                .path = path,
                .thread = &thread,
            })) {
                .stop => |msg| return msg,
                .result => |r| result = r,
            },
        }
        // Archive before mask: put() must see secrets to write the placeholder.
        const archive_src = try allocator.dupe(u8, result);
        defer allocator.free(archive_src);
        {
            const hooked = try hooks.post(allocator, io, workspace, dir, con, tool_name, path, result);
            allocator.free(result);
            result = hooked;
            if (Tool.Name.fromSlice(tool_name)) |n| {
                if (n.needsVerify()) {
                    recordVerify(allocator, io, workspace, trace, result);
                }
            }
        }
        if (tool_blob.items.len + result.len > tool_blob_cap) {
            const drop = tool_blob.items.len + result.len - tool_blob_cap;
            if (drop < tool_blob.items.len) {
                const keep = tool_blob.items[drop..];
                std.mem.copyForwards(u8, tool_blob.items[0..keep.len], keep);
                tool_blob.shrinkRetainingCapacity(keep.len);
            } else {
                tool_blob.clearRetainingCapacity();
            }
        }
        try tool_blob.appendSlice(allocator, result);
        var out_detail_buf: [permissions.max_command]u8 = undefined;
        const detail = blk: {
            const d = toolDetail(&out_detail_buf, tool_args);
            break :blk if (d.len != 0) d else path orelse "";
        };
        host.toolOut(tool_name, detail, true, result);
        for (extras) |ex| {
            host.pollCancel();
            host.pollModeCycle();
            if (host.cancelled()) break;
            var ex_detail_buf: [permissions.max_command]u8 = undefined;
            const ex_path = toolDetail(&ex_detail_buf, ex.args);
            host.tool(ex.name, ex_path, false);
            const d = admitCall(liveMode(run), ex.name, ex.args, has_tty, cfg.rules, run.session_rules, always[0..always_n]);
            if (d != .allow) {
                const deny_msg = if (ex_path.len != 0)
                    try std.fmt.allocPrint(allocator, "permission denied: {s}\n", .{ex_path})
                else
                    try allocator.dupe(u8, "permission denied\n");
                defer allocator.free(deny_msg);
                host.toolOut(ex.name, ex_path, true, deny_msg);
                continue;
            }
            const extra_res = dispatch.run(dir, io, allocator, workspace, ex.name, ex.args, home) catch |err|
                try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
            host.toolOut(ex.name, ex_path, true, extra_res);
            const joined = try std.fmt.allocPrint(allocator, "{s}\nTool {s} result:\n{s}", .{ result, ex.name, extra_res });
            allocator.free(result);
            allocator.free(extra_res);
            result = joined;
        }

        // A tool round with no prose gets no assistant turn at all.
        //
        // This used to append "[tool <name>]" as the assistant's entire
        // message. The model reads its own history, so a turn whose whole
        // content was a bracket tag taught it that bracket tags are a thing
        // to say -- and it started emitting "[tool list]" as prose. The tool
        // result below already names the tool, so the placeholder was telling
        // the model nothing it could not read one message later.
        if (asst_text.len != 0) {
            try thread.append(allocator, .{
                .role = try allocator.dupe(u8, "assistant"),
                .content = asst_text,
            });
        } else {
            allocator.free(asst_text);
        }

        const result_nl = try ensureNl(allocator, result);
        allocator.free(result);
        var follow_raw = if (std.mem.startsWith(u8, result_nl, "Note "))
            try allocator.dupe(u8, result_nl)
        else
            try std.fmt.allocPrint(allocator, "Tool {s} result:\n{s}Continue.", .{ tool_name, result_nl });
        allocator.free(result_nl);
        if (Tool.Name.fromSlice(tool_name)) |n| {
            if (n == .board or n == .peer) {
                const tail_now = board.loadTail(allocator, io, workspace);
                defer if (tail_now.len > 0) allocator.free(tail_now);
                const now = try ssvp.summary(allocator, tail_now);
                defer allocator.free(now);
                if (n == .board) {
                    switch (try ssvp.adopt(allocator, &last_summary, now, .self)) {
                        .none => {},
                        .merge => |msg| allocator.free(msg),
                    }
                } else switch (try ssvp.adopt(allocator, &last_summary, now, .peer)) {
                    .none => {},
                    .merge => |msg| {
                        defer allocator.free(msg);
                        const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ msg, follow_raw });
                        allocator.free(follow_raw);
                        follow_raw = joined;
                    },
                }
            }
        }
        const follow = try presentResult(allocator, dir, io, tool_name, path, follow_raw, archive_src);
        allocator.free(follow_raw);
        allocator.free(tool_name);
        allocator.free(tool_args);
        try thread.append(allocator, .{
            .role = try allocator.dupe(u8, "user"),
            .content = follow,
        });
        switch (try compactThread(allocator, &thread)) {
            .applied, .skipped => {},
        }
        host.pollCancel();
        if (host.cancelled()) return allocator.dupe(u8, interrupted_text);
        if (turns >= max_tool_turns) {
            return std.fmt.allocPrint(
                allocator,
                "stopped: max_tool_turns={d}, next would be {d}; not a clean verdict.\n",
                .{ max_tool_turns, turns + 1 },
            );
        }
        last = (try postOrStop(allocator, io, endpoint, thread.items, sys, flags)) orelse
            return allocator.dupe(u8, interrupted_text);
        turns += 1;
    }
}

const AdmitOutcome = union(enum) {
    stop: []u8,
    result: []u8,
};

const AdmitArgs = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    workspace: []const u8,
    endpoint: types.Endpoint,
    home: []const u8,
    mode: config.PermissionMode,
    has_tty: bool,
    reads: *Reads,
    depth: u8,
    depth_cap: u8,
    allow_peer: bool,
    host: sink.Host,
    trace: ?*Trace,
    plan: Plan,
    cfg: settings.File,
    lookup: env.Lookup,
    auth_json: []const u8,
    explored: bool,
    same: usize,
    asst_text: []u8,
    tool_name: []u8,
    tool_args: []u8,
    path: ?[]const u8,
    thread: *std.ArrayList(pclient.Message),
};

/// Runs an admitted tool: doom, peer, ask_user, compact, verify-gated writes, or dispatch.
fn executeAdmitted(a: AdmitArgs) !AdmitOutcome {
    const allocator = a.allocator;
    if (a.same >= doom_after) {
        allocator.free(a.asst_text);
        const msg = try std.fmt.allocPrint(
            allocator,
            "doom_loop: same tool {d} times with identical input (doom_after={d}); not a clean verdict.\n",
            .{ a.same, doom_after },
        );
        var doom_detail_buf: [permissions.max_command]u8 = undefined;
        a.host.toolOut(a.tool_name, toolDetail(&doom_detail_buf, a.tool_args), true, msg);
        allocator.free(a.tool_name);
        allocator.free(a.tool_args);
        return .{ .stop = msg };
    }

    const tool_name = a.tool_name;
    const tool_args = a.tool_args;
    const path = a.path;
    var result: []u8 = undefined;
    if (Tool.Name.fromSlice(tool_name) == .peer) {
        if (a.depth >= a.depth_cap) {
            result = try allocator.dupe(u8, "peer: nested peer denied; post to board so other peers can read it\n");
        } else if (!a.allow_peer) {
            result = try allocator.dupe(u8, "peer: auto delegation is off for this task; manual /peers still works\n");
        } else {
            const goal = sse.argString(allocator, tool_args, "goal") orelse
                sse.argString(allocator, tool_args, "query") orelse "";
            const nested = try peerTask(allocator, goal);
            defer allocator.free(nested);
            var place = try isolate.forPeer(allocator, a.dir, a.io, a.workspace, a.depth + 1);
            defer place.deinit(allocator);
            const opened = isolate.open(place, a.io, a.dir);
            defer opened.deinit(a.io);
            const peer_ws = place.workspace(a.workspace);
            var peer_ep = peer_router.endpoint(
                allocator,
                a.io,
                a.home,
                a.lookup,
                a.auth_json,
                a.endpoint,
                goal,
            ) catch |err| blk: {
                if (err == error.NoCredential) break :blk a.endpoint;
                return err;
            };
            const peer_owned = !std.mem.eql(u8, peer_ep.base_url, a.endpoint.base_url) or
                !std.mem.eql(u8, peer_ep.api_key, a.endpoint.api_key) or
                !std.mem.eql(u8, peer_ep.model, a.endpoint.model);
            defer if (peer_owned) peer_router.deinitEndpoint(allocator, &peer_ep);
            result = chatOnce(allocator, a.io, opened.dir(), peer_ws, peer_ep, nested, .{
                .mode = a.mode,
                .has_tty = a.has_tty,
                .home = a.home,
                .reads = a.reads,
                .depth = a.depth + 1,
                .trace = a.trace,
                .plan = a.plan,
                .host = a.host,
                .max_peer_depth = a.depth_cap,
                .lookup = a.lookup,
                .auth_json = a.auth_json,
            }) catch |err|
                try std.fmt.allocPrint(allocator, "Note (kept):\n(FAIL peer {s})\n", .{@errorName(err)});
        }
    } else if (Tool.Name.fromSlice(tool_name) == .ask_user) {
        const q = sse.argString(allocator, tool_args, "question") orelse "confirm?";
        result = try permissions.askText(a.io, allocator, q);
    } else if (Tool.Name.fromSlice(tool_name) == .compact) {
        result = try allocator.dupe(u8, switch (try compactThread(allocator, a.thread)) {
            .applied => "compacted. ARC cites at .omfx/recall/rN.txt; never encrypted. continue from the kept tail.\n",
            .skipped => "compact skipped: under turn/char budget.\n",
        });
    } else if (blk: {
        const n = Tool.Name.fromSlice(tool_name) orelse break :blk false;
        break :blk n.needsVerify() and path != null;
    }) {
        const p = path.?;
        const exists = fileExists(a.dir, a.io, allocator, p);
        const need_read = Tool.Name.fromSlice(tool_name) == .edit or exists;
        if (!a.explored) {
            result = try exploreBlock(allocator, tool_name);
        } else if (need_read and !a.reads.guard.mayEdit(p)) {
            result = try Guard.blockMessage(allocator, tool_name, p);
        } else {
            const mark = undo.depth(allocator, a.dir, a.io);
            result = dispatch.run(a.dir, a.io, allocator, a.workspace, tool_name, tool_args, a.home) catch |err| blk: {
                break :blk try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
            };
            a.reads.guard.record(p);
            const note = diag.afterWrite(allocator, a.io, a.workspace, a.dir, p) catch
                try diag.unavailable(allocator, "checker failed");
            defer allocator.free(note);
            if (gate.rejectIfNewlyBroken(allocator, a.io, a.workspace, a.dir, p, mark, note) catch null) |rejected| {
                allocator.free(result);
                result = rejected;
            } else {
                const diff = diag.afterDiff(allocator, a.io, a.workspace, p) catch
                    try allocator.dupe(u8, "review: unavailable (git diff failed); not a clean verdict\n");
                defer allocator.free(diff);
                var llm_review: []const u8 = "";
                if (settings.reviewLlm(a.cfg)) {
                    llm_review = try billedReview(allocator, a.io, a.endpoint, diff);
                }
                defer if (llm_review.len > 0) allocator.free(llm_review);
                const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}{s}{s}", .{ result, note, diff, llm_review });
                allocator.free(result);
                result = joined;
            }
        }
    } else {
        result = dispatch.run(a.dir, a.io, allocator, a.workspace, tool_name, tool_args, a.home) catch |err| blk: {
            break :blk try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
        };
        if (path) |p| {
            if (Tool.Name.fromSlice(tool_name) == .read) a.reads.guard.record(p);
        }
    }
    return .{ .result = result };
}

pub const doom_after: usize = 3;
/// Receipt: every real provider names a tool from the advertised list on the
/// first try. Three in a row is a model that has lost the list, not a slip.
pub const max_malformed: usize = 3;
const malformed_text =
    "stopped: three tool calls in a row named tools that do not exist; not a clean verdict.\n";
/// Receipt: a clean write is 1-2 follow-up HTTP turns; a 130s MissingPath loop was dozens.
/// 24 is a tripwire, not a design target.
pub const max_tool_turns: usize = 24;

comptime {
    if (max_tool_turns < doom_after) @compileError("max_tool_turns must exceed doom_after");
}

pub fn bumpRepeat(
    same: *usize,
    prev_name: []const u8,
    prev_args: []const u8,
    name: []const u8,
    args: []const u8,
) usize {
    if (std.mem.eql(u8, prev_name, name) and std.mem.eql(u8, prev_args, args)) {
        same.* += 1;
    } else {
        same.* = 1;
    }
    return same.*;
}

fn recordVerify(
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
                // Board notes only exist when peers are running. Gating the
                // playbook on them meant a solo session recorded nothing, no
                // matter how many clean verifies it produced -- the file was
                // never written once. The verified tool is the pattern worth
                // keeping when there is no board to read.
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

fn assembleSystem(
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

fn admitCall(
    mode: config.PermissionMode,
    name: []const u8,
    args: []const u8,
    has_tty: bool,
    rules: []const permissions.Rule,
    session: []const permissions.Rule,
    always: []const []const u8,
) permissions.Decision {
    if (permissions.exactKeyHit(always, name, args)) return .allow;
    return permissions.admitWithSession(mode, name, args, has_tty, rules, session);
}

fn exploreBlock(allocator: std.mem.Allocator, tool: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "blocked: {s} before explore\nhonesty: not a clean {s}\nCall list, grep, glob, or read first.\n",
        .{ tool, tool },
    );
}

fn presentResult(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    tool_name: []const u8,
    path: ?[]const u8,
    follow_raw: []const u8,
    /// Unmasked tool body; secrets archive as placeholder even when short.
    archive_src: []const u8,
) ![]u8 {
    const trimmed = try trim.apply(allocator, follow_raw);
    const secret = hooks.hasSecret(archive_src);
    if (follow_raw.len <= compact.result_budget and !secret) return trimmed;
    defer allocator.free(trimmed);
    const target: recall.Target = if (path) |p| .{ .path = p } else .none;
    const body = if (secret) archive_src else follow_raw;
    const id = recall.put(dir, io, tool_name, target, body) catch {
        return compact.capResult(allocator, trimmed);
    };
    const stub = try recall.cite(allocator, .{
        .id = id,
        .tool = tool_name,
        .target = target,
        .chars = body.len,
    });
    defer allocator.free(stub);
    const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stub, trimmed });
    defer allocator.free(joined);
    return compact.capResult(allocator, joined);
}

test "presentResult archives secret-shaped bodies as placeholder" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = "api_key=sk-secret-e2e-not-for-disk\n";
    const follow = "Tool bash result:\napi_key***\nContinue.";
    const out = try presentResult(a, tmp.dir, io, "bash", null, follow, raw);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cite r") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-secret-e2e") == null);
    const body = try recall.load(a, tmp.dir, io, @enumFromInt(1));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "(sensitive; not saved)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sk-secret-e2e") == null);
}

fn billedReview(
    allocator: std.mem.Allocator,
    io: Io,
    endpoint: types.Endpoint,
    diff: []const u8,
) ![]u8 {
    const sys = diag.reviewPrompt(diff);
    const user = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ sys, diff });
    defer allocator.free(user);
    const msgs = [_]pclient.Message{.{ .role = "user", .content = user }};
    var rev = try pclient.postChatMsgs(allocator, io, endpoint, &msgs, sys);
    defer rev.deinit(allocator);
    return std.fmt.allocPrint(allocator, "review: llm\n{s}", .{rev.textSlice()});
}

fn compactThread(allocator: std.mem.Allocator, thread: *std.ArrayList(pclient.Message)) !compact.Applied {
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

fn fileExists(dir: Io.Dir, io: Io, allocator: std.mem.Allocator, rel: []const u8) bool {
    const body = dir.readFileAlloc(io, rel, allocator, .limited(1)) catch return false;
    allocator.free(body);
    return true;
}

fn ensureNl(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0 or s[s.len - 1] == '\n') return allocator.dupe(u8, s);
    return std.fmt.allocPrint(allocator, "{s}\n", .{s});
}

test "toolDetail unescapes a command tab" {
    var buf: [64]u8 = undefined;
    const d = toolDetail(&buf, "{\"command\":\"ls\\t-la\"}");
    try std.testing.expectEqualStrings("ls\t-la", d);
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

test "parseReflect reads PUSHBACK lessons and ignores TASK" {
    try std.testing.expectEqualStrings("do not rewrite auth", parseReflect("PUSHBACK do not rewrite auth").pushback);
    try std.testing.expectEqualStrings("stop adding files", parseReflect("pushback: stop adding files\n").pushback);
    try std.testing.expect(parseReflect("TASK") == .task);
    try std.testing.expect(parseReflect("thats not what i want you to do") == .task);
}

test "trace setTool stores a hash" {
    var t = Trace{};
    t.setTool("edit", "{\"path\":\"a.zig\"}");
    try std.testing.expectEqualStrings("edit", t.toolName());
    try std.testing.expect(t.args_tag != 0);
}

test "peerTask names the goal" {
    const s = try peerTask(std.testing.allocator, "fix auth");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "fix auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Do not spawn peer") != null);
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

test "doom_loop trips on the third identical call" {
    var same: usize = 0;
    try std.testing.expectEqual(@as(usize, 1), bumpRepeat(&same, "", "", "read", "{}"));
    try std.testing.expectEqual(@as(usize, 1), bumpRepeat(&same, "read", "{}", "write", "{}"));
    try std.testing.expectEqual(@as(usize, 2), bumpRepeat(&same, "write", "{}", "write", "{}"));
    try std.testing.expectEqual(@as(usize, 3), bumpRepeat(&same, "write", "{}", "write", "{}"));
    try std.testing.expect(same >= doom_after);
}

test "a tool round with no prose leaves no assistant turn behind" {
    // The bracket tag the model learned to imitate is gone from the source:
    // a placeholder that looks like speech becomes speech.
    const src = @embedFile("agent.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "\"[tool {s}]\"") == null);
}

test "max_tool_turns names the budget" {
    try std.testing.expect(max_tool_turns >= 8);
    try std.testing.expect(max_tool_turns > doom_after);
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

test "a clean verify records a playbook entry without a board" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try pathing.testWorkspace(a, &tmp);
    defer a.free(ws);

    var trace = Trace{};
    trace.setTool("edit", "{}");
    // Solo session: no peers, so no board notes. This used to write nothing at
    // all -- the playbook file had never been created in any real run.
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

test "toolName survives being handed to a caller" {
    // Returned by value, this slice pointed into the parameter copy and read
    // back as stack garbage once the function returned.
    var t = Trace{};
    t.setTool("edit", "{}");
    const name = t.toolName();
    var scratch: [256]u8 = undefined;
    // Churn the stack between taking the slice and reading it.
    @memset(&scratch, 0xAA);
    std.mem.doNotOptimizeAway(&scratch);
    try std.testing.expectEqualStrings("edit", name);
}

test "the system prompt does not move when the workspace does" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Prompt caching matches an exact prefix. If a file write changed the
    // system prompt, every turn after the first edit would reprocess the whole
    // request, which is what the git snapshot and the repo map used to do.
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
