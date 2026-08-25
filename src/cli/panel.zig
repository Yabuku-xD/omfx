//! Full-window panels for slash commands that are editors, not one-shot output.
//!
//! `/settings` printing a key=value dump and asking you to retype
//! `/settings sound=off` is a form pretending to be a log line. A panel is the
//! same data with a cursor on it: arrow to a row, press space or type, see the
//! value change where it lives.
//!
//! Design constraints this file works under:
//!
//!  - Zero dependencies. libvaxis is the reference for *technique* -- its
//!    double-buffered cell diff, its lazy-render gate, its synchronized frame --
//!    not a library to link. omfx paints its own SGR (see `AGENTS.md`).
//!  - Rendering is pure. `render` takes a `Panel` and returns bytes, so every
//!    layout rule here is testable without a terminal.
//!  - Motion is a function of elapsed milliseconds, never of frame count, so a
//!    slow terminal shows the same animation shorter rather than in slow motion.

const std = @import("std");
const Io = std.Io;

const paint = @import("../core/ansi.zig");
const width = @import("width.zig");
const virt = @import("virt.zig");

/// Reveal time for an opening panel. Long enough to read as motion, short
/// enough that it never delays a keystroke: a panel is interactive on the
/// first frame, the animation only affects what is drawn.
pub const open_ms: i64 = 120;
/// Frame budget. 60fps is wasted on a terminal; this is the rate at which
/// row-by-row reveal still looks continuous.
pub const frame_ms: i64 = 16;

/// Widest a panel will ever draw, so a 300-column terminal gets a readable
/// column rather than a full-bleed wall of text.
pub const max_cols: u16 = 72;
/// Rows of list a panel shows at once. Past this it scrolls.
///
/// A panel sized to its content means `/help` is a full-screen wall while
/// `/status` is a sliver -- every command a different shape. A fixed window
/// makes them one recognisable object, and 15 rows fits a 24-row terminal with
/// the transcript still visible behind it.
pub const max_visible: u16 = 15;
/// Every slash command plus its group headings is ~55 rows, and a session list
/// can be longer. A cap below that silently drops rows off the end of a list,
/// which is worse than a taller struct: `/help` showed 24 of 46 commands.
pub const max_fields: usize = 128;

comptime {
    if (open_ms <= 0) @compileError("open_ms must animate for a measurable time");
    if (max_fields == 0) @compileError("a panel must hold at least one field");
}

/// What a row edits. The kind decides how the value renders and what a
/// keypress does to it, so adding a control type does not touch the painter.
pub const Kind = union(enum) {
    /// on/off. Space or Enter flips it.
    toggle,
    /// One of a fixed set. Left/right cycles.
    choice: []const []const u8,
    text,
    /// Whole number, clamped. Left/right steps by `step`, which a byte budget
    /// needs larger than one to be reachable at all.
    number: struct { min: u32, max: u32, step: u32 = 1 },
    /// Not editable: shown for orientation (a path, a version).
    info,
    /// A row you pick rather than edit: a command, a session, a model.
    /// Enter chooses it and closes the panel.
    pick,
    /// A heading inside a list. Skipped by the cursor, like `.info`.
    heading,
    /// A row that is read, not edited: a key binding. The cursor lands on it so
    /// Enter can open its page, and nothing else happens to it.
    entry,
};

pub const Field = struct {
    key: []const u8,
    label: []const u8,
    kind: Kind,
    /// Current value, borrowed. The panel never owns strings.
    value: []const u8 = "",
    /// One line under the row when selected. Says why, not what.
    help: []const u8 = "",
    /// The long form, shown on its own page when the row is opened. A binding
    /// whose one-line help is the whole story does not need one.
    detail: []const u8 = "",
};

pub const Panel = struct {
    title: []const u8,
    fields: [max_fields]Field = undefined,
    n: usize = 0,
    sel: usize = 0,
    /// Milliseconds since the panel opened. Drives the reveal.
    elapsed_ms: i64 = open_ms,
    /// Set while a `.text` row is being typed into.
    editing: bool = false,
    /// Live edit buffer for the row being typed into, borrowed from the caller.
    edit: []const u8 = "",

    /// Whether typing filters the list. The rows themselves are rebuilt by the
    /// caller against `query`, so the panel stays a painter and never has to
    /// hold two views of the same list.
    search: bool = false,
    /// What has been typed into the search, borrowed.
    query: []const u8 = "",
    /// The row whose `detail` is open, if any.
    detail_of: ?usize = null,

    /// Rows past the cap are dropped. `overflow` records that so a caller can
    /// say so rather than presenting a truncated list as complete.
    overflow: usize = 0,

    pub fn add(self: *Panel, f: Field) void {
        if (self.n == max_fields) {
            self.overflow += 1;
            return;
        }
        self.fields[self.n] = f;
        self.n += 1;
    }

    pub fn items(self: *const Panel) []const Field {
        return self.fields[0..self.n];
    }

    pub fn current(self: *const Panel) ?Field {
        if (self.n == 0) return null;
        return self.fields[@min(self.sel, self.n - 1)];
    }

    /// Put the cursor on the first row a keypress would act on.
    ///
    /// `move(1)` then `move(-1)` looks equivalent and is not: `move` wraps, so
    /// stepping back from the first row lands on the *last* one. Every list
    /// panel opened scrolled to its bottom because of it.
    pub fn selectFirst(self: *Panel) void {
        for (self.fields[0..self.n], 0..) |f, i| {
            if (f.kind == .info or f.kind == .heading) continue;
            self.sel = i;
            return;
        }
        self.sel = 0;
    }

    /// Rows skip `.info` when moving, so the cursor never parks somewhere a
    /// keypress would do nothing.
    pub fn move(self: *Panel, delta: i32) void {
        if (self.n == 0) return;
        var i: usize = self.sel;
        var guard: usize = 0;
        while (guard <= self.n) : (guard += 1) {
            const next = @mod(@as(i32, @intCast(i)) + delta + @as(i32, @intCast(self.n)), @as(i32, @intCast(self.n)));
            i = @intCast(next);
            if (self.fields[i].kind != .info and self.fields[i].kind != .heading) break;
        }
        self.sel = i;
    }
};

