const tui = @import("../../../tui.zig");
const cmds = @import("../../../cmds.zig");
const session_mod = @import("../../session.zig");

const dispatch = @import("../dispatch.zig");

const Session = session_mod.Session;
const LoopAction = dispatch.LoopAction;
const Deps = dispatch.Deps;

pub fn handlePageUp(sess: *Session) LoopAction {
    if (sess.palette.len > 0) {
        const step = tui.paletteItemRows(sess.layout, sess.palette.len);
        sess.palette_sel = if (sess.palette_sel > step) sess.palette_sel - step else 0;
        sess.dirty = true;
        return .continue_loop;
    }
    if (sess.bumpScroll(true, sess.layout.transcript_rows)) sess.dirty = true;
    return .continue_loop;
}

pub fn handlePageDown(sess: *Session) LoopAction {
    if (sess.palette.len > 0) {
        const step = tui.paletteItemRows(sess.layout, sess.palette.len);
        sess.palette_sel = @min(sess.palette.len - 1, sess.palette_sel + step);
        sess.dirty = true;
        return .continue_loop;
    }
    if (sess.bumpScroll(false, sess.layout.transcript_rows)) sess.dirty = true;
    return .continue_loop;
}

pub fn handleScrollUp(sess: *Session) LoopAction {
    if (sess.bumpScroll(true, tui.wheel_step)) sess.dirty = true;
    return .continue_loop;
}

pub fn handleScrollDown(sess: *Session) LoopAction {
    if (sess.bumpScroll(false, tui.wheel_step)) sess.dirty = true;
    return .continue_loop;
}

pub fn handleResize(sess: *Session, deps: *const Deps, model: []const u8) !LoopAction {
    const state = &sess.state;
    const arena = deps.arena;
    const stdout = deps.stdout;
    const workspace = deps.workspace;

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
}
