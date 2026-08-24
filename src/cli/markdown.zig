const std = @import("std");
const paint = @import("../core/ansi.zig");
const measure = @import("width.zig");
const mermaid = @import("../core/mermaid.zig");

pub const FormatError = error{OutOfMemory};

fn appendSpaces(out: *std.ArrayList(u8), allocator: std.mem.Allocator, n: u16) !void {
    var i: u16 = 0;
    while (i < n) : (i += 1) try out.append(allocator, ' ');
}

fn appendPadded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, src: []const u8, cols: u16) !void {
    const clip = if (measure.cellsTo(src) <= cols) src else src[0..measure.indexAtCell(src, cols)];
    try out.appendSlice(allocator, clip);
    const used = measure.cellsTo(clip);
    if (used < cols) try appendSpaces(out, allocator, cols - used);
}

fn headingBody(t: []const u8) ?[]const u8 {
    if (t.len < 3 or t[0] != '#') return null;
    var n: usize = 0;
    while (n < t.len and t[n] == '#' and n < 6) n += 1;
    if (n >= t.len or t[n] != ' ') return null;
    return t[n + 1 ..];
}

/// Longest prefix of `t` that fits `room` cells, broken at a space when there
/// is one. Without it a long paragraph wrapped back to column zero and left the
/// transcript ragged.
fn wrapTake(t: []const u8, room: u16) []const u8 {
    if (measure.cellsTo(t) <= room) return t;
    const cut = measure.indexAtCell(t, room);
    if (cut == 0) return t[0..measure.utf8LenAt(t, 0)];
    if (std.mem.lastIndexOfScalar(u8, t[0..cut], ' ')) |sp| {
        if (sp != 0) return t[0..sp];
    }
    return t[0..cut];
}

/// Cells `paintInline` will actually draw for `t`.
///
/// Not the same as the source width: `**bold**` is eight characters and four
/// cells, while `` `code` `` is six and six, because the backticks are traded
/// for the padding spaces around the highlight. A table measured on the source
/// pads every bold cell four cells too wide, and the borders walk off in a
/// staircase.
pub fn inlineCells(t: []const u8) u16 {
    var n: u16 = 0;
    var i: usize = 0;
    while (i < t.len) {
        if (t[i] == '*' and i + 1 < t.len and t[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, t, i + 2, "**") orelse t.len;
            n += measure.cellsTo(t[i + 2 .. end]);
            i = if (end + 1 < t.len) end + 2 else t.len;
            continue;
        }
        if (t[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, t, i + 1, '`') orelse t.len;
            // One space each side of the highlight, in place of the backticks.
            n += measure.cellsTo(t[i + 1 .. end]) + 2;
            i = if (end < t.len) end + 1 else t.len;
            continue;
        }
        const len = measure.utf8LenAt(t, i);
        n += measure.runeWidth(measure.runeAt(t, i));
        i += len;
    }
    return n;
}

/// The most of `t` that draws within `cells`, cut on a rune boundary and never
/// inside a markup pair: half a backtick pair paints the rest of the row as
/// code and eats the padding after it.
pub fn clipInline(t: []const u8, room: u16) []const u8 {
    if (inlineCells(t) <= room) return t;
    var n: u16 = 0;
    var i: usize = 0;
    var cut: usize = 0;
    while (i < t.len) {
        var next = i;
        var add: u16 = 0;
        if (t[i] == '*' and i + 1 < t.len and t[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, t, i + 2, "**") orelse t.len;
            add = measure.cellsTo(t[i + 2 .. end]);
            next = if (end + 1 < t.len) end + 2 else t.len;
        } else if (t[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, t, i + 1, '`') orelse t.len;
            add = measure.cellsTo(t[i + 1 .. end]) + 2;
            next = if (end < t.len) end + 1 else t.len;
        } else {
            const len = measure.utf8LenAt(t, i);
            add = measure.runeWidth(measure.runeAt(t, i));
            next = i + len;
        }
        if (n + add > room) break;
        n += add;
        i = next;
        cut = i;
    }
    return t[0..cut];
}

