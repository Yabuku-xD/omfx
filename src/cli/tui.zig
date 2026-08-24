const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const tty = @import("tty.zig");
const slash = @import("../core/slash.zig");
const cli = @import("../core/cli.zig");
const activity = @import("activity.zig");

pub const enter_alt = tty.enter_seq;
pub const leave_alt = tty.restore_seq;
pub const bel = "\x07";
pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";

/// Paste into the composer is a prompt, not a file. Named so a hit is fixable.
pub const max_paste: usize = 256 * 1024;

const log = std.log.scoped(.tui);

pub const Size = struct { rows: u16, cols: u16 };

fn winsizeOn(fd: std.posix.fd_t) ?Size {
    var wsz: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const req: u32 = @truncate(std.posix.T.IOCGWINSZ);
    const rc = std.c.ioctl(fd, @bitCast(req), &wsz);
    if (rc < 0 or wsz.row == 0 or wsz.col == 0) return null;
    return .{ .rows = wsz.row, .cols = wsz.col };
}

pub fn size(fallback_rows: u16, fallback_cols: u16) Size {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .rows = fallback_rows, .cols = fallback_cols };
    }
    if (winsizeOn(std.posix.STDOUT_FILENO)) |s| return s;
    if (winsizeOn(std.posix.STDIN_FILENO)) |s| return s;
    return .{ .rows = fallback_rows, .cols = fallback_cols };
}

pub const Layout = struct {
    rows: u16,
    cols: u16,
    header_rows: u16,
    footer_rows: u16,
    transcript_rows: u16,
    transcript_start_row: u16,
    footer_start_row: u16,

    pub fn compute(rows: u16, cols: u16) Layout {
        const header_rows: u16 = if (rows >= 6) 1 else 0;
        const footer_rows: u16 = if (rows >= 8) 4 else if (rows >= 5) 3 else if (rows >= 3) 2 else 1;
        const used = header_rows + footer_rows;
        const transcript_rows = if (rows > used) rows - used else 0;
        const transcript_start_row: u16 = header_rows + 1;
        const footer_start_row = if (transcript_rows == 0)
            transcript_start_row
        else
            transcript_start_row + transcript_rows;
        return .{
            .rows = rows,
            .cols = if (cols == 0) 1 else cols,
            .header_rows = header_rows,
            .footer_rows = footer_rows,
            .transcript_rows = transcript_rows,
            .transcript_start_row = transcript_start_row,
            .footer_start_row = footer_start_row,
        };
    }

    pub fn regionTop(self: Layout) u16 {
        return self.transcript_start_row;
    }

    pub fn regionBottom(self: Layout) u16 {
        if (self.transcript_rows == 0) return self.transcript_start_row;
        return self.transcript_start_row + self.transcript_rows - 1;
    }

    /// Last scroll row when an overlay of `overlay_h` rows sits above the footer.
    /// Overlay rows are not in the scroll region, so command output cannot push them up.
    pub fn scrollBottom(self: Layout, overlay_h: u16) u16 {
        const full = self.regionBottom();
        if (overlay_h == 0) return full;
        const cut = self.footer_start_row -| overlay_h;
        if (cut <= self.transcript_start_row) return self.transcript_start_row;
        return cut - 1;
    }
};

/// Sticky chrome cups. Recomputed after every resize so menus stay on the transcript.
pub const Cups = struct {
    transcript: [32]u8 = undefined,
    transcript_len: usize = 0,
    footer: [32]u8 = undefined,
    footer_len: usize = 0,

    pub fn compute(layout: Layout) Cups {
        var c = Cups{};
        const t = moveTo(&c.transcript, layout.regionBottom(), 1) catch return c;
        c.transcript_len = t.len;
        const f = moveTo(&c.footer, layout.footer_start_row, 1) catch return c;
        c.footer_len = f.len;
        return c;
    }

    pub fn toTranscript(self: *const Cups) []const u8 {
        return self.transcript[0..self.transcript_len];
    }

    pub fn toFooter(self: *const Cups) []const u8 {
        return self.footer[0..self.footer_len];
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

pub const PaintError = error{ OutOfMemory, WriteFailed, NoSpaceLeft };

const Overlay = union(enum) {
    none,
    menu: u16,
};

fn overlayFor(layout: Layout, n: usize) Overlay {
    const h = palettePaintRows(layout, n);
    if (h == 0) return .none;
    return .{ .menu = h };
}


pub const width = @import("width.zig");

/// Re-exported so paint and input code reads the same as before the split.
pub const cellsTo = width.cellsTo;
const runeWidth = width.runeWidth;
const utf8LenAt = width.utf8LenAt;
const runeAt = width.runeAt;
const skipEsc = width.skipEsc;
const indexAtCell = width.indexAtCell;
const utf8Prev = width.utf8Prev;
const utf8Next = width.utf8Next;
const wordByte = width.wordByte;

pub const Transcript = @import("transcript.zig").Transcript;
pub const paint = @import("../core/ansi.zig");

pub const think_head = paint.think_open;
pub const think_tail = paint.think_close;

/// ConEmu/Ghostty tab progress. 3 = indeterminate (the tab spinner); 0 = off.
pub const tab_busy = "\x1b]9;4;3\x07";
pub const tab_idle = "\x1b]9;4;0\x07";
pub const tab_title_idle = "\x1b]0;omfx\x07";

pub fn tabTitleSeq(buf: []u8, frame: usize, phrase: []const u8) []const u8 {
    const clip = phrase[0..@min(phrase.len, 48)];
    if (clip.len == 0) {
        return std.fmt.bufPrint(buf, "\x1b]0;{s} omfx\x07", .{activity.glyph(frame)}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "\x1b]0;{s} {s} - omfx\x07", .{ activity.glyph(frame), clip }) catch buf[0..0];
}

/// Idle tab: what this window is, not what it is doing. A row of terminal tabs
/// all reading "omfx" tells you nothing; the workspace says which checkout and
/// the model says which agent is answering in it.
pub fn idleTitleSeq(buf: []u8, place: []const u8, model: []const u8) []const u8 {
    const name = std.fs.path.basename(place);
    if (name.len == 0) return tab_title_idle;
    const short = name[0..@min(name.len, 32)];
    if (model.len == 0) {
        return std.fmt.bufPrint(buf, "\x1b]0;{s} - omfx\x07", .{short}) catch tab_title_idle;
    }
    const m = model[0..@min(model.len, 32)];
    return std.fmt.bufPrint(buf, "\x1b]0;{s} \u{00b7} {s}\x07", .{ short, m }) catch tab_title_idle;
}

pub fn writeTabTitle(w: *Io.Writer, frame: usize, phrase: []const u8) void {
    var buf: [96]u8 = undefined;
    w.writeAll(tabTitleSeq(&buf, frame, phrase)) catch return;
}

/// Hidden cannot be open. Idle/open only exist when the user asked to see thinking.
pub const ThinkView = union(enum) {
    hidden,
    idle,
    open,

    pub fn init(visible: bool) ThinkView {
        return if (visible) .idle else .hidden;
    }

    pub fn shows(self: ThinkView) bool {
        return self != .hidden;
    }

    pub fn push(self: *ThinkView, chunk: []const u8) ?ThinkFrame {
        if (chunk.len == 0) return null;
        return switch (self.*) {
            .hidden => null,
            .idle => blk: {
                self.* = .open;
                break :blk .{ .prefix = think_head, .body = chunk };
            },
            .open => .{ .body = chunk },
        };
    }

    pub fn end(self: *ThinkView) []const u8 {
        return switch (self.*) {
            .open => blk: {
                self.* = .idle;
                break :blk think_tail;
            },
            .hidden, .idle => "",
        };
    }
};

pub const ThinkFrame = struct {
    prefix: []const u8 = "",
    body: []const u8,
};

pub fn setScrollRegion(buf: []u8, top: u16, bottom: u16) ![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}r", .{ top, bottom });
}

pub fn moveTo(buf: []u8, row: u16, col: u16) ![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col });
}

/// One binding and what it does. `pinned` survives a narrow terminal; the rest
/// are dropped, last first, until the row fits.
///
/// The bar used to be three hand-written strings per context, which meant every
/// new binding had to be spliced into each of them at the right width. Building
/// it from the list a context actually offers is how grok-build does it, and it
/// is the only way the bar cannot drift from the keys that work.
pub const HintItem = struct {
    keys: []const u8,
    label: []const u8,
    pinned: bool = false,
};

pub const hint_sep = "  \u{b7}  ";
const hint_sep_cells: u16 = 5;
pub const max_hints: usize = 8;

const composer_hints = [_]HintItem{
    .{ .keys = "enter", .label = "send", .pinned = true },
    .{ .keys = "shift+tab", .label = "mode" },
    .{ .keys = "ctrl+p", .label = "palette" },
    .{ .keys = "tab", .label = "scrollback" },
    .{ .keys = "?", .label = "keys", .pinned = true },
};

const scrollback_hints = [_]HintItem{
    .{ .keys = "j/k", .label = "move", .pinned = true },
    .{ .keys = "e", .label = "expand", .pinned = true },
    .{ .keys = "E", .label = "all" },
    .{ .keys = "y", .label = "copy" },
    .{ .keys = "esc", .label = "back", .pinned = true },
};

fn hintCells(item: HintItem) u16 {
    return cellsTo(item.keys) + 1 + cellsTo(item.label);
}

fn hintWidth(items: []const HintItem, keep: *const [max_hints]bool) u16 {
    var total: u16 = 0;
    var shown: usize = 0;
    for (items, 0..) |item, i| {
        if (!keep[i]) continue;
        total +|= hintCells(item) + (if (shown == 0) @as(u16, 0) else hint_sep_cells);
        shown += 1;
    }
    return total;
}

