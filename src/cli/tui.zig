const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const tty = @import("tty.zig");
const slash = @import("../core/slash.zig");
const cli = @import("../core/cli.zig");
const activity = @import("activity.zig");
const modal = @import("modal.zig");
const diffview = @import("diffview.zig");
const uxcopy = @import("uxcopy.zig");

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

const layout_mod = @import("tui/layout.zig");
const events = @import("tui/events.zig");
const palette_mod = @import("tui/palette.zig");
const chrome_mod = @import("tui/chrome.zig");
const scroll_mod = @import("tui/scroll.zig");

pub const Size = layout_mod.Size;
pub const Layout = layout_mod.Layout;
pub const Cups = layout_mod.Cups;
pub const size = layout_mod.size;
pub const moveTo = layout_mod.moveTo;

pub const Turn = chrome_mod.Turn;
pub const Hint = chrome_mod.Hint;
pub const Footer = chrome_mod.Footer;
pub const generating = chrome_mod.generating;
pub const stop_hint = chrome_mod.stop_hint;
pub const queued_hint = chrome_mod.queued_hint;
pub const PaintError = chrome_mod.PaintError;
pub const welcome = chrome_mod.welcome;
pub const min_card_cols = chrome_mod.min_card_cols;
pub const min_menu_cols = chrome_mod.min_menu_cols;
pub const Sel = chrome_mod.Sel;
pub const sel_off = chrome_mod.sel_off;
pub const jump_label = chrome_mod.jump_label;

pub const HintItem = scroll_mod.HintItem;
pub const hint_sep = scroll_mod.hint_sep;
pub const max_hints = scroll_mod.max_hints;
pub const renderHints = scroll_mod.renderHints;

pub const pick_cap = palette_mod.pick_cap;
pub const max_skill_hits = palette_mod.max_skill_hits;
pub const max_slash_hits = palette_mod.max_slash_hits;
pub const slash_view_rows = palette_mod.slash_view_rows;
pub const palette_max_items = palette_mod.palette_max_items;
pub const KeyRow = palette_mod.KeyRow;
pub const key_rows = palette_mod.key_rows;
pub const keys_sheet = palette_mod.keys_sheet;
pub const Pick = palette_mod.Pick;
pub const PickKind = palette_mod.PickKind;

pub const paletteItemRows = palette_mod.paletteItemRows;
pub const slashVisible = palette_mod.slashVisible;
pub const paletteWidth = palette_mod.paletteWidth;
pub const paletteBandRows = palette_mod.paletteBandRows;
pub const palettePaintRows = palette_mod.palettePaintRows;
pub const slashWindowStart = palette_mod.slashWindowStart;
pub const slashMatches = palette_mod.slashMatches;
pub const keysDraft = palette_mod.keysDraft;
pub const matchKeys = palette_mod.matchKeys;
pub const matchSlash = palette_mod.matchSlash;
pub const slashGhost = palette_mod.slashGhost;
pub const atPrefix = palette_mod.atPrefix;
pub const matchAt = palette_mod.matchAt;

pub const formatHeader = chrome_mod.formatHeader;
pub const contextRow = chrome_mod.contextRow;
pub const shortTokens = chrome_mod.shortTokens;
pub const formatSlashMenu = chrome_mod.formatSlashMenu;
pub const formatWelcome = chrome_mod.formatWelcome;
pub const writeWelcome = chrome_mod.writeWelcome;
pub const formatFooter = chrome_mod.formatFooter;
pub const writeFooter = chrome_mod.writeFooter;
pub const writeChrome = chrome_mod.writeChrome;
pub const formatJumpPill = chrome_mod.formatJumpPill;
pub const paintSequence = chrome_mod.paintSequence;
pub const writeSelected = chrome_mod.writeSelected;
pub const plainCells = chrome_mod.plainCells;
pub const chromeOverlay = chrome_mod.chromeOverlay;
pub const writeTranscript = chrome_mod.writeTranscript;
pub const writeTranscriptOverlay = chrome_mod.writeTranscriptOverlay;
pub const writePane = chrome_mod.writePane;
pub const composerRow = chrome_mod.composerRow;
pub const inComposer = chrome_mod.inComposer;
pub const hintFor = chrome_mod.hintFor;