fn paintInline(out: *std.ArrayList(u8), allocator: std.mem.Allocator, t: []const u8) !void {
    try out.appendSlice(allocator, paint.asst_fg);
    var i: usize = 0;
    while (i < t.len) {
        if (t[i] == '*' and i + 1 < t.len and t[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, t, i + 2, "**") orelse t.len;
            // Colour rather than weight: bold at this size thickens the
            // glyphs without lifting them off the line, while the composer's
            // green is already the colour the eye is trained to find.
            try out.appendSlice(allocator, paint.reset);
            try out.appendSlice(allocator, paint.accent_dim);
            try out.appendSlice(allocator, t[i + 2 .. end]);
            try out.appendSlice(allocator, paint.reset);
            try out.appendSlice(allocator, paint.asst_fg);
            i = if (end + 1 < t.len) end + 2 else t.len;
            continue;
        }
        if (t[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, t, i + 1, '`') orelse t.len;
            try out.appendSlice(allocator, paint.reset);
            try out.appendSlice(allocator, paint.code_bg);
            try out.appendSlice(allocator, paint.code_fg);
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, t[i + 1 .. end]);
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, paint.reset);
            try out.appendSlice(allocator, paint.asst_fg);
            i = if (end < t.len) end + 1 else t.len;
            continue;
        }
        try out.append(allocator, t[i]);
        i += 1;
    }
    try out.appendSlice(allocator, paint.reset);
}

fn fenceLang(t: []const u8) []const u8 {
    var i: usize = 0;
    while (i < t.len and (t[i] == '`' or t[i] == '~')) i += 1;
    return std.mem.trim(u8, t[i..], " \t");
}

fn isFence(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~");
}

/// `|---|:--:|` and friends: the row that turns the row above into a header.
fn isTableRule(t: []const u8) bool {
    if (t.len < 3 or t[0] != '|') return false;
    for (t) |c| {
        if (c != '|' and c != '-' and c != ':' and c != ' ') return false;
    }
    return std.mem.indexOfScalar(u8, t, '-') != null;
}

fn orderedBody(t: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i]) and i < 3) i += 1;
    if (i == 0 or i + 1 >= t.len) return null;
    if (t[i] != '.' and t[i] != ')') return null;
    if (t[i + 1] != ' ') return null;
    return t[i + 2 ..];
}

