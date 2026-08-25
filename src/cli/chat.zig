const std = @import("std");
const Tool = @import("../core/tool.zig");
const paint = @import("../core/ansi.zig");
const activity = @import("activity.zig");
const measure = @import("width.zig");
const mermaid = @import("../core/mermaid.zig");
const diffview = @import("diffview.zig");

pub const max_preview: usize = 12;
pub const max_diff_preview: usize = diffview.collapsed_cap;

pub const Status = enum { run, ok, err, deny };

pub const Verb = struct {
    run: []const u8,
    done: []const u8,
};

pub fn verbFor(name: []const u8) Verb {
    const n = Tool.Name.fromSlice(name) orelse return .{ .run = "Running", .done = "Ran" };
    return switch (n) {
        .read, .open_file, .file_info => .{ .run = "Reading", .done = "Read" },
        .write => .{ .run = "Writing", .done = "Wrote" },
        .edit, .patch => .{ .run = "Editing", .done = "Edited" },
        .bash => .{ .run = "Running", .done = "Ran" },
        .grep, .glob, .semantic_search, .web_search => .{ .run = "Searching", .done = "Searched" },
        .list => .{ .run = "Listing", .done = "Listed" },
        .web_fetch => .{ .run = "Fetching", .done = "Fetched" },
        .web_scrape => .{ .run = "Scraping", .done = "Scraped" },
        .mcp => .{ .run = "Calling", .done = "Called" },
        .memory => .{ .run = "Remembering", .done = "Remembered" },
        .copy, .mkdir, .delete, .rename => .{ .run = "Changing", .done = "Changed" },
        .ask_user => .{ .run = "Asking", .done = "Asked" },
        .browser => .{ .run = "Browsing", .done = "Browsed" },
        .peer => .{ .run = "Delegating", .done = "Delegated" },
        .board => .{ .run = "Posting", .done = "Posted" },
        .compact => .{ .run = "Compacting", .done = "Compacted" },
        .todo => .{ .run = "Planning", .done = "Tasks" },
        .job => .{ .run = "Checking", .done = "Checked" },
        .read_result => .{ .run = "Re-reading", .done = "Re-read" },
    };
}

pub fn statusOf(done: bool, body: []const u8) Status {
    if (!done) return .run;
    if (std.mem.startsWith(u8, body, "permission denied") or std.mem.startsWith(u8, body, "denied "))
        return .deny;
    if (std.mem.startsWith(u8, body, "tool error:") or std.mem.startsWith(u8, body, "(FAIL"))
        return .err;
    return .ok;
}

fn mark(st: Status) []const u8 {
    return switch (st) {
        .run => "\u{25cc}",
        .ok => "\u{2713}",
        .err => "\u{2717}",
        .deny => "\u{2298}",
    };
}

pub fn clipCols(src: []const u8, cols: u16) []const u8 {
    if (cols == 0) return src[0..0];
    if (measure.cellsTo(src) <= cols) return src;
    return src[0..measure.indexAtCell(src, cols)];
}

pub const FormatError = error{OutOfMemory};
const markdown = @import("markdown.zig");
pub const Markdown = markdown.Markdown;
pub const formatAssistant = markdown.formatAssistant;
pub const inlineCells = markdown.inlineCells;
pub const clipInline = markdown.clipInline;

/// User turn: blank row, accent gutter, wrapped text, blank row.
/// A gutter reads as "mine" at a glance without a box or a fill fighting the
/// transcript for contrast.
pub fn formatUser(allocator: std.mem.Allocator, cols: u16, text: []const u8) FormatError![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const body: []const u8 = if (trimmed.len == 0) " " else trimmed;
    const width: u16 = if (cols < 8) 8 else cols;
    const text_w: u16 = width - 2;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '\n');
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        var rest = raw;
        while (true) {
            const take = clipCols(rest, text_w);
            rest = rest[take.len..];
            try out.appendSlice(allocator, paint.accent_dim);
            try out.appendSlice(allocator, "\u{258c}");
            try out.appendSlice(allocator, paint.reset);
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, paint.user_fg);
            try out.appendSlice(allocator, take);
            try out.appendSlice(allocator, paint.reset);
            try out.append(allocator, '\n');
            if (rest.len == 0) break;
        }
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

pub fn looksLikeDiff(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "\n@@ ") != null or std.mem.startsWith(u8, body, "@@ ")) return true;
    if (std.mem.indexOf(u8, body, "\ndiff --git ") != null or std.mem.startsWith(u8, body, "diff --git ")) return true;
    if (std.mem.indexOf(u8, body, "\n+++ ") != null and std.mem.indexOf(u8, body, "\n--- ") != null) return true;
    return false;
}

/// Unified diff: + mint, - red, @@ cyan. Collapsed by default; open the call for full.
pub fn formatDiff(allocator: std.mem.Allocator, cols: u16, src: []const u8) ![]u8 {
    return diffview.render(allocator, cols, src, false);
}

/// Full colored diff (no line cap). `focus_hunk` highlights one @@ header.
pub fn formatDiffExpanded(allocator: std.mem.Allocator, cols: u16, src: []const u8, focus_hunk: ?usize) ![]u8 {
    return diffview.renderFocus(allocator, cols, src, true, focus_hunk);
}