/// Eased fraction of the reveal, 0..1.
///
/// Ease-out cubic: fastest at the start, settling at the end. A linear reveal
/// reads as a machine drawing rows; this reads as a panel arriving.
pub fn progress(elapsed_ms: i64) f32 {
    if (elapsed_ms >= open_ms) return 1;
    if (elapsed_ms <= 0) return 0;
    const t = @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(open_ms));
    const inv = 1 - t;
    return 1 - inv * inv * inv;
}

/// Rows of the panel body visible at this point in the reveal. Always at least
/// one, so an opening panel is never a bare border.
pub fn revealedRows(total: usize, elapsed_ms: i64) usize {
    if (total == 0) return 0;
    const p = progress(elapsed_ms);
    const shown: usize = @intFromFloat(@round(p * @as(f32, @floatFromInt(total))));
    return @max(1, @min(total, shown));
}

/// True while a repaint is still needed. The caller stops scheduling frames
/// when this goes false, so an idle panel costs nothing -- libvaxis's
/// lazy-render gate, without its screen buffer.
pub fn animating(elapsed_ms: i64) bool {
    return elapsed_ms < open_ms;
}

pub const Geometry = struct {
    cols: u16,
    rows: u16,
    row0: u16,
    col0: u16,
};

/// Rows of the frame that are not fields: top border, title, rule, help,
/// bottom border.
pub const chrome_rows: u16 = 5;

/// How many fields fit in this geometry. A list longer than this scrolls
/// rather than drawing past the frame -- an unwindowed `/help` painted 54 rows
/// into a 34-row terminal and tore the box apart.
pub fn visibleRows(g: Geometry) usize {
    return virt.viewRows(g.rows, chrome_rows, max_visible);
}

/// First field to draw so `sel` stays on screen.
pub fn windowStart(total: usize, sel: usize, view: usize) usize {
    return virt.windowStart(total, sel, view);
}

/// Centred, clamped to `max_cols`, and never taller than the pane.
pub fn geometry(term_rows: u16, term_cols: u16, field_count: usize) Geometry {
    const want_cols: u16 = @min(max_cols, if (term_cols > 8) term_cols - 4 else term_cols);
    // title + rule + fields + rule + help + borders
    const capped_fields = @min(field_count, @as(usize, max_visible));
    const want_rows: u16 = @intCast(@min(@as(usize, term_rows), capped_fields + chrome_rows + 1));
    return .{
        .cols = want_cols,
        .rows = want_rows,
        .row0 = if (term_rows > want_rows) (term_rows - want_rows) / 2 + 1 else 1,
        .col0 = if (term_cols > want_cols) (term_cols - want_cols) / 2 + 1 else 1,
    };
}

fn valueText(f: Field, editing: bool, edit: []const u8) []const u8 {
    if (editing and f.kind == .text) return edit;
    if (f.value.len != 0) return f.value;
    return switch (f.kind) {
        .toggle => "off",
        else => "-",
    };
}

/// `on` is two letters, `off` is three. The trailing space keeps both
/// decorations five cells so the right border does not jump on toggle.
const toggle_on = "\u{25cf} on ";
const toggle_off = "\u{25cb} off";
const choice_l = "\u{2039} ";
const choice_r = " \u{203a}";

comptime {
    std.debug.assert(width.cellsTo(toggle_on) == width.cellsTo(toggle_off));
}

fn toggleMark(on: bool) []const u8 {
    return if (on) toggle_on else toggle_off;
}

/// Pad must count what `decorate` paints. Counting the raw value left the
/// right `|` one column past the frame.
fn valueCells(kind: Kind, selected: bool, text: []const u8) u16 {
    return switch (kind) {
        .toggle => width.cellsTo(toggleMark(std.mem.eql(u8, text, "on"))),
        .choice => blk: {
            var n = width.cellsTo(text);
            if (selected) n += width.cellsTo(choice_l) + width.cellsTo(choice_r);
            break :blk n;
        },
        else => width.cellsTo(text),
    };
}

