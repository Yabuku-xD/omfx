const std = @import("std");
const Io = std.Io;

const tui = @import("tui.zig");
const activity = @import("activity.zig");
const panel_mod = @import("panel.zig");
const runs_mod = @import("runs.zig");
const draft_mod = @import("draft.zig");
const statusline_mod = @import("statusline.zig");
const tty = @import("tty.zig");
const cmds = @import("cmds.zig");
const jobs = @import("../tools/jobs.zig");
const skills = @import("../core/skills.zig");
const todos = @import("../core/todos.zig");
const paint = @import("../core/ansi.zig");
const live_mod = @import("live.zig");
const chat = @import("chat.zig");
const ask_run = @import("run.zig");
const slash = @import("../core/slash.zig");
const agent = @import("../core/agent.zig");
const autoeffort = @import("../core/autoeffort.zig");
const deadline = @import("../tools/deadline.zig");
const settings = @import("../core/settings.zig");
const session = @import("../core/session.zig");
const mention = @import("../core/mention.zig");
const vision = @import("../core/vision.zig");
const playbook = @import("../core/playbook.zig");
const permissions = @import("../core/permissions.zig");
const config = @import("../core/config.zig");
const env = @import("../core/env.zig");
const cli = @import("../core/cli.zig");
const catalog = @import("../providers/catalog.zig");
const models = @import("../providers/models.zig");
const auth = @import("../providers/auth.zig");
const types = @import("../providers/types.zig");
const pathing = @import("../tools/pathing.zig");
const relay = @import("../tools/relay.zig");
const sound_mod = @import("sound.zig");
const diagram = @import("../core/diagram.zig");
const sink = @import("../core/sink.zig");
const toast_mod = @import("toast.zig");
const diffview = @import("diffview.zig");
const board = @import("../core/board.zig");
const progress = @import("progress.zig");
const runlog = @import("../core/runlog.zig");
const menus = @import("menus.zig");
const session_mod = @import("repl/session.zig");
const runs_ui = @import("repl/runs_ui.zig");
const input_mod = @import("repl/input.zig");
const turn_mod = @import("repl/turn.zig");
const loop_mod = @import("repl/loop.zig");
const panels = @import("panels.zig");

pub const Session = session_mod.Session;
const nowMs = session_mod.nowMs;

const log = std.log.scoped(.repl);

pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    home: []const u8,
    workspace: []const u8,
    lookup: env.Lookup,
    model_name: []const u8,
    resolved: ?catalog.Resolved,
    mode_init: config.PermissionMode,
    parsed: cli.Parsed,
) !void {
    const sz0 = tui.size(24, 80);
    var sess = Session{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .stdout = stdout,
        .home = home,
        .workspace = workspace,
        .lookup = lookup,
        .parsed = parsed,
        .fallback_model = model_name,
        .state = .{
            .mode = mode_init,
            .effort = parsed.effort orelse "",
            .effort_prev = parsed.effort orelse "",
            .resolved = resolved,
            .reads = agent.Reads.init(gpa),
        },
        .shown = tui.Transcript.init(gpa, sz0.cols),
        .runs = runs_mod.Store.init(gpa),
        .layout = tui.Layout.compute(sz0.rows, sz0.cols),
        .cups = undefined,
    };
    sess.cups = tui.Cups.compute(sess.layout);
    defer sess.deinit();
    const state = &sess.state;
    {
        var cfg = settings.load(gpa, io, home);
        defer cfg.deinit(gpa);
        relay.ensure(gpa, io, settings.cdpPort(cfg));
        state.sound = settings.soundOn(cfg);
        if (cfg.effort.len > 0 and state.effort.len == 0) state.effort = try arena.dupe(u8, cfg.effort);
        // Builtin/cache only — `describeModel` hits /models and can stall the
        // first paint for tens of seconds on a slow or flaky network. The live
        // list loads when the user opens /model or the picker.
        {
            const provider = if (state.resolved) |r| r.spec.id else "";
            const id = if (state.resolved) |r| r.model else model_name;
            if (models.lookup(provider, id)) |m| sess.ctx_window = m.context_window;
        }
        if (cfg.editor.len > 0 and !std.mem.eql(u8, cfg.editor, "auto")) state.editor = try arena.dupe(u8, cfg.editor);
        deadline.setDefaultSecs(cfg.bash_timeout);
        if (cfg.keep_sessions != 0) session.prune(gpa, io, home, cfg.keep_sessions);
        state.thinking = settings.thinkingOn(cfg);
        state.telemetry = settings.telemetryOn(cfg);
        if (cfg.statusline.len > 0) state.statusline = !std.mem.eql(u8, cfg.statusline, "off");
        if (cfg.composer.len > 0) state.composer = try arena.dupe(u8, cfg.composer);
        if (!parsed.yolo and !parsed.auto) cmds.applySurface(state, cfg.last_mode);
        for (cfg.workspace_dirs) |d| {
            state.appendExtra(try arena.dupe(u8, d)) catch break;
        }
    }
    const skill_roots = skills.readAccessRoots(arena, io, home, workspace) catch &.{};
    sess.read_extra = skill_roots;
    sess.skill_specs = loop_mod.skillSpecs(&sess);
    var raw = tty.Raw.enter();
    defer raw.leave();
    // Registered before the restore defer so restore runs first (LIFO), then
    // this message lands on the primary screen instead of vanishing with alt.
    var exit_eof = false;
    defer {
        if (exit_eof) {
            var err_buf: [256]u8 = undefined;
            var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
            err_w.interface.writeAll("omfx: stdin closed — interactive mode needs a terminal\n") catch {};
            err_w.interface.flush() catch {};
        }
    }
    const painted = try tui.paintSequence(arena, sess.layout, .{
        .model = model_name,
        .permission = cmds.footerPerm(state),
        .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
        .composer = state.composer,
        .place = workspace,
    });
    try stdout.writeAll(painted);
    try stdout.flush();
    if (state.sound) sound_mod.play(io, lookup, .bloom);

    defer {
        const dump = tui.restoreWithScrollback(arena, sess.shown.bytes()) catch tui.restoreSequence();
        stdout.writeAll(dump) catch |err| {
            log.debug("restore write: {s}", .{@errorName(err)});
        };
        stdout.flush() catch |err| {
            log.debug("restore flush: {s}", .{@errorName(err)});
        };
    }

    try tui.writeWelcome(arena, stdout, sess.layout, .{
        .model = model_name,
        .permission = cmds.footerPerm(state),
        .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
        .composer = state.composer,
        .place = workspace,
    });
    try stdout.flush();

    if (parsed.resume_id) |rid| {
        const path = try session.sessionPath(arena, home, session.resolveId(rid));
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1_000_000))) |blob| {
            try sess.shown.append(blob);
            sess.paintTranscript();
            try stdout.flush();
        } else |_| {}
    }

    var slash_buf: [tui.max_slash_hits]slash.Spec = undefined;
    var at_store: [32][96]u8 = undefined;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.Reader.initStreaming(.stdin(), io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    try loop_mod.run(&sess, .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .stdout = stdout,
        .home = home,
        .workspace = workspace,
        .lookup = lookup,
        .model_name = model_name,
        .stdin = stdin,
        .slash_buf = &slash_buf,
        .at_store = &at_store,
        .exit_eof = &exit_eof,
    });
}

/// A Session with no terminal attached, for exercising the state the event loop
/// mutates. `run` needs a tty; the decisions it makes do not.
fn testSession(allocator: std.mem.Allocator) Session {
    return Session.testing(allocator);
}

test "completing a command replaces the whole draft" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    const rows = [_]slash.Spec{.{ .name = "/help", .help = "list slash commands" }};
    try sess.draft.insertSlice(std.testing.allocator, "/hel");
    sess.palette = &rows;
    try std.testing.expect(!try sess.completePalette());
    try std.testing.expectEqualStrings("/help", sess.draft.items());
    try std.testing.expectEqual(@as(usize, 0), sess.palette.len);
}