fn lastKept(keep: *const [max_hints]bool) ?usize {
    var found: ?usize = null;
    for (keep, 0..) |on, i| {
        if (on) found = i;
    }
    return found;
}

/// As many hints as fit, in their own order, pinned ones dropped last.
pub fn renderHints(buf: []u8, all: []const HintItem, cols: u16) []const u8 {
    // Clamped, not asserted: a release build with one hint too many would write
    // past `keep`, and a dropped hint is not worth that.
    const items = all[0..@min(all.len, max_hints)];
    var keep: [max_hints]bool = @splat(false);
    var used: u16 = 0;
    var shown: usize = 0;
    for (items, 0..) |item, i| {
        if (!item.pinned) continue;
        keep[i] = true;
        used += hintCells(item) + (if (shown == 0) @as(u16, 0) else hint_sep_cells);
        shown += 1;
    }
    for (items, 0..) |item, i| {
        if (item.pinned) continue;
        const want = hintCells(item) + (if (shown == 0) @as(u16, 0) else hint_sep_cells);
        if (used + want > cols) continue;
        keep[i] = true;
        used += want;
        shown += 1;
    }
    // Even the pinned hints can overrun a narrow pane. They give way from the
    // front, because the last one is the way back out and half a hint is worse
    // than one fewer.
    while (hintWidth(items, &keep) > cols) {
        const last = lastKept(&keep) orelse break;
        var dropped = false;
        for (keep[0..items.len], 0..) |on, i| {
            if (!on or i == last) continue;
            keep[i] = false;
            dropped = true;
            break;
        }
        if (!dropped) break;
    }

    var n: usize = 0;
    var first = true;
    for (items, 0..) |item, i| {
        if (!keep[i]) continue;
        if (!first) {
            if (n + hint_sep.len > buf.len) break;
            @memcpy(buf[n..][0..hint_sep.len], hint_sep);
            n += hint_sep.len;
        }
        first = false;
        const one = std.fmt.bufPrint(buf[n..], "{s} {s}", .{ item.keys, item.label }) catch break;
        n += one.len;
    }
    return clipCells(buf[0..n], cols);
}

pub const pick_cap: usize = 128;

/// Skills a palette can offer at once.
///
/// Receipt: the machine this was written on has 181 skills in one directory
/// and 167 in another. At the old cap of 128 the list silently stopped part
/// way through the alphabet, which reads as "omfx cannot see my skills".
pub const max_skill_hits: usize = 512;
pub const max_slash_hits: usize = slash.builtin.len + max_skill_hits;
pub const slash_view_rows: usize = 8;

/// Visible item rows for any list. Same height for `/`, `/models`, keys, @files.
/// Rows the picker shows before it starts scrolling. Five fits a filtered
/// list without pushing the composer down the screen.
pub const palette_max_items: u16 = 5;

/// The picker's height in rows, for `n` matches.
///
/// It shrinks to the matches: a box that keeps five rows of nothing after a
/// filter cuts the list to two reads as an empty pane rather than a short
/// answer. It never grows past `palette_max_items`, so the list scrolls
/// instead of eating the transcript.
pub fn paletteItemRows(layout: Layout, n: usize) u16 {
    const room = layout.transcript_rows;
    if (room <= 2) return 1;
    const cap: u16 = @min(palette_max_items, room - 2);
    if (cap == 0) return 1;
    if (n == 0) return 1;
    return @min(cap, @as(u16, @intCast(@min(n, @as(usize, cap)))));
}

/// Every binding in one table, with the section it belongs to and the long
/// form for its own page. Both the inline `?` list and the cheatsheet panel
/// read this, so a binding cannot exist in one and be missing from the other.
pub const KeyRow = struct {
    name: []const u8,
    help: []const u8,
    section: []const u8,
    detail: []const u8 = "",
};

pub const key_rows = [_]KeyRow{
    .{
        .name = "enter",
        .help = "send; newline when multiline is on",
        .section = "Sending",
        .detail = "Sends what is in the composer. With multiline on it inserts a newline instead, and shift-enter sends.",
    },
    .{ .name = "shift-enter", .help = "newline; send when multiline is on", .section = "Sending" },
    .{ .name = "alt-enter", .help = "newline; send when multiline is on", .section = "Sending" },
    .{
        .name = "shift-tab",
        .help = "cycle normal / plan / yolo",
        .section = "Sending",
        .detail = "Cycles the permission surface: normal asks before a sensitive tool, plan refuses to write at all, yolo stops asking.",
    },
    .{ .name = "ctrl-m", .help = "toggle multiline", .section = "Sending" },
    .{ .name = "ctrl-enter", .help = "newline, or send now while a turn runs", .section = "Sending" },
    .{ .name = "\\ enter", .help = "newline without sending", .section = "Sending" },
    .{ .name = "ctrl-a e", .help = "line start / end", .section = "Editing" },
    .{ .name = "ctrl-k u w", .help = "kill to end / start / word", .section = "Editing" },
    .{ .name = "ctrl-y", .help = "yank last kill", .section = "Editing" },
    .{ .name = "ctrl-z", .help = "undo last edit; ctrl-shift-z redo", .section = "Editing" },
    .{ .name = "alt-b f", .help = "word left / right", .section = "Editing" },
    .{ .name = "ctrl-b", .help = "caret left", .section = "Editing" },
    .{ .name = "ctrl-r", .help = "redo last edit", .section = "Editing" },
    .{
        .name = "ctrl-g",
        .help = "edit the prompt in $EDITOR",
        .section = "Editing",
        .detail = "Opens the draft in $EDITOR. What you save comes back into the composer; quitting without saving leaves it as it was.",
    },
    .{ .name = "tab", .help = "complete the highlighted list row", .section = "Navigation" },
    .{ .name = "up down", .help = "history on an empty prompt, else move the list", .section = "Navigation" },
    .{ .name = "page-up down", .help = "page the list or the transcript", .section = "Navigation" },
    .{ .name = "home end", .help = "line start / end; first / last in a list", .section = "Navigation" },
    .{
        .name = "tab (empty)",
        .help = "keyboard into the scrollback",
        .section = "Scrollback",
        .detail = "Moves the keyboard out of the composer and into the transcript, where the tool runs can be opened from the keyboard. Esc brings it back, and so does typing anything that is not a scrollback key.",
    },
    .{ .name = "j k", .help = "scrollback: move between tool runs", .section = "Scrollback" },
    .{ .name = "e enter", .help = "scrollback: open / close the run", .section = "Scrollback" },
    .{ .name = "h l", .help = "scrollback: close / open the run", .section = "Scrollback" },
    .{ .name = "E", .help = "scrollback: open or close every run", .section = "Scrollback" },
    .{ .name = "g G", .help = "scrollback: first / last run", .section = "Scrollback" },
    .{
        .name = "drag",
        .help = "select text; letting go copies it",
        .section = "Scrollback",
        .detail = "Once omfx asks the terminal to report the mouse, the terminal stops making its own selection -- so omfx makes one. Drag over the transcript or the composer and let go: the text is on the clipboard, without the escape sequences that painted it.\n\nA drag stays in the region it started in. Half a selection in the transcript and half in the footer is not something you can copy.",
    },
    .{
        .name = "click",
        .help = "open a tool run, or one of its calls; click again to close",
        .section = "Scrollback",
        .detail = "Clicking a run's summary opens it and clicking it again closes it; clicking one of its calls opens that call's output, and clicking the same call again puts it back. Every gesture is its own undo, and the keyboard follows the pointer so the two never disagree about which run is current.\n\nA press that never moved is a click; a press that moved is a selection. Deciding on release rather than on press is what lets one gesture be both.",
    },
    .{ .name = "shift-left right", .help = "scrollback: previous / next run", .section = "Scrollback" },
    .{ .name = "ctrl-j k", .help = "scrollback: scroll a line without moving the selection", .section = "Scrollback" },
    .{ .name = "ctrl-u d", .help = "scrollback: scroll half a page", .section = "Scrollback" },
    .{ .name = "space", .help = "scrollback: hand the keyboard back to the composer", .section = "Scrollback" },
    .{ .name = "Y", .help = "scrollback: copy the selected call's output", .section = "Scrollback" },
    .{
        .name = "y",
        .help = "scrollback: copy the run's commands",
        .section = "Scrollback",
        .detail = "Copies the selected run's commands, one per line, through the system clipboard tool. Nothing is copied when the host has none.",
    },
    .{ .name = "ctrl-p", .help = "command palette", .section = "Session" },
    .{ .name = "ctrl-n", .help = "new session (press twice)", .section = "Session" },
    .{ .name = "ctrl-q", .help = "quit (press twice); ctrl-d empty also", .section = "Session" },
    .{ .name = "ctrl-c", .help = "quit", .section = "Session" },
    .{
        .name = "esc esc",
        .help = "clear draft, or rewind if empty",
        .section = "Session",
        .detail = "Once clears the draft. Twice on an empty composer rewinds the last turn, which is how you undo a tool call you did not want.",
    },
    .{
        .name = "ctrl-o",
        .help = "toggle yolo",
        .section = "Session",
        .detail = "Yolo stops the permission prompts for this session only. It is never written to disk, so a new session starts asking again.",
    },
    .{ .name = "ctrl-s", .help = "session picker", .section = "Session" },
    .{
        .name = "ctrl-t",
        .help = "cycle reasoning level, auto included",
        .section = "Session",
        .detail = "Steps through the levels the model in use declares, plus auto, wrapping round. The level is shown next to the model name in the footer.\n\nThe list is per model, not a fixed one: xhigh and max exist on some models and not on others, and a level the model does not take is refused by the provider.\n\nauto reads the prompt and picks a level per turn. It is not a difficulty dial: a short mechanical ask and a turn that has already failed twice both get the floor, and the budget goes to the multi-step asks in between, which is where the research says the gains actually are. /thinking toggles whether reasoning text is shown, which is a different thing.",
    },
    .{ .name = "ctrl-l", .help = "mcp picker", .section = "Session" },
    .{ .name = "ctrl-x .", .help = "this cheatsheet; /shortcuts too", .section = "Session" },
    .{ .name = "!", .help = "run a shell command straight from the composer", .section = "Sending" },
    .{ .name = "f2", .help = "settings; ctrl-, too", .section = "Session" },
    .{ .name = "/help", .help = "all commands", .section = "Session" },
};