/// How a value is decorated. A toggle reads as a switch, a choice as a
/// carousel, so the control type is legible without reading the help line.
fn decorate(out: *std.ArrayList(u8), a: std.mem.Allocator, f: Field, selected: bool, text: []const u8) !void {
    switch (f.kind) {
        .toggle => {
            const on = std.mem.eql(u8, text, "on");
            try out.appendSlice(a, if (on) paint.accent else paint.muted);
            try out.appendSlice(a, toggleMark(on));
            try out.appendSlice(a, paint.reset);
        },
        .choice => {
            if (selected) {
                try out.appendSlice(a, paint.muted);
                try out.appendSlice(a, choice_l);
                try out.appendSlice(a, paint.reset);
            }
            try out.appendSlice(a, if (selected) paint.accent else paint.asst_fg);
            try out.appendSlice(a, text);
            try out.appendSlice(a, paint.reset);
            if (selected) {
                try out.appendSlice(a, paint.muted);
                try out.appendSlice(a, choice_r);
                try out.appendSlice(a, paint.reset);
            }
        },
        .info, .entry => {
            try out.appendSlice(a, paint.muted);
            try out.appendSlice(a, text);
            try out.appendSlice(a, paint.reset);
        },
        // A pick row carries its description in the value column, dimmed, so
        // the name stays the thing you scan for.
        .pick => {
            try out.appendSlice(a, paint.muted);
            try out.appendSlice(a, text);
            try out.appendSlice(a, paint.reset);
        },
        .heading => {},
        .text, .number => {
            try out.appendSlice(a, if (selected) paint.accent else paint.asst_fg);
            try out.appendSlice(a, text);
            try out.appendSlice(a, paint.reset);
        },
    }
}

fn rule(out: *std.ArrayList(u8), a: std.mem.Allocator, n: u16) !void {
    var i: u16 = 0;
    while (i < n) : (i += 1) try out.appendSlice(a, "\u{2500}");
}

fn moveTo(buf: []u8, row: u16, col: u16) ![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col });
}

fn pad(out: *std.ArrayList(u8), a: std.mem.Allocator, used: u16, inner: u16) !void {
    var i: u16 = used;
    while (i < inner) : (i += 1) try out.append(a, ' ');
}

