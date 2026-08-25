const std = @import("std");
const Io = std.Io;

const tui = @import("../../tui.zig");
const draft_mod = @import("../../draft.zig");
const cmds = @import("../../cmds.zig");
const skills = @import("../../../core/skills.zig");
const slash = @import("../../../core/slash.zig");
const menus = @import("../../menus.zig");
const panels = @import("../../panels.zig");
const session_mod = @import("../session.zig");
const runs_ui = @import("../runs_ui.zig");
const input_mod = @import("../input.zig");
const turn_mod = @import("../turn.zig");

pub const Session = session_mod.Session;
const nowMs = session_mod.nowMs;

pub const LoopAction = enum {
    continue_loop,
    break_loop,
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

pub fn handleEvent(sess: *Session, deps: anytype, ev: tui.Event) !LoopAction {
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
    const exit_eof = deps.exit_eof;

    const model = if (state.resolved) |r| r.model else model_name;
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
    if (sess.focus == .scrollback and input_mod.scrollbackKey(sess, ev)) return .continue_loop;
    switch (ev) {
        .skip => return .continue_loop,
        // Turn jumps belong to the scrollback; in the composer a shifted
        // arrow is not a caret move, so it does nothing rather than
        // guessing.
        .shift_left, .shift_right => return .continue_loop,
        .click => |c| {
            startSel(sess, c.row, c.col);
            return .continue_loop;
        },
        .drag => |c| {
            sess.extendSel(c.row, c.col);
            return .continue_loop;
        },
        .release => |c| {
            // Jump pill first: only the button cells, not the rest of the row.
            if (sess.tryJumpClick(c.row, c.col)) {
                sess.dragging = false;
                return .continue_loop;
            }
            // A press that never moved is a click, and a click on a tool
            // run opens it. Deciding here rather than on press is what
            // lets one gesture be both.
            if (!sess.marked.on()) runs_ui.clickRun(sess, c.row) else sess.copySel(gpa);
            sess.dragging = false;
            return .continue_loop;
        },
        .page_up => {
            if (sess.palette.len > 0) {
                const step = tui.paletteItemRows(sess.layout, sess.palette.len);
                sess.palette_sel = if (sess.palette_sel > step) sess.palette_sel - step else 0;
                sess.dirty = true;
                return .continue_loop;
            }
            if (sess.bumpScroll(true, sess.layout.transcript_rows)) sess.dirty = true;
            return .continue_loop;
        },
        .page_down => {
            if (sess.palette.len > 0) {
                const step = tui.paletteItemRows(sess.layout, sess.palette.len);
                sess.palette_sel = @min(sess.palette.len - 1, sess.palette_sel + step);
                sess.dirty = true;
                return .continue_loop;
            }
            if (sess.bumpScroll(false, sess.layout.transcript_rows)) sess.dirty = true;
            return .continue_loop;
        },
        .scroll_up => {
            if (sess.bumpScroll(true, tui.wheel_step)) sess.dirty = true;
            return .continue_loop;
        },
        .scroll_down => {
            if (sess.bumpScroll(false, tui.wheel_step)) sess.dirty = true;
            return .continue_loop;
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
            return .continue_loop;
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
                return .continue_loop;
            }
            if (sess.palette.len > 0) {
                if (tui.atPrefix(sess.draft.items()) == null) sess.draft.clear();
                sess.palette = slash_buf[0..(0)];
                sess.palette_sel = 0;
                sess.arm.clear();
                sess.dirty = true;
                return .continue_loop;
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
                return .continue_loop;
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
                return .continue_loop;
            }
            return .continue_loop;
        },
        .up => {
            if (sess.palette.len > 0) {
                if (sess.palette_sel > 0) sess.palette_sel -= 1;
            } else if (sess.draft.items().len == 0) {
                if (try sess.hist.older(gpa, sess.draft.items())) |line| try sess.draft.replace(gpa, line);
            }
            sess.dirty = true;
            return .continue_loop;
        },
        .down => {
            if (sess.palette.len > 0) {
                if (sess.palette_sel + 1 < sess.palette.len) sess.palette_sel += 1;
            } else if (sess.draft.items().len == 0) {
                if (sess.hist.newer(sess.draft.items())) |line| try sess.draft.replace(gpa, line);
            }
            sess.dirty = true;
            return .continue_loop;
        },
        .history_prev => {
            if (sess.palette.len > 0) {
                if (sess.palette_sel > 0) sess.palette_sel -= 1;
            } else if (sess.draft.items().len == 0) {
                if (try sess.hist.older(gpa, sess.draft.items())) |line| try sess.draft.replace(gpa, line);
            }
            sess.dirty = true;
            return .continue_loop;
        },
        .history_next => {
            if (sess.palette.len > 0) {
                if (sess.palette_sel + 1 < sess.palette.len) sess.palette_sel += 1;
            } else if (sess.draft.items().len == 0) {
                if (sess.hist.newer(sess.draft.items())) |line| try sess.draft.replace(gpa, line);
            }
            sess.dirty = true;
            return .continue_loop;
        },
        .tab => {
            if (tui.keysDraft(sess.draft.items())) {
                sess.dirty = true;
                return .continue_loop;
            }
            // Nothing to complete: hand the keyboard to the scrollback, the
            // way Tab does in every other pane-and-prompt TUI.
            if (sess.palette.len == 0 and sess.draft.items().len == 0) {
                if (runs_ui.focusScrollback(sess)) return .continue_loop;
            }
            _ = try sess.completePalette();
            sess.dirty = true;
            return .continue_loop;
        },
        .keys => {
            try sess.hold.flush(gpa, &sess.draft);
            if (tui.keysDraft(sess.draft.items())) sess.draft.clear();
            // ctrl-x on an empty prompt opens the cheatsheet; `?` typed
            // into the composer keeps the inline list it always had.
            openSearchPanel(sess, .shortcuts);
            sess.palette_sel = 0;
            sess.dirty = true;
            return .continue_loop;
        },
        .shift_tab => {
            sess.note(cmds.cycleSurface(state), nowMs(io));
            var ctx = sess.cmdCtx();
            cmds.persistChat(&ctx);
            sess.arm.clear();
            sess.dirty = true;
            return .continue_loop;
        },
        .interrupt => return .break_loop,
        .ctrl_d => {
            if (sess.draft.items().len != 0) {
                sess.draft.delete();
                sess.dirty = true;
                return .continue_loop;
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
            )) return .break_loop;
            sess.dirty = true;
            return .continue_loop;
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
            return .continue_loop;
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
            return .continue_loop;
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
            )) return .break_loop;
            sess.dirty = true;
            return .continue_loop;
        },
        .yolo => {
            var ctx = sess.cmdCtx();
            _ = try cmds.dispatch(&ctx, "/yolo");
            cmds.persistChat(&ctx);
            sess.paintTranscript();
            try stdout.flush();
            sess.dirty = true;
            return .continue_loop;
        },
        .sessions => {
            var ctx = sess.cmdCtx();
            _ = try cmds.dispatch(&ctx, "/session");
            sess.dirty = true;
            return .continue_loop;
        },
        .ctrl_m => {
            sess.multiline = !sess.multiline;
            sess.dirty = true;
            return .continue_loop;
        },
        .ctrl_enter => {
            try sess.hold.flush(gpa, &sess.draft);
            try sess.draft.insert(gpa, '\n');
            sess.dirty = true;
            return .continue_loop;
        },
        .ctrl_b => {
            sess.draft.left();
            sess.dirty = true;
            return .continue_loop;
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
            return .continue_loop;
        },
        .ctrl_r => {
            sess.draft.redo();
            sess.dirty = true;
            return .continue_loop;
        },
        .ctrl_j => {
            sess.dirty = true;
            return .continue_loop;
        },
        .f2 => {
            var ctx = sess.cmdCtx();
            _ = try cmds.dispatch(&ctx, "/settings");
            sess.paintTranscript();
            try stdout.flush();
            sess.dirty = true;
            return .continue_loop;
        },
        .newline => {
            try sess.hold.flush(gpa, &sess.draft);
            if (sess.multiline) {
                // Shift/Alt+Enter sends while sess.multiline is on.
            } else {
                try sess.draft.insert(gpa, '\n');
                sess.dirty = true;
                return .continue_loop;
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
            return .continue_loop;
        },
        .yank => {
            try sess.hold.flush(gpa, &sess.draft);
            try sess.draft.yank(gpa);
            sess.dirty = true;
            return .continue_loop;
        },
        .undo => {
            sess.draft.undo();
            sess.dirty = true;
            return .continue_loop;
        },
        .redo => {
            sess.draft.redo();
            sess.dirty = true;
            return .continue_loop;
        },
        .word_left => {
            sess.draft.wordLeft();
            sess.dirty = true;
            return .continue_loop;
        },
        .word_right => {
            sess.draft.wordRight();
            sess.dirty = true;
            return .continue_loop;
        },
        // A long prompt belongs in a real editor. ctrl-g (or the bound
        // external-editor key) sends the draft to $EDITOR and loads it back.
        .external_editor => {
            panels.editDraftExternally(sess) catch {};
            sess.dirty = true;
            return .continue_loop;
        },
        .kill_word_right => {
            sess.draft.killWordRight(gpa);
            sess.dirty = true;
            return .continue_loop;
        },
        .byte => |b| {
            try sess.hold.push(gpa, &sess.draft, b);
            sess.dirty = true;
            return .continue_loop;
        },
        .rune => |cp| {
            try sess.hold.flush(gpa, &sess.draft);
            var rune_buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &rune_buf) catch {
                sess.dirty = true;
                return .continue_loop;
            };
            try sess.draft.insertSlice(gpa, rune_buf[0..n]);
            sess.dirty = true;
            return .continue_loop;
        },
        .backspace => {
            try sess.hold.flush(gpa, &sess.draft);
            sess.draft.backspace();
            sess.dirty = true;
            return .continue_loop;
        },
        .delete => {
            try sess.hold.flush(gpa, &sess.draft);
            sess.draft.delete();
            sess.dirty = true;
            return .continue_loop;
        },
        .left => {
            sess.draft.left();
            sess.dirty = true;
            return .continue_loop;
        },
        .right => {
            sess.draft.right();
            sess.dirty = true;
            return .continue_loop;
        },
        .home => {
            if (sess.palette.len > 0) {
                sess.palette_sel = 0;
            } else {
                sess.draft.home();
            }
            sess.dirty = true;
            return .continue_loop;
        },
        .end => {
            if (sess.palette.len > 0) {
                sess.palette_sel = sess.palette.len - 1;
            } else {
                sess.draft.end();
            }
            sess.dirty = true;
            return .continue_loop;
        },
        .kill_line => {
            sess.draft.killLine(gpa);
            sess.dirty = true;
            return .continue_loop;
        },
        .kill_to_start => {
            sess.draft.killToStart(gpa);
            sess.dirty = true;
            return .continue_loop;
        },
        .kill_word => {
            sess.draft.killWord(gpa);
            sess.dirty = true;
            return .continue_loop;
        },
        .paste_start => {
            try sess.hold.flush(gpa, &sess.draft);
            try tui.takePaste(stdin, gpa, &sess.draft);
            sess.dirty = true;
            return .continue_loop;
        },
        .paste_end => return .continue_loop,
        .eof => {
            exit_eof.* = true;
            return .break_loop;
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
                return .continue_loop;
            }
            if (sess.multiline) {
                try sess.draft.insert(gpa, '\n');
                sess.dirty = true;
                return .continue_loop;
            }
        },
    }

    if (tui.keysDraft(sess.draft.items())) {
        sess.draft.clear();
        sess.dirty = true;
        return .continue_loop;
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
        return .continue_loop;
    }

    if (sess.palette.len > 0 and std.mem.indexOfScalar(u8, sess.draft.items(), ' ') == null) {
        // A completed mention is still being written; a completed command is
        // the whole line, so it falls through and sends.
        if (try sess.completePalette()) {
            sess.dirty = true;
            return .continue_loop;
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
            return .continue_loop;
        }
        sess.dirty = true;
        return .continue_loop;
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
            .context_used = sess.ctx_used,
            .context_window = sess.ctx_window,
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
        return .continue_loop;
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
                return .continue_loop;
            },
            .quit => return .break_loop,
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
                return .continue_loop;
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
        return .continue_loop;
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
        .quit_loop => return .break_loop,
    }
    return .continue_loop;
}