fn previewLines(body: []const u8, cap: usize, shown: *usize, total: *usize) []const u8 {
    shown.* = 0;
    total.* = 0;
    if (body.len == 0) return body;
    var i: usize = 0;
    var last: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\n') {
            total.* += 1;
            if (shown.* < cap) {
                shown.* += 1;
                last = i + 1;
            }
        }
    }
    if (body.len > 0 and body[body.len - 1] != '\n') total.* += 1;
    if (total.* <= cap) {
        shown.* = total.*;
        return body;
    }
    if (shown.* == 0) return body[0..@min(body.len, 80)];
    return body[0..last];
}

/// Whether a run of this tool is worth collapsing.
///
/// Exhaustive rather than a default, so a new tool has to state its intent.
/// The ones excluded are those whose output *is* the answer the user asked
/// for -- collapsing a web search or a peer report hides the point of it.
pub fn groupable(name: []const u8) bool {
    const t = Tool.Name.fromSlice(name) orelse return false;
    return switch (t) {
        .read, .open_file, .file_info, .list, .glob, .grep, .semantic_search, .bash, .edit, .patch, .write, .copy, .mkdir, .rename, .delete, .memory, .job, .read_result => true,
        .web_fetch, .web_scrape, .web_search, .ask_user, .browser, .peer, .board, .mcp, .compact, .todo => false,
    };
}

/// A run of consecutive calls to the same tool, shown as one row.
///
/// Ten `bash` cards in a row is ten near-identical lines the reader scrolls
/// past; "Ran 5 shell commands" is the same information in one. The detail is
/// not thrown away -- `expanded` draws every call under a tree extender, which
/// is what the toggle in the transcript flips.
pub const Group = struct {
    name: []const u8,
    /// Most recent argument, shown on the collapsed row so it is not opaque.
    last_detail: []const u8 = "",
    count: usize = 1,
    status: Status = .ok,
    expanded: bool = false,
    selected: bool = false,

    /// Whether a call belongs to the run currently open.
    pub fn accepts(self: Group, name: []const u8) bool {
        return self.count > 0 and std.mem.eql(u8, self.name, name);
    }
};

/// The collapsed summary row, with a disclosure marker.
///
/// `▸`/`▾` is the affordance: it says the detail exists and is one keypress
/// away, which a bare count does not.
pub fn formatGroup(allocator: std.mem.Allocator, cols: u16, g: Group) FormatError![]u8 {
    const color: []const u8 = switch (g.status) {
        .run => paint.muted,
        .ok => paint.accent_dim,
        .err, .deny => paint.del_fg,
    };
    var head: [96]u8 = undefined;
    const t = Tool.Name.fromSlice(g.name) orelse .bash;
    const said = activity.pastPhrase(&head, t, g.last_detail, g.count);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, color);
    if (g.selected) try out.appendSlice(allocator, paint.sel_bg);
    // No caret on a run with nothing under it: an arrow that does not open
    // is an affordance that lies. One call is already fully described by the
    // summary row it sits on.
    try out.appendSlice(allocator, if (g.count < 2) " " else if (g.expanded) "\u{25be}" else "\u{25b8}");
    if (g.selected) try out.appendSlice(allocator, paint.reset);
    try out.appendSlice(allocator, color);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, clipCols(said, if (cols > 4) cols - 4 else cols));
    try out.appendSlice(allocator, paint.reset);
    if (!g.expanded and g.last_detail.len != 0) {
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, clipCols(g.last_detail, if (cols > 40) cols - 34 else 8));
        try out.appendSlice(allocator, paint.reset);
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// One call inside an expanded group: a tree extender and the argument.
///
/// The `└` matches what a reader expects from a tree, and the indent makes the
/// run scannable as a unit rather than as loose lines.
pub fn formatGroupChild(
    allocator: std.mem.Allocator,
    cols: u16,
    name: []const u8,
    detail: []const u8,
    last: bool,
    open: bool,
) FormatError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, paint.border);
    try out.appendSlice(allocator, if (last) "  \u{2514} " else "  \u{251c} ");
    try out.appendSlice(allocator, paint.reset);
    // An open child gets the same caret the parent uses, so one glyph means
    // one thing everywhere in the tree.
    try out.appendSlice(allocator, if (open) paint.accent_dim else paint.muted);
    if (open) try out.appendSlice(allocator, "\u{25be} ");
    // The call as it was made: tool name, then its argument in brackets. The
    // argument alone drew a lone dot for a `list` of ".", and a past-tense
    // verb read as prose rather than as the call it stands for.
    try out.appendSlice(allocator, name);
    try out.append(allocator, '(');
    const used: u16 = @intCast(@min(cols, 11 + name.len));
    try out.appendSlice(allocator, clipCols(detail, cols -| used));
    try out.append(allocator, ')');
    try out.appendSlice(allocator, paint.reset);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Receipt: a `git status` is ~500 bytes and a build log runs to megabytes.
/// Twelve lines is the most that reads as part of a tree rather than as a
/// wall, and the row that follows says what was cut.
pub const child_body_lines: usize = 12;

/// The output of one opened call, indented under it.
/// Diffs paint in full colour (the summary card already showed the collapse).
/// Plain text stays capped so a huge bash dump does not flood the pane.
pub fn formatChildBody(
    allocator: std.mem.Allocator,
    cols: u16,
    body: []const u8,
    last: bool,
) FormatError![]u8 {
    return formatChildBodyFocus(allocator, cols, body, last, null);
}