/// The same rows as the inline `?` list wants them.
pub const keys_sheet = blk: {
    var out: [key_rows.len]slash.Spec = undefined;
    for (key_rows, 0..) |row, i| out[i] = .{ .name = row.name, .help = row.help };
    break :blk out;
};

fn permChoice(sel: usize) Perm {
    return switch (sel) {
        0 => .allow,
        1 => .always,
        else => .deny,
    };
}

/// Blocking permission prompt, painted over the transcript as the same box the
/// slash palette uses. Arrow keys or 1/2/3 pick; Esc denies without quitting,
/// ctrl-c quits the turn.
pub fn askPerm(
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    layout: *Layout,
    model: []const u8,
    name: []const u8,
    detail: []const u8,
) Perm {
    var sel: usize = 0;
    var head_buf: [220]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "{s} wants to run {s} {s}", .{ model, name, detail }) catch name;
    while (true) {
        const menu = formatSlashMenu(allocator, layout.cols, &perm_sheet, sel, perm_sheet.len) catch return .deny;
        defer allocator.free(menu);
        const start_row = layout.footer_start_row -| @as(u16, perm_sheet.len + 3);
        eraseRows(stdout, start_row, perm_sheet.len + 3) catch return .deny;
        var cup: [32]u8 = undefined;
        stdout.writeAll(moveTo(&cup, start_row, 1) catch return .deny) catch return .deny;
        stdout.writeAll(paint.warn) catch return .deny;
        stdout.writeAll(clipCells(head, layout.cols)) catch return .deny;
        stdout.writeAll(paint.reset) catch return .deny;
        writeLinesAt(stdout, start_row + 1, menu) catch return .deny;
        stdout.flush() catch return .deny;

        switch (nextEvent(stdin)) {
            .enter => return permChoice(sel),
            .history_prev, .up => sel = if (sel == 0) perm_sheet.len - 1 else sel - 1,
            .history_next, .down => sel = (sel + 1) % perm_sheet.len,
            .byte => |b| switch (b) {
                '1' => return .allow,
                '2' => return .always,
                '3' => return .deny,
                else => {},
            },
            // Esc declines this one call; ctrl-c abandons the whole turn.
            .esc => return .deny,
            .interrupt, .quit, .ctrl_d, .eof => return .quit,
            else => {},
        }
    }
}

pub const perm_sheet = [_]slash.Spec{
    .{ .name = "1", .help = "allow once" },
    .{ .name = "2", .help = "always for this kind" },
    .{ .name = "3", .help = "deny" },
};

pub const PickKind = enum { none, providers, models, efforts, sessions, skills, mcp, login, web, commands };

/// The most of `s` that fits in `cap` bytes without splitting a rune. A cut
/// mid-sequence renders as a replacement glyph, which reads as corruption.
fn fitRunes(s: []const u8, cap: usize) usize {
    if (s.len <= cap) return s.len;
    var n = cap;
    while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1;
    return n;
}

/// Catalog overlay. Same box as `/` and `?`. Names/help copied into `names`/`helps`.
pub const Pick = struct {
    kind: PickKind = .none,
    rows: [pick_cap]slash.Spec = undefined,
    n: usize = 0,
    names: [pick_cap][72]u8 = undefined,
    helps: [pick_cap][72]u8 = undefined,

    pub fn clear(self: *Pick) void {
        self.kind = .none;
        self.n = 0;
    }

    pub fn open(self: *Pick, kind: PickKind) void {
        self.kind = kind;
        self.n = 0;
    }

    pub fn push(self: *Pick, name: []const u8, help: []const u8) void {
        self.pushRow(name, help, false);
    }

    /// A row read right to left: the description leads and the id follows.
    pub fn pushFlipped(self: *Pick, name: []const u8, help: []const u8) void {
        self.pushRow(name, help, true);
    }

    fn pushRow(self: *Pick, name: []const u8, help: []const u8, flip: bool) void {
        if (self.n >= pick_cap) return;
        const i = self.n;
        const nlen = fitRunes(name, self.names[i].len);
        @memcpy(self.names[i][0..nlen], name[0..nlen]);
        const hlen = fitRunes(help, self.helps[i].len);
        @memcpy(self.helps[i][0..hlen], help[0..hlen]);
        self.rows[i] = .{ .name = self.names[i][0..nlen], .help = self.helps[i][0..hlen], .flip = flip };
        self.n += 1;
    }

    pub fn match(self: *const Pick, query: []const u8, out: []slash.Spec) usize {
        const q = std.mem.trim(u8, query, " \t");
        var k: usize = 0;
        for (self.rows[0..self.n]) |spec| {
            if (q.len != 0 and !slashMatches(q, spec.name) and !slashMatches(q, spec.help)) continue;
            if (k == out.len) break;
            out[k] = spec;
            k += 1;
        }
        return k;
    }
};

pub fn slashVisible(n: usize, view: usize) usize {
    return @min(n, view);
}

pub fn paletteWidth(cols: u16) u16 {
    return if (cols == 0) 1 else cols;
}

pub fn paletteBandRows(layout: Layout, n: usize) u16 {
    const items = paletteItemRows(layout, n);
    const want = items + 2;
    return @min(want, layout.transcript_rows);
}

pub fn palettePaintRows(layout: Layout, n: usize) u16 {
    if (n == 0) return 0;
    return paletteBandRows(layout, n);
}

pub fn slashWindowStart(sel: usize, n: usize, view: usize) usize {
    if (n <= view or view == 0) return 0;
    var start: usize = if (sel + 1 > view) sel + 1 - view else 0;
    if (start + view > n) start = n - view;
    return start;
}

fn foldByte(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// Prefix first; otherwise every query rune in order (so `/mdl` hits `/model`).
pub fn slashMatches(prefix: []const u8, name: []const u8) bool {
    if (std.mem.startsWith(u8, name, prefix)) return true;
    const q = if (prefix.len > 0 and prefix[0] == '/') prefix[1..] else prefix;
    const s = if (name.len > 0 and name[0] == '/') name[1..] else name;
    if (q.len == 0) return true;
    var i: usize = 0;
    for (s) |c| {
        if (i < q.len and foldByte(c) == foldByte(q[i])) i += 1;
    }
    return i == q.len;
}

pub fn keysDraft(src: []const u8) bool {
    return src.len > 0 and src[0] == '?' and std.mem.indexOfScalar(u8, src, ' ') == null;
}

pub fn matchKeys(prefix: []const u8, out: []slash.Spec) usize {
    if (!keysDraft(prefix)) return 0;
    const q = prefix[1..];
    var n: usize = 0;
    for (keys_sheet) |spec| {
        if (q.len != 0 and !slashMatches(q, spec.name) and std.mem.indexOf(u8, spec.help, q) == null)
            continue;
        if (n == out.len) break;
        out[n] = spec;
        n += 1;
    }
    return n;
}

/// `extra` is appended after every builtin, in both the prefix pass and the
/// fuzzy one: a skill is a document someone dropped in a directory, and it
/// should never outrank a command omfx actually implements.
pub fn matchSlash(prefix: []const u8, out: []slash.Spec, extra: []const slash.Spec) usize {
    if (prefix.len == 0 or prefix[0] != '/') return 0;
    // The prefix ends at the first space, so a second call later in the line
    // still opens the list for what is being typed now.
    const word = prefix[lastWordStart(prefix)..];
    if (word.len == 0 or word[0] != '/') return 0;
    if (std.mem.indexOfScalar(u8, word, ' ') != null) return 0;
    return matchWord(word, out, extra);
}

/// Where the word under the caret begins.
fn lastWordStart(line: []const u8) usize {
    var i = line.len;
    while (i > 0 and line[i - 1] != ' ' and line[i - 1] != '\n') i -= 1;
    return i;
}

fn matchWord(prefix: []const u8, out: []slash.Spec, extra: []const slash.Spec) usize {
    var n: usize = 0;
    for (slash.builtin) |spec| {
        if (!std.mem.startsWith(u8, spec.name, prefix)) continue;
        if (n == out.len) break;
        out[n] = spec;
        n += 1;
    }
    for (extra) |spec| {
        if (!std.mem.startsWith(u8, spec.name, prefix)) continue;
        if (n == out.len) break;
        out[n] = spec;
        n += 1;
    }
    for (slash.builtin) |spec| {
        if (std.mem.startsWith(u8, spec.name, prefix)) continue;
        if (!slashMatches(prefix, spec.name)) continue;
        if (n == out.len) break;
        out[n] = spec;
        n += 1;
    }
    for (extra) |spec| {
        if (std.mem.startsWith(u8, spec.name, prefix)) continue;
        if (!slashMatches(prefix, spec.name)) continue;
        if (n == out.len) break;
        out[n] = spec;
        n += 1;
    }
    return n;
}

/// The keys that work in the scrollback are not the keys that work in the
/// composer, and a bar that lies about that is worse than no bar.
pub fn scrollbackHint(buf: []u8, cols: u16) []const u8 {
    return renderHints(buf, &scrollback_hints, cols);
}

pub fn hintFor(buf: []u8, cols: u16) []const u8 {
    return renderHints(buf, &composer_hints, cols);
}

/// Printed once into the transcript pane: how to fill it, one next step.
pub const welcome = paint.muted ++ "Type a prompt. " ++ paint.reset ++ paint.accent_dim ++ "?" ++ paint.reset ++ paint.muted ++ " keys, " ++ paint.reset ++ paint.accent_dim ++ "/help" ++ paint.reset ++ paint.muted ++ " commands." ++ paint.reset ++ "\n";

/// Full command map. Shown from /help, not at startup.
pub const feature_sheet =
    \\tab on an empty prompt moves the keyboard into the scrollback
    \\  j k move  e open  E all  g G ends  y copy  esc back
    \\ctrl-q twice quits
    \\slash
    \\  /help /login /logout /models /model /fast /effort /plan /yolo
    \\  /permissions /allowlist /sandbox /status /stats /usage /settings /thinking
    \\  /web /browser /reload /mcp /skills /init /workspace /undo /copy /diagram
    \\  /session /resume /clear /reset /rename /compact /rewind /fork
    \\  /peers /background /trace /feedback /quit
    \\tools (via the model, or !cmd for bash)
    \\  read write edit bash glob grep list copy mkdir delete rename
    \\  file_info open_file semantic_search web_fetch web_search
    \\  ask_user memory browser peer board mcp patch compact
    \\keys  Enter:send  Shift+Tab:mode  Ctrl+:shortcuts  ctrl-q quit  ?:keys
    \\
;

const Window = struct { slice: []const u8, park: u16, from: usize };

fn composerWindow(src: []const u8, caret: usize, cols: u16) Window {
    const cap: usize = @min(caret, src.len);
    const caret_c = cellsTo(src[0..cap]);
    const total = cellsTo(src);
    if (total <= cols) {
        const park: u16 = @intCast(@min(@as(u32, cols), caret_c + 1));
        return .{ .slice = src, .park = if (park == 0) 1 else park, .from = 0 };
    }
    const start_cell: u16 = if (caret_c + 1 > cols) caret_c + 1 - cols else 0;
    const from = indexAtCell(src, start_cell);
    const to = indexAtCell(src, start_cell + cols);
    const rel = caret_c - start_cell;
    const park: u16 = @intCast(@min(@as(u32, cols), rel + 1));
    return .{ .slice = src[from..to], .park = if (park == 0) 1 else park, .from = from };
}

fn sanitizeRow(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, src.len);
    for (src, 0..) |b, i| {
        out[i] = if (b == '\n' or b == '\r') ' ' else b;
    }
    return out;
}

