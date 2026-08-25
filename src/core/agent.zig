const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const permissions = @import("permissions.zig");
const settings = @import("settings.zig");
const env = @import("env.zig");
const peer_policy = @import("peer_policy.zig");
const board = @import("board.zig");
const ssvp = @import("ssvp.zig");
const vision = @import("vision.zig");
const contract_mod = @import("contract.zig");
const hooks = @import("hooks.zig");
const types = @import("../providers/types.zig");
const pclient = @import("../providers/client.zig");
const dispatch = @import("../tools/dispatch.zig");
const sse = @import("../providers/sse.zig");
const Tool = @import("tool.zig");
const sink = @import("sink.zig");
const turn_loop = @import("agent/turn_loop.zig");
const setup = @import("agent/setup.zig");
const reflect_mod = @import("agent/reflect.zig");
const execute_mod = @import("agent/execute.zig");
const context = @import("context.zig");

pub const max_read_paths = setup.max_read_paths;
pub const interrupted_text = setup.interrupted_text;
pub const Guard = setup.Guard;
pub const stripPath = setup.stripPath;
pub const Reads = setup.Reads;
pub const max_peer_depth = setup.max_peer_depth;
pub const max_peer_depth_cap = setup.max_peer_depth_cap;
pub const Verify = setup.Verify;
pub const Trace = setup.Trace;
pub const Plan = setup.Plan;
pub const Run = setup.Run;
pub const ChatError = setup.ChatError;
pub const Reflect = reflect_mod.Reflect;
pub const reflect_sys = reflect_mod.reflect_sys;
pub const parseReflect = reflect_mod.parseReflect;
pub const reflectFollowup = reflect_mod.reflectFollowup;
pub const peerTask = reflect_mod.peerTask;
pub const doom_after = execute_mod.doom_after;
pub const bumpRepeat = execute_mod.bumpRepeat;
pub const orient_after = turn_loop.orient_after;

/// Printed the moment a stop is requested, because the request itself cannot be
/// torn down until the provider sends its first byte. Without it a long
/// reasoning pause makes the key look dead.
const stopping_ack = "\r\x1b[K\x1b[2m" ++ sink.stopping_phrase ++ "\x1b[0m\r\n";

fn postOrStop(
    allocator: std.mem.Allocator,
    io: Io,
    endpoint: types.Endpoint,
    messages: []const pclient.Message,
    sys: []const u8,
    flags: pclient.ChatFlags,
) !?pclient.ChatResult {
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
        .page_rows = flags.host.page_rows,
    };
    watch.start();
    defer watch.finish();
    return pclient.postChatFiltered(allocator, io, endpoint, messages, sys, flags) catch |err| {
        if (flags.host.cancelled()) return null;
        return err;
    };
}