pub fn formatChildBodyFocus(
    allocator: std.mem.Allocator,
    cols: u16,
    body: []const u8,
    last: bool,
    focus_hunk: ?usize,
) FormatError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // A run that is still open needs its trunk drawn past this block; the
    // last one has nothing below it, so the gutter goes blank.
    const trunk: []const u8 = if (last) "    " else "  \u{2502} ";
    const room = if (cols > 10) cols - 10 else cols;
    const text = std.mem.trimEnd(u8, body, "\n");
    if (text.len == 0) {
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, trunk);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, "  no output");
        try out.appendSlice(allocator, paint.reset);
        try out.append(allocator, '\n');
        return out.toOwnedSlice(allocator);
    }
    if (looksLikeDiff(text)) {
        const painted = try formatDiffExpanded(allocator, if (cols > 4) cols - 4 else cols, text, focus_hunk);
        defer allocator.free(painted);
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, painted, "\n"), '\n');
        while (it.next()) |line| {
            try out.appendSlice(allocator, paint.border);
            try out.appendSlice(allocator, trunk);
            try out.appendSlice(allocator, paint.reset);
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        if (n == child_body_lines) break;
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, trunk);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.dim);
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, clipCols(line, room));
        try out.appendSlice(allocator, paint.reset);
        try out.append(allocator, '\n');
        n += 1;
    }
    const total = std.mem.count(u8, text, "\n") + 1;
    if (total > n) {
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, trunk);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.muted);
        try out.print(allocator, "  {d} more lines", .{total - n});
        try out.appendSlice(allocator, paint.reset);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// Tool card: verb + path/command, then truncated body or a diff.
pub fn formatTool(
    allocator: std.mem.Allocator,
    cols: u16,
    name: []const u8,
    detail: []const u8,
    done: bool,
    body: []const u8,
) ![]u8 {
    const st = statusOf(done, body);
    const v = verbFor(name);
    const word = if (st == .run) v.run else v.done;

    const color: []const u8 = switch (st) {
        .run => paint.muted,
        .ok => paint.accent_dim,
        .err, .deny => paint.del_fg,
    };
    // Mark and verb carry the state; the argument is context, so it stays quiet.
    const head_w: u16 = if (cols > 4) cols - 4 else cols;
    var head_buf: [220]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "{s} {s}", .{ mark(st), word }) catch word;
    const detail_w: u16 = if (head_w > head.len) head_w - @as(u16, @intCast(head.len)) - 1 else 0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, color);
    try out.appendSlice(allocator, clipCols(head, head_w));
    try out.appendSlice(allocator, paint.reset);
    if (detail.len != 0 and detail_w != 0) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, clipCols(detail, detail_w));
        try out.appendSlice(allocator, paint.reset);
    }
    try out.append(allocator, '\n');

    if (st == .run or body.len == 0) return out.toOwnedSlice(allocator);

    // The task list styles itself and is the point of the card, so it is not
    // gutter-indented and not subject to the body preview cap.
    if (Tool.Name.fromSlice(name) == .todo) {
        try out.appendSlice(allocator, body);
        if (body.len != 0 and body[body.len - 1] != '\n') try out.append(allocator, '\n');
        return out.toOwnedSlice(allocator);
    }

    if (looksLikeDiff(body)) {
        const painted = try formatDiff(allocator, cols, body);
        defer allocator.free(painted);
        try out.appendSlice(allocator, painted);
        return out.toOwnedSlice(allocator);
    }

    var shown: usize = 0;
    var total: usize = 0;
    const slice = previewLines(body, max_preview, &shown, &total);
    var it = std.mem.splitScalar(u8, slice, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "│");
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, clipCols(line, if (cols > 4) cols - 4 else cols));
        try out.appendSlice(allocator, paint.reset);
        try out.append(allocator, '\n');
    }
    if (total > max_preview) {
        var buf: [40]u8 = undefined;
        const more = std.fmt.bufPrint(&buf, "{s}  … {d} more{s}\n", .{ paint.dim, total - max_preview, paint.reset }) catch "  …\n";
        try out.appendSlice(allocator, more);
    }
    return out.toOwnedSlice(allocator);
}

/// Cells the left rule occupies, so wrap stays inside the pane.
pub const think_gutter_cells: u16 = 2;

/// Prefix every thinking row, not every token. Per-chunk indent doubled
/// spaces between streamed words (`The  user  just`).
const think_bar = paint.border ++ "\u{2502} " ++ paint.reset;

fn thinkOpenRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, col: *u16) !void {
    try out.appendSlice(allocator, think_bar);
    try out.appendSlice(allocator, paint.muted);
    try out.appendSlice(allocator, paint.italic);
    col.* = think_gutter_cells;
}

/// How much of a word is held back before the wrap gives up and splits it.
/// A real word is nowhere near this; a base64 blob is, and it must still move.
const think_word_cap: usize = 48;

/// Thinking wrap state. The column alone was not enough: a row break decided
/// on the rune in hand lands inside whatever word the provider happened to
/// split its chunk on, so the word being spelled is held back until it ends.
pub const Think = struct {
    col: u16 = 0,
    buf: [think_word_cap]u8 = undefined,
    len: usize = 0,
    cells: u16 = 0,
    /// A space waiting for the word that follows it. Held too, so a break lands
    /// on the gap instead of leaving the space stranded at the row end.
    space: bool = false,
};

fn thinkBreak(out: *std.ArrayList(u8), allocator: std.mem.Allocator, st: *Think) !void {
    try out.appendSlice(allocator, paint.reset);
    try out.append(allocator, '\n');
    st.col = 0;
    st.space = false;
}