fn padCells(allocator: std.mem.Allocator, src: []const u8, cols: u16) ![]u8 {
    const w = cellsTo(src);
    const extra: usize = if (w >= cols) 0 else cols - w;
    const out = try allocator.alloc(u8, src.len + extra);
    @memcpy(out[0..src.len], src);
    @memset(out[src.len..], ' ');
    return out;
}

fn clipCells(src: []const u8, cols: u16) []const u8 {
    if (cellsTo(src) <= cols) return src;
    return src[0..indexAtCell(src, cols)];
}

fn ruleLine(allocator: std.mem.Allocator, cols: u16) ![]u8 {
    const cell = "─";
    const n = if (cols == 0) 1 else cols;
    const out = try allocator.alloc(u8, cell.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        @memcpy(out[i * cell.len ..][0..cell.len], cell);
    }
    return out;
}

fn boxEdgeIn(allocator: std.mem.Allocator, cols: u16, left: []const u8, right: []const u8, color: []const u8) ![]u8 {
    const inner: u16 = if (cols >= 2) cols - 2 else 1;
    const mid = try ruleLine(allocator, inner);
    defer allocator.free(mid);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{ color, left, mid, right, paint.reset });
}

fn boxEdge(allocator: std.mem.Allocator, cols: u16, left: []const u8, right: []const u8) ![]u8 {
    return boxEdgeIn(allocator, cols, left, right, paint.border);
}

/// Workspace on the left, one brand dot to anchor it, how full the context
/// window is on the right. Model and mode live in the footer.
///
/// The window is the one number you cannot recover once you have run past it,
/// so it is on screen rather than behind a command.
pub fn formatHeader(allocator: std.mem.Allocator, layout: Layout, footer: Footer) ![]u8 {
    if (layout.header_rows == 0) return allocator.dupe(u8, "");
    const inner: u16 = if (layout.cols > 3) layout.cols - 3 else 0;
    var ctx_buf: [32]u8 = undefined;
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

/// "325K / 500K", or "" until the provider has reported a count.
///
/// Both halves are shown rather than a percentage: a percentage of a number
/// you cannot see is not actionable, and the window differs per model and per
/// login route.
pub fn contextRow(buf: []u8, used: u32, window: u32) []const u8 {
    if (window == 0) return "";
    var w: Io.Writer = .fixed(buf);
    writeTokens(&w, used) catch return "";
    w.writeAll(" / ") catch return "";
    writeTokens(&w, window) catch return "";
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

/// `left` flush left, `right` flush right, padded to `inner` cells.
///
/// When the pair does not fit, the right side wins and the left is trimmed to
/// what remains: the model and mode on the right identify the session, while
/// the hint on the left is a reminder you can lose. Previously neither was
/// clipped and the row simply ran past the terminal, tearing the footer at any
/// width narrower than hint + meta.
fn padPair(allocator: std.mem.Allocator, left: []const u8, right: []const u8, inner: u16) ![]u8 {
    const rw = cellsTo(right);
    // The right side is never trimmed below a readable remainder; past that
    // both sides shrink rather than one vanishing.
    const right_shown = if (rw <= inner) right else clipCells(right, inner);
    const rw2 = cellsTo(right_shown);
    const room: u16 = if (inner > rw2 + 1) inner - rw2 - 1 else 0;
    const left_shown = clipCells(left, room);
    const lw = cellsTo(left_shown);

    const gap: usize = if (inner > lw + rw2) inner - lw - rw2 else @intFromBool(room > 0);
    var buf: [256]u8 = undefined;
    const n = @min(gap, buf.len);
    @memset(buf[0..n], ' ');
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ left_shown, buf[0..n], right_shown });
}

fn rowTitle(hit: slash.Spec) []const u8 {
    return if (hit.flip) hit.help else hit.name;
}

fn rowMeta(hit: slash.Spec) []const u8 {
    return if (hit.flip) hit.name else hit.help;
}

fn boxBottomCount(allocator: std.mem.Allocator, cols: u16, selected: usize, total: usize, view: usize) ![]u8 {
    const inner: u16 = if (cols >= 2) cols - 2 else cols;
    if (total <= view) return boxEdge(allocator, cols, "╰", "╯");
    var count_buf: [24]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, " {d}/{d} ", .{ selected + 1, total }) catch " ? ";
    const cw = cellsTo(count);
    const dashes: u16 = if (inner > cw) inner - cw else 0;
    const rule = try ruleLine(allocator, dashes);
    defer allocator.free(rule);
    return std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}{s}{s}{s}{s}╯{s}",
        .{ paint.border, paint.reset, paint.muted, count, paint.reset, paint.border, rule, paint.reset },
    );
}

fn writeBoxRow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), inner: u16, body: []const u8) !void {
    const padded = try padCells(allocator, body, inner);
    defer allocator.free(padded);
    try out.appendSlice(allocator, paint.border);
    try out.appendSlice(allocator, "│");
    try out.appendSlice(allocator, paint.reset);
    try out.appendSlice(allocator, padded);
    try out.appendSlice(allocator, paint.border);
    try out.appendSlice(allocator, "│");
    try out.appendSlice(allocator, paint.reset);
}

/// A menu narrower than this is two borders and a marker with nothing between
/// them; drawing it just tears the row.
pub const min_menu_cols: u16 = 12;

pub fn formatSlashMenu(
    allocator: std.mem.Allocator,
    cols: u16,
    hits: []const slash.Spec,
    selected: usize,
    item_rows: usize,
) ![]u8 {
    if (cols < min_menu_cols) return allocator.dupe(u8, "");
    const view: usize = if (item_rows == 0) 1 else item_rows;
    const box_w = paletteWidth(cols);
    const inner: u16 = if (box_w >= 2) box_w - 2 else box_w;
    const start = slashWindowStart(selected, hits.len, view);
    const filled = slashVisible(hits.len -| start, view);
    const vis = if (hits.len == 0) hits else hits[start .. start + filled];
    const vis_sel: usize = if (hits.len == 0) 0 else selected - start;
    var name_w: u16 = 0;
    for (vis) |hit| name_w = @max(name_w, cellsTo(rowTitle(hit)));
    const cap: u16 = if (inner > 8) inner / 2 else inner;
    name_w = @min(name_w, cap);

    const top = try boxEdge(allocator, box_w, "╭", "╮");
    defer allocator.free(top);
    const bot = try boxBottomCount(allocator, box_w, selected, hits.len, view);
    defer allocator.free(bot);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, top);
    var body_rows: usize = 0;
    if (vis.len == 0) {
        try out.append(allocator, '\n');
        try writeBoxRow(allocator, &out, inner, " no match");
        body_rows = 1;
    }
    for (vis, 0..) |hit, i| {
        try out.append(allocator, '\n');
        const sel = i == vis_sel;
        const mark: []const u8 = if (sel) "▸ " else "  ";
        const title = clipCells(rowTitle(hit), name_w);
        const named = try padCells(allocator, title, name_w);
        defer allocator.free(named);
        const used = 2 + name_w + 2;
        const help_cols: u16 = if (inner > used) inner - used else 0;
        const help = clipCells(rowMeta(hit), help_cols);
        const helped = try padCells(allocator, help, help_cols);
        defer allocator.free(helped);
        // Selected row: accent marker and title, meta stays quiet either way.
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "│");
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, if (sel) paint.accent else paint.border);
        try out.appendSlice(allocator, mark);
        try out.appendSlice(allocator, if (sel) paint.bold ++ paint.accent else paint.label);
        try out.appendSlice(allocator, named);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, helped);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "│");
        try out.appendSlice(allocator, paint.reset);
        body_rows += 1;
    }
    while (body_rows < view) : (body_rows += 1) {
        try out.append(allocator, '\n');
        try writeBoxRow(allocator, &out, inner, "");
    }
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, bot);
    return out.toOwnedSlice(allocator);
}

