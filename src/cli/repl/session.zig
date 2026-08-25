const std = @import("std");
const Io = std.Io;

const tui = @import("../tui.zig");
const panel_mod = @import("../panel.zig");
const runs_mod = @import("../runs.zig");
const toast_mod = @import("../toast.zig");
const cmds = @import("../cmds.zig");
const todo_mod = @import("../../core/todos.zig");
const chat = @import("../chat.zig");
const slash = @import("../../core/slash.zig");
const env = @import("../../core/env.zig");
const cli = @import("../../core/cli.zig");
const menus = @import("../menus.zig");
const sink = @import("../../core/sink.zig");
const pathing = @import("../../tools/pathing.zig");
const agent = @import("../../core/agent.zig");

const log = std.log.scoped(.repl);

pub fn nowMs(io: Io) i64 {
    return Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
}

pub const Session = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    home: []const u8,
    workspace: []const u8,
    lookup: env.Lookup,
    parsed: cli.Parsed,

    state: cmds.State,
    shown: tui.Transcript,
    /// Open todos for this session. Bound into `todos.active` for the REPL lifetime.
    tasks: todo_mod.List = .{},
    /// Skill read roots cached at startup; folded into path access for the session.
    read_extra: []const []const u8 = &.{},
    /// Committed tool runs, by the bytes they occupy in `shown`.
    runs: runs_mod.Store,
    /// Where the keyboard is. Scrollback focus is how a run is opened without
    /// a mouse; the composer keeps its draft untouched while it is up.
    focus: Focus = .prompt,
    /// Index into `runs.items` while focused there.
    sel: usize = 0,
    /// Scratch for the hint row, which is rebuilt from the live bindings on
    /// every paint rather than kept as a string per width.
    hint_buf: [256]u8 = undefined,
    /// Set when a prompt typed during the turn ended with Enter: the loop sends
    /// it instead of waiting for a key that was already pressed.
    steer_send: bool = false,
    layout: tui.Layout,
    cups: tui.Cups,
    draft: tui.Draft = .{},
    hist: tui.History = .{},
    hold: tui.Utf8Hold = .{},
    arm: tui.Arm = .{},

    scroll: usize = 0,
    dirty: bool = true,
    multiline: bool = false,
    cancel: std.atomic.Value(bool) = .init(false),
    mode_note: []const u8 = "",
    /// When the note went up. It answers the hint row for a few seconds and
    /// then gets out of the way: a confirmation that never leaves stops being
    /// a confirmation and becomes a label on the wrong thing.
    mode_note_at: i64 = 0,
    /// Toast queue: confirmations sit above the footer so they do not steal
    /// the hint row from keys / generating status.
    toasts: toast_mod.Queue = .{},
    /// Last painted toast line (owned by `gpa`). Empty when nothing is showing.
    toast_paint: []u8 = &.{},
    /// Hunk focus inside an opened diff (scrollback n/p).
    hunk_i: usize = 0,
    hunk_n: usize = 0,

    /// Palette rows currently offered, and which one is highlighted.
    palette: []const slash.Spec = &.{},
    palette_sel: usize = 0,
    palette_stash: std.ArrayList(u8) = .empty,
    /// Shown until a provider resolves and supplies the real name.
    fallback_model: []const u8 = "",
    /// Current activity phrase, set by the turn in flight so both paint paths
    /// show the same words.
    status: []const u8 = "",
    /// The fixed floor under every turn: the system prompt and the advertised
    /// tool schemas, in bytes, as the last turn sent them.
    trace_sys: u32 = 0,
    trace_tools: u32 = 0,
    /// What the window is holding after the last turn, and what it holds.
    /// Read from the provider's own usage, never estimated.
    ctx_used: u32 = 0,
    ctx_window: u32 = 0,
    /// The last turn's prompt as the provider billed it. Kept apart from
    /// `ctx_used` because the question "how much of the window is full" and
    /// the question "how much of it did I pay full price for" have different
    /// answers on a cached turn.
    ctx_fresh: u32 = 0,
    ctx_cache_read: u32 = 0,
    ctx_cache_write: u32 = 0,
    /// The call inside the open run the keyboard is on.
    child: usize = 0,
    /// Skills on this machine, as slash commands. Built once at startup: they
    /// are files on disk, and rescanning per keystroke would stat a hundred
    /// directories to answer a prefix.
    skill_specs: []const slash.Spec = &.{},
    /// Text the pointer has dragged over, and whether a button is still down.
    marked: tui.Sel = .{},
    dragging: bool = false,
    /// Turns in a row that ended without a clean verdict. `auto` reads this:
    /// a model that is stuck does not get more thinking, it gets less.
    stuck: usize = 0,

    /// Open settings panel, if any. A panel owns the keyboard while it is up:
    /// the composer keeps its draft untouched underneath.
    panel: ?panel_mod.Panel = null,
    panel_opened_ms: i64 = 0,
    /// Set when a pick row was chosen; the loop runs it after the panel closes.
    panel_pick: []const u8 = "",
    /// Live buffer for a `.text` row being typed into, and for the search box
    /// of a panel that filters.
    panel_edit: std.ArrayList(u8) = .empty,
    /// Which searchable panel is open, so a keystroke rebuilds the same one.
    /// Non-search panels leave this null.
    panel_kind: ?cmds.PanelKind = null,

    pub const Focus = enum { prompt, scrollback };

    pub fn deinit(self: *Session) void {
        self.runs.deinit();
        self.panel_edit.deinit(self.gpa);
        self.draft.deinit(self.gpa);
        self.hist.deinit(self.gpa);
        self.palette_stash.deinit(self.gpa);
        self.shown.deinit();
        self.state.deinit(self.gpa);
    }

    pub fn toTranscript(self: *const Session) []const u8 {
        return self.cups.toTranscript();
    }

    pub fn cmdCtx(self: *Session) cmds.Ctx {
        // Width follows the pane, so a command answer wraps where the rest of
        // the transcript does rather than at a compiled-in guess.
        self.state.cols = self.layout.cols;
        return .{
            .gpa = self.gpa,
            .arena = self.arena,
            .io = self.io,
            .stdout = self.stdout,
            .home = self.home,
            .workspace = self.workspace,
            .lookup = self.lookup,
            .to_transcript = self.toTranscript(),
            .flag_provider = self.parsed.provider,
            .flag_model = self.parsed.model,
            .shown = &self.shown,
            .state = &self.state,
        };
    }

    pub fn model(self: *const Session) []const u8 {
        if (self.state.resolved) |r| return r.model;
        return self.fallback_model;
    }

    pub fn pathAccess(self: *const Session) pathing.Access {
        return .{
            .workspace = self.workspace,
            .extra = self.state.extraSlice(),
            .read_extra = self.read_extra,
        };
    }

    pub fn syncPathing(self: *const Session) void {
        pathing.setAccess(self.pathAccess());
    }

    /// Minimal session for unit tests (no tty).
    pub fn testing(allocator: std.mem.Allocator) Session {
        return .{
            .gpa = allocator,
            .arena = allocator,
            .io = std.testing.io,
            .stdout = undefined,
            .home = "/tmp",
            .workspace = "/tmp",
            .lookup = (env.Table{ .pairs = &.{} }).lookup(),
            .parsed = .{},
            .state = .{ .mode = .ask, .reads = agent.Reads.init(allocator) },
            .shown = tui.Transcript.init(allocator, 80),
            .runs = runs_mod.Store.init(allocator),
            .layout = tui.Layout.compute(24, 80),
            .cups = tui.Cups.compute(tui.Layout.compute(24, 80)),
        };
    }

    pub fn footer(self: *Session, turn: tui.Turn) tui.Footer {
        self.refreshToast();
        return .{
            .model = self.model(),
            .permission = cmds.footerPerm(&self.state),
            .effort = if (self.state.effort.len == 0) cmds.auto_effort else self.state.effort,
            .sel = self.marked,
            .context_used = self.ctx_used,
            .context_window = self.ctx_window,
            .composer = self.state.composer,
            .place = self.workspace,
            .turn = turn,
            // The same activity phrase the live pane paints. Without this the
            // repl's own repaints fall back to the generic "Generating", so
            // the status flickers between the two on every frame.
            .status = self.status,
            // The keys that work in the scrollback are not the keys that work
            // in the composer, so the bar says which set is live.
            .hint = if (self.focus == .scrollback and turn == .idle)
                .{ .text = tui.scrollbackHint(&self.hint_buf, self.layout.cols) }
            else
                .auto,
            .toast = self.toast_paint,
            .jump = tui.jumpVisible(self.scroll, self.layout.transcript_rows),
        };
    }

    pub fn publishJumpHit(self: *Session) void {
        if (tui.jumpVisible(self.scroll, self.layout.transcript_rows)) {
            if (tui.jumpHitBox(self.layout)) |box| {
                sink.setJumpHit(true, box.row, box.col0, box.col1);
                return;
            }
        }
        sink.setJumpHit(false, 0, 0, 0);
    }

    /// Re-pin to the live tail. During a turn that resumes stick-to-stream.
    pub fn jumpToBottom(self: *Session) bool {
        if (self.scroll == 0) return false;
        self.scroll = 0;
        self.dirty = true;
        return true;
    }

    pub fn tryJumpClick(self: *Session, row: u16, col: u16) bool {
        if (!tui.jumpVisible(self.scroll, self.layout.transcript_rows)) return false;
        if (!tui.jumpHit(self.layout, row, col)) return false;
        return self.jumpToBottom();
    }

    pub fn refreshToast(self: *Session) void {
        if (self.toast_paint.len != 0) {
            self.gpa.free(self.toast_paint);
            self.toast_paint = &.{};
        }
        const line = self.toasts.line(self.gpa, self.layout.cols, nowMs(self.io)) catch return;
        self.toast_paint = line;
    }

    /// Name the tab for the window it is, now that nothing is running in it.
    pub fn writeIdleTitle(self: *const Session) void {
        var buf: [96]u8 = undefined;
        self.stdout.writeAll(tui.idleTitleSeq(&buf, self.workspace, self.model())) catch |err| {
            log.debug("tab title: {s}", .{@errorName(err)});
        };
    }

    /// Move within the open run's calls. Returns false at either end so the
    /// caller can fall through to moving between runs instead.
    pub fn moveChild(self: *Session, back: bool) bool {
        if (self.sel >= self.runs.items.items.len) return false;
        const rec = &self.runs.items.items[self.sel];
        if (!rec.expanded or !rec.openable()) return false;
        const n = rec.details.len;
        if (back) {
            if (self.child == 0) return false;
            self.child -= 1;
        } else {
            if (self.child + 1 >= n) return false;
            self.child += 1;
        }
        self.dirty = true;
        return true;
    }

    pub fn extendSel(self: *Session, row: u16, col: u16) void {
        if (!self.dragging or self.marked.where == .none) return;
        const at = self.selPoint(row, col) orelse return;
        // A drag that leaves the region it started in stops there rather than
        // jumping: half a selection in each is not a thing you can copy.
        if (at.where != self.marked.where) return;
        if (self.marked.b_row == at.row and self.marked.b_col == at.col) return;
        self.marked.b_row = at.row;
        self.marked.b_col = at.col;
        self.dirty = true;
    }

    pub fn clearSel(self: *Session) void {
        if (self.marked.where == .none) return;
        self.marked = .{};
        self.dirty = true;
    }

    const Point = struct { where: tui.Sel.Where, row: usize, col: u16 };

    /// The region and cell a screen position falls in, or null for chrome.
    pub fn selPoint(self: *Session, row: u16, col: u16) ?Point {
        const cell: u16 = if (col == 0) 0 else col - 1;
        if (tui.transcriptRowAt(self.layout, &self.shown, self.scroll, row)) |idx| {
            return .{ .where = .transcript, .row = idx, .col = cell };
        }
        if (tui.inComposer(self.layout, row)) {
            return .{ .where = .composer, .row = 0, .col = cell };
        }
        return null;
    }

    /// The marked text, plain, one row per line.
    pub fn selText(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        switch (self.marked.where) {
            .none => {},
            .transcript => {
                const o = self.marked.ordered();
                var i = o.a_row;
                while (i <= o.b_row and i < self.shown.rowCount()) : (i += 1) {
                    const row = self.shown.row(i);
                    if (self.marked.span(i, tui.width.cellsTo(row))) |h| {
                        try tui.plainCells(&out, allocator, row, h.from, h.to);
                    }
                    if (i != o.b_row) try out.append(allocator, '\n');
                }
            },
            .composer => {
                // Cells are counted from the start of the row, prompt
                // included, so the prompt has to be there when they are read.
                const text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.state.composer, self.draft.items() });
                defer allocator.free(text);
                if (self.marked.span(0, tui.width.cellsTo(text))) |h| {
                    try tui.plainCells(&out, allocator, text, h.from, h.to);
                }
            },
        }
        return out.toOwnedSlice(allocator);
    }

    /// Letting go copies. With the terminal's own selection gone there is
    /// nothing else that would put the text on the clipboard.
    pub fn copySel(self: *Session, allocator: std.mem.Allocator) void {
        if (!self.marked.on()) return;
        const text = self.selText(allocator) catch return;
        defer allocator.free(text);
        if (text.len == 0) return;
        self.note(if (cmds.copyClipboard(self.io, text))
            std.fmt.allocPrint(self.arena, "Copied {d} characters.", .{text.len}) catch "Copied."
        else
            "No clipboard tool on this machine.", nowMs(self.io));
    }

    /// The task list as sticky chrome rows above the composer, or none when
    /// every item is done (a finished checklist is just noise).
    pub fn pinTodos(self: *Session, rows: [][]const u8) []const []const u8 {
        const list = &self.tasks;
        if (list.n == 0) return &.{};
        const c = list.counts();
        if (c.done == c.total) return &.{};
        var n: usize = 0;
        for (list.items[0..list.n]) |item| {
            if (n == rows.len) break;
            rows[n] = chat.formatTodo(self.arena, self.layout.cols, item.slice(), item.status == .in_progress, item.status == .done) catch continue;
            n += 1;
        }
        return rows[0..n];
    }

    /// Transcript rows available to scroll after sticky chrome is reserved.
    pub fn scrollRows(self: *const Session) u16 {
        var todo_n: u16 = 0;
        const list = &self.tasks;
        if (list.n != 0) {
            const c = list.counts();
            if (c.done != c.total) todo_n = @intCast(@min(list.n, std.math.maxInt(u16)));
        }
        const overlay = todo_n + @as(u16, if (tui.jumpVisible(self.scroll, self.layout.transcript_rows)) 1 else 0);
        const full = self.layout.transcript_rows;
        return if (full > overlay) full - overlay else full;
    }

    /// Repaint the transcript alone. The footer is painted by the dirty pass.
    /// Shrink the scroll region by sticky chrome so wheel/page paints cannot
    /// overwrite the todo list sitting above the composer.
    pub fn paintTranscript(self: *Session) void {
        self.shown.resize(self.layout.cols) catch |err| {
            log.debug("transcript resize: {s}", .{@errorName(err)});
        };
        const overlay: u16 = self.layout.transcript_rows -| self.scrollRows();
        tui.writeTranscriptOverlay(self.stdout, self.layout, &self.shown, self.scroll, self.marked, overlay) catch |err| {
            log.debug("writeTranscript: {s}", .{@errorName(err)});
        };
        self.stdout.flush() catch |err| {
            log.debug("flush: {s}", .{@errorName(err)});
        };
    }

    /// Wheel and page keys must not paint the transcript alone: that CUP-parks
    /// the caret in the pane. A no-op step (content already fits) must not
    /// mark dirty either, or the pane flickers as if it scrolled.
    pub fn bumpScroll(self: *Session, up: bool, step: u16) bool {
        const next = tui.stepScroll(
            self.scroll,
            self.shown.rowCount(),
            self.scrollRows(),
            up,
            step,
        );
        if (next == self.scroll) return false;
        self.scroll = next;
        return true;
    }

    pub fn paintAll(self: *Session, turn: tui.Turn) void {
        self.shown.resize(self.layout.cols) catch |err| {
            log.debug("transcript resize: {s}", .{@errorName(err)});
        };
        var todo_rows: [todo_mod.max_items][]const u8 = undefined;
        var foot = self.footer(turn);
        foot.tasks = self.pinTodos(&todo_rows);
        tui.writePane(self.gpa, self.stdout, self.layout, foot, &self.shown, self.scroll) catch |err| {
            log.debug("writePane: {s}", .{@errorName(err)});
        };
        self.publishJumpHit();
        self.stdout.flush() catch |err| {
            log.debug("flush: {s}", .{@errorName(err)});
        };
    }

    /// Replace the token under the caret with the highlighted palette row.
    /// Returns true when it filled an `@mention`, which is an argument the user
    /// is still writing rather than a whole line ready to send.
    ///
    /// Tab, click, and Enter each did this by hand in three copies that had
    /// already drifted: two closed the menu, one only moved the selection.
    pub fn completePalette(self: *Session) !bool {
        if (self.palette.len == 0) return false;
        const picked = self.palette[self.palette_sel].name;
        const at = tui.atPrefix(self.draft.items());
        if (at) |pre| {
            const items = self.draft.items();
            try self.draft.replace(self.gpa, items[0 .. items.len - (pre.len + 1)]);
        } else {
            self.draft.clear();
        }
        try self.draft.insertSlice(self.gpa, picked);
        self.clearPalette();
        return at != null;
    }

    /// Paint the panel over the pane. Returns whether another frame is due, so
    /// the loop only polls fast while something is actually moving.
    pub fn paintPanel(self: *Session) bool {
        const p = &(self.panel orelse return false);
        p.elapsed_ms = nowMs(self.io) - self.panel_opened_ms;
        p.edit = self.panel_edit.items;
        const g = panel_mod.geometry(self.layout.rows, self.layout.cols, p.n);
        const body = panel_mod.render(self.arena, p, g) catch return false;
        self.stdout.writeAll(tui.sync_begin) catch return false;
        // The pane is repainted underneath first. A panel only erases its own
        // footprint, so whatever the pane drew around it -- the welcome card in
        // particular -- stayed on screen framing the panel with orphaned rows.
        self.shown.resize(self.layout.cols) catch |err| {
            log.debug("transcript resize: {s}", .{@errorName(err)});
        };
        tui.writePane(self.gpa, self.stdout, self.layout, self.footer(.idle), &self.shown, self.scroll) catch |err| {
            log.debug("writePane: {s}", .{@errorName(err)});
        };
        self.stdout.writeAll(tui.hide_cursor) catch |err| {
            log.debug("hide cursor: {s}", .{@errorName(err)});
        };
        self.stdout.writeAll(body) catch |err| {
            log.debug("panel: {s}", .{@errorName(err)});
        };
        self.stdout.writeAll(tui.sync_end) catch |err| {
            log.debug("sync: {s}", .{@errorName(err)});
        };
        self.stdout.flush() catch |err| {
            log.debug("flush: {s}", .{@errorName(err)});
        };
        return panel_mod.animating(p.elapsed_ms);
    }

    pub fn openPanel(self: *Session, p: panel_mod.Panel) void {
        self.panel = p;
        self.panel_opened_ms = nowMs(self.io);
        self.panel_edit.clearRetainingCapacity();
        self.panel_kind = null;
    }

    /// How long a one-line confirmation holds the hint row.
    ///
    /// Long enough to read a short sentence at a glance, short enough that the
    /// keys you actually need are back before you look for them.
    pub const note_ms: i64 = 3000;

    pub fn note(self: *Session, text: []const u8, now_ms: i64) void {
        self.mode_note = text;
        self.mode_note_at = now_ms;
        self.toasts.push(text, now_ms);
        self.dirty = true;
    }

    /// A finished menu step leaves its confirmation here rather than in the
    /// transcript, so it clears itself the way every other one-line answer
    /// does.
    pub fn takeMenuNote(self: *Session, out: *menus.Out, now_ms: i64) void {
        if (out.note.len == 0) return;
        self.note(out.note, now_ms);
        out.note = "";
    }

    pub fn noteClear(self: *Session) void {
        self.mode_note = "";
        self.mode_note_at = 0;
        self.toasts = .{};
        if (self.toast_paint.len != 0) {
            self.gpa.free(self.toast_paint);
            self.toast_paint = &.{};
        }
    }

    pub fn noteExpired(self: *const Session, now_ms: i64) bool {
        if (self.mode_note.len == 0) return false;
        return now_ms - self.mode_note_at >= note_ms;
    }

    pub fn closePanel(self: *Session) void {
        self.panel = null;
        self.panel_kind = null;
        self.panel_edit.clearRetainingCapacity();
        self.dirty = true;
    }

    pub fn clearPalette(self: *Session) void {
        self.palette = &.{};
        self.palette_sel = 0;
    }
};
