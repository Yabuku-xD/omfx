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
const todo_mod = @import("../core/todos.zig");
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
pub const UsageTab = cmd_ctx.UsageTab;
pub const usageTabNext = cmd_ctx.usageTabNext;
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

const cmd_registry = @import("cmds/registry.zig");

pub const reloadFromDisk = cmd_registry.reloadFromDisk;
pub const copyNoteShown = cmd_registry.copyNoteShown;
pub const copyNote = cmd_registry.copyNote;
pub const applySetting = cmd_registry.applySetting;
pub const PlanArg = cmd_registry.PlanArg;
pub const RewindArg = cmd_registry.RewindArg;

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
            cmd_registry.persist(ctx, line, out, trace, "continued");
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
    if (slash.Name.fromToken(token)) |cmd| return cmd_registry.run(ctx, cmd, rest);
    var table = commands.load(ctx.gpa, ctx.io, ctx.home, ctx.workspace);
    defer table.deinit(ctx.gpa);
    if (table.find(token)) |item| return .{ .retry = try commands.render(ctx.arena, item.body, rest) };
    const specs = try cmd_registry.combinedSpecs(ctx);
    if (slash.count(specs, token) > 0) {
        const spec = slash.nth(specs, token, 0).?;
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{s}  {s}\n", .{ spec.name, spec.help }));
        return .handled;
    }
    return .fallthrough;
}
pub fn formatReload(allocator: std.mem.Allocator, provider: []const u8, model: []const u8, port: u16, skills_n: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "reloaded\nsettings\nauth provider={s} model={s}\nreads\nrelay {d}\nskills {d}\n", .{
        provider, model, port, skills_n,
    });
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
            try cmd_registry.doResume(ctx, name);
        },
        .mcp => {
            ctx.state.pick.clear();
            const msg = try mcp.run(ctx.gpa, ctx.io, ctx.home, "list", name, "{}");
            defer ctx.gpa.free(msg);
            try emit(ctx, msg);
        },
        .login => {
            ctx.state.pick.clear();
            try cmd_registry.startLoginPick(ctx, name);
            if (ctx.state.pending == .none) reloadFromDisk(ctx);
        },
        .web => {
            ctx.state.pick.clear();
            try cmd_registry.startWebPick(ctx, name);
            if (ctx.state.pending == .web_order) cmd_registry.fillWebPick(ctx);
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
    try std.testing.expectEqualStrings("plan  look first; say go when ready", cycleSurface(&st));
    try std.testing.expectEqualStrings("plan", footerPerm(&st));
    try std.testing.expectEqualStrings("yolo  changes without asking", cycleSurface(&st));
    try std.testing.expectEqualStrings("yolo", footerPerm(&st));
    try std.testing.expectEqualStrings("normal  routine tools run; risky ones ask", cycleSurface(&st));
    try std.testing.expectEqualStrings("auto", footerPerm(&st));
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
    var read_extra: []const []const u8 = &.{};
    var tasks = todo_mod.List{};
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
        .read_extra = &read_extra,
        .tasks = &tasks,
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