const WelcomeRow = struct {
    left: []const u8,
    right: []const u8 = "",
    /// Painted on `left`. `right` is always the accent (it is the thing to type).
    style: []const u8 = "",
};

/// Centred card: name, what it is talking to, then the four things worth doing.
/// Narrower than this a bordered card is all border and no content, so the
/// welcome degrades to the one-line form instead of drawing a broken box.
pub const min_card_cols: u16 = 24;

pub fn formatWelcome(allocator: std.mem.Allocator, layout: Layout, footer: Footer) ![]u8 {
    if (layout.cols < min_card_cols or layout.transcript_rows < 3) {
        return allocator.dupe(u8, clipCells(welcome, layout.cols));
    }
    // Never wider than the terminal: the borders are two of those columns, so
    // a card sized to `cols` itself overflows by two.
    const card_w: u16 = if (layout.cols >= 56)
        48
    else if (layout.cols > 16)
        layout.cols - 8
    else
        @min(layout.cols, @max(layout.cols, 4));
    const inner: u16 = if (card_w >= 2) card_w - 2 else card_w;
    const top = try boxEdge(allocator, card_w, "\u{256d}", "\u{256e}");
    defer allocator.free(top);
    const bot = try boxEdge(allocator, card_w, "\u{2570}", "\u{256f}");
    defer allocator.free(bot);

    var talk_buf: [160]u8 = undefined;
    const talk = std.fmt.bufPrint(&talk_buf, " Talking to {s}", .{footer.model}) catch " Talking to a model";

    const rows = [_]WelcomeRow{
        .{ .left = " " ++ cli.title, .right = cli.version, .style = paint.bold ++ paint.accent },
        .{ .left = "" },
        .{ .left = talk, .style = paint.label },
        .{ .left = "" },
        .{ .left = " New session", .right = "/clear", .style = paint.muted },
        .{ .left = " Resume session", .right = "/resume", .style = paint.muted },
        .{ .left = " Commands", .right = "/help", .style = paint.muted },
        .{ .left = " Keys", .right = "?", .style = paint.muted },
    };

    const card_h: u16 = @intCast(rows.len + 2);
    const col: u16 = if (layout.cols > card_w) (layout.cols - card_w) / 2 + 1 else 1;
    const room = layout.transcript_rows;
    const row0: u16 = if (room > card_h)
        layout.transcript_start_row + (room - card_h) / 2
    else
        layout.transcript_start_row;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cup: [32]u8 = undefined;
    var r = row0;
    try out.appendSlice(allocator, try moveTo(&cup, r, col));
    try out.appendSlice(allocator, top);
    r += 1;
    for (rows) |row| {
        // Right column is drawn flush; the left pad absorbs the width difference.
        // On a narrow card there is no room for it at all.
        const rw = if (cellsTo(row.right) + 4 <= inner) cellsTo(row.right) else 0;
        const lw: u16 = if (rw == 0) inner else if (inner > rw + 1) inner - rw - 1 else inner;
        const left = try padCells(allocator, clipCells(row.left, lw), lw);
        defer allocator.free(left);
        try out.appendSlice(allocator, try moveTo(&cup, r, col));
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "\u{2502}");
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, row.style);
        try out.appendSlice(allocator, left);
        try out.appendSlice(allocator, paint.reset);
        if (rw != 0) {
            try out.appendSlice(allocator, paint.accent_dim);
            try out.appendSlice(allocator, clipCells(row.right, rw));
            try out.appendSlice(allocator, paint.reset);
            try out.append(allocator, ' ');
        }
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "\u{2502}");
        try out.appendSlice(allocator, paint.reset);
        r += 1;
    }
    try out.appendSlice(allocator, try moveTo(&cup, r, col));
    try out.appendSlice(allocator, bot);
    return out.toOwnedSlice(allocator);
}

pub fn writeWelcome(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
) PaintError!void {
    var region_buf: [32]u8 = undefined;
    const region = try setScrollRegion(&region_buf, layout.regionTop(), layout.regionBottom());
    const card = try formatWelcome(allocator, layout, footer);
    defer allocator.free(card);
    try stdout.writeAll(sync_begin);
    try stdout.writeAll(region);
    try eraseRows(stdout, layout.transcript_start_row, layout.transcript_rows);
    try stdout.writeAll(card);
    try stdout.writeAll(sync_end);
}

/// The argument hint for a slash command the user has finished typing.
///
/// Shown only with the caret at the end of a bare command, so it never sits
/// between what you typed and where you are typing.
pub fn slashGhost(draft: []const u8, caret: usize) []const u8 {
    if (draft.len == 0 or draft[0] != '/' or caret != draft.len) return "";
    const name = std.mem.sliceTo(draft, ' ');
    // Either the name alone, or the name and exactly one space: past that the
    // user is writing the argument and does not need to be told its shape.
    if (draft.len != name.len and !(draft.len == name.len + 1 and draft[name.len] == ' ')) return "";
    const args = slash.argsFor(name);
    if (args.len == 0) return "";
    return args;
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

pub fn writeFooter(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
) PaintError!void {
    try writeChrome(allocator, stdout, layout, footer);
}

pub fn writeChrome(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
) PaintError!void {
    var move_buf: [32]u8 = undefined;
    const head = try formatHeader(allocator, layout, footer);
    defer allocator.free(head);
    const move = try moveTo(&move_buf, layout.footer_start_row, 1);
    const body = try formatFooter(allocator, layout, footer);
    defer allocator.free(body);
    try stdout.writeAll(sync_begin);
    try stdout.writeAll(hide_cursor);
    try stdout.writeAll(head);
    switch (overlayFor(layout, footer.slash.len)) {
        .none => {},
        .menu => |overlay_h| {
            const start_row = layout.footer_start_row - @min(overlay_h, layout.footer_start_row - 1);
            try eraseRows(stdout, start_row, overlay_h);
            const menu = try formatSlashMenu(allocator, layout.cols, footer.slash, footer.slash_sel, paletteItemRows(layout, footer.slash.len));
            defer allocator.free(menu);
            try writeLinesAt(stdout, start_row, menu);
        },
    }
    try stdout.writeAll(move);
    try stdout.writeAll(body);
    // Shown in both states. A turn can be steered while it runs, so the
    // composer is live throughout, and a live prompt with no caret reads as a
    // prompt that has stopped taking input.
    try stdout.writeAll(show_cursor);
    try stdout.writeAll(sync_end);
}

fn eraseRows(stdout: *Io.Writer, from_row: u16, n: u16) !void {
    var cup: [32]u8 = undefined;
    var r: u16 = 0;
    while (r < n) : (r += 1) {
        const at = try moveTo(&cup, from_row + r, 1);
        try stdout.writeAll(at);
        try stdout.writeAll("\x1b[2K");
    }
}

fn writeLinesAt(stdout: *Io.Writer, from_row: u16, text: []const u8) !void {
    var cup: [32]u8 = undefined;
    var r = from_row;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const at = try moveTo(&cup, r, 1);
        try stdout.writeAll(at);
        try stdout.writeAll("\x1b[2K");
        try stdout.writeAll(line);
        r +|= 1;
    }
}

pub const keys = @import("keys.zig");

/// Re-exported so `tui.Event` and friends keep working across the split.
pub const Click = keys.Click;
pub const Event = keys.Event;
pub const Perm = keys.Perm;
pub const takeEvent = keys.takeEvent;
pub const pollEvent = keys.pollEvent;
pub const nextEvent = keys.nextEvent;
pub const arm_quit_ms = draft_mod.arm_quit_ms;
pub const arm_esc_ms = draft_mod.arm_esc_ms;

pub fn composerRow(layout: Layout) u16 {
    if (layout.footer_rows >= 2)
        return @min(layout.rows, layout.footer_start_row + 1);
    return layout.footer_start_row;
}

pub fn inComposer(layout: Layout, row: u16) bool {
    return row == composerRow(layout);
}

pub fn inTranscript(layout: Layout, row: u16) bool {
    if (layout.transcript_rows == 0) return false;
    return row >= layout.transcript_start_row and row < layout.footer_start_row;
}

pub fn maxScroll(total: usize, rows: u16) usize {
    return if (total > rows) total - rows else 0;
}

/// Stays put when content already fits, so the pane does not flicker.
pub fn stepScroll(scroll: usize, total: usize, rows: u16, up: bool, step: u16) usize {
    const max = maxScroll(total, rows);
    if (up) return @min(max, scroll + step);
    if (scroll > step) return @min(max, scroll - step);
    return 0;
}

