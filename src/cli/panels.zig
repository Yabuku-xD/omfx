const std = @import("std");
const Io = std.Io;

const tui = @import("tui.zig");
const panel_mod = @import("panel.zig");
const statusline_mod = @import("statusline.zig");
const tty = @import("tty.zig");
const cmds = @import("cmds.zig");
const jobs = @import("../tools/jobs.zig");
const slash = @import("../core/slash.zig");
const settings = @import("../core/settings.zig");
const session = @import("../core/session.zig");
const board = @import("../core/board.zig");
const progress = @import("progress.zig");

const session_mod = @import("repl/session.zig");

const Session = session_mod.Session;

const known_editors = [_][]const u8{
    "code", "cursor", "zed", "subl",  "windsurf",
    "hx",   "nvim",   "vim", "emacs", "nano",
    "vi",
};

/// One for "auto" plus every editor that could be found.
pub const max_editors: usize = known_editors.len + 1;

/// The editors actually on this machine. `auto` leads, because following
/// $VISUAL then $EDITOR is the right answer for most people and the only one
/// that keeps working when they change their mind elsewhere.
pub fn detectEditors(sess: *Session, out: [][]const u8) usize {
    out[0] = "auto";
    var n: usize = 1;
    const path = sess.lookup.get("PATH") orelse return n;
    for (known_editors) |name| {
        if (n == out.len) break;
        if (onPath(sess, path, name)) {
            out[n] = name;
            n += 1;
        }
    }
    return n;
}

fn onPath(sess: *Session, path: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        const st = Io.Dir.cwd().statFile(sess.io, full, .{}) catch continue;
        if (st.kind == .file) return true;
    }
    return false;
}

pub fn build(sess: *Session, kind: cmds.PanelKind) panel_mod.Panel {
    return switch (kind) {
        .settings => settingsPanel(sess),
        .help => helpPanel(sess),
        .shortcuts => keysPanel(sess),
        .sessions => sessionPanel(sess),
        .statusline => statuslinePanel(sess),
        .status => statusPanel(sess),
        .rewind => rewindPanel(sess),
        .context => contextPanel(sess),
        .jobs => jobsPanel(sess),
        .workspace => workspacePanel(sess),
        .plan => planPanel(sess),
        .files => filesPanel(sess),
        .peers => peersPanel(sess),
    };
}

pub fn settingsPanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    var p = panel_mod.Panel{ .title = "Settings" };
    p.add(.{
        .key = "sound",
        .label = "Sound",
        .kind = .toggle,
        .value = if (sess.state.sound) "on" else "off",
        .help = "chime on launch and when a turn finishes",
    });
    p.add(.{
        .key = "thinking",
        .label = "Show thinking",
        .kind = .toggle,
        .value = if (sess.state.thinking) "on" else "off",
        .help = "show the assistant's thinking while it works",
    });
    p.add(.{
        .key = "telemetry",
        .label = "Telemetry",
        .kind = .toggle,
        .value = if (sess.state.telemetry) "on" else "off",
        .help = "only says which app is talking; off keeps you anonymous",
    });
    p.add(.{
        .key = "peer",
        .label = "Auto teammates",
        .kind = .toggle,
        .value = if (settings.peerAutoOn(cfg)) "on" else "off",
        .help = "lets the assistant ask a teammate on its own; /peers still works anytime",
    });
    p.add(.{
        .key = "statusline",
        .label = "Status line",
        .kind = .toggle,
        .value = if (sess.state.statusline) "on" else "off",
        .help = "model and mode under the composer",
    });
    p.add(.{
        .key = "mode",
        .label = "Permissions",
        // The three surfaces `shift-tab` cycles, spelled the way `config.Surface`
        // spells them -- a list that disagrees makes every value read as index 0.
        .kind = .{ .choice = &.{ "normal", "plan", "yolo" } },
        .value = cmds.footerPerm(&sess.state),
        .help = "normal prompts, plan is read-only, yolo allows writes",
    });
    p.add(.{
        .key = "sandbox",
        .label = "Sandbox",
        .kind = .{ .choice = &.{ "on", "off" } },
        .value = if (settings.sandboxOff(cfg)) "off" else "on",
        .help = "OS sandbox on bash, network denied",
    });
    var editors: [max_editors][]const u8 = undefined;
    const found = detectEditors(sess, &editors);
    p.add(.{
        .key = "editor",
        .label = "Editor",
        // A choice of what is installed, not a name you have to spell: the
        // wrong spelling fails at ctrl-g, an hour after you typed it.
        .kind = .{ .choice = editors[0..found] },
        .value = if (cfg.editor.len == 0) editors[0] else sess.arena.dupe(u8, cfg.editor) catch editors[0],
        .help = "ctrl-g opens this; auto follows $VISUAL then $EDITOR",
    });
    p.add(.{
        .key = "bash_timeout",
        .label = "Command timeout",
        .kind = .{ .number = .{ .min = 0, .max = 3600, .step = 30 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.bash_timeout}) catch "0",
        .help = "seconds a bash command may run; 0 is the default 120",
    });
    p.add(.{
        .key = "keep_sessions",
        .label = "Keep sessions",
        .kind = .{ .number = .{ .min = 0, .max = 1000, .step = 10 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.keep_sessions}) catch "0",
        .help = "saved sessions kept on disk; 0 keeps every one",
    });
    p.add(.{
        .key = "max_peer_depth",
        .label = "Peer depth",
        .kind = .{ .number = .{ .min = 0, .max = 8 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.max_peer_depth}) catch "1",
        .help = "how many levels of teammate a peer may spawn",
    });
    const path = settings.path(sess.arena, sess.home) catch "";
    p.add(.{ .key = "path", .label = "File", .kind = .info, .value = path });
    return p;
}

