const std = @import("std");
const Io = std.Io;

const tui = @import("tui.zig");
const activity = @import("activity.zig");
const panel_mod = @import("panel.zig");
const runs_mod = @import("runs.zig");
const draft_mod = @import("draft.zig");
const statusline_mod = @import("statusline.zig");
const tty = @import("tty.zig");
const cmds = @import("cmds.zig");
const jobs = @import("../tools/jobs.zig");
const skills = @import("../core/skills.zig");
const todos = @import("../core/todos.zig");
const paint = @import("../core/ansi.zig");
const live_mod = @import("live.zig");
const chat = @import("chat.zig");
const ask_run = @import("run.zig");
const slash = @import("../core/slash.zig");
const agent = @import("../core/agent.zig");
const autoeffort = @import("../core/autoeffort.zig");
const deadline = @import("../tools/deadline.zig");
const settings = @import("../core/settings.zig");
const session = @import("../core/session.zig");
const mention = @import("../core/mention.zig");
const vision = @import("../core/vision.zig");
const playbook = @import("../core/playbook.zig");
const permissions = @import("../core/permissions.zig");
const config = @import("../core/config.zig");
const env = @import("../core/env.zig");
const cli = @import("../core/cli.zig");
const catalog = @import("../providers/catalog.zig");
const models = @import("../providers/models.zig");
const auth = @import("../providers/auth.zig");
const types = @import("../providers/types.zig");
const pathing = @import("../tools/pathing.zig");
const relay = @import("../tools/relay.zig");
const sound_mod = @import("sound.zig");
const diagram = @import("../core/diagram.zig");
const sink = @import("../core/sink.zig");
const toast_mod = @import("toast.zig");
const diffview = @import("diffview.zig");
const board = @import("../core/board.zig");
const progress = @import("progress.zig");
const runlog = @import("../core/runlog.zig");
const menus = @import("menus.zig");

const log = std.log.scoped(.repl);

fn toEndpoint(arena: std.mem.Allocator, resolved_opt: ?catalog.Resolved) ?types.Endpoint {
    const resolved = resolved_opt orelse return null;
    return catalog.ownedEndpoint(arena, resolved);
}

/// `auto` is resolved here, at the last possible moment, because the level it
/// picks depends on the prompt that is about to be sent and on how the last
/// turns went. Every other level passes through unchanged.
fn applyEffort(endpoint: *types.Endpoint, effort: []const u8, ladder: []const u8, prompt: []const u8, failures: usize) void {
    if (effort.len == 0) return;
    if (!std.mem.eql(u8, effort, cmds.auto_effort)) {
        endpoint.effort = effort;
        return;
    }
    const picked = autoeffort.resolve(ladder, prompt, failures);
    if (picked.len > 0) endpoint.effort = picked;
}

fn nowMs(io: Io) i64 {
    return Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
}