/// Assistant markdown, one line at a time, with the state a line cannot carry
/// on its own: whether we are inside a fence, and whether a table is open.
///
/// The streaming pane and the retained transcript both drive this, so a block
/// cannot render one way live and another way on replay.
pub const Markdown = struct {
    cols: u16 = 80,
    in_fence: bool = false,
    /// Rows of the table being read, still in markdown. A table cannot be drawn
    /// one row at a time: every column width is a property of the whole block.
    /// Rendering each row on its own is what left the columns ragged, and it is
    /// why glamour, tablewriter and ratatui all collect the block first.
    rows: std.ArrayList([]u8) = .empty,
    /// The `|---|:--:|` row, kept for its alignment markers.
    rule: []u8 = &.{},
    /// Whether the fence being read is a mermaid block. Those are collected
    /// like a table is: a diagram is a property of the whole block.
    diagram: bool = false,
    /// Whether the reply has printed anything yet. A model that opens with a
    /// blank line would otherwise stack it on the blank row the block above
    /// already ends with, and the gap between blocks would not be one rule.
    started: bool = false,

    /// Text column. Every block in the transcript starts here: the user gutter
    /// and the thinking gutter both sit in the two cells to its left, so a
    /// reply that started at column zero was the only thing out of line.
    pub const indent: u16 = 2;

    fn inner(self: Markdown) u16 {
        return if (self.cols > indent + 8) self.cols - indent else 8;
    }

    pub fn deinit(self: *Markdown, allocator: std.mem.Allocator) void {
        self.dropTable(allocator);
        self.rows.deinit(allocator);
    }

    /// Render one finished line, inset to the shared text column. A table row
    /// draws nothing yet: the block it belongs to lands when the block ends.
    pub fn line(self: *Markdown, allocator: std.mem.Allocator, src: []const u8) FormatError![]u8 {
        const t = std.mem.trimEnd(u8, src, "\r");
        if (!self.in_fence and t.len != 0 and t[0] == '|') {
            try self.hold(allocator, t);
            return allocator.alloc(u8, 0);
        }
        if (!self.started) {
            if (std.mem.trim(u8, t, " \t").len == 0) return allocator.alloc(u8, 0);
            self.started = true;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (self.rows.items.len != 0 and !self.diagram) {
            const drawn = try self.drawTable(allocator);
            defer allocator.free(drawn);
            try out.appendSlice(allocator, drawn);
        }
        const body = try self.render(allocator, src);
        defer allocator.free(body);
        try indentInto(&out, allocator, body);
        return out.toOwnedSlice(allocator);
    }

    /// The block still buffered when the message ends. Empty when there is none.
    pub fn flush(self: *Markdown, allocator: std.mem.Allocator) FormatError![]u8 {
        if (self.rows.items.len == 0) return allocator.alloc(u8, 0);
        // A fence that never closed is a diagram nobody finished describing, so
        // it prints as what it is: source.
        if (self.diagram) {
            self.diagram = false;
            return self.plate(allocator, "mermaid");
        }
        return self.drawTable(allocator);
    }

    /// A mermaid block as a drawing, or as source when it is not something the
    /// renderer draws faithfully. Source is plainer; it is never wrong.
    fn drawDiagram(self: *Markdown, allocator: std.mem.Allocator) FormatError![]u8 {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(allocator);
        for (self.rows.items) |row| {
            try src.appendSlice(allocator, row);
            try src.append(allocator, '\n');
        }
        const drawn = try mermaid.render(allocator, self.inner(), src.items) orelse
            return self.plate(allocator, "mermaid");
        defer allocator.free(drawn);
        self.dropTable(allocator);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        // The canvas is plain text; the colour is put on here so a diagram
        // reads at the same weight as a table's grid.
        try out.appendSlice(allocator, paint.grid);
        try indentInto(&out, allocator, drawn);
        try out.appendSlice(allocator, paint.reset);
        return out.toOwnedSlice(allocator);
    }

    /// The buffered block drawn as a code plate.
    fn plate(self: *Markdown, allocator: std.mem.Allocator, lang: []const u8) FormatError![]u8 {
        defer self.dropTable(allocator);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const top = try codeEdge(allocator, self.inner(), lang, true);
        defer allocator.free(top);
        try indentInto(&out, allocator, top);
        for (self.rows.items) |row| {
            const body = try codeRow(allocator, self.inner(), row);
            defer allocator.free(body);
            try indentInto(&out, allocator, body);
        }
        const bottom = try codeEdge(allocator, self.inner(), "", false);
        defer allocator.free(bottom);
        try indentInto(&out, allocator, bottom);
        return out.toOwnedSlice(allocator);
    }

    fn hold(self: *Markdown, allocator: std.mem.Allocator, t: []const u8) FormatError!void {
        if (isTableRule(t)) {
            if (self.rule.len == 0) self.rule = try allocator.dupe(u8, t);
            return;
        }
        try self.rows.append(allocator, try allocator.dupe(u8, t));
    }

    fn dropTable(self: *Markdown, allocator: std.mem.Allocator) void {
        for (self.rows.items) |r| allocator.free(r);
        self.rows.clearRetainingCapacity();
        if (self.rule.len != 0) {
            allocator.free(self.rule);
            self.rule = &.{};
        }
    }

    /// The whole block at once: widths from every row, the widest column giving
    /// ground first when the block is wider than the pane.
    fn drawTable(self: *Markdown, allocator: std.mem.Allocator) FormatError![]u8 {
        defer self.dropTable(allocator);
        var w: [max_table_cols]u16 = @splat(0);
        var right: [max_table_cols]bool = @splat(true);
        var ncols: usize = 0;
        for (self.rows.items, 0..) |row, ri| {
            var it = cells(row);
            var ci: usize = 0;
            while (it.next()) |cell| : (ci += 1) {
                if (ci == max_table_cols) break;
                const c = std.mem.trim(u8, cell, " \t");
                // Measured as it will be drawn, not as it was written.
                w[ci] = @max(w[ci], if (ri == 0) measure.cellsTo(c) else inlineCells(c));
                // The header names a column; it never says what the column is.
                if (ri != 0 and !numeric(c)) right[ci] = false;
                ncols = @max(ncols, ci + 1);
            }
        }
        if (ncols == 0) return allocator.alloc(u8, 0);

        // Every column carries a space of padding on each side, and the rules
        // between and around them take one cell each.
        const frame: u16 = @intCast(ncols * 2 + ncols + 1);
        const room: u16 = if (self.inner() > frame + min_table_col) self.inner() - frame else min_table_col;
        shrinkToFit(w[0..ncols], room);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const header = self.rule.len != 0;
        try edge(&out, allocator, w[0..ncols], .top);
        for (self.rows.items, 0..) |row, ri| {
            var line_buf: std.ArrayList(u8) = .empty;
            defer line_buf.deinit(allocator);
            const head = header and ri == 0;
            try self.drawRow(&line_buf, allocator, row, w[0..ncols], right[0..ncols], head);
            try indentInto(&out, allocator, line_buf.items);
            if (head) try edge(&out, allocator, w[0..ncols], .mid);
        }
        try edge(&out, allocator, w[0..ncols], .bottom);
        return out.toOwnedSlice(allocator);
    }

    const Edge = enum { top, mid, bottom };

    /// One rule across the whole table, with a joint over every column rule.
    fn edge(
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        w: []const u16,
        kind: Edge,
    ) FormatError!void {
        const glyphs: [3][]const u8 = switch (kind) {
            .top => .{ "\u{250c}", "\u{252c}", "\u{2510}" },
            .mid => .{ "\u{251c}", "\u{253c}", "\u{2524}" },
            .bottom => .{ "\u{2514}", "\u{2534}", "\u{2518}" },
        };
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, paint.grid);
        try buf.appendSlice(allocator, glyphs[0]);
        for (w, 0..) |c, i| {
            if (i != 0) try buf.appendSlice(allocator, glyphs[1]);
            var n: u16 = 0;
            while (n < c + 2) : (n += 1) try buf.appendSlice(allocator, "\u{2500}");
        }
        try buf.appendSlice(allocator, glyphs[2]);
        try buf.appendSlice(allocator, paint.reset);
        try buf.append(allocator, '\n');
        try indentInto(out, allocator, buf.items);
    }

    fn drawRow(
        self: *const Markdown,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        row: []const u8,
        w: []const u16,
        right: []const bool,
        header: bool,
    ) FormatError!void {
        var it = cells(row);
        var ci: usize = 0;
        while (ci < w.len) : (ci += 1) {
            const raw = it.next() orelse "";
            const trimmed = std.mem.trim(u8, raw, " \t");
            const text = if (header) clipCellsTo(trimmed, w[ci]) else clipInline(trimmed, w[ci]);
            const shown = if (header) measure.cellsTo(text) else inlineCells(text);
            const pad = w[ci] -| shown;
            try out.appendSlice(allocator, paint.grid);
            try out.appendSlice(allocator, "\u{2502}");
            try out.appendSlice(allocator, paint.reset);
            try out.append(allocator, ' ');
            // A header names the column and is read as a label, so it sits in
            // the middle of it; a value is read down the column and lines up
            // on the edge its type reads from.
            const lead: u16 = if (header)
                pad / 2
            else if (ruleAlign(self.rule, ci) orelse
                (if (right[ci]) Align.right else Align.left) == .right) pad else 0;
            try appendSpaces(out, allocator, lead);
            if (header) {
                try out.appendSlice(allocator, paint.accent_dim);
                try out.appendSlice(allocator, text);
                try out.appendSlice(allocator, paint.reset);
            } else {
                try paintInline(out, allocator, text);
            }
            try appendSpaces(out, allocator, pad - lead);
            try out.append(allocator, ' ');
        }
        try out.appendSlice(allocator, paint.grid);
        try out.appendSlice(allocator, "\u{2502}");
        try out.appendSlice(allocator, paint.reset);
        try out.append(allocator, '\n');
    }

    /// One row's worth of markdown, unindented. Advances the fence state.
    fn render(self: *Markdown, allocator: std.mem.Allocator, src: []const u8) FormatError![]u8 {
        const t = std.mem.trimEnd(u8, src, "\r");

        if (isFence(t)) {
            const lang = fenceLang(t);
            if (self.in_fence) {
                self.in_fence = false;
                if (self.diagram) {
                    self.diagram = false;
                    return self.drawDiagram(allocator);
                }
                return codeEdge(allocator, self.inner(), "", false);
            }
            self.in_fence = true;
            if (std.ascii.eqlIgnoreCase(lang, "mermaid")) {
                self.diagram = true;
                return allocator.alloc(u8, 0);
            }
            return codeEdge(allocator, self.inner(), lang, true);
        }
        if (self.in_fence) {
            if (!self.diagram) return codeRow(allocator, self.inner(), t);
            try self.rows.append(allocator, try allocator.dupe(u8, t));
            return allocator.alloc(u8, 0);
        }

        if (headingBody(t)) |title| {
            return std.fmt.allocPrint(allocator, "{s}{s}{s}\n", .{ paint.accent, title, paint.reset });
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        if (std.mem.startsWith(u8, t, "> ")) {
            try out.appendSlice(allocator, paint.border);
            try out.appendSlice(allocator, "\u{2503} ");
            try out.appendSlice(allocator, paint.reset);
            try out.appendSlice(allocator, paint.muted);
            try out.appendSlice(allocator, t[2..]);
            try out.appendSlice(allocator, paint.reset);
            try out.append(allocator, '\n');
            return out.toOwnedSlice(allocator);
        }

        // Nested bullets keep their indent; only the marker is restyled.
        const lead = t.len - std.mem.trimStart(u8, t, " ").len;
        const body = t[lead..];
        if (body.len >= 2 and (std.mem.startsWith(u8, body, "- ") or std.mem.startsWith(u8, body, "* "))) {
            const bullet = if (lead >= 2) "\u{25e6} " else "\u{2022} ";
            try self.flow(&out, allocator, t[0..lead], bullet, body[2..]);
            return out.toOwnedSlice(allocator);
        }
        if (orderedBody(body)) |rest| {
            try self.flow(&out, allocator, t[0..lead], body[0 .. body.len - rest.len], rest);
            return out.toOwnedSlice(allocator);
        }

        try self.flow(&out, allocator, "", "", t);
        return out.toOwnedSlice(allocator);
    }

    /// Render a line that is still being streamed. State is left untouched, so
    /// the committed render of the same line is identical.
    pub fn peek(self: Markdown, allocator: std.mem.Allocator, src: []const u8) FormatError![]u8 {
        const t = std.mem.trimEnd(u8, src, "\r");
        // A table row in flight is shown as it arrived. The aligned block does
        // not exist until the block ends, and dropping the row would make the
        // pane look frozen half-way through a table.
        if (!self.in_fence and t.len != 0 and t[0] == '|') {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try appendSpaces(&out, allocator, indent);
            try out.appendSlice(allocator, paint.muted);
            try out.appendSlice(allocator, clipCellsTo(t, self.inner()));
            try out.appendSlice(allocator, paint.reset);
            try out.append(allocator, '\n');
            return out.toOwnedSlice(allocator);
        }
        var copy = self;
        // The copy shares nothing it could free: the real buffer stays put.
        copy.rows = .empty;
        copy.rule = &.{};
        return copy.line(allocator, src);
    }

    /// Wrapped body under a marker: the first row carries the marker, the rest
    /// hang under the text, never back at the margin.
    fn flow(
        self: Markdown,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        lead: []const u8,
        marker: []const u8,
        text: []const u8,
    ) FormatError!void {
        const mark_w = measure.cellsTo(marker);
        // A pathological indent cannot be allowed to wrap the cast; there is no
        // room left to hang under one that wide anyway.
        const lead_w: u16 = @intCast(@min(lead.len, self.inner()));
        const hang: u16 = lead_w + mark_w;
        const room: u16 = if (self.inner() > hang + 8) self.inner() - hang else 8;
        var rest = text;
        var first = true;
        while (true) {
            const take = wrapTake(rest, room);
            try out.appendSlice(allocator, lead);
            if (first and marker.len != 0) {
                try out.appendSlice(allocator, paint.accent_dim);
                try out.appendSlice(allocator, marker);
                try out.appendSlice(allocator, paint.reset);
            } else {
                try appendSpaces(out, allocator, mark_w);
            }
            try paintInline(out, allocator, take);
            try out.append(allocator, '\n');
            rest = std.mem.trimStart(u8, rest[take.len..], " ");
            first = false;
            if (rest.len == 0) break;
        }
    }
};

fn codeWidth(cols: u16) u16 {
    return if (cols > 4) @min(cols, 120) - 2 else 2;
}

/// Fence edge: a plate-wide rule, with the language named on the way in.
fn codeEdge(allocator: std.mem.Allocator, cols: u16, lang: []const u8, open: bool) FormatError![]u8 {
    const w = codeWidth(cols);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, paint.border);
    try out.appendSlice(allocator, if (open) "\u{256d}" else "\u{2570}");
    const named = if (open and lang.len != 0) lang else "";
    if (named.len != 0) {
        try out.appendSlice(allocator, "\u{2500} ");
        try out.appendSlice(allocator, paint.muted);
        try out.appendSlice(allocator, named);
        try out.appendSlice(allocator, paint.border);
        try out.append(allocator, ' ');
    }
    const used: u16 = if (named.len == 0) 1 else @as(u16, @intCast(@min(named.len + 4, w)));
    var i: u16 = used;
    while (i < w) : (i += 1) try out.appendSlice(allocator, "\u{2500}");
    try out.appendSlice(allocator, if (open) "\u{256e}" else "\u{256f}");
    try out.appendSlice(allocator, paint.reset);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Longest prefix of `s` that fits `n` bytes without splitting a UTF-8 rune.
fn takeRunes(s: []const u8, n: u16) []const u8 {
    if (s.len <= n) return s;
    var end: usize = n;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// One line inside a fence: gutter, then the code on its own plate. Long lines
/// wrap onto more plate rows -- clipping a code line silently deletes code.
fn codeRow(allocator: std.mem.Allocator, cols: u16, text: []const u8) FormatError![]u8 {
    const w = codeWidth(cols);
    const inner: u16 = if (w > 2) w - 2 else 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rest = text;
    while (true) {
        const take = takeRunes(rest, inner);
        rest = rest[take.len..];
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "\u{2502}");
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.code_bg);
        try out.appendSlice(allocator, paint.code_fg);
        try out.append(allocator, ' ');
        try appendPadded(&out, allocator, take, inner);
        try out.appendSlice(allocator, paint.reset);
        try out.appendSlice(allocator, paint.border);
        try out.appendSlice(allocator, "\u{2502}");
        try out.appendSlice(allocator, paint.reset);
        try out.append(allocator, '\n');
        if (rest.len == 0) break;
    }
    return out.toOwnedSlice(allocator);
}

