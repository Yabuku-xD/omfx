const std = @import("std");
const Io = std.Io;

const tui = @import("../../tui.zig");
const slash = @import("../../../core/slash.zig");
const env = @import("../../../core/env.zig");
const session_mod = @import("../session.zig");
const input_mod = @import("../input.zig");

const pointer = @import("dispatch/pointer.zig");
const scroll = @import("dispatch/scroll.zig");
const edit = @import("dispatch/edit.zig");
const chords = @import("dispatch/chords.zig");
const submit = @import("dispatch/submit.zig");

pub const Session = session_mod.Session;
const nowMs = session_mod.nowMs;

pub const LoopAction = enum {
    continue_loop,
    break_loop,
};

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
    exit_eof: *bool,
    at_store: *[32][96]u8,
};

pub const startSel = pointer.startSel;
pub const openSearchPanel = pointer.openSearchPanel;

pub fn handleEvent(sess: *Session, deps: *const Deps, ev: tui.Event) !LoopAction {
    const state = &sess.state;
    const model_name = deps.model_name;

    const model = if (state.resolved) |r| r.model else model_name;
    const tag = std.meta.activeTag(ev);
    if (tag != .skip and tag != .shift_tab and !state.pending.awaitingInput()) sess.noteClear();
    // Nothing was typed, so nothing else will repaint: the note has to ask
    // for the frame that takes it back down.
    if (tag == .skip) {
        const now = nowMs(deps.io);
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
        .click => |c| return pointer.handleClick(sess, c.row, c.col),
        .drag => |c| return pointer.handleDrag(sess, c.row, c.col),
        .release => |c| return pointer.handleRelease(sess, deps, c.row, c.col),
        .page_up => return scroll.handlePageUp(sess),
        .page_down => return scroll.handlePageDown(sess),
        .scroll_up => return scroll.handleScrollUp(sess),
        .scroll_down => return scroll.handleScrollDown(sess),
        .resize => return scroll.handleResize(sess, deps, model),
        .esc => return chords.handleEsc(sess, deps),
        .up => return edit.handleUp(sess, deps),
        .down => return edit.handleDown(sess, deps),
        .history_prev => return edit.handleHistoryPrev(sess, deps),
        .history_next => return edit.handleHistoryNext(sess, deps),
        .tab => return chords.handleTab(sess, deps),
        .keys => return chords.handleKeys(sess, deps),
        .shift_tab => return chords.handleShiftTab(sess, deps),
        .interrupt => return chords.handleInterrupt(),
        .ctrl_d => return chords.handleCtrlD(sess, deps),
        .palette => return chords.handlePalette(sess, deps),
        .new_session => return chords.handleNewSession(sess, deps, model),
        .quit => return chords.handleQuit(sess, deps),
        .yolo => return chords.handleYolo(sess, deps),
        .sessions => return chords.handleSessions(sess),
        .ctrl_m => return chords.handleCtrlM(sess),
        .ctrl_enter => return chords.handleCtrlEnter(sess, deps),
        .ctrl_b => return chords.handleCtrlB(sess),
        .ctrl_t => return chords.handleCtrlT(sess, deps),
        .ctrl_r => return chords.handleCtrlR(sess),
        .ctrl_j => return chords.handleCtrlJ(sess),
        .f2 => return chords.handleF2(sess, deps),
        .newline => {
            if (try chords.handleNewline(sess, deps)) |action| return action;
        },
        .redraw => return chords.handleRedraw(sess, deps, model),
        .yank => return edit.handleYank(sess, deps),
        .undo => return edit.handleUndo(sess),
        .redo => return edit.handleRedo(sess),
        .word_left => return edit.handleWordLeft(sess),
        .word_right => return edit.handleWordRight(sess),
        // A long prompt belongs in a real editor. ctrl-g (or the bound
        // external-editor key) sends the draft to $EDITOR and loads it back.
        .external_editor => return edit.handleExternalEditor(sess),
        .kill_word_right => return edit.handleKillWordRight(sess, deps),
        .byte => |b| return edit.handleByte(sess, deps, b),
        .rune => |cp| return edit.handleRune(sess, deps, cp),
        .backspace => return edit.handleBackspace(sess, deps),
        .delete => return edit.handleDelete(sess, deps),
        .left => return edit.handleLeft(sess),
        .right => return edit.handleRight(sess),
        .home => return edit.handleHome(sess),
        .end => return edit.handleEnd(sess),
        .kill_line => return edit.handleKillLine(sess, deps),
        .kill_to_start => return edit.handleKillToStart(sess, deps),
        .kill_word => return edit.handleKillWord(sess, deps),
        .paste_start => return edit.handlePasteStart(sess, deps),
        .paste_end => return edit.handlePasteEnd(),
        .eof => return chords.handleEof(deps),
        .enter => {
            if (try submit.handleEnter(sess, deps)) |action| return action;
        },
    }

    return submit.afterSwitch(sess, deps, model);
}
