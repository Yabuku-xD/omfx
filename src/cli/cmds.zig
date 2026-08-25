const std = @import("std");
const chat = @import("chat.zig");
const paint = @import("../core/ansi.zig");
const Io = std.Io;

const log = std.log.scoped(.cmds);

const slash = @import("../core/slash.zig");
const config = @import("../core/config.zig");
const env = @import("../core/env.zig");
const settings = @import("../core/settings.zig");
const session = @import("../core/session.zig");
const sse = @import("../providers/sse.zig");
const permissions = @import("../core/permissions.zig");
const skills = @import("../core/skills.zig");
const agent = @import("../core/agent.zig");
const deadline = @import("../tools/deadline.zig");
const cli = @import("../core/cli.zig");
const commands = @import("../core/commands.zig");
const context = @import("../core/context.zig");
const mention = @import("../core/mention.zig");
const runlog = @import("../core/runlog.zig");
const ide_mod = @import("../core/ide.zig");
const plugins = @import("../core/plugins.zig");
const menus = @import("menus.zig");
const tui = @import("tui.zig");
const run = @import("run.zig");
const catalog = @import("../providers/catalog.zig");
const auth = @import("../providers/auth.zig");
const types = @import("../providers/types.zig");
const models = @import("../providers/models.zig");
const registry = @import("../providers/registry.zig");
const relay = @import("../tools/relay.zig");
const mcp = @import("../tools/mcp.zig");
const web_search = @import("../tools/web_search.zig");
const undo = @import("../tools/undo.zig");
const git_work = @import("../tools/git_work.zig");
const jobs = @import("../tools/jobs.zig");
const pathing = @import("../tools/pathing.zig");
const bash = @import("../tools/bash.zig");
const isolate = @import("../tools/isolate.zig");
const diagram = @import("../core/diagram.zig");
const peer_router = @import("../core/peer_router.zig");
const model_signals = @import("../providers/model_signals.zig");
const handoff_mod = @import("../core/handoff.zig");
const checkpoint_mod = @import("../core/checkpoint.zig");
const spec_mod = @import("../core/spec.zig");

const cmd_ctx = @import("cmd_ctx.zig");
const model_pick = @import("model_pick.zig");

pub const Flow = cmd_ctx.Flow;
pub const PanelKind = cmd_ctx.PanelKind;
pub const max_extra = cmd_ctx.max_extra;
pub const max_jobs = cmd_ctx.max_jobs;
pub const max_marks = cmd_ctx.max_marks;
pub const Mark = cmd_ctx.Mark;
pub const State = cmd_ctx.State;
pub const Ctx = cmd_ctx.Ctx;
pub const OnOff = cmd_ctx.OnOff;
pub const BgAction = cmd_ctx.BgAction;
pub const copy_note = cmd_ctx.copy_note;
pub const footerPerm = cmd_ctx.footerPerm;
pub const cycleSurface = cmd_ctx.cycleSurface;
pub const persistChat = cmd_ctx.persistChat;
pub const refreshInto = cmd_ctx.refreshInto;
pub const applySurface = cmd_ctx.applySurface;
const emit = cmd_ctx.emit;
const settle = cmd_ctx.settle;
const readAuth = cmd_ctx.readAuth;

pub const auto_effort = model_pick.auto_effort;
pub const describeModel = model_pick.describeModel;
pub const modelSummary = model_pick.modelSummary;
pub const stepPickBack = model_pick.stepPickBack;
pub const cycleEffort = model_pick.cycleEffort;
const doEffort = model_pick.doEffort;
const doModels = model_pick.doModels;

fn ensureDir(io: Io, dir: []const u8) void {
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir, @errorName(err) });
    };
}

fn persistPref(gpa: std.mem.Allocator, io: Io, home: []const u8, key: settings.Pref, value: []const u8) void {
    settings.setPref(gpa, io, home, key, value) catch |err| {
        log.warn("persist {s}: {s}", .{ @tagName(key), @errorName(err) });
    };
}

fn combinedSpecs(ctx: *Ctx) ![]slash.Spec {
    var table = commands.load(ctx.gpa, ctx.io, ctx.home, ctx.workspace);
    defer table.deinit(ctx.gpa);
    const extra = try table.specs(ctx.arena);
    const out = try ctx.arena.alloc(slash.Spec, slash.builtin.len + extra.len);
    @memcpy(out[0..slash.builtin.len], &slash.builtin);
    @memcpy(out[slash.builtin.len..], extra);
    return out;
}

pub fn reloadFromDisk(ctx: *Ctx) void {
    var prefs = settings.load(ctx.gpa, ctx.io, ctx.home);
    defer prefs.deinit(ctx.gpa);
    const json = readAuth(ctx.arena, ctx.io, ctx.home);
    const provider = ctx.flag_provider orelse (if (prefs.last_provider.len > 0) prefs.last_provider else null);
    const model = ctx.flag_model orelse (if (prefs.last_model.len > 0) prefs.last_model else null);
    var resolved = auth.resolveStored(ctx.lookup, json, provider, model);
    if (ctx.state.model_override) |override| {
        if (resolved) |*r| r.model = override;
    }
    ctx.state.resolved = resolved;
    refreshInto(ctx, false);
}

pub fn markTurn(ctx: *Ctx, preview: []const u8) void {
    const path = session.sessionPath(ctx.arena, ctx.home, session.resolveId("last")) catch return;
    const blob = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1_000_000)) catch "";
    ctx.state.pushMark(preview, session.nonEmptyCount(blob), undo.depth(ctx.gpa, Io.Dir.cwd(), ctx.io));
}

pub fn runShell(ctx: *Ctx, line: []const u8) !bool {
    switch (mention.classify(line)) {
        .text => return false,
        .shell => |cmd| {
            if (cmd.len == 0) {
                try emit(ctx, "Run a shell command with !<command>.\n");
                return true;
            }
            markTurn(ctx, line);
            const out = bash.run(ctx.gpa, ctx.io, ctx.workspace, cmd) catch |err|
                try std.fmt.allocPrint(ctx.gpa, "error: {s}\n", .{@errorName(err)});
            defer ctx.gpa.free(out);
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{s}\n{s}", .{ line, out }));
            var trace = agent.Trace{};
            trace.setTool("bash", cmd);
            persist(ctx, line, out, trace, "continued");
            ctx.state.last_prompt = try ctx.arena.dupe(u8, line);
            ctx.state.last_reply = try ctx.arena.dupe(u8, out);
            ctx.state.had_turn = true;
            return true;
        },
    }
}

pub fn dispatch(ctx: *Ctx, line: []const u8) !Flow {
    const token_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const token = line[0..token_end];
    const rest = std.mem.trim(u8, line[token_end..], " \t");
    if (slash.Name.fromToken(token)) |cmd| return runCmd(ctx, cmd, rest);
    var table = commands.load(ctx.gpa, ctx.io, ctx.home, ctx.workspace);
    defer table.deinit(ctx.gpa);
    if (table.find(token)) |item| return .{ .retry = try commands.render(ctx.arena, item.body, rest) };
    const specs = try combinedSpecs(ctx);
    if (slash.count(specs, token) > 0) {
        const spec = slash.nth(specs, token, 0).?;
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{s}  {s}\n", .{ spec.name, spec.help }));
        return .handled;
    }
    return .fallthrough;
}

fn endpointOf(ctx: *Ctx) ?types.Endpoint {
    refreshInto(ctx, false);
    const resolved = ctx.state.resolved orelse return null;
    var ep = catalog.toEndpoint(resolved);
    ep.base_url = ctx.arena.dupe(u8, resolved.base_url) catch return null;
    if (ctx.state.effort.len > 0) ep.effort = ctx.state.effort;
    return ep;
}

fn peerEndpointOf(ctx: *Ctx, goal: []const u8) ?types.Endpoint {
    const main = endpointOf(ctx) orelse return null;
    const json = readAuth(ctx.arena, ctx.io, ctx.home);
    const ep = peer_router.endpoint(
        ctx.arena,
        ctx.io,
        ctx.home,
        ctx.lookup,
        json,
        main,
        goal,
    ) catch return null;
    return ep;
}

fn persist(ctx: *Ctx, user: []const u8, assistant: []const u8, trace: agent.Trace, outcome: []const u8) void {
    var tool_buf: [40]u8 = undefined;
    const tool_body = if (trace.tool_len > 0)
        std.fmt.bufPrint(&tool_buf, "{s}:{x:0>8}", .{ trace.toolName(), trace.args_tag }) catch trace.toolName()
    else
        "";
    const verify = if (trace.verify != .none) @tagName(trace.verify) else "";
    session.appendTurn(ctx.gpa, ctx.io, ctx.home, user, assistant, tool_body, verify, outcome) catch |err| {
        log.warn("persist: {s}", .{@errorName(err)});
    };
}

fn freshSession(ctx: *Ctx) void {
    session.rotateLast(ctx.arena, ctx.io, ctx.home);
    session.truncateLast(ctx.arena, ctx.io, ctx.home);
    ctx.state.pending.deinit(ctx.gpa);
    ctx.state.reads.deinit();
    ctx.state.had_turn = false;
    ctx.state.last_goal = "";
    ctx.state.last_prompt = "";
    ctx.state.last_tool = "";
    ctx.state.last_reply = "";
    ctx.state.interrupted = false;
    ctx.state.session_title = "";
    ctx.state.plan = .off;
    ctx.state.last_plan = "";
    ctx.state.marks_n = 0;
}