pub const maxScroll = scroll_mod.maxScroll;
pub const jumpThreshold = scroll_mod.jumpThreshold;
pub const jumpVisible = scroll_mod.jumpVisible;
pub const JumpHit = scroll_mod.JumpHit;
pub const jumpHitBox = scroll_mod.jumpHitBox;
pub const jumpHit = scroll_mod.jumpHit;
pub const contextHitBox = scroll_mod.contextHitBox;
pub const contextHit = scroll_mod.contextHit;
pub const wheel_step = scroll_mod.wheel_step;
pub const stepScroll = scroll_mod.stepScroll;
pub const scrollbackHint = scroll_mod.scrollbackHint;
pub const transcriptRowAt = scroll_mod.transcriptRowAt;
pub const transcriptFirstRow = scroll_mod.transcriptFirstRow;

pub fn setScrollRegion(buf: []u8, top: u16, bottom: u16) ![]u8 {
    return chrome_mod.setScrollRegion(buf, top, bottom);
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

fn permChoice(sel: usize) Perm {
    return switch (sel) {
        0 => .allow,
        1 => .always,
        else => .deny,
    };
}
fn paintModalFrame(stdout: *Io.Writer, g: modal.Geometry, frame: []const u8) !void {
    try stdout.writeAll(hide_cursor);
    var clear_r: u16 = g.row0;
    while (clear_r < g.row0 + g.rows) : (clear_r += 1) {
        var cup: [32]u8 = undefined;
        try stdout.writeAll(try moveTo(&cup, clear_r, 1));
        try stdout.writeAll("\x1b[2K");
    }
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, frame, "\n"), '\n');
    var r: u16 = g.row0;
    while (it.next()) |line| {
        var cup: [32]u8 = undefined;
        try stdout.writeAll(try moveTo(&cup, r, g.col0));
        try stdout.writeAll(line);
        r +|= 1;
    }
    try stdout.flush();
}

pub fn askPerm(
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    layout: *Layout,
    name: []const u8,
    detail: []const u8,
    preview: []const u8,
) Perm {
    var sel: usize = 0;
    const title = "Allow this?";
    const action = uxcopy.actionTitle(name);
    const detail_line: []const u8 = if (detail.len != 0) detail else uxcopy.missingDetail(name);
    var head_buf: [320]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "{s}\n{s}", .{ action, detail_line }) catch action;

    const looks_diff = preview.len != 0 and (std.mem.indexOf(u8, preview, "\n+") != null or
        std.mem.indexOf(u8, preview, "\n-") != null or
        std.mem.startsWith(u8, preview, "@@") or
        std.mem.startsWith(u8, preview, "---") or
        std.mem.startsWith(u8, preview, "diff "));
    const painted_preview = if (looks_diff)
        diffview.render(allocator, @min(layout.cols, modal.max_cols) -| 4, preview, true) catch null
    else
        null;
    defer if (painted_preview) |p| allocator.free(p);

    const body = blk: {
        if (painted_preview) |p| {
            break :blk std.fmt.allocPrint(allocator, "{s}\n{s}", .{ head, std.mem.trimEnd(u8, p, "\n") }) catch head;
        }
        if (preview.len != 0) {
            break :blk std.fmt.allocPrint(allocator, "{s}\n{s}", .{ head, preview }) catch head;
        }
        break :blk head;
    };
    defer if (body.ptr != head.ptr) allocator.free(body);
    const painted = painted_preview != null;

    while (true) {
        const sz = size(layout.rows, layout.cols);
        layout.* = Layout.compute(sz.rows, sz.cols);
        const lines = modal.bodyLineCount(body);
        const g = modal.geometry(layout.rows, layout.cols, lines, modal.perm_buttons.len);
        const frame = modal.render(allocator, g, title, body, &modal.perm_buttons, sel, painted) catch return .deny;
        defer allocator.free(frame);
        paintModalFrame(stdout, g, frame) catch return .deny;

        switch (nextEvent(stdin)) {
            .enter => return permChoice(sel),
            .history_prev, .up => sel = if (sel == 0) modal.perm_buttons.len - 1 else sel - 1,
            .history_next, .down => sel = (sel + 1) % modal.perm_buttons.len,
            .byte => |b| switch (b) {
                '1' => return .allow,
                '2' => return .always,
                '3' => return .deny,
                else => {},
            },
            .esc => return .deny,
            .interrupt, .quit, .ctrl_d, .eof => return .quit,
            else => {},
        }
    }
}