/// Receipt: the widest table in this repo's recorded transcripts is 5 columns.
/// 24 is a tripwire for markup that is not a table, not a budget to design to.
const max_table_cols: usize = 24;
/// Narrower than this a column shows nothing but its ellipsis.
const min_table_col: u16 = 4;
const table_sep = " \u{2502} ";
const table_sep_cells: u16 = 3;

/// Inset every row of `body` to the shared text column.
fn indentInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, body: []const u8) FormatError!void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
    while (it.next()) |row| {
        // A blank row stays blank: indenting it only leaves trailing spaces.
        if (measure.cellsTo(row) != 0) try appendSpaces(out, allocator, Markdown.indent);
        try out.appendSlice(allocator, row);
        try out.append(allocator, '\n');
    }
}

/// Widest column gives ground first, down to a floor, until the block fits.
fn shrinkToFit(w: []u16, room: u16) void {
    while (true) {
        var total: u16 = 0;
        var widest: usize = 0;
        for (w, 0..) |c, i| {
            total +|= c;
            if (c > w[widest]) widest = i;
        }
        if (total <= room) return;
        if (w[widest] <= min_table_col) return;
        w[widest] -= 1;
    }
}

fn clipCellsTo(s: []const u8, room: u16) []const u8 {
    if (measure.cellsTo(s) <= room) return s;
    return s[0..measure.indexAtCell(s, room)];
}