pub fn formatReload(allocator: std.mem.Allocator, provider: []const u8, model: []const u8, port: u16, skills_n: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "reloaded\nsettings\nauth provider={s} model={s}\nreads\nrelay {d}\nskills {d}\n", .{
        provider, model, port, skills_n,
    });
}

fn runCmd(ctx: *Ctx, cmd: slash.Name, rest: []const u8) !Flow {
    switch (cmd) {
        .help => {
            if (rest.len == 0) return .{ .panel = .help };
            const specs = try combinedSpecs(ctx);
            try emit(ctx, try slash.helpFor(ctx.arena, specs, rest));
        },
        .shortcuts => if (rest.len == 0) return .{ .panel = .shortcuts } else try emit(ctx, "Shortcuts are shown in the shortcuts panel.\n"),
        .login => try startLoginPick(ctx, rest),
        .web => try startWebPick(ctx, rest),
        .browser => try emit(ctx, try relay.install(ctx.arena, ctx.io, ctx.home)),
        .reload => try doReload(ctx),
        .yolo => try doYolo(ctx, rest),
        .effort => try doEffort(ctx, rest),
        .peers => try doPeers(ctx, rest),
        .@"resume" => if (rest.len == 0) return .{ .panel = .sessions } else try doResume(ctx, rest),
        .clear => {
            const n = jobs.count();
            freshSession(ctx);
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "cleared (background jobs kept: {d})\n", .{n}));
        },
        .reset => {
            const n = jobs.killAll();
            freshSession(ctx);
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "reset (background jobs stopped: {d})\n", .{n}));
        },
        .@"continue" => {
            if (rest.len == 0) return .{ .panel = .sessions };
            if (ctx.state.last_prompt.len == 0) {
                try emit(ctx, "There is nothing to continue yet.\n");
                return .handled;
            }
            return .{ .retry = ctx.state.last_prompt };
        },
        .rename => try doRename(ctx, rest),
        .compact => try doCompact(ctx),
        .quit => return .quit,
        .logout => try doLogout(ctx, rest),
        .models => try doModels(ctx, rest),
        .fast => try doFast(ctx, rest),
        .permissions => try doPermissions(ctx, rest),
        .allowlist => try doAllowlist(ctx, rest),
        .sandbox => try doSandbox(ctx, rest),
        .status => return .{ .panel = .status },
        .stats => try doStats(ctx),
        .usage => try doUsage(ctx),
        .context => return .{ .panel = .context },
        .settings => if (rest.len == 0) return .{ .panel = .settings } else try doSettings(ctx, rest),
        .appearance => try doAppearance(ctx, rest),
        .statusline => if (rest.len == 0) return .{ .panel = .statusline } else try doTogglePref(ctx, rest, &ctx.state.statusline, .statusline),
        .sound => try doTogglePref(ctx, rest, &ctx.state.sound, .sound),
        .thinking => try doTogglePref(ctx, rest, &ctx.state.thinking, .thinking),
        .version => try emit(ctx, try std.fmt.allocPrint(ctx.arena, "omfx {s}\n", .{cli.version})),
        .background => if (rest.len == 0) return .{ .panel = .jobs } else try doBackground(ctx, rest),
        .mcp => try doMcp(ctx, rest),
        .workspace => if (rest.len == 0) return .{ .panel = .workspace } else try doWorkspace(ctx, rest),
        .undo => {
            const msg = try undo.pop(ctx.gpa, Io.Dir.cwd(), ctx.io, ctx.workspace);
            defer ctx.gpa.free(msg);
            const git_note = try git_work.undoOmfxCommit(ctx.gpa, ctx.io, ctx.workspace);
            defer ctx.gpa.free(git_note);
            if (git_note.len == 0) {
                try emit(ctx, msg);
            } else {
                try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ msg, git_note }));
            }
        },
        .copy => try doCopy(ctx),
        .diagram => try doDiagram(ctx),
        .feedback => try doFeedback(ctx),
        .trace => try doTrace(ctx),
        .plan => return doPlan(ctx, rest),
        .init => try doInit(ctx, rest),
        .rewind => if (rest.len == 0) return .{ .panel = .rewind } else try doRewind(ctx, rest),
        .fork => try doFork(ctx),
        .handoff => try doHandoff(ctx, rest),
        .spec => return doSpec(ctx, rest),
        .checkpoint => try doCheckpoint(ctx, rest, .ready),
        .sleep => try doCheckpoint(ctx, rest, .sleeping),
        .wake => return doWake(ctx, rest),
        .ide => try doIde(ctx, rest),
        .plugin => try emit(ctx, try plugins.run(ctx.arena, ctx.io, ctx.home, rest)),
    }
    return .handled;
}

fn doReload(ctx: *Ctx) !void {
    // The skill list is scanned once at startup, so a skill added or deleted
    // since then is only visible after this. Flagged rather than rescanned
    // here: the list lives on the session, which owns the arena it is in.
    ctx.state.skills_stale = true;
    ctx.state.pending.deinit(ctx.gpa);
    ctx.state.reads.deinit();
    reloadFromDisk(ctx);
    var cfg = settings.load(ctx.gpa, ctx.io, ctx.home);
    defer cfg.deinit(ctx.gpa);
    const port = settings.cdpPort(cfg);
    ctx.state.sound = settings.soundOn(cfg);
    ctx.state.thinking = settings.thinkingOn(cfg);
    ctx.state.telemetry = settings.telemetryOn(cfg);
    if (cfg.statusline.len > 0) ctx.state.statusline = !std.mem.eql(u8, cfg.statusline, "off");
    if (cfg.composer.len > 0) ctx.state.composer = try ctx.arena.dupe(u8, cfg.composer);
    ctx.state.extra_n = 0;
    for (cfg.workspace_dirs) |d| ctx.state.appendExtra(try ctx.arena.dupe(u8, d)) catch break;
    pathing.setAccess(.{ .workspace = ctx.workspace, .extra = ctx.state.extraSlice() });
    relay.ensure(ctx.gpa, ctx.io, port);
    model_signals.ensure(ctx.gpa, ctx.io, ctx.home);
    const names = skills.listAllNames(ctx.gpa, ctx.io, Io.Dir.cwd(), ctx.home, ctx.workspace) catch try ctx.gpa.alloc([]const u8, 0);
    defer {
        for (names) |name| ctx.gpa.free(name);
        ctx.gpa.free(names);
    }
    const provider = if (ctx.state.resolved) |r| r.spec.id else "(unset)";
    const model = if (ctx.state.resolved) |r| r.model else "(unset)";
    try emit(ctx, try formatReload(ctx.arena, provider, model, port, names.len));
}

fn doYolo(ctx: *Ctx, rest: []const u8) !void {
    const next = OnOff.fromRest(rest, ctx.state.mode == .yolo) orelse {
        try emit(ctx, "Turn writes on or off: /yolo [on|off].\n");
        return;
    };
    ctx.state.mode = if (next) .yolo else .ask;
    persistChat(ctx);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "permission={s}\n", .{ctx.state.mode.asSlice()}));
}

fn doPeers(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len == 0) {
        try emit(ctx, "Give the teammate a goal: /peers <goal>.\n");
        return;
    }
    const ep = peerEndpointOf(ctx, rest) orelse {
        try emit(ctx, run.missing_key_text);
        return;
    };
    const json = readAuth(ctx.arena, ctx.io, ctx.home);
    const nested = try agent.peerTask(ctx.arena, rest);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "/peers {s}\n", .{rest}));
    var trace = agent.Trace{};
    var reply_owned = true;
    const reply = agent.chatOnce(ctx.gpa, ctx.io, Io.Dir.cwd(), ctx.workspace, ep, nested, .{
        .mode = ctx.state.mode,
        .has_tty = true,
        .home = ctx.home,
        .reads = &ctx.state.reads,
        .depth = 1,
        .trace = &trace,
        .plan = ctx.state.plan,
        .lookup = ctx.lookup,
        .auth_json = json,
        .session_rules = ctx.state.sessionRuleSlice(),
    }) catch |err| blk: {
        reply_owned = false;
        break :blk try std.fmt.allocPrint(ctx.arena, "error: {s}\n", .{@errorName(err)});
    };
    defer if (reply_owned) ctx.gpa.free(reply);
    try emit(ctx, reply);
    ctx.state.last_reply = try ctx.arena.dupe(u8, reply);
    persist(ctx, rest, reply, trace, if (trace.denied) "denied" else "continued");
    ctx.state.had_turn = true;
}

fn adoptBlob(ctx: *Ctx, blob: []const u8) void {
    const user = session.lastBody(blob, .user);
    const asst = session.lastBody(blob, .assistant);
    if (user.len > 0) {
        ctx.state.last_prompt = ctx.arena.dupe(u8, user) catch user;
        ctx.state.last_goal = if (user.len > 80) user[0..80] else user;
        ctx.state.had_turn = true;
    }
    if (asst.len > 0) ctx.state.last_reply = ctx.arena.dupe(u8, asst) catch asst;
}

fn replaySession(ctx: *Ctx, blob: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var walk = session.Walk.init(blob);
    while (walk.next()) |entry| {
        const body = sse.unescapeAlloc(ctx.arena, entry.body) catch continue;
        const text = std.mem.trim(u8, body, " \t\r\n");
        if (text.len == 0) continue;
        switch (entry.kind) {
            .user => try out.appendSlice(ctx.arena, try chat.formatUser(ctx.arena, 80, text)),
            .assistant => try out.appendSlice(ctx.arena, try chat.formatAssistant(ctx.arena, 80, text)),
            .tool, .verify, .outcome, .summary => {},
        }
    }
    if (out.items.len == 0) return "(empty session)\n";
    return out.toOwnedSlice(ctx.arena);
}