/// Everything the event loop mutates, in one place.
///
/// These used to be twenty-odd locals in `run`, which is why building a
/// `cmds.Ctx` took eleven arguments and appeared fourteen times. With the state
/// named, the context is built once and the loop can hand out `&self.state`.
const Session = struct {
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

    fn deinit(self: *Session) void {
        self.runs.deinit();
        self.panel_edit.deinit(self.gpa);
        self.draft.deinit(self.gpa);
        self.hist.deinit(self.gpa);
        self.palette_stash.deinit(self.gpa);
        self.shown.deinit();
        self.state.deinit(self.gpa);
    }

    fn toTranscript(self: *const Session) []const u8 {
        return self.cups.toTranscript();
    }

    fn cmdCtx(self: *Session) cmds.Ctx {
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

    fn model(self: *const Session) []const u8 {
        return if (self.state.resolved) |r| r.model else self.fallback_model;
    }

    fn footer(self: *Session, turn: tui.Turn) tui.Footer {
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

    fn publishJumpHit(self: *Session) void {
        if (tui.jumpVisible(self.scroll, self.layout.transcript_rows)) {
            if (tui.jumpHitBox(self.layout)) |box| {
                sink.setJumpHit(true, box.row, box.col0, box.col1);
                return;
            }
        }
        sink.setJumpHit(false, 0, 0, 0);
    }

    /// Re-pin to the live tail. During a turn that resumes stick-to-stream.
    fn jumpToBottom(self: *Session) bool {
        if (self.scroll == 0) return false;
        self.scroll = 0;
        self.dirty = true;
        return true;
    }

    fn tryJumpClick(self: *Session, row: u16, col: u16) bool {
        if (!tui.jumpVisible(self.scroll, self.layout.transcript_rows)) return false;
        if (!tui.jumpHit(self.layout, row, col)) return false;
        return self.jumpToBottom();
    }

    fn refreshToast(self: *Session) void {
        if (self.toast_paint.len != 0) {
            self.gpa.free(self.toast_paint);
            self.toast_paint = &.{};
        }
        const line = self.toasts.line(self.gpa, self.layout.cols, nowMs(self.io)) catch return;
        self.toast_paint = line;
    }

    /// Name the tab for the window it is, now that nothing is running in it.
    fn writeIdleTitle(self: *const Session) void {
        var buf: [96]u8 = undefined;
        self.stdout.writeAll(tui.idleTitleSeq(&buf, self.workspace, self.model())) catch |err| {
            log.debug("tab title: {s}", .{@errorName(err)});
        };
    }

    /// Open or close the tool run a click landed on.
    ///
    /// The transcript is append-only everywhere else. A run is the one span
    /// that is re-rendered in place, because its calls belong where the run is
    /// and not at the bottom of the pane.
    /// Re-render one run's bytes where they already sit.
    fn redrawRun(self: *Session, rec: *runs_mod.Store.Rec) bool {
        // A cleared transcript leaves records pointing at bytes that are gone.
        if (rec.off + rec.len > self.shown.bytes().len) return false;
        const focus: ?usize = if (rec.childOpen(self.child) and self.hunk_n > 0) self.hunk_i else null;
        const next = runs_mod.renderFocus(self.gpa, self.layout.cols, rec.*, focus) catch return false;
        defer self.gpa.free(next);
        const was = rec.len;
        self.shown.replace(rec.off, was, next) catch return false;
        rec.len = next.len;
        self.runs.shift(rec.off, @as(isize, @intCast(next.len)) - @as(isize, @intCast(was)));
        self.dirty = true;
        return true;
    }

    fn syncHunkNav(self: *Session, rec: *const runs_mod.Store.Rec) void {
        if (!rec.expanded or !rec.childOpen(self.child) or self.child >= rec.bodies.len) {
            self.hunk_i = 0;
            self.hunk_n = 0;
            return;
        }
        const body = rec.bodies[self.child];
        if (!chat.looksLikeDiff(body)) {
            self.hunk_i = 0;
            self.hunk_n = 0;
            return;
        }
        self.hunk_n = diffview.hunkCount(body);
        if (self.hunk_n == 0) {
            self.hunk_i = 0;
            return;
        }
        if (self.hunk_i >= self.hunk_n) self.hunk_i = self.hunk_n - 1;
    }

    fn stepHunk(self: *Session, forward: bool) bool {
        if (self.focus != .scrollback or self.sel >= self.runs.items.items.len) return false;
        const rec = &self.runs.items.items[self.sel];
        self.syncHunkNav(rec);
        if (self.hunk_n == 0) return false;
        if (forward) {
            self.hunk_i = (self.hunk_i + 1) % self.hunk_n;
        } else {
            self.hunk_i = if (self.hunk_i == 0) self.hunk_n - 1 else self.hunk_i - 1;
        }
        return self.redrawRun(rec);
    }

    fn mark(self: *Session, i: usize, on: bool) void {
        if (i >= self.runs.items.items.len) return;
        const rec = &self.runs.items.items[i];
        if (rec.selected == on) return;
        rec.selected = on;
        _ = self.redrawRun(rec);
    }

    /// Move the keyboard into the scrollback, on the newest run.
    fn focusScrollback(self: *Session) bool {
        if (self.focus == .scrollback) return true;
        if (self.runs.items.items.len == 0) return false;
        self.focus = .scrollback;
        self.sel = self.runs.items.items.len - 1;
        self.mark(self.sel, true);
        self.showRun(self.sel);
        self.dirty = true;
        return true;
    }

    fn blurScrollback(self: *Session) void {
        if (self.focus == .prompt) return;
        self.mark(self.sel, false);
        self.focus = .prompt;
        self.dirty = true;
    }

    fn moveSel(self: *Session, back: bool) void {
        const n = self.runs.items.items.len;
        if (n == 0) return;
        const next = if (back)
            (if (self.sel == 0) n - 1 else self.sel - 1)
        else
            (if (self.sel + 1 >= n) 0 else self.sel + 1);
        if (next == self.sel) return;
        self.mark(self.sel, false);
        self.sel = next;
        self.mark(self.sel, true);
        self.showRun(self.sel);
    }

    /// First or last run, for `g` and `G`.
    fn selectEnd(self: *Session, last: bool) void {
        const n = self.runs.items.items.len;
        if (n == 0) return;
        const next = if (last) n - 1 else 0;
        if (next == self.sel) return;
        self.mark(self.sel, false);
        self.sel = next;
        self.mark(self.sel, true);
        self.showRun(self.sel);
    }

    /// `want` null toggles; otherwise open or close explicitly.
    fn setExpanded(self: *Session, want: ?bool) void {
        if (self.sel >= self.runs.items.items.len) return;
        const rec = &self.runs.items.items[self.sel];
        if (!rec.openable()) return;
        const next = want orelse !rec.expanded;
        if (next == rec.expanded) return;
        rec.expanded = next;
        // Closing a run closes what was open inside it: reopening should not
        // hand back a body you had already dismissed.
        if (!next) rec.open_bits = 0;
        self.child = 0;
        _ = self.redrawRun(rec);
        self.showRun(self.sel);
    }

    /// Move within the open run's calls. Returns false at either end so the
    /// caller can fall through to moving between runs instead.
    fn moveChild(self: *Session, back: bool) bool {
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

    /// Open the call the keyboard is on, or close it if it is already open.
    /// Pressing it again on the same call is what closes it: one gesture, and
    /// it is its own undo.
    fn toggleChild(self: *Session) bool {
        if (self.sel >= self.runs.items.items.len) return false;
        const rec = &self.runs.items.items[self.sel];
        if (!rec.expanded or !rec.openable()) return false;
        if (self.child >= rec.details.len) return false;
        rec.toggleChildBit(self.child);
        _ = self.redrawRun(rec);
        self.showRun(self.sel);
        return true;
    }

    /// Anchor a selection where the button went down. Chrome -- the header,
    /// the welcome card, the hint row -- has no region, so a drag there marks
    /// nothing.
    fn startSel(self: *Session, row: u16, col: u16) void {
        self.dragging = true;
        // Jump pill: press must not start a selection; release performs the jump.
        if (tui.jumpVisible(self.scroll, self.layout.transcript_rows) and tui.jumpHit(self.layout, row, col)) {
            self.dragging = false;
            self.clearSel();
            return;
        }
        // The counter is the only thing in the header, and clicking a number
        // to ask what it is made of is the gesture people already try.
        if (self.layout.header_rows != 0 and row == 1 and col + 16 > self.layout.cols) {
            self.openPanel(buildPanel(self, .context));
            return;
        }
        const at = self.selPoint(row, col) orelse {
            self.clearSel();
            // A press on chrome is a press away from what had the keyboard:
            // the composer is where typing goes, so that is where it lands.
            self.blurScrollback();
            return;
        };
        // Clicking the composer leaves the scrollback the same way esc does.
        if (at.where == .composer) self.blurScrollback();
        self.marked = .{ .where = at.where, .a_row = at.row, .a_col = at.col, .b_row = at.row, .b_col = at.col };
        self.dirty = true;
    }

    fn extendSel(self: *Session, row: u16, col: u16) void {
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

    fn clearSel(self: *Session) void {
        if (self.marked.where == .none) return;
        self.marked = .{};
        self.dirty = true;
    }

    const Point = struct { where: tui.Sel.Where, row: usize, col: u16 };

    /// The region and cell a screen position falls in, or null for chrome.
    fn selPoint(self: *Session, row: u16, col: u16) ?Point {
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
    fn selText(self: *Session, allocator: std.mem.Allocator) ![]u8 {
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
    fn copySel(self: *Session, allocator: std.mem.Allocator) void {
        if (!self.marked.on()) return;
        const text = self.selText(allocator) catch return;
        defer allocator.free(text);
        if (text.len == 0) return;
        self.note(if (cmds.copyClipboard(self.io, text))
            std.fmt.allocPrint(self.arena, "Copied {d} characters.", .{text.len}) catch "Copied."
        else
            "No clipboard tool on this machine.", nowMs(self.io));
    }

    /// A click on a tool run: the summary toggles the run, a call toggles its
    /// output, and clicking the same thing again puts it back. Every gesture
    /// is its own undo, so nothing needs a second key to close.
    fn clickRun(self: *Session, term_row: u16) void {
        // A click on transcript text that is not a run is a click away from
        // the run tree, so it hands the keyboard back rather than leaving you
        // in a mode whose keys the hint row is still advertising.
        const row = tui.transcriptRowAt(self.layout, &self.shown, self.scroll, term_row) orelse {
            self.blurScrollback();
            return;
        };
        const off = self.shown.rowOffset(row) orelse {
            self.blurScrollback();
            return;
        };
        const idx = self.runs.indexAt(off) orelse {
            self.blurScrollback();
            return;
        };
        const rec = &self.runs.items.items[idx];
        const part = runs_mod.partAt(self.arena, self.layout.cols, rec.*, off - rec.off) catch return orelse return;

        // Clicking a run also moves the keyboard onto it, so the pointer and
        // the keys never disagree about which run is current.
        if (self.focus == .scrollback and self.sel != idx) self.mark(self.sel, false);
        self.focus = .scrollback;
        self.sel = idx;
        self.mark(idx, true);

        switch (part) {
            .summary => {
                if (!rec.openable()) {
                    self.dirty = true;
                    return;
                }
                rec.expanded = !rec.expanded;
                if (!rec.expanded) rec.open_bits = 0;
                self.child = 0;
                self.hunk_i = 0;
            },
            .child => |i| {
                self.child = i;
                rec.toggleChildBit(i);
                self.hunk_i = 0;
            },
        }
        self.syncHunkNav(rec);
        _ = self.redrawRun(rec);
        self.showRun(idx);
        self.dirty = true;
    }

    /// Open every run, or close them all when they are already open.
    fn expandAll(self: *Session) void {
        var want = false;
        for (self.runs.items.items) |r| {
            if (r.openable() and !r.expanded) want = true;
        }
        var i: usize = 0;
        while (i < self.runs.items.items.len) : (i += 1) {
            const rec = &self.runs.items.items[i];
            if (!rec.openable() or rec.expanded == want) continue;
            rec.expanded = want;
            _ = self.redrawRun(rec);
        }
        self.showRun(self.sel);
    }

    /// The selected run's calls, one per line, on the clipboard.
    fn copyRun(self: *Session) void {
        if (self.sel >= self.runs.items.items.len) return;
        const rec = self.runs.items.items[self.sel];
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        for (rec.details) |d| {
            out.appendSlice(self.gpa, d) catch return;
            out.append(self.gpa, '\n') catch return;
        }
        self.note(if (cmds.copyClipboard(self.io, out.items))
            "Copied the run's commands."
        else
            "No clipboard tool on this machine.", nowMs(self.io));
    }

    /// The run's output rather than the commands that produced it.
    /// The output of the call the cursor is on, which is the half `y` does
    /// not take: `y` copies what was run, this copies what came back.
    fn copyRunOutput(self: *Session) void {
        if (self.sel >= self.runs.items.items.len) return;
        const rec = self.runs.items.items[self.sel];
        if (self.child >= rec.bodies.len) return;
        const body = rec.bodies[self.child];
        if (body.len == 0) {
            self.note("That call returned nothing.", nowMs(self.io));
            return;
        }
        self.note(if (cmds.copyClipboard(self.io, body))
            std.fmt.allocPrint(self.arena, "Copied {d} characters of output.", .{body.len}) catch "Copied."
        else
            "No clipboard tool on this machine.", nowMs(self.io));
    }

    /// Jump to the previous or next tool run, skipping the ones in between.
    /// Turn-to-turn is the unit you read a transcript in.
    fn selectTurn(self: *Session, back: bool) void {
        const n = self.runs.items.items.len;
        if (n == 0) return;
        const next = if (back)
            (if (self.sel == 0) 0 else self.sel - 1)
        else
            (if (self.sel + 1 >= n) n - 1 else self.sel + 1);
        if (next == self.sel) return;
        self.mark(self.sel, false);
        self.sel = next;
        self.mark(self.sel, true);
        self.showRun(self.sel);
    }

    /// Scroll just enough to bring a run's first row into the pane.
    fn showRun(self: *Session, i: usize) void {
        if (i >= self.runs.items.items.len) return;
        const row = self.shown.rowOfOffset(self.runs.items.items[i].off) orelse return;
        const total = self.shown.rowCount();
        const rows = self.scrollRows();
        if (rows == 0 or total <= rows) {
            self.scroll = 0;
            return;
        }
        const max = tui.maxScroll(total, rows);
        var s = @min(self.scroll, max);
        const start = total - rows - s;
        if (row < start) {
            s = if (total > rows + row) total - rows - row else max;
        } else if (row >= start + rows) {
            s = if (total > row + 1) total - row - 1 else 0;
        }
        self.scroll = @min(s, max);
    }

    /// The task list as sticky chrome rows above the composer, or none when
    /// every item is done (a finished checklist is just noise).
    fn pinTodos(self: *Session, rows: [][]const u8) []const []const u8 {
        const list = todos.get();
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
    fn scrollRows(self: *const Session) u16 {
        var todo_n: u16 = 0;
        const list = todos.get();
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
    fn paintTranscript(self: *Session) void {
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
    fn bumpScroll(self: *Session, up: bool, step: u16) bool {
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

    fn paintAll(self: *Session, turn: tui.Turn) void {
        self.shown.resize(self.layout.cols) catch |err| {
            log.debug("transcript resize: {s}", .{@errorName(err)});
        };
        var todo_rows: [todos.max_items][]const u8 = undefined;
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
    fn completePalette(self: *Session) !bool {
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
    fn paintPanel(self: *Session) bool {
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

    fn openPanel(self: *Session, p: panel_mod.Panel) void {
        self.panel = p;
        self.panel_opened_ms = nowMs(self.io);
        self.panel_edit.clearRetainingCapacity();
        self.panel_kind = null;
    }

    /// A panel whose list is rebuilt as you type.
    fn openSearchPanel(self: *Session, kind: cmds.PanelKind) void {
        self.openPanel(buildPanel(self, kind));
        self.panel_kind = kind;
        if (self.panel) |*p| {
            p.search = true;
            p.query = self.panel_edit.items;
            p.selectFirst();
        }
    }

    /// Re-runs the builder against what has been typed. The reveal is not
    /// restarted: the panel is already open, only its rows changed.
    fn refilterPanel(self: *Session) void {
        const kind = self.panel_kind orelse return;
        var next = buildPanel(self, kind);
        next.search = true;
        next.query = self.panel_edit.items;
        next.selectFirst();
        self.panel = next;
        self.dirty = true;
    }

    /// How long a one-line confirmation holds the hint row.
    ///
    /// Long enough to read a short sentence at a glance, short enough that the
    /// keys you actually need are back before you look for them.
    const note_ms: i64 = 3000;

    fn note(self: *Session, text: []const u8, now_ms: i64) void {
        self.mode_note = text;
        self.mode_note_at = now_ms;
        self.toasts.push(text, now_ms);
        self.dirty = true;
    }

    /// A finished menu step leaves its confirmation here rather than in the
    /// transcript, so it clears itself the way every other one-line answer
    /// does.
    fn takeMenuNote(self: *Session, out: *menus.Out, now_ms: i64) void {
        if (out.note.len == 0) return;
        self.note(out.note, now_ms);
        out.note = "";
    }

    fn noteClear(self: *Session) void {
        self.mode_note = "";
        self.mode_note_at = 0;
        self.toasts = .{};
        if (self.toast_paint.len != 0) {
            self.gpa.free(self.toast_paint);
            self.toast_paint = &.{};
        }
    }

    fn noteExpired(self: *const Session, now_ms: i64) bool {
        if (self.mode_note.len == 0) return false;
        return now_ms - self.mode_note_at >= note_ms;
    }

    fn closePanel(self: *Session) void {
        self.panel = null;
        self.panel_kind = null;
        self.panel_edit.clearRetainingCapacity();
        self.dirty = true;
    }

    fn clearPalette(self: *Session) void {
        self.palette = &.{};
        self.palette_sel = 0;
    }
};

/// Editors omfx knows how to look for, in the order a picker should offer
/// them: the graphical ones people configure deliberately first, then the
/// terminal ones that are almost always present.
const known_editors = [_][]const u8{
    "code", "cursor", "zed", "subl",  "windsurf",
    "hx",   "nvim",   "vim", "emacs", "nano",
    "vi",
};

/// One for "auto" plus every editor that could be found.
pub const max_editors: usize = known_editors.len + 1;

/// The editors actually on this machine. `auto` leads, because following
/// $VISUAL then $EDITOR is the right answer for most people and the only one
/// that keeps working when they change their mind elsewhere.
fn detectEditors(sess: *Session, out: [][]const u8) usize {
    out[0] = "auto";
    var n: usize = 1;
    const path = sess.lookup.get("PATH") orelse return n;
    for (known_editors) |name| {
        if (n == out.len) break;
        if (onPath(sess, path, name)) {
            out[n] = name;
            n += 1;
        }
    }
    return n;
}

fn onPath(sess: *Session, path: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        const st = Io.Dir.cwd().statFile(sess.io, full, .{}) catch continue;
        if (st.kind == .file) return true;
    }
    return false;
}

/// Rows are the same keys `/settings key=value` accepts, so the panel and the
/// one-shot form can never drift: this is the same setter, with a cursor.
fn buildPanel(sess: *Session, kind: cmds.PanelKind) panel_mod.Panel {
    return switch (kind) {
        .settings => settingsPanel(sess),
        .help => helpPanel(sess),
        .shortcuts => keysPanel(sess),
        .sessions => sessionPanel(sess),
        .statusline => statuslinePanel(sess),
        .status => statusPanel(sess),
        .rewind => rewindPanel(sess),
        .context => contextPanel(sess),
        .jobs => jobsPanel(sess),
        .workspace => workspacePanel(sess),
        .plan => planPanel(sess),
        .files => filesPanel(sess),
        .peers => peersPanel(sess),
    };
}

fn settingsPanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    var p = panel_mod.Panel{ .title = "Settings" };
    p.add(.{
        .key = "sound",
        .label = "Sound",
        .kind = .toggle,
        .value = if (sess.state.sound) "on" else "off",
        .help = "chime on launch and when a turn finishes",
    });
    p.add(.{
        .key = "thinking",
        .label = "Show thinking",
        .kind = .toggle,
        .value = if (sess.state.thinking) "on" else "off",
        .help = "show the assistant's thinking while it works",
    });
    p.add(.{
        .key = "telemetry",
        .label = "Telemetry",
        .kind = .toggle,
        .value = if (sess.state.telemetry) "on" else "off",
        .help = "only says which app is talking; off keeps you anonymous",
    });
    p.add(.{
        .key = "peer",
        .label = "Auto teammates",
        .kind = .toggle,
        .value = if (settings.peerAutoOn(cfg)) "on" else "off",
        .help = "lets the assistant ask a teammate on its own; /peers still works anytime",
    });
    p.add(.{
        .key = "statusline",
        .label = "Status line",
        .kind = .toggle,
        .value = if (sess.state.statusline) "on" else "off",
        .help = "model and mode under the composer",
    });
    p.add(.{
        .key = "mode",
        .label = "Permissions",
        // The three surfaces `shift-tab` cycles, spelled the way `config.Surface`
        // spells them -- a list that disagrees makes every value read as index 0.
        .kind = .{ .choice = &.{ "normal", "plan", "yolo" } },
        .value = cmds.footerPerm(&sess.state),
        .help = "normal prompts, plan is read-only, yolo allows writes",
    });
    p.add(.{
        .key = "sandbox",
        .label = "Sandbox",
        .kind = .{ .choice = &.{ "on", "off" } },
        .value = if (settings.sandboxOff(cfg)) "off" else "on",
        .help = "OS sandbox on bash, network denied",
    });
    var editors: [max_editors][]const u8 = undefined;
    const found = detectEditors(sess, &editors);
    p.add(.{
        .key = "editor",
        .label = "Editor",
        // A choice of what is installed, not a name you have to spell: the
        // wrong spelling fails at ctrl-g, an hour after you typed it.
        .kind = .{ .choice = editors[0..found] },
        .value = if (cfg.editor.len == 0) editors[0] else sess.arena.dupe(u8, cfg.editor) catch editors[0],
        .help = "ctrl-g opens this; auto follows $VISUAL then $EDITOR",
    });
    p.add(.{
        .key = "bash_timeout",
        .label = "Command timeout",
        .kind = .{ .number = .{ .min = 0, .max = 3600, .step = 30 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.bash_timeout}) catch "0",
        .help = "seconds a bash command may run; 0 is the default 120",
    });
    p.add(.{
        .key = "keep_sessions",
        .label = "Keep sessions",
        .kind = .{ .number = .{ .min = 0, .max = 1000, .step = 10 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.keep_sessions}) catch "0",
        .help = "saved sessions kept on disk; 0 keeps every one",
    });
    p.add(.{
        .key = "max_peer_depth",
        .label = "Peer depth",
        .kind = .{ .number = .{ .min = 0, .max = 8 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.max_peer_depth}) catch "1",
        .help = "how many levels of teammate a peer may spawn",
    });
    const path = settings.path(sess.arena, sess.home) catch "";
    p.add(.{ .key = "path", .label = "File", .kind = .info, .value = path });
    return p;
}

/// Writes one field through to disk and to the live session, then rebuilds the
/// panel so what is on screen is what was actually saved.
fn applyPanelField(sess: *Session, p: panel_mod.Panel, value: []const u8) void {
    const f = p.current() orelse return;
    var ctx = sess.cmdCtx();

    // A status-line field toggle edits one entry of a list, not a scalar, so
    // it is rewritten here rather than passed straight to the setter.
    if (std.mem.startsWith(u8, f.key, "field:")) {
        var cfg = settings.load(sess.gpa, sess.io, sess.home);
        defer cfg.deinit(sess.gpa);
        var sl = statusline_mod.parse(cfg.statusline_place, cfg.statusline_fields);
        const name = f.key["field:".len..];
        if (statusline_mod.Field.fromSlice(name)) |fld| {
            if (std.mem.eql(u8, value, "on")) sl.add(fld) else sl.remove(fld);
        }
        var buf: [160]u8 = undefined;
        const encoded = sl.encode(&buf);
        const line2 = std.fmt.allocPrint(sess.arena, "statusline_fields={s}", .{encoded}) catch return;
        _ = cmds.applySetting(&ctx, line2) catch {};
        const sel2 = p.sel;
        var next2 = statuslinePanel(sess);
        next2.sel = sel2;
        next2.elapsed_ms = panel_mod.open_ms;
        sess.panel = next2;
        return;
    }
    // A statusline placement rebuilds its own panel, not the settings one.
    const is_statusline = std.mem.eql(u8, f.key, "statusline_place");
    const line = std.fmt.allocPrint(sess.arena, "{s}={s}", .{ f.key, value }) catch return;
    // Same path as `/settings key=value`: one setter, no second source of truth.
    _ = cmds.applySetting(&ctx, line) catch {};
    const sel = p.sel;
    var next = if (is_statusline) statuslinePanel(sess) else settingsPanel(sess);
    next.sel = sel;
    next.elapsed_ms = panel_mod.open_ms;
    sess.panel = next;
}

fn togglePanelField(sess: *Session) void {
    const p = sess.panel orelse return;
    const f = p.current() orelse return;
    if (f.kind != .toggle) return;
    applyPanelField(sess, p, if (std.mem.eql(u8, f.value, "on")) "off" else "on");
}

/// Left/right on a choice cycles the list; on a number it steps within bounds.
fn stepPanelValue(sess: *Session, forward: bool) void {
    const p = sess.panel orelse return;
    const f = p.current() orelse return;
    switch (f.kind) {
        .choice => |opts| {
            if (opts.len == 0) return;
            var at: usize = 0;
            for (opts, 0..) |o, i| {
                if (std.mem.eql(u8, o, f.value)) at = i;
            }
            const n: i32 = @intCast(opts.len);
            const next = @mod(@as(i32, @intCast(at)) + (if (forward) @as(i32, 1) else -1) + n, n);
            applyPanelField(sess, p, opts[@intCast(next)]);
        },
        .number => |b| {
            const cur = std.fmt.parseInt(u32, f.value, 10) catch b.min;
            const stepped: u32 = if (forward)
                @min(b.max, cur +| b.step)
            else if (cur <= b.step) b.min else @max(b.min, cur - b.step);
            const text = std.fmt.allocPrint(sess.arena, "{d}", .{stepped}) catch return;
            applyPanelField(sess, p, text);
        },
        .toggle => togglePanelField(sess),
        // Nothing to step: a pick is chosen with Enter, the rest are inert.
        .text, .info, .pick, .heading, .entry => {},
    }
}

/// Hands the draft to `$EDITOR`, then reads back whatever was saved.
///
/// The terminal has to be given back for the duration: an editor that inherits
/// raw mode and the alt screen paints into omfx's buffer instead of its own.
fn editDraftExternally(sess: *Session) !void {
    // Settings first: $EDITOR is the machine's answer, the setting is this
    // user's answer for omfx specifically.
    const editor = if (sess.state.editor.len != 0)
        sess.state.editor
    else
        sess.lookup.get("VISUAL") orelse sess.lookup.get("EDITOR") orelse "vi";
    const path = try std.fmt.allocPrint(sess.arena, "{s}/.omfx/draft.txt", .{sess.workspace});
    const dir = try std.fmt.allocPrint(sess.arena, "{s}/.omfx", .{sess.workspace});
    Io.Dir.cwd().createDirPath(sess.io, dir) catch return;
    {
        var f = Io.Dir.cwd().createFile(sess.io, path, .{ .truncate = true }) catch return;
        defer f.close(sess.io);
        var buf: [512]u8 = undefined;
        var w = f.writer(sess.io, &buf);
        w.interface.writeAll(sess.draft.items()) catch {};
        w.interface.flush() catch {};
    }

    // Leave the alt screen and cooked the terminal, or the editor draws into
    // omfx's screen and omfx keeps eating the keystrokes.
    sess.stdout.writeAll(tui.restoreSequence()) catch {};
    sess.stdout.flush() catch {};
    tty.restore();

    var child = std.process.spawn(sess.io, .{
        .argv = &.{ editor, path },
        .cwd = .{ .path = sess.workspace },
    }) catch {
        _ = tty.Raw.enter();
        return;
    };
    _ = child.wait(sess.io) catch {};

    _ = tty.Raw.enter();
    sess.stdout.writeAll(tui.enter_alt) catch {};
    sess.stdout.flush() catch {};

    const body = Io.Dir.cwd().readFileAlloc(sess.io, path, sess.arena, .limited(256 * 1024)) catch return;
    // A trailing newline is the editor's, not the prompt's.
    try sess.draft.replace(sess.gpa, std.mem.trimEnd(u8, body, "\n\r"));
    // Scratch only — do not leave draft.txt polluting the workspace tree.
    Io.Dir.cwd().deleteFile(sess.io, path) catch {};
}

/// Everything about this session, in one readable frame.
///
/// `/status` printed a `key=value` block into the transcript; the same facts in
/// a panel read as a dashboard and dismiss cleanly.
fn statusPanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    var p = panel_mod.Panel{ .title = "Status" };
    p.add(.{ .key = "", .label = "Model", .kind = .info, .value = sess.model() });
    p.add(.{
        .key = "",
        .label = "Provider",
        .kind = .info,
        .value = if (sess.state.resolved) |r| r.spec.id else "(none)",
    });
    p.add(.{ .key = "", .label = "Permissions", .kind = .info, .value = cmds.footerPerm(&sess.state) });
    p.add(.{
        .key = "",
        .label = "Sandbox",
        .kind = .info,
        .value = if (settings.sandboxOff(cfg)) "off" else "on",
    });
    p.add(.{ .key = "", .label = "Workspace", .kind = .info, .value = sess.workspace });
    p.add(.{
        .key = "",
        .label = "Session",
        .kind = .info,
        .value = if (sess.state.session_title.len > 0) sess.state.session_title else "(unsaved)",
    });
    p.add(.{
        .key = "",
        .label = "Background jobs",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{jobs.count()}) catch "0",
    });
    p.add(.{
        .key = "",
        .label = "Extra dirs",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{sess.state.extraSlice().len}) catch "0",
    });
    return p;
}

/// Background commands, with log size as soft progress.
fn jobsPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Background work" };
    var snap: [jobs.max_jobs]jobs.Job = undefined;
    for (jobs.snapshot(&snap)) |j| {
        const rel = jobs.logRel(sess.arena, j.id) catch "";
        const bytes = jobs.logBytes(sess.io, sess.workspace, j.id);
        const cap: u64 = @max(bytes, 64 * 1024);
        var bar_buf: [128]u8 = undefined;
        const bar = progress.render(&bar_buf, 48, bytes, cap, if (jobs.running(j)) "working" else "finished");
        p.add(.{
            .key = std.fmt.allocPrint(sess.arena, "/background kill {d}", .{j.id}) catch "",
            .label = std.fmt.allocPrint(sess.arena, "{d}  {s}", .{ j.id, if (jobs.running(j)) "still working" else "finished" }) catch "",
            .kind = .pick,
            .value = j.command(),
            .help = std.fmt.allocPrint(sess.arena, "{s} · {s} · enter stops it", .{ bar, rel }) catch "",
        });
    }
    if (p.n == 0) p.add(.{
        .key = "",
        .label = "Nothing running in the background",
        .kind = .info,
        .help = "Long commands can keep going while you chat",
    });
    p.selectFirst();
    return p;
}

/// Review the last plan: approve runs /plan go; lines are read-only checklist.
fn planPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Your plan" };
    const plan = if (sess.state.last_plan.len != 0) sess.state.last_plan else sess.state.last_reply;
    if (plan.len == 0) {
        p.add(.{
            .key = "",
            .label = "No plan yet",
            .kind = .info,
            .help = "Start plan mode, ask what you want, then come back here",
        });
        p.add(.{
            .key = "/plan on",
            .label = "Start planning",
            .kind = .pick,
            .help = "Looks around and drafts a plan — no changes until you say go",
        });
    } else {
        p.add(.{
            .key = "/plan go",
            .label = "Looks good — do it",
            .kind = .pick,
            .help = "Leaves plan mode and carries out the steps below",
        });
        p.add(.{
            .key = "/plan off",
            .label = "Keep planning",
            .kind = .pick,
            .help = "Stay in plan mode and keep refining",
        });
        p.add(.{ .key = "", .label = "Steps", .kind = .heading });
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, plan, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            if (n >= 40) {
                p.add(.{
                    .key = "",
                    .label = "…and more",
                    .kind = .info,
                    .help = "Only the first steps fit here",
                });
                break;
            }
            p.add(.{ .key = "", .label = t, .kind = .info });
            n += 1;
        }
    }
    p.selectFirst();
    return p;
}

/// Workspace file picker — picking inserts @path into the draft via the key.
fn filesPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Pick a file", .search = true };
    var store: [64][96]u8 = undefined;
    var rows: [64]slash.Spec = undefined;
    const n = tui.matchAt(Io.Dir.cwd(), sess.io, sess.arena, "", &store, rows[0..]);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = rows[i].name;
        p.add(.{
            .key = std.fmt.allocPrint(sess.arena, "@{s} ", .{name}) catch "",
            .label = name,
            .kind = .pick,
            .help = "enter adds this file to what you are typing",
        });
    }
    if (p.n == 0) p.add(.{
        .key = "",
        .label = "No files found here",
        .kind = .info,
        .help = "Type to search, or check you are in the right folder",
    });
    p.selectFirst();
    return p;
}

/// Peer / board status — goals and recent board notes.
fn peersPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Teammates" };
    p.add(.{
        .key = "",
        .label = "How it works",
        .kind = .info,
        .help = "A teammate works on a goal in the background. Turn Auto teammates on in Settings if you want that by default.",
    });
    if (sess.state.last_goal.len != 0) {
        p.add(.{ .key = "", .label = "Last goal", .kind = .info, .value = sess.state.last_goal });
    }
    p.add(.{
        .key = "/peers ",
        .label = "Ask a teammate…",
        .kind = .pick,
        .help = "Then type what you want them to do",
    });
    p.add(.{ .key = "", .label = "Shared notes", .kind = .heading });
    const raw = board.loadTail(sess.arena, sess.io, sess.workspace);
    var notes: [board.max_notes]board.Note = undefined;
    const nn = board.parseAll(raw, &notes);
    if (nn == 0) {
        p.add(.{
            .key = "",
            .label = "No shared notes yet",
            .kind = .info,
            .help = "Notes appear here when teammates leave updates",
        });
    } else {
        var i: usize = nn;
        var shown: usize = 0;
        while (i > 0 and shown < 12) {
            i -= 1;
            const note = notes[i];
            const kind_label: []const u8 = switch (note.kind) {
                .fact => "Note",
                .fail => "Problem",
                .path => "File",
            };
            p.add(.{
                .key = "",
                .label = kind_label,
                .kind = .info,
                .value = note.text,
            });
            shown += 1;
        }
    }
    p.selectFirst();
    return p;
}

/// The workspace root and any extra directories the agent may touch.
fn workspacePanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Workspace" };
    p.add(.{ .key = "", .label = "Root", .kind = .info, .value = sess.workspace });
    if (sess.state.extraSlice().len == 0) {
        p.add(.{ .key = "", .label = "No extra folders", .kind = .info, .help = "Add one with /workspace add <folder>" });
    } else {
        p.add(.{ .key = "", .label = "Extra", .kind = .heading });
        for (sess.state.extraSlice()) |d| p.add(.{ .key = "", .label = d, .kind = .info });
    }
    return p;
}

/// Which facts the status line shows, and where.
///
/// One toggle per field plus a placement choice, because "which of these eight
/// do I want" is a form, not a command line to memorise.
fn statuslinePanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    const sl = statusline_mod.parse(cfg.statusline_place, cfg.statusline_fields);

    var p = panel_mod.Panel{ .title = "Status line" };
    p.add(.{
        .key = "statusline_place",
        .label = "Show in",
        .kind = .{ .choice = &.{ "footer", "header", "both" } },
        .value = sl.place.asSlice(),
        .help = "footer sits by the composer, header across the top",
    });
    p.add(.{ .key = "", .label = "Fields", .kind = .heading });
    inline for (comptime std.meta.tags(statusline_mod.Field)) |f| {
        p.add(.{
            .key = "field:" ++ @tagName(f),
            .label = @tagName(f),
            .kind = .toggle,
            .value = if (sl.has(f)) "on" else "off",
            .help = fieldHelp(f),
        });
    }
    p.selectFirst();
    return p;
}