/// Writes one field through to disk and to the live session, then rebuilds the
/// panel so what is on screen is what was actually saved.
pub fn applyPanelField(sess: *Session, p: panel_mod.Panel, value: []const u8) void {
    const f = p.current() orelse return;
    var ctx = sess.cmdCtx();

    // A status-line field toggle edits one entry of a list, not a scalar, so
    // it is rewritten here rather than passed straight to the setter.
    if (std.mem.startsWith(u8, f.key, "field:")) {
        var cfg = settings.load(sess.gpa, sess.io, sess.home);
        defer cfg.deinit(sess.gpa);
        var sl = statusline_mod.parse(cfg.statusline_place, cfg.statusline_fields);
        const name = f.key["field:".len..];
        if (statusline_mod.Field.fromSlice(name)) |fld| {
            if (std.mem.eql(u8, value, "on")) sl.add(fld) else sl.remove(fld);
        }
        var buf: [160]u8 = undefined;
        const encoded = sl.encode(&buf);
        const line2 = std.fmt.allocPrint(sess.arena, "statusline_fields={s}", .{encoded}) catch return;
        _ = cmds.applySetting(&ctx, line2) catch {};
        const sel2 = p.sel;
        var next2 = statuslinePanel(sess);
        next2.sel = sel2;
        next2.elapsed_ms = panel_mod.open_ms;
        sess.panel = next2;
        return;
    }
    // A statusline placement rebuilds its own panel, not the settings one.
    const is_statusline = std.mem.eql(u8, f.key, "statusline_place");
    const line = std.fmt.allocPrint(sess.arena, "{s}={s}", .{ f.key, value }) catch return;
    // Same path as `/settings key=value`: one setter, no second source of truth.
    _ = cmds.applySetting(&ctx, line) catch {};
    const sel = p.sel;
    var next = if (is_statusline) statuslinePanel(sess) else settingsPanel(sess);
    next.sel = sel;
    next.elapsed_ms = panel_mod.open_ms;
    sess.panel = next;
}

pub fn togglePanelField(sess: *Session) void {
    const p = sess.panel orelse return;
    const f = p.current() orelse return;
    if (f.kind != .toggle) return;
    applyPanelField(sess, p, if (std.mem.eql(u8, f.value, "on")) "off" else "on");
}