fn doResume(ctx: *Ctx, id_raw: []const u8) !void {
    const id = session.resolveId(id_raw);
    const path = try session.sessionPath(ctx.arena, ctx.home, id);
    const blob = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1_000_000)) catch {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "session not found: {s}\n", .{id.bytes}));
        return;
    };
    adoptBlob(ctx, blob);
    ctx.state.session_title = try ctx.arena.dupe(u8, id.bytes);
    try emit(ctx, try replaySession(ctx, blob));
}

fn doRename(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len == 0) {
        if (ctx.state.session_title.len == 0) try emit(ctx, "Give the session a title: /rename <title>.") else try emit(ctx, try std.fmt.allocPrint(ctx.arena, "session={s}\n", .{ctx.state.session_title}));
        return;
    }
    var buf: [40]u8 = undefined;
    const title = session.slugTitle(rest, &buf);
    const src = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
    const dest = try session.sessionPath(ctx.arena, ctx.home, session.resolveId(try ctx.arena.dupe(u8, title)));
    Io.Dir.copyFile(Io.Dir.cwd(), src, Io.Dir.cwd(), dest, ctx.io, .{}) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "rename failed: {s}\n", .{@errorName(err)}));
        return;
    };
    ctx.state.session_title = try ctx.arena.dupe(u8, title);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "session={s}\n", .{title}));
}

fn doCompact(ctx: *Ctx) !void {
    const path = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
    var store: session.Store = .{};
    defer store.deinit(ctx.gpa);
    const blob = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(1_000_000)) catch {
        try emit(ctx, "The thread is already short enough to leave alone.\n");
        return;
    };
    defer ctx.gpa.free(blob);
    try store.load(ctx.gpa, blob);
    const before = store.lines.items.len;
    if (!try store.compactNow(ctx.gpa)) {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "nothing to compact ({d} lines, keep_last={d})\n", .{ before, @import("../core/compact.zig").keep_last }));
        return;
    }
    store.path = path;
    store.persist(ctx.gpa, Io.Dir.cwd(), ctx.io) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "compact failed: {s}\n", .{@errorName(err)}));
        return;
    };
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "compacted {d} -> {d} lines\n", .{ before, store.lines.items.len }));
}

fn doLogout(ctx: *Ctx, rest: []const u8) !void {
    const json = readAuth(ctx.arena, ctx.io, ctx.home);
    if (std.mem.eql(u8, rest, "all")) {
        try auth.writeFile(ctx.gpa, ctx.io, ctx.home, "{}\n");
        ctx.state.resolved = null;
        try emit(ctx, "Signed out of every stored provider.\n");
        return;
    }
    const id = if (rest.len > 0) rest else if (ctx.state.resolved) |r| r.spec.id else {
        try emit(ctx, "Say which one to sign out of: /logout [provider|all].\n");
        return;
    };
    const next = try auth.removeId(ctx.gpa, json, id);
    defer ctx.gpa.free(next);
    try auth.writeFile(ctx.gpa, ctx.io, ctx.home, next);
    ctx.state.resolved = auth.resolveStored(ctx.lookup, next, ctx.flag_provider, ctx.flag_model);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "logged out {s}\n", .{id}));
}

fn doFast(ctx: *Ctx, rest: []const u8) !void {
    const next = OnOff.fromRest(rest, ctx.state.fast) orelse {
        try emit(ctx, "Turn fast mode on or off: /fast [on|off].\n");
        return;
    };
    ctx.state.fast = next;
    if (ctx.state.fast) {
        ctx.state.effort_prev = ctx.state.effort;
        ctx.state.effort = config.Effort.none.asSlice();
    } else {
        ctx.state.effort = ctx.state.effort_prev;
    }
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "fast={s} effort={s}\n", .{
        if (ctx.state.fast) "on" else "off",
        if (ctx.state.effort.len == 0) auto_effort else ctx.state.effort,
    }));
}

fn doPermissions(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len == 0) {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "permission={s}\n", .{ctx.state.mode.asSlice()}));
        return;
    }
    if (config.PermissionMode.fromSlice(rest)) |m| {
        ctx.state.mode = m;
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "permission={s}\n", .{m.asSlice()}));
    } else {
        try emit(ctx, "Choose how writes are approved: /permissions ask|auto|yolo.\n");
    }
}

fn doAllowlist(ctx: *Ctx, rest: []const u8) !void {
    var cfg = settings.load(ctx.gpa, ctx.io, ctx.home);
    defer cfg.deinit(ctx.gpa);
    if (rest.len == 0) {
        if (cfg.rules.len == 0 and ctx.state.session_rule_n == 0) {
            try emit(ctx, "The allowlist is empty. Rules live in ~/.omfx/settings.json.\n");
            return;
        }
        var out: std.ArrayList(u8) = .empty;
        for (cfg.rules) |r| {
            try out.appendSlice(ctx.arena, r.pattern);
            if (r.fallback != .none) {
                try out.appendSlice(ctx.arena, "#fallback=");
                try out.appendSlice(ctx.arena, r.fallback.asSlice());
            }
            try out.appendSlice(ctx.arena, "  ");
            try out.appendSlice(ctx.arena, @tagName(r.action));
            try out.append(ctx.arena, '\n');
        }
        for (ctx.state.sessionRuleSlice()) |r| {
            try out.appendSlice(ctx.arena, "session ");
            try out.appendSlice(ctx.arena, r.pattern);
            try out.appendSlice(ctx.arena, "  ");
            try out.appendSlice(ctx.arena, @tagName(r.action));
            try out.append(ctx.arena, '\n');
        }
        try emit(ctx, try out.toOwnedSlice(ctx.arena));
        return;
    }
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    const first = it.next() orelse {
        try emit(ctx, "Add a rule with /allowlist <pattern> allow|ask|deny, or /allowlist session <pattern> ask|deny.\n");
        return;
    };
    if (std.mem.eql(u8, first, "remove")) {
        const pat = std.mem.trim(u8, it.rest(), " \t");
        if (pat.len == 0) {
            try emit(ctx, "Say which rule to drop: /allowlist remove <pattern>.\n");
            return;
        }
        if (try settings.removeRule(ctx.gpa, ctx.io, ctx.home, pat))
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "removed {s}\n", .{pat}))
        else
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "not in allowlist: {s}\n", .{pat}));
        return;
    }
    if (std.mem.eql(u8, first, "session")) {
        const rest2 = std.mem.trim(u8, it.rest(), " \t");
        const sp = std.mem.lastIndexOfScalar(u8, rest2, ' ') orelse {
            try emit(ctx, "Session rules shrink only: /allowlist session <pattern> ask|deny.\n");
            return;
        };
        const pattern = std.mem.trim(u8, rest2[0..sp], " \t");
        const action_s = std.mem.trim(u8, rest2[sp + 1 ..], " \t");
        const action = permissions.parseAction(action_s) orelse {
            try emit(ctx, "Session rules shrink only: /allowlist session <pattern> ask|deny.\n");
            return;
        };
        ctx.state.appendSessionRule(pattern, action) catch |err| {
            switch (err) {
                error.Expand => try emit(ctx, "Session rules cannot expand privilege; use /allowlist <pattern> allow.\n"),
                error.Full => try emit(ctx, "Session allowlist is full (8 rules).\n"),
            }
            return;
        };
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "session {s} {s}\n", .{ pattern, @tagName(action) }));
        return;
    }
    const sp = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse {
        try emit(ctx, "Add a rule with /allowlist <pattern> allow|ask|deny.\n");
        return;
    };
    const pattern = std.mem.trim(u8, rest[0..sp], " \t");
    const action_s = std.mem.trim(u8, rest[sp + 1 ..], " \t");
    const action = permissions.parseAction(action_s) orelse {
        try emit(ctx, "Add a rule with /allowlist <pattern> allow|ask|deny.\n");
        return;
    };
    if (pattern.len == 0) {
        try emit(ctx, "Add a rule with /allowlist <pattern> allow|ask|deny.\n");
        return;
    }
    try settings.appendRule(ctx.gpa, ctx.io, ctx.home, pattern, action);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{s} {s}\n", .{ pattern, @tagName(action) }));
}

fn doSandbox(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len == 0) {
        var cfg = settings.load(ctx.gpa, ctx.io, ctx.home);
        defer cfg.deinit(ctx.gpa);
        const cur: []const u8 = if (settings.sandboxOff(cfg)) "off" else "on";
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "sandbox={s} ({s})\n", .{ cur, run.sandboxName() }));
        return;
    }
    if (std.mem.eql(u8, rest, "off") or std.mem.eql(u8, rest, "on")) {
        try settings.setSandbox(ctx.gpa, ctx.io, ctx.home, rest);
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "sandbox={s}\n", .{rest}));
    } else {
        try emit(ctx, "Turn the sandbox on or off: /sandbox on|off.\n");
    }
}

fn doStats(ctx: *Ctx) !void {
    const path = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
    const blob = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1_000_000)) catch "";
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |l| {
        if (l.len > 0) lines += 1;
    }
    const tool = if (ctx.state.last_tool.len == 0) "-" else ctx.state.last_tool;
    try emit(ctx, try std.fmt.allocPrint(
        ctx.arena,
        "turns={s}\nlines={d}\nlast_tool={s}\nchars={d}\n",
        .{ if (ctx.state.had_turn) "yes" else "no", lines, tool, blob.len },
    ));
}

