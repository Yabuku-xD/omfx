const std = @import("std");
const Io = std.Io;

const tui = @import("../tui.zig");
const panel_mod = @import("../panel.zig");
const cmds = @import("../cmds.zig");
const skills = @import("../../core/skills.zig");
const slash = @import("../../core/slash.zig");
const session = @import("../../core/session.zig");
const env = @import("../../core/env.zig");
const panels = @import("../panels.zig");
const session_mod = @import("session.zig");

const paint_mod = @import("loop/paint.zig");
const dispatch_mod = @import("loop/dispatch.zig");

pub const Session = session_mod.Session;
pub const LoopAction = dispatch_mod.LoopAction;
const nowMs = session_mod.nowMs;

pub const startSel = dispatch_mod.startSel;
pub const openSearchPanel = dispatch_mod.openSearchPanel;

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

    while (true) {
        if (state.skills_stale) {
            state.skills_stale = false;
            sess.skill_specs = skillSpecs(sess);
        }
        if (sess.dirty) try paint_mod.paintFrame(sess, deps);

        // A panel owns the keyboard while it is up. Polling at the frame
        // budget rather than 64ms keeps the reveal smooth, and drops back to
        // the idle rate the moment the animation settles.
        if (sess.panel != null) {
            const more = sess.paintPanel();
            const wait: i32 = if (more) @intCast(panel_mod.frame_ms) else 64;
            const pev = tui.pollEvent(deps.stdin, wait);
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
        } else tui.pollEvent(deps.stdin, 64);

        switch (try dispatch_mod.handleEvent(sess, @ptrCast(&deps), ev)) {
            .continue_loop => {},
            .break_loop => break,
        }
    }
}
