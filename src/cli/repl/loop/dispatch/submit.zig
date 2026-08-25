const std = @import("std");

const tui = @import("../../../tui.zig");
const draft_mod = @import("../../../draft.zig");
const cmds = @import("../../../cmds.zig");
const skills = @import("../../../../core/skills.zig");
const slash = @import("../../../../core/slash.zig");
const menus = @import("../../../menus.zig");
const panels = @import("../../../panels.zig");
const session_mod = @import("../../session.zig");
const turn_mod = @import("../../turn.zig");

const pointer = @import("pointer.zig");
const dispatch = @import("../dispatch.zig");

const Session = session_mod.Session;
const LoopAction = dispatch.LoopAction;
const Deps = dispatch.Deps;
const nowMs = session_mod.nowMs;

/// Returns null when enter should fall through to submit handling.
pub fn handleEnter(sess: *Session, deps: *const Deps) !?LoopAction {
    const gpa = deps.gpa;
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
    return null;
}

pub fn afterSwitch(sess: *Session, deps: *const Deps, model: []const u8) !LoopAction {
    const state = &sess.state;
    const gpa = deps.gpa;
    const arena = deps.arena;
    const io = deps.io;
    const stdout = deps.stdout;
    const home = deps.home;
    const workspace = deps.workspace;
    const lookup = deps.lookup;
    const stdin = deps.stdin;
    const slash_buf = deps.slash_buf;

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
                    .help, .shortcuts => pointer.openSearchPanel(sess, kind),
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