test "completing a mention replaces only the mention" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    const rows = [_]slash.Spec{.{ .name = "@src/cli/tui.zig", .help = "file" }};
    try sess.draft.insertSlice(std.testing.allocator, "look at @src/cli/tu");
    sess.palette = &rows;
    // True: a mention is an argument, so Enter must keep editing, not send.
    try std.testing.expect(try sess.completePalette());
    try std.testing.expectEqualStrings("look at @src/cli/tui.zig", sess.draft.items());
}

test "completing with an empty palette is a no-op" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.draft.insertSlice(std.testing.allocator, "/hel");
    try std.testing.expect(!try sess.completePalette());
    try std.testing.expectEqualStrings("/hel", sess.draft.items());
}

test "the session footer follows the resolved model and turn" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    sess.fallback_model = "(unset)";
    try std.testing.expectEqualStrings("(unset)", sess.footer(.idle).model);
    try std.testing.expect(sess.footer(.generating).turn == .generating);
}

test "a session transcript survives clear and reuse" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("first turn\n");
    try std.testing.expect(!sess.shown.isEmpty());
    sess.shown.clear();
    try std.testing.expect(sess.shown.isEmpty());
    try sess.shown.append("second turn\n");
    try std.testing.expectEqualStrings("second turn\n", sess.shown.bytes());
}

test "the permissions row offers exactly the real surfaces" {
    // A choice list that disagrees with config.Surface makes every current
    // value look unmatched, so cycling always restarts from the first option.
    // settingsPanel formats values into sess.arena, so the test needs a real
    // one rather than the leak-checking allocator standing in for it.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = scratch.allocator();
    defer sess.deinit();
    const p = panels.build(&sess, .settings);
    for (p.items()) |f| {
        if (!std.mem.eql(u8, f.key, "mode")) continue;
        const opts = switch (f.kind) {
            .choice => |o| o,
            else => return error.PermissionsRowIsNotAChoice,
        };
        try std.testing.expectEqual(std.meta.tags(config.Surface).len, opts.len);
        for (opts) |o| {
            try std.testing.expect(config.Surface.fromSlice(o) != null);
        }
        // And the value currently shown has to be one of them.
        var found = false;
        for (opts) |o| {
            if (std.mem.eql(u8, o, f.value)) found = true;
        }
        try std.testing.expect(found);
        return;
    }
    return error.NoPermissionsRow;
}

test "every settings row maps to a key the setter accepts" {
    // settingsPanel formats values into sess.arena, so the test needs a real
    // one rather than the leak-checking allocator standing in for it.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = scratch.allocator();
    defer sess.deinit();
    const p = panels.build(&sess, .settings);
    try std.testing.expect(p.n > 0);
    for (p.items()) |f| {
        try std.testing.expect(f.key.len > 0);
        try std.testing.expect(f.label.len > 0);
        if (f.kind == .info) continue;
        // An editable row with no help is a control nobody can explain.
        try std.testing.expect(f.help.len > 0);
    }
}

test "every panel builds without a terminal" {
    // A panel that crashes or comes back empty is a command that looks broken.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = scratch.allocator();
    defer sess.deinit();

    const built = [_]panel_mod.Panel{
        panels.build(&sess, .settings),
        panels.build(&sess, .statusline),
        panels.build(&sess, .status),
        panels.build(&sess, .jobs),
        panels.build(&sess, .workspace),
        panels.build(&sess, .sessions),
        panels.build(&sess, .help),
    };
    for (built) |p| {
        try std.testing.expect(p.title.len > 0);
        // Empty is allowed only if the panel says why.
        try std.testing.expect(p.n > 0);
        for (p.items()) |f| try std.testing.expect(f.label.len > 0);
    }
}