fn liveMode(run: Run) config.PermissionMode {
    return if (run.mode_live) |p| p.* else run.mode;
}

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
    var always: [8][]u8 = undefined;
    var always_n: usize = 0;
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
    const sys = try setup.assembleSystem(allocator, io, dir, workspace, home, allow_peer, plan, run.lookup, run.auth_json, endpoint);
    if (trace) |t| {
        t.sys_bytes = @intCast(@min(sys.len, std.math.maxInt(u32)));
        t.tools_bytes = @intCast(@min(pclient.advertisedBytes(endpoint), std.math.maxInt(u32)));
    }

    const state_block = try setup.workspaceState(
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

    var thread = try setup.seedThread(
        allocator,
        run.prior_user,
        run.prior_assistant,
        user_with_state,
        try vision.attach(allocator, dir, io, workspace, user),
    );

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
    var orient_streak: usize = 0;
    var tool_rounds: usize = 0;
    const trace_hook: ?turn_loop.TraceHook = if (trace) |t| .{
        .ctx = t,
        .deny_tool = struct {
            fn f(ctx: *anyopaque, name: []const u8, args: []const u8) void {
                const tr: *Trace = @ptrCast(@alignCast(ctx));
                tr.denied = true;
                tr.setTool(name, args);
            }
        }.f,
    } else null;
    while (true) {
        turn_loop.pollBoundary(host);
        if (host.cancelled()) {
            last.deinit(allocator);
            return allocator.dupe(u8, interrupted_text);
        }
        if (try turn_loop.finishIfText(allocator, &last, tool_rounds, ensureNl)) |text| return text;
        const extracted = turn_loop.extractToolCall(&last);
        const call = extracted.call;
        const extras = extracted.extras;
        tool_rounds += 1;
        if (try turn_loop.malformedToolCheck(
            allocator,
            .{ .name = call.name, .preamble = call.preamble },
            &malformed,
            max_malformed,
            malformed_text,
            &last,
            ensureNl,
        )) |stop| return stop;
        const mode = liveMode(run);
        const admitted = try turn_loop.admitToolCall(.{
            .allocator = allocator,
            .io = io,
            .mode = mode,
            .has_tty = has_tty,
            .rules = cfg.rules,
            .session_rules = run.session_rules,
            .always = always[0..always_n],
            .always_n = &always_n,
            .always_cap = always.len,
            .host = host,
            .trace = trace_hook,
            .plan = plan,
            .user = user,
            .tool_blob = tool_blob.items,
            .workspace = workspace,
            .call = .{ .name = call.name, .args = call.args },
        });
        switch (admitted) {
            .stop => |msg| {
                last.deinit(allocator);
                return msg;
            },
            .allow => |ok| {
                defer if (ok.one_shot) |k| allocator.free(k);
                const asst_text = try allocator.dupe(u8, call.preamble);
                const tool_name = try allocator.dupe(u8, call.name);
                var start_activity_buf: [120]u8 = undefined;
                const activity_label = sse.argStringInto(&start_activity_buf, call.args, "activity") orelse
                    sse.argStringInto(&start_activity_buf, call.args, "description") orelse "";
                host.tool(call.name, activity_label, false);
                const tool_args = try allocator.dupe(u8, call.args);
                last.deinit(allocator);
                if (trace) |t| t.setTool(tool_name, tool_args);

                host.pollModeCycle();
                const mode_run = liveMode(run);
                if (try turn_loop.recheckAdmitted(.{
                    .allocator = allocator,
                    .io = io,
                    .mode = mode_run,
                    .has_tty = has_tty,
                    .rules = cfg.rules,
                    .session_rules = run.session_rules,
                    .always = always[0..always_n],
                    .host = host,
                    .one_shot = ok.one_shot,
                    .tool_name = tool_name,
                    .tool_args = tool_args,
                })) |deny_body| {
                    var deny_detail_buf: [permissions.max_command]u8 = undefined;
                    const deny_detail = turn_loop.toolDetail(&deny_detail_buf, tool_args);
                    host.toolOut(tool_name, deny_detail, true, deny_body);
                    allocator.free(asst_text);
                    allocator.free(tool_name);
                    allocator.free(tool_args);
                    return deny_body;
                }

                if (Tool.Name.fromSlice(tool_name)) |n| {
                    if (n.isExplore()) explored = true;
                }
                if (Tool.Name.fromSlice(tool_name) == .todo) {
                    same = 0;
                } else {
                    _ = execute_mod.bumpRepeat(&same, prev_name, prev_args, tool_name, tool_args);
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
                    .allow => switch (try execute_mod.executeAdmitted(.{
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
                        .chat_once = chatOnce,
                    })) {
                        .stop => |msg| return msg,
                        .result => |r| result = r,
                    },
                }
                const archive_src = try allocator.dupe(u8, result);
                defer allocator.free(archive_src);
                {
                    const hooked = try hooks.post(allocator, io, workspace, dir, con, tool_name, path, result);
                    allocator.free(result);
                    result = hooked;
                    if (Tool.Name.fromSlice(tool_name)) |n| {
                        if (n.needsVerify()) {
                            setup.recordVerify(allocator, io, workspace, trace, result);
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
                    const d = turn_loop.toolDetail(&out_detail_buf, tool_args);
                    break :blk if (d.len != 0) d else path orelse "";
                };
                host.toolOut(tool_name, detail, true, result);
                for (extras) |ex| {
                    host.pollCancel();
                    host.pollModeCycle();
                    if (host.cancelled()) break;
                    var ex_detail_buf: [permissions.max_command]u8 = undefined;
                    const ex_path = turn_loop.toolDetail(&ex_detail_buf, ex.args);
                    host.tool(ex.name, ex_path, false);
                    const d = turn_loop.admitCall(liveMode(run), ex.name, ex.args, has_tty, cfg.rules, run.session_rules, always[0..always_n]);
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

                const round_orients = turn_loop.roundOrients(asst_text, tool_name, tool_args);
                if (round_orients) orient_streak += 1 else orient_streak = 0;

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

                if (orient_streak >= turn_loop.orient_after) {
                    const nudged = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ follow_raw, turn_loop.orient_nudge });
                    allocator.free(follow_raw);
                    follow_raw = nudged;
                }

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
                const follow = try execute_mod.presentResult(allocator, dir, io, tool_name, path, follow_raw, archive_src);
                allocator.free(follow_raw);
                allocator.free(tool_name);
                allocator.free(tool_args);
                try thread.append(allocator, .{
                    .role = try allocator.dupe(u8, "user"),
                    .content = follow,
                });
                switch (try setup.compactThread(allocator, &thread)) {
                    .applied, .skipped => {},
                }
                host.pollCancel();
                if (host.cancelled()) return allocator.dupe(u8, interrupted_text);
                if (try turn_loop.checkTurnLimit(allocator, turns, max_tool_turns)) |stop| return stop;
                last = (try postOrStop(allocator, io, endpoint, thread.items, sys, flags)) orelse
                    return allocator.dupe(u8, interrupted_text);
                turns += 1;
            },
        }
    }
}

pub const max_malformed: usize = 3;
const malformed_text =
    "stopped: three tool calls in a row named tools that do not exist; not a clean verdict.\n";
pub const max_tool_turns: usize = 24;

comptime {
    if (max_tool_turns < doom_after) @compileError("max_tool_turns must exceed doom_after");
}

fn ensureNl(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0 or s[s.len - 1] == '\n') return allocator.dupe(u8, s);
    return std.fmt.allocPrint(allocator, "{s}\n", .{s});
}

test "trace setTool stores a hash" {
    var t = Trace{};
    t.setTool("edit", "{\"path\":\"a.zig\"}");
    try std.testing.expectEqualStrings("edit", t.toolName());
    try std.testing.expect(t.args_tag != 0);
}

test "a tool round with no prose leaves no assistant turn behind" {
    const src = @embedFile("agent.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "\"[tool {s}]\"") == null);
}

test "max_tool_turns names the budget" {
    try std.testing.expect(max_tool_turns >= 8);
    try std.testing.expect(max_tool_turns > doom_after);
}

test "toolName survives being handed to a caller" {
    var t = Trace{};
    t.setTool("edit", "{}");
    const name = t.toolName();
    var scratch: [256]u8 = undefined;
    @memset(&scratch, 0xAA);
    std.mem.doNotOptimizeAway(&scratch);
    try std.testing.expectEqualStrings("edit", name);
}