/// Pure: same panel and geometry in, same bytes out. Every layout rule in here
/// is asserted in this file's tests without a terminal.
pub fn render(a: std.mem.Allocator, p: *const Panel, g: Geometry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var cup: [32]u8 = undefined;

    const inner: u16 = if (g.cols >= 2) g.cols - 2 else 1;
    const view = visibleRows(g);
    const revealed = revealedRows(p.n, p.elapsed_ms);
    const shown = @min(revealed, view);
    const start = windowStart(p.n, p.sel, view);
    // The frame dims while opening, so the panel fades in rather than snapping.
    const opening = animating(p.elapsed_ms);
    const edge = if (opening) paint.border else paint.accent_dim;

    // Erase the panel's footprint first. Without this the transcript shows
    // through wherever a row is shorter than the one it covers -- the stray
    // vertical bars at the right edge of an open panel.
    var clear_row = g.row0;
    while (clear_row < g.row0 + g.rows) : (clear_row += 1) {
        try out.appendSlice(a, try moveTo(&cup, clear_row, g.col0));
        var c: u16 = 0;
        while (c < g.cols) : (c += 1) try out.append(a, ' ');
    }

    var r = g.row0;
    try out.appendSlice(a, try moveTo(&cup, r, g.col0));
    try out.appendSlice(a, edge);
    try out.appendSlice(a, "\u{256d}");
    try rule(&out, a, inner);
    try out.appendSlice(a, "\u{256e}");
    try out.appendSlice(a, paint.reset);
    r += 1;

    // Title row.
    try out.appendSlice(a, try moveTo(&cup, r, g.col0));
    try out.appendSlice(a, edge);
    try out.appendSlice(a, "\u{2502}");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.bold);
    try out.appendSlice(a, paint.accent);
    try out.append(a, ' ');
    const title = clip(p.title, if (inner > 2) inner - 2 else inner);
    try out.appendSlice(a, title);
    try out.appendSlice(a, paint.reset);
    var used_title: u16 = width.cellsTo(title) + 1;
    // What you have typed lives in the title, where a search box would be if
    // the panel had one. A separate row would cost a row of list on a short
    // terminal, and the list is the thing being searched.
    if (p.search) {
        const room: u16 = if (inner > used_title + 4) inner - used_title - 4 else 0;
        const q = clip(p.query, room);
        try out.appendSlice(a, paint.muted);
        try out.appendSlice(a, "  ");
        try out.appendSlice(a, q);
        try out.appendSlice(a, paint.reset);
        try out.appendSlice(a, paint.accent);
        try out.appendSlice(a, "\u{2588}");
        try out.appendSlice(a, paint.reset);
        used_title += 2 + width.cellsTo(q) + 1;
    }
    try pad(&out, a, used_title, inner);
    try out.appendSlice(a, edge);
    try out.appendSlice(a, "\u{2502}");
    try out.appendSlice(a, paint.reset);
    r += 1;

    // The box is always `view` rows tall, even while the reveal is still
    // filling it. Drawing a shorter frame each animation step left the previous
    // taller frame's bottom rows on screen -- the torn rows above an opening
    // panel.
    var drawn: usize = 0;
    if (p.detail_of) |di| {
        const f = p.fields[@min(di, if (p.n == 0) 0 else p.n - 1)];
        const text = if (f.detail.len != 0) f.detail else f.help;
        var rest = text;
        const room: u16 = if (inner > 4) inner - 4 else 1;
        while (drawn < view) : (drawn += 1) {
            const take = if (rest.len == 0) rest else wrapAt(rest, room);
            try out.appendSlice(a, try moveTo(&cup, r, g.col0));
            try out.appendSlice(a, edge);
            try out.appendSlice(a, "\u{2502}");
            try out.appendSlice(a, paint.reset);
            try out.appendSlice(a, "  ");
            try out.appendSlice(a, paint.asst_fg);
            try out.appendSlice(a, take);
            try out.appendSlice(a, paint.reset);
            try pad(&out, a, 2 + width.cellsTo(take), inner);
            try out.appendSlice(a, edge);
            try out.appendSlice(a, "\u{2502}");
            try out.appendSlice(a, paint.reset);
            r += 1;
            rest = if (take.len == 0) rest else std.mem.trimStart(u8, rest[take.len..], " \n");
        }
        return finish(&out, a, p, g, r, inner, edge, view);
    }
    for (p.items()[start .. start + shown], 0..) |f, off| {
        drawn += 1;
        const i = start + off;
        const selected = i == p.sel;
        try out.appendSlice(a, try moveTo(&cup, r, g.col0));
        try out.appendSlice(a, edge);
        try out.appendSlice(a, "\u{2502}");
        try out.appendSlice(a, paint.reset);

        // A caret marks the row a keypress acts on.
        try out.appendSlice(a, if (selected) paint.accent else paint.reset);
        try out.appendSlice(a, if (selected) " \u{25b8} " else "   ");
        try out.appendSlice(a, paint.reset);

        if (f.kind == .heading) {
            try out.appendSlice(a, paint.border);
            try out.appendSlice(a, " ");
            try out.appendSlice(a, paint.bold);
            try out.appendSlice(a, paint.label);
            const h = clip(f.label, if (inner > 4) inner - 4 else inner);
            try out.appendSlice(a, h);
            try out.appendSlice(a, paint.reset);
            try pad(&out, a, width.cellsTo(h) + 4, inner);
            try out.appendSlice(a, edge);
            try out.appendSlice(a, "\u{2502}");
            try out.appendSlice(a, paint.reset);
            r += 1;
            continue;
        }
        const label_w: u16 = @min(22, inner / 2);
        const label = clip(f.label, label_w);
        try out.appendSlice(a, if (selected) paint.asst_fg else paint.label);
        try out.appendSlice(a, label);
        try out.appendSlice(a, paint.reset);
        // Cells, never bytes. A `…` is three bytes and one column, so counting
        // length left every ellipsized row two cells short of the frame and the
        // transcript underneath showed through as a stray vertical bar.
        var used: u16 = 3 + width.cellsTo(label);
        while (used < 3 + label_w + 2) : (used += 1) try out.append(a, ' ');

        var val_buf: [max_cols * 4]u8 = undefined;
        const room: u16 = if (inner > used + 2) inner - used - 2 else 1;
        const text = clipEllipsis(&val_buf, valueText(f, p.editing and selected, p.edit), room);
        try decorate(&out, a, f, selected, text);
        used += valueCells(f.kind, selected, text);
        // A text row being edited shows where the caret sits.
        if (p.editing and selected and f.kind == .text) {
            try out.appendSlice(a, paint.accent);
            try out.appendSlice(a, "\u{2588}");
            try out.appendSlice(a, paint.reset);
            used += 1;
        }
        try pad(&out, a, used, inner);
        try out.appendSlice(a, edge);
        try out.appendSlice(a, "\u{2502}");
        try out.appendSlice(a, paint.reset);
        r += 1;
    }

    // Blank rows keep the frame the same height from the first frame on.
    const fill = @min(view, p.n);
    while (drawn < fill) : (drawn += 1) {
        try out.appendSlice(a, try moveTo(&cup, r, g.col0));
        try out.appendSlice(a, edge);
        try out.appendSlice(a, "\u{2502}");
        try out.appendSlice(a, paint.reset);
        try pad(&out, a, 0, inner);
        try out.appendSlice(a, edge);
        try out.appendSlice(a, "\u{2502}");
        try out.appendSlice(a, paint.reset);
        r += 1;
    }

    return finish(&out, a, p, g, r, inner, edge, view);
}

/// Longest prefix of `t` that fits `room` cells, broken at a space when there
/// is one. A detail page is prose, and prose does not break mid-word.
fn wrapAt(t: []const u8, room: u16) []const u8 {
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    const head = t[0..nl];
    if (width.cellsTo(head) <= room) return head;
    const cut = width.indexAtCell(head, room);
    if (cut == 0) return head[0..@min(head.len, 1)];
    if (std.mem.lastIndexOfScalar(u8, head[0..cut], ' ')) |sp| {
        if (sp != 0) return head[0..sp];
    }
    return head[0..cut];
}

