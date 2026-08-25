const std = @import("std");
const Io = std.Io;

const slash = @import("../../core/slash.zig");
const layout_mod = @import("layout.zig");

pub const Layout = layout_mod.Layout;

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
    .{ .name = "n p", .help = "scrollback: next / previous section in a long change", .section = "Scrollback" },
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
    .{ .name = "ctrl-n", .help = "start a fresh chat (asks first)", .section = "Session" },
    .{ .name = "ctrl-q", .help = "leave omfx (asks first); ctrl-d on empty also", .section = "Session" },
    .{ .name = "ctrl-c", .help = "leave right away", .section = "Session" },
    .{
        .name = "esc esc",
        .help = "clear what you typed, or go back if empty",
        .section = "Session",
        .detail = "First press clears what you are typing (after you confirm). On an empty box it asks to go back to an earlier message — useful if the last reply did something you did not want.",
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
pub const PickKind = enum { none, providers, models, efforts, sessions, mcp, login, web, commands };

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
    const search = @import("../../tools/search.zig");
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

test "a bare letter is only ever a scrollback binding" {
    // In the composer a letter is text, never a command; the vim keys exist
    // only while the keyboard is in the scrollback, and the sheet must say so.
    const letters = [_][]const u8{ "j k", "e enter", "n p", "h l", "E", "g G", "y" };
    for (keys_sheet) |row| {
        for (letters) |l| {
            if (!std.mem.eql(u8, row.name, l)) continue;
            try std.testing.expect(std.mem.startsWith(u8, row.help, "scrollback:"));
        }
        try std.testing.expect(std.mem.indexOf(u8, row.help, "scroll focused") == null);
    }
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

test "ctrl-c leaves right away in the keys sheet" {
    var found = false;
    for (keys_sheet) |row| {
        if (std.mem.eql(u8, row.name, "ctrl-c")) {
            try std.testing.expectEqualStrings("leave right away", row.help);
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

test "the picker shrinks to its matches and caps at five" {
    const layout = Layout.compute(24, 80);
    try std.testing.expectEqual(@as(u16, 80), paletteWidth(80));
    // A filter that leaves two rows draws a two-row box, not five.
    try std.testing.expectEqual(@as(u16, 2), paletteItemRows(layout, 2));
    try std.testing.expectEqual(@as(u16, 5), paletteItemRows(layout, 5));
    // Past the cap it scrolls rather than growing.
    try std.testing.expectEqual(@as(u16, 5), paletteItemRows(layout, 40));
    // The band follows the box, so the transcript is not left with a hole.
    try std.testing.expect(paletteBandRows(layout, 2) < paletteBandRows(layout, 12));
}
