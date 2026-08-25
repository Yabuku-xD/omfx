const std = @import("std");

const tui = @import("../../../tui.zig");
const panels = @import("../../../panels.zig");
const session_mod = @import("../../session.zig");

const dispatch = @import("../dispatch.zig");

const Session = session_mod.Session;
const LoopAction = dispatch.LoopAction;
const Deps = dispatch.Deps;

pub fn handleUp(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    if (sess.palette.len > 0) {
        if (sess.palette_sel > 0) sess.palette_sel -= 1;
    } else if (sess.draft.items().len == 0) {
        if (try sess.hist.older(gpa, sess.draft.items())) |line| try sess.draft.replace(gpa, line);
    }
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleDown(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    if (sess.palette.len > 0) {
        if (sess.palette_sel + 1 < sess.palette.len) sess.palette_sel += 1;
    } else if (sess.draft.items().len == 0) {
        if (sess.hist.newer(sess.draft.items())) |line| try sess.draft.replace(gpa, line);
    }
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleHistoryPrev(sess: *Session, deps: *const Deps) !LoopAction {
    return handleUp(sess, deps);
}

pub fn handleHistoryNext(sess: *Session, deps: *const Deps) !LoopAction {
    return handleDown(sess, deps);
}

pub fn handleByte(sess: *Session, deps: *const Deps, b: u8) !LoopAction {
    const gpa = deps.gpa;
    try sess.hold.push(gpa, &sess.draft, b);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleRune(sess: *Session, deps: *const Deps, cp: u21) !LoopAction {
    const gpa = deps.gpa;
    try sess.hold.flush(gpa, &sess.draft);
    var rune_buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &rune_buf) catch {
        sess.dirty = true;
        return .continue_loop;
    };
    try sess.draft.insertSlice(gpa, rune_buf[0..n]);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleBackspace(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    try sess.hold.flush(gpa, &sess.draft);
    sess.draft.backspace();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleDelete(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    try sess.hold.flush(gpa, &sess.draft);
    sess.draft.delete();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleLeft(sess: *Session) LoopAction {
    sess.draft.left();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleRight(sess: *Session) LoopAction {
    sess.draft.right();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleHome(sess: *Session) LoopAction {
    if (sess.palette.len > 0) {
        sess.palette_sel = 0;
    } else {
        sess.draft.home();
    }
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleEnd(sess: *Session) LoopAction {
    if (sess.palette.len > 0) {
        sess.palette_sel = sess.palette.len - 1;
    } else {
        sess.draft.end();
    }
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleWordLeft(sess: *Session) LoopAction {
    sess.draft.wordLeft();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleWordRight(sess: *Session) LoopAction {
    sess.draft.wordRight();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleYank(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    try sess.hold.flush(gpa, &sess.draft);
    try sess.draft.yank(gpa);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleUndo(sess: *Session) LoopAction {
    sess.draft.undo();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleRedo(sess: *Session) LoopAction {
    sess.draft.redo();
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleExternalEditor(sess: *Session) LoopAction {
    panels.editDraftExternally(sess) catch {};
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleKillWordRight(sess: *Session, deps: *const Deps) LoopAction {
    const gpa = deps.gpa;
    sess.draft.killWordRight(gpa);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleKillLine(sess: *Session, deps: *const Deps) LoopAction {
    const gpa = deps.gpa;
    sess.draft.killLine(gpa);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleKillToStart(sess: *Session, deps: *const Deps) LoopAction {
    const gpa = deps.gpa;
    sess.draft.killToStart(gpa);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handleKillWord(sess: *Session, deps: *const Deps) LoopAction {
    const gpa = deps.gpa;
    sess.draft.killWord(gpa);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handlePasteStart(sess: *Session, deps: *const Deps) !LoopAction {
    const gpa = deps.gpa;
    const stdin = deps.stdin;
    try sess.hold.flush(gpa, &sess.draft);
    try tui.takePaste(stdin, gpa, &sess.draft);
    sess.dirty = true;
    return .continue_loop;
}

pub fn handlePasteEnd() LoopAction {
    return .continue_loop;
}