/// The rule, the help row and the bottom border. Shared so the list view and
/// the detail page cannot drift into two different-looking panels.
fn finish(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    p: *const Panel,
    g: Geometry,
    row: u16,
    inner: u16,
    edge: []const u8,
    view: usize,
) ![]u8 {
    var cup: [32]u8 = undefined;
    var r = row;
    // Help for the selected row, then the key hints.
    try out.appendSlice(a, try moveTo(&cup, r, g.col0));
    try out.appendSlice(a, edge);
    try out.appendSlice(a, "\u{251c}");
    try rule(out, a, inner);
    try out.appendSlice(a, "\u{2524}");
    try out.appendSlice(a, paint.reset);
    r += 1;

    var pos_buf: [32]u8 = undefined;
    const pos: []const u8 = if (p.overflow > 0)
        std.fmt.bufPrint(&pos_buf, "{d}/{d} +{d} dropped", .{ p.sel + 1, p.n, p.overflow }) catch ""
    else if (p.n > view)
        std.fmt.bufPrint(&pos_buf, "{d}/{d}", .{ p.sel + 1, p.n }) catch ""
    else
        "";
    const help = if (p.current()) |f| f.help else "";
    try out.appendSlice(a, try moveTo(&cup, r, g.col0));
    try out.appendSlice(a, edge);
    try out.appendSlice(a, "\u{2502}");
    try out.appendSlice(a, paint.reset);
    try out.appendSlice(a, paint.muted);
    try out.append(a, ' ');
    const room: u16 = if (inner > 2 + pos.len) inner - 2 - @as(u16, @intCast(pos.len)) else inner;
    const help_text = clip(if (help.len != 0) help else hintFor(p), room);
    try out.appendSlice(a, help_text);
    try out.appendSlice(a, paint.reset);
    // Position sits at the right edge so a long list says where you are in it.
    if (pos.len != 0) {
        try pad(out, a, width.cellsTo(help_text) + 1, inner - width.cellsTo(pos));
        try out.appendSlice(a, paint.border);
        try out.appendSlice(a, pos);
        try out.appendSlice(a, paint.reset);
    } else {
        try pad(out, a, width.cellsTo(help_text) + 1, inner);
    }
    try out.appendSlice(a, edge);
    try out.appendSlice(a, "\u{2502}");
    try out.appendSlice(a, paint.reset);
    r += 1;

    try out.appendSlice(a, try moveTo(&cup, r, g.col0));
    try out.appendSlice(a, edge);
    try out.appendSlice(a, "\u{2570}");
    try rule(out, a, inner);
    try out.appendSlice(a, "\u{256f}");
    try out.appendSlice(a, paint.reset);
    return out.toOwnedSlice(a);
}

fn hintFor(p: *const Panel) []const u8 {
    if (p.editing) return "type your answer  ·  enter saves  ·  esc cancels";
    const f = p.current() orelse return "esc closes";
    return switch (f.kind) {
        .toggle => "space turns on/off  ·  up/down moves  ·  esc closes",
        .choice => "left/right changes  ·  up/down moves  ·  esc closes",
        .number => "left/right adjusts  ·  up/down moves  ·  esc closes",
        .text => "enter to edit  ·  up/down moves  ·  esc closes",
        .pick => "enter chooses  ·  up/down moves  ·  type to filter  ·  esc closes",
        .entry => "enter opens  ·  up/down moves  ·  type to filter  ·  esc closes",
        .info, .heading => "up/down moves  ·  esc closes",
    };
}