fn fieldHelp(f: statusline_mod.Field) []const u8 {
    return switch (f) {
        .model => "the model answering this turn",
        .mode => "normal, plan, or yolo",
        .workspace => "the directory omfx is rooted at",
        .branch => "current git branch, when the workspace is a repo",
        .tokens => "tokens spent in this session",
        .session => "session id, for /resume",
        .peers => "how many teammates are running",
        .jobs => "how many background commands are alive",
    };
}

/// Every slash command, grouped, as a panel you arrow through.
///
/// `/help` printed fifty lines into the transcript, which pushed the whole
/// conversation off screen to read a reference you then had to scroll back
/// past. A panel is the same list you can act on and dismiss.
/// Every binding, grouped, searchable, each with a page of its own.
///
/// The inline `?` list answers "what was that key again"; this answers "what
/// can I do here", which is a different question and needs room to say it.
fn keysPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Keys" };
    const q = sess.panel_edit.items;
    var section: []const u8 = "";
    for (tui.key_rows) |row| {
        if (!keyMatches(q, row)) continue;
        if (!std.mem.eql(u8, section, row.section)) {
            section = row.section;
            p.add(.{ .key = "", .label = row.section, .kind = .heading });
        }
        p.add(.{
            .key = row.name,
            .label = row.name,
            .kind = .entry,
            .value = row.help,
            .help = row.help,
            .detail = row.detail,
        });
    }
    if (p.n == 0) p.add(.{ .key = "", .label = "Nothing matches what you typed", .kind = .info });
    p.selectFirst();
    return p;
}