fn thinkWord(out: *std.ArrayList(u8), allocator: std.mem.Allocator, st: *Think, limit: u16) !void {
    std.debug.assert(st.len <= st.buf.len);
    // Every row opens with the gutter, so a limit past it leaves at least one
    // cell of room and the split loop below always advances.
    std.debug.assert(limit > think_gutter_cells);
    if (st.len == 0) return;
    const gap: u16 = if (st.space and st.col > think_gutter_cells) 1 else 0;
    if (st.col > think_gutter_cells and st.col + gap + st.cells > limit) try thinkBreak(out, allocator, st);
    if (st.space and st.col > think_gutter_cells) {
        try out.append(allocator, ' ');
        st.col += 1;
    }
    st.space = false;
    // Aliases the buffer the emptied counters describe: nothing below refills
    // it, so the slice stays the word this call is placing.
    var rest = st.buf[0..st.len];
    st.len = 0;
    st.cells = 0;
    // A word wider than a whole row still has to be split somewhere.
    while (rest.len != 0) {
        if (st.col == 0) try thinkOpenRow(out, allocator, &st.col);
        const room: u16 = if (limit > st.col) limit - st.col else 1;
        const cut = measure.indexAtCell(rest, room);
        const take = if (cut == 0) rest[0..measure.utf8LenAt(rest, 0)] else rest[0..cut];
        try out.appendSlice(allocator, take);
        st.col +|= measure.cellsTo(take);
        rest = rest[take.len..];
        if (rest.len != 0) try thinkBreak(out, allocator, st);
    }
}

fn thinkLimit(cols: u16) u16 {
    return if (cols > think_gutter_cells) cols else think_gutter_cells + 1;
}

/// Stream one thinking chunk into a quote-style block. `st` carries the row
/// and the unfinished word across tokens, so wrap and gutter survive a chunk
/// boundary that falls anywhere.
pub fn formatThink(allocator: std.mem.Allocator, cols: u16, chunk: []const u8, st: *Think) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const limit = thinkLimit(cols);
    try out.appendSlice(allocator, paint.muted);
    try out.appendSlice(allocator, paint.italic);
    const head = out.items.len;

    var i: usize = 0;
    while (i < chunk.len) {
        const c = chunk[i];
        if (c == '\n' or c == '\r') {
            try thinkWord(&out, allocator, st, limit);
            try thinkBreak(&out, allocator, st);
            i += 1;
            if (i < chunk.len and c == '\r' and chunk[i] == '\n') i += 1;
            continue;
        }
        if (c == ' ' or c == '\t') {
            try thinkWord(&out, allocator, st, limit);
            if (st.col > think_gutter_cells) st.space = true;
            i += 1;
            continue;
        }
        const n = measure.utf8LenAt(chunk, i);
        if (n == 0) break;
        if (st.len + n > think_word_cap) try thinkWord(&out, allocator, st, limit);
        @memcpy(st.buf[st.len..][0..n], chunk[i .. i + n]);
        st.len += n;
        st.cells +|= measure.runeWidth(measure.runeAt(chunk, i));
        i += n;
    }
    // A chunk that only lengthened the held-back word paints nothing, and the
    // style bytes on their own would still be committed to the transcript.
    if (out.items.len == head) {
        out.clearRetainingCapacity();
        return out.toOwnedSlice(allocator);
    }
    try out.appendSlice(allocator, paint.reset);
    return out.toOwnedSlice(allocator);
}

/// The block is over: whatever word was held back has to land.
pub fn flushThink(allocator: std.mem.Allocator, cols: u16, st: *Think) ![]u8 {
    if (st.len == 0) return allocator.alloc(u8, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, paint.muted);
    try out.appendSlice(allocator, paint.italic);
    try thinkWord(&out, allocator, st, thinkLimit(cols));
    try out.appendSlice(allocator, paint.reset);
    return out.toOwnedSlice(allocator);
}

pub const think_open = paint.think_open;
pub const think_close = paint.think_close;

/// The line range a `read` covered, from its own numbered output.
///
/// Taken from the result rather than from the arguments: `offset` and `limit`
/// are what was asked for, and a short file or a cap makes the two differ.
/// The row should say what was read.
pub fn lineSpan(body: []const u8) ?struct { from: usize, to: usize } {
    const first = leadingNumber(body) orelse return null;
    var last = first;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (leadingNumber(line)) |n| last = n;
    }
    return .{ .from = first, .to = last };
}

/// The `{d: >6}\t` prefix `fs.read` writes, or null for any other line.
fn leadingNumber(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == start or i >= line.len or line[i] != '\t') return null;
    return std.fmt.parseInt(usize, line[start..i], 10) catch null;
}

/// One task in the pinned list.
///
/// The mark carries the state and the colour carries the emphasis: exactly
/// one task is in progress at a time, so it is the only one that reads at
/// full weight, and a finished task is struck through rather than removed so
/// the shape of the work stays visible.
pub fn formatTodo(allocator: std.mem.Allocator, cols: u16, text: []const u8, active: bool, done: bool) FormatError![]u8 {
    const glyph: []const u8 = if (done) "\u{2713}" else if (active) "\u{25d0}" else "\u{25cb}";
    const color: []const u8 = if (done) paint.muted else if (active) paint.accent_dim else paint.dim;
    return std.fmt.allocPrint(allocator, "  {s}{s} {s}{s}\n", .{
        color,
        glyph,
        clipCols(text, if (cols > 6) cols - 6 else cols),
        paint.reset,
    });
}