/// Left/right on a choice cycles the list; on a number it steps within bounds.
pub fn stepPanelValue(sess: *Session, forward: bool) void {
    const p = sess.panel orelse return;
    const f = p.current() orelse return;
    switch (f.kind) {
        .choice => |opts| {
            if (opts.len == 0) return;
            var at: usize = 0;
            for (opts, 0..) |o, i| {
                if (std.mem.eql(u8, o, f.value)) at = i;
            }
            const n: i32 = @intCast(opts.len);
            const next = @mod(@as(i32, @intCast(at)) + (if (forward) @as(i32, 1) else -1) + n, n);
            applyPanelField(sess, p, opts[@intCast(next)]);
        },
        .number => |b| {
            const cur = std.fmt.parseInt(u32, f.value, 10) catch b.min;
            const stepped: u32 = if (forward)
                @min(b.max, cur +| b.step)
            else if (cur <= b.step) b.min else @max(b.min, cur - b.step);
            const text = std.fmt.allocPrint(sess.arena, "{d}", .{stepped}) catch return;
            applyPanelField(sess, p, text);
        },
        .toggle => togglePanelField(sess),
        // Nothing to step: a pick is chosen with Enter, the rest are inert.
        .text, .info, .pick, .heading, .entry => {},
    }
}

/// Hands the draft to `$EDITOR`, then reads back whatever was saved.
///
/// The terminal has to be given back for the duration: an editor that inherits
/// raw mode and the alt screen paints into omfx's buffer instead of its own.
pub fn editDraftExternally(sess: *Session) !void {
    // Settings first: $EDITOR is the machine's answer, the setting is this
    // user's answer for omfx specifically.
    const editor = if (sess.state.editor.len != 0)
        sess.state.editor
    else
        sess.lookup.get("VISUAL") orelse sess.lookup.get("EDITOR") orelse "vi";
    const path = try std.fmt.allocPrint(sess.arena, "{s}/.omfx/draft.txt", .{sess.workspace});
    const dir = try std.fmt.allocPrint(sess.arena, "{s}/.omfx", .{sess.workspace});
    Io.Dir.cwd().createDirPath(sess.io, dir) catch return;
    {
        var f = Io.Dir.cwd().createFile(sess.io, path, .{ .truncate = true }) catch return;
        defer f.close(sess.io);
        var buf: [512]u8 = undefined;
        var w = f.writer(sess.io, &buf);
        w.interface.writeAll(sess.draft.items()) catch {};
        w.interface.flush() catch {};
    }

    // Leave the alt screen and cooked the terminal, or the editor draws into
    // omfx's screen and omfx keeps eating the keystrokes.
    sess.stdout.writeAll(tui.restoreSequence()) catch {};
    sess.stdout.flush() catch {};
    tty.restore();

    var child = std.process.spawn(sess.io, .{
        .argv = &.{ editor, path },
        .cwd = .{ .path = sess.workspace },
    }) catch {
        _ = tty.Raw.enter();
        return;
    };
    _ = child.wait(sess.io) catch {};

    _ = tty.Raw.enter();
    sess.stdout.writeAll(tui.enter_alt) catch {};
    sess.stdout.flush() catch {};

    const body = Io.Dir.cwd().readFileAlloc(sess.io, path, sess.arena, .limited(256 * 1024)) catch return;
    // A trailing newline is the editor's, not the prompt's.
    try sess.draft.replace(sess.gpa, std.mem.trimEnd(u8, body, "\n\r"));
    // Scratch only — do not leave draft.txt polluting the workspace tree.
    Io.Dir.cwd().deleteFile(sess.io, path) catch {};
}

/// Everything about this session, in one readable frame.
///
/// `/status` printed a `key=value` block into the transcript; the same facts in
/// a panel read as a dashboard and dismiss cleanly.
pub fn statusPanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    var p = panel_mod.Panel{ .title = "Status" };
    p.add(.{ .key = "", .label = "Model", .kind = .info, .value = sess.model() });
    p.add(.{
        .key = "",
        .label = "Provider",
        .kind = .info,
        .value = if (sess.state.resolved) |r| r.spec.id else "(none)",
    });
    p.add(.{ .key = "", .label = "Permissions", .kind = .info, .value = cmds.footerPerm(&sess.state) });
    p.add(.{
        .key = "",
        .label = "Sandbox",
        .kind = .info,
        .value = if (settings.sandboxOff(cfg)) "off" else "on",
    });
    p.add(.{ .key = "", .label = "Workspace", .kind = .info, .value = sess.workspace });
    p.add(.{
        .key = "",
        .label = "Session",
        .kind = .info,
        .value = if (sess.state.session_title.len > 0) sess.state.session_title else "(unsaved)",
    });
    p.add(.{
        .key = "",
        .label = "Background jobs",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{jobs.count()}) catch "0",
    });
    p.add(.{
        .key = "",
        .label = "Extra dirs",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{sess.state.extraSlice().len}) catch "0",
    });
    return p;
}

