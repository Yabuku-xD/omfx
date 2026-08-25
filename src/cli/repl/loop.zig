const std = @import("std");
const Io = std.Io;

const tui = @import("../tui.zig");
const panel_mod = @import("../panel.zig");
const draft_mod = @import("../draft.zig");
const cmds = @import("../cmds.zig");
const skills = @import("../../core/skills.zig");
const todos = @import("../../core/todos.zig");
const slash = @import("../../core/slash.zig");
const session = @import("../../core/session.zig");
const env = @import("../../core/env.zig");
const sink = @import("../../core/sink.zig");
const menus = @import("../menus.zig");
const panels = @import("../panels.zig");
const session_mod = @import("session.zig");
const runs_ui = @import("runs_ui.zig");
const input_mod = @import("input.zig");
const turn_mod = @import("turn.zig");

pub const Session = session_mod.Session;
const nowMs = session_mod.nowMs;

pub const Deps = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    home: []const u8,
    workspace: []const u8,
    lookup: env.Lookup,
    model_name: []const u8,
    stdin: *Io.Reader,
    slash_buf: *[tui.max_slash_hits]slash.Spec,
    at_store: *[32][96]u8,
    exit_eof: *bool,
};

pub fn startSel(sess: *Session, row: u16, col: u16) void {
    sess.dragging = true;
    if (tui.jumpVisible(sess.scroll, sess.layout.transcript_rows) and tui.jumpHit(sess.layout, row, col)) {
        sess.dragging = false;
        sess.clearSel();
        return;
    }
    if (sess.layout.header_rows != 0 and row == 1 and col + 16 > sess.layout.cols) {
        sess.openPanel(panels.build(sess, .context));
        return;
    }
    const at = sess.selPoint(row, col) orelse {
        sess.clearSel();
        runs_ui.blurScrollback(sess);
        return;
    };
    if (at.where == .composer) runs_ui.blurScrollback(sess);
    sess.marked = .{ .where = at.where, .a_row = at.row, .a_col = at.col, .b_row = at.row, .b_col = at.col };
    sess.dirty = true;
}


pub fn openSearchPanel(sess: *Session, kind: cmds.PanelKind) void {
    sess.openPanel(panels.build(sess, kind));
    sess.panel_kind = kind;
    if (sess.panel) |*p| {
        p.search = true;
        p.query = sess.panel_edit.items;
        p.selectFirst();
    }
}

pub fn refilterPanel(sess: *Session) void {
    const kind = sess.panel_kind orelse return;
    var next = panels.build(sess, kind);
    next.search = true;
    next.query = sess.panel_edit.items;
    next.selectFirst();
    sess.panel = next;
    sess.dirty = true;
}


pub fn skillSpecs(sess: *Session) []const slash.Spec {
    const names = skills.listAllNames(sess.arena, sess.io, Io.Dir.cwd(), sess.home, sess.workspace) catch return &.{};
    const out = sess.arena.alloc(slash.Spec, names.len) catch return &.{};
    var n: usize = 0;
    for (names) |name| {
        const cmd = std.fmt.allocPrint(sess.arena, "/{s}", .{name}) catch continue;
        const path = skills.pathOf(sess.arena, sess.io, sess.home, sess.workspace, name);
        const help = if (path) |p| skills.describe(sess.arena, sess.io, p) else "";
        out[n] = .{ .name = cmd, .help = if (help.len != 0) help else "skill" };
        n += 1;
    }
    std.mem.sort(slash.Spec, out[0..n], {}, panels.lessThanSpec);
    return out[0..n];
}