/// A one-line status the harness is asserting, not the model: interrupted,
/// rewound, compacted. Marked so it cannot be mistaken for a reply.
pub fn formatNotice(allocator: std.mem.Allocator, cols: u16, text: []const u8) FormatError![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{25a0} {s}{s}\n", .{
        paint.warn,
        clipCols(text, if (cols > 2) cols - 2 else cols),
        paint.reset,
    });
}

/// A command's answer: what `/effort`, `/models`, `/status` and the rest say
/// back.
///
/// Quiet on purpose. This is the harness talking about itself, not the model
/// answering, so it takes the muted colour and the same two-column gutter as
/// everything else in the transcript. Raw text at column zero read like a
/// crash dump next to the styled rows around it.
pub fn formatCommand(allocator: std.mem.Allocator, cols: u16, text: []const u8) ![]u8 {
    const body = std.mem.trimEnd(u8, text, "\n");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const room = if (cols > gutter_cells) cols - gutter_cells else cols;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, clipCols(line, room));
        try out.appendSlice(allocator, paint.reset);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// The two columns every transcript row opens with.
pub const gutter_cells: u16 = 2;

test "a command answer is quiet, indented, and never raw" {
    const a = std.testing.allocator;
    const out = try formatCommand(a, 60, "Using Grok 4.5.  500k context\neffort: low\n");
    defer a.free(out);
    // Same gutter as every other transcript row.
    try std.testing.expect(std.mem.startsWith(u8, out, "  "));
    try std.testing.expect(std.mem.indexOf(u8, out, paint.muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Using Grok 4.5.") != null);
    // Two lines in, two lines out: the trailing newline is not a third row.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    // Every row is styled, not just the first.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, paint.muted));
}

test "a long command answer is clipped inside the gutter" {
    const a = std.testing.allocator;
    const long = "x" ** 200;
    const out = try formatCommand(a, 40, long);
    defer a.free(out);
    // 40 cells minus the gutter, so the row cannot push the pane sideways.
    try std.testing.expectEqual(@as(usize, 40 - gutter_cells), std.mem.count(u8, out, "x"));
}

test "a todo card keeps its own styling and skips the preview cap" {
    const todos = @import("../core/todos.zig");
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "{\"todos\":[");
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        if (i != 0) try body.append(a, ',');
        try body.print(a, "\"task {d}\"", .{i});
    }
    try body.appendSlice(a, "]}");
    const card = try todos.set(a, body.items);
    defer a.free(card);

    const out = try formatTool(a, 80, "todo", "", true, card);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "task 14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "more") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│  ") == null);
}

test "formatNotice is marked and not a reply" {
    const s = try formatNotice(std.testing.allocator, 40, "Interrupted");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Interrupted") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "■") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.warn) != null);
}

test "fenced code renders as a plate, not a bare rule" {
    const s = try formatAssistant(std.testing.allocator, 40, "before\n```zig\nconst x = 1;\n```\nafter\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "const") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "x = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.code_bg) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "╰") != null);
}

test "long code lines wrap instead of losing code" {
    const long = "x" ** 90;
    const s = try formatAssistant(std.testing.allocator, 40, "```\n" ++ long ++ "\n```\n");
    defer std.testing.allocator.free(s);
    var found: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, "x")) |at| : (i = at + 1) found += 1;
    try std.testing.expectEqual(long.len, found);
}

test "markdown inside a fence stays literal" {
    const s = try formatAssistant(std.testing.allocator, 40, "```\n# not a heading\n- not a bullet\n```\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "# not a heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "- not a bullet") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "• ") == null);
}

test "streaming line by line matches the replayed block" {
    const reply = "# Title\ntext with `code`\n```zig\nfn main() void {}\n# still code\n```\n| a | b |\n|---|---|\n| 1 | 2 |\n- item\n";
    const whole = try formatAssistant(std.testing.allocator, 60, reply);
    defer std.testing.allocator.free(whole);

    var md = Markdown{ .cols = 60 };
    defer md.deinit(std.testing.allocator);
    var streamed: std.ArrayList(u8) = .empty;
    defer streamed.deinit(std.testing.allocator);
    // The live pane never flushes the empty tail after the last newline, so
    // neither does the replay it has to match.
    var it = std.mem.splitScalar(u8, reply[0 .. reply.len - 1], '\n');
    while (it.next()) |src| {
        const painted = try md.line(std.testing.allocator, src);
        defer std.testing.allocator.free(painted);
        try streamed.appendSlice(std.testing.allocator, painted);
    }
    try std.testing.expectEqualStrings(whole, streamed.items);
}

test "peek does not advance fence state" {
    var md = Markdown{ .cols = 40 };
    defer md.deinit(std.testing.allocator);
    const half = try md.peek(std.testing.allocator, "```zig");
    defer std.testing.allocator.free(half);
    try std.testing.expect(!md.in_fence);
    const committed = try md.line(std.testing.allocator, "```zig");
    defer std.testing.allocator.free(committed);
    try std.testing.expect(md.in_fence);
    try std.testing.expectEqualStrings(half, committed);
}

test "table rows lose the pipe rule and gain a header" {
    const s = try formatAssistant(std.testing.allocator, 60, "| File | Lines |\n|------|-------|\n| a.zig | 12 |\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "|------|") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "File") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "│") != null);
}

test "ordered lists and quotes keep their shape" {
    const s = try formatAssistant(std.testing.allocator, 60, "1. first\n2. second\n> quoted\n  - nested\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "1. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "2. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "┃") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "◦ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "nested") != null);
}

test "formatUser wraps instead of clipping to one row" {
    const s = try formatUser(std.testing.allocator, 16, "hello from the other side");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "hello from the") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "other side") != null);
    var gutters: usize = 0;
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == 0xe2 and s[i + 1] == 0x96 and s[i + 2] == 0x8c) gutters += 1;
    }
    try std.testing.expect(gutters >= 2);
}