/// Background commands, with log size as soft progress.
pub fn jobsPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Background work" };
    var snap: [jobs.max_jobs]jobs.Job = undefined;
    for (jobs.snapshot(&snap)) |j| {
        const rel = jobs.logRel(sess.arena, j.id) catch "";
        const bytes = jobs.logBytes(sess.io, sess.workspace, j.id);
        const cap: u64 = @max(bytes, 64 * 1024);
        var bar_buf: [128]u8 = undefined;
        const bar = progress.render(&bar_buf, 48, bytes, cap, if (jobs.running(j)) "working" else "finished");
        p.add(.{
            .key = std.fmt.allocPrint(sess.arena, "/background kill {d}", .{j.id}) catch "",
            .label = std.fmt.allocPrint(sess.arena, "{d}  {s}", .{ j.id, if (jobs.running(j)) "still working" else "finished" }) catch "",
            .kind = .pick,
            .value = j.command(),
            .help = std.fmt.allocPrint(sess.arena, "{s} · {s} · enter stops it", .{ bar, rel }) catch "",
        });
    }
    if (p.n == 0) p.add(.{
        .key = "",
        .label = "Nothing running in the background",
        .kind = .info,
        .help = "Long commands can keep going while you chat",
    });
    p.selectFirst();
    return p;
}

/// Review the last plan: approve runs /plan go; lines are read-only checklist.
pub fn planPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Your plan" };
    const plan = if (sess.state.last_plan.len != 0) sess.state.last_plan else sess.state.last_reply;
    if (plan.len == 0) {
        p.add(.{
            .key = "",
            .label = "No plan yet",
            .kind = .info,
            .help = "Start plan mode, ask what you want, then come back here",
        });
        p.add(.{
            .key = "/plan on",
            .label = "Start planning",
            .kind = .pick,
            .help = "Looks around and drafts a plan — no changes until you say go",
        });
    } else {
        p.add(.{
            .key = "/plan go",
            .label = "Looks good — do it",
            .kind = .pick,
            .help = "Leaves plan mode and carries out the steps below",
        });
        p.add(.{
            .key = "/plan off",
            .label = "Keep planning",
            .kind = .pick,
            .help = "Stay in plan mode and keep refining",
        });
        p.add(.{ .key = "", .label = "Steps", .kind = .heading });
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, plan, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            if (n >= 40) {
                p.add(.{
                    .key = "",
                    .label = "…and more",
                    .kind = .info,
                    .help = "Only the first steps fit here",
                });
                break;
            }
            p.add(.{ .key = "", .label = t, .kind = .info });
            n += 1;
        }
    }
    p.selectFirst();
    return p;
}

/// Workspace file picker — picking inserts @path into the draft via the key.
pub fn filesPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Pick a file", .search = true };
    var store: [64][96]u8 = undefined;
    var rows: [64]slash.Spec = undefined;
    const n = tui.matchAt(Io.Dir.cwd(), sess.io, sess.arena, "", &store, rows[0..]);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = rows[i].name;
        p.add(.{
            .key = std.fmt.allocPrint(sess.arena, "@{s} ", .{name}) catch "",
            .label = name,
            .kind = .pick,
            .help = "enter adds this file to what you are typing",
        });
    }
    if (p.n == 0) p.add(.{
        .key = "",
        .label = "No files found here",
        .kind = .info,
        .help = "Type to search, or check you are in the right folder",
    });
    p.selectFirst();
    return p;
}

/// Peer / board status — goals and recent board notes.
pub fn peersPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Teammates" };
    p.add(.{
        .key = "",
        .label = "How it works",
        .kind = .info,
        .help = "A teammate works on a goal in the background. Turn Auto teammates on in Settings if you want that by default.",
    });
    if (sess.state.last_goal.len != 0) {
        p.add(.{ .key = "", .label = "Last goal", .kind = .info, .value = sess.state.last_goal });
    }
    p.add(.{
        .key = "/peers ",
        .label = "Ask a teammate…",
        .kind = .pick,
        .help = "Then type what you want them to do",
    });
    p.add(.{ .key = "", .label = "Shared notes", .kind = .heading });
    const raw = board.loadTail(sess.arena, sess.io, sess.workspace);
    var notes: [board.max_notes]board.Note = undefined;
    const nn = board.parseAll(raw, &notes);
    if (nn == 0) {
        p.add(.{
            .key = "",
            .label = "No shared notes yet",
            .kind = .info,
            .help = "Notes appear here when teammates leave updates",
        });
    } else {
        var i: usize = nn;
        var shown: usize = 0;
        while (i > 0 and shown < 12) {
            i -= 1;
            const note = notes[i];
            const kind_label: []const u8 = switch (note.kind) {
                .fact => "Note",
                .fail => "Problem",
                .path => "File",
            };
            p.add(.{
                .key = "",
                .label = kind_label,
                .kind = .info,
                .value = note.text,
            });
            shown += 1;
        }
    }
    p.selectFirst();
    return p;
}

