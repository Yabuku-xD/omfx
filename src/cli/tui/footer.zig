const std = @import("std");
const Io = std.Io;

const slash = @import("../../core/slash.zig");
const cli = @import("../../core/cli.zig");
const layout_mod = @import("layout.zig");
const scroll_mod = @import("scroll.zig");
const width = @import("../width.zig");
const paint = @import("../../core/ansi.zig");

const box = @import("footer/box.zig");
const menu = @import("footer/menu.zig");
const welcome_mod = @import("footer/welcome.zig");

pub const Layout = layout_mod.Layout;
pub const moveTo = layout_mod.moveTo;

pub const min_menu_cols = menu.min_menu_cols;
pub const min_card_cols = welcome_mod.min_card_cols;
pub const welcome = welcome_mod.welcome;
pub const formatSlashMenu = menu.formatSlashMenu;

const cellsTo = width.cellsTo;
const padCells = box.padCells;
const clipCells = box.clipCells;
const sanitizeRow = box.sanitizeRow;
const ruleLine = box.ruleLine;
const boxEdgeIn = box.boxEdgeIn;
const padPair = box.padPair;
const composerWindow = box.composerWindow;
const widestRow = box.widestRow;

/// Once mouse reporting is on the terminal stops making its own, so omfx has
/// to. It is deliberately not a rectangle over the screen: the welcome card,
/// the header and the hint row are chrome, and dragging across them should
/// select nothing.
pub const Sel = struct {
    pub const Where = enum { none, transcript, composer };

    where: Where = .none,
    /// Transcript row indices, or 0 for the composer, which is one row.
    a_row: usize = 0,
    b_row: usize = 0,
    /// Cell columns within the row, measured past any escape sequences.
    a_col: u16 = 0,
    b_col: u16 = 0,

    pub fn on(self: Sel) bool {
        return self.where != .none and !(self.a_row == self.b_row and self.a_col == self.b_col);
    }

    /// The pair reordered so the first point is the earlier one; a drag
    /// upward or leftward selects the same span as the drag back down.
    pub fn ordered(self: Sel) Sel {
        const flip = self.b_row < self.a_row or (self.b_row == self.a_row and self.b_col < self.a_col);
        if (!flip) return self;
        return .{
            .where = self.where,
            .a_row = self.b_row,
            .a_col = self.b_col,
            .b_row = self.a_row,
            .b_col = self.a_col,
        };
    }

    /// The selected cell range on `row`, or null when the row is outside it.
    pub fn span(self: Sel, row: usize, cells: u16) ?struct { from: u16, to: u16 } {
        const o = self.ordered();
        if (row < o.a_row or row > o.b_row) return null;
        const from: u16 = if (row == o.a_row) o.a_col else 0;
        const to: u16 = if (row == o.b_row) @min(o.b_col, cells) else cells;
        if (from >= to) return null;
        return .{ .from = from, .to = to };
    }
};

/// Idle parks the caret. Generating hides it and owns the hint row.
pub const Turn = union(enum) {
    idle,
    generating,
};

/// Auto follows Turn (Generating vs keys). Text is an armed note.
pub const Hint = union(enum) {
    auto,
    text: []const u8,
};

pub const generating = "Generating";
/// Footer hint while a turn runs. The activity line already names the work.
pub const stop_hint = "esc  stop  \u{b7}  type to queue a message";
pub const queued_hint = "enter queues  \u{b7}  sends at turn end  \u{b7}  esc drops";

pub const Footer = struct {
    model: []const u8,
    permission: []const u8,
    composer: []const u8,
    /// Byte offset into `composer` for the caret. Null means the end.
    caret: ?usize = null,
    /// 1-based CUP column. Non-zero overrides display-width parking.
    park_col: u16 = 0,
    place: []const u8 = cli.bin,
    slash: []const slash.Spec = &.{},
    slash_sel: usize = 0,
    hint: Hint = .auto,
    turn: Turn = .idle,
    /// What the agent is doing, from `activity.zig`. Empty means no words yet;
    /// the pane does not invent "Generating".
    status: []const u8 = "",
    /// Text the pointer has dragged over.
    sel: Sel = .{},
    /// Argument placeholder drawn after the caret, muted. Never part of the
    /// draft: it is a reminder, not text you are about to send.
    ghost: []const u8 = "",
    /// Tokens the window is holding after the last turn, and how many it
    /// takes. Zero window means nothing is drawn.
    context_used: u32 = 0,
    context_window: u32 = 0,
    /// Reasoning level in use, shown next to the model. Empty when the model
    /// takes none, or when it is on the provider default.
    effort: []const u8 = "",
    /// Typed while the turn runs. Drawn in the composer row, muted, because it
    /// is a message already committed to this turn rather than a draft.
    queued: []const u8 = "",
    /// Ephemeral confirmation above the footer. Empty means nothing to draw.
    toast: []const u8 = "",
    /// Floating jump-to-bottom pill above the composer when scrolled up.
    jump: bool = false,
    /// Open todos painted as sticky chrome above the composer (Claude Ctrl+T
    /// pattern). Not part of the scrolling transcript.
    tasks: []const []const u8 = &.{},
    /// Live context breakdown while generating (click the header bar).
    peek: []const []const u8 = &.{},

    fn hintLine(self: Footer, buf: []u8, cols: u16) []const u8 {
        return switch (self.hint) {
            .text => |t| t,
            .auto => switch (self.turn) {
                .generating => if (self.queued.len != 0) queued_hint else stop_hint,
                .idle => hintFor(buf, cols),
            },
        };
    }
};