test "formatUser keeps a blank row above and below" {
    const s = try formatUser(std.testing.allocator, 40, "hey");
    defer std.testing.allocator.free(s);
    try std.testing.expect(s[0] == '\n');
    try std.testing.expect(std.mem.indexOf(u8, s, "hey") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.accent_dim) != null);
    try std.testing.expect(std.mem.endsWith(u8, s, "\n\n"));
}

test "formatDiff colors add and delete" {
    const src =
        \\--- a/x
        \\+++ b/x
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-old
        \\+new
    ;
    const s = try formatDiff(std.testing.allocator, 40, src);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.add_fg) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.del_fg) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.hunk) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "+new") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "-old") != null);
}

test "formatTool uses Reading and truncates" {
    const s = try formatTool(std.testing.allocator, 40, "read", "src/foo.zig", false, "");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Reading") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "src/foo.zig") != null);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try body.appendSlice(std.testing.allocator, "line\n");
    }
    const d = try formatTool(std.testing.allocator, 40, "bash", "ls", true, body.items);
    defer std.testing.allocator.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "Ran") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "more") != null);
}

test "formatTool routes diffs to formatDiff" {
    const body = "@@ -1 +1 @@\n-old\n+new\n";
    const s = try formatTool(std.testing.allocator, 40, "edit", "a.zig", true, body);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Edited") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.add_fg) != null);
}

test "formatAssistant paints heading list fence and code" {
    const s = try formatAssistant(std.testing.allocator, 80, "# Title\n- item\n```\ncode\n```\nuse `x` here\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "•") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "──") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.rule) != null);
}

/// Rows as a reader sees them: styling stripped, so a test can assert on the
/// text and the row breaks instead of on escape bytes.
fn plainRows(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        const skip = measure.skipEsc(src, i);
        if (skip != i) {
            i = skip;
            continue;
        }
        try out.append(a, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn thinkAll(a: std.mem.Allocator, cols: u16, chunks: []const []const u8) ![]u8 {
    var st: Think = .{};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (chunks) |c| {
        const painted = try formatThink(a, cols, c, &st);
        defer a.free(painted);
        try out.appendSlice(a, painted);
    }
    const tail = try flushThink(a, cols, &st);
    defer a.free(tail);
    try out.appendSlice(a, tail);
    return out.toOwnedSlice(a);
}

test "thinking chunks do not indent every token" {
    const a = std.testing.allocator;
    const painted = try thinkAll(a, 80, &.{ "The", " user", " asked" });
    defer a.free(painted);
    const s = try plainRows(a, painted);
    defer a.free(s);
    try std.testing.expectEqualStrings("\u{2502} The user asked", s);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "\u{2502}"));
}

test "a chunk boundary inside a word does not break the row inside it" {
    const a = std.testing.allocator;
    // 12 cells of room after the gutter: "before " fills the first row and
    // the chunk splits "afterward" in half, which must still land whole.
    const painted = try thinkAll(a, 14, &.{ "before af", "terward" });
    defer a.free(painted);
    const s = try plainRows(a, painted);
    defer a.free(s);
    try std.testing.expectEqualStrings("\u{2502} before\n\u{2502} afterward", s);
}

test "thinking wraps with a gutter on the next row" {
    const a = std.testing.allocator;
    const s = try thinkAll(a, 8, &.{"abcdefghij"});
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\n") != null);
    var guts: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, "\u{2502}")) |at| {
        guts += 1;
        i = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), guts);
}

test "emphasis is colour, never weight" {
    const s = try formatAssistant(std.testing.allocator, 80, "### What I'm good at\nI'm **omfx**, a local agent.\n");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "What I'm good at") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "###") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "omfx") != null);
    // Bold thickens glyphs without lifting them off the line; the accent is
    // what the eye already looks for in this palette.
    try std.testing.expect(std.mem.indexOf(u8, s, paint.bold) == null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.accent_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.accent) != null);
}

test "verbFor covers every tool name" {
    inline for (std.meta.tags(Tool.Name)) |tag| {
        const v = verbFor(@tagName(tag));
        try std.testing.expect(v.run.len > 0);
        try std.testing.expect(v.done.len > 0);
    }
}

test "statusOf maps deny and error" {
    try std.testing.expectEqual(Status.run, statusOf(false, "x"));
    try std.testing.expectEqual(Status.ok, statusOf(true, "hello"));
    try std.testing.expectEqual(Status.deny, statusOf(true, "permission denied\n"));
    try std.testing.expectEqual(Status.err, statusOf(true, "tool error: Broken"));
}

test "a run of the same tool collapses to one row" {
    const a = std.testing.allocator;
    const s = try formatGroup(a, 80, .{ .name = "bash", .last_detail = "zig build test", .count = 5 });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Ran the test suite") != null);
    // Collapsed rows carry the disclosure marker and the latest argument.
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{25b8}") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "zig build test") != null);
}