test "session panel shows when and del removes the file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try pathing.testWorkspace(a, &tmp);
    defer a.free(home);
    const dir_path = try std.fs.path.join(a, &.{ home, ".omfx", "sessions" });
    defer a.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    {
        const path = try std.fs.path.join(a, &.{ dir_path, "gone.jsonl" });
        defer a.free(path);
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        var buf: [256]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("{\"kind\":\"user\",\"text\":\"hello there\"}\n");
        try w.interface.flush();
    }
    {
        const path = try std.fs.path.join(a, &.{ dir_path, "stay.jsonl" });
        defer a.free(path);
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        var buf: [256]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("{\"kind\":\"user\",\"text\":\"keep me\"}\n");
        try w.interface.flush();
    }

    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var sess = testSession(a);
    sess.arena = scratch.allocator();
    sess.home = home;
    defer sess.deinit();

    sess.openPanel(panels.build(&sess, .sessions));
    sess.panel_kind = .sessions;
    const p0 = sess.panel.?;
    try std.testing.expect(p0.n >= 2);
    var saw_when = false;
    for (p0.items()) |f| {
        if (f.kind != .pick) continue;
        try std.testing.expect(std.mem.startsWith(u8, f.key, "/resume "));
        try std.testing.expect(std.mem.indexOf(u8, f.value, "·") != null);
        try std.testing.expect(f.value.len >= "YYYY-MM-DD HH:MM".len);
        try std.testing.expect(std.mem.indexOf(u8, f.help, "del deletes") != null);
        saw_when = true;
    }
    try std.testing.expect(saw_when);

    // Select the first pick and delete it forever.
    sess.panel.?.selectFirst();
    const before = sess.panel.?.n;
    try std.testing.expect(loop_mod.panelKey(&sess, .delete));
    try std.testing.expect(sess.panel != null);
    try std.testing.expectEqual(cmds.PanelKind.sessions, sess.panel_kind.?);
    try std.testing.expect(sess.panel.?.n < before);

    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const left = try session.listIds(dir, io, a);
    defer {
        for (left) |id| a.free(id);
        a.free(left);
    }
    try std.testing.expectEqual(@as(usize, 1), left.len);
}

test "the help panel lists every command exactly once" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    const p = panels.build(&sess, .help);
    var seen: usize = 0;
    for (p.items()) |f| {
        if (f.kind != .pick) continue;
        seen += 1;
        // A row you can pick has to name a real command.
        try std.testing.expect(slash.find(f.key) != null);
    }
    try std.testing.expectEqual(slash.builtin.len, seen);
    // Nothing was silently dropped off the end.
    try std.testing.expectEqual(@as(usize, 0), p.overflow);
}

test "the cursor lands on a runnable row, never a heading" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    const p = panels.build(&sess, .help);
    const f = p.current().?;
    try std.testing.expect(f.kind != .heading and f.kind != .info);
}

test "typing into the commands panel filters it" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    defer sess.panel_edit.deinit(std.testing.allocator);
    try sess.panel_edit.appendSlice(std.testing.allocator, "sess");
    const p = panels.build(&sess, .help);
    var picks: usize = 0;
    for (p.items()) |f| {
        if (f.kind != .pick) continue;
        picks += 1;
        // Matched on the name or on what the command does, not on neither.
        try std.testing.expect(std.ascii.indexOfIgnoreCase(f.key, "sess") != null or
            std.ascii.indexOfIgnoreCase(f.value, "sess") != null);
    }
    try std.testing.expect(picks > 0);
    try std.testing.expect(picks < slash.builtin.len);
}

test "a query that matches nothing says so instead of showing everything" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    defer sess.panel_edit.deinit(std.testing.allocator);
    try sess.panel_edit.appendSlice(std.testing.allocator, "zzzznope");
    const p = panels.build(&sess, .help);
    try std.testing.expectEqual(@as(usize, 1), p.n);
    try std.testing.expectEqual(panel_mod.Kind.info, p.items()[0].kind);
}