pub fn panelKey(sess: *Session, ev: tui.Event) bool {
    const p = &(sess.panel orelse return false);
    const gpa = sess.gpa;

    if (p.editing) {
        switch (ev) {
            .enter => {
                panels.applyPanelField(sess, p.*, sess.panel_edit.items);
                p.editing = false;
            },
            .esc => p.editing = false,
            .backspace => {
                if (sess.panel_edit.items.len > 0) _ = sess.panel_edit.pop();
            },
            .byte => |b| sess.panel_edit.append(gpa, b) catch {},
            .rune => |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                if (n > 0) sess.panel_edit.appendSlice(gpa, buf[0..n]) catch {};
            },
            else => {},
        }
        return true;
    }

    // An open page owns the keyboard: the list is behind it, not beside it.
    if (p.detail_of != null) {
        switch (ev) {
            .skip => {},
            .esc, .left, .backspace, .enter, .quit, .interrupt => p.detail_of = null,
            else => {},
        }
        return true;
    }

    if (p.search) {
        switch (ev) {
            .backspace => {
                if (sess.panel_edit.items.len > 0) {
                    _ = sess.panel_edit.pop();
                    refilterPanel(sess);
                }
                return true;
            },
            .byte => |b| if (b >= 0x20 and b < 0x7f) {
                sess.panel_edit.append(gpa, b) catch {};
                refilterPanel(sess);
                return true;
            },
            else => {},
        }
    }

    switch (ev) {
        .skip => return true,
        .esc, .quit, .interrupt => {
            sess.closePanel();
            return true;
        },
        .up, .history_prev => p.move(-1),
        .down, .history_next => p.move(1),
        .left, .right => panels.stepPanelValue(sess, ev == .right),
        .delete => {
            if (sess.panel_kind != .sessions) return true;
            const f = p.current() orelse return true;
            if (f.kind != .pick or f.key.len == 0) return true;
            const id = if (std.mem.startsWith(u8, f.key, "/resume "))
                f.key["/resume ".len..]
            else
                f.key;
            if (id.len == 0) return true;
            const kept = p.sel;
            session.remove(sess.gpa, sess.io, sess.home, sess.workspace, id);
            var next = panels.build(sess, .sessions);
            next.elapsed_ms = panel_mod.open_ms;
            if (next.n > 0) next.sel = @min(kept, next.n - 1);
            sess.panel = next;
            sess.panel_kind = .sessions;
            sess.note("Deleted forever.", nowMs(sess.io));
            sess.dirty = true;
            return true;
        },
        .enter => {
            const f = p.current() orelse return true;
            switch (f.kind) {
                .toggle => panels.togglePanelField(sess),
                .text => {
                    p.editing = true;
                    sess.panel_edit.clearRetainingCapacity();
                    sess.panel_edit.appendSlice(gpa, f.value) catch {};
                },
                // Choosing a row runs it: the panel closes and the command it
                // names is fed back through the normal dispatch.
                .pick => {
                    sess.panel_pick = sess.arena.dupe(u8, f.key) catch "";
                    sess.closePanel();
                },
                // A binding is read, not run: Enter opens its page.
                .entry => p.detail_of = p.sel,
                else => {},
            }
        },
        .byte => |b| if (b == ' ') panels.togglePanelField(sess),
        else => {},
    }
    return true;
}
pub fn run(sess: *Session, deps: Deps) !void {
    const state = &sess.state;
    const gpa = deps.gpa;
    const arena = deps.arena;
    const io = deps.io;
    const stdout = deps.stdout;
    const home = deps.home;
    const workspace = deps.workspace;
    const lookup = deps.lookup;
    const model_name = deps.model_name;
    const stdin = deps.stdin;
    const slash_buf = deps.slash_buf;
    const at_store = deps.at_store;
    const exit_eof = deps.exit_eof;

    while (true) {
        const model = if (state.resolved) |r| r.model else model_name;
        if (state.skills_stale) {
            state.skills_stale = false;
            sess.skill_specs = skillSpecs(sess);
        }
        if (sess.dirty) {
            const plain_comp = try std.fmt.allocPrint(gpa, "{s}{s}", .{ state.composer, sess.draft.items() });
            defer gpa.free(plain_comp);
            const ghost = tui.slashGhost(sess.draft.items(), sess.draft.cur);
            const shown_comp = plain_comp;
            const draft_items = sess.draft.items();
            if (state.pick.kind != .none and (draft_items.len == 0 or draft_items[0] != '/')) {
                sess.palette = slash_buf[0..(state.pick.match(draft_items, slash_buf[0..]))];
            } else {
                sess.palette = slash_buf[0..(tui.matchKeys(draft_items, slash_buf[0..]))];
                if (sess.palette.len == 0) sess.palette = slash_buf[0..(tui.matchSlash(draft_items, slash_buf[0..], sess.skill_specs))];
                if (sess.palette.len == 0) {
                    if (tui.atPrefix(draft_items)) |pre| {
                        sess.palette = slash_buf[0..(tui.matchAt(Io.Dir.cwd(), io, arena, pre, at_store, slash_buf[0..]))];
                    }
                }
            }
            if (sess.palette.len == 0) sess.palette_sel = 0 else if (sess.palette_sel >= sess.palette.len) sess.palette_sel = sess.palette.len - 1;
            // Scrollback focus repaints the whole pane even without a status
            // line: the hint row has to say which keys are live.
            if (state.statusline or sess.focus == .scrollback or tui.jumpVisible(sess.scroll, sess.layout.transcript_rows)) {
                var hint_buf: [256]u8 = undefined;
                const armed = sess.arm.note(nowMs(io));
                const hint: tui.Hint = if (armed.len > 0)
                    .{ .text = armed }
                else if (sess.focus == .scrollback)
                    .{ .text = tui.scrollbackHint(&hint_buf, sess.layout.cols) }
                else if (sess.multiline)
                    .{ .text = "multiline on   shift-enter send" }
                else
                    .auto;
                const toast_line = sess.toasts.line(gpa, sess.layout.cols, nowMs(io)) catch "";
                defer if (toast_line.len != 0) gpa.free(toast_line);
                var todo_rows: [todos.max_items][]const u8 = undefined;
                try tui.writePane(gpa, stdout, sess.layout, .{
                    .model = model,
                    .permission = cmds.footerPerm(state),
                    .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
                    .context_used = sess.ctx_used,
                    .context_window = sess.ctx_window,
                    .composer = shown_comp,
                    .ghost = ghost,
                    .caret = state.composer.len + sess.draft.cur,
                    .place = workspace,
                    .slash = sess.palette,
                    .slash_sel = sess.palette_sel,
                    .hint = hint,
                    .sel = sess.marked,
                    .toast = toast_line,
                    .jump = tui.jumpVisible(sess.scroll, sess.layout.transcript_rows),
                    .tasks = sess.pinTodos(&todo_rows),
                }, &sess.shown, sess.scroll);
                sess.publishJumpHit();
            } else {
                try stdout.writeAll(tui.sync_begin);
                try stdout.writeAll(sess.cups.toFooter());
                try stdout.writeAll("\x1b[2K");
                try stdout.writeAll(shown_comp);
                try stdout.writeAll(tui.sync_end);
                sink.setJumpHit(false, 0, 0, 0);
            }
            try stdout.flush();
            sess.dirty = false;
        }

        // A panel owns the keyboard while it is up. Polling at the frame
        // budget rather than 64ms keeps the reveal smooth, and drops back to
        // the idle rate the moment the animation settles.
        if (sess.panel != null) {
            const more = sess.paintPanel();
            const wait: i32 = if (more) @intCast(panel_mod.frame_ms) else 64;
            const pev = tui.pollEvent(stdin, wait);
            if (panelKey(sess, pev)) continue;
        }
        // A row chosen in a panel runs as if it had been typed, so picking
        // `/model` from `/help` behaves exactly like typing it.
        if (sess.panel_pick.len > 0) {
            const picked = sess.panel_pick;
            sess.panel_pick = "";
            try sess.draft.replace(gpa, picked);
            sess.dirty = true;
            continue;
        }

        const ev = if (sess.steer_send) blk: {
            sess.steer_send = false;
            break :blk tui.Event.enter;
        } else tui.pollEvent(stdin, 64);
        const tag = std.meta.activeTag(ev);
        if (tag != .skip and tag != .shift_tab and !state.pending.awaitingInput()) sess.noteClear();
        // Nothing was typed, so nothing else will repaint: the note has to ask
        // for the frame that takes it back down.
        if (tag == .skip) {
            const now = nowMs(io);
            if (sess.noteExpired(now) and !state.pending.awaitingInput()) {
                sess.noteClear();
                sess.dirty = true;
            }
            // The arm's own window has passed, so the hint it put up is
            // describing a key that no longer does that.
            if (sess.arm.expired(sess.arm.ttl(), now)) {
                sess.arm.clear();
                sess.dirty = true;
            }
        }
        // Scrollback focus owns the keyboard the way a panel does, so it has to
        // answer before the composer sees a key it would insert.
        if (sess.focus == .scrollback and input_mod.scrollbackKey(sess, ev)) continue;
        switch (ev) {
            .skip => continue,
            // Turn jumps belong to the scrollback; in the composer a shifted
            // arrow is not a caret move, so it does nothing rather than
            // guessing.
            .shift_left, .shift_right => continue,
            .click => |c| {
                startSel(sess, c.row, c.col);
                continue;
            },
            .drag => |c| {
                sess.extendSel(c.row, c.col);
                continue;
            },
            .release => |c| {
                // Jump pill first: only the button cells, not the rest of the row.
                if (sess.tryJumpClick(c.row, c.col)) {
                    sess.dragging = false;
                    continue;
                }
                // A press that never moved is a click, and a click on a tool
                // run opens it. Deciding here rather than on press is what
                // lets one gesture be both.
                if (!sess.marked.on()) runs_ui.clickRun(sess, c.row) else sess.copySel(gpa);
                sess.dragging = false;
                continue;
            },
            .page_up => {
                if (sess.palette.len > 0) {
                    const step = tui.paletteItemRows(sess.layout, sess.palette.len);
                    sess.palette_sel = if (sess.palette_sel > step) sess.palette_sel - step else 0;
                    sess.dirty = true;
                    continue;
                }
                if (sess.bumpScroll(true, sess.layout.transcript_rows)) sess.dirty = true;
                continue;
            },
            .page_down => {
                if (sess.palette.len > 0) {
                    const step = tui.paletteItemRows(sess.layout, sess.palette.len);
                    sess.palette_sel = @min(sess.palette.len - 1, sess.palette_sel + step);
                    sess.dirty = true;
                    continue;
                }
                if (sess.bumpScroll(false, sess.layout.transcript_rows)) sess.dirty = true;
                continue;
            },
            .scroll_up => {
                if (sess.bumpScroll(true, tui.wheel_step)) sess.dirty = true;
                continue;
            },
            .scroll_down => {
                if (sess.bumpScroll(false, tui.wheel_step)) sess.dirty = true;
                continue;
            },
            .resize => {
                const now = tui.size(sess.layout.rows, sess.layout.cols);
                sess.layout = tui.Layout.compute(now.rows, now.cols);
                sess.cups = tui.Cups.compute(sess.layout);
                if (sess.shown.rowCount() == 0) {
                    tui.writeWelcome(arena, stdout, sess.layout, .{
                        .model = model,
                        .permission = cmds.footerPerm(state),
                        .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
                        .context_used = sess.ctx_used,
                        .context_window = sess.ctx_window,
                        .composer = state.composer,
                        .place = workspace,
                    }) catch {};
                } else {
                    sess.paintTranscript();
                }
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .esc => {
                if (state.pick.kind == .commands and sess.palette_stash.items.len > 0) {
                    try sess.draft.replace(gpa, sess.palette_stash.items);
                    sess.palette_stash.clearRetainingCapacity();
                }
                var pctx = sess.cmdCtx();
                if (cmds.stepPickBack(&pctx)) {
                    if (state.pick.kind == .none) sess.draft.clear();
                    sess.palette = slash_buf[0..(0)];
                    sess.palette_sel = 0;
                    sess.arm.clear();
                    sess.dirty = true;
                    continue;
                }
                if (sess.palette.len > 0) {
                    if (tui.atPrefix(sess.draft.items()) == null) sess.draft.clear();
                    sess.palette = slash_buf[0..(0)];
                    sess.palette_sel = 0;
                    sess.arm.clear();
                    sess.dirty = true;
                    continue;
                }
                const now_ms = nowMs(io);
                _ = now_ms;
                if (sess.draft.items().len != 0) {
                    if (tui.askConfirm(
                        stdin,
                        stdout,
                        gpa,
                        &sess.layout,
                        "Clear what you typed?",
                        "This only clears the box you are typing in. Your chat stays.",
                        "Clear",
                        "Keep typing",
                    )) {
                        sess.draft.clear();
                        sess.palette = slash_buf[0..(0)];
                        sess.palette_sel = 0;
                    }
                    sess.dirty = true;
                    continue;
                }
                if (sess.shown.rowCount() != 0) {
                    if (tui.askConfirm(
                        stdin,
                        stdout,
                        gpa,
                        &sess.layout,
                        "Go back to an earlier message?",
                        "Removes the latest turn from this chat. You can keep typing afterward.",
                        "Go back",
                        "Stay here",
                    )) {
                        var ctx = sess.cmdCtx();
                        _ = try cmds.dispatch(&ctx, "/rewind");
                        sess.paintTranscript();
                        try stdout.flush();
                    }
                    sess.dirty = true;
                    continue;
                }
                continue;
            },
            .up => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel > 0) sess.palette_sel -= 1;
                } else if (sess.draft.items().len == 0) {
                    if (try sess.hist.older(gpa, sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .down => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel + 1 < sess.palette.len) sess.palette_sel += 1;
                } else if (sess.draft.items().len == 0) {
                    if (sess.hist.newer(sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .history_prev => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel > 0) sess.palette_sel -= 1;
                } else if (sess.draft.items().len == 0) {
                    if (try sess.hist.older(gpa, sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .history_next => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel + 1 < sess.palette.len) sess.palette_sel += 1;
                } else if (sess.draft.items().len == 0) {
                    if (sess.hist.newer(sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .tab => {
                if (tui.keysDraft(sess.draft.items())) {
                    sess.dirty = true;
                    continue;
                }
                // Nothing to complete: hand the keyboard to the scrollback, the
                // way Tab does in every other pane-and-prompt TUI.
                if (sess.palette.len == 0 and sess.draft.items().len == 0) {
                    if (runs_ui.focusScrollback(sess)) continue;
                }
                _ = try sess.completePalette();
                sess.dirty = true;
                continue;
            },
            .keys => {
                try sess.hold.flush(gpa, &sess.draft);
                if (tui.keysDraft(sess.draft.items())) sess.draft.clear();
                // ctrl-x on an empty prompt opens the cheatsheet; `?` typed
                // into the composer keeps the inline list it always had.
                openSearchPanel(sess, .shortcuts);
                sess.palette_sel = 0;
                sess.dirty = true;
                continue;
            },
            .shift_tab => {
                sess.note(cmds.cycleSurface(state), nowMs(io));
                var ctx = sess.cmdCtx();
                cmds.persistChat(&ctx);
                sess.arm.clear();
                sess.dirty = true;
                continue;
            },
            .interrupt => break,
            .ctrl_d => {
                if (sess.draft.items().len != 0) {
                    sess.draft.delete();
                    sess.dirty = true;
                    continue;
                }
                if (tui.askConfirm(
                    stdin,
                    stdout,
                    gpa,
                    &sess.layout,
                    "Leave omfx?",
                    "Your chat is saved. You can open it again later.",
                    "Leave",
                    "Stay",
                )) break;
                sess.dirty = true;
                continue;
            },
            .palette => {
                try sess.hold.flush(gpa, &sess.draft);
                if (state.pick.kind == .commands) {
                    if (sess.palette_stash.items.len > 0) try sess.draft.replace(gpa, sess.palette_stash.items);
                    sess.palette_stash.clearRetainingCapacity();
                    state.pick.clear();
                } else {
                    sess.palette_stash.clearRetainingCapacity();
                    try sess.palette_stash.appendSlice(gpa, sess.draft.items());
                    sess.draft.clear();
                    cmds.fillCommands(state);
                    sess.palette_sel = 0;
                }
                sess.dirty = true;
                continue;
            },
            .new_session => {
                if (tui.askConfirm(
                    stdin,
                    stdout,
                    gpa,
                    &sess.layout,
                    "Start a fresh chat?",
                    "This chat is saved. You will see a blank screen to begin again.",
                    "Start fresh",
                    "Keep this chat",
                )) {
                    var ctx = sess.cmdCtx();
                    _ = try cmds.dispatch(&ctx, "/clear");
                    sess.shown.clear();
                    sess.runs.clear();
                    sess.focus = .prompt;
                    sess.scroll = 0;
                    tui.writeWelcome(arena, stdout, sess.layout, .{
                        .model = model,
                        .permission = cmds.footerPerm(state),
                        .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
                        .context_used = sess.ctx_used,
                        .context_window = sess.ctx_window,
                        .composer = state.composer,
                        .place = workspace,
                    }) catch {};
                    try stdout.flush();
                }
                sess.dirty = true;
                continue;
            },
            .quit => {
                if (tui.askConfirm(
                    stdin,
                    stdout,
                    gpa,
                    &sess.layout,
                    "Leave omfx?",
                    "Your chat is saved. You can open it again later.",
                    "Leave",
                    "Stay",
                )) break;
                sess.dirty = true;
                continue;
            },
            .yolo => {
                var ctx = sess.cmdCtx();
                _ = try cmds.dispatch(&ctx, "/yolo");
                cmds.persistChat(&ctx);
                sess.paintTranscript();
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .sessions => {
                var ctx = sess.cmdCtx();
                _ = try cmds.dispatch(&ctx, "/session");
                sess.dirty = true;
                continue;
            },
            .ctrl_m => {
                sess.multiline = !sess.multiline;
                sess.dirty = true;
                continue;
            },
            .ctrl_enter => {
                try sess.hold.flush(gpa, &sess.draft);
                try sess.draft.insert(gpa, '\n');
                sess.dirty = true;
                continue;
            },
            .ctrl_b => {
                sess.draft.left();
                sess.dirty = true;
                continue;
            },
            .ctrl_t => {
                var ctx = sess.cmdCtx();
                try cmds.cycleEffort(&ctx);
                sess.note(std.fmt.allocPrint(sess.arena, "Reasoning set to {s}.", .{
                    if (state.effort.len == 0) cmds.auto_effort else state.effort,
                }) catch "Reasoning changed.", nowMs(io));
                sess.paintTranscript();
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .ctrl_r => {
                sess.draft.redo();
                sess.dirty = true;
                continue;
            },
            .ctrl_j => {
                sess.dirty = true;
                continue;
            },
            .f2 => {
                var ctx = sess.cmdCtx();
                _ = try cmds.dispatch(&ctx, "/settings");
                sess.paintTranscript();
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .newline => {
                try sess.hold.flush(gpa, &sess.draft);
                if (sess.multiline) {
                    // Shift/Alt+Enter sends while sess.multiline is on.
                } else {
                    try sess.draft.insert(gpa, '\n');
                    sess.dirty = true;
                    continue;
                }
            },
            .redraw => {
                var ctx = sess.cmdCtx();
                _ = try cmds.dispatch(&ctx, "/mcp");
                if (sess.shown.rowCount() == 0) {
                    tui.writeWelcome(arena, stdout, sess.layout, .{
                        .model = model,
                        .permission = cmds.footerPerm(state),
                        .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
                        .context_used = sess.ctx_used,
                        .context_window = sess.ctx_window,
                        .composer = state.composer,
                        .place = workspace,
                    }) catch {};
                } else {
                    sess.paintTranscript();
                }
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .yank => {
                try sess.hold.flush(gpa, &sess.draft);
                try sess.draft.yank(gpa);
                sess.dirty = true;
                continue;
            },
            .undo => {
                sess.draft.undo();
                sess.dirty = true;
                continue;
            },
            .redo => {
                sess.draft.redo();
                sess.dirty = true;
                continue;
            },
            .word_left => {
                sess.draft.wordLeft();
                sess.dirty = true;
                continue;
            },
            .word_right => {
                sess.draft.wordRight();
                sess.dirty = true;
                continue;
            },
            // A long prompt belongs in a real editor. ctrl-g (or the bound
            // external-editor key) sends the draft to $EDITOR and loads it back.
            .external_editor => {
                panels.editDraftExternally(sess) catch {};
                sess.dirty = true;
                continue;
            },
            .kill_word_right => {
                sess.draft.killWordRight(gpa);
                sess.dirty = true;
                continue;
            },
            .byte => |b| {
                try sess.hold.push(gpa, &sess.draft, b);
                sess.dirty = true;
                continue;
            },
            .rune => |cp| {
                try sess.hold.flush(gpa, &sess.draft);
                var rune_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &rune_buf) catch {
                    sess.dirty = true;
                    continue;
                };
                try sess.draft.insertSlice(gpa, rune_buf[0..n]);
                sess.dirty = true;
                continue;
            },
            .backspace => {
                try sess.hold.flush(gpa, &sess.draft);
                sess.draft.backspace();
                sess.dirty = true;
                continue;
            },
            .delete => {
                try sess.hold.flush(gpa, &sess.draft);
                sess.draft.delete();
                sess.dirty = true;
                continue;
            },
            .left => {
                sess.draft.left();
                sess.dirty = true;
                continue;
            },
            .right => {
                sess.draft.right();
                sess.dirty = true;
                continue;
            },
            .home => {
                if (sess.palette.len > 0) {
                    sess.palette_sel = 0;
                } else {
                    sess.draft.home();
                }
                sess.dirty = true;
                continue;
            },
            .end => {
                if (sess.palette.len > 0) {
                    sess.palette_sel = sess.palette.len - 1;
                } else {
                    sess.draft.end();
                }
                sess.dirty = true;
                continue;
            },
            .kill_line => {
                sess.draft.killLine(gpa);
                sess.dirty = true;
                continue;
            },
            .kill_to_start => {
                sess.draft.killToStart(gpa);
                sess.dirty = true;
                continue;
            },
            .kill_word => {
                sess.draft.killWord(gpa);
                sess.dirty = true;
                continue;
            },
            .paste_start => {
                try sess.hold.flush(gpa, &sess.draft);
                try tui.takePaste(stdin, gpa, &sess.draft);
                sess.dirty = true;
                continue;
            },
            .paste_end => continue,
            .eof => {
                exit_eof.* = true;
                break;
            },
            .enter => {
                try sess.hold.flush(gpa, &sess.draft);
                const items = sess.draft.items();
                // `C:\\` ends in a backslash the user typed on purpose; only an
                // odd run of them is a continuation.
                if (draft_mod.endsWithContinuation(items)) {
                    sess.draft.backspace();
                    try sess.draft.insert(gpa, '\n');
                    sess.dirty = true;
                    continue;
                }
                if (sess.multiline) {
                    try sess.draft.insert(gpa, '\n');
                    sess.dirty = true;
                    continue;
                }
            },
        }

        if (tui.keysDraft(sess.draft.items())) {
            sess.draft.clear();
            sess.dirty = true;
            continue;
        }

        if (state.pick.kind != .none and (sess.draft.items().len == 0 or sess.draft.items()[0] != '/')) {
            if (sess.palette.len > 0) {
                const picked = try arena.dupe(u8, sess.palette[sess.palette_sel].name);
                sess.draft.clear();
                var pctx = sess.cmdCtx();
                _ = try cmds.applyPick(&pctx, picked);
                sess.takeMenuNote(&state.menu, nowMs(io));
                sess.palette_stash.clearRetainingCapacity();
                if (state.pick.kind == .none) {
                    sess.paintTranscript();
                    try stdout.flush();
                }
            } else {
                state.pick.clear();
                sess.draft.clear();
            }
            sess.dirty = true;
            continue;
        }

        if (sess.palette.len > 0 and std.mem.indexOfScalar(u8, sess.draft.items(), ' ') == null) {
            // A completed mention is still being written; a completed command is
            // the whole line, so it falls through and sends.
            if (try sess.completePalette()) {
                sess.dirty = true;
                continue;
            }
        }

        const trimmed_line = std.mem.trim(u8, sess.draft.items(), " \r\t");
        if (trimmed_line.len == 0) {
            sess.draft.clear();
            if (state.pending != .none) {
                state.menu.cols = sess.layout.cols;
                // Empty line finishes a guided order (or cancels other prompts).
                try menus.feed(gpa, arena, io, home, stdout, sess.toTranscript(), &sess.shown, &state.pending, &state.menu, "");
                sess.takeMenuNote(&state.menu, nowMs(io));
                sess.dirty = true;
                continue;
            }
            sess.dirty = true;
            continue;
        }
        var prompt_text: []const u8 = try arena.dupe(u8, trimmed_line);
        sess.hist.remember(gpa, prompt_text) catch {};
        sess.draft.clear();
        sess.palette = slash_buf[0..(0)];
        sess.palette_sel = 0;
        sess.palette = &.{};
        if (state.statusline) {
            tui.writeFooter(gpa, stdout, sess.layout, .{
                .model = model,
                .permission = cmds.footerPerm(state),
                .effort = state.effort,
                .composer = state.composer,
                .place = workspace,
            }) catch {};
        }
        try stdout.flush();

        if (state.pending != .none and prompt_text[0] == '/') {
            state.pending.deinit(gpa);
        }

        if (state.pending != .none) {
            state.menu.cols = sess.layout.cols;
            try menus.feed(gpa, arena, io, home, stdout, sess.toTranscript(), &sess.shown, &state.pending, &state.menu, prompt_text);
            sess.takeMenuNote(&state.menu, nowMs(io));
            if (state.pending == .none) {
                var cred_ctx = sess.cmdCtx();
                cmds.reloadFromDisk(&cred_ctx);
            }
            sess.dirty = true;
            continue;
        }

        var ctx = sess.cmdCtx();
        if (prompt_text[0] == '/') {
            switch (try cmds.dispatch(&ctx, prompt_text)) {
                .handled => {
                    sess.takeMenuNote(&state.menu, nowMs(io));
                    if (state.pick.kind == .none) {
                        sess.paintTranscript();
                        try stdout.flush();
                    }
                    sess.dirty = true;
                    continue;
                },
                .quit => break,
                .panel => |kind| {
                    switch (kind) {
                        .help, .shortcuts => openSearchPanel(sess, kind),
                        else => {
                            sess.openPanel(panels.build(sess, kind));
                            // Keep the kind so list panels can act on keys
                            // (sessions: del) without reopening.
                            sess.panel_kind = kind;
                        },
                    }
                    sess.dirty = true;
                    continue;
                },
                .fallthrough => {},
                .retry => |again| {
                    prompt_text = again;
                },
            }
        }

        // Skills stack with @files in one prompt: leading `/a /b
        // task @path`, and omp-style mid-prose `/skill` tokens. After system
        // slash commands so `/help` stays a command, not a skill.
        if (try skills.expand(arena, io, home, workspace, prompt_text)) |expanded| {
            prompt_text = expanded;
        }

        if (try cmds.runShell(&ctx, prompt_text)) {
            sess.dirty = true;
            continue;
        }

        switch (try turn_mod.runTurn(
            sess,
            gpa,
            arena,
            io,
            home,
            workspace,
            lookup,
            model,
            stdin,
            stdout,
            prompt_text,
        )) {
            .ok => {},
            .quit_loop => break,
        }
    }
}
