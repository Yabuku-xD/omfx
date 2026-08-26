const std = @import("std");

const tui = @import("../../../tui.zig");
const cmds = @import("../../../cmds.zig");
const panels = @import("../../../panels.zig");
const session_mod = @import("../../session.zig");
const runs_ui = @import("../../runs_ui.zig");

const dispatch = @import("../dispatch.zig");

const Session = session_mod.Session;
const LoopAction = dispatch.LoopAction;
const Deps = dispatch.Deps;

pub fn startSel(sess: *Session, row: u16, col: u16) void {
    if (tui.jumpVisible(sess.scroll, sess.layout.transcript_rows) and tui.jumpHit(sess.layout, row, col)) {
        sess.dragging = false;
        sess.clearSel();
        return;
    }
    if (tui.contextHit(sess.layout, row, col)) {
        sess.dragging = false;
        sess.clearSel();
        sess.usage_tab = .context;
        sess.openPanel(panels.build(sess, .usage));
        sess.panel_kind = .usage;
        sess.dirty = true;
        return;
    }
    sess.dragging = true;
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

pub fn handleClick(sess: *Session, row: u16, col: u16) LoopAction {
    startSel(sess, row, col);
    return .continue_loop;
}

pub fn handleDrag(sess: *Session, row: u16, col: u16) LoopAction {
    sess.extendSel(row, col);
    return .continue_loop;
}

pub fn handleRelease(sess: *Session, deps: *const Deps, row: u16, col: u16) LoopAction {
    const gpa = deps.gpa;
    // Jump pill first: only the button cells, not the rest of the row.
    if (sess.tryJumpClick(row, col)) {
        sess.dragging = false;
        return .continue_loop;
    }
    // A press that never moved is a click, and a click on a tool
    // run opens it. Deciding here rather than on press is what
    // lets one gesture be both.
    if (!sess.marked.on()) runs_ui.clickRun(sess, row) else sess.copySel(gpa);
    sess.dragging = false;
    return .continue_loop;
}