fn doUsage(ctx: *Ctx) !void {
    const path = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
    const blob = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1_000_000)) catch "";
    var user_n: usize = 0;
    var asst_n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, "\"kind\":\"user\"") != null) user_n += 1;
        if (std.mem.indexOf(u8, l, "\"kind\":\"assistant\"") != null) asst_n += 1;
    }
    // Two windows side by side: one number says work happened, two say whether
    // it is getting slower, chattier, or more often refused.
    const c = runlog.compare(ctx.gpa, ctx.io, ctx.home);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.gpa);
    try out.print(ctx.gpa, "session\n  chars={d} user_turns={d} assistant_turns={d}\n", .{ blob.len, user_n, asst_n });
    if (c.now.turns == 0) {
        try out.appendSlice(ctx.gpa, "\nturns\n  no turns recorded yet\n");
    } else {
        try out.print(ctx.gpa, "\nlast {d} turns\n", .{c.now.turns});
        try out.print(ctx.gpa, "  {d}ms avg  {d} tokens avg  {d} tools  {d} not clean\n", .{
            c.now.avgMs(),
            c.now.avgTokens(),
            c.now.tools,
            c.now.denied,
        });
        if (c.before.turns != 0) {
            try out.print(ctx.gpa, "previous {d}\n", .{c.before.turns});
            try out.print(ctx.gpa, "  {d}ms avg  {d} tokens avg  {d} tools  {d} not clean\n", .{
                c.before.avgMs(),
                c.before.avgTokens(),
                c.before.tools,
                c.before.denied,
            });
        }
        try out.print(ctx.gpa, "\n  ~/.omfx/{s}\n", .{runlog.file_name});
    }
    try emit(ctx, try ctx.arena.dupe(u8, out.items));
}

/// Applies one `key=value`, to disk and to the live session.
///
/// Shared by `/settings key=value` and the settings panel, so the two can never
/// disagree about what a key means or which of them also updates `State`.
pub fn applySetting(ctx: *Ctx, pair: []const u8) !bool {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return false;
    const key = std.mem.trim(u8, pair[0..eq], " \t");
    const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
    if (std.mem.eql(u8, key, "sandbox")) {
        try settings.setSandbox(ctx.gpa, ctx.io, ctx.home, value);
    } else if (settings.NumPref.fromSlice(key)) |num| {
        const n = std.fmt.parseInt(u32, value, 10) catch return false;
        try settings.setNumber(ctx.gpa, ctx.io, ctx.home, num, n);
    } else if (std.mem.eql(u8, key, "mode")) {
        applySurface(ctx.state, value);
        persistChat(ctx);
    } else if (settings.Pref.fromSlice(key)) |pref| {
        // `auto` is omfx's own level: stored as empty, because it is resolved
        // per prompt rather than sent.
        const stored = if ((pref == .effort or pref == .editor or pref == .ide) and
            std.mem.eql(u8, value, auto_effort)) "" else value;
        try settings.setPref(ctx.gpa, ctx.io, ctx.home, pref, stored);
    } else return false;

    // The live session mirrors what was just written, so the change is visible
    // without a restart.
    if (std.mem.eql(u8, key, "sound")) ctx.state.sound = std.mem.eql(u8, value, "on");
    if (std.mem.eql(u8, key, "thinking")) ctx.state.thinking = std.mem.eql(u8, value, "on");
    if (std.mem.eql(u8, key, "telemetry")) ctx.state.telemetry = std.mem.eql(u8, value, "on");
    if (std.mem.eql(u8, key, "statusline")) ctx.state.statusline = !std.mem.eql(u8, value, "off");
    if (std.mem.eql(u8, key, "composer") and value.len > 0) ctx.state.composer = try ctx.arena.dupe(u8, value);
    // "auto" is how the panel spells unset: fall back to $VISUAL then $EDITOR.
    if (std.mem.eql(u8, key, "editor")) ctx.state.editor = if (std.mem.eql(u8, value, "auto")) "" else try ctx.arena.dupe(u8, value);
    if (std.mem.eql(u8, key, "ide")) ctx.state.ide = if (std.mem.eql(u8, value, "auto")) "" else try ctx.arena.dupe(u8, value);
    if (std.mem.eql(u8, key, "bash_timeout")) deadline.setDefaultSecs(std.fmt.parseInt(u32, value, 10) catch 0);
    if (std.mem.eql(u8, key, "effort")) ctx.state.effort = if (std.mem.eql(u8, value, auto_effort)) "" else try ctx.arena.dupe(u8, value);
    if (std.mem.eql(u8, key, "git_auto") and std.mem.eql(u8, value, "on")) {
        git_work.resetDirtyFlag();
    }
    return true;
}

const settings_usage = "usage: /settings <key>=<value>\n  sound thinking telemetry peer git_auto git_dirty statusline sandbox mode composer editor ide\n  review cdp_port effort bash_timeout keep_sessions max_peer_depth\n";

fn settingNote(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    if (std.mem.eql(u8, key, "peer")) {
        return std.fmt.allocPrint(allocator, "Auto peers {s}.\n", .{value});
    }
    if (std.mem.eql(u8, key, "git_auto")) {
        return std.fmt.allocPrint(allocator, "Git auto-commit {s}.\n", .{value});
    }
    return std.fmt.allocPrint(allocator, "{s}={s}\n", .{ key, value });
}

fn doSettings(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len > 0) {
        if (!(applySetting(ctx, rest) catch false)) {
            try emit(ctx, settings_usage);
            return;
        }
        const eq = std.mem.indexOfScalar(u8, rest, '=').?;
        try emit(ctx, try settingNote(
            ctx.arena,
            std.mem.trim(u8, rest[0..eq], " \t"),
            std.mem.trim(u8, rest[eq + 1 ..], " \t"),
        ));
        return;
    }
    const p = try settings.path(ctx.arena, ctx.home);
    var cfg = settings.load(ctx.gpa, ctx.io, ctx.home);
    defer cfg.deinit(ctx.gpa);
    try emit(ctx, try std.fmt.allocPrint(
        ctx.arena,
        "{s}\nrules={d} mcp={d} sandbox={s} cdp={d} sound={s} thinking={s} statusline={s} composer={s} extra_dirs={d}\n",
        .{
            p,
            cfg.rules.len,
            cfg.mcp.len,
            if (settings.sandboxOff(cfg)) "off" else "on",
            settings.cdpPort(cfg),
            if (ctx.state.sound) "on" else "off",
            if (ctx.state.thinking) "on" else "off",
            if (ctx.state.statusline) "on" else "off",
            ctx.state.composer,
            cfg.workspace_dirs.len,
        },
    ));
}

fn doMcp(ctx: *Ctx, rest: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    const action = it.next() orelse "list";
    const name = it.next() orelse "";
    const arguments = std.mem.trim(u8, it.rest(), " \t");
    if ((std.mem.eql(u8, action, "list") or action.len == 0) and name.len == 0) {
        var cfg = settings.load(ctx.gpa, ctx.io, ctx.home);
        defer cfg.deinit(ctx.gpa);
        if (cfg.mcp.len == 0) {
            const msg = try mcp.run(ctx.gpa, ctx.io, ctx.home, "list", "", "{}");
            defer ctx.gpa.free(msg);
            try emit(ctx, msg);
            return;
        }
        ctx.state.pick.open(.mcp);
        for (cfg.mcp) |s| ctx.state.pick.push(s.name, if (s.command.len > 0) s.command else "mcp");
        return;
    }
    const msg = try mcp.run(ctx.gpa, ctx.io, ctx.home, action, name, if (arguments.len == 0) "{}" else arguments);
    defer ctx.gpa.free(msg);
    try emit(ctx, msg);
}

fn configuredLabel(arena: std.mem.Allocator, name: []const u8, on: bool) []const u8 {
    if (!on) return name;
    // Tick leads: the menu clips the title to half width from the start, so a
    // trailing "✓ configured" was the first thing to disappear.
    return std.fmt.allocPrint(arena, "✓ {s}", .{name}) catch name;
}

fn startLoginPick(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len > 0) {
        try menus.startLogin(ctx.gpa, ctx.arena, ctx.io, ctx.home, ctx.stdout, ctx.to_transcript, ctx.shown, &ctx.state.pending, &ctx.state.menu, rest);
        if (ctx.state.pending == .none) reloadFromDisk(ctx);
        return;
    }
    const json = auth.readJson(ctx.gpa, ctx.io, ctx.home);
    defer if (json.len > 0) ctx.gpa.free(json);
    ctx.state.pick.open(.login);
    for (catalog.all) |spec| {
        const on = auth.extractKey(json, catalog.storeId(spec)) != null or auth.extractKey(json, spec.id) != null;
        ctx.state.pick.pushFlipped(spec.id, configuredLabel(ctx.arena, spec.name, on));
    }
}

fn fillWebPick(ctx: *Ctx) void {
    const json = auth.readJson(ctx.gpa, ctx.io, ctx.home);
    defer if (json.len > 0) ctx.gpa.free(json);
    var file = settings.load(ctx.gpa, ctx.io, ctx.home);
    defer file.deinit(ctx.gpa);
    ctx.state.pick.open(.web);
    if (ctx.state.pending == .web_order) {
        ctx.state.pick.pushFlipped(web_search.order_pick_id, "Start over");
        ctx.state.pick.pushFlipped(web_search.default_pick_id, "Use built-in order");
    } else {
        ctx.state.pick.pushFlipped(web_search.order_pick_id, "Set search order");
        ctx.state.pick.pushFlipped(web_search.default_pick_id, "Use built-in order");
    }
    for (web_search.all) |spec| {
        const on = web_search.isConfigured(spec, json, file.web);
        ctx.state.pick.pushFlipped(spec.id, configuredLabel(ctx.arena, spec.name, on));
    }
}

