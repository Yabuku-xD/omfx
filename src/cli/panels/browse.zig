const std = @import("std");
const Io = std.Io;

const tui = @import("../tui.zig");
const panel_mod = @import("../panel.zig");
const cmds = @import("../cmds.zig");
const jobs = @import("../../tools/jobs.zig");
const slash = @import("../../core/slash.zig");
const settings = @import("../../core/settings.zig");
const session = @import("../../core/session.zig");
const board = @import("../../core/board.zig");
const progress = @import("../progress.zig");

const session_mod = @import("../repl/session.zig");
const runlog = @import("../../core/runlog.zig");
const cli = @import("../../core/cli.zig");

const Session = session_mod.Session;
const UsageTab = cmds.UsageTab;

pub const usage_tab_labels = [_][]const u8{ "Context usage", "Usage limit", "Session info" };

const bytes_per_token: u32 = 4;

pub fn usagePanel(sess: *Session) panel_mod.Panel {
    return usagePanelFrom(.{
        .arena = sess.arena,
        .io = sess.io,
        .home = sess.home,
        .workspace = sess.workspace,
        .model = sess.model(),
        .provider = if (sess.state.resolved) |r| r.spec.id else "(none)",
        .session_title = sess.state.session_title,
        .ctx_used = sess.ctx_used,
        .ctx_window = sess.ctx_window,
        .trace_sys = sess.trace_sys,
        .trace_tools = sess.trace_tools,
        .ctx_fresh = sess.ctx_fresh,
        .ctx_cache_read = sess.ctx_cache_read,
        .ctx_cache_write = sess.ctx_cache_write,
    }, sess.usage_tab);
}

pub const UsageView = struct {
    arena: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
    model: []const u8,
    provider: []const u8,
    session_title: []const u8,
    ctx_used: u32,
    ctx_window: u32,
    trace_sys: u32,
    trace_tools: u32,
    ctx_fresh: u32,
    ctx_cache_read: u32,
    ctx_cache_write: u32,
};

pub fn usagePanelFrom(view: UsageView, tab: UsageTab) panel_mod.Panel {
    var p = panel_mod.Panel{
        .title = "Usage",
        .tabs = &usage_tab_labels,
        .tab_sel = @intFromEnum(tab),
    };
    switch (tab) {
        .context => fillContextTab(view, &p),
        .limit => fillLimitTab(view, &p),
        .session => fillSessionTab(view, &p),
    }
    if (p.n > 0) p.sel = 0;
    return p;
}

fn fillContextTab(view: UsageView, p: *panel_mod.Panel) void {
    const window = view.ctx_window;
    if (window == 0) {
        p.add(.{ .key = "", .label = "No window reported yet", .kind = .info });
        return;
    }
    const used = view.ctx_used;
    const sys = view.trace_sys / bytes_per_token;
    const tools = view.trace_tools / bytes_per_token;
    const fixed = @min(sys + tools, used);
    const messages = used - fixed;
    const pct = @as(u64, used) * 100 / window;

    p.add(.{
        .key = "",
        .label = "Context",
        .kind = .info,
        .value = std.fmt.allocPrint(view.arena, "{s} / {s} tokens ({d}%)", .{
            shortTok(view, used),
            shortTok(view, window),
            pct,
        }) catch "",
    });
    p.add(.{ .key = "", .label = "Model", .kind = .info, .value = view.model });
    addContextGrid(view, p, used, window);
    p.add(.{ .key = "", .label = "", .kind = .info });
    p.add(.{ .key = "", .label = "Messages", .kind = .info, .value = contextRowAlloc(view, messages, window) });
    p.add(.{ .key = "", .label = "System prompt", .kind = .info, .value = contextRowAlloc(view, @min(sys, used), window) });
    p.add(.{ .key = "", .label = "Tool schemas", .kind = .info, .value = contextRowAlloc(view, @min(tools, used -| sys), window) });
    p.add(.{ .key = "", .label = "Free", .kind = .info, .value = contextRowAlloc(view, window -| used, window) });
    addCacheRowsFrom(view, p);
    if (used * 100 / window >= 80) {
        const remain = window -| used;
        p.add(.{
            .key = "",
            .label = "Auto-compact",
            .kind = .info,
            .value = std.fmt.allocPrint(view.arena, "at 80% — {s} tokens remaining", .{shortTok(view, remain)}) catch "",
        });
    }
    const c = runlog.compare(view.arena, view.io, view.home);
    if (c.now.turns != 0) {
        p.add(.{
            .key = "",
            .label = "Turns",
            .kind = .info,
            .value = std.fmt.allocPrint(view.arena, "{d}  ·  {d} tool calls", .{ c.now.turns, c.now.tools }) catch "",
        });
    }
}