pub const draft_mod = @import("draft.zig");

/// Re-exported so the composer's callers read the same as before the split.
pub const Draft = draft_mod.Draft;
pub const History = draft_mod.History;
pub const Utf8Hold = draft_mod.Utf8Hold;
pub const history_cap = draft_mod.history_cap;
pub const takePaste = draft_mod.takePaste;
pub const popUtf8 = draft_mod.popUtf8;
/// "Press it twice" state lives with the composer it guards.
pub const Arm = draft_mod.Arm;
pub const ArmKind = draft_mod.ArmKind;

pub fn atPrefix(src: []const u8) ?[]const u8 {
    if (src.len == 0) return null;
    var i = src.len;
    while (i > 0) {
        const p = src[i - 1];
        if (p == ' ' or p == '\t' or p == '\n' or p == '\r') break;
        i -= 1;
    }
    const tok = src[i..];
    if (tok.len == 0 or tok[0] != '@') return null;
    return tok[1..];
}

/// `@` completion. Walks the workspace, so `@src/cli/tui.zig` completes the
/// way `@tui.zig` does -- a top-level-only listing misses almost every file in
/// a real repo. Ranked: basename hits before path hits, shallow before deep.
pub fn matchAt(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    store: [][96]u8,
    out: []slash.Spec,
) usize {
    const search = @import("../tools/search.zig");
    var w = search.Walk.init(allocator, io, dir, "") catch return 0;
    defer w.deinit();

    const Hit = struct { path: [96]u8, len: usize, rank: usize };
    var hits: [128]Hit = undefined;
    var n: usize = 0;
    while (w.next() catch null) |rel| {
        defer allocator.free(rel);
        if (rel.len == 0 or rel[0] == '.') continue;
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
        const rank: usize = if (prefix.len == 0)
            std.mem.count(u8, rel, "/")
        else if (slashMatches(prefix, base))
            std.mem.count(u8, rel, "/")
        else if (slashMatches(prefix, rel))
            std.mem.count(u8, rel, "/") + 100
        else
            continue;
        if (rel.len + 1 >= 96) continue;
        if (n == hits.len) {
            // Keep the best 128 seen so far rather than the first 128 found.
            var worst: usize = 0;
            for (hits[0..n], 0..) |h, i| {
                if (h.rank > hits[worst].rank) worst = i;
            }
            if (hits[worst].rank <= rank) continue;
            n -= 1;
            hits[worst] = hits[n];
        }
        const wrote = std.fmt.bufPrint(&hits[n].path, "@{s}", .{rel}) catch continue;
        hits[n].len = wrote.len;
        hits[n].rank = rank;
        n += 1;
    }

    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            if (hits[j].rank < hits[i].rank) {
                const tmp = hits[i];
                hits[i] = hits[j];
                hits[j] = tmp;
            }
        }
    }
    const take = @min(n, @min(store.len, out.len));
    i = 0;
    while (i < take) : (i += 1) {
        const src = hits[i].path[0..hits[i].len];
        @memcpy(store[i][0..src.len], src);
        out[i] = .{ .name = store[i][0..src.len], .help = "file" };
    }
    return take;
}

/// Holds an incomplete UTF-8 sequence so IME bytes do not split a rune.
pub fn paintSequence(allocator: std.mem.Allocator, layout: Layout, footer: Footer) ![]u8 {
    var region_buf: [32]u8 = undefined;
    var move_buf: [32]u8 = undefined;
    const region = try setScrollRegion(&region_buf, layout.regionTop(), layout.regionBottom());
    const head = try formatHeader(allocator, layout, footer);
    defer allocator.free(head);
    const move = try moveTo(&move_buf, layout.footer_start_row, 1);
    const body = try formatFooter(allocator, layout, footer);
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "{s}\x1b[H\x1b[2J{s}{s}{s}{s}{s}{s}", .{
        enter_alt,
        sync_begin,
        region,
        head,
        move,
        body,
        sync_end,
    });
}

/// Takes no allocator, because it needs no memory: the rows already exist,
/// folded, inside the Transcript. That is the whole point -- a paint that
/// cannot allocate cannot leak.
/// A selection the app owns.
///
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
        // A row inside a multi-row selection runs to its end, and the trailing
        // blank is not part of the text, so it stops at the last cell.
        const to: u16 = if (row == o.b_row) @min(o.b_col, cells) else cells;
        if (from >= to) return null;
        return .{ .from = from, .to = to };
    }
};

/// Background off, foreground untouched.
pub const sel_off = "\x1b[49m";

/// `row` with cells [from, to) on the selection background.
///
/// The background is turned off with SGR 49 rather than a full reset so the
/// row keeps its own foreground colours, and it is re-asserted after every
/// escape inside the span, because a row is free to reset its own attributes
/// halfway through.
pub fn writeSelected(out: *Io.Writer, row: []const u8, from: u16, to: u16) !void {
    const a = width.indexAtCell(row, from);
    const b = width.indexAtCell(row, to);
    try out.writeAll(row[0..a]);
    try out.writeAll(paint.sel_bg);
    var i = a;
    while (i < b) {
        const nxt = width.skipEsc(row, i);
        if (nxt != i) {
            try out.writeAll(row[i..nxt]);
            try out.writeAll(paint.sel_bg);
            i = nxt;
            continue;
        }
        const len = width.utf8LenAt(row, i);
        try out.writeAll(row[i..][0..len]);
        i += len;
    }
    try out.writeAll(sel_off);
    try out.writeAll(row[b..]);
}

/// The text of cells [from, to) with every escape sequence dropped: what goes
/// on the clipboard is what the eye sees, not how it was painted.
pub fn plainCells(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row: []const u8, from: u16, to: u16) !void {
    const a = width.indexAtCell(row, from);
    const b = width.indexAtCell(row, to);
    var i = a;
    while (i < b) {
        const nxt = width.skipEsc(row, i);
        if (nxt != i) {
            i = nxt;
            continue;
        }
        const len = width.utf8LenAt(row, i);
        try out.appendSlice(allocator, row[i..][0..len]);
        i += len;
    }
}

pub fn writeTranscript(
    stdout: *Io.Writer,
    layout: Layout,
    t: *const Transcript,
    scroll: usize,
    sel: Sel,
) PaintError!void {
    const total = t.rowCount();
    const rows = layout.transcript_rows;
    const off = @min(scroll, maxScroll(total, rows));
    const start: usize = if (total > rows + off) total - rows - off else 0;
    const vis: u16 = if (total > start) @intCast(@min(rows, total - start)) else 0;
    const first = transcriptFirstRow(layout.transcript_start_row, rows, vis);
    var region_buf: [32]u8 = undefined;
    const region = try setScrollRegion(&region_buf, layout.regionTop(), layout.regionBottom());
    try stdout.writeAll(sync_begin);
    try stdout.writeAll(region);
    try stdout.writeAll("\x1b[?7l");
    try eraseRows(stdout, layout.transcript_start_row, rows);
    var cup: [32]u8 = undefined;
    var i = start;
    var shown: u16 = 0;
    while (i < total and shown < vis) : (i += 1) {
        try stdout.writeAll(try moveTo(&cup, first + shown, 1));
        const row = t.row(i);
        const hit = if (sel.where == .transcript) sel.span(i, width.cellsTo(row)) else null;
        if (hit) |h| try writeSelected(stdout, row, h.from, h.to) else try stdout.writeAll(row);
        try stdout.writeAll("\x1b[K");
        shown += 1;
    }
    try stdout.writeAll("\x1b[?7h");
    try stdout.writeAll(sync_end);
}

/// The allocator here is footer-only: bounded by terminal width, and freed.
pub fn writePane(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: Layout,
    footer: Footer,
    t: *Transcript,
    scroll: usize,
) PaintError!void {
    stdout.writeAll(hide_cursor) catch return error.WriteFailed;
    // The activity row belongs to the turn, so it is set here rather than left
    // to each of the callers to remember.
    t.setStatus(switch (footer.turn) {
        .generating => footer.status,
        .idle => "",
    });
    if (t.isEmpty() and footer.turn == .idle) {
        try writeWelcome(allocator, stdout, layout, footer);
    } else {
        try writeTranscript(stdout, layout, t, scroll, footer.sel);
    }
    try writeFooter(allocator, stdout, layout, footer);
}

/// Which committed transcript row a terminal row is showing, if any.
///
/// The same arithmetic `writeTranscript` paints with, read backwards. Keeping
/// them apart would let a click land one row off the thing it pointed at.
pub fn transcriptRowAt(layout: Layout, t: *const Transcript, scroll: usize, term_row: u16) ?usize {
    const total = t.rowCount();
    const rows = layout.transcript_rows;
    if (rows == 0 or total == 0) return null;
    const off = @min(scroll, maxScroll(total, rows));
    const start: usize = if (total > rows + off) total - rows - off else 0;
    const vis: u16 = if (total > start) @intCast(@min(rows, total - start)) else 0;
    const first = transcriptFirstRow(layout.transcript_start_row, rows, vis);
    if (term_row < first or term_row >= first + vis) return null;
    return start + (term_row - first);
}

pub fn transcriptFirstRow(start_row: u16, rows: u16, vis: u16) u16 {
    if (vis == 0 or vis >= rows) return start_row;
    return start_row + (rows - vis);
}

pub fn restoreSequence() []const u8 {
    return leave_alt;
}