/// Blocking yes/no. Buttons name the consequence. Esc / 2 declines; 1 / enter confirms.
pub fn askConfirm(
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    layout: *Layout,
    title: []const u8,
    body: []const u8,
    yes_label: []const u8,
    no_label: []const u8,
) bool {
    var sel: usize = 0;
    const buttons = [_]modal.Button{
        .{ .key = "1", .label = yes_label },
        .{ .key = "2", .label = no_label },
    };
    while (true) {
        const sz = size(layout.rows, layout.cols);
        layout.* = Layout.compute(sz.rows, sz.cols);
        const lines = modal.bodyLineCount(body);
        const g = modal.geometry(layout.rows, layout.cols, lines, buttons.len);
        const frame = modal.render(allocator, g, title, body, &buttons, sel, false) catch return false;
        defer allocator.free(frame);
        paintModalFrame(stdout, g, frame) catch return false;

        switch (nextEvent(stdin)) {
            .enter => return sel == 0,
            .history_prev, .up => sel = if (sel == 0) buttons.len - 1 else sel - 1,
            .history_next, .down => sel = (sel + 1) % buttons.len,
            .byte => |b| switch (b) {
                '1', 'y', 'Y' => return true,
                '2', 'n', 'N' => return false,
                else => {},
            },
            .esc, .interrupt, .quit, .ctrl_d, .eof => return false,
            else => {},
        }
    }
}

pub const perm_sheet = [_]slash.Spec{
    .{ .name = "1", .help = "Allow once" },
    .{ .name = "2", .help = "Always allow this" },
    .{ .name = "3", .help = "Don't allow" },
};
/// Full command map. Shown from /help, not at startup.
pub const feature_sheet =
    \\On an empty prompt, Tab moves into the chat history
    \\  j/k move  e see everything  n/p jump sections  E open all  y copy  esc back
    \\ctrl-q asks before leaving
    \\slash
    \\  /help /login /logout /models /model /fast /effort /plan /yolo
    \\  /permissions /allowlist /sandbox /status /stats /usage /settings /thinking
    \\  /web /browser /reload /mcp /init /workspace /undo /copy /diagram
    \\  /session /resume /clear /reset /rename /compact /rewind /fork
    \\  /peers /files /background /trace /feedback /quit
    \\tools (via the model, or !cmd for bash)
    \\  read write edit bash glob grep list copy mkdir delete rename
    \\  file_info open_file semantic_search web_fetch web_scrape web_search
    \\  ask_user memory browser peer board mcp patch compact
    \\keys  Enter:send  Shift+Tab:mode  Ctrl+:shortcuts  ctrl-q leave  ?:keys
    \\
;
/// Re-exported so `tui.Event` and friends keep working across the split.
pub const draft_mod = @import("draft.zig");

pub const Click = events.Click;
pub const Event = events.Event;
pub const Perm = events.Perm;
pub const takeEvent = events.takeEvent;
pub const pollEvent = events.pollEvent;
pub const nextEvent = events.nextEvent;
pub const arm_quit_ms = draft_mod.arm_quit_ms;
pub const arm_esc_ms = draft_mod.arm_esc_ms;

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

test "perm sheet offers allow once, always, and don't allow" {
    try std.testing.expectEqual(@as(usize, 3), perm_sheet.len);
    try std.testing.expectEqualStrings("1", perm_sheet[0].name);
    try std.testing.expectEqualStrings("3", perm_sheet[2].name);
    try std.testing.expect(std.mem.indexOf(u8, perm_sheet[0].help, "Allow once") != null);
    try std.testing.expect(std.mem.indexOf(u8, perm_sheet[1].help, "Always") != null);
    try std.testing.expect(std.mem.indexOf(u8, perm_sheet[2].help, "Don't allow") != null);
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

test "the idle tab names the workspace and the model" {
    var buf: [96]u8 = undefined;
    const s = idleTitleSeq(&buf, "/Users/x/Downloads/ffx", "grok-composer-2.5-fast");
    try std.testing.expect(std.mem.indexOf(u8, s, "ffx") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "grok-composer-2.5-fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Downloads") == null);
    // No model resolved yet is a name, not a half-drawn title.
    try std.testing.expectEqualStrings(tab_title_idle, idleTitleSeq(&buf, "", ""));
}