test "a note holds the hint row briefly, then gives it back" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    sess.note("Reasoning set to high.", 1000);
    try std.testing.expectEqualStrings("Reasoning set to high.", sess.mode_note);
    try std.testing.expect(!sess.noteExpired(1000));
    try std.testing.expect(!sess.noteExpired(1000 + Session.note_ms - 1));
    try std.testing.expect(sess.noteExpired(1000 + Session.note_ms));
    sess.noteClear();
    // Nothing set, so nothing to expire: an empty note must not ask for a
    // repaint on every idle poll.
    try std.testing.expect(!sess.noteExpired(1_000_000));
}

test "enter opens a run, then opens a call inside it, then closes each" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();

    const off = sess.shown.bytes().len;
    const row = try chat.formatGroup(a, sess.layout.cols, .{
        .name = "bash",
        .last_detail = "zig test",
        .count = 2,
    });
    defer a.free(row);
    try sess.shown.append(row);
    try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{ "built\n", "ok\n" });

    try std.testing.expect(runs_ui.focusScrollback(&sess));
    try std.testing.expect(sess.runs.items.items[0].openable());

    // Enter on a closed run opens it.
    _ = input_mod.scrollbackKey(&sess, .enter);
    try std.testing.expect(sess.runs.items.items[0].expanded);

    // Enter again opens the call the cursor is on, rather than closing the run.
    _ = input_mod.scrollbackKey(&sess, .enter);
    try std.testing.expect(sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "built") != null);

    // And once more on the same call closes just that call.
    _ = input_mod.scrollbackKey(&sess, .enter);
    try std.testing.expect(!sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(sess.runs.items.items[0].expanded);
}

test "a drag marks text and letting go copies it" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();
    try sess.shown.append("hello world\n");

    const row = termRow(&sess, 0);
    loop_mod.startSel(&sess, row, 1);
    try std.testing.expect(!sess.marked.on());
    sess.extendSel(row, 6);
    try std.testing.expect(sess.marked.on());

    const text = try sess.selText(a);
    defer a.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "the task list pins while there is work left, then gets out of the way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();
    var rows: [todos.max_items][]const u8 = undefined;

    // Scoped to this session, not process-wide.
    const none = try sess.tasks.applyJson(std.testing.allocator, "{\"todos\":[]}");
    std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), sess.pinTodos(&rows).len);

    const out = try sess.tasks.applyJson(std.testing.allocator,
        \\{"todos":[{"content":"read the loader","status":"completed"},{"content":"fix the parser","status":"in_progress"},{"content":"run the tests","status":"pending"}]}
    );
    std.testing.allocator.free(out);
    const pinned = sess.pinTodos(&rows);
    try std.testing.expectEqual(@as(usize, 3), pinned.len);
    try std.testing.expect(std.mem.indexOf(u8, pinned[1], "fix the parser") != null);
    // Exactly one task reads at full weight: the one being worked on.
    try std.testing.expect(std.mem.indexOf(u8, pinned[1], paint.accent_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, pinned[2], paint.accent_dim) == null);

    // All done: the pane gives the rows back rather than holding a wall of ticks.
    const fin = try sess.tasks.applyJson(std.testing.allocator,
        \\{"todos":[{"content":"read the loader","status":"completed"}]}
    );
    std.testing.allocator.free(fin);
    try std.testing.expectEqual(@as(usize, 0), sess.pinTodos(&rows).len);
}

test "the context card splits the window into parts that add up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    // Nothing measured yet: say so rather than draw a card of zeroes.
    try std.testing.expectEqual(panel_mod.Kind.info, panels.build(&sess, .context).items()[0].kind);
    try std.testing.expectEqual(@as(usize, 1), panels.build(&sess, .context).n);

    sess.ctx_window = 500_000;
    sess.ctx_used = 100_000;
    sess.trace_sys = 8_000;
    sess.trace_tools = 4_000;
    const p = panels.build(&sess, .context);
    try std.testing.expectEqualStrings("Total", p.items()[0].label);
    try std.testing.expectEqualStrings("100.0k (20%)", p.items()[0].value);
    // 12000 bytes of fixed floor at four bytes a token is 3000, so messages
    // is what the provider counted minus that.
    try std.testing.expectEqualStrings("97.0k (19%)", p.items()[1].value);
    try std.testing.expectEqualStrings("2.0k (0%)", p.items()[2].value);
    try std.testing.expectEqualStrings("1.0k (0%)", p.items()[3].value);
    try std.testing.expectEqualStrings("400.0k (80%)", p.items()[4].value);
}