fn startWebPick(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len > 0) {
        try menus.startWeb(ctx.gpa, ctx.arena, ctx.io, ctx.home, ctx.stdout, ctx.to_transcript, ctx.shown, &ctx.state.pending, &ctx.state.menu, rest);
        if (ctx.state.pending == .web_order) fillWebPick(ctx);
        return;
    }
    fillWebPick(ctx);
}

pub fn applyPick(ctx: *Ctx, name: []const u8) !Flow {
    const kind = ctx.state.pick.kind;
    switch (kind) {
        .none => {},
        .providers => {
            try model_pick.bindProvider(ctx, name);
            if (ctx.state.resolved == null) return .handled;
            model_pick.fillModelsFor(ctx, name);
            if (ctx.state.pick.n == 0) {
                ctx.state.pick.clear();
                try emit(ctx, "No models to show.\n");
            }
        },
        .models => {
            ctx.state.pick.clear();
            try model_pick.doModel(ctx, name);
            persistChat(ctx);
            const provider = if (ctx.state.resolved) |r| r.spec.id else "";
            _ = model_pick.fillEffortsFor(ctx, provider, name);
        },
        .efforts => {
            ctx.state.pick.clear();
            const level = name;
            ctx.state.effort = try ctx.arena.dupe(u8, level);
            settings.setPref(ctx.gpa, ctx.io, ctx.home, .effort, level) catch |err| {
                log.warn("effort: {s}", .{@errorName(err)});
            };
            settle(ctx, try std.fmt.allocPrint(ctx.arena, "Reasoning set to {s}.", .{level}));
        },
        .sessions => {
            ctx.state.pick.clear();
            try doResume(ctx, name);
        },
        .mcp => {
            ctx.state.pick.clear();
            const msg = try mcp.run(ctx.gpa, ctx.io, ctx.home, "list", name, "{}");
            defer ctx.gpa.free(msg);
            try emit(ctx, msg);
        },
        .login => {
            ctx.state.pick.clear();
            try menus.startLogin(ctx.gpa, ctx.arena, ctx.io, ctx.home, ctx.stdout, ctx.to_transcript, ctx.shown, &ctx.state.pending, &ctx.state.menu, name);
            if (ctx.state.pending == .none) reloadFromDisk(ctx);
        },
        .web => {
            ctx.state.pick.clear();
            try menus.startWeb(ctx.gpa, ctx.arena, ctx.io, ctx.home, ctx.stdout, ctx.to_transcript, ctx.shown, &ctx.state.pending, &ctx.state.menu, name);
            if (ctx.state.pending == .web_order) fillWebPick(ctx);
        },
        .commands => {
            ctx.state.pick.clear();
            return dispatch(ctx, name);
        },
    }
    return .handled;
}

pub fn fillCommands(state: *State) void {
    state.pick.open(.commands);
    for (slash.builtin) |spec| state.pick.push(spec.name, spec.help);
}

fn persistExtra(ctx: *Ctx) !void {
    try settings.setWorkspaceDirs(ctx.gpa, ctx.io, ctx.home, ctx.state.extraSlice());
    pathing.setAccess(.{ .workspace = ctx.workspace, .extra = ctx.state.extraSlice() });
}

fn doWorkspace(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len == 0) {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(ctx.arena, ctx.workspace);
        try out.append(ctx.arena, '\n');
        for (ctx.state.extraSlice()) |d| {
            try out.appendSlice(ctx.arena, d);
            try out.append(ctx.arena, '\n');
        }
        try emit(ctx, try out.toOwnedSlice(ctx.arena));
        return;
    }
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    const action = it.next() orelse "";
    const dir_s = std.mem.trim(u8, it.rest(), " \t");
    if (std.mem.eql(u8, action, "remove")) {
        if (dir_s.len == 0) {
            try emit(ctx, "Say which directory to drop: /workspace remove <dir>.\n");
            return;
        }
        if (!ctx.state.removeExtra(dir_s)) {
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "not in extra dirs: {s}\n", .{dir_s}));
            return;
        }
        try persistExtra(ctx);
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "removed {s}\n", .{dir_s}));
        return;
    }
    if (!std.mem.eql(u8, action, "add") or dir_s.len == 0) {
        try emit(ctx, "Add a directory with /workspace add <dir>, or drop one with /workspace remove <dir>.\n");
        return;
    }
    var opened = Io.Dir.cwd().openDir(ctx.io, dir_s, .{}) catch {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "not a directory: {s}\n", .{dir_s}));
        return;
    };
    opened.close(ctx.io);
    ctx.state.appendExtra(try ctx.arena.dupe(u8, dir_s)) catch {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "extra dirs: max={d}\n", .{max_extra}));
        return;
    };
    try persistExtra(ctx);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "added {s}\n", .{dir_s}));
}

fn doDiagram(ctx: *Ctx) !void {
    if (ctx.state.last_reply.len == 0) {
        try emit(ctx, "There is no reply to draw a diagram from.\n");
        return;
    }
    var saved = try diagram.save(ctx.gpa, Io.Dir.cwd(), ctx.io, ctx.state.last_reply);
    defer saved.deinit(ctx.gpa);
    switch (saved) {
        .none => try emit(ctx, "The last reply had no mermaid diagrams in it.\n"),
        .report => |msg| try emit(ctx, msg),
    }
}

const CopyNote = union(enum) {
    absent,
    shown,
};

fn copyNoteShown(text: []const u8) bool {
    return copyNote(text) == .shown;
}

/// Whether the note is already the last thing on screen, so /copy twice running
/// does not stack two identical lines.
fn copyNote(text: []const u8) CopyNote {
    return if (std.mem.endsWith(u8, text, copy_note)) .shown else .absent;
}

fn doCopy(ctx: *Ctx) !void {
    if (ctx.state.last_reply.len == 0) {
        try emit(ctx, "There is no reply to copy yet.\n");
        return;
    }
    if (!copyClipboard(ctx.io, ctx.state.last_reply)) {
        try emit(ctx, ctx.state.last_reply);
        try emit(ctx, "No clipboard tool on this machine, so the reply is printed above.\n");
        return;
    }
    switch (copyNote(ctx.shown.bytes())) {
        .shown => {},
        .absent => try emit(ctx, copy_note),
    }
}

/// Best-effort clipboard write. False when the host has no clipboard tool.
pub fn copyClipboard(io: Io, text: []const u8) bool {
    const builtin = @import("builtin");
    const attempts: []const []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{&.{"pbcopy"}},
        else => &.{ &.{"wl-copy"}, &.{ "xclip", "-selection", "clipboard" } },
    };
    for (attempts) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        if (child.stdin) |f| {
            var buf: [256]u8 = undefined;
            var w = f.writer(io, &buf);
            w.interface.writeAll(text) catch |err| {
                log.warn("clipboard write: {s}", .{@errorName(err)});
            };
            w.interface.flush() catch |err| {
                log.warn("clipboard flush: {s}", .{@errorName(err)});
            };
            f.close(io);
            child.stdin = null;
        }
        _ = child.wait(io) catch continue;
        return true;
    }
    return false;
}

fn doTrace(ctx: *Ctx) !void {
    const dest = try std.fs.path.join(ctx.arena, &.{ ctx.home, ".omfx", "trace.txt" });
    const sess = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
    const blob = Io.Dir.cwd().readFileAlloc(ctx.io, sess, ctx.arena, .limited(16_000)) catch "";
    const provider = if (ctx.state.resolved) |r| r.spec.id else "(unset)";
    const model = if (ctx.state.resolved) |r| r.model else "(unset)";
    const body = try std.fmt.allocPrint(
        ctx.arena,
        "omfx {s}\nprovider={s}\nmodel={s}\npermission={s}\nworkspace={s}\nsession={s}\n\n{s}",
        .{ cli.version, provider, model, ctx.state.mode.asSlice(), ctx.workspace, sess, blob },
    );
    const dir = std.fs.path.dirname(dest) orelse ctx.home;
    ensureDir(ctx.io, dir);
    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{ .truncate = true }) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "trace failed: {s}\n", .{@errorName(err)}));
        return;
    };
    defer file.close(ctx.io);
    var buf: [512]u8 = undefined;
    var w = file.writer(ctx.io, &buf);
    w.interface.writeAll(body) catch |err| {
        log.warn("trace write: {s}", .{@errorName(err)});
    };
    w.interface.flush() catch |err| {
        log.warn("trace flush: {s}", .{@errorName(err)});
    };
    _ = copyClipboard(ctx.io, dest);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "trace {s}\n", .{dest}));
}

fn doTogglePref(ctx: *Ctx, rest: []const u8, slot: *bool, key: settings.Pref) !void {
    const next = OnOff.fromRest(rest, slot.*) orelse {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "usage: /{s} [on|off]\n", .{@tagName(key)}));
        return;
    };
    slot.* = next;
    const flag: OnOff = if (next) .on else .off;
    persistPref(ctx.gpa, ctx.io, ctx.home, key, flag.asSlice());
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{s}={s}\n", .{ @tagName(key), flag.asSlice() }));
}

fn doAppearance(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len == 0) {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "composer={s}\n", .{ctx.state.composer}));
        return;
    }
    ctx.state.composer = try ctx.arena.dupe(u8, rest);
    persistPref(ctx.gpa, ctx.io, ctx.home, .composer, rest);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "composer={s}\n", .{ctx.state.composer}));
}