fn keyMatches(q: []const u8, row: tui.KeyRow) bool {
    if (q.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(row.name, q) != null or
        std.ascii.indexOfIgnoreCase(row.help, q) != null or
        std.ascii.indexOfIgnoreCase(row.section, q) != null;
}

/// Every discovered skill as a slash command, sorted so the list reads the
/// way a directory does.
///
/// The help text is the skill's own `description:` from its front matter, so
/// the list says what each one is for. Reading the head of every SKILL.md is
/// a few hundred bytes each and happens once.
fn skillSpecs(sess: *Session) []const slash.Spec {
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
    std.mem.sort(slash.Spec, out[0..n], {}, lessThanSpec);
    return out[0..n];
}

fn lessThanSpec(_: void, a: slash.Spec, b: slash.Spec) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn helpPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Commands" };
    const q = sess.panel_edit.items;
    for (slash.groups) |grp| {
        // A heading with nothing under it is noise, so the group is only
        // opened once a row in it survives the filter.
        var titled = false;
        for (grp.names) |name| {
            const spec = slash.find(name) orelse continue;
            if (!commandMatches(q, spec)) continue;
            if (!titled) {
                titled = true;
                p.add(.{ .key = "", .label = grp.title, .kind = .heading });
            }
            p.add(.{ .key = spec.name, .label = spec.name, .kind = .pick, .value = spec.help });
        }
    }
    if (p.n == 0) p.add(.{ .key = "", .label = "Nothing matches what you typed", .kind = .info });
    p.selectFirst();
    return p;
}

/// Name or description, case-insensitively: you look a command up by what it
/// is called or by what it does, and only one of those is in front of you.
fn commandMatches(q: []const u8, spec: slash.Spec) bool {
    if (q.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(spec.name, q) != null or
        std.ascii.indexOfIgnoreCase(spec.help, q) != null;
}

/// Where the context window has gone.
///
/// The total is the provider's own count, cache included. The parts under it
/// are bytes omfx measured divided by `bytes_per_token`: the system prompt
/// and the tool schemas are strings this binary holds, so their size is known
/// exactly even though their token count is not. Messages is what is left,
/// which is the number people actually want and the one no API reports.
fn contextPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Context window" };
    const window = sess.ctx_window;
    if (window == 0) {
        p.add(.{ .key = "", .label = "no window reported yet", .kind = .info });
        return p;
    }
    const used = sess.ctx_used;
    const sys = sess.trace_sys / bytes_per_token;
    const tools = sess.trace_tools / bytes_per_token;
    // The fixed floor cannot exceed what the provider says is in the window.
    const fixed = @min(sys + tools, used);
    const messages = used - fixed;

    p.add(.{
        .key = "",
        .label = "Total",
        .kind = .info,
        .value = contextRow(sess, used, window),
    });
    p.add(.{ .key = "", .label = "Messages", .kind = .info, .value = contextRow(sess, messages, window) });
    p.add(.{ .key = "", .label = "System prompt", .kind = .info, .value = contextRow(sess, @min(sys, used), window) });
    p.add(.{ .key = "", .label = "Tool schemas", .kind = .info, .value = contextRow(sess, @min(tools, used -| sys), window) });
    p.add(.{
        .key = "",
        .label = "Free space",
        .kind = .info,
        .value = contextRow(sess, window -| used, window),
    });
    addCacheRows(sess, &p);
    return p;
}

/// What the last turn cost, split the way the provider bills it.
///
/// The hit rate is cache reads over the whole prompt, which is the number that
/// decides the bill: a read is a tenth of the price of fresh input, and a
/// write is a quarter more. Providers report the three separately for exactly
/// this reason, so they are shown separately rather than summed into one
/// "cached" figure that hides which way it went.
fn addCacheRows(sess: *Session, p: *panel_mod.Panel) void {
    const read = sess.ctx_cache_read;
    const write = sess.ctx_cache_write;
    const fresh = sess.ctx_fresh;
    const prompt = fresh +| read +| write;
    if (prompt == 0) return;

    p.add(.{ .key = "", .label = "", .kind = .info });
    const pct = @as(u64, read) * 100 / prompt;
    var buf: [24]u8 = undefined;
    p.add(.{
        .key = "",
        .label = "Served from cache",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{s} of the last prompt ({d}%)", .{
            tui.shortTokens(&buf, read),
            pct,
        }) catch "",
    });
    var fresh_buf: [24]u8 = undefined;
    p.add(.{
        .key = "",
        .label = "Read fresh",
        .kind = .info,
        .value = std.fmt.allocPrint(sess.arena, "{s}", .{tui.shortTokens(&fresh_buf, fresh)}) catch "",
    });
    if (write > 0) {
        var w_buf: [24]u8 = undefined;
        p.add(.{
            .key = "",
            .label = "Written to cache",
            .kind = .info,
            .value = std.fmt.allocPrint(sess.arena, "{s}, readable on the next turn", .{
                tui.shortTokens(&w_buf, write),
            }) catch "",
        });
    }
    if (read == 0 and write == 0) {
        p.add(.{ .key = "", .label = "", .kind = .info, .value = "This provider reported no caching." });
    }
}

/// Receipt: measured over this repo's own session files, one token averages
/// 3.9 bytes of prompt text. Four is the round number either side of that,
/// and the parts it sizes are labelled as omfx's own measurement rather than
/// as anything a provider counted.
const bytes_per_token: u32 = 4;

fn contextRow(sess: *Session, tokens: u32, window: u32) []const u8 {
    const pct = if (window == 0) 0 else @as(u64, tokens) * 100 / window;
    var buf: [24]u8 = undefined;
    return std.fmt.allocPrint(sess.arena, "{s} ({d}%)", .{ tui.shortTokens(&buf, tokens), pct }) catch "";
}

/// The prompts of this session, newest first, as points to go back to.
///
/// A list you pick from rather than a number you count out: what you remember
/// is what you asked, not how many turns ago you asked it.
fn rewindPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Go back to a message" };
    const state = &sess.state;
    if (state.marks_n == 0) {
        p.add(.{
            .key = "",
            .label = "Nothing to go back to yet",
            .kind = .info,
            .help = "Messages you send will show up here",
        });
        return p;
    }
    var i: usize = state.marks_n;
    while (i > 0) {
        i -= 1;
        const steps = state.marks_n - i;
        // The key is the command the pick runs: choosing a row fills the
        // composer with it, which is the same route every other panel takes.
        const key = std.fmt.allocPrint(sess.arena, "/rewind {d}", .{steps}) catch continue;
        const back = if (steps == 1)
            "1 turn back"
        else
            std.fmt.allocPrint(sess.arena, "{d} turns back", .{steps}) catch "back";
        p.add(.{
            .key = key,
            .label = sess.arena.dupe(u8, state.marks[i].previewSlice()) catch continue,
            .kind = .pick,
            .value = back,
        });
    }
    p.selectFirst();
    return p;
}