fn fillLimitTab(view: UsageView, p: *panel_mod.Panel) void {
    p.add(.{ .key = "", .label = "Session usage", .kind = .heading, .value = "" });
    const path = session.sessionPath(view.arena, view.home, session.resolveId("last")) catch "";
    const blob = if (path.len != 0)
        Io.Dir.cwd().readFileAlloc(view.io, path, view.arena, .limited(1_000_000)) catch ""
    else
        "";
    var user_n: usize = 0;
    var asst_n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, "\"kind\":\"user\"") != null) user_n += 1;
        if (std.mem.indexOf(u8, l, "\"kind\":\"assistant\"") != null) asst_n += 1;
    }
    p.add(.{
        .key = "",
        .label = "Transcript",
        .kind = .info,
        .value = std.fmt.allocPrint(view.arena, "{d} chars  ·  {d} user  ·  {d} assistant", .{
            blob.len, user_n, asst_n,
        }) catch "",
    });
    const c = runlog.compare(view.arena, view.io, view.home);
    if (c.now.turns == 0) {
        p.add(.{ .key = "", .label = "Turn log", .kind = .info, .value = "No turns recorded yet" });
    } else {
        p.add(.{
            .key = "",
            .label = std.fmt.allocPrint(view.arena, "Last {d} turns", .{c.now.turns}) catch "Recent turns",
            .kind = .info,
            .value = std.fmt.allocPrint(view.arena, "{d}ms avg  ·  {d} tokens avg  ·  {d} tools  ·  {d} not clean", .{
                c.now.avgMs(),
                c.now.avgTokens(),
                c.now.tools,
                c.now.denied,
            }) catch "",
        });
        if (c.before.turns != 0) {
            p.add(.{
                .key = "",
                .label = std.fmt.allocPrint(view.arena, "Previous {d}", .{c.before.turns}) catch "Previous",
                .kind = .info,
                .value = std.fmt.allocPrint(view.arena, "{d}ms avg  ·  {d} tokens avg  ·  {d} tools  ·  {d} not clean", .{
                    c.before.avgMs(),
                    c.before.avgTokens(),
                    c.before.tools,
                    c.before.denied,
                }) catch "",
            });
        }
    }
    p.add(.{
        .key = "",
        .label = "Log file",
        .kind = .info,
        .value = std.fmt.allocPrint(view.arena, "~/.omfx/{s}", .{runlog.file_name}) catch "",
    });
}

fn fillSessionTab(view: UsageView, p: *panel_mod.Panel) void {
    p.add(.{ .key = "", .label = "Shell", .kind = .info, .value = std.fmt.allocPrint(view.arena, "omfx {s}", .{cli.version}) catch "" });
    p.add(.{
        .key = "",
        .label = "Session",
        .kind = .info,
        .value = if (view.session_title.len > 0) view.session_title else "(unsaved)",
    });
    p.add(.{ .key = "", .label = "Working directory", .kind = .info, .value = view.workspace });
    p.add(.{ .key = "", .label = "Model", .kind = .info, .value = view.model });
    p.add(.{ .key = "", .label = "Provider", .kind = .info, .value = view.provider });
    if (view.ctx_window != 0) {
        p.add(.{
            .key = "",
            .label = "Context",
            .kind = .info,
            .value = std.fmt.allocPrint(view.arena, "{s} / {s} ({d}%)", .{
                shortTok(view, view.ctx_used),
                shortTok(view, view.ctx_window),
                @as(u64, view.ctx_used) * 100 / view.ctx_window,
            }) catch "",
        });
    }
}