const composer_hints = [_]scroll_mod.HintItem{
    .{ .keys = "enter", .label = "send", .pinned = true },
    .{ .keys = "shift+tab", .label = "mode" },
    .{ .keys = "ctrl+p", .label = "palette" },
    .{ .keys = "tab", .label = "scrollback" },
    .{ .keys = "?", .label = "keys", .pinned = true },
};

pub fn hintFor(buf: []u8, cols: u16) []const u8 {
    return scroll_mod.renderHints(buf, &composer_hints, cols);
}

/// Workspace on the left, one brand dot to anchor it, how full the context
/// window is on the right. Model and mode live in the footer.
pub fn formatHeader(allocator: std.mem.Allocator, layout: Layout, footer: Footer) ![]u8 {
    if (layout.header_rows == 0) return allocator.dupe(u8, "");
    const inner: u16 = if (layout.cols > 3) layout.cols - 3 else 0;
    var ctx_buf: [160]u8 = undefined;
    const ctx = contextRow(&ctx_buf, footer.context_used, footer.context_window);
    const room: u16 = if (inner > cellsTo(ctx)) inner - cellsTo(ctx) else 0;
    const padded = try padCells(allocator, clipCells(footer.place, room), room);
    defer allocator.free(padded);
    return std.fmt.allocPrint(
        allocator,
        "\x1b[H\x1b[2K {s}\u{25cf} {s}{s}{s}{s}{s}{s}",
        .{ paint.accent_dim, paint.reset, paint.muted, padded, ctx, paint.reset, paint.reset },
    );
}

/// " [████░░░░] 325K / 500K", or "" until the provider has reported a count.
pub fn contextRow(buf: []u8, used: u32, window: u32) []const u8 {
    if (window == 0) return "";
    const tw: u16 = 8;
    const filled: u16 = @intCast(@min(@as(u64, tw), (@as(u64, used) * tw) / window));
    var w: Io.Writer = .fixed(buf);
    w.writeAll(paint.accent_dim) catch return "";
    w.writeAll("[") catch return "";
    var i: u16 = 0;
    while (i < tw) : (i += 1) {
        w.writeAll(if (i < filled) "█" else "░") catch return "";
    }
    w.writeAll("]") catch return "";
    w.writeAll(paint.muted) catch return "";
    w.writeAll(" ") catch return "";
    writeTokens(&w, used) catch return "";
    w.writeAll(" / ") catch return "";
    writeTokens(&w, window) catch return "";
    w.writeAll(paint.reset) catch return "";
    return w.buffered();
}

/// A token count at a glance: "97.0k" rather than "97000".
///
/// One decimal below a million, because the difference between 97k and 98k is
/// not worth reading but the difference between 1.0M and 1.9M is.
pub fn shortTokens(buf: []u8, n: u32) []const u8 {
    var w: Io.Writer = .fixed(buf);
    if (n < 1000) {
        w.print("{d}", .{n}) catch return "";
    } else if (n < 1_000_000) {
        w.print("{d}.{d}k", .{ n / 1000, (n % 1000) / 100 }) catch return "";
    } else {
        w.print("{d}.{d}M", .{ n / 1_000_000, (n % 1_000_000) / 100_000 }) catch return "";
    }
    return w.buffered();
}

fn writeTokens(w: *Io.Writer, n: u32) !void {
    // "0K" rather than "0": both halves carry the same unit, so the pair reads
    // as a fraction from the first frame.
    if (n < 1000) return w.print("{d}K", .{n / 1000});
    if (n < 1_000_000) return w.print("{d}K", .{n / 1000});
    return w.print("{d}.{d}M", .{ n / 1_000_000, (n % 1_000_000) / 100_000 });
}