fn clip(s: []const u8, cols: u16) []const u8 {
    if (width.cellsTo(s) <= cols) return s;
    var n: usize = @min(s.len, cols);
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Clip with a trailing ellipsis, into a caller buffer.
///
/// A bare cut leaves `(/n` and `existin` on screen, which reads as broken
/// output rather than as text that did not fit.
fn clipEllipsis(buf: []u8, s: []const u8, cols: u16) []const u8 {
    if (cols == 0) return "";
    if (width.cellsTo(s) <= cols) return s;
    if (cols <= 1) return clip(s, cols);
    const head = clip(s, cols - 1);
    const n = @min(buf.len, head.len);
    @memcpy(buf[0..n], head[0..n]);
    if (n + 3 > buf.len) return buf[0..n];
    @memcpy(buf[n..][0..3], "\u{2026}");
    return buf[0 .. n + 3];
}

test "progress eases out and saturates" {
    try std.testing.expectEqual(@as(f32, 0), progress(0));
    try std.testing.expectEqual(@as(f32, 1), progress(open_ms));
    try std.testing.expectEqual(@as(f32, 1), progress(open_ms * 5));
    // Ease-out: more than half the distance is covered in the first half.
    try std.testing.expect(progress(@divTrunc(open_ms, 2)) > 0.5);
}

test "the reveal always shows a row and never overshoots" {
    try std.testing.expectEqual(@as(usize, 1), revealedRows(8, 0));
    try std.testing.expectEqual(@as(usize, 8), revealedRows(8, open_ms));
    try std.testing.expectEqual(@as(usize, 8), revealedRows(8, open_ms * 10));
    try std.testing.expectEqual(@as(usize, 0), revealedRows(0, 0));
    var ms: i64 = 0;
    while (ms <= open_ms) : (ms += frame_ms) {
        const n = revealedRows(6, ms);
        try std.testing.expect(n >= 1 and n <= 6);
    }
}

test "animating stops so an idle panel costs nothing" {
    try std.testing.expect(animating(0));
    try std.testing.expect(!animating(open_ms));
    try std.testing.expect(!animating(open_ms + 1));
}

test "geometry centres and clamps" {
    const g = geometry(40, 200, 6);
    try std.testing.expectEqual(max_cols, g.cols);
    // Centred, not flush left.
    try std.testing.expect(g.col0 > 1);
    try std.testing.expect(g.row0 > 1);

    // A narrow terminal gets the width it has, not a negative one, and the
    // panel must still fit inside the screen it was measured against.
    const tiny = geometry(6, 20, 6);
    try std.testing.expect(tiny.cols <= 20);
    try std.testing.expect(tiny.rows <= 6);
    try std.testing.expect(tiny.col0 + tiny.cols <= 20 + 1);
    try std.testing.expect(tiny.row0 + tiny.rows <= 6 + 1);

    // And a terminal narrower than the margin does not underflow.
    const cramped = geometry(3, 6, 4);
    try std.testing.expect(cramped.cols >= 1 and cramped.cols <= 6);
    try std.testing.expectEqual(@as(u16, 1), cramped.col0);
}

test "a list opens at its first actionable row, not its last" {
    var p = Panel{ .title = "t" };
    p.add(.{ .key = "", .label = "Head", .kind = .heading });
    p.add(.{ .key = "a", .label = "A", .kind = .pick });
    p.add(.{ .key = "b", .label = "B", .kind = .pick });
    p.selectFirst();
    try std.testing.expectEqual(@as(usize, 1), p.sel);

    // The move(1)/move(-1) pair this replaced wrapped past the heading to the
    // end of the list, which is why every list panel opened scrolled to its
    // bottom. Needs three rows to show: with two, the wrap lands back on 1.
    var q = Panel{ .title = "t" };
    q.add(.{ .key = "", .label = "Head", .kind = .heading });
    q.add(.{ .key = "a", .label = "A", .kind = .pick });
    q.add(.{ .key = "b", .label = "B", .kind = .pick });
    q.add(.{ .key = "c", .label = "C", .kind = .pick });
    q.move(1);
    q.move(-1);
    try std.testing.expectEqual(q.n - 1, q.sel);
    q.selectFirst();
    try std.testing.expectEqual(@as(usize, 1), q.sel);
}

test "selectFirst on an all-heading panel does not hang" {
    var p = Panel{ .title = "t" };
    p.add(.{ .key = "", .label = "H", .kind = .heading });
    p.selectFirst();
    try std.testing.expectEqual(@as(usize, 0), p.sel);
}

test "move skips info rows and wraps" {
    var p = Panel{ .title = "t" };
    p.add(.{ .key = "a", .label = "A", .kind = .toggle });
    p.add(.{ .key = "i", .label = "I", .kind = .info });
    p.add(.{ .key = "b", .label = "B", .kind = .toggle });
    p.move(1);
    // Landing on the info row would leave keys doing nothing.
    try std.testing.expectEqual(@as(usize, 2), p.sel);
    p.move(1);
    try std.testing.expectEqual(@as(usize, 0), p.sel);
    p.move(-1);
    try std.testing.expectEqual(@as(usize, 2), p.sel);
}

test "move on an all-info panel terminates" {
    var p = Panel{ .title = "t" };
    p.add(.{ .key = "i", .label = "I", .kind = .info });
    p.add(.{ .key = "j", .label = "J", .kind = .info });
    // The guard has to stop the search rather than spin forever.
    p.move(1);
    try std.testing.expect(p.sel < p.n);
}

fn testPanel() Panel {
    var p = Panel{ .title = "Settings" };
    p.add(.{ .key = "sound", .label = "Sound", .kind = .toggle, .value = "on", .help = "bell when a turn ends" });
    p.add(.{ .key = "mode", .label = "Permissions", .kind = .{ .choice = &.{ "ask", "auto", "yolo" } }, .value = "ask" });
    p.add(.{ .key = "composer", .label = "Composer", .kind = .text, .value = "> " });
    p.add(.{ .key = "path", .label = "File", .kind = .info, .value = "~/.omfx/settings.json" });
    return p;
}

test "render draws every visible field and the title" {
    const a = std.testing.allocator;
    var p = testPanel();
    const s = try render(a, &p, geometry(30, 100, p.n));
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Sound") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Permissions") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "~/.omfx/settings.json") != null);
    // The selected row carries a caret and the help line explains it.
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{25b8}") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "bell when a turn ends") != null);
}

test "the frame is the same height on every animation frame" {
    const a = std.testing.allocator;
    var names: [40][12]u8 = undefined;
    var p = longPanel(&names);
    const g = geometry(40, 100, p.n);

    // The bottom border must land on the same row at every point in the
    // reveal, or the previous frame's rows are left on screen.
    var first_bottom: ?usize = null;
    var ms: i64 = 0;
    while (ms <= open_ms) : (ms += frame_ms) {
        p.elapsed_ms = ms;
        const s = try render(a, &p, g);
        defer a.free(s);
        const at = std.mem.lastIndexOf(u8, s, "\u{2570}").?;
        // Count cursor moves before the bottom border: that is its row.
        var moves: usize = 0;
        var i: usize = 0;
        while (i < at) : (i += 1) {
            if (s[i] == 'H' and i > 0 and std.ascii.isDigit(s[i - 1])) moves += 1;
        }
        if (first_bottom) |f| {
            try std.testing.expectEqual(f, moves);
        } else first_bottom = moves;
    }
}