/// Saved sessions, newest first, with when they last changed and how far they got.
fn sessionPanel(sess: *Session) panel_mod.Panel {
    var p = panel_mod.Panel{ .title = "Resume a session" };
    const dir_path = std.fs.path.join(sess.arena, &.{ sess.home, ".omfx", "sessions" }) catch return p;
    var dir = Io.Dir.cwd().openDir(sess.io, dir_path, .{ .iterate = true }) catch {
        p.add(.{ .key = "", .label = "No saved chats yet", .kind = .info });
        return p;
    };
    defer dir.close(sess.io);
    const idlist = session.listIds(dir, sess.io, sess.arena) catch return p;

    const Entry = struct { id: []const u8, mtime: i128, asked: []const u8, turns: usize, when: []const u8 };
    var rows: [panel_mod.max_fields]Entry = undefined;
    var n: usize = 0;
    for (idlist) |id| {
        if (n == rows.len) break;
        const path = session.sessionPath(sess.arena, sess.home, session.resolveId(id)) catch continue;
        const blob = Io.Dir.cwd().readFileAlloc(sess.io, path, sess.arena, .limited(64_000)) catch continue;
        const st = Io.Dir.cwd().statFile(sess.io, path, .{}) catch continue;
        var when_buf: [32]u8 = undefined;
        const when = sess.arena.dupe(u8, session.formatWhen(&when_buf, sess.io, path)) catch "";
        rows[n] = .{
            .id = id,
            .mtime = st.mtime.toNanoseconds(),
            .asked = session.firstUser(blob),
            .turns = std.mem.count(u8, blob, "\"kind\":\"user\""),
            .when = when,
        };
        n += 1;
    }
    std.mem.sort(Entry, rows[0..n], {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.less);

    for (rows[0..n]) |row| {
        const turns = std.fmt.allocPrint(sess.arena, "{d} turn{s}", .{
            row.turns,
            if (row.turns == 1) "" else "s",
        }) catch "";
        const meta = if (row.when.len != 0)
            std.fmt.allocPrint(sess.arena, "{s}  ·  {s}", .{ row.when, turns }) catch turns
        else
            turns;
        p.add(.{
            .key = std.fmt.allocPrint(sess.arena, "/resume {s}", .{row.id}) catch row.id,
            .label = if (row.asked.len != 0) sess.arena.dupe(u8, row.asked) catch row.id else row.id,
            .kind = .pick,
            .value = meta,
            .help = "enter opens  ·  del deletes forever  ·  up/down moves  ·  esc closes",
        });
    }
    if (p.n == 0) p.add(.{ .key = "", .label = "No saved chats yet", .kind = .info });
    p.selectFirst();
    return p;
}

/// Moves whatever was typed during the turn into the composer.
///
/// The watcher owns stdin while the model is answering, so a sentence written
/// mid-turn used to be read and thrown away. Keeping it is the difference
/// between a pane that swallows your typing and one you can steer.
fn takeSteering(sess: *Session) void {
    var buf: [sink.max_steer]u8 = undefined;
    const got = sink.takeSteer(&buf);
    if (got.text.len == 0) return;
    // A word joined onto whatever was already in the composer needs a gap,
    // unless the typing already carried one.
    if (sess.draft.items().len != 0 and got.text[0] != ' ') sess.draft.insert(sess.gpa, ' ') catch {};
    for (got.text) |c| sess.draft.insert(sess.gpa, c) catch return;
    sess.steer_send = got.ready;
    sess.dirty = true;
}

/// Handles one event while the keyboard is in the scrollback. Returns true when
/// it consumed the event.
///
/// The bindings are the ones a reader expects from a pager -- j/k to move, e to
/// fold, g/G for the ends -- so the run tree can be worked without a mouse. Any
/// other printable key hands the keyboard back to the composer and is typed
/// there, because a mode that silently swallows what you type is a trap.
fn scrollbackKey(sess: *Session, ev: tui.Event) bool {
    switch (ev) {
        .esc => {
            sess.blurScrollback();
            return true;
        },
        .tab, .shift_tab => {
            sess.blurScrollback();
            return true;
        },
        .down => {
            if (!sess.moveChild(false)) sess.moveSel(false);
            return true;
        },
        .up => {
            if (!sess.moveChild(true)) sess.moveSel(true);
            return true;
        },
        .right => {
            sess.setExpanded(true);
            return true;
        },
        .left => {
            sess.setExpanded(false);
            return true;
        },
        .enter => {
            // Inside an open run, Enter belongs to the call the cursor is on.
            if (sess.toggleChild()) return true;
            sess.setExpanded(null);
            return true;
        },
        // Scroll without moving the selection: reading around a run should not
        // cost you your place in it.
        .ctrl_j => {
            if (sess.bumpScroll(false, 1)) sess.dirty = true;
            return true;
        },
        .kill_line => {
            if (sess.bumpScroll(true, 1)) sess.dirty = true;
            return true;
        },
        .ctrl_d => {
            if (sess.bumpScroll(false, @max(1, sess.layout.transcript_rows / 2))) sess.dirty = true;
            return true;
        },
        .kill_to_start => {
            if (sess.bumpScroll(true, @max(1, sess.layout.transcript_rows / 2))) sess.dirty = true;
            return true;
        },
        .shift_right => {
            sess.selectTurn(false);
            return true;
        },
        .shift_left => {
            sess.selectTurn(true);
            return true;
        },
        .byte => |b| switch (b) {
            'j' => {
                if (!sess.moveChild(false)) sess.moveSel(false);
                return true;
            },
            'k' => {
                if (!sess.moveChild(true)) sess.moveSel(true);
                return true;
            },
            'e' => {
                sess.setExpanded(null);
                return true;
            },
            'l' => {
                sess.setExpanded(true);
                return true;
            },
            'h' => {
                sess.setExpanded(false);
                return true;
            },
            'g' => {
                sess.selectEnd(false);
                return true;
            },
            'G' => {
                sess.selectEnd(true);
                return true;
            },
            'E' => {
                sess.expandAll();
                return true;
            },
            'n' => {
                if (sess.stepHunk(true)) return true;
                return false;
            },
            'p' => {
                if (sess.stepHunk(false)) return true;
                return false;
            },
            'y' => {
                sess.copyRun();
                return true;
            },
            'q' => {
                sess.blurScrollback();
                return true;
            },
            // Space hands the keyboard back without typing a space, the way
            // it does in grok-build: reading is a mode you leave, not a key
            // you have to remember.
            ' ' => {
                sess.blurScrollback();
                return true;
            },
            'Y' => {
                sess.copyRunOutput();
                return true;
            },
            else => {
                sess.blurScrollback();
                return false;
            },
        },
        else => return false,
    }
}

/// Handles one event for an open panel. Returns true when the panel consumed
/// it, which is every key except the ones that close the panel.
///
/// Split out of the main event switch on purpose: the loop already has ~50
/// arms, and a modal that swallows input does not belong inside them.
fn panelKey(sess: *Session, ev: tui.Event) bool {
    const p = &(sess.panel orelse return false);
    const gpa = sess.gpa;

    if (p.editing) {
        switch (ev) {
            .enter => {
                applyPanelField(sess, p.*, sess.panel_edit.items);
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
                    sess.refilterPanel();
                }
                return true;
            },
            .byte => |b| if (b >= 0x20 and b < 0x7f) {
                sess.panel_edit.append(gpa, b) catch {};
                sess.refilterPanel();
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
        .left, .right => stepPanelValue(sess, ev == .right),
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
            var next = sessionPanel(sess);
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
                .toggle => togglePanelField(sess),
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
        .byte => |b| if (b == ' ') togglePanelField(sess),
        else => {},
    }
    return true;
}

pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    home: []const u8,
    workspace: []const u8,
    lookup: env.Lookup,
    model_name: []const u8,
    resolved: ?catalog.Resolved,
    mode_init: config.PermissionMode,
    parsed: cli.Parsed,
) !void {
    const sz0 = tui.size(24, 80);
    var sess = Session{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .stdout = stdout,
        .home = home,
        .workspace = workspace,
        .lookup = lookup,
        .parsed = parsed,
        .fallback_model = model_name,
        .state = .{
            .mode = mode_init,
            .effort = parsed.effort orelse "",
            .effort_prev = parsed.effort orelse "",
            .resolved = resolved,
            .reads = agent.Reads.init(gpa),
        },
        .shown = tui.Transcript.init(gpa, sz0.cols),
        .runs = runs_mod.Store.init(gpa),
        .layout = tui.Layout.compute(sz0.rows, sz0.cols),
        .cups = undefined,
    };
    sess.cups = tui.Cups.compute(sess.layout);
    defer sess.deinit();
    const state = &sess.state;
    {
        var cfg = settings.load(gpa, io, home);
        defer cfg.deinit(gpa);
        relay.ensure(gpa, io, settings.cdpPort(cfg));
        state.sound = settings.soundOn(cfg);
        if (cfg.effort.len > 0 and state.effort.len == 0) state.effort = try arena.dupe(u8, cfg.effort);
        // Builtin/cache only — `describeModel` hits /models and can stall the
        // first paint for tens of seconds on a slow or flaky network. The live
        // list loads when the user opens /model or the picker.
        {
            const provider = if (state.resolved) |r| r.spec.id else "";
            const id = if (state.resolved) |r| r.model else model_name;
            if (models.lookup(provider, id)) |m| sess.ctx_window = m.context_window;
        }
        if (cfg.editor.len > 0 and !std.mem.eql(u8, cfg.editor, "auto")) state.editor = try arena.dupe(u8, cfg.editor);
        deadline.setDefaultSecs(cfg.bash_timeout);
        if (cfg.keep_sessions != 0) session.prune(gpa, io, home, cfg.keep_sessions);
        state.thinking = settings.thinkingOn(cfg);
        state.telemetry = settings.telemetryOn(cfg);
        if (cfg.statusline.len > 0) state.statusline = !std.mem.eql(u8, cfg.statusline, "off");
        if (cfg.composer.len > 0) state.composer = try arena.dupe(u8, cfg.composer);
        if (!parsed.yolo and !parsed.auto) cmds.applySurface(state, cfg.last_mode);
        for (cfg.workspace_dirs) |d| {
            state.appendExtra(try arena.dupe(u8, d)) catch break;
        }
    }
    const skill_roots = skills.readAccessRoots(arena, io, home, workspace) catch &.{};
    pathing.setAccess(.{ .workspace = workspace, .extra = state.extraSlice(), .read_extra = skill_roots });
    sess.skill_specs = skillSpecs(&sess);
    var raw = tty.Raw.enter();
    defer raw.leave();
    // Registered before the restore defer so restore runs first (LIFO), then
    // this message lands on the primary screen instead of vanishing with alt.
    var exit_eof = false;
    defer {
        if (exit_eof) {
            var err_buf: [256]u8 = undefined;
            var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
            err_w.interface.writeAll("omfx: stdin closed — interactive mode needs a terminal\n") catch {};
            err_w.interface.flush() catch {};
        }
    }
    const painted = try tui.paintSequence(arena, sess.layout, .{
        .model = model_name,
        .permission = cmds.footerPerm(state),
        .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
        .composer = state.composer,
        .place = workspace,
    });
    try stdout.writeAll(painted);
    try stdout.flush();
    if (state.sound) sound_mod.play(io, lookup, .bloom);

    defer {
        const dump = tui.restoreWithScrollback(arena, sess.shown.bytes()) catch tui.restoreSequence();
        stdout.writeAll(dump) catch |err| {
            log.debug("restore write: {s}", .{@errorName(err)});
        };
        stdout.flush() catch |err| {
            log.debug("restore flush: {s}", .{@errorName(err)});
        };
    }

    try tui.writeWelcome(arena, stdout, sess.layout, .{
        .model = model_name,
        .permission = cmds.footerPerm(state),
        .effort = if (state.effort.len == 0) cmds.auto_effort else state.effort,
        .composer = state.composer,
        .place = workspace,
    });
    try stdout.flush();

    if (parsed.resume_id) |rid| {
        const path = try session.sessionPath(arena, home, session.resolveId(rid));
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1_000_000))) |blob| {
            try sess.shown.append(blob);
            sess.paintTranscript();
            try stdout.flush();
        } else |_| {}
    }

    var slash_buf: [tui.max_slash_hits]slash.Spec = undefined;
    var at_store: [32][96]u8 = undefined;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.Reader.initStreaming(.stdin(), io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        const model = if (state.resolved) |r| r.model else model_name;
        if (state.skills_stale) {
            state.skills_stale = false;
            sess.skill_specs = skillSpecs(&sess);
        }
        if (sess.dirty) {
            const plain_comp = try std.fmt.allocPrint(gpa, "{s}{s}", .{ state.composer, sess.draft.items() });
            defer gpa.free(plain_comp);
            const ghost = tui.slashGhost(sess.draft.items(), sess.draft.cur);
            const shown_comp = plain_comp;
            const draft_items = sess.draft.items();
            if (state.pick.kind != .none and (draft_items.len == 0 or draft_items[0] != '/')) {
                sess.palette = slash_buf[0..(state.pick.match(draft_items, &slash_buf))];
            } else {
                sess.palette = slash_buf[0..(tui.matchKeys(draft_items, &slash_buf))];
                if (sess.palette.len == 0) sess.palette = slash_buf[0..(tui.matchSlash(draft_items, &slash_buf, sess.skill_specs))];
                if (sess.palette.len == 0) {
                    if (tui.atPrefix(draft_items)) |pre| {
                        sess.palette = slash_buf[0..(tui.matchAt(Io.Dir.cwd(), io, arena, pre, &at_store, slash_buf[0..]))];
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

        // A panel owns the keyboard while it is up. Polling at the frame
        // budget rather than 64ms keeps the reveal smooth, and drops back to
        // the idle rate the moment the animation settles.
        if (sess.panel != null) {
            const more = sess.paintPanel();
            const wait: i32 = if (more) @intCast(panel_mod.frame_ms) else 64;
            const pev = tui.pollEvent(stdin, wait);
            if (panelKey(&sess, pev)) continue;
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
        } else tui.pollEvent(stdin, 64);
        const tag = std.meta.activeTag(ev);
        if (tag != .skip and tag != .shift_tab and !state.pending.awaitingInput()) sess.noteClear();
        // Nothing was typed, so nothing else will repaint: the note has to ask
        // for the frame that takes it back down.
        if (tag == .skip) {
            const now = nowMs(io);
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
        if (sess.focus == .scrollback and scrollbackKey(&sess, ev)) continue;
        switch (ev) {
            .skip => continue,
            // Turn jumps belong to the scrollback; in the composer a shifted
            // arrow is not a caret move, so it does nothing rather than
            // guessing.
            .shift_left, .shift_right => continue,
            .click => |c| {
                sess.startSel(c.row, c.col);
                continue;
            },
            .drag => |c| {
                sess.extendSel(c.row, c.col);
                continue;
            },
            .release => |c| {
                // Jump pill first: only the button cells, not the rest of the row.
                if (sess.tryJumpClick(c.row, c.col)) {
                    sess.dragging = false;
                    continue;
                }
                // A press that never moved is a click, and a click on a tool
                // run opens it. Deciding here rather than on press is what
                // lets one gesture be both.
                if (!sess.marked.on()) sess.clickRun(c.row) else sess.copySel(gpa);
                sess.dragging = false;
                continue;
            },
            .page_up => {
                if (sess.palette.len > 0) {
                    const step = tui.paletteItemRows(sess.layout, sess.palette.len);
                    sess.palette_sel = if (sess.palette_sel > step) sess.palette_sel - step else 0;
                    sess.dirty = true;
                    continue;
                }
                if (sess.bumpScroll(true, sess.layout.transcript_rows)) sess.dirty = true;
                continue;
            },
            .page_down => {
                if (sess.palette.len > 0) {
                    const step = tui.paletteItemRows(sess.layout, sess.palette.len);
                    sess.palette_sel = @min(sess.palette.len - 1, sess.palette_sel + step);
                    sess.dirty = true;
                    continue;
                }
                if (sess.bumpScroll(false, sess.layout.transcript_rows)) sess.dirty = true;
                continue;
            },
            .scroll_up => {
                if (sess.bumpScroll(true, tui.wheel_step)) sess.dirty = true;
                continue;
            },
            .scroll_down => {
                if (sess.bumpScroll(false, tui.wheel_step)) sess.dirty = true;
                continue;
            },
            .resize => {
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
                continue;
            },
            .esc => {
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
                    continue;
                }
                if (sess.palette.len > 0) {
                    if (tui.atPrefix(sess.draft.items()) == null) sess.draft.clear();
                    sess.palette = slash_buf[0..(0)];
                    sess.palette_sel = 0;
                    sess.arm.clear();
                    sess.dirty = true;
                    continue;
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
                    continue;
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
                    continue;
                }
                continue;
            },
            .up => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel > 0) sess.palette_sel -= 1;
                } else if (sess.draft.items().len == 0) {
                    if (try sess.hist.older(gpa, sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .down => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel + 1 < sess.palette.len) sess.palette_sel += 1;
                } else if (sess.draft.items().len == 0) {
                    if (sess.hist.newer(sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .history_prev => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel > 0) sess.palette_sel -= 1;
                } else if (sess.draft.items().len == 0) {
                    if (try sess.hist.older(gpa, sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .history_next => {
                if (sess.palette.len > 0) {
                    if (sess.palette_sel + 1 < sess.palette.len) sess.palette_sel += 1;
                } else if (sess.draft.items().len == 0) {
                    if (sess.hist.newer(sess.draft.items())) |line| try sess.draft.replace(gpa, line);
                }
                sess.dirty = true;
                continue;
            },
            .tab => {
                if (tui.keysDraft(sess.draft.items())) {
                    sess.dirty = true;
                    continue;
                }
                // Nothing to complete: hand the keyboard to the scrollback, the
                // way Tab does in every other pane-and-prompt TUI.
                if (sess.palette.len == 0 and sess.draft.items().len == 0) {
                    if (sess.focusScrollback()) continue;
                }
                _ = try sess.completePalette();
                sess.dirty = true;
                continue;
            },
            .keys => {
                try sess.hold.flush(gpa, &sess.draft);
                if (tui.keysDraft(sess.draft.items())) sess.draft.clear();
                // ctrl-x on an empty prompt opens the cheatsheet; `?` typed
                // into the composer keeps the inline list it always had.
                sess.openSearchPanel(.shortcuts);
                sess.palette_sel = 0;
                sess.dirty = true;
                continue;
            },
            .shift_tab => {
                sess.note(cmds.cycleSurface(state), nowMs(io));
                var ctx = sess.cmdCtx();
                cmds.persistChat(&ctx);
                sess.arm.clear();
                sess.dirty = true;
                continue;
            },
            .interrupt => break,
            .ctrl_d => {
                if (sess.draft.items().len != 0) {
                    sess.draft.delete();
                    sess.dirty = true;
                    continue;
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
                )) break;
                sess.dirty = true;
                continue;
            },
            .palette => {
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
                continue;
            },
            .new_session => {
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
                continue;
            },
            .quit => {
                if (tui.askConfirm(
                    stdin,
                    stdout,
                    gpa,
                    &sess.layout,
                    "Leave omfx?",
                    "Your chat is saved. You can open it again later.",
                    "Leave",
                    "Stay",
                )) break;
                sess.dirty = true;
                continue;
            },
            .yolo => {
                var ctx = sess.cmdCtx();
                _ = try cmds.dispatch(&ctx, "/yolo");
                cmds.persistChat(&ctx);
                sess.paintTranscript();
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .sessions => {
                var ctx = sess.cmdCtx();
                _ = try cmds.dispatch(&ctx, "/session");
                sess.dirty = true;
                continue;
            },
            .ctrl_m => {
                sess.multiline = !sess.multiline;
                sess.dirty = true;
                continue;
            },
            .ctrl_enter => {
                try sess.hold.flush(gpa, &sess.draft);
                try sess.draft.insert(gpa, '\n');
                sess.dirty = true;
                continue;
            },
            .ctrl_b => {
                sess.draft.left();
                sess.dirty = true;
                continue;
            },
            .ctrl_t => {
                var ctx = sess.cmdCtx();
                try cmds.cycleEffort(&ctx);
                sess.note(std.fmt.allocPrint(sess.arena, "Reasoning set to {s}.", .{
                    if (state.effort.len == 0) cmds.auto_effort else state.effort,
                }) catch "Reasoning changed.", nowMs(io));
                sess.paintTranscript();
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .ctrl_r => {
                sess.draft.redo();
                sess.dirty = true;
                continue;
            },
            .ctrl_j => {
                sess.dirty = true;
                continue;
            },
            .f2 => {
                var ctx = sess.cmdCtx();
                _ = try cmds.dispatch(&ctx, "/settings");
                sess.paintTranscript();
                try stdout.flush();
                sess.dirty = true;
                continue;
            },
            .newline => {
                try sess.hold.flush(gpa, &sess.draft);
                if (sess.multiline) {
                    // Shift/Alt+Enter sends while sess.multiline is on.
                } else {
                    try sess.draft.insert(gpa, '\n');
                    sess.dirty = true;
                    continue;
                }
            },
            .redraw => {
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
                continue;
            },
            .yank => {
                try sess.hold.flush(gpa, &sess.draft);
                try sess.draft.yank(gpa);
                sess.dirty = true;
                continue;
            },
            .undo => {
                sess.draft.undo();
                sess.dirty = true;
                continue;
            },
            .redo => {
                sess.draft.redo();
                sess.dirty = true;
                continue;
            },
            .word_left => {
                sess.draft.wordLeft();
                sess.dirty = true;
                continue;
            },
            .word_right => {
                sess.draft.wordRight();
                sess.dirty = true;
                continue;
            },
            // A long prompt belongs in a real editor. ctrl-g (or the bound
            // external-editor key) sends the draft to $EDITOR and loads it back.
            .external_editor => {
                editDraftExternally(&sess) catch {};
                sess.dirty = true;
                continue;
            },
            .kill_word_right => {
                sess.draft.killWordRight(gpa);
                sess.dirty = true;
                continue;
            },
            .byte => |b| {
                try sess.hold.push(gpa, &sess.draft, b);
                sess.dirty = true;
                continue;
            },
            .rune => |cp| {
                try sess.hold.flush(gpa, &sess.draft);
                var rune_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &rune_buf) catch {
                    sess.dirty = true;
                    continue;
                };
                try sess.draft.insertSlice(gpa, rune_buf[0..n]);
                sess.dirty = true;
                continue;
            },
            .backspace => {
                try sess.hold.flush(gpa, &sess.draft);
                sess.draft.backspace();
                sess.dirty = true;
                continue;
            },
            .delete => {
                try sess.hold.flush(gpa, &sess.draft);
                sess.draft.delete();
                sess.dirty = true;
                continue;
            },
            .left => {
                sess.draft.left();
                sess.dirty = true;
                continue;
            },
            .right => {
                sess.draft.right();
                sess.dirty = true;
                continue;
            },
            .home => {
                if (sess.palette.len > 0) {
                    sess.palette_sel = 0;
                } else {
                    sess.draft.home();
                }
                sess.dirty = true;
                continue;
            },
            .end => {
                if (sess.palette.len > 0) {
                    sess.palette_sel = sess.palette.len - 1;
                } else {
                    sess.draft.end();
                }
                sess.dirty = true;
                continue;
            },
            .kill_line => {
                sess.draft.killLine(gpa);
                sess.dirty = true;
                continue;
            },
            .kill_to_start => {
                sess.draft.killToStart(gpa);
                sess.dirty = true;
                continue;
            },
            .kill_word => {
                sess.draft.killWord(gpa);
                sess.dirty = true;
                continue;
            },
            .paste_start => {
                try sess.hold.flush(gpa, &sess.draft);
                try tui.takePaste(stdin, gpa, &sess.draft);
                sess.dirty = true;
                continue;
            },
            .paste_end => continue,
            .eof => {
                exit_eof = true;
                break;
            },
            .enter => {
                try sess.hold.flush(gpa, &sess.draft);
                const items = sess.draft.items();
                // `C:\\` ends in a backslash the user typed on purpose; only an
                // odd run of them is a continuation.
                if (draft_mod.endsWithContinuation(items)) {
                    sess.draft.backspace();
                    try sess.draft.insert(gpa, '\n');
                    sess.dirty = true;
                    continue;
                }
                if (sess.multiline) {
                    try sess.draft.insert(gpa, '\n');
                    sess.dirty = true;
                    continue;
                }
            },
        }

        if (tui.keysDraft(sess.draft.items())) {
            sess.draft.clear();
            sess.dirty = true;
            continue;
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
            continue;
        }

        if (sess.palette.len > 0 and std.mem.indexOfScalar(u8, sess.draft.items(), ' ') == null) {
            // A completed mention is still being written; a completed command is
            // the whole line, so it falls through and sends.
            if (try sess.completePalette()) {
                sess.dirty = true;
                continue;
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
                continue;
            }
            sess.dirty = true;
            continue;
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
            continue;
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
                    continue;
                },
                .quit => break,
                .panel => |kind| {
                    switch (kind) {
                        .help, .shortcuts => sess.openSearchPanel(kind),
                        else => {
                            sess.openPanel(buildPanel(&sess, kind));
                            // Keep the kind so list panels can act on keys
                            // (sessions: del) without reopening.
                            sess.panel_kind = kind;
                        },
                    }
                    sess.dirty = true;
                    continue;
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
            continue;
        }

        {
            var cred_ctx = sess.cmdCtx();
            cmds.refreshInto(&cred_ctx, false);
        }
        const model_prompt = try mention.expand(arena, Io.Dir.cwd(), io, workspace, prompt_text);
        const shown = try vision.display(arena, Io.Dir.cwd(), io, workspace, prompt_text);
        const composer = try std.fmt.allocPrint(arena, "{s}{s}", .{ state.composer, shown });
        if (state.statusline) {
            try tui.writeFooter(arena, stdout, sess.layout, .{
                .model = model,
                .permission = cmds.footerPerm(state),
                .effort = state.effort,
                .composer = composer,
                .place = workspace,
            });
        } else {
            try stdout.writeAll(tui.sync_begin);
            try stdout.writeAll(sess.cups.toFooter());
            try stdout.writeAll("\x1b[2K");
            try stdout.writeAll(composer);
            try stdout.writeAll(tui.sync_end);
        }
        try stdout.flush();

        const user_line = try chat.formatUser(arena, sess.layout.cols, shown);
        try sess.shown.append(user_line);
        sess.scroll = 0;
        // Activity for this turn, started before the first paint so the status
        // says what is happening instead of a generic word.
        var act = live_mod.Live.Act{};
        // The status row borrows act.buf, which is this iteration's stack. Left
        // set, the next idle paint reads a dead frame and draws whatever bytes
        // happen to be there.
        defer sess.status = "";
        act.begin();
        sess.status = act.renderNow();
        sess.paintAll(.generating);
        stdout.writeAll(tui.tab_busy) catch |err| {
            log.debug("tab busy: {s}", .{@errorName(err)});
        };
        {
            var head: [activity.max_phrase]u8 = undefined;
            tui.writeTabTitle(stdout, activity.frameOf(0), activity.headline(&head, act.state));
        }
        try stdout.flush();

        var endpoint = toEndpoint(arena, state.resolved);
        if (endpoint == null) {
            // Through the same formatter as every other command answer: this
            // is the harness talking, and it should not be the one raw block.
            try sess.shown.append(try chat.formatCommand(arena, sess.layout.cols, ask_run.missing_key_text));
            sess.status = "";
            sess.paintAll(.idle);
            tty.flushInput();
            stdout.writeAll(tui.tab_idle) catch |err| {
                log.debug("tab idle: {s}", .{@errorName(err)});
            };
            sess.writeIdleTitle();
            try stdout.flush();
            sess.dirty = true;
            continue;
        }
        {
            const provider = if (state.resolved) |r| r.spec.id else "";
            var ec = sess.cmdCtx();
            const described = cmds.describeModel(&ec, provider, endpoint.?.model);
            const ladder = if (described) |m| m.efforts else "";
            applyEffort(&endpoint.?, state.effort, ladder, prompt_text, sess.stuck);
            // The provider's own number, held to this login's ceiling. The
            // catalog value predates both.
            if (described) |m| {
                if (m.context_window != 0) endpoint.?.context_window = m.context_window;
            }
        }
        cmds.markTurn(&ctx, prompt_text);
        var trace = agent.Trace{};
        const turn_began_ms = nowMs(io);
        sess.cancel.store(false, .release);
        // One renderer per turn: fences opened while streaming close on replay.
        var md = chat.Markdown{ .cols = sess.layout.cols };
        defer md.deinit(gpa);
        var tool_run = live_mod.Live.Run{};
        var asst_hold: std.ArrayList(u8) = .empty;
        defer asst_hold.deinit(gpa);
        var live = live_mod.tty(.{
            .stdout = stdout,
            .stdin = stdin,
            .allocator = gpa,
            .layout = &sess.layout,
            .footer = sess.footer(.generating),
            .cancel = &sess.cancel,
            .shown = &sess.shown,
            .think_view = tui.ThinkView.init(state.thinking),
            .asst_hold = &asst_hold,
            .md = &md,
            .act = &act,
            .group = &tool_run,
            .runs = &sess.runs,
            .arena = arena,
            .scroll = &sess.scroll,
        });
        live.startSpin();
        defer live.stopSpin();
        {
            const host = live.host();
            var wait_watch = sink.Watch{
                .cancel = &sess.cancel,
                .tick = host.on_tick,
                .tick_ctx = host.ctx,
                .page_rows = sess.layout.transcript_rows,
            };
            wait_watch.start();
            defer wait_watch.finish();
            if (state.had_turn and !sess.cancel.load(.acquire)) {
                if (agent.reflectFollowup(gpa, io, endpoint.?, state.last_goal, state.last_tool, prompt_text) catch null) |lesson| {
                    defer gpa.free(lesson);
                    playbook.noteHarmful(gpa, io, workspace, lesson);
                }
            }
        }
        var cfg_depth = settings.load(gpa, io, home);
        const peer_depth = cfg_depth.max_peer_depth;
        cfg_depth.deinit(gpa);
        const auth_json = auth.readJson(arena, io, home);
        // Committed bytes, not display rows: rows include the transient status
        // and streaming tail, which move during the turn for reasons that have
        // nothing to do with whether the reply was already shown.
        const kept = sess.shown.bytes().len;
        var reply_owned = true;
        var turn_host = live.host();
        turn_host.mode_live = &state.mode;
        const reply = if (sess.cancel.load(.acquire)) blk: {
            reply_owned = false;
            break :blk @as([]const u8, "");
        } else agent.chatOnce(
            gpa,
            io,
            Io.Dir.cwd(),
            workspace,
            endpoint.?,
            model_prompt,
            .{
                .mode = state.mode,
                .mode_live = &state.mode,
                .has_tty = true,
                .home = home,
                .reads = &state.reads,
                .trace = &trace,
                .plan = state.plan,
                .host = turn_host,
                .max_peer_depth = peer_depth,
                .prior_user = if (state.interrupted) state.last_prompt else "",
                .prior_assistant = if (state.interrupted) state.last_reply else "",
                .lookup = lookup,
                .auth_json = auth_json,
                .session_rules = state.sessionRuleSlice(),
                .failures = sess.stuck,
            },
        ) catch |err| blk: {
            reply_owned = false;
            break :blk try std.fmt.allocPrint(arena, "Unable to complete the turn ({s}). Try again.\n", .{@errorName(err)});
        };
        defer if (reply_owned) gpa.free(reply);
        const cancelled = sess.cancel.load(.acquire);
        // Words aimed at a turn the user just stopped are not the next prompt.
        if (cancelled) sink.dropSteer();
        const partial = if (cancelled) try arena.dupe(u8, asst_hold.items) else "";
        // Final prose that never streamed (common after tool rounds) must still
        // land in the transcript even though tool cards already grew `shown`.
        const streamed_asst = asst_hold.items.len != 0;
        live.flushAsst();
        live.flushGroups();
        live.flushTable();
        live.closeThink();
        live.stopSpin();
        if (!reply_owned) {
            try sess.shown.append(try arena.dupe(u8, reply));
        } else if (reply.len > 0 and (!streamed_asst or sess.shown.bytes().len == kept)) {
            try sess.shown.append(try chat.formatAssistant(arena, sess.layout.cols, reply));
        }
        if (diagram.save(gpa, Io.Dir.cwd(), io, reply)) |saved| {
            defer saved.deinit(gpa);
            switch (saved) {
                .none => {},
                .report => |msg| try sess.shown.append(
                    try chat.formatCommand(arena, sess.layout.cols, msg),
                ),
            }
        } else |err| {
            log.warn("diagram: {s}", .{@errorName(err)});
        }
        // The turn is over, so there is no activity to report; the row has to
        // go before the paint, not when the frame unwinds.
        sess.status = "";
        sess.paintAll(.idle);
        tty.flushInput();
        stdout.writeAll(tui.tab_idle) catch |err| {
            log.debug("tab idle: {s}", .{@errorName(err)});
        };
        sess.writeIdleTitle();
        try stdout.flush();
        if (cancelled) {
            // Keep the interrupted ask and whatever streamed, so "continue"
            // attaches to that turn instead of a new repo task.
            try sess.shown.append(try chat.formatNotice(arena, sess.layout.cols, "Interrupted"));
            const asst = if (partial.len > 0) partial else agent.interrupted_text;
            persistSession(gpa, io, home, model_prompt, asst, trace, "interrupted") catch |err| {
                log.warn("persist session: {s}", .{@errorName(err)});
            };
            if (!state.interrupted) {
                const goal_keep = if (prompt_text.len > 80) prompt_text[0..80] else prompt_text;
                state.last_goal = try arena.dupe(u8, goal_keep);
                state.last_prompt = try arena.dupe(u8, prompt_text);
            }
            state.last_tool = try arena.dupe(u8, if (trace.tool_len > 0) trace.toolName() else "");
            state.last_reply = try arena.dupe(u8, asst);
            state.had_turn = true;
            state.interrupted = true;
            cmds.persistChat(&ctx);
            sess.paintAll(.idle);
            try stdout.flush();
            sess.dirty = true;
            continue;
        }
        takeSteering(&sess);
        {
            var cmd_buf: [64]u8 = undefined;
            const pending = sink.takePendingCmd(&cmd_buf);
            if (pending.len != 0) {
                // Mid-turn Enter on `/settings` (etc.): run after the turn, do
                // not send as a user message.
                switch (try cmds.dispatch(&ctx, pending)) {
                    .handled => {
                        sess.takeMenuNote(&state.menu, nowMs(io));
                        sess.dirty = true;
                    },
                    .quit => {},
                    .panel => |kind| {
                        switch (kind) {
                            .help, .shortcuts => sess.openSearchPanel(kind),
                            else => {
                                sess.openPanel(buildPanel(&sess, kind));
                                sess.panel_kind = kind;
                            },
                        }
                        sess.dirty = true;
                    },
                    .fallthrough, .retry => {
                        try sess.draft.replace(sess.gpa, pending);
                        sess.steer_send = true;
                        sess.dirty = true;
                    },
                }
            }
        }
        if (state.sound) sound_mod.play(io, lookup, .success);
        const outcome: []const u8 = if (trace.denied) "denied" else "continued";
        // The window is the thread resent each turn, so what it holds is the
        // last turn's count, not a running sum.
        if (act.state.tokens != 0) {
            sess.ctx_used = act.state.tokens;
            sess.ctx_fresh = act.state.fresh_input;
            sess.ctx_cache_read = act.state.cache_read;
            sess.ctx_cache_write = act.state.cache_write;
        }
        if (trace.sys_bytes != 0) sess.trace_sys = trace.sys_bytes;
        if (trace.tools_bytes != 0) sess.trace_tools = trace.tools_bytes;
        if (endpoint) |ep| sess.ctx_window = ep.context_window;
        // What `auto` reads next turn. A clean turn clears it: being stuck is
        // a run of failures, not a memory of one.
        sess.stuck = if (trace.denied or cancelled) sess.stuck + 1 else 0;
        runlog.append(gpa, io, home, .{
            .at_ms = turn_began_ms,
            .model = sess.model(),
            .ms = nowMs(io) - turn_began_ms,
            .tokens = act.state.tokens,
            .tools = trace.tools,
            .verdict = outcome,
            .chars = reply.len,
        });
        persistSession(gpa, io, home, model_prompt, reply, trace, outcome) catch |err| {
            log.warn("persist session: {s}", .{@errorName(err)});
        };
        const goal_keep = if (prompt_text.len > 80) prompt_text[0..80] else prompt_text;
        state.last_goal = try arena.dupe(u8, goal_keep);
        state.last_prompt = try arena.dupe(u8, prompt_text);
        state.last_tool = try arena.dupe(u8, if (trace.tool_len > 0) trace.toolName() else "");
        state.last_reply = try arena.dupe(u8, reply);
        if (state.plan == .on) state.last_plan = try arena.dupe(u8, reply);
        state.had_turn = true;
        state.interrupted = false;
        cmds.persistChat(&ctx);
        sess.dirty = true;
    }
}

fn persistSession(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    user: []const u8,
    assistant: []const u8,
    trace: agent.Trace,
    outcome: []const u8,
) !void {
    var tool_buf: [40]u8 = undefined;
    const tool_body = if (trace.tool_len > 0)
        std.fmt.bufPrint(&tool_buf, "{s}:{x:0>8}", .{ trace.toolName(), trace.args_tag }) catch trace.toolName()
    else
        "";
    const verify = if (trace.verify != .none) @tagName(trace.verify) else "";
    try session.appendTurn(gpa, io, home, user, assistant, tool_body, verify, outcome);
}

/// A Session with no terminal attached, for exercising the state the event loop
/// mutates. `run` needs a tty; the decisions it makes do not.
fn testSession(allocator: std.mem.Allocator) Session {
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

test "completing a command replaces the whole draft" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    const rows = [_]slash.Spec{.{ .name = "/help", .help = "list slash commands" }};
    try sess.draft.insertSlice(std.testing.allocator, "/hel");
    sess.palette = &rows;
    try std.testing.expect(!try sess.completePalette());
    try std.testing.expectEqualStrings("/help", sess.draft.items());
    try std.testing.expectEqual(@as(usize, 0), sess.palette.len);
}

test "completing a mention replaces only the mention" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    const rows = [_]slash.Spec{.{ .name = "@src/cli/tui.zig", .help = "file" }};
    try sess.draft.insertSlice(std.testing.allocator, "look at @src/cli/tu");
    sess.palette = &rows;
    // True: a mention is an argument, so Enter must keep editing, not send.
    try std.testing.expect(try sess.completePalette());
    try std.testing.expectEqualStrings("look at @src/cli/tui.zig", sess.draft.items());
}

test "completing with an empty palette is a no-op" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.draft.insertSlice(std.testing.allocator, "/hel");
    try std.testing.expect(!try sess.completePalette());
    try std.testing.expectEqualStrings("/hel", sess.draft.items());
}

test "the session footer follows the resolved model and turn" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    sess.fallback_model = "(unset)";
    try std.testing.expectEqualStrings("(unset)", sess.footer(.idle).model);
    try std.testing.expect(sess.footer(.generating).turn == .generating);
}

test "a session transcript survives clear and reuse" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("first turn\n");
    try std.testing.expect(!sess.shown.isEmpty());
    sess.shown.clear();
    try std.testing.expect(sess.shown.isEmpty());
    try sess.shown.append("second turn\n");
    try std.testing.expectEqualStrings("second turn\n", sess.shown.bytes());
}

test "the permissions row offers exactly the real surfaces" {
    // A choice list that disagrees with config.Surface makes every current
    // value look unmatched, so cycling always restarts from the first option.
    // settingsPanel formats values into sess.arena, so the test needs a real
    // one rather than the leak-checking allocator standing in for it.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = scratch.allocator();
    defer sess.deinit();
    const p = settingsPanel(&sess);
    for (p.items()) |f| {
        if (!std.mem.eql(u8, f.key, "mode")) continue;
        const opts = switch (f.kind) {
            .choice => |o| o,
            else => return error.PermissionsRowIsNotAChoice,
        };
        try std.testing.expectEqual(std.meta.tags(config.Surface).len, opts.len);
        for (opts) |o| {
            try std.testing.expect(config.Surface.fromSlice(o) != null);
        }
        // And the value currently shown has to be one of them.
        var found = false;
        for (opts) |o| {
            if (std.mem.eql(u8, o, f.value)) found = true;
        }
        try std.testing.expect(found);
        return;
    }
    return error.NoPermissionsRow;
}

test "every settings row maps to a key the setter accepts" {
    // settingsPanel formats values into sess.arena, so the test needs a real
    // one rather than the leak-checking allocator standing in for it.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = scratch.allocator();
    defer sess.deinit();
    const p = settingsPanel(&sess);
    try std.testing.expect(p.n > 0);
    for (p.items()) |f| {
        try std.testing.expect(f.key.len > 0);
        try std.testing.expect(f.label.len > 0);
        if (f.kind == .info) continue;
        // An editable row with no help is a control nobody can explain.
        try std.testing.expect(f.help.len > 0);
    }
}

test "every panel builds without a terminal" {
    // A panel that crashes or comes back empty is a command that looks broken.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = scratch.allocator();
    defer sess.deinit();

    const built = [_]panel_mod.Panel{
        settingsPanel(&sess),
        statuslinePanel(&sess),
        statusPanel(&sess),
        jobsPanel(&sess),
        workspacePanel(&sess),
        sessionPanel(&sess),
        helpPanel(&sess),
    };
    for (built) |p| {
        try std.testing.expect(p.title.len > 0);
        // Empty is allowed only if the panel says why.
        try std.testing.expect(p.n > 0);
        for (p.items()) |f| try std.testing.expect(f.label.len > 0);
    }
}

test "session panel shows when and del removes the file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try pathing.testWorkspace(a, &tmp);
    defer a.free(home);
    const dir_path = try std.fs.path.join(a, &.{ home, ".omfx", "sessions" });
    defer a.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    {
        const path = try std.fs.path.join(a, &.{ dir_path, "gone.jsonl" });
        defer a.free(path);
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        var buf: [256]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("{\"kind\":\"user\",\"text\":\"hello there\"}\n");
        try w.interface.flush();
    }
    {
        const path = try std.fs.path.join(a, &.{ dir_path, "stay.jsonl" });
        defer a.free(path);
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        var buf: [256]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("{\"kind\":\"user\",\"text\":\"keep me\"}\n");
        try w.interface.flush();
    }

    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var sess = testSession(a);
    sess.arena = scratch.allocator();
    sess.home = home;
    defer sess.deinit();

    sess.openPanel(sessionPanel(&sess));
    sess.panel_kind = .sessions;
    const p0 = sess.panel.?;
    try std.testing.expect(p0.n >= 2);
    var saw_when = false;
    for (p0.items()) |f| {
        if (f.kind != .pick) continue;
        try std.testing.expect(std.mem.startsWith(u8, f.key, "/resume "));
        try std.testing.expect(std.mem.indexOf(u8, f.value, "·") != null);
        try std.testing.expect(f.value.len >= "YYYY-MM-DD HH:MM".len);
        try std.testing.expect(std.mem.indexOf(u8, f.help, "del deletes") != null);
        saw_when = true;
    }
    try std.testing.expect(saw_when);

    // Select the first pick and delete it forever.
    sess.panel.?.selectFirst();
    const before = sess.panel.?.n;
    try std.testing.expect(panelKey(&sess, .delete));
    try std.testing.expect(sess.panel != null);
    try std.testing.expectEqual(cmds.PanelKind.sessions, sess.panel_kind.?);
    try std.testing.expect(sess.panel.?.n < before);

    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const left = try session.listIds(dir, io, a);
    defer {
        for (left) |id| a.free(id);
        a.free(left);
    }
    try std.testing.expectEqual(@as(usize, 1), left.len);
}

test "the help panel lists every command exactly once" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    const p = helpPanel(&sess);
    var seen: usize = 0;
    for (p.items()) |f| {
        if (f.kind != .pick) continue;
        seen += 1;
        // A row you can pick has to name a real command.
        try std.testing.expect(slash.find(f.key) != null);
    }
    try std.testing.expectEqual(slash.builtin.len, seen);
    // Nothing was silently dropped off the end.
    try std.testing.expectEqual(@as(usize, 0), p.overflow);
}