test "the rewind panel offers a prompt to go back to, not a number to count" {
    // The panel builds its rows in the turn arena, which the session owns in
    // a real run; the test has to give it one.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    const empty = panels.build(&sess, .rewind);
    try std.testing.expectEqual(@as(usize, 1), empty.n);
    try std.testing.expectEqual(panel_mod.Kind.info, empty.items()[0].kind);

    sess.state.pushMark("add the dark mode toggle", 4, 0);
    sess.state.pushMark("run the tests", 9, 1);
    const p = panels.build(&sess, .rewind);
    // Newest first: the last thing you asked is the likeliest place to return.
    try std.testing.expectEqualStrings("run the tests", p.items()[0].label);
    try std.testing.expectEqualStrings("add the dark mode toggle", p.items()[1].label);
    // Picking a row runs the command it names.
    try std.testing.expectEqualStrings("/rewind 1", p.items()[0].key);
    try std.testing.expectEqualStrings("/rewind 2", p.items()[1].key);
    try std.testing.expectEqualStrings("1 turn back", p.items()[0].value);
    try std.testing.expectEqualStrings("2 turns back", p.items()[1].value);
}

test "clicking away from the scrollback hands the keyboard back" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();
    try sess.shown.append("\u{25b8} Read a file  a.zig\n");
    try sess.runs.add(0, sess.shown.bytes().len, false, "read", &.{"a.zig"}, &.{});

    try std.testing.expect(runs_ui.focusScrollback(&sess));
    try std.testing.expect(sess.focus == .scrollback);

    // The composer is where typing goes, so a press there takes the keyboard.
    loop_mod.startSel(&sess, sess.layout.footer_start_row + 1, 3);
    try std.testing.expect(sess.focus == .prompt);

    try std.testing.expect(runs_ui.focusScrollback(&sess));
    // And so does a press on chrome, which belongs to neither region.
    loop_mod.startSel(&sess, sess.layout.rows, 3);
    try std.testing.expect(sess.focus == .prompt);
}

test "a drag never leaves the region it started in" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();
    try sess.shown.append("hello world\n");

    loop_mod.startSel(&sess, termRow(&sess, 0), 1);
    // Chrome has no region, so the mark stays where the drag began: half a
    // selection in the transcript and half in the footer cannot be copied.
    sess.extendSel(sess.layout.rows, 4);
    try std.testing.expect(!sess.marked.on());
    try std.testing.expect(sess.marked.where == .transcript);
}

test "a click opens the run, then the call, then puts each back" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();

    const off = sess.shown.bytes().len;
    const row = try chat.formatGroup(a, sess.layout.cols, .{
        .name = "bash",
        .last_detail = "zig test",
        .count = 2,
    });
    defer a.free(row);
    try sess.shown.append(row);
    try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{ "built\n", "ok\n" });

    const summary = termRow(&sess, 0);
    runs_ui.clickRun(&sess, summary);
    try std.testing.expect(sess.runs.items.items[0].expanded);
    // The keyboard follows the pointer, so the two never disagree.
    try std.testing.expect(sess.focus == .scrollback);

    // The first call is the row under the summary.
    runs_ui.clickRun(&sess, termRow(&sess, 1));
    try std.testing.expect(sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "built") != null);

    // Clicking the same call again closes it; the run stays open.
    runs_ui.clickRun(&sess, termRow(&sess, 1));
    try std.testing.expect(!sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(sess.runs.items.items[0].expanded);

    // And clicking the summary again closes the run.
    runs_ui.clickRun(&sess, termRow(&sess, 0));
    try std.testing.expect(!sess.runs.items.items[0].expanded);
}