pub fn formatWelcome(allocator: std.mem.Allocator, layout: Layout, footer: Footer) ![]u8 {
    return welcome_mod.formatWelcome(allocator, layout, footer.model);
}

pub fn formatFooter(allocator: std.mem.Allocator, layout: Layout, footer: Footer) ![]u8 {
    var meta_buf: [160]u8 = undefined;
    // Effort sits with the model because it is a property of the model, and
    // because a level you cannot see is a level you forget you set.
    const meta = if (footer.effort.len != 0)
        try std.fmt.bufPrint(&meta_buf, "{s} ({s}) · {s}", .{ footer.model, footer.effort, footer.permission })
    else
        try std.fmt.bufPrint(&meta_buf, "{s} · {s}", .{ footer.model, footer.permission });
    const boxed = layout.footer_rows >= 4 and layout.cols >= 8;
    const inner: u16 = if (boxed) layout.cols - 2 else layout.cols;
    // The line being typed mid-turn is a draft like any other: it gets the
    // prompt and the ordinary colour. Muting it read as a disabled field, and
    // dropping the prompt made the row look like output rather than input.
    // The messages already committed with Enter are the muted ones, and they
    // are drawn as their own numbered rows above the status line.
    const body = if (footer.queued.len != 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ footer.composer, footer.queued })
    else if (footer.ghost.len != 0)
        try std.fmt.allocPrint(allocator, "{s} {s}{s}{s}", .{ footer.composer, paint.muted, footer.ghost, paint.reset })
    else
        try allocator.dupe(u8, footer.composer);
    defer allocator.free(body);
    const caret = if (footer.queued.len != 0) body.len else footer.caret orelse footer.composer.len;
    const win = composerWindow(body, caret, inner);
    const shown_raw = try sanitizeRow(allocator, win.slice);
    defer allocator.free(shown_raw);
    const left = try padCells(allocator, shown_raw, inner);
    defer allocator.free(left);

    const park_inner: u16 = if (footer.park_col == 0) win.park else footer.park_col;
    const park_col: u16 = if (boxed)
        @min(layout.cols, park_inner + 1)
    else
        @min(layout.cols, park_inner);
    const park_use: u16 = if (park_col == 0) 1 else park_col;
    const comp_row: u16 = if (layout.footer_rows >= 2)
        @min(layout.rows, layout.footer_start_row + 1)
    else
        layout.footer_start_row;
    var park_buf: [32]u8 = undefined;
    const park = try moveTo(&park_buf, comp_row, park_use);
    var hint_buf: [256]u8 = undefined;
    const hints = footer.hintLine(&hint_buf, layout.cols);

    if (boxed) {
        // The composer is where you type, in both states: it keeps the accent
        // so the eye can find it without hunting, rather than going grey the
        // moment a turn ends and blending into the transcript above it.
        const edge: []const u8 = paint.accent_dim;
        const top = try boxEdgeIn(allocator, layout.cols, "╭", "╮", edge);
        defer allocator.free(top);
        const bot = try boxEdgeIn(allocator, layout.cols, "╰", "╯", edge);
        defer allocator.free(bot);
        const mid = try std.fmt.allocPrint(
            allocator,
            "{s}│{s}{s}{s}│{s}",
            .{ edge, paint.reset, left, edge, paint.reset },
        );
        defer allocator.free(mid);
        const painted_hints = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ paint.muted, hints, paint.reset });
        defer allocator.free(painted_hints);
        const painted_meta = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ paint.label, meta, paint.reset });
        defer allocator.free(painted_meta);
        const hint_row = try padPair(allocator, painted_hints, painted_meta, layout.cols);
        defer allocator.free(hint_row);
        return std.fmt.allocPrint(
            allocator,
            "\x1b[2K{s}\n\x1b[2K{s}\n\x1b[2K{s}\n\x1b[2K{s}{s}",
            .{ top, mid, bot, hint_row, park },
        );
    }

    const composer = try padCells(allocator, shown_raw, layout.cols);
    defer allocator.free(composer);
    if (layout.footer_rows >= 3) {
        const rule = try ruleLine(allocator, layout.cols);
        defer allocator.free(rule);
        return std.fmt.allocPrint(
            allocator,
            "\x1b[2K{s}{s}{s}\n\x1b[2K{s}\n\x1b[2K{s}{s}{s}{s}",
            .{ paint.border, rule, paint.reset, composer, paint.muted, hints, paint.reset, park },
        );
    }
    if (layout.footer_rows == 2) {
        return std.fmt.allocPrint(
            allocator,
            "\x1b[2K{s}\n\x1b[2K{s}{s}{s}{s}",
            .{ composer, paint.muted, hints, paint.reset, park },
        );
    }
    return std.fmt.allocPrint(allocator, "\x1b[2K{s}{s}", .{ composer, park });
}