/// The workspace root and any extra directories the agent may touch.
pub fn workspacePanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Workspace" };
    p.add(.{ .key = "", .label = "Root", .kind = .info, .value = sess.workspace });
    if (sess.state.extraSlice().len == 0) {
        p.add(.{ .key = "", .label = "No extra folders", .kind = .info, .help = "Add one with /workspace add <folder>" });
    } else {
        p.add(.{ .key = "", .label = "Extra", .kind = .heading });
        for (sess.state.extraSlice()) |d| p.add(.{ .key = "", .label = d, .kind = .info });
    }
    return p;
}

/// Which facts the status line shows, and where.
///
/// One toggle per field plus a placement choice, because "which of these eight
/// do I want" is a form, not a command line to memorise.
pub fn statuslinePanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    const sl = statusline_mod.parse(cfg.statusline_place, cfg.statusline_fields);

    var p = panel_mod.Panel{ .title = "Status line" };
    p.add(.{
        .key = "statusline_place",
        .label = "Show in",
        .kind = .{ .choice = &.{ "footer", "header", "both" } },
        .value = sl.place.asSlice(),
        .help = "footer sits by the composer, header across the top",
    });
    p.add(.{ .key = "", .label = "Fields", .kind = .heading });
    inline for (comptime std.meta.tags(statusline_mod.Field)) |f| {
        p.add(.{
            .key = "field:" ++ @tagName(f),
            .label = @tagName(f),
            .kind = .toggle,
            .value = if (sl.has(f)) "on" else "off",
            .help = fieldHelp(f),
        });
    }
    p.selectFirst();
    return p;
}

pub fn fieldHelp(f: statusline_mod.Field) []const u8 {
    return switch (f) {
        .model => "the model answering this turn",
        .mode => "normal, plan, or yolo",
        .workspace => "the directory omfx is rooted at",
        .branch => "current git branch, when the workspace is a repo",
        .tokens => "tokens spent in this session",
        .session => "session id, for /resume",
        .peers => "how many teammates are running",
        .jobs => "how many background commands are alive",
    };
}

/// Every slash command, grouped, as a panel you arrow through.
///
/// `/help` printed fifty lines into the transcript, which pushed the whole
/// conversation off screen to read a reference you then had to scroll back
/// past. A panel is the same list you can act on and dismiss.
/// Every binding, grouped, searchable, each with a page of its own.
///
/// The inline `?` list answers "what was that key again"; this answers "what
/// can I do here", which is a different question and needs room to say it.
pub fn keysPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Keys" };
    const q = sess.panel_edit.items;
    var section: []const u8 = "";
    for (tui.key_rows) |row| {
        if (!keyMatches(q, row)) continue;
        if (!std.mem.eql(u8, section, row.section)) {
            section = row.section;
            p.add(.{ .key = "", .label = row.section, .kind = .heading });
        }
        p.add(.{
            .key = row.name,
            .label = row.name,
            .kind = .entry,
            .value = row.help,
            .help = row.help,
            .detail = row.detail,
        });
    }
    if (p.n == 0) p.add(.{ .key = "", .label = "Nothing matches what you typed", .kind = .info });
    p.selectFirst();
    return p;
}

