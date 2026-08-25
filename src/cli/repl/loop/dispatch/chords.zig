const std = @import("std");

const tui = @import("../../../tui.zig");
const cmds = @import("../../../cmds.zig");
const session_mod = @import("../../session.zig");
const runs_ui = @import("../../runs_ui.zig");

const pointer = @import("pointer.zig");
const dispatch = @import("../dispatch.zig");

const Session = session_mod.Session;
const LoopAction = dispatch.LoopAction;
const Deps = dispatch.Deps;
const nowMs = session_mod.nowMs;

pub fn handleEsc(sess: *Session, deps: *const Deps) !LoopAction {
    const state = &sess.state;
    const gpa = deps.gpa;
    const io = deps.io;
    const stdout = deps.stdout;
    const stdin = deps.stdin;
    const slash_buf = deps.slash_buf;

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
}

pub fn handleTab(sess: *Session, deps: *const Deps) !LoopAction {
    _ = deps;
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
}

pub fn handleKeys(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    try sess.hold.flush(gpa, &sess.draft);
    if (tui.keysDraft(sess.draft.items())) sess.draft.clear();
    // ctrl-x on an empty prompt opens the cheatsheet; `?` typed
    // into the composer keeps the inline list it always had.
    pointer.openSearchPanel(sess, .shortcuts);
    sess.palette_sel = 0;
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleShiftTab(sess: *Session, deps: *const Deps) LoopAction {
    const state = &sess.state;
    const io = deps.io;
    sess.note(cmds.cycleSurface(state), nowMs(io));
    var ctx = sess.cmdCtx();
    cmds.persistChat(&ctx);
    sess.arm.clear();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleCtrlD(sess: *Session, deps: *const Deps) LoopAction {
    const gpa = deps.gpa;
    const stdout = deps.stdout;
    const stdin = deps.stdin;
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
}

pub fn handlePalette(sess: *Session, deps: *const Deps) !LoopAction {
    const state = &sess.state;
    const gpa = deps.gpa;
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
}

pub fn handleNewSession(sess: *Session, deps: *const Deps, model: []const u8) !LoopAction {
    const state = &sess.state;
    const gpa = deps.gpa;
    const arena = deps.arena;
    const stdout = deps.stdout;
    const stdin = deps.stdin;
    const workspace = deps.workspace;
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
}

pub fn handleQuit(sess: *Session, deps: *const Deps) LoopAction {
    const gpa = deps.gpa;
    const stdout = deps.stdout;
    const stdin = deps.stdin;
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
}

pub fn handleYolo(sess: *Session, deps: *const Deps) !LoopAction {
    const stdout = deps.stdout;
    var ctx = sess.cmdCtx();
    _ = try cmds.dispatch(&ctx, "/yolo");
    cmds.persistChat(&ctx);
    sess.paintTranscript();
    try stdout.flush();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleSessions(sess: *Session) !LoopAction {
    var ctx = sess.cmdCtx();
    _ = try cmds.dispatch(&ctx, "/session");
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleCtrlM(sess: *Session) LoopAction {
    sess.multiline = !sess.multiline;
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleCtrlEnter(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    try sess.hold.flush(gpa, &sess.draft);
    try sess.draft.insert(gpa, '\n');
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleCtrlB(sess: *Session) LoopAction {
    sess.draft.left();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleCtrlT(sess: *Session, deps: *const Deps) !LoopAction {
    const state = &sess.state;
    const io = deps.io;
    const stdout = deps.stdout;
    var ctx = sess.cmdCtx();
    try cmds.cycleEffort(&ctx);
    sess.note(std.fmt.allocPrint(sess.arena, "Reasoning set to {s}.", .{
        if (state.effort.len == 0) cmds.auto_effort else state.effort,
    }) catch "Reasoning changed.", nowMs(io));
    sess.paintTranscript();
    try stdout.flush();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleCtrlR(sess: *Session) LoopAction {
    sess.draft.redo();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleCtrlJ(sess: *Session) LoopAction {
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleF2(sess: *Session, deps: *const Deps) !LoopAction {
    const stdout = deps.stdout;
    var ctx = sess.cmdCtx();
    _ = try cmds.dispatch(&ctx, "/settings");
    sess.paintTranscript();
    try stdout.flush();
    sess.dirty = true;
    return .continue_loop;
}

/// Returns null when newline should fall through to submit handling.
pub fn handleNewline(sess: *Session, deps: *const Deps) !?LoopAction {
    const gpa = deps.gpa;
    try sess.hold.flush(gpa, &sess.draft);
    if (sess.multiline) {
        // Shift/Alt+Enter sends while sess.multiline is on.
        return null;
    } else {
        try sess.draft.insert(gpa, '\n');
        sess.dirty = true;
        return .continue_loop;
    }
}

pub fn handleRedraw(sess: *Session, deps: *const Deps, model: []const u8) !LoopAction {
    const state = &sess.state;
    const arena = deps.arena;
    const stdout = deps.stdout;
    const workspace = deps.workspace;
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
}

pub fn handleEof(deps: *const Deps) LoopAction {
    deps.exit_eof.* = true;
    return .break_loop;
}

pub fn handleInterrupt() LoopAction {
    return .break_loop;
}

test "interrupt harness: ctrl-c breaks the repl loop" {
    try std.testing.expectEqual(@as(LoopAction, .break_loop), handleInterrupt());
}