test "footer composer shows image and url placeholders" {
    const layout = Layout.compute(24, 80);
    const s = try formatFooter(std.testing.allocator, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "> [Image 1] [Image 2] [URL 1]",
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "[Image 1] [Image 2] [URL 1]") != null);
}

test "formatFooter shows typed composer text" {
    const layout = Layout.compute(24, 80);
    const s = try formatFooter(std.testing.allocator, layout, .{
        .model = "x",
        .permission = "normal",
        .composer = "> hello world",
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "hello world") != null);
}

test "footer parks cursor on composer after status" {
    const layout = Layout.compute(24, 80);
    const s = try formatFooter(std.testing.allocator, layout, .{
        .model = "grok-4.6",
        .permission = "ask",
        .composer = "> ",
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "enter send") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[22;4H") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "grok-4.6") != null);
}

test "header is a quiet place line" {
    const layout = Layout.compute(24, 80);
    const s = try formatHeader(std.testing.allocator, layout, .{
        .model = "grok-4.6",
        .permission = "ask",
        .composer = "> ",
        .place = "omfx",
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "omfx") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.accent_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[7m") == null);
}

test "the ghost is drawn muted and is not part of the draft" {
    const a = std.testing.allocator;
    const layout = Layout.compute(24, 60);
    const s = try formatFooter(a, layout, .{
        .model = "x",
        .permission = "yolo",
        .composer = "> /effort",
        .ghost = "[level]",
    });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "[level]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.muted) != null);
}

test "a queued message takes the composer row and renames the hint" {
    const a = std.testing.allocator;
    const layout = Layout.compute(24, 60);
    const s = try formatFooter(a, layout, .{
        .model = "x",
        .permission = "yolo",
        .composer = "> ",
        .turn = .generating,
        .queued = "also fix the test",
    });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "also fix the test") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, queued_hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, stop_hint) == null);
}

test "nothing queued leaves the composer and the stop hint alone" {
    const a = std.testing.allocator;
    const layout = Layout.compute(24, 60);
    const s = try formatFooter(a, layout, .{
        .model = "x",
        .permission = "yolo",
        .composer = "> draft",
        .turn = .generating,
    });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "> draft") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, stop_hint) != null);
}

test "composer window keeps caret on screen" {
    const layout = Layout.compute(24, 8);
    var buf: [32]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast('a' + (i % 26));
    const s = try formatFooter(std.testing.allocator, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = &buf,
        .caret = buf.len,
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[22;") != null);
}

test "the hint bar drops unpinned hints before it clips" {
    var buf: [256]u8 = undefined;
    const wide = hintFor(&buf, 120);
    try std.testing.expect(std.mem.indexOf(u8, wide, "enter send") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "shift+tab mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "tab scrollback") != null);

    // Narrow keeps what you cannot work without and drops the rest.
    var buf2: [256]u8 = undefined;
    const narrow = hintFor(&buf2, 24);
    try std.testing.expect(cellsTo(narrow) <= 24);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "enter send") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "? keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "palette") == null);

    var buf3: [256]u8 = undefined;
    try std.testing.expect(cellsTo(hintFor(&buf3, 5)) <= 5);
}

test "formatFooter offers the stop key while a turn runs" {
    const layout = Layout.compute(24, 80);
    const s = try formatFooter(std.testing.allocator, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "",
        .turn = .generating,
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, stop_hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, generating) == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "enter send") == null);
}

test "formatFooter Hint text wins over Turn" {
    const layout = Layout.compute(24, 80);
    const s = try formatFooter(std.testing.allocator, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "",
        .hint = .{ .text = "armed quit" },
        .turn = .generating,
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "armed quit") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, stop_hint) == null);
}

test "the composer keeps the accent in both states" {
    const a = std.testing.allocator;
    const layout = Layout.compute(24, 70);
    const idle = try formatFooter(a, layout, .{ .model = "x", .permission = "yolo", .composer = "> " });
    defer a.free(idle);
    const busy = try formatFooter(a, layout, .{ .model = "x", .permission = "yolo", .composer = "> ", .turn = .generating });
    defer a.free(busy);
    // The box is where you type whether or not a turn is running, so it does
    // not go grey and blend into the transcript when one ends.
    try std.testing.expect(std.mem.indexOf(u8, idle, paint.accent_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, busy, paint.accent_dim) != null);
}