pub fn keyMatches(q: []const u8, row: tui.KeyRow) bool {
    if (q.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(row.name, q) != null or
        std.ascii.indexOfIgnoreCase(row.help, q) != null or
        std.ascii.indexOfIgnoreCase(row.section, q) != null;
}

pub fn lessThanSpec(_: void, a: slash.Spec, b: slash.Spec) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn helpPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Commands" };
    const q = sess.panel_edit.items;
    for (slash.groups) |grp| {
        // A heading with nothing under it is noise, so the group is only
        // opened once a row in it survives the filter.
        var titled = false;
        for (grp.names) |name| {
            const spec = slash.find(name) orelse continue;
            if (!commandMatches(q, spec)) continue;
            if (!titled) {
                titled = true;
                p.add(.{ .key = "", .label = grp.title, .kind = .heading });
            }
            p.add(.{ .key = spec.name, .label = spec.name, .kind = .pick, .value = spec.help });
        }
    }
    if (p.n == 0) p.add(.{ .key = "", .label = "Nothing matches what you typed", .kind = .info });
    p.selectFirst();
    return p;
}

/// Name or description, case-insensitively: you look a command up by what it
/// is called or by what it does, and only one of those is in front of you.
pub fn commandMatches(q: []const u8, spec: slash.Spec) bool {
    if (q.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(spec.name, q) != null or
        std.ascii.indexOfIgnoreCase(spec.help, q) != null;
}

/// Where the context window has gone.
///
/// The total is the provider's own count, cache included. The parts under it
/// are bytes omfx measured divided by `bytes_per_token`: the system prompt
/// and the tool schemas are strings this binary holds, so their size is known
/// exactly even though their token count is not. Messages is what is left,
/// which is the number people actually want and the one no API reports.
pub fn contextPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Context window" };
    const window = sess.ctx_window;
    if (window == 0) {
        p.add(.{ .key = "", .label = "no window reported yet", .kind = .info });
        return p;
    }
    const used = sess.ctx_used;
    const sys = sess.trace_sys / bytes_per_token;
    const tools = sess.trace_tools / bytes_per_token;
    // The fixed floor cannot exceed what the provider says is in the window.
    const fixed = @min(sys + tools, used);
    const messages = used - fixed;

    p.add(.{
        .key = "",
        .label = "Total",
        .kind = .info,
        .value = contextRow(sess, used, window),
    });
    p.add(.{ .key = "", .label = "Messages", .kind = .info, .value = contextRow(sess, messages, window) });
    p.add(.{ .key = "", .label = "System prompt", .kind = .info, .value = contextRow(sess, @min(sys, used), window) });
    p.add(.{ .key = "", .label = "Tool schemas", .kind = .info, .value = contextRow(sess, @min(tools, used -| sys), window) });
    p.add(.{
        .key = "",
        .label = "Free space",
        .kind = .info,
        .value = contextRow(sess, window -| used, window),
    });
    addCacheRows(sess, &p);
    return p;
}

/// What the last turn cost, split the way the provider bills it.
///
/// The hit rate is cache reads over the whole prompt, which is the number that
/// decides the bill: a read is a tenth of the price of fresh input, and a
/// write is a quarter more. Providers report the three separately for exactly
/// this reason, so they are shown separately rather than summed into one
/// "cached" figure that hides which way it went.
pub fn addCacheRows(sess: *Session, p: *panel_mod.Panel) void {
    const read = sess.ctx_cache_read;
    const write = sess.ctx_cache_write;
    const fresh = sess.ctx_fresh;
    const prompt = fresh +| read +| write;
    if (prompt == 0) return;

    p.add(.{ .key = "", .label = "", .kind = .info });
    const pct = @as(u64, read) * 100 / prompt;
    var buf: [24]u8 = undefined;
    p.add(.{
        .key = "",
        .label = "Served from cache",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{s} of the last prompt ({d}%)", .{
            tui.shortTokens(&buf, read),
            pct,
        }) catch "",
    });
    var fresh_buf: [24]u8 = undefined;
    p.add(.{
        .key = "",
        .label = "Read fresh",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{s}", .{tui.shortTokens(&fresh_buf, fresh)}) catch "",
    });
    if (write > 0) {
        var w_buf: [24]u8 = undefined;
        p.add(.{
            .key = "",
            .label = "Written to cache",
            .kind = .info,
            .value = std.fmt.allocPrint(sess.arena, "{s}, readable on the next turn", .{
                tui.shortTokens(&w_buf, write),
            }) catch "",
        });
    }
    if (read == 0 and write == 0) {
        p.add(.{ .key = "", .label = "", .kind = .info, .value = "This provider reported no caching." });
    }
}