fn doBackground(ctx: *Ctx, rest: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    const action_s = it.next() orelse "list";
    const action = std.meta.stringToEnum(BgAction, action_s) orelse {
        try emit(ctx, "List background jobs with /background list, or stop one with /background kill <id>.\n");
        return;
    };
    switch (action) {
        .list => {
            if (jobs.count() == 0) {
                try emit(ctx, "Nothing is running in the background.\n");
                return;
            }
            var out: std.ArrayList(u8) = .empty;
            var snap: [jobs.max_jobs]jobs.Job = undefined;
            for (jobs.snapshot(&snap)) |j| {
                const rel = try jobs.logRel(ctx.arena, j.id);
                try out.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{d}  {s}  {s}  {s}\n", .{
                    j.id,
                    if (jobs.running(j)) "running " else "finished",
                    j.command(),
                    rel,
                }));
            }
            try emit(ctx, try out.toOwnedSlice(ctx.arena));
        },
        .kill => {
            const id_s = it.next() orelse {
                try emit(ctx, "Say which job to stop: /background kill <id>.\n");
                return;
            };
            const id = std.fmt.parseInt(usize, id_s, 10) catch {
                try emit(ctx, "Say which job to stop: /background kill <id>.\n");
                return;
            };
            // The old version dropped a string from an array and signalled
            // nothing, so a "killed" job kept running.
            if (!jobs.kill(id)) {
                try emit(ctx, try std.fmt.allocPrint(ctx.arena, "no job {d}\n", .{id}));
                return;
            }
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "killed {d}\n", .{id}));
        },
    }
}

fn doFeedback(ctx: *Ctx) !void {
    const dest = try std.fs.path.join(ctx.arena, &.{ ctx.home, ".omfx", "feedback.md" });
    const sess = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
    const blob = Io.Dir.cwd().readFileAlloc(ctx.io, sess, ctx.arena, .limited(4_000)) catch "";
    const body = try std.fmt.allocPrint(
        ctx.arena,
        "# omfx feedback\nversion={s}\nworkspace={s}\nprovider={s}\nmodel={s}\n\n## session excerpt\n```\n{s}\n```\n",
        .{
            cli.version,
            ctx.workspace,
            if (ctx.state.resolved) |r| r.spec.id else "(unset)",
            if (ctx.state.resolved) |r| r.model else "(unset)",
            blob,
        },
    );
    const dir = std.fs.path.dirname(dest) orelse ctx.home;
    ensureDir(ctx.io, dir);
    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{ .truncate = true, .permissions = .fromMode(0o600) }) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "feedback failed: {s}\n", .{@errorName(err)}));
        return;
    };
    defer file.close(ctx.io);
    var buf: [512]u8 = undefined;
    var w = file.writer(ctx.io, &buf);
    w.interface.writeAll(body) catch |err| {
        log.warn("feedback write: {s}", .{@errorName(err)});
    };
    w.interface.flush() catch |err| {
        log.warn("feedback flush: {s}", .{@errorName(err)});
    };
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "wrote {s}\n", .{dest}));
}

const PlanArg = union(enum) {
    enter,
    set: agent.Plan,
    go,
    prompt: []const u8,

    fn parse(rest: []const u8) PlanArg {
        if (rest.len == 0) return .enter;
        if (std.mem.eql(u8, rest, "on")) return .{ .set = .on };
        if (std.mem.eql(u8, rest, "off")) return .{ .set = .off };
        if (std.mem.eql(u8, rest, "go")) return .go;
        return .{ .prompt = rest };
    }
};

const RewindArg = union(enum) {
    list,
    steps: usize,
    /// Compress one half of the session instead of discarding it. The point
    /// is the same -- the thread got long -- but the work is kept.
    summarize: struct { steps: usize, half: session.Half },

    fn parse(rest: []const u8) ?RewindArg {
        if (std.mem.eql(u8, rest, "list")) return .list;
        if (rest.len == 0) return .{ .steps = 1 };
        const sp = std.mem.indexOfScalar(u8, rest, ' ');
        const head = if (sp) |i| rest[0..i] else rest;
        const n = std.fmt.parseInt(usize, head, 10) catch return null;
        if (n == 0) return null;
        if (sp) |i| {
            const word = std.mem.trim(u8, rest[i..], " \t");
            if (std.mem.eql(u8, word, "from")) return .{ .summarize = .{ .steps = n, .half = .from } };
            if (std.mem.eql(u8, word, "upto")) return .{ .summarize = .{ .steps = n, .half = .upto } };
            return null;
        }
        return .{ .steps = n };
    }
};

fn doPlan(ctx: *Ctx, rest: []const u8) !Flow {
    switch (PlanArg.parse(rest)) {
        .enter => {
            ctx.state.plan = .on;
            try emit(ctx, "plan=on\nread-only frontier interview until /plan go\n");
            if (ctx.state.last_plan.len > 0) {
                try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{s}\n", .{ctx.state.last_plan}));
            }
            if (ctx.state.last_goal.len > 0) {
                return .{ .retry = try std.fmt.allocPrint(
                    ctx.arena,
                    "Plan mode for: {s}\nMap the design-tree frontier. Use read/grep/glob/list/semantic_search (and bash only for git status|diff|log or ls|pwd|cat). Do not implement until /plan go.\n",
                    .{ctx.state.last_goal},
                ) };
            }
            return .handled;
        },
        .set => |next| {
            ctx.state.plan = next;
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "plan={s}\n", .{next.asSlice()}));
            return .handled;
        },
        .go => {
            ctx.state.plan = .off;
            const plan = if (ctx.state.last_plan.len > 0) ctx.state.last_plan else ctx.state.last_reply;
            if (plan.len == 0) {
                try emit(ctx, "There is no plan to implement yet.\n");
                return .handled;
            }
            try emit(ctx, "plan=off\n");
            return .{ .retry = try std.fmt.allocPrint(ctx.arena, "Implement the approved plan.\n\n{s}", .{plan}) };
        },
        .prompt => |text| {
            ctx.state.plan = .on;
            try emit(ctx, "plan=on\n");
            return .{ .retry = text };
        },
    }
}

fn doInit(ctx: *Ctx, rest: []const u8) !void {
    const overwrite = std.mem.eql(u8, rest, "overwrite");
    switch (try context.scaffoldAgents(ctx.arena, Io.Dir.cwd(), ctx.io, overwrite)) {
        .exists => |n| try emit(ctx, try std.fmt.allocPrint(ctx.arena, "AGENTS.md exists ({d} bytes). /init overwrite to replace.\n", .{n})),
        .wrote => |n| try emit(ctx, try std.fmt.allocPrint(ctx.arena, "wrote AGENTS.md ({d} bytes)\n", .{n})),
    }
}

fn doRewind(ctx: *Ctx, rest: []const u8) !void {
    const arg = RewindArg.parse(rest) orelse {
        try emit(ctx, "Say how far back: /rewind <n>, or /rewind list.\nTo compress instead of discard: /rewind <n> from, or /rewind <n> upto.\n");
        return;
    };
    switch (arg) {
        .summarize => |sum| {
            const mark = ctx.state.rewindMarks(sum.steps) orelse {
                try emit(ctx, "There is nothing that far back.\n");
                return;
            };
            const span = session.summarizeAt(ctx.gpa, ctx.io, ctx.home, mark.lines, sum.half) catch |err| {
                try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Could not summarize: {s}.\n", .{@errorName(err)}));
                return;
            };
            if (span == 0) {
                try emit(ctx, "There is not enough on that side to be worth summarizing.\n");
                return;
            }
            const path = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
            const blob = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1_000_000)) catch "";
            adoptBlob(ctx, blob);
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Summarized {d} turns {s} \"{s}\".\n", .{
                span,
                if (sum.half == .from) "after" else "before",
                mark.previewSlice(),
            }));
        },
        .list => {
            if (ctx.state.marks_n == 0) {
                try emit(ctx, "no rewind points\n");
                return;
            }
            var out: std.ArrayList(u8) = .empty;
            var i: usize = ctx.state.marks_n;
            while (i > 0) {
                i -= 1;
                const m = ctx.state.marks[i];
                const n = ctx.state.marks_n - i;
                try out.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{d}  {s}\n", .{ n, m.previewSlice() }));
            }
            try emit(ctx, try out.toOwnedSlice(ctx.arena));
            return;
        },
        .steps => |n| {
            const mark = ctx.state.rewindMarks(n) orelse {
                try emit(ctx, "nothing to rewind\n");
                return;
            };
            session.rewindLast(ctx.gpa, ctx.io, ctx.home, mark.lines) catch |err| {
                try emit(ctx, try std.fmt.allocPrint(ctx.arena, "rewind session: {s}\n", .{@errorName(err)}));
                return;
            };
            const files = try undo.popTo(ctx.gpa, Io.Dir.cwd(), ctx.io, ctx.workspace, mark.undo_n);
            defer ctx.gpa.free(files);
            const path = try session.sessionPath(ctx.arena, ctx.home, session.resolveId("last"));
            const blob = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1_000_000)) catch "";
            adoptBlob(ctx, blob);
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "rewound {d}  {s}\n{s}", .{ n, mark.previewSlice(), files }));
        },
    }
}