test "the reasoning level rides with the model name" {
    const a = std.testing.allocator;
    const layout = Layout.compute(24, 70);
    const with = try formatFooter(a, layout, .{
        .model = "grok-4.5",
        .permission = "yolo",
        .composer = "> ",
        .effort = "auto",
    });
    defer a.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "grok-4.5 (auto) \u{b7} yolo") != null);

    // A model with no levels says nothing rather than "()".
    const without = try formatFooter(a, layout, .{
        .model = "grok-4.5",
        .permission = "yolo",
        .composer = "> ",
    });
    defer a.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "grok-4.5 \u{b7} yolo") != null);
    try std.testing.expect(std.mem.indexOf(u8, without, "()") == null);
}

test "the header carries the window, and only once there is a count" {
    const a = std.testing.allocator;
    const layout = Layout.compute(24, 80);
    const row = try formatHeader(a, layout, .{
        .model = "x",
        .permission = "yolo",
        .composer = "> ",
        .place = "/tmp/ws",
        .context_used = 325_000,
        .context_window = 500_000,
    });
    defer a.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "325K / 500K") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "/tmp/ws") != null);

    // No window known yet: the row is the workspace alone, not "0 / 0".
    const bare = try formatHeader(a, layout, .{ .model = "x", .permission = "yolo", .composer = "> ", .place = "/tmp/ws" });
    defer a.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "/") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, " / ") == null);
}

test "token counts read at a glance at every size" {
    var buf: [160]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, contextRow(&buf, 940, 8_000), "0K / 8K") != null);
    try std.testing.expect(std.mem.indexOf(u8, contextRow(&buf, 0, 500_000), "0K / 500K") != null);
    const mid = contextRow(&buf, 325_000, 500_000);
    try std.testing.expect(std.mem.indexOf(u8, mid, "325K / 500K") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "█") != null);
    try std.testing.expect(std.mem.indexOf(u8, contextRow(&buf, 199_000, 1_000_000), "199K / 1.0M") != null);
    try std.testing.expectEqualStrings("", contextRow(&buf, 100, 0));
}

test "CJK caret uses two cells" {
    try std.testing.expectEqual(@as(u16, 2), cellsTo("あ"));
    try std.testing.expectEqual(@as(u16, 1), cellsTo("a"));
    const layout = Layout.compute(24, 80);
    const s = try formatFooter(std.testing.allocator, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "> あ",
        .caret = 5,
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[22;6H") != null);
}

test "the last transcript row is not the footer row" {
    const l = Layout.compute(30, 100);
    try std.testing.expectEqual(@as(u16, 2), l.transcript_start_row);
    try std.testing.expectEqual(@as(u16, 26), l.regionBottom());
    try std.testing.expectEqual(@as(u16, 27), l.footer_start_row);
    // A notice painted on the last transcript row must survive the footer paint.
    try std.testing.expect(l.regionBottom() < l.footer_start_row);
}

test "chrome fits every terminal size it can be given" {
    const a = std.testing.allocator;
    // Sizes that have historically broken layout: one column, one row, the
    // 80x24 default, a phone-sized split, and an ultrawide.
    const sizes = [_][2]u16{
        .{ 1, 1 },   .{ 2, 3 },   .{ 5, 10 },  .{ 24, 80 },
        .{ 10, 20 }, .{ 3, 200 }, .{ 60, 40 }, .{ 100, 300 },
        .{ 24, 39 }, .{ 24, 40 }, .{ 25, 81 }, .{ 8, 8 },
    };
    for (sizes) |sz| {
        const rows = sz[0];
        const cols = sz[1];
        const layout = Layout.compute(rows, cols);

        const head = try formatHeader(a, layout, .{ .model = "a-long-model-name", .permission = "normal", .composer = "> ", .place = "/a/very/long/workspace/path/that/keeps/going" });
        defer a.free(head);
        try std.testing.expect(widestRow(head) <= cols);

        const foot = try formatFooter(a, layout, .{
            .model = "a-long-model-name",
            .permission = "normal",
            .composer = "> some text being typed right now",
            .place = "/a/very/long/workspace/path",
        });
        defer a.free(foot);
        try std.testing.expect(widestRow(foot) <= cols);

        const card = try formatWelcome(a, layout, .{ .model = "a-long-model-name", .permission = "normal", .composer = "> " });
        defer a.free(card);
        try std.testing.expect(widestRow(card) <= cols);
    }
}