/// Alt-screen contents are lost on exit, so the transcript is replayed into the
/// normal screen's scrollback on the way out.
pub fn restoreWithScrollback(allocator: std.mem.Allocator, shown: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ leave_alt, shown });
}

test "24x80 pins header and footer around the transcript" {
    const l = Layout.compute(24, 80);
    try std.testing.expectEqual(@as(u16, 1), l.header_rows);
    try std.testing.expectEqual(@as(u16, 19), l.transcript_rows);
    try std.testing.expectEqual(@as(u16, 2), l.transcript_start_row);
    try std.testing.expectEqual(@as(u16, 4), l.footer_rows);
    try std.testing.expectEqual(@as(u16, 21), l.footer_start_row);
    try std.testing.expectEqual(@as(u16, 20), l.regionBottom());
    try std.testing.expectEqual(@as(u16, 16), l.scrollBottom(4));
    try std.testing.expectEqual(@as(u16, 20), l.scrollBottom(0));
}

test "transcript sits above the footer" {
    try std.testing.expectEqual(@as(u16, 19), transcriptFirstRow(2, 19, 2));
    try std.testing.expectEqual(@as(u16, 2), transcriptFirstRow(2, 19, 19));
    try std.testing.expectEqual(@as(u16, 2), transcriptFirstRow(2, 19, 0));
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

test "paint keeps footer start after many lines" {
    const layout = Layout.compute(24, 80);
    const painted = try paintSequence(std.testing.allocator, layout, .{
        .model = "anthropic/claude",
        .permission = "ask",
        .composer = "> ",
    });
    defer std.testing.allocator.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, enter_alt) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, sync_begin) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[21;1H") != null);
}

test "restoreWithScrollback keeps transcript after alt screen" {
    const s = try restoreWithScrollback(std.testing.allocator, "hello\nworld\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, leave_alt));
    try std.testing.expect(std.mem.indexOf(u8, s, "hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "world\n") != null);
}

test "fallback size is 24x80" {
    const s = Size{ .rows = 24, .cols = 80 };
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}

test "ThinkView hidden drops chunks" {
    var v = ThinkView.init(false);
    try std.testing.expect(!v.shows());
    try std.testing.expect(v.push("plan") == null);
    try std.testing.expectEqualStrings("", v.end());
}

test "ThinkView opens once then stays open" {
    var v = ThinkView.init(true);
    const first = v.push("ab").?;
    try std.testing.expectEqualStrings(think_head, first.prefix);
    try std.testing.expectEqualStrings("ab", first.body);
    const next = v.push("c").?;
    try std.testing.expectEqualStrings("", next.prefix);
    try std.testing.expectEqualStrings("c", next.body);
    try std.testing.expectEqualStrings(think_tail, v.end());
    try std.testing.expectEqualStrings("", v.end());
}

test "ask path must not emit alt screen in the constant itself" {
    try std.testing.expect(std.mem.indexOf(u8, enter_alt, "1049") != null);
}

test "a truncated row never ends inside a rune" {
    var p = Pick{};
    // 3-byte runes, so a byte cap that is not a multiple of 3 lands mid-rune.
    const wide = "\u{4e00}" ** 40;
    p.push(wide, wide);
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.rows[0].name));
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.rows[0].help));
    try std.testing.expect(p.rows[0].name.len > 0);
}

test "a finished slash command shows its argument shape, and only then" {
    try std.testing.expectEqualStrings("[ask|auto|yolo]", slashGhost("/permissions", 12));
    // One space still counts as "not writing the argument yet".
    try std.testing.expectEqualStrings("[ask|auto|yolo]", slashGhost("/permissions ", 13));
    // Once there is an argument the shape is in the way.
    try std.testing.expectEqualStrings("", slashGhost("/permissions yolo", 17));
    // Not at the end of the line, so the ghost would sit between text and caret.
    try std.testing.expectEqualStrings("", slashGhost("/permissions", 4));
    try std.testing.expectEqualStrings("", slashGhost("hello", 5));
    // A command that takes nothing says nothing.
    try std.testing.expectEqualStrings("", slashGhost("/help", 5));
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

test "the way out is the last hint to go" {
    var buf: [256]u8 = undefined;
    const wide = scrollbackHint(&buf, 60);
    try std.testing.expect(std.mem.indexOf(u8, wide, "j/k move") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "y copy") != null);

    // Too narrow for all three pinned hints: the escape hatch survives.
    var buf2: [256]u8 = undefined;
    const narrow = scrollbackHint(&buf2, 24);
    try std.testing.expect(cellsTo(narrow) <= 24);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "esc back") != null);

    var buf3: [256]u8 = undefined;
    const tiny = scrollbackHint(&buf3, 9);
    try std.testing.expect(cellsTo(tiny) <= 9);
    try std.testing.expectEqualStrings("esc back", tiny);
}

test "a bare letter is only ever a scrollback binding" {
    // In the composer a letter is text, never a command; the vim keys exist
    // only while the keyboard is in the scrollback, and the sheet must say so.
    const letters = [_][]const u8{ "j k", "e enter", "h l", "E", "g G", "y" };
    for (keys_sheet) |row| {
        for (letters) |l| {
            if (!std.mem.eql(u8, row.name, l)) continue;
            try std.testing.expect(std.mem.startsWith(u8, row.help, "scrollback:"));
        }
        try std.testing.expect(std.mem.indexOf(u8, row.help, "scroll focused") == null);
    }
}

test "welcome is one empty-state line" {
    try std.testing.expect(std.mem.indexOf(u8, welcome, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "Type a prompt") != null);
}

test "stepScroll does not move when content fits" {
    try std.testing.expectEqual(@as(usize, 0), maxScroll(10, 20));
    try std.testing.expectEqual(@as(usize, 0), stepScroll(0, 10, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 0), stepScroll(0, 10, 20, false, 3));
}

test "stepScroll clamps to the last page" {
    try std.testing.expectEqual(@as(usize, 5), maxScroll(25, 20));
    try std.testing.expectEqual(@as(usize, 3), stepScroll(0, 25, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 5), stepScroll(3, 25, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 5), stepScroll(5, 25, 20, true, 3));
    try std.testing.expectEqual(@as(usize, 2), stepScroll(5, 25, 20, false, 3));
    try std.testing.expectEqual(@as(usize, 0), stepScroll(2, 25, 20, false, 3));
}

test "writeTranscript clears the pane and paints chunks" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var t = Transcript.init(std.testing.allocator, layout.cols);
    defer t.deinit();
    try t.append("hello from user\n");
    try writeTranscript(&aw.writer, layout, &t, 0, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "hello from user") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[19;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Oh My Fx") == null);
}

test "writePane paints chat then footer" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var t = Transcript.init(std.testing.allocator, layout.cols);
    defer t.deinit();
    try t.append("hello from user\n");
    try writePane(std.testing.allocator, &aw.writer, layout, .{
        .model = "x",
        .permission = "normal",
        .composer = "> ",
        .place = "/tmp",
    }, &t, 0);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "hello from user") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "enter send") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), hide_cursor) != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), show_cursor) != null);
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

test "writePane hides the caret only while it redraws" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var t = Transcript.init(std.testing.allocator, layout.cols);
    defer t.deinit();
    try t.append("You\nhey\n");
    try writePane(std.testing.allocator, &aw.writer, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "",
        .place = "/tmp",
        .turn = .generating,
    }, &t, 0);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, generating) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, stop_hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, hide_cursor) != null);
    // Parked back on the composer at the end of the frame: the pane hides the
    // caret while it redraws, not for the length of the turn.
    try std.testing.expect(std.mem.indexOf(u8, out, show_cursor) != null);
}

test "writeFooter without a menu does not wipe the transcript band" {
    const layout = Layout.compute(24, 80);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeFooter(std.testing.allocator, &aw.writer, layout, .{
        .model = "x",
        .permission = "ask",
        .composer = "",
        .place = "/tmp",
    });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[13;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[20;1H") == null);
}

test "welcome card is centered with commands" {
    const layout = Layout.compute(24, 80);
    const s = try formatWelcome(std.testing.allocator, layout, .{
        .model = "grok-4.6",
        .permission = "ask",
        .composer = "> ",
    });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Oh My Fx") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "/resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Talking to") != null);
}

test "skills list after every builtin, never in front of one" {
    var buf: [max_slash_hits]slash.Spec = undefined;
    const extra = [_]slash.Spec{
        .{ .name = "/help-me-write", .help = "skill" },
        .{ .name = "/aaa", .help = "skill" },
    };
    const n = matchSlash("/help", &buf, &extra);
    try std.testing.expect(n >= 2);
    // The command omfx implements comes first; the document on disk follows.
    try std.testing.expectEqualStrings("/help", buf[0].name);
    try std.testing.expectEqualStrings("/help-me-write", buf[1].name);
}

test "a second slash later in the line opens the list for that word" {
    var buf: [max_slash_hits]slash.Spec = undefined;
    const extra = [_]slash.Spec{.{ .name = "/deslop", .help = "skill" }};
    // Composing two skills: the word under the caret is what is being typed.
    const n = matchSlash("/tdd and /des", &buf, &extra);
    try std.testing.expect(n >= 1);
    // Matched on `/des`, the word being typed, not on `/tdd` behind it.
    try std.testing.expectEqualStrings("/deslop", buf[0].name);
}

test "matchSlash filters by prefix" {
    var buf: [8]slash.Spec = undefined;
    const n = matchSlash("/he", &buf, &.{});
    try std.testing.expect(n >= 1);
    try std.testing.expectEqualStrings("/help", buf[0].name);
    try std.testing.expectEqual(@as(usize, 0), matchSlash("help", &buf, &.{}));
}

test "Pick match filters by name" {
    var p = Pick{};
    p.open(.models);
    p.push("groq", "llama");
    p.push("anthropic", "claude");
    var buf: [8]slash.Spec = undefined;
    try std.testing.expectEqual(@as(usize, 2), p.match("", &buf));
    try std.testing.expectEqual(@as(usize, 1), p.match("groq", &buf));
    try std.testing.expectEqualStrings("groq", buf[0].name);
    p.clear();
    try std.testing.expectEqual(PickKind.none, p.kind);
}

test "keysDraft is a leading question mark" {
    try std.testing.expect(keysDraft("?"));
    try std.testing.expect(keysDraft("?c"));
    try std.testing.expect(!keysDraft("? foo"));
    try std.testing.expect(!keysDraft("/help"));
    var buf: [64]slash.Spec = undefined;
    try std.testing.expectEqual(keys_sheet.len, matchKeys("?", &buf));
    const n = matchKeys("?c", &buf);
    try std.testing.expect(n >= 1);
    try std.testing.expect(std.mem.indexOf(u8, buf[0].name, "c") != null or std.mem.indexOf(u8, buf[0].help, "c") != null);
}

test "matchSlash fuzzy finds model from mdl" {
    var buf: [16]slash.Spec = undefined;
    const n = matchSlash("/mdl", &buf, &.{});
    try std.testing.expect(n >= 1);
    try std.testing.expect(std.mem.eql(u8, buf[0].name, "/model") or std.mem.eql(u8, buf[0].name, "/models"));
}

test "slash menu highlights the selected row" {
    const hits = [_]slash.Spec{
        .{ .name = "/help", .help = "list slash commands" },
        .{ .name = "/quit", .help = "exit" },
    };
    const s = try formatSlashMenu(std.testing.allocator, 40, &hits, 1, 8);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "/quit") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "▸") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.accent) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[2K") == null);
}

