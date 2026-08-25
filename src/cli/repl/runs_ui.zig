const std = @import("std");

const tui = @import("../tui.zig");
const runs_mod = @import("../runs.zig");
const chat = @import("../chat.zig");
const diffview = @import("../diffview.zig");
const cmds = @import("../cmds.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;
const nowMs = session_mod.nowMs;

pub fn redrawRun(sess: *Session, rec: *runs_mod.Store.Rec) bool {
    const focus: ?usize = if (rec.childOpen(sess.child) and sess.hunk_n > 0) sess.hunk_i else null;
    const ok = runs_mod.redrawInPlace(sess.gpa, sess.layout.cols, &sess.runs, &sess.shown, rec, focus);
    if (ok) sess.dirty = true;
    return ok;
}

pub fn syncHunkNav(sess: *Session, rec: *const runs_mod.Store.Rec) void {
    if (!rec.expanded or !rec.childOpen(sess.child) or sess.child >= rec.bodies.len) {
        sess.hunk_i = 0;
        sess.hunk_n = 0;
        return;
    }
    const body = rec.bodies[sess.child];
    if (!chat.looksLikeDiff(body)) {
        sess.hunk_i = 0;
        sess.hunk_n = 0;
        return;
    }
    sess.hunk_n = diffview.hunkCount(body);
    if (sess.hunk_n == 0) {
        sess.hunk_i = 0;
        return;
    }
    if (sess.hunk_i >= sess.hunk_n) sess.hunk_i = sess.hunk_n - 1;
}

pub fn stepHunk(sess: *Session, forward: bool) bool {
    if (sess.focus != .scrollback or sess.sel >= sess.runs.items.items.len) return false;
    const rec = &sess.runs.items.items[sess.sel];
    syncHunkNav(sess, rec);
    if (sess.hunk_n == 0) return false;
    if (forward) {
        sess.hunk_i = (sess.hunk_i + 1) % sess.hunk_n;
    } else {
        sess.hunk_i = if (sess.hunk_i == 0) sess.hunk_n - 1 else sess.hunk_i - 1;
    }
    return redrawRun(sess, rec);
}

pub fn mark(sess: *Session, i: usize, on: bool) void {
    if (i >= sess.runs.items.items.len) return;
    const rec = &sess.runs.items.items[i];
    if (rec.selected == on) return;
    rec.selected = on;
    _ = redrawRun(sess, rec);
}

pub fn focusScrollback(sess: *Session) bool {
    if (sess.focus == .scrollback) return true;
    if (sess.runs.items.items.len == 0) return false;
    sess.focus = .scrollback;
    sess.sel = sess.runs.items.items.len - 1;
    mark(sess, sess.sel, true);
    showRun(sess, sess.sel);
    sess.dirty = true;
    return true;
}

pub fn blurScrollback(sess: *Session) void {
    if (sess.focus == .prompt) return;
    mark(sess, sess.sel, false);
    sess.focus = .prompt;
    sess.dirty = true;
}

pub fn moveSel(sess: *Session, back: bool) void {
    const n = sess.runs.items.items.len;
    if (n == 0) return;
    const next = if (back)
        (if (sess.sel == 0) n - 1 else sess.sel - 1)
    else
        (if (sess.sel + 1 >= n) 0 else sess.sel + 1);
    if (next == sess.sel) return;
    mark(sess, sess.sel, false);
    sess.sel = next;
    mark(sess, sess.sel, true);
    showRun(sess, sess.sel);
}

pub fn selectEnd(sess: *Session, last: bool) void {
    const n = sess.runs.items.items.len;
    if (n == 0) return;
    const next = if (last) n - 1 else 0;
    if (next == sess.sel) return;
    mark(sess, sess.sel, false);
    sess.sel = next;
    mark(sess, sess.sel, true);
    showRun(sess, sess.sel);
}

pub fn setExpanded(sess: *Session, want: ?bool) void {
    if (sess.sel >= sess.runs.items.items.len) return;
    const rec = &sess.runs.items.items[sess.sel];
    if (!rec.openable()) return;
    const next = want orelse !rec.expanded;
    if (next == rec.expanded) return;
    rec.expanded = next;
    // Closing a run closes what was open inside it: reopening should not
    // hand back a body you had already dismissed.
    if (!next) rec.open_bits = 0;
    sess.child = 0;
    _ = redrawRun(sess, rec);
    showRun(sess, sess.sel);
}

pub fn clickRun(sess: *Session, term_row: u16) void {
    const click = runs_mod.clickAtTermRow(
        sess.arena,
        sess.layout,
        &sess.runs,
        &sess.shown,
        sess.scroll,
        term_row,
    ) catch return orelse {
        blurScrollback(sess, );
        return;
    };
    const idx = click.run_index;
    const rec = &sess.runs.items.items[idx];

    if (sess.focus == .scrollback and sess.sel != idx) mark(sess, sess.sel, false);
    sess.focus = .scrollback;
    sess.sel = idx;
    mark(sess, idx, true);

    switch (click.part) {
        .summary => {
            if (!rec.openable()) {
                sess.dirty = true;
                return;
            }
            _ = runs_mod.applyPartToggle(rec, click.part);
            sess.child = 0;
            sess.hunk_i = 0;
        },
        .child => |i| {
            sess.child = i;
            _ = runs_mod.applyPartToggle(rec, click.part);
            sess.hunk_i = 0;
        },
    }
    syncHunkNav(sess, rec);
    _ = redrawRun(sess, rec);
    showRun(sess, idx);
    sess.dirty = true;
}

pub fn expandAll(sess: *Session) void {
    var want = false;
    for (sess.runs.items.items) |r| {
        if (r.openable() and !r.expanded) want = true;
    }
    var i: usize = 0;
    while (i < sess.runs.items.items.len) : (i += 1) {
        const rec = &sess.runs.items.items[i];
        if (!rec.openable() or rec.expanded == want) continue;
        rec.expanded = want;
        _ = redrawRun(sess, rec);
    }
    showRun(sess, sess.sel);
}

pub fn copyRun(sess: *Session) void {
    if (sess.sel >= sess.runs.items.items.len) return;
    const rec = sess.runs.items.items[sess.sel];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(sess.gpa);
    for (rec.details) |d| {
        out.appendSlice(sess.gpa, d) catch return;
        out.append(sess.gpa, '\n') catch return;
    }
    sess.note(if (cmds.copyClipboard(sess.io, out.items))
        "Copied the run's commands."
    else
        "No clipboard tool on this machine.", nowMs(sess.io));
}

pub fn copyRunOutput(sess: *Session) void {
    if (sess.sel >= sess.runs.items.items.len) return;
    const rec = sess.runs.items.items[sess.sel];
    if (sess.child >= rec.bodies.len) return;
    const body = rec.bodies[sess.child];
    if (body.len == 0) {
        sess.note("That call returned nothing.", nowMs(sess.io));
        return;
    }
    sess.note(if (cmds.copyClipboard(sess.io, body))
        std.fmt.allocPrint(sess.arena, "Copied {d} characters of output.", .{body.len}) catch "Copied."
    else
        "No clipboard tool on this machine.", nowMs(sess.io));
}

pub fn showRun(sess: *Session, i: usize) void {
    if (i >= sess.runs.items.items.len) return;
    const row = sess.shown.rowOfOffset(sess.runs.items.items[i].off) orelse return;
    const total = sess.shown.rowCount();
    const rows = sess.scrollRows();
    if (rows == 0 or total <= rows) {
        sess.scroll = 0;
        return;
    }
    const max = tui.maxScroll(total, rows);
    var s = @min(sess.scroll, max);
    const start = total - rows - s;
    if (row < start) {
        s = if (total > rows + row) total - rows - row else max;
    } else if (row >= start + rows) {
        s = if (total > row + 1) total - row - 1 else 0;
    }
    sess.scroll = @min(s, max);
}

pub fn selectTurn(sess: *Session, back: bool) void {
    const n = sess.runs.items.items.len;
    if (n == 0) return;
    const next = if (back)
        (if (sess.sel == 0) 0 else sess.sel - 1)
    else
        (if (sess.sel + 1 >= n) n - 1 else sess.sel + 1);
    if (next == sess.sel) return;
    mark(sess, sess.sel, false);
    sess.sel = next;
    mark(sess, sess.sel, true);
    showRun(sess, sess.sel);
}

pub fn toggleChild(sess: *Session) bool {
    if (sess.sel >= sess.runs.items.items.len) return false;
    const rec = &sess.runs.items.items[sess.sel];
    if (!rec.expanded or !rec.openable()) return false;
    if (sess.child >= rec.details.len) return false;
    rec.toggleChildBit(sess.child);
    _ = redrawRun(sess, rec);
    showRun(sess, sess.sel);
    return true;
}