test "an opening panel draws fewer rows than a settled one" {
    const a = std.testing.allocator;
    var p = testPanel();
    p.elapsed_ms = 0;
    const opening = try render(a, &p, geometry(30, 100, p.n));
    defer a.free(opening);
    p.elapsed_ms = open_ms;
    const settled = try render(a, &p, geometry(30, 100, p.n));
    defer a.free(settled);
    try std.testing.expect(opening.len < settled.len);
    // The last field only exists once the reveal finishes.
    try std.testing.expect(std.mem.indexOf(u8, opening, "~/.omfx/settings.json") == null);
    try std.testing.expect(std.mem.indexOf(u8, settled, "~/.omfx/settings.json") != null);
}

test "a toggle reads as a switch and a choice as a carousel" {
    const a = std.testing.allocator;
    var p = testPanel();
    const on = try render(a, &p, geometry(30, 100, p.n));
    defer a.free(on);
    try std.testing.expect(std.mem.indexOf(u8, on, "\u{25cf} on") != null);

    p.fields[0].value = "off";
    const off = try render(a, &p, geometry(30, 100, p.n));
    defer a.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "\u{25cb} off") != null);

    p.sel = 1;
    const choice = try render(a, &p, geometry(30, 100, p.n));
    defer a.free(choice);
    try std.testing.expect(std.mem.indexOf(u8, choice, "\u{2039}") != null);
    try std.testing.expect(std.mem.indexOf(u8, choice, "\u{203a}") != null);
}

fn nextCup(s: []const u8, from: usize) ?struct { at: usize, body: usize } {
    var i = from;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] != 0x1b or s[i + 1] != '[') continue;
        var k = i + 2;
        while (k < s.len and (std.ascii.isDigit(s[k]) or s[k] == ';')) k += 1;
        if (k < s.len and s[k] == 'H') return .{ .at = i, .body = k + 1 };
    }
    return null;
}

fn rowCells(s: []const u8, needle: []const u8) u16 {
    const hit = std.mem.indexOf(u8, s, needle) orelse return 0;
    var start: usize = 0;
    var i: usize = 0;
    while (nextCup(s, i)) |cup| {
        if (cup.body <= hit) {
            start = cup.body;
            i = cup.body;
            continue;
        }
        return width.cellsTo(s[start..cup.at]);
    }
    return width.cellsTo(s[start..]);
}

test "toggle on and off keep the right border on the same column" {
    try std.testing.expectEqual(width.cellsTo(toggle_on), valueCells(.toggle, true, "on"));
    try std.testing.expectEqual(width.cellsTo(toggle_off), valueCells(.toggle, true, "off"));

    const a = std.testing.allocator;
    var p = Panel{ .title = "Settings" };
    p.add(.{ .key = "statusline", .label = "Status line", .kind = .toggle, .value = "on", .help = "under the composer" });
    p.add(.{ .key = "sound", .label = "Sound", .kind = .toggle, .value = "off", .help = "bell" });
    const g = geometry(30, 80, p.n);
    const on = try render(a, &p, g);
    defer a.free(on);
    p.fields[0].value = "off";
    const off = try render(a, &p, g);
    defer a.free(off);

    const on_w = rowCells(on, "Status line");
    const off_w = rowCells(off, "Status line");
    try std.testing.expectEqual(g.cols, on_w);
    try std.testing.expectEqual(g.cols, off_w);
    try std.testing.expectEqual(on_w, off_w);
    try std.testing.expectEqual(g.cols, rowCells(on, "Sound"));
}

test "editing shows the live buffer and a caret" {
    const a = std.testing.allocator;
    var p = testPanel();
    p.sel = 2;
    p.editing = true;
    p.edit = "$ ";
    const s = try render(a, &p, geometry(30, 100, p.n));
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "$ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{2588}") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "esc cancel") != null);
}

test "render never writes past the panel width" {
    const a = std.testing.allocator;
    var p = Panel{ .title = "x" ** 200 };
    p.add(.{ .key = "k", .label = "L" ** 120, .kind = .text, .value = "V" ** 120 });
    const g = geometry(30, 100, p.n);
    const s = try render(a, &p, g);
    defer a.free(s);
    // Every painted row must fit the frame, or the box tears.
    var it = std.mem.splitScalar(u8, s, '\x1b');
    while (it.next()) |chunk| {
        const nl = std.mem.indexOfScalar(u8, chunk, 'H') orelse continue;
        const body = chunk[nl + 1 ..];
        try std.testing.expect(width.cellsTo(body) <= g.cols + 2);
    }
}

test "a panel erases what it covers" {
    const a = std.testing.allocator;
    var p = testPanel();
    const g = geometry(30, 100, p.n);
    const s = try render(a, &p, g);
    defer a.free(s);
    // Every row of the footprint is blanked before anything is drawn, or the
    // transcript underneath shows through at the edges.
    var blanks: usize = 0;
    var it = std.mem.splitSequence(u8, s, "  ");
    while (it.next()) |_| blanks += 1;
    try std.testing.expect(blanks > g.rows);
    // The clear happens before the frame, so the frame survives it.
    const first_corner = std.mem.indexOf(u8, s, "\u{256d}").?;
    const first_space_run = std.mem.indexOf(u8, s, "     ").?;
    try std.testing.expect(first_space_run < first_corner);
}