test "the cursor lands on a runnable row, never a heading" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    const p = helpPanel(&sess);
    const f = p.current().?;
    try std.testing.expect(f.kind != .heading and f.kind != .info);
}

test "typing into the commands panel filters it" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    defer sess.panel_edit.deinit(std.testing.allocator);
    try sess.panel_edit.appendSlice(std.testing.allocator, "sess");
    const p = helpPanel(&sess);
    var picks: usize = 0;
    for (p.items()) |f| {
        if (f.kind != .pick) continue;
        picks += 1;
        // Matched on the name or on what the command does, not on neither.
        try std.testing.expect(std.ascii.indexOfIgnoreCase(f.key, "sess") != null or
            std.ascii.indexOfIgnoreCase(f.value, "sess") != null);
    }
    try std.testing.expect(picks > 0);
    try std.testing.expect(picks < slash.builtin.len);
}

test "a query that matches nothing says so instead of showing everything" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    defer sess.panel_edit.deinit(std.testing.allocator);
    try sess.panel_edit.appendSlice(std.testing.allocator, "zzzznope");
    const p = helpPanel(&sess);
    try std.testing.expectEqual(@as(usize, 1), p.n);
    try std.testing.expectEqual(panel_mod.Kind.info, p.items()[0].kind);
}

test "auto resolves to a level of the model's own, and only auto does" {
    var ep = types.Endpoint{
        .vendor = .xai,
        .base_url = "https://api.x.ai/v1",
        .api_key = "k",
        .model = "grok-4.6",
    };
    const ladder = "low,medium,high,xhigh";

    applyEffort(&ep, "high", ladder, "anything", 0);
    try std.testing.expectEqualStrings("high", ep.effort);

    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, ladder, "why does this deadlock?", 0);
    try std.testing.expectEqualStrings("xhigh", ep.effort);

    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, ladder, "rename x to y", 0);
    try std.testing.expectEqualStrings("low", ep.effort);

    // Two failed turns: down, not up.
    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, ladder, "why does this deadlock?", 2);
    try std.testing.expectEqualStrings("low", ep.effort);

    // A model with no levels is left alone rather than sent "auto".
    ep.effort = "";
    applyEffort(&ep, cmds.auto_effort, "", "why does this deadlock?", 0);
    try std.testing.expectEqualStrings("", ep.effort);
}