test "a flipped row leads with the description, not the id" {
    const hits = [_]slash.Spec{
        .{ .name = "grok-composer-2.5-fast", .help = "Grok Composer 2.5 Fast", .flip = true },
    };
    const s = try formatSlashMenu(std.testing.allocator, 64, &hits, 0, 8);
    defer std.testing.allocator.free(s);
    const title_at = std.mem.indexOf(u8, s, "Grok Composer 2.5 Fast") orelse {
        try std.testing.expect(false);
        return;
    };
    const id_at = std.mem.indexOf(u8, s, "grok-composer-2.5-fast") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(title_at < id_at);
}

test "slash menu windows past the first page" {
    var hits: [12]slash.Spec = undefined;
    for (&hits, 0..) |*h, i| {
        h.* = .{ .name = "/help", .help = "x" };
        _ = i;
    }
    hits[0].name = "/help";
    hits[9].name = "/trace";
    const s = try formatSlashMenu(std.testing.allocator, 40, &hits, 9, 6);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "/trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "10/12") != null);
    try std.testing.expectEqual(@as(usize, 4), slashWindowStart(9, 12, 6));
}

test "ctrl-c is quit in the keys sheet" {
    var found = false;
    for (keys_sheet) |row| {
        if (std.mem.eql(u8, row.name, "ctrl-c")) {
            try std.testing.expectEqualStrings("quit", row.help);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "atPrefix reads the open @ token" {
    try std.testing.expectEqualStrings("he", atPrefix("see @he").?);
    try std.testing.expect(atPrefix("see @he ") == null);
    try std.testing.expect(atPrefix("/help") == null);
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
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0K / 8K", contextRow(&buf, 940, 8_000));
    try std.testing.expectEqualStrings("0K / 500K", contextRow(&buf, 0, 500_000));
    try std.testing.expectEqualStrings("325K / 500K", contextRow(&buf, 325_000, 500_000));
    try std.testing.expectEqualStrings("199K / 1.0M", contextRow(&buf, 199_000, 1_000_000));
    try std.testing.expectEqualStrings("", contextRow(&buf, 100, 0));
}

test "the picker shrinks to its matches and caps at five" {
    const layout = Layout.compute(24, 80);
    try std.testing.expectEqual(@as(u16, 80), paletteWidth(80));
    // A filter that leaves two rows draws a two-row box, not five.
    try std.testing.expectEqual(@as(u16, 2), paletteItemRows(layout, 2));
    try std.testing.expectEqual(@as(u16, 5), paletteItemRows(layout, 5));
    // Past the cap it scrolls rather than growing.
    try std.testing.expectEqual(@as(u16, 5), paletteItemRows(layout, 40));

    var b: [12]slash.Spec = undefined;
    for (&b) |*h| h.* = .{ .name = "/help", .help = "x" };
    const two = try formatSlashMenu(std.testing.allocator, 80, b[0..2], 0, paletteItemRows(layout, 2));
    defer std.testing.allocator.free(two);
    const many = try formatSlashMenu(std.testing.allocator, 80, &b, 0, paletteItemRows(layout, b.len));
    defer std.testing.allocator.free(many);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, two, "\n"));
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, many, "\n"));
    // The band follows the box, so the transcript is not left with a hole.
    try std.testing.expect(paletteBandRows(layout, 2) < paletteBandRows(layout, 12));
}

test "narrow layout still has a footer row" {
    const l = Layout.compute(8, 40);
    try std.testing.expect(l.footer_rows >= 1);
    try std.testing.expect(l.transcript_rows >= 1);
}

test "Cups track footer after resize" {
    const a = Cups.compute(Layout.compute(24, 80));
    try std.testing.expect(std.mem.indexOf(u8, a.toFooter(), "21;1H") != null);
    const b = Cups.compute(Layout.compute(12, 40));
    try std.testing.expect(std.mem.indexOf(u8, b.toFooter(), "9;1H") != null);
}

test "perm choice maps rows to decisions" {
    try std.testing.expectEqual(Perm.allow, permChoice(0));
    try std.testing.expectEqual(Perm.always, permChoice(1));
    try std.testing.expectEqual(Perm.deny, permChoice(2));
    // Out of range must fail closed, never allow.
    try std.testing.expectEqual(Perm.deny, permChoice(99));
}

test "perm sheet offers exactly allow, always, deny" {
    try std.testing.expectEqual(@as(usize, 3), perm_sheet.len);
    try std.testing.expectEqualStrings("1", perm_sheet[0].name);
    try std.testing.expectEqualStrings("3", perm_sheet[2].name);
    try std.testing.expect(std.mem.indexOf(u8, perm_sheet[2].help, "deny") != null);
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

/// Widest painted row in `bytes`, measured in display cells.
///
/// Rows are split on cursor moves as well as newlines: the pane positions each
/// row with a CUP rather than a `\n`, so splitting on newlines alone measures
/// one giant row and proves nothing.
fn widestRow(bytes: []const u8) u16 {
    var widest: u16 = 0;
    var row: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\n' or bytes[i] == '\r') {
            widest = @max(widest, width.cellsTo(bytes[row..i]));
            i += 1;
            row = i;
            continue;
        }
        if (bytes[i] == 0x1b) {
            const end = width.skipEsc(bytes, i);
            // A cursor move ends the current row wherever it was.
            if (end > i + 1 and (bytes[end - 1] == 'H' or bytes[end - 1] == 'f')) {
                widest = @max(widest, width.cellsTo(bytes[row..i]));
                row = end;
            }
            i = end;
            continue;
        }
        i += 1;
    }
    return @max(widest, width.cellsTo(bytes[row..]));
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

test "tab title names omfx and a spinner glyph" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    writeTabTitle(&aw.writer, 0, "Waiting for response...");
    const s = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, s, "omfx") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Waiting for response...") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, activity.glyph(0)) != null);
    try std.testing.expect(std.mem.startsWith(u8, s, "\x1b]0;"));
}

test "the slash menu fits every width" {
    const a = std.testing.allocator;
    const hits = [_]slash.Spec{
        .{ .name = "/a-very-long-command-name-here", .help = "an equally long description of what it does" },
        .{ .name = "/b", .help = "short" },
    };
    for ([_]u16{ 1, 2, 8, 20, 40, 80, 200 }) |cols| {
        const menu = try formatSlashMenu(a, cols, &hits, 0, 2);
        defer a.free(menu);
        try std.testing.expect(widestRow(menu) <= cols);
    }
}

test "the idle tab names the workspace and the model" {
    var buf: [96]u8 = undefined;
    const s = idleTitleSeq(&buf, "/Users/x/Downloads/ffx", "grok-composer-2.5-fast");
    try std.testing.expect(std.mem.indexOf(u8, s, "ffx") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "grok-composer-2.5-fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Downloads") == null);
    // No model resolved yet is a name, not a half-drawn title.
    try std.testing.expectEqualStrings(tab_title_idle, idleTitleSeq(&buf, "", ""));
}

test "a click maps back to the row the pane painted there" {
    var t = Transcript.init(std.testing.allocator, 80);
    defer t.deinit();
    try t.append("one\ntwo\nthree\n");
    const layout = Layout.compute(24, 80);
    const first = transcriptFirstRow(layout.transcript_start_row, layout.transcript_rows, 3);
    try std.testing.expectEqual(@as(?usize, 0), transcriptRowAt(layout, &t, 0, first));
    try std.testing.expectEqual(@as(?usize, 2), transcriptRowAt(layout, &t, 0, first + 2));
    try std.testing.expectEqual(@as(?usize, null), transcriptRowAt(layout, &t, 0, first + 3));
    try std.testing.expectEqual(@as(?usize, null), transcriptRowAt(layout, &t, 0, 0));
}
