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
const Session = session_mod.Session;

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

const bytes_per_token: u32 = 4;

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

pub fn contextRow(sess: *Session, tokens: u32, window: u32) []const u8 {
    const pct = if (window == 0) 0 else @as(u64, tokens) * 100 / window;
    var buf: [24]u8 = undefined;
    return std.fmt.allocPrint(sess.arena, "{s} ({d}%)", .{ tui.shortTokens(&buf, tokens), pct }) catch "";
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