fn doFork(ctx: *Ctx) !void {
    var id_buf: [24]u8 = undefined;
    var n = ctx.state.fork_n;
    const picked = blk: {
        while (n < 10_000) {
            n += 1;
            const cand = std.fmt.bufPrint(&id_buf, "f{d}", .{n}) catch "f1";
            const path = try session.sessionPath(ctx.arena, ctx.home, session.resolveId(cand));
            var f = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only }) catch break :blk cand;
            f.close(ctx.io);
        }
        break :blk "f1";
    };
    ctx.state.fork_n = n;
    const id = try ctx.arena.dupe(u8, picked);
    const dest = session.forkLast(ctx.gpa, ctx.io, ctx.home, id) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "fork failed: {s}\n", .{@errorName(err)}));
        return;
    };
    defer ctx.gpa.free(dest);
    const tree = isolate.forFork(ctx.gpa, Io.Dir.cwd(), ctx.io, ctx.workspace, id) catch .parent;
    defer tree.deinit(ctx.gpa);
    switch (tree) {
        .parent => try emit(ctx, try std.fmt.allocPrint(ctx.arena, "forked {s}\n/resume {s}\n", .{ id, id })),
        .tree => |p| try emit(ctx, try std.fmt.allocPrint(ctx.arena, "forked {s}\nworktree {s}\n/resume {s}\n", .{ id, p, id })),
    }
}

fn doHandoff(ctx: *Ctx, rest: []const u8) !void {
    const goal = if (rest.len > 0) rest else ctx.state.last_goal;
    var n = ctx.state.fork_n;
    var id_buf: [24]u8 = undefined;
    const picked = blk: {
        while (n < 10_000) {
            n += 1;
            const cand = std.fmt.bufPrint(&id_buf, "h{d}", .{n}) catch "h1";
            const path = try session.sessionPath(ctx.arena, ctx.home, session.resolveId(cand));
            var f = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only }) catch break :blk cand;
            f.close(ctx.io);
        }
        break :blk "h1";
    };
    ctx.state.fork_n = n;
    const id = try ctx.arena.dupe(u8, picked);

    const built = handoff_mod.build(ctx.gpa, ctx.io, ctx.workspace, id, .{
        .goal = goal,
        .last_tool = ctx.state.last_tool,
        .last_reply = ctx.state.last_reply,
    }) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "handoff failed: {s}\n", .{@errorName(err)}));
        return;
    };
    defer ctx.gpa.free(built.stub);
    defer ctx.gpa.free(built.packet);
    defer ctx.gpa.free(built.rel_path);

    handoff_mod.writePacket(ctx.gpa, ctx.io, ctx.workspace, built.rel_path, built.packet) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "handoff packet: {s}\n", .{@errorName(err)}));
        return;
    };

    const dest = try session.sessionPath(ctx.arena, ctx.home, session.resolveId(id));
    const line = try session.encode(ctx.arena, .user, built.stub);
    if (std.fs.path.dirname(dest)) |dir| ensureDir(ctx.io, dir);
    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{ .truncate = true }) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "handoff failed: {s}\n", .{@errorName(err)}));
        return;
    };
    defer file.close(ctx.io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(ctx.io, &buf);
    w.interface.writeAll(line) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "handoff write: {s}\n", .{@errorName(err)}));
        return;
    };
    w.interface.flush() catch |err| {
        log.warn("handoff flush: {s}", .{@errorName(err)});
    };
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "handoff {s}\npacket {s}\n/resume {s}\n", .{ id, built.rel_path, id }));
}

fn doSpec(ctx: *Ctx, rest: []const u8) !Flow {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) {
        const msg = try spec_mod.list(ctx.gpa, ctx.io, ctx.workspace);
        defer ctx.gpa.free(msg);
        try emit(ctx, msg);
        return .handled;
    }
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const first = it.next() orelse {
        try emit(ctx, "usage: /spec [list|new <name>|<name>|next|run]\n");
        return .handled;
    };
    if (std.mem.eql(u8, first, "new")) {
        const name = it.next() orelse {
            try emit(ctx, "usage: /spec new <name>\n");
            return .handled;
        };
        const msg = spec_mod.create(ctx.gpa, ctx.io, ctx.workspace, name) catch |err| {
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "spec new: {s}\n", .{@errorName(err)}));
            return .handled;
        };
        defer ctx.gpa.free(msg);
        try emit(ctx, msg);
        return .{ .retry = try specKick(ctx.arena, name, "requirements") };
    }
    if (std.mem.eql(u8, first, "next")) {
        const msg = try spec_mod.advance(ctx.gpa, ctx.io, ctx.workspace);
        defer ctx.gpa.free(msg);
        try emit(ctx, msg);
        if (spec_mod.loadActive(ctx.arena, ctx.io, ctx.workspace)) |cur| {
            return .{ .retry = try specKick(ctx.arena, cur.name, cur.phase.asSlice()) };
        }
        return .handled;
    }
    if (std.mem.eql(u8, first, "run")) {
        const name = it.next();
        if (name) |n| {
            const msg = try spec_mod.resumeNamed(ctx.gpa, ctx.io, ctx.workspace, n);
            defer ctx.gpa.free(msg);
            try emit(ctx, msg);
        }
        try setActiveExecute(ctx);
        try emit(ctx, "spec run: phase=execute\n");
        const cur = spec_mod.loadActive(ctx.arena, ctx.io, ctx.workspace) orelse return .handled;
        return .{ .retry = try specKick(ctx.arena, cur.name, "execute") };
    }
    const msg = try spec_mod.resumeNamed(ctx.gpa, ctx.io, ctx.workspace, first);
    defer ctx.gpa.free(msg);
    try emit(ctx, msg);
    return .{ .retry = try specKick(ctx.arena, first, "requirements") };
}

fn specKick(arena: std.mem.Allocator, name: []const u8, phase: []const u8) ![]u8 {
    const file = if (std.mem.eql(u8, phase, "execute"))
        "tasks.md"
    else
        try std.fmt.allocPrint(arena, "{s}.md", .{phase});
    return std.fmt.allocPrint(
        arena,
        "Spec {s} active (phase={s}). Use read/write/edit/patch on .omfx/specs/{s}/{s}. Keep the full doc on disk — do not paste it into chat. Orient with grep/glob/list/semantic_search as needed.\n",
        .{ name, phase, name, file },
    );
}

fn setActiveExecute(ctx: *Ctx) !void {
    const cur = spec_mod.loadActive(ctx.gpa, ctx.io, ctx.workspace) orelse return;
    defer ctx.gpa.free(cur.name);
    try spec_mod.setActive(ctx.gpa, ctx.io, ctx.workspace, .{ .name = cur.name, .phase = .execute });
}

fn doCheckpoint(ctx: *Ctx, rest: []const u8, status: checkpoint_mod.Status) !void {
    const note = std.mem.trim(u8, rest, " \t");
    const git_sha = blk: {
        const p = try std.fs.path.join(ctx.arena, &.{ ctx.workspace, ".omfx", "git_last_sha" });
        const raw = Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.arena, .limited(80)) catch break :blk "";
        break :blk std.mem.trim(u8, raw, " \t\r\n");
    };
    const built = checkpoint_mod.build(ctx.gpa, ctx.io, ctx.workspace, status, .{
        .goal = ctx.state.last_goal,
        .note = note,
        .last_tool = ctx.state.last_tool,
        .last_reply = ctx.state.last_reply,
        .mode = ctx.state.mode.asSlice(),
        .plan = ctx.state.plan.asSlice(),
        .git_sha = git_sha,
    }) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "checkpoint failed: {s}\n", .{@errorName(err)}));
        return;
    };
    defer ctx.gpa.free(built.id);
    defer ctx.gpa.free(built.stub);
    defer ctx.gpa.free(built.packet);
    defer ctx.gpa.free(built.meta);
    defer ctx.gpa.free(built.rel_dir);

    checkpoint_mod.writeRun(ctx.gpa, ctx.io, ctx.workspace, built) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "checkpoint write: {s}\n", .{@errorName(err)}));
        return;
    };

    if (status == .sleeping) {
        try emit(ctx, try std.fmt.allocPrint(
            ctx.arena,
            "sleep {s}\n{s}/\nparked (zero compute). /wake {s}\n",
            .{ built.id, built.rel_dir, built.id },
        ));
    } else {
        try emit(ctx, try std.fmt.allocPrint(
            ctx.arena,
            "checkpoint {s}\n{s}/\n",
            .{ built.id, built.rel_dir },
        ));
    }
}

fn doWake(ctx: *Ctx, rest: []const u8) !Flow {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) {
        const msg = try checkpoint_mod.list(ctx.gpa, ctx.io, ctx.workspace);
        defer ctx.gpa.free(msg);
        try emit(ctx, msg);
        return .handled;
    }
    const id = if (std.mem.eql(u8, trimmed, "last"))
        (checkpoint_mod.loadActiveId(ctx.arena, ctx.io, ctx.workspace) orelse {
            try emit(ctx, "No active run. /wake list\n");
            return .handled;
        })
    else
        trimmed;

    const stub = checkpoint_mod.wakeStub(ctx.gpa, ctx.io, ctx.workspace, id) catch |err| {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "wake failed: {s}\n", .{@errorName(err)}));
        return .handled;
    };
    defer ctx.gpa.free(stub);
    const owned = try ctx.arena.dupe(u8, stub);
    ctx.state.last_goal = if (owned.len > 80) owned[0..80] else owned;
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "wake {s}\n", .{id}));
    return .{ .retry = owned };
}