/// Receipt: measured over this repo's own session files, one token averages
/// 3.9 bytes of prompt text. Four is the round number either side of that,
/// and the parts it sizes are labelled as omfx's own measurement rather than
/// as anything a provider counted.
const bytes_per_token: u32 = 4;

pub fn contextRow(sess: *Session, tokens: u32, window: u32) []const u8 {
    const pct = if (window == 0) 0 else @as(u64, tokens) * 100 / window;
    var buf: [24]u8 = undefined;
    return std.fmt.allocPrint(sess.arena, "{s} ({d}%)", .{ tui.shortTokens(&buf, tokens), pct }) catch "";
}

/// The prompts of this session, newest first, as points to go back to.
///
/// A list you pick from rather than a number you count out: what you remember
/// is what you asked, not how many turns ago you asked it.
pub fn rewindPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Go back to a message" };
    const state = &sess.state;
    if (state.marks_n == 0) {
        p.add(.{
            .key = "",
            .label = "Nothing to go back to yet",
            .kind = .info,
            .help = "Messages you send will show up here",
        });
        return p;
    }
    var i: usize = state.marks_n;
    while (i > 0) {
        i -= 1;
        const steps = state.marks_n - i;
        // The key is the command the pick runs: choosing a row fills the
        // composer with it, which is the same route every other panel takes.
        const key = std.fmt.allocPrint(sess.arena, "/rewind {d}", .{steps}) catch continue;
        const back = if (steps == 1)
            "1 turn back"
        else
            std.fmt.allocPrint(sess.arena, "{d} turns back", .{steps}) catch "back";
        p.add(.{
            .key = key,
            .label = sess.arena.dupe(u8, state.marks[i].previewSlice()) catch continue,
            .kind = .pick,
            .value = back,
        });
    }
    p.selectFirst();
    return p;
}

/// Saved sessions, newest first, with when they last changed and how far they got.
pub fn sessionPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Resume a session" };
    const dir_path = std.fs.path.join(sess.arena, &.{ sess.home, ".omfx", "sessions" }) catch return p;
    var dir = Io.Dir.cwd().openDir(sess.io, dir_path, .{ .iterate = true }) catch {
        p.add(.{ .key = "", .label = "No saved chats yet", .kind = .info });
        return p;
    };
    defer dir.close(sess.io);
    const idlist = session.listIds(dir, sess.io, sess.arena) catch return p;

    const Entry = struct { id: []const u8, mtime: i128, asked: []const u8, turns: usize, when: []const u8 };
    var rows: [panel_mod.max_fields]Entry = undefined;
    var n: usize = 0;
    for (idlist) |id| {
        if (n == rows.len) break;
        const path = session.sessionPath(sess.arena, sess.home, session.resolveId(id)) catch continue;
        const blob = Io.Dir.cwd().readFileAlloc(sess.io, path, sess.arena, .limited(64_000)) catch continue;
        const st = Io.Dir.cwd().statFile(sess.io, path, .{}) catch continue;
        var when_buf: [32]u8 = undefined;
        const when = sess.arena.dupe(u8, session.formatWhen(&when_buf, sess.io, path)) catch "";
        rows[n] = .{
            .id = id,
            .mtime = st.mtime.toNanoseconds(),
            .asked = session.firstUser(blob),
            .turns = std.mem.count(u8, blob, "\"kind\":\"user\""),
            .when = when,
        };
        n += 1;
    }
    std.mem.sort(Entry, rows[0..n], {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.less);

    for (rows[0..n]) |row| {
        const turns = std.fmt.allocPrint(sess.arena, "{d} turn{s}", .{
            row.turns,
            if (row.turns == 1) "" else "s",
        }) catch "";
        const meta = if (row.when.len != 0)
            std.fmt.allocPrint(sess.arena, "{s}  ·  {s}", .{ row.when, turns }) catch turns
        else
            turns;
        p.add(.{
            .key = std.fmt.allocPrint(sess.arena, "/resume {s}", .{row.id}) catch row.id,
            .label = if (row.asked.len != 0) sess.arena.dupe(u8, row.asked) catch row.id else row.id,
            .kind = .pick,
            .value = meta,
            .help = "enter opens  ·  del deletes forever  ·  up/down moves  ·  esc closes",
        });
    }
    if (p.n == 0) p.add(.{ .key = "", .label = "No saved chats yet", .kind = .info });
    p.selectFirst();
    return p;
}