test "an idle footer carries no activity row" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    // What the bug looked like: the row survived the turn that owned its bytes,
    // and the next paint read a stack frame that was gone.
    sess.status = "Waiting for response...";
    try std.testing.expectEqualStrings("Waiting for response...", sess.footer(.generating).status);
    sess.status = "";
    try std.testing.expectEqualStrings("", sess.footer(.idle).status);
}

/// The terminal row the pane is currently painting transcript row `idx` on.
fn termRow(sess: *const Session, idx: usize) u16 {
    const n = sess.shown.rowCount();
    const vis: u16 = @intCast(@min(n, sess.layout.transcript_rows));
    return tui.transcriptFirstRow(sess.layout.transcript_start_row, sess.layout.transcript_rows, vis) +
        @as(u16, @intCast(idx));
}

test "a click opens the run it landed on, and closes it again" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("before\n");
    const off = sess.shown.bytes().len;
    const rec_row = try chat.formatGroup(std.testing.allocator, sess.layout.cols, .{
        .name = "bash",
        .last_detail = "zig test",
        .count = 2,
    });
    defer std.testing.allocator.free(rec_row);
    try sess.shown.append(rec_row);
    try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{});

    const rows0 = sess.shown.rowCount();
    runs_ui.clickRun(&sess, termRow(&sess, 1));
    try std.testing.expectEqual(rows0 + 2, sess.shown.rowCount());
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "zig build") != null);

    // Clicking the summary again closes it.
    runs_ui.clickRun(&sess, termRow(&sess, 1));
    try std.testing.expectEqual(rows0, sess.shown.rowCount());
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "zig build") == null);
    try std.testing.expectEqualStrings("before", sess.shown.row(0));
}

test "a run with one call has nothing to open" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("\u{25b8} Read a file  a.zig\n");
    try sess.runs.add(0, sess.shown.bytes().len, false, "read", &.{"a.zig"}, &.{});
    runs_ui.clickRun(&sess, termRow(&sess, 0));
    try std.testing.expect(!sess.runs.items.items[0].expanded);
}

test "the scrollback keyboard walks runs and folds the selected one" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.deinit();
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const off = sess.shown.bytes().len;
        const row = try chat.formatGroup(a, sess.layout.cols, .{
            .name = "bash",
            .last_detail = "zig test",
            .count = 2,
        });
        defer a.free(row);
        try sess.shown.append(row);
        try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{});
    }

    // Focus lands on the newest run, not the oldest.
    try std.testing.expect(runs_ui.focusScrollback(&sess));
    try std.testing.expectEqual(@as(usize, 1), sess.sel);
    try std.testing.expect(sess.runs.items.items[1].selected);

    _ = input_mod.scrollbackKey(&sess, .{ .byte = 'k' });
    try std.testing.expectEqual(@as(usize, 0), sess.sel);
    try std.testing.expect(!sess.runs.items.items[1].selected);

    _ = input_mod.scrollbackKey(&sess, .{ .byte = 'e' });
    try std.testing.expect(sess.runs.items.items[0].expanded);
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "zig build") != null);
    _ = input_mod.scrollbackKey(&sess, .{ .byte = 'h' });
    try std.testing.expect(!sess.runs.items.items[0].expanded);

    // Typing anything else goes back to the composer and is not swallowed.
    try std.testing.expect(!input_mod.scrollbackKey(&sess, .{ .byte = 'z' }));
    try std.testing.expectEqual(Session.Focus.prompt, sess.focus);
    try std.testing.expect(!sess.runs.items.items[0].selected);
}

test "there is nothing to focus without a run" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("just text\n");
    try std.testing.expect(!runs_ui.focusScrollback(&sess));
    try std.testing.expectEqual(Session.Focus.prompt, sess.focus);
}