fn doIde(ctx: *Ctx, rest: []const u8) !void {
    const trimmed = std.mem.trim(u8, rest, " \t");
    const path_env = ctx.lookup.get("PATH") orelse "";
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "open")) {
        var cfg = settings.load(ctx.gpa, ctx.io, ctx.home);
        defer cfg.deinit(ctx.gpa);
        try emit(ctx, try ide_mod.open(ctx.arena, ctx.io, path_env, ctx.workspace, cfg.ide));
        return;
    }
    if (std.mem.eql(u8, trimmed, "list")) {
        var found: [ide_mod.max_ides][]const u8 = undefined;
        const n = ide_mod.detect(ctx.io, path_env, &found);
        if (n == 0) {
            try emit(ctx, "no IDE binaries on PATH (code, cursor, zed, windsurf, …)\n");
            return;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(ctx.arena);
        try out.appendSlice(ctx.arena, "IDEs on PATH:\n");
        for (found[0..n]) |id| {
            try out.appendSlice(ctx.arena, "  ");
            try out.appendSlice(ctx.arena, id);
            try out.append(ctx.arena, '\n');
        }
        try emit(ctx, try out.toOwnedSlice(ctx.arena));
        return;
    }
    try settings.setPref(ctx.gpa, ctx.io, ctx.home, .ide, trimmed);
    ctx.state.ide = try ctx.arena.dupe(u8, trimmed);
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "IDE set to {s}. /ide open launches it.\n", .{trimmed}));
}

test "reload report names every surface" {
    const s = try formatReload(std.testing.allocator, "xai", "grok-4.6", 9224, 2);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "reloaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "auth provider=xai") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "reads") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "relay 9224") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "skills 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "playbook") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "AGENTS.md") == null);
}

test "cycleSurface walks normal plan yolo" {
    var reads = agent.Reads.init(std.testing.allocator);
    defer reads.deinit();
    var st = State{ .mode = .ask, .reads = reads };
    try std.testing.expectEqualStrings("normal", footerPerm(&st));
    try std.testing.expectEqualStrings("plan  read-only; /plan go to implement", cycleSurface(&st));
    try std.testing.expectEqualStrings("plan", footerPerm(&st));
    try std.testing.expectEqualStrings("yolo  tools run without asking", cycleSurface(&st));
    try std.testing.expectEqualStrings("yolo", footerPerm(&st));
    try std.testing.expectEqualStrings("normal  ask before tools", cycleSurface(&st));
    try std.testing.expectEqualStrings("normal", footerPerm(&st));
    applySurface(&st, "plan");
    try std.testing.expectEqualStrings("plan", footerPerm(&st));
}

test "dispatch unknown slash falls through" {
    try std.testing.expectEqual(slash.Name.clear, slash.Name.fromToken("/new").?);
    try std.testing.expect(slash.Name.fromToken("/not-a-command") == null);
}

test "fillCommands lists builtin slash names" {
    var st = State{ .mode = .ask, .reads = agent.Reads.init(std.testing.allocator) };
    defer st.deinit(std.testing.allocator);
    fillCommands(&st);
    try std.testing.expectEqual(tui.PickKind.commands, st.pick.kind);
    try std.testing.expect(st.pick.n >= 1);
    try std.testing.expectEqualStrings("/help", st.pick.rows[0].name);
}

test "plan and rewind args are tagged" {
    try std.testing.expect(PlanArg.parse("") == .enter);
    try std.testing.expectEqual(agent.Plan.on, PlanArg.parse("on").set);
    try std.testing.expect(PlanArg.parse("go") == .go);
    try std.testing.expectEqualStrings("ship it", PlanArg.parse("ship it").prompt);
    try std.testing.expect(RewindArg.parse("list").? == .list);
    try std.testing.expectEqual(@as(usize, 1), RewindArg.parse("").?.steps);
    try std.testing.expectEqual(@as(usize, 3), RewindArg.parse("3").?.steps);
    try std.testing.expect(RewindArg.parse("0") == null);
}

test "rewindMarks walks back n turns" {
    var reads = agent.Reads.init(std.testing.allocator);
    defer reads.deinit();
    var st = State{ .mode = .ask, .reads = reads };
    st.pushMark("one", 0, 0);
    st.pushMark("two", 2, 1);
    const m = st.rewindMarks(1).?;
    try std.testing.expectEqualStrings("two", m.previewSlice());
    try std.testing.expectEqual(@as(usize, 1), st.marks_n);
}

test "bench: slash commands dispatch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try pathing.testWorkspace(a, &tmp);
    defer a.free(home);
    try Io.Dir.cwd().createDirPath(io, home);
    const sess_dir = try std.fs.path.join(a, &.{ home, ".omfx", "sessions" });
    defer a.free(sess_dir);
    try Io.Dir.cwd().createDirPath(io, sess_dir);
    {
        var n: usize = 0;
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(a);
        while (n < 12) : (n += 1) {
            const line = try std.fmt.allocPrint(a, "{{\"kind\":\"user\",\"body\":\"turn-{d}\"}}\n", .{n});
            defer a.free(line);
            try blob.appendSlice(a, line);
        }
        const path = try std.fs.path.join(a, &.{ sess_dir, "last.jsonl" });
        defer a.free(path);
        var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var buf: [256]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(blob.items);
        try w.interface.flush();
    }

    const table = env.Table{ .pairs = &.{.{ .key = "HOME", .value = home }} };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var shown = tui.Transcript.init(a, 80);
    defer shown.deinit();
    const reads = agent.Reads.init(a);
    var state = State{ .mode = .ask, .reads = reads };
    defer state.deinit(a);
    var ctx = Ctx{
        .gpa = a,
        .arena = arena,
        .io = io,
        .stdout = &aw.writer,
        .home = home,
        .workspace = "/tmp",
        .lookup = table.lookup(),
        .to_transcript = "",
        .flag_provider = "xai-oauth",
        .flag_model = "grok-4.5",
        .shown = &shown,
        .state = &state,
    };

    const cases = [_][]const u8{
        "/help",
        "/help compact",
        "/version",
        "/status",
        "/stats",
        "/usage",
        "/settings",
        "/context",
        "/shortcuts",
        "/models",
        "/model",
        "/effort",
        "/effort low",
        "/fast",
        "/permissions",
        "/permissions auto",
        "/allowlist",
        "/sandbox",
        "/yolo",
        "/thinking",
        "/thinking on",
        "/sound off",
        "/statusline",
        "/appearance",
        "/mcp",
        "/workspace",
        "/background",
        "/feedback",
        "/trace",
        "/diagram",
        "/copy",
        "/undo",
        "/continue",
        "/peers",
        "/plan",
        "/rewind list",
        "/rename",
        "/session",
        "/compact",
        "/fork",
        "/handoff",
        "/spec",
        "/checkpoint",
        "/sleep",
        "/wake list",
        "/login",
        "/web",
        "/browser",
    };

    const t0 = Io.Clock.Timestamp.now(io, .awake);
    var n: usize = 0;
    for (cases) |line| {
        const flow = dispatch(&ctx, line) catch |err| {
            std.debug.print("BENCH slash fail {s} {s}\n", .{ line, @errorName(err) });
            return err;
        };
        switch (flow) {
            .handled, .quit, .fallthrough, .retry, .panel => {},
        }
        n += 1;
    }
    const ns = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
    std.debug.print("BENCH slash_n={d} slash_ns={d} out_bytes={d}\n", .{ n, ns, aw.written().len });
    try std.testing.expectEqual(cases.len, n);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "omfx 0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Reasoning set to low.") != null);
}

test "a level list reads as a sentence, not as wire format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("low, medium, high", model_pick.effortList(a, "low,medium,high"));
    try std.testing.expectEqualStrings("high", model_pick.effortList(a, "high"));
    try std.testing.expectEqualStrings("", model_pick.effortList(a, ""));
    // A trailing comma from a provider must not become a trailing gap.
    try std.testing.expectEqualStrings("low, high", model_pick.effortList(a, "low,high,"));
}

test "a model row says what the model is, not what it is called" {
    var buf: [96]u8 = undefined;
    const grok = models.lookup("xai-oauth", "grok-4.6").?;
    const row = modelSummary(&buf, grok);
    try std.testing.expect(std.mem.indexOf(u8, row, "500k") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "text+vision") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "xhigh") != null);
    // The id is on the left already; repeating it here is the bug this fixed.
    try std.testing.expect(std.mem.indexOf(u8, row, "grok-4.6") == null);
}

test "the window unit follows the size" {
    var buf: [96]u8 = undefined;
    const api = models.lookup("openai", "gpt-5.6").?;
    try std.testing.expect(std.mem.indexOf(u8, modelSummary(&buf, api), "1.0M") != null);

    var plain = models.lookup("xai-api", "grok-2-vision").?;
    try std.testing.expect(std.mem.indexOf(u8, modelSummary(&buf, plain), "8k") != null);
    // No reasoning levels, so the row stops after the modalities.
    plain.efforts = "";
    plain.vision = false;
    try std.testing.expectEqualStrings("8k  \u{b7}  text", modelSummary(&buf, plain));

    // A window nobody published says so rather than showing 0k.
    plain.context_window = 0;
    try std.testing.expect(std.mem.startsWith(u8, modelSummary(&buf, plain), "window unknown"));
}

test "copyNoteShown detects the last copy line" {
    try std.testing.expect(!copyNoteShown(""));
    try std.testing.expect(!copyNoteShown("hello\n"));
    try std.testing.expect(copyNoteShown("copied last reply\n"));
    try std.testing.expect(copyNoteShown("hello\ncopied last reply\n"));
    // The note must be the tail, not merely present somewhere above.
    try std.testing.expect(!copyNoteShown("copied last reply\nhello\n"));
}