test "a note holds the hint row briefly, then gives it back" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    sess.note("Reasoning set to high.", 1000);
    try std.testing.expectEqualStrings("Reasoning set to high.", sess.mode_note);
    try std.testing.expect(!sess.noteExpired(1000));
    try std.testing.expect(!sess.noteExpired(1000 + Session.note_ms - 1));
    try std.testing.expect(sess.noteExpired(1000 + Session.note_ms));
    sess.noteClear();
    // Nothing set, so nothing to expire: an empty note must not ask for a
    // repaint on every idle poll.
    try std.testing.expect(!sess.noteExpired(1_000_000));
}

test "enter opens a run, then opens a call inside it, then closes each" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();

    const off = sess.shown.bytes().len;
    const row = try chat.formatGroup(a, sess.layout.cols, .{
        .name = "bash",
        .last_detail = "zig test",
        .count = 2,
    });
    defer a.free(row);
    try sess.shown.append(row);
    try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{ "built\n", "ok\n" });

    try std.testing.expect(sess.focusScrollback());
    try std.testing.expect(sess.runs.items.items[0].openable());

    // Enter on a closed run opens it.
    _ = scrollbackKey(&sess, .enter);
    try std.testing.expect(sess.runs.items.items[0].expanded);

    // Enter again opens the call the cursor is on, rather than closing the run.
    _ = scrollbackKey(&sess, .enter);
    try std.testing.expect(sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "built") != null);

    // And once more on the same call closes just that call.
    _ = scrollbackKey(&sess, .enter);
    try std.testing.expect(!sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(sess.runs.items.items[0].expanded);
}