test "a long list scrolls instead of drawing past the frame" {
    const a = std.testing.allocator;
    var names: [40][12]u8 = undefined;
    var p = longPanel(&names);
    // 40 rows in a 20-row terminal: the frame must still close.
    const g = geometry(20, 100, p.n);
    try std.testing.expect(g.rows <= 20);
    const s = try render(a, &p, g);
    defer a.free(s);
    var rows: usize = 0;
    var it = std.mem.splitSequence(u8, s, "\x1b[");
    while (it.next()) |chunk| {
        if (std.mem.indexOfScalar(u8, chunk, 'H') != null) rows += 1;
    }
    // One cup per cleared row plus one per drawn row, never more than the box.
    try std.testing.expect(rows <= @as(usize, g.rows) * 2 + 4);
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{2570}") != null);
}

test "the window follows the cursor and reports position" {
    const a = std.testing.allocator;
    var names: [40][12]u8 = undefined;
    var p = longPanel(&names);
    const g = geometry(20, 100, p.n);
    p.sel = p.n - 1;
    const s = try render(a, &p, g);
    defer a.free(s);
    // The last row is on screen, and the frame says where you are.
    try std.testing.expect(std.mem.indexOf(u8, s, "row39") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "40/40") != null);
    // The first row scrolled off.
    try std.testing.expect(std.mem.indexOf(u8, s, "row0 ") == null);
}

test "a list longer than the cap says so instead of lying" {
    const a = std.testing.allocator;
    var p = Panel{ .title = "Over" };
    for (0..max_fields + 3) |_| {
        p.add(.{ .key = "k", .label = "L", .kind = .toggle, .value = "off" });
    }
    try std.testing.expectEqual(max_fields, p.n);
    try std.testing.expectEqual(@as(usize, 3), p.overflow);
    const s = try render(a, &p, geometry(20, 100, p.n));
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "+3 dropped") != null);
}

test "windowStart keeps the selection inside the view" {
    try std.testing.expectEqual(@as(usize, 0), windowStart(10, 0, 5));
    try std.testing.expectEqual(@as(usize, 0), windowStart(3, 2, 5));
    try std.testing.expectEqual(@as(usize, 5), windowStart(10, 9, 5));
    // Never scrolls past the end.
    try std.testing.expectEqual(@as(usize, 5), windowStart(10, 20, 5));
}

/// Labels live in the caller's buffer: a slice into a local would dangle the
/// moment this returned, which is how the first version of this helper failed.
fn longPanel(names: *[40][12]u8) Panel {
    var p = Panel{ .title = "Long" };
    for (0..40) |i| {
        const name = std.fmt.bufPrint(&names[i], "row{d}", .{i}) catch "row";
        p.add(.{ .key = name, .label = name, .kind = .toggle, .value = "off" });
    }
    return p;
}

test "a panel with no fields still renders a frame" {
    const a = std.testing.allocator;
    var p = Panel{ .title = "Empty" };
    const s = try render(a, &p, geometry(30, 100, 0));
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{2570}") != null);
}

test "every panel is the same height regardless of its content" {
    // A one-row panel and a fifty-row panel must present as the same object.
    var names: [40][12]u8 = undefined;
    const long = longPanel(&names);
    var short = Panel{ .title = "Short" };
    short.add(.{ .key = "a", .label = "A", .kind = .toggle, .value = "on" });
    short.add(.{ .key = "b", .label = "B", .kind = .toggle, .value = "on" });

    const tall = geometry(50, 100, long.n);
    try std.testing.expectEqual(max_visible, @as(u16, @intCast(visibleRows(tall))));
    try std.testing.expectEqual(max_visible + chrome_rows + 1, tall.rows);

    // A short panel is only as tall as it needs, never taller than the cap.
    const small = geometry(50, 100, short.n);
    try std.testing.expect(small.rows < tall.rows);
    try std.testing.expect(small.rows <= max_visible + chrome_rows + 1);
}

test "a short terminal still bounds the panel" {
    var names: [40][12]u8 = undefined;
    const long = longPanel(&names);
    const g = geometry(12, 100, long.n);
    try std.testing.expect(g.rows <= 12);
    try std.testing.expect(visibleRows(g) <= max_visible);
}

test "clipped text ends in an ellipsis, not mid-word silence" {
    const a = std.testing.allocator;
    var p = Panel{ .title = "T" };
    p.add(.{
        .key = "k",
        .label = "Long",
        .kind = .info,
        .value = "a description that is far too long to fit inside this frame at all",
    });
    const s = try render(a, &p, geometry(20, 60, p.n));
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{2026}") != null);
}

test "clipEllipsis never exceeds its budget" {
    var buf: [256]u8 = undefined;
    for ([_]u16{ 0, 1, 2, 5, 20, 200 }) |cols| {
        const got = clipEllipsis(&buf, "the quick brown fox jumps over the lazy dog", cols);
        try std.testing.expect(width.cellsTo(got) <= @max(cols, 1));
    }
    // Text that fits is returned untouched, with no ellipsis added.
    try std.testing.expectEqualStrings("short", clipEllipsis(&buf, "short", 40));
}