test "an expanded group flips the marker and drops the inline detail" {
    const a = std.testing.allocator;
    const s = try formatGroup(a, 80, .{ .name = "bash", .last_detail = "ls -la", .count = 3, .expanded = true });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{25be}") != null);
    // The children carry the detail once expanded, so the header stops repeating it.
    try std.testing.expect(std.mem.indexOf(u8, s, "ls -la") == null);
}

test "children draw a tree, with the last one closing it" {
    const a = std.testing.allocator;
    const mid = try formatGroupChild(a, 80, "bash", "git status", false, false);
    defer a.free(mid);
    const end = try formatGroupChild(a, 80, "bash", "git diff", true, false);
    defer a.free(end);
    try std.testing.expect(std.mem.indexOf(u8, mid, "\u{251c}") != null);
    try std.testing.expect(std.mem.indexOf(u8, end, "\u{2514}") != null);
    try std.testing.expect(std.mem.indexOf(u8, end, "git diff") != null);
}

test "a group only accepts its own tool" {
    const g = Group{ .name = "bash", .count = 2 };
    try std.testing.expect(g.accepts("bash"));
    try std.testing.expect(!g.accepts("read"));
    // An empty group starts nothing.
    try std.testing.expect(!(Group{ .name = "bash", .count = 0 }).accepts("bash"));
}

test "a failed run reads as failed even when collapsed" {
    const a = std.testing.allocator;
    const s = try formatGroup(a, 80, .{ .name = "bash", .last_detail = "x", .count = 4, .status = .err });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, paint.del_fg) != null);
}

test "only tools whose output is not the answer collapse" {
    try std.testing.expect(groupable("bash"));
    try std.testing.expect(groupable("read"));
    try std.testing.expect(groupable("edit"));
    // The output of these IS what was asked for; hiding it hides the point.
    try std.testing.expect(!groupable("web_search"));
    try std.testing.expect(!groupable("peer"));
    try std.testing.expect(!groupable("todo"));
    try std.testing.expect(!groupable("ask_user"));
    try std.testing.expect(!groupable("not-a-tool"));
}

test "assistant rows sit at the shared text column and wrap under their marker" {
    const a = std.testing.allocator;
    const s = try formatAssistant(a, 40, "Strong at\n- a bullet long enough to need a second row here\n");
    defer a.free(s);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s, "\n"), '\n');
    var rows: usize = 0;
    while (it.next()) |row| : (rows += 1) {
        try std.testing.expect(std.mem.startsWith(u8, row, "  "));
        try std.testing.expect(measure.cellsTo(row) <= 40);
    }
    // Heading, marker row, hung continuation.
    try std.testing.expectEqual(@as(usize, 3), rows);
    try std.testing.expect(std.mem.indexOf(u8, s, "\n    \x1b") != null);
}

test "a chunk that only extends the held word paints nothing" {
    const a = std.testing.allocator;
    var st: Think = .{};
    const mid = try formatThink(a, 80, "unfini", &st);
    defer a.free(mid);
    try std.testing.expectEqual(@as(usize, 0), mid.len);
    const rest = try flushThink(a, 80, &st);
    defer a.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, rest, "unfini") != null);
}

test "a table is drawn as a block, with its columns aligned" {
    const a = std.testing.allocator;
    const src =
        "| Area | Score |\n|------|------:|\n| Tool use | 9 |\n| Code edits | 8 |\n";
    const out = try formatAssistant(a, 60, src);
    defer a.free(out);
    const plain = try plainRows(a, out);
    defer a.free(plain);
    try std.testing.expectEqualStrings(
        "  \u{250c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{252c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}\n" ++
            "  \u{2502}    Area    \u{2502} Score \u{2502}\n" ++
            "  \u{251c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{253c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}\n" ++
            "  \u{2502} Tool use   \u{2502}     9 \u{2502}\n" ++
            "  \u{2502} Code edits \u{2502}     8 \u{2502}\n" ++
            "  \u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}\n",
        plain,
    );
}

test "a table wider than the pane shrinks its widest column" {
    const a = std.testing.allocator;
    const src = "| a | b |\n|---|---|\n| short | " ++ ("x" ** 60) ++ " |\n";
    const out = try formatAssistant(a, 30, src);
    defer a.free(out);
    const plain = try plainRows(a, out);
    defer a.free(plain);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, plain, "\n"), '\n');
    while (it.next()) |row| try std.testing.expect(measure.cellsTo(row) <= 30);
}

test "a reply that ends on a table still draws it" {
    const a = std.testing.allocator;
    const out = try formatAssistant(a, 40, "| a |\n|---|\n| 1 |\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1") != null);
}

test "a reply that opens with blank lines does not stack them" {
    const a = std.testing.allocator;
    const out = try formatAssistant(a, 40, "\n\nfirst\n\nsecond\n");
    defer a.free(out);
    const plain = try plainRows(a, out);
    defer a.free(plain);
    try std.testing.expectEqualStrings("  first\n\n  second\n", plain);
}

test "a mermaid fence is drawn, and anything else stays a code plate" {
    const a = std.testing.allocator;
    const drawn = try formatAssistant(a, 80, "```mermaid\ngraph LR\nA --> B\n```\n");
    defer a.free(drawn);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "\u{25b6}") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "graph LR") == null);

    const kept = try formatAssistant(a, 80, "```mermaid\nclassDiagram\nA <|-- B\n```\n");
    defer a.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "classDiagram") != null);
}

