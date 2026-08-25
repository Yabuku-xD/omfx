const std = @import("std");
const Io = std.Io;

const tui = @import("../tui.zig");
const tty = @import("../tty.zig");
const cmds = @import("../cmds.zig");
const chat = @import("../chat.zig");
const live_mod = @import("../live.zig");
const ask_run = @import("../run.zig");
const agent = @import("../../core/agent.zig");
const autoeffort = @import("../../core/autoeffort.zig");
const settings = @import("../../core/settings.zig");
const mention = @import("../../core/mention.zig");
const vision = @import("../../core/vision.zig");
const playbook = @import("../../core/playbook.zig");
const catalog = @import("../../providers/catalog.zig");
const auth = @import("../../providers/auth.zig");
const types = @import("../../providers/types.zig");
const env = @import("../../core/env.zig");
const diagram = @import("../../core/diagram.zig");
const sink = @import("../../core/sink.zig");
const sound_mod = @import("../sound.zig");
const runlog = @import("../../core/runlog.zig");
const activity = @import("../activity.zig");
const panels = @import("../panels.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;
const nowMs = session_mod.nowMs;

const log = std.log.scoped(.repl);

pub const Outcome = enum { ok, quit_loop };

fn toEndpoint(arena: std.mem.Allocator, resolved_opt: ?catalog.Resolved) ?types.Endpoint {
    const resolved = resolved_opt orelse return null;
    return catalog.ownedEndpoint(arena, resolved);
}

fn applyEffort(endpoint: *types.Endpoint, effort: []const u8, ladder: []const u8, prompt: []const u8, failures: usize) void {
    if (effort.len == 0) return;
    if (!std.mem.eql(u8, effort, cmds.auto_effort)) {
        endpoint.effort = effort;
        return;
    }
    const picked = autoeffort.resolve(ladder, prompt, failures);
    if (picked.len > 0) endpoint.effort = picked;
}

fn persistSession(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    user: []const u8,
    assistant: []const u8,
    trace: agent.Trace,
    outcome: []const u8,
) !void {
    var tool_buf: [40]u8 = undefined;
    const tool_body = if (trace.tool_len > 0)
        std.fmt.bufPrint(&tool_buf, "{s}:{x:0>8}", .{ trace.toolName(), trace.args_tag }) catch trace.toolName()
    else
        "";
    const verify = if (trace.verify != .none) @tagName(trace.verify) else "";
    const session = @import("../../core/session.zig");
    try session.appendTurn(gpa, io, home, user, assistant, tool_body, verify, outcome);
}

pub fn takeSteering(sess: *Session) void {
    var buf: [sink.max_steer]u8 = undefined;
    const got = sink.takeSteer(&buf);
    if (got.text.len == 0) return;
    if (sess.draft.items().len != 0 and got.text[0] != ' ') sess.draft.insert(sess.gpa, ' ') catch {};
    for (got.text) |c| sess.draft.insert(sess.gpa, c) catch return;
    sess.steer_send = got.ready;
    sess.dirty = true;
}

fn openSearchPanel(sess: *Session, kind: cmds.PanelKind) void {
    sess.openPanel(panels.build(sess, kind));
    sess.panel_kind = kind;
    if (sess.panel) |*p| {
        p.search = true;
        p.query = sess.panel_edit.items;
        p.selectFirst();
    }
}

/// Run one chat turn: paint the prompt, stream the reply, persist state.
pub fn runTurn(
    sess: *Session,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
    lookup: env.Lookup,
    model: []const u8,
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    prompt_text: []const u8,
) !Outcome {
    const state = &sess.state;
    var ctx = sess.cmdCtx();

    {
        var cred_ctx = sess.cmdCtx();
        cmds.refreshInto(&cred_ctx, false);
    }
    const model_prompt = try mention.expand(arena, Io.Dir.cwd(), io, workspace, prompt_text);
    const shown = try vision.display(arena, Io.Dir.cwd(), io, workspace, prompt_text);
    const composer = try std.fmt.allocPrint(arena, "{s}{s}", .{ state.composer, shown });
    if (state.statusline) {
        try tui.writeFooter(arena, stdout, sess.layout, .{
            .model = model,
            .permission = cmds.footerPerm(state),
            .effort = state.effort,
            .composer = composer,
            .place = workspace,
        });
    } else {
        try stdout.writeAll(tui.sync_begin);
        try stdout.writeAll(sess.cups.toFooter());
        try stdout.writeAll("\x1b[2K");
        try stdout.writeAll(composer);
        try stdout.writeAll(tui.sync_end);
    }
    try stdout.flush();

    const user_line = try chat.formatUser(arena, sess.layout.cols, shown);
    try sess.shown.append(user_line);
    sess.scroll = 0;
    var act = live_mod.Live.Act{};
    defer sess.status = "";
    act.begin();
    sess.status = act.renderNow();
    sess.paintAll(.generating);
    stdout.writeAll(tui.tab_busy) catch |err| {
        log.debug("tab busy: {s}", .{@errorName(err)});
    };
    {
        var head: [activity.max_phrase]u8 = undefined;
        tui.writeTabTitle(stdout, activity.frameOf(0), activity.headline(&head, act.state));
    }
    try stdout.flush();

    var endpoint = toEndpoint(arena, state.resolved);
    if (endpoint == null) {
        try sess.shown.append(try chat.formatCommand(arena, sess.layout.cols, ask_run.missing_key_text));
        sess.status = "";
        sess.paintAll(.idle);
        tty.flushInput();
        stdout.writeAll(tui.tab_idle) catch |err| {
            log.debug("tab idle: {s}", .{@errorName(err)});
        };
        sess.writeIdleTitle();
        try stdout.flush();
        sess.dirty = true;
        return .ok;
    }
    {
        const provider = if (state.resolved) |r| r.spec.id else "";
        var ec = sess.cmdCtx();
        const described = cmds.describeModel(&ec, provider, endpoint.?.model);
        const ladder = if (described) |m| m.efforts else "";
        applyEffort(&endpoint.?, state.effort, ladder, prompt_text, sess.stuck);
        if (described) |m| {
            if (m.context_window != 0) endpoint.?.context_window = m.context_window;
        }
    }
    cmds.markTurn(&ctx, prompt_text);
    var trace = agent.Trace{};
    const turn_began_ms = nowMs(io);
    sess.cancel.store(false, .release);
    var md = chat.Markdown{ .cols = sess.layout.cols };
    defer md.deinit(gpa);
    var tool_run = live_mod.Live.Run{};
    var asst_hold: std.ArrayList(u8) = .empty;
    defer asst_hold.deinit(gpa);
    var live = live_mod.tty(.{
        .stdout = stdout,
        .stdin = stdin,
        .allocator = gpa,
        .layout = &sess.layout,
        .footer = sess.footer(.generating),
        .cancel = &sess.cancel,
        .shown = &sess.shown,
        .think_view = tui.ThinkView.init(state.thinking),
        .asst_hold = &asst_hold,
        .md = &md,
        .act = &act,
        .group = &tool_run,
        .runs = &sess.runs,
        .arena = arena,
        .scroll = &sess.scroll,
    });
    live.startSpin();
    defer live.stopSpin();
    {
        const host = live.host();
        var wait_watch = sink.Watch{
            .cancel = &sess.cancel,
            .tick = host.on_tick,
            .tick_ctx = host.ctx,
            .page_rows = sess.layout.transcript_rows,
        };
        wait_watch.start();
        defer wait_watch.finish();
        if (state.had_turn and !sess.cancel.load(.acquire)) {
            if (agent.reflectFollowup(gpa, io, endpoint.?, state.last_goal, state.last_tool, prompt_text) catch null) |lesson| {
                defer gpa.free(lesson);
                playbook.noteHarmful(gpa, io, workspace, lesson);
            }
        }
    }
    var cfg_depth = settings.load(gpa, io, home);
    const peer_depth = cfg_depth.max_peer_depth;
    cfg_depth.deinit(gpa);
    const auth_json = auth.readJson(arena, io, home);
    const kept = sess.shown.bytes().len;
    var reply_owned = true;
    var turn_host = live.host();
    turn_host.mode_live = &state.mode;
    const reply = if (sess.cancel.load(.acquire)) blk: {
        reply_owned = false;
        break :blk @as([]const u8, "");
    } else agent.chatOnce(
        gpa,
        io,
        Io.Dir.cwd(),
        workspace,
        endpoint.?,
        model_prompt,
        .{
            .mode = state.mode,
            .mode_live = &state.mode,
            .has_tty = true,
            .home = home,
            .reads = &state.reads,
            .trace = &trace,
            .plan = state.plan,
            .host = turn_host,
            .max_peer_depth = peer_depth,
            .prior_user = if (state.interrupted) state.last_prompt else "",
            .prior_assistant = if (state.interrupted) state.last_reply else "",
            .lookup = lookup,
            .auth_json = auth_json,
            .session_rules = state.sessionRuleSlice(),
            .failures = sess.stuck,
        },
    ) catch |err| blk: {
        reply_owned = false;
        break :blk try std.fmt.allocPrint(arena, "Unable to complete the turn ({s}). Try again.\n", .{@errorName(err)});
    };
    defer if (reply_owned) gpa.free(reply);
    const cancelled = sess.cancel.load(.acquire);
    if (cancelled) sink.dropSteer();
    const partial = if (cancelled) try arena.dupe(u8, asst_hold.items) else "";
    const streamed_asst = asst_hold.items.len != 0;
    live.flushAsst();
    live.flushGroups();
    live.flushTable();
    live.closeThink();
    live.stopSpin();
    if (!reply_owned) {
        try sess.shown.append(try arena.dupe(u8, reply));
    } else if (reply.len > 0 and (!streamed_asst or sess.shown.bytes().len == kept)) {
        try sess.shown.append(try chat.formatAssistant(arena, sess.layout.cols, reply));
    }
    if (diagram.save(gpa, Io.Dir.cwd(), io, reply)) |saved| {
        defer saved.deinit(gpa);
        switch (saved) {
            .none => {},
            .report => |msg| try sess.shown.append(
                try chat.formatCommand(arena, sess.layout.cols, msg),
            ),
        }
    } else |err| {
        log.warn("diagram: {s}", .{@errorName(err)});
    }
    sess.status = "";
    sess.paintAll(.idle);
    tty.flushInput();
    stdout.writeAll(tui.tab_idle) catch |err| {
        log.debug("tab idle: {s}", .{@errorName(err)});
    };
    sess.writeIdleTitle();
    try stdout.flush();
    if (cancelled) {
        try sess.shown.append(try chat.formatNotice(arena, sess.layout.cols, "Interrupted"));
        const asst = if (partial.len > 0) partial else agent.interrupted_text;
        persistSession(gpa, io, home, model_prompt, asst, trace, "interrupted") catch |err| {
            log.warn("persist session: {s}", .{@errorName(err)});
        };
        if (!state.interrupted) {
            const goal_keep = if (prompt_text.len > 80) prompt_text[0..80] else prompt_text;
            state.last_goal = try arena.dupe(u8, goal_keep);
            state.last_prompt = try arena.dupe(u8, prompt_text);
        }
        state.last_tool = try arena.dupe(u8, if (trace.tool_len > 0) trace.toolName() else "");
        state.last_reply = try arena.dupe(u8, asst);
        state.had_turn = true;
        state.interrupted = true;
        cmds.persistChat(&ctx);
        sess.paintAll(.idle);
        try stdout.flush();
        sess.dirty = true;
        return .ok;
    }
    takeSteering(sess);
    {
        var cmd_buf: [64]u8 = undefined;
        const pending = sink.takePendingCmd(&cmd_buf);
        if (pending.len != 0) {
            switch (try cmds.dispatch(&ctx, pending)) {
                .handled => {
                    sess.takeMenuNote(&state.menu, nowMs(io));
                    sess.dirty = true;
                },
                .quit => return .quit_loop,
                .panel => |kind| {
                    switch (kind) {
                        .help, .shortcuts => openSearchPanel(sess, kind),
                        else => {
                            sess.openPanel(panels.build(sess, kind));
                            sess.panel_kind = kind;
                        },
                    }
                    sess.dirty = true;
                },
                .fallthrough, .retry => {
                    try sess.draft.replace(sess.gpa, pending);
                    sess.steer_send = true;
                    sess.dirty = true;
                },
            }
        }
    }
    if (state.sound) sound_mod.play(io, lookup, .success);
    const outcome: []const u8 = if (trace.denied) "denied" else "continued";
    if (act.state.tokens != 0) {
        sess.ctx_used = act.state.tokens;
        sess.ctx_fresh = act.state.fresh_input;
        sess.ctx_cache_read = act.state.cache_read;
        sess.ctx_cache_write = act.state.cache_write;
    }
    if (trace.sys_bytes != 0) sess.trace_sys = trace.sys_bytes;
    if (trace.tools_bytes != 0) sess.trace_tools = trace.tools_bytes;
    if (endpoint) |ep| sess.ctx_window = ep.context_window;
    sess.stuck = if (trace.denied or cancelled) sess.stuck + 1 else 0;
    runlog.append(gpa, io, home, .{
        .at_ms = turn_began_ms,
        .model = sess.model(),
        .ms = nowMs(io) - turn_began_ms,
        .tokens = act.state.tokens,
        .tools = trace.tools,
        .verdict = outcome,
        .chars = reply.len,
    });
    persistSession(gpa, io, home, model_prompt, reply, trace, outcome) catch |err| {
        log.warn("persist session: {s}", .{@errorName(err)});
    };
    const goal_keep = if (prompt_text.len > 80) prompt_text[0..80] else prompt_text;
    state.last_goal = try arena.dupe(u8, goal_keep);
    state.last_prompt = try arena.dupe(u8, prompt_text);
    state.last_tool = try arena.dupe(u8, if (trace.tool_len > 0) trace.toolName() else "");
    state.last_reply = try arena.dupe(u8, reply);
    if (state.plan == .on) state.last_plan = try arena.dupe(u8, reply);
    state.had_turn = true;
    state.interrupted = false;
    cmds.persistChat(&ctx);
    sess.dirty = true;
    return .ok;
}

test "auto resolves to a level of the model's own, and only auto does" {
    var ep = types.Endpoint{
        .vendor = .xai,
        .base_url = "https://api.x.ai/v1",
        .api_key = "k",
        .model = "grok-4.6",
    };
    const ladder = "low,medium,high,xhigh";

    applyEffort(&ep, "high", ladder, "anything", 0);
    try std.testing.expectEqualStrings("high", ep.effort);

    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, ladder, "why does this deadlock?", 0);
    try std.testing.expectEqualStrings("xhigh", ep.effort);

    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, ladder, "rename x to y", 0);
    try std.testing.expectEqualStrings("low", ep.effort);

    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, ladder, "why does this deadlock?", 2);
    try std.testing.expectEqualStrings("low", ep.effort);

    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, "", "why does this deadlock?", 0);
    try std.testing.expectEqualStrings("", ep.effort);
}