/// Cells of one markdown row: the outer pipes are the frame, not a column.
fn cells(row: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, std.mem.trim(u8, row, "|"), '|');
}

const Align = enum { left, right };

/// `--:` and `:-:` in the rule row, per column.
fn ruleAlign(rule: []const u8, col: usize) ?Align {
    var it = cells(rule);
    var i: usize = 0;
    while (it.next()) |cell| : (i += 1) {
        if (i != col) continue;
        const c = std.mem.trim(u8, cell, " \t");
        if (c.len == 0) return null;
        if (c[c.len - 1] == ':') return .right;
        return .left;
    }
    return null;
}

fn numeric(c: []const u8) bool {
    if (c.len == 0) return false;
    for (c) |ch| {
        if (!std.ascii.isDigit(ch) and ch != '.' and ch != '%' and ch != '-' and ch != '+') return false;
    }
    return true;
}

fn tableRule(allocator: std.mem.Allocator, w: u16) FormatError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, paint.border);
    var i: u16 = 0;
    while (i < w) : (i += 1) try out.appendSlice(allocator, "\u{2500}");
    try out.appendSlice(allocator, paint.reset);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Whole-reply render. Same renderer the live pane drives, so replay matches.
pub fn formatAssistant(allocator: std.mem.Allocator, cols: u16, text: []const u8) FormatError![]u8 {
    var md = Markdown{ .cols = cols };
    defer md.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // One trailing newline is the end of the last row, not a blank row of its
    // own. Kept, a reply owned a blank line the next block also brings.
    var it = std.mem.splitScalar(u8, if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text, '\n');
    while (it.next()) |src| {
        const painted = try md.line(allocator, src);
        defer allocator.free(painted);
        try out.appendSlice(allocator, painted);
    }
    const tail = try md.flush(allocator);
    defer allocator.free(tail);
    try out.appendSlice(allocator, tail);
    const spaced = try oneBlankBetween(allocator, out.items);
    out.deinit(allocator);
    return spaced;
}

/// Collapse runs of blank rows to a single one.
///
/// A reply's rhythm comes from the source markdown, which is written by a
/// model and spaces itself however it likes: two blank lines before a
/// heading, none after a table, three around a list. The transcript reads as
/// one document, so the gap between blocks has to be one thing.
///
/// Rows are compared by visible width rather than by bytes: a "blank" row
/// from the markdown renderer still carries the colour escapes it opened
/// with.
fn oneBlankBetween(allocator: std.mem.Allocator, text: []const u8) FormatError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var blanks: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |row| {
        // `splitScalar` yields an empty tail after the final newline; that is
        // the end of the last row, not a row of its own.
        if (row.len == 0 and it.rest().len == 0 and !first) break;
        if (measure.cellsTo(row) == 0) {
            blanks += 1;
            continue;
        }
        // Leading blanks belong to whatever came before this block.
        if (blanks != 0 and !first) {
            try out.append(allocator, '\n');
        }
        blanks = 0;
        first = false;
        try out.appendSlice(allocator, row);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}