test "a drag marks text and letting go copies it" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();
    try sess.shown.append("hello world\n");

    const row = termRow(&sess, 0);
    sess.startSel(row, 1);
    try std.testing.expect(!sess.marked.on());
    sess.extendSel(row, 6);
    try std.testing.expect(sess.marked.on());

    const text = try sess.selText(a);
    defer a.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "the task list pins while there is work left, then gets out of the way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();
    var rows: [todos.max_items][]const u8 = undefined;

    // The list is process-wide, so start from a known empty one.
    const none = try todos.set(std.testing.allocator, "{\"todos\":[]}");
    std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), sess.pinTodos(&rows).len);

    const out = try todos.set(std.testing.allocator,
        \\{"todos":[{"content":"read the loader","status":"completed"},{"content":"fix the parser","status":"in_progress"},{"content":"run the tests","status":"pending"}]}
    );
    std.testing.allocator.free(out);
    const pinned = sess.pinTodos(&rows);
    try std.testing.expectEqual(@as(usize, 3), pinned.len);
    try std.testing.expect(std.mem.indexOf(u8, pinned[1], "fix the parser") != null);
    // Exactly one task reads at full weight: the one being worked on.
    try std.testing.expect(std.mem.indexOf(u8, pinned[1], paint.accent_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, pinned[2], paint.accent_dim) == null);

    // All done: the pane gives the rows back rather than holding a wall of ticks.
    const fin = try todos.set(std.testing.allocator,
        \\{"todos":[{"content":"read the loader","status":"completed"}]}
    );
    std.testing.allocator.free(fin);
    try std.testing.expectEqual(@as(usize, 0), sess.pinTodos(&rows).len);
}

test "the context card splits the window into parts that add up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    // Nothing measured yet: say so rather than draw a card of zeroes.
    try std.testing.expectEqual(panel_mod.Kind.info, contextPanel(&sess).items()[0].kind);
    try std.testing.expectEqual(@as(usize, 1), contextPanel(&sess).n);

    sess.ctx_window = 500_000;
    sess.ctx_used = 100_000;
    sess.trace_sys = 8_000;
    sess.trace_tools = 4_000;
    const p = contextPanel(&sess);
    try std.testing.expectEqualStrings("Total", p.items()[0].label);
    try std.testing.expectEqualStrings("100.0k (20%)", p.items()[0].value);
    // 12000 bytes of fixed floor at four bytes a token is 3000, so messages
    // is what the provider counted minus that.
    try std.testing.expectEqualStrings("97.0k (19%)", p.items()[1].value);
    try std.testing.expectEqualStrings("2.0k (0%)", p.items()[2].value);
    try std.testing.expectEqualStrings("1.0k (0%)", p.items()[3].value);
    try std.testing.expectEqualStrings("400.0k (80%)", p.items()[4].value);
}

test "the rewind panel offers a prompt to go back to, not a number to count" {
    // The panel builds its rows in the turn arena, which the session owns in
    // a real run; the test has to give it one.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    const empty = rewindPanel(&sess);
    try std.testing.expectEqual(@as(usize, 1), empty.n);
    try std.testing.expectEqual(panel_mod.Kind.info, empty.items()[0].kind);

    sess.state.pushMark("add the dark mode toggle", 4, 0);
    sess.state.pushMark("run the tests", 9, 1);
    const p = rewindPanel(&sess);
    // Newest first: the last thing you asked is the likeliest place to return.
    try std.testing.expectEqualStrings("run the tests", p.items()[0].label);
    try std.testing.expectEqualStrings("add the dark mode toggle", p.items()[1].label);
    // Picking a row runs the command it names.
    try std.testing.expectEqualStrings("/rewind 1", p.items()[0].key);
    try std.testing.expectEqualStrings("/rewind 2", p.items()[1].key);
    try std.testing.expectEqualStrings("1 turn back", p.items()[0].value);
    try std.testing.expectEqualStrings("2 turns back", p.items()[1].value);
}

test "clicking away from the scrollback hands the keyboard back" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();
    try sess.shown.append("\u{25b8} Read a file  a.zig\n");
    try sess.runs.add(0, sess.shown.bytes().len, false, "read", &.{"a.zig"}, &.{});

    try std.testing.expect(sess.focusScrollback());
    try std.testing.expect(sess.focus == .scrollback);

    // The composer is where typing goes, so a press there takes the keyboard.
    sess.startSel(sess.layout.footer_start_row + 1, 3);
    try std.testing.expect(sess.focus == .prompt);

    try std.testing.expect(sess.focusScrollback());
    // And so does a press on chrome, which belongs to neither region.
    sess.startSel(sess.layout.rows, 3);
    try std.testing.expect(sess.focus == .prompt);
}

test "a drag never leaves the region it started in" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();
    try sess.shown.append("hello world\n");

    sess.startSel(termRow(&sess, 0), 1);
    // Chrome has no region, so the mark stays where the drag began: half a
    // selection in the transcript and half in the footer cannot be copied.
    sess.extendSel(sess.layout.rows, 4);
    try std.testing.expect(!sess.marked.on());
    try std.testing.expect(sess.marked.where == .transcript);
}

test "a click opens the run, then the call, then puts each back" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.shown.deinit();
    defer sess.runs.deinit();

    const off = sess.shown.bytes().len;
    const row = try chat.formatGroup(a, sess.layout.cols, .{
        .name = "bash",
        .last_detail = "zig test",
        .count = 2,
    });
    defer a.free(row);
    try sess.shown.append(row);
    try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{ "built\n", "ok\n" });

    const summary = termRow(&sess, 0);
    sess.clickRun(summary);
    try std.testing.expect(sess.runs.items.items[0].expanded);
    // The keyboard follows the pointer, so the two never disagree.
    try std.testing.expect(sess.focus == .scrollback);

    // The first call is the row under the summary.
    sess.clickRun(termRow(&sess, 1));
    try std.testing.expect(sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "built") != null);

    // Clicking the same call again closes it; the run stays open.
    sess.clickRun(termRow(&sess, 1));
    try std.testing.expect(!sess.runs.items.items[0].childOpen(0));
    try std.testing.expect(sess.runs.items.items[0].expanded);

    // And clicking the summary again closes the run.
    sess.clickRun(termRow(&sess, 0));
    try std.testing.expect(!sess.runs.items.items[0].expanded);
}

test "an idle footer carries no activity row" {
    var sess = testSession(std.testing.allocator);
    defer sess.shown.deinit();
    // What the bug looked like: the row survived the turn that owned its bytes,
    // and the next paint read a stack frame that was gone.
    sess.status = "Waiting for response...";
    try std.testing.expectEqualStrings("Waiting for response...", sess.footer(.generating).status);
    sess.status = "";
    try std.testing.expectEqualStrings("", sess.footer(.idle).status);
}

/// The terminal row the pane is currently painting transcript row `idx` on.
fn termRow(sess: *const Session, idx: usize) u16 {
    const n = sess.shown.rowCount();
    const vis: u16 = @intCast(@min(n, sess.layout.transcript_rows));
    return tui.transcriptFirstRow(sess.layout.transcript_start_row, sess.layout.transcript_rows, vis) +
        @as(u16, @intCast(idx));
}

test "a click opens the run it landed on, and closes it again" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("before\n");
    const off = sess.shown.bytes().len;
    const rec_row = try chat.formatGroup(std.testing.allocator, sess.layout.cols, .{
        .name = "bash",
        .last_detail = "zig test",
        .count = 2,
    });
    defer std.testing.allocator.free(rec_row);
    try sess.shown.append(rec_row);
    try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{});

    const rows0 = sess.shown.rowCount();
    sess.clickRun(termRow(&sess, 1));
    try std.testing.expectEqual(rows0 + 2, sess.shown.rowCount());
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "zig build") != null);

    // Clicking the summary again closes it.
    sess.clickRun(termRow(&sess, 1));
    try std.testing.expectEqual(rows0, sess.shown.rowCount());
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "zig build") == null);
    try std.testing.expectEqualStrings("before", sess.shown.row(0));
}

test "a run with one call has nothing to open" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("\u{25b8} Read a file  a.zig\n");
    try sess.runs.add(0, sess.shown.bytes().len, false, "read", &.{"a.zig"}, &.{});
    sess.clickRun(termRow(&sess, 0));
    try std.testing.expect(!sess.runs.items.items[0].expanded);
}

test "the scrollback keyboard walks runs and folds the selected one" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.deinit();
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const off = sess.shown.bytes().len;
        const row = try chat.formatGroup(a, sess.layout.cols, .{
            .name = "bash",
            .last_detail = "zig test",
            .count = 2,
        });
        defer a.free(row);
        try sess.shown.append(row);
        try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "zig build", "zig test" }, &.{});
    }

    // Focus lands on the newest run, not the oldest.
    try std.testing.expect(sess.focusScrollback());
    try std.testing.expectEqual(@as(usize, 1), sess.sel);
    try std.testing.expect(sess.runs.items.items[1].selected);

    _ = scrollbackKey(&sess, .{ .byte = 'k' });
    try std.testing.expectEqual(@as(usize, 0), sess.sel);
    try std.testing.expect(!sess.runs.items.items[1].selected);

    _ = scrollbackKey(&sess, .{ .byte = 'e' });
    try std.testing.expect(sess.runs.items.items[0].expanded);
    try std.testing.expect(std.mem.indexOf(u8, sess.shown.bytes(), "zig build") != null);
    _ = scrollbackKey(&sess, .{ .byte = 'h' });
    try std.testing.expect(!sess.runs.items.items[0].expanded);

    // Typing anything else goes back to the composer and is not swallowed.
    try std.testing.expect(!scrollbackKey(&sess, .{ .byte = 'z' }));
    try std.testing.expectEqual(Session.Focus.prompt, sess.focus);
    try std.testing.expect(!sess.runs.items.items[0].selected);
}

test "there is nothing to focus without a run" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    try sess.shown.append("just text\n");
    try std.testing.expect(!sess.focusScrollback());
    try std.testing.expectEqual(Session.Focus.prompt, sess.focus);
}

test "E opens every run at once, and closes them the same way" {
    const a = std.testing.allocator;
    var sess = testSession(a);
    defer sess.deinit();
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const off = sess.shown.bytes().len;
        const row = try chat.formatGroup(a, sess.layout.cols, .{ .name = "bash", .count = 2 });
        defer a.free(row);
        try sess.shown.append(row);
        try sess.runs.add(off, sess.shown.bytes().len - off, false, "bash", &.{ "one", "two" }, &.{});
    }
    try std.testing.expect(sess.focusScrollback());
    _ = scrollbackKey(&sess, .{ .byte = 'E' });
    for (sess.runs.items.items) |r| try std.testing.expect(r.expanded);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, sess.shown.bytes(), "one"));
    _ = scrollbackKey(&sess, .{ .byte = 'E' });
    for (sess.runs.items.items) |r| try std.testing.expect(!r.expanded);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, sess.shown.bytes(), "one"));
}

test "the keys panel filters as you type and opens a page" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    sess.openSearchPanel(.shortcuts);
    const all = sess.panel.?.n;
    try std.testing.expect(all > 10);

    _ = panelKey(&sess, .{ .byte = 's' });
    _ = panelKey(&sess, .{ .byte = 'c' });
    const some = sess.panel.?.n;
    try std.testing.expect(some < all);
    try std.testing.expect(some > 0);
    try std.testing.expectEqualStrings("sc", sess.panel.?.query);

    // Backspace widens the list again.
    _ = panelKey(&sess, .backspace);
    try std.testing.expect(sess.panel.?.n > some);

    // Enter reads the binding rather than running it.
    sess.panel_edit.clearRetainingCapacity();
    sess.refilterPanel();
    sess.panel.?.selectFirst();
    _ = panelKey(&sess, .enter);
    try std.testing.expect(sess.panel.?.detail_of != null);
    try std.testing.expectEqualStrings("", sess.panel_pick);
    _ = panelKey(&sess, .esc);
    try std.testing.expect(sess.panel.?.detail_of == null);
    try std.testing.expect(sess.panel != null);
}

test "every binding lands in a section" {
    for (tui.key_rows) |row| {
        try std.testing.expect(row.section.len != 0);
        try std.testing.expect(row.help.len != 0);
    }
}

test "a prompt typed during a turn lands in the composer" {
    var sess = testSession(std.testing.allocator);
    defer sess.deinit();
    sink.dropSteer();

    // Nothing typed: the composer is left alone.
    takeSteering(&sess);
    try std.testing.expectEqual(@as(usize, 0), sess.draft.items().len);
    try std.testing.expect(!sess.steer_send);

    sink.pushSteerForTest("and run the tests");
    takeSteering(&sess);
    try std.testing.expectEqualStrings("and run the tests", sess.draft.items());
    try std.testing.expect(!sess.steer_send);

    // Enter while the turn ran means send it, appended to what was there.
    sink.pushSteerForTest(" now\r");
    takeSteering(&sess);
    try std.testing.expectEqualStrings("and run the tests now", sess.draft.items());
    try std.testing.expect(sess.steer_send);
    sink.dropSteer();
}

test "the context card carries the cache split, wherever it was opened from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    sess.ctx_window = 500_000;
    sess.ctx_used = 200_000;
    sess.ctx_fresh = 6_000;
    sess.ctx_cache_read = 190_000;
    sess.ctx_cache_write = 4_000;

    // `/context` and a click on the header counter open the same card, so
    // asserting the one function covers both doors.
    const p = contextPanel(&sess);
    var hit: ?[]const u8 = null;
    var wrote: ?[]const u8 = null;
    for (p.items()) |it| {
        if (std.mem.eql(u8, it.label, "Served from cache")) hit = it.value;
        if (std.mem.eql(u8, it.label, "Written to cache")) wrote = it.value;
    }
    // 190000 of a 200000-token prompt.
    try std.testing.expectEqualStrings("190.0k of the last prompt (95%)", hit.?);
    try std.testing.expect(wrote != null);
}

test "a provider that reports no caching gets no cache rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = testSession(std.testing.allocator);
    sess.arena = arena_state.allocator();
    defer sess.shown.deinit();

    sess.ctx_window = 500_000;
    sess.ctx_used = 100_000;
    // Nothing measured means nothing claimed: a card of zeroes reads as a
    // cache that missed, which is not what happened.
    const p = contextPanel(&sess);
    for (p.items()) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.label, "Served from cache"));
    }
}