fn shortTok(view: UsageView, tokens: u32) []const u8 {
    var buf: [24]u8 = undefined;
    return view.arena.dupe(u8, tui.shortTokens(&buf, tokens)) catch "-";
}

fn contextRowAlloc(view: UsageView, tokens: u32, window: u32) []const u8 {
    const pct = if (window == 0) 0 else @as(u64, tokens) * 100 / window;
    return std.fmt.allocPrint(view.arena, "{s} ({d}%)", .{ shortTok(view, tokens), pct }) catch "";
}

fn addContextGrid(view: UsageView, p: *panel_mod.Panel, used: u32, window: u32) void {
    if (window == 0) return;
    const filled: usize = @min(@as(usize, used * 100 / window), 100);
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (i > 0 and i % 20 == 0 and n + 1 < buf.len) {
            buf[n] = '\n';
            n += 1;
        }
        const ch: u8 = if (i < filled) '#' else '.';
        if (n + 1 < buf.len) {
            buf[n] = ch;
            n += 1;
        }
    }
    p.add(.{
        .key = "",
        .label = "",
        .kind = .info,
        .value = view.arena.dupe(u8, buf[0..n]) catch "",
    });
}

fn addCacheRowsFrom(view: UsageView, p: *panel_mod.Panel) void {
    const read = view.ctx_cache_read;
    const write = view.ctx_cache_write;
    const fresh = view.ctx_fresh;
    const prompt = fresh +| read +| write;
    if (prompt == 0) return;

    p.add(.{ .key = "", .label = "", .kind = .info });
    const pct = @as(u64, read) * 100 / prompt;
    p.add(.{
        .key = "",
        .label = "Served from cache",
        .kind = .info,
        .value = std.fmt.allocPrint(view.arena, "{s} of the last prompt ({d}%)", .{
            shortTok(view, read),
            pct,
        }) catch "",
    });
    p.add(.{
        .key = "",
        .label = "Read fresh",
        .kind = .info,
        .value = shortTok(view, fresh),
    });
    if (write > 0) {
        p.add(.{
            .key = "",
            .label = "Written to cache",
            .kind = .info,
            .value = std.fmt.allocPrint(view.arena, "{s}, readable on the next turn", .{
                shortTok(view, write),
            }) catch "",
        });
    }
    if (read == 0 and write == 0) {
        p.add(.{ .key = "", .label = "", .kind = .info, .value = "This provider reported no caching." });
    }
}

pub fn contextPanel(sess: *Session) panel_mod.Panel {
    return usagePanel(sess);
}

pub fn addCacheRows(sess: *Session, p: *panel_mod.Panel) void {
    addCacheRowsFrom(.{
        .arena = sess.arena,
        .io = sess.io,
        .home = sess.home,
        .workspace = sess.workspace,
        .model = sess.model(),
        .provider = "",
        .session_title = "",
        .ctx_used = sess.ctx_used,
        .ctx_window = sess.ctx_window,
        .trace_sys = sess.trace_sys,
        .trace_tools = sess.trace_tools,
        .ctx_fresh = sess.ctx_fresh,
        .ctx_cache_read = sess.ctx_cache_read,
        .ctx_cache_write = sess.ctx_cache_write,
    }, p);
}

pub fn contextRow(sess: *Session, tokens: u32, window: u32) []const u8 {
    return contextRowAlloc(.{
        .arena = sess.arena,
        .io = sess.io,
        .home = sess.home,
        .workspace = sess.workspace,
        .model = "",
        .provider = "",
        .session_title = "",
        .ctx_used = 0,
        .ctx_window = window,
        .trace_sys = 0,
        .trace_tools = 0,
        .ctx_fresh = 0,
        .ctx_cache_read = 0,
        .ctx_cache_write = 0,
    }, tokens, window);
}

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

pub fn commandMatches(q: []const u8, spec: slash.Spec) bool {
    if (q.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(spec.name, q) != null or
        std.ascii.indexOfIgnoreCase(spec.help, q) != null;
}

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
