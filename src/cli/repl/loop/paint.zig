const std = @import("std");
const Io = std.Io;

const tui = @import("../../tui.zig");
const cmds = @import("../../cmds.zig");
const slash = @import("../../../core/slash.zig");
const todos = @import("../../../core/todos.zig");
const sink = @import("../../../core/sink.zig");
const session_mod = @import("../session.zig");

pub const Session = session_mod.Session;
const nowMs = session_mod.nowMs;

pub fn paintFrame(sess: *Session, deps: anytype) !void {
    const state = &sess.state;
    const gpa = deps.gpa;
    const arena = deps.arena;
    const io = deps.io;
    const stdout = deps.stdout;
    const workspace = deps.workspace;
    const model_name = deps.model_name;
    const slash_buf = deps.slash_buf;
    const at_store = deps.at_store;

    const model = if (state.resolved) |r| r.model else model_name;
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