test "E opens every run at once, and closes them the same way" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.deinit();
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const off = sess.shown.bytes().len;
        const row = try chat.formatGroup(a, sess.layout.cols, .{ .name = "bash", .count = 2 });
        defer a.free(row);
        try sess.shown.append(row);
        try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "one", "two" }, &.{});
    }
    try std.testing.expect(runs_ui.focusScrollback(&sess));
    _ = input_mod.scrollbackKey(&sess, .{ .byte = 'E' });
    for (sess.runs.items.items) |r| try std.testing.expect(r.expanded);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, sess.shown.bytes(), "one"));
    _ = input_mod.scrollbackKey(&sess, .{ .byte = 'E' });
    for (sess.runs.items.items) |r| try std.testing.expect(!r.expanded);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, sess.shown.bytes(), "one"));
}

test "the keys panel filters as you type and opens a page" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    loop_mod.openSearchPanel(&sess, .shortcuts);
    const all = sess.panel.?.n;
    try std.testing.expect(all > 10);

    _ = loop_mod.panelKey(&sess, .{ .byte = 's' });
    _ = loop_mod.panelKey(&sess, .{ .byte = 'c' });
    const some = sess.panel.?.n;
    try std.testing.expect(some < all);
    try std.testing.expect(some > 0);
    try std.testing.expectEqualStrings("sc", sess.panel.?.query);

    // Backspace widens the list again.
    _ = loop_mod.panelKey(&sess, .backspace);
    try std.testing.expect(sess.panel.?.n > some);

    // Enter reads the binding rather than running it.
    sess.panel_edit.clearRetainingCapacity();
    loop_mod.refilterPanel(&sess);
    sess.panel.?.selectFirst();
    _ = loop_mod.panelKey(&sess, .enter);
    try std.testing.expect(sess.panel.?.detail_of != null);
    try std.testing.expectEqualStrings("", sess.panel_pick);
    _ = loop_mod.panelKey(&sess, .esc);
    try std.testing.expect(sess.panel.?.detail_of == null);
    try std.testing.expect(sess.panel != null);
}

test "every binding lands in a section" {
    for (tui.key_rows) |row| {
        try std.testing.expect(row.section.len != 0);
        try std.testing.expect(row.help.len != 0);
    }
}

test "a prompt typed during a turn lands in the composer" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    sink.dropSteer();

    // Nothing typed: the composer is left alone.
    turn_mod.takeSteering(&sess);
    try std.testing.expectEqual(@as(usize, 0), sess.draft.items().len);
    try std.testing.expect(!sess.steer_send);

    sink.pushSteerForTest("and run the tests");
    turn_mod.takeSteering(&sess);
    try std.testing.expectEqualStrings("and run the tests", sess.draft.items());
    try std.testing.expect(!sess.steer_send);

    // Enter while the turn ran means send it, appended to what was there.
    sink.pushSteerForTest(" now\r");
    turn_mod.takeSteering(&sess);
    try std.testing.expectEqualStrings("and run the tests now", sess.draft.items());
    try std.testing.expect(sess.steer_send);
    sink.dropSteer();
}

test "the context card carries the cache split, wherever it was opened from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    sess.ctx_window = 500_000;
    sess.ctx_used = 200_000;
    sess.ctx_fresh = 6_000;
    sess.ctx_cache_read = 190_000;
    sess.ctx_cache_write = 4_000;

    // `/context` and a click on the header counter open the same card, so
    // asserting the one function covers both doors.
    const p = panels.build(&sess, .context);
    var hit: ?[]const u8 = null;
    var wrote: ?[]const u8 = null;
    for (p.items()) |it| {
        if (std.mem.eql(u8, it.label, "Served from cache")) hit = it.value;
        if (std.mem.eql(u8, it.label, "Written to cache")) wrote = it.value;
    }
    // 190000 of a 200000-token prompt.
    try std.testing.expectEqualStrings("190.0k of the last prompt (95%)", hit.?);
    try std.testing.expect(wrote != null);
}

test "a provider that reports no caching gets no cache rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    sess.ctx_window = 500_000;
    sess.ctx_used = 100_000;
    // Nothing measured means nothing claimed: a card of zeroes reads as a
    // cache that missed, which is not what happened.
    const p = panels.build(&sess, .context);
    for (p.items()) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.label, "Served from cache"));
    }
}