test "an unclosed mermaid fence prints its source" {
    const a = std.testing.allocator;
    const out = try formatAssistant(a, 80, "```mermaid\ngraph LR\nA --> B\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "graph LR") != null);
}

test "a table's grid reads at content weight, not chrome weight" {
    const a = std.testing.allocator;
    var md = Markdown{ .cols = 60 };
    defer md.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var it = std.mem.splitScalar(u8, "| A | B |\n| --- | --- |\n| one | two |", '\n');
    while (it.next()) |line| {
        const drawn = try md.line(a, line);
        defer a.free(drawn);
        try out.appendSlice(a, drawn);
    }
    const tail = try md.flush(a);
    defer a.free(tail);
    try out.appendSlice(a, tail);
    try std.testing.expect(std.mem.indexOf(u8, out.items, paint.grid) != null);
    // The dim chrome colour framed the content it was meant to organise.
    try std.testing.expect(std.mem.indexOf(u8, out.items, paint.border) == null);
}

test "a reply has one blank row between blocks, never two or none" {
    const a = std.testing.allocator;
    const src =
        \\First paragraph.
        \\
        \\
        \\
        \\## A heading with three blanks above it
        \\Text jammed right under the heading.
        \\
        \\Last paragraph.
        \\
        \\
    ;
    const out = try formatAssistant(a, 70, src);
    defer a.free(out);
    // No run of two blank rows survives, and none leads or trails.
    var blanks: usize = 0;
    var most: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    var rows: usize = 0;
    while (it.next()) |row| {
        rows += 1;
        if (measure.cellsTo(row) == 0) blanks += 1 else blanks = 0;
        most = @max(most, blanks);
    }
    try std.testing.expect(most <= 1);
    try std.testing.expect(rows > 0);
    try std.testing.expect(!std.mem.startsWith(u8, out, "\n"));
    // The blank the source did have between blocks is kept: collapsing to
    // zero would run the paragraphs together.
    try std.testing.expect(std.mem.indexOf(u8, out, "Last paragraph.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "First paragraph.") != null);
}

test "a read row says which lines it covered" {
    const body =
        "     1\tfirst\n" ++
        "     2\tsecond\n" ++
        "     3\tthird\n";
    const span = lineSpan(body).?;
    try std.testing.expectEqual(@as(usize, 1), span.from);
    try std.testing.expectEqual(@as(usize, 3), span.to);

    // A page from the middle reports where it actually started.
    const paged = "   250\ta\n   251\tb\n... stopped at 2 lines; read on with offset=252\n";
    const p2 = lineSpan(paged).?;
    try std.testing.expectEqual(@as(usize, 250), p2.from);
    try std.testing.expectEqual(@as(usize, 251), p2.to);

    // Anything that is not numbered output has no range to report.
    try std.testing.expect(lineSpan("(no such file)\n") == null);
    try std.testing.expect(lineSpan("") == null);
}

test "a run with one call shows no caret to open" {
    const a = std.testing.allocator;
    const one = try formatGroup(a, 80, .{ .name = "read", .last_detail = "a.zig", .count = 1 });
    defer a.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "\u{25b8}") == null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\u{25be}") == null);

    // Two calls have something to show, so the caret is earned.
    const many = try formatGroup(a, 80, .{ .name = "read", .last_detail = "b.zig", .count = 2 });
    defer a.free(many);
    try std.testing.expect(std.mem.indexOf(u8, many, "\u{25b8}") != null);
}

test "a call row reads as the call that was made" {
    const a = std.testing.allocator;
    // The shape that drew a lone dot: `list` of the workspace root.
    const dot = try formatGroupChild(a, 80, "list", ".", true, false);
    defer a.free(dot);
    try std.testing.expect(std.mem.indexOf(u8, dot, "list(.)") != null);

    // A call with no argument at all still says which tool ran.
    const bare = try formatGroupChild(a, 80, "read", "", true, false);
    defer a.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "read()") != null);

    // A long command is cut inside the brackets, not past them.
    const long = try formatGroupChild(a, 40, "bash", "x" ** 200, true, false);
    defer a.free(long);
    try std.testing.expect(std.mem.indexOf(u8, long, ")") != null);
    try std.testing.expect(std.mem.count(u8, long, "x") < 40);
    try std.testing.expect(measure.cellsTo(long) <= 40);
}

test "table cells line up whatever markup they carry" {
    const a = std.testing.allocator;
    var md = Markdown{ .cols = 78 };
    defer md.deinit(a);
    const src =
        \\| Dir | Likely contents |
        \\| --- | --- |
        \\| `src/` | Main Zig source |
        \\| **bold** | Emphasis |
        \\| `.ffx/`, `.agents/`, `.claude/` | Tooling config |
        \\| plain | Nothing special |
    ;
    var it = std.mem.splitScalar(u8, src, '\n');
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    while (it.next()) |line| {
        const drawn = try md.line(a, line);
        defer a.free(drawn);
        try out.appendSlice(a, drawn);
    }
    const tail = try md.flush(a);
    defer a.free(tail);
    try out.appendSlice(a, tail);

    // Every drawn row is the same number of visible cells: that is what makes
    // the borders form a rectangle instead of a staircase.
    var rows = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.items, "\n"), '\n');
    var want: ?u16 = null;
    while (rows.next()) |row| {
        const n = measure.cellsTo(row);
        if (want) |w| {
            if (n != w) {
                std.debug.print("row is {d} cells, table is {d}: {s}\n", .{ n, w, row });
                return error.RaggedTable;
            }
        } else want = n;
    }
    try std.testing.expect(want != null);
}
