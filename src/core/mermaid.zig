//! Mermaid diagrams drawn with box-drawing runes, in-process.
//!
//! The reference implementations (mermaid-ascii, termaid) all do the same three
//! things: parse the source into nodes and edges, place those on a coarse grid,
//! then paint the grid into a character canvas. None of it needs a browser, an
//! SVG rasteriser, or a font -- those are only required to produce an image,
//! and a terminal does not want an image.
//!
//! What is supported is what a model actually emits: `graph`/`flowchart` in the
//! four directions, and `sequenceDiagram` messages. Anything else -- subgraphs,
//! class diagrams, a graph too wide for the pane -- returns null, and the caller
//! falls back to printing the source, which is never wrong, only plainer.

const std = @import("std");

fn starts(line: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, line, prefix);
}

const measure = @import("../cli/width.zig");

/// Receipt: every mermaid block recorded in this repo's benches is 2 nodes,
/// and a diagram stops being readable in a terminal well before 20. 64 is a
/// tripwire for generated markup, not a budget a real diagram reaches.
pub const max_nodes: usize = 64;
pub const max_edges: usize = 128;
/// Beyond this the drawing is wider than any terminal and worth less than the
/// source it replaced.
pub const max_cols: u16 = 200;
pub const max_rows: u16 = 400;

pub const Dir = enum {
    down,
    right,

    fn fromSlice(s: []const u8) ?Dir {
        if (std.mem.eql(u8, s, "TD") or std.mem.eql(u8, s, "TB")) return .down;
        if (std.mem.eql(u8, s, "LR")) return .right;
        return null;
    }
};

pub const Style = enum { solid, dotted, thick, open };

const Node = struct {
    id: []const u8,
    label: []const u8,
    layer: u16 = 0,
    /// Position across the layer, in node slots.
    cross: u16 = 0,
};

const Edge = struct {
    from: u16,
    to: u16,
    label: []const u8 = "",
    style: Style = .solid,
};

const Graph = struct {
    nodes: [max_nodes]Node = undefined,
    n: u16 = 0,
    edges: [max_edges]Edge = undefined,
    e: u16 = 0,
    dir: Dir = .down,

    fn find(self: *Graph, id: []const u8) ?u16 {
        for (self.nodes[0..self.n], 0..) |node, i| {
            if (std.mem.eql(u8, node.id, id)) return @intCast(i);
        }
        return null;
    }

    fn intern(self: *Graph, raw: []const u8) ?u16 {
        const parsed = splitLabel(raw);
        if (parsed.id.len == 0) return null;
        if (self.find(parsed.id)) |i| {
            // A later mention may be the one that carries the label.
            if (self.nodes[i].label.ptr == self.nodes[i].id.ptr and parsed.label.len != 0) {
                self.nodes[i].label = parsed.label;
            }
            return i;
        }
        if (self.n == max_nodes) return null;
        self.nodes[self.n] = .{
            .id = parsed.id,
            .label = if (parsed.label.len != 0) parsed.label else parsed.id,
        };
        self.n += 1;
        return self.n - 1;
    }
};

/// `A[Some label]`, `A(Some label)`, `A{Some label}` and the doubled forms.
fn splitLabel(raw: []const u8) struct { id: []const u8, label: []const u8 } {
    const t = std.mem.trim(u8, raw, " \t");
    const open = std.mem.indexOfAny(u8, t, "[({") orelse return .{ .id = t, .label = "" };
    if (open == 0) return .{ .id = t, .label = "" };
    const close: u8 = switch (t[open]) {
        '[' => ']',
        '(' => ')',
        else => '}',
    };
    const end = std.mem.lastIndexOfScalar(u8, t, close) orelse return .{ .id = t, .label = "" };
    if (end <= open) return .{ .id = t, .label = "" };
    const inner = std.mem.trim(u8, t[open + 1 .. end], "[({])} \t\"");
    return .{ .id = t[0..open], .label = inner };
}

const Arrow = struct {
    at: usize,
    len: usize,
    style: Style,
};

/// The arrow shapes a flowchart uses, longest first so `-.->` is not read as
/// `---` with a stray dot.
fn findArrow(s: []const u8) ?Arrow {
    const shapes = [_]struct { text: []const u8, style: Style }{
        .{ .text = "-.->", .style = .dotted },
        .{ .text = "-.-", .style = .dotted },
        .{ .text = "==>", .style = .thick },
        .{ .text = "-->", .style = .solid },
        .{ .text = "---", .style = .open },
        .{ .text = "->", .style = .solid },
    };
    var best: ?Arrow = null;
    for (shapes) |shape| {
        const at = std.mem.indexOf(u8, s, shape.text) orelse continue;
        if (best) |b| {
            if (at > b.at) continue;
            if (at == b.at and shape.text.len <= b.len) continue;
        }
        best = .{ .at = at, .len = shape.text.len, .style = shape.style };
    }
    return best;
}

/// `|label|` immediately after an arrow.
fn takeEdgeLabel(rest: []const u8) struct { label: []const u8, rest: []const u8 } {
    const t = std.mem.trimStart(u8, rest, " \t");
    if (t.len == 0 or t[0] != '|') return .{ .label = "", .rest = rest };
    const end = std.mem.indexOfScalarPos(u8, t, 1, '|') orelse
        return .{ .label = "", .rest = rest };
    return .{ .label = std.mem.trim(u8, t[1..end], " \t"), .rest = t[end + 1 ..] };
}

fn addEdges(g: *Graph, lhs: []const u8, rhs: []const u8, label: []const u8, style: Style) void {
    var from_it = std.mem.splitScalar(u8, lhs, '&');
    while (from_it.next()) |a| {
        const fi = g.intern(a) orelse continue;
        var to_it = std.mem.splitScalar(u8, rhs, '&');
        while (to_it.next()) |b| {
            const ti = g.intern(b) orelse continue;
            if (g.e == max_edges) return;
            g.edges[g.e] = .{ .from = fi, .to = ti, .label = label, .style = style };
            g.e += 1;
        }
    }
}

fn parseFlow(src: []const u8, g: *Graph) bool {
    var seen_header = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '%') continue;
        if (!seen_header) {
            const head = if (std.mem.startsWith(u8, line, "flowchart"))
                line["flowchart".len..]
            else if (std.mem.startsWith(u8, line, "graph"))
                line["graph".len..]
            else
                return false;
            g.dir = Dir.fromSlice(std.mem.trim(u8, head, " \t")) orelse .down;
            seen_header = true;
            continue;
        }
        // Not a shape this renderer draws: say so rather than drawing a lie.
        if (starts(line, "subgraph") or starts(line, "end")) return false;
        if (starts(line, "classDef") or starts(line, "class ")) continue;
        if (starts(line, "style ")) continue;

        var guard: usize = 0;
        while (findArrow(line)) |arrow| {
            guard += 1;
            if (guard > max_edges) return false;
            const lhs = line[0..arrow.at];
            const after = takeEdgeLabel(line[arrow.at + arrow.len ..]);
            // A chain keeps going: the right side of this arrow is the left
            // side of the next one.
            const next = findArrow(after.rest);
            const rhs = if (next) |nx| after.rest[0..nx.at] else after.rest;
            addEdges(g, lhs, rhs, after.label, arrow.style);
            if (next == null) break;
            line = after.rest;
        }
    }
    return seen_header and g.n != 0;
}

/// Longest path from a root. Cycles settle because a node can only be pushed
/// down `n` times before every layer is taken.
fn layer(g: *Graph) void {
    var round: u16 = 0;
    while (round < g.n) : (round += 1) {
        var moved = false;
        for (g.edges[0..g.e]) |edge| {
            if (edge.from == edge.to) continue;
            const want = g.nodes[edge.from].layer + 1;
            if (g.nodes[edge.to].layer < want) {
                g.nodes[edge.to].layer = want;
                moved = true;
            }
        }
        if (!moved) break;
    }
    var used: [max_nodes]u16 = @splat(0);
    for (g.nodes[0..g.n]) |*node| {
        node.cross = used[node.layer];
        used[node.layer] += 1;
    }
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

/// A grid of runes. Everything is drawn into this and serialised once, so an
/// edge crossing a box is a bug you can see rather than interleaved writes.
const Canvas = struct {
    allocator: std.mem.Allocator,
    cells: []u21,
    rows: u16,
    cols: u16,

    fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Canvas {
        const cells = try allocator.alloc(u21, @as(usize, rows) * cols);
        @memset(cells, ' ');
        return .{ .allocator = allocator, .cells = cells, .rows = rows, .cols = cols };
    }

    fn deinit(self: *Canvas) void {
        self.allocator.free(self.cells);
    }

    fn put(self: *Canvas, row: u16, col: u16, cp: u21) void {
        if (row >= self.rows or col >= self.cols) return;
        self.cells[@as(usize, row) * self.cols + col] = cp;
    }

    fn at(self: Canvas, row: u16, col: u16) u21 {
        if (row >= self.rows or col >= self.cols) return ' ';
        return self.cells[@as(usize, row) * self.cols + col];
    }

    /// Write only where nothing has been drawn, so a box always wins over a
    /// line. Two lines that meet become a crossing rather than one erasing the
    /// other, which is the difference between a diagram and a smudge.
    fn line(self: *Canvas, row: u16, col: u16, cp: u21) void {
        const have = self.at(row, col);
        if (have == ' ') {
            self.put(row, col, cp);
            return;
        }
        if (crosses(have, cp)) self.put(row, col, '\u{253c}');
    }

    fn text(self: *Canvas, row: u16, col: u16, s: []const u8) void {
        var i: usize = 0;
        var c = col;
        while (i < s.len) {
            const n = measure.utf8LenAt(s, i);
            self.put(row, c, measure.runeAt(s, i));
            c +|= measure.runeWidth(measure.runeAt(s, i));
            i += n;
        }
    }

    fn box(self: *Canvas, row: u16, col: u16, w: u16, h: u16, label: []const u8) void {
        self.put(row, col, '\u{250c}');
        self.put(row, col + w - 1, '\u{2510}');
        self.put(row + h - 1, col, '\u{2514}');
        self.put(row + h - 1, col + w - 1, '\u{2518}');
        var i: u16 = 1;
        while (i < w - 1) : (i += 1) {
            self.put(row, col + i, '\u{2500}');
            self.put(row + h - 1, col + i, '\u{2500}');
        }
        var j: u16 = 1;
        while (j < h - 1) : (j += 1) {
            self.put(row + j, col, '\u{2502}');
            self.put(row + j, col + w - 1, '\u{2502}');
        }
        self.text(row + h / 2, col + 2, label);
    }

    fn toOwned(self: Canvas, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        // The grid is sized for the worst case; the drawing ends where the last
        // painted row does, and blank rows below it are just dead space.
        var last: u16 = 0;
        var scan: u16 = 0;
        while (scan < self.rows) : (scan += 1) {
            var c: u16 = 0;
            while (c < self.cols) : (c += 1) {
                if (self.at(scan, c) != ' ') last = scan + 1;
            }
        }
        var r: u16 = 0;
        while (r < last) : (r += 1) {
            var end: u16 = self.cols;
            while (end > 0 and self.at(r, end - 1) == ' ') end -= 1;
            var c: u16 = 0;
            var buf: [4]u8 = undefined;
            while (c < end) : (c += 1) {
                const n = std.unicode.utf8Encode(self.at(r, c), &buf) catch 1;
                try out.appendSlice(allocator, buf[0..n]);
            }
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }
};

fn vertical(cp: u21) bool {
    return cp == '\u{2502}' or cp == '\u{2506}' or cp == '\u{2503}';
}

fn horizontal(cp: u21) bool {
    return cp == '\u{2500}' or cp == '\u{2504}' or cp == '\u{2501}';
}

fn crosses(have: u21, want: u21) bool {
    if (vertical(have) and horizontal(want)) return true;
    return horizontal(have) and vertical(want);
}

fn lineRune(style: Style, vertical_run: bool) u21 {
    return switch (style) {
        .dotted => if (vertical_run) '\u{2506}' else '\u{2504}',
        .thick => if (vertical_run) '\u{2503}' else '\u{2501}',
        .solid, .open => if (vertical_run) '\u{2502}' else '\u{2500}',
    };
}

const gap_main: u16 = 4;
const gap_cross: u16 = 2;
const box_h: u16 = 3;

fn drawFlow(allocator: std.mem.Allocator, g: *Graph, cols: u16) !?[]u8 {
    layer(g);

    // One slot width for every node, so a column stays a column and an edge
    // between two layers meets the box it points at.
    var layers: u16 = 0;
    var slot: u16 = 0;
    for (g.nodes[0..g.n]) |node| {
        layers = @max(layers, node.layer + 1);
        slot = @max(slot, measure.cellsTo(node.label) + 4);
    }

    var per_layer: [max_nodes]u16 = @splat(0);
    for (g.nodes[0..g.n]) |node| per_layer[node.layer] += 1;
    var widest: u16 = 0;
    for (per_layer[0..layers]) |c| widest = @max(widest, c);

    const down = g.dir == .down;
    const total_cols: u32 = if (down)
        @as(u32, widest) * (slot + gap_cross)
    else
        @as(u32, layers) * (slot + gap_main);
    const total_rows: u32 = if (down)
        @as(u32, layers) * (box_h + gap_main)
    else
        @as(u32, widest) * (box_h + gap_cross);
    if (total_cols > @min(cols, max_cols) or total_rows > max_rows) return null;

    var canvas = try Canvas.init(allocator, @intCast(total_rows), @intCast(total_cols));
    defer canvas.deinit();

    for (g.nodes[0..g.n]) |node| {
        const pos = nodePos(node, slot, down);
        canvas.box(pos.row, pos.col, slot, box_h, node.label);
    }
    for (g.edges[0..g.e]) |edge| {
        if (edge.from == edge.to) continue;
        drawEdge(&canvas, g, edge, slot, down);
    }
    return try canvas.toOwned(allocator);
}

fn nodePos(node: Node, slot: u16, down: bool) struct { row: u16, col: u16 } {
    if (down) {
        return .{
            .row = node.layer * (box_h + gap_main),
            .col = node.cross * (slot + gap_cross),
        };
    }
    return .{
        .row = node.cross * (box_h + gap_cross),
        .col = node.layer * (slot + gap_main),
    };
}

/// Down, across, down (or right, across, right): the only routing shape that
/// never needs a diagonal, which a character grid cannot draw anyway.
fn drawEdge(canvas: *Canvas, g: *Graph, edge: Edge, slot: u16, down: bool) void {
    const a = nodePos(g.nodes[edge.from], slot, down);
    const b = nodePos(g.nodes[edge.to], slot, down);
    if (down) {
        const from_col = a.col + slot / 2;
        const to_col = b.col + slot / 2;
        const start = a.row + box_h;
        const end = if (b.row > 0) b.row - 1 else 0;
        if (end < start) return;
        const mid = start + (end - start) / 2;
        var r = start;
        while (r <= mid) : (r += 1) canvas.line(r, from_col, lineRune(edge.style, true));
        if (from_col != to_col) {
            var c = @min(from_col, to_col);
            const run = lineRune(edge.style, false);
            while (c <= @max(from_col, to_col)) : (c += 1) canvas.line(mid, c, run);
        }
        r = mid;
        while (r <= end) : (r += 1) canvas.line(r, to_col, lineRune(edge.style, true));
        if (from_col != to_col) {
            canvas.put(mid, from_col, if (to_col > from_col) '\u{2514}' else '\u{2518}');
            canvas.put(mid, to_col, if (to_col > from_col) '\u{2510}' else '\u{250c}');
        }
        if (edge.style != .open) canvas.put(end, to_col, '\u{25bc}');
        if (edge.label.len != 0) canvas.text(mid, @max(from_col, to_col) + 2, edge.label);
        return;
    }
    const from_row = a.row + box_h / 2;
    const to_row = b.row + box_h / 2;
    const start = a.col + slot;
    const end = if (b.col > 0) b.col - 1 else 0;
    if (end < start) return;
    const mid = start + (end - start) / 2;
    var c = start;
    while (c <= mid) : (c += 1) canvas.line(from_row, c, lineRune(edge.style, false));
    if (from_row != to_row) {
        var r = @min(from_row, to_row);
        const run = lineRune(edge.style, true);
        while (r <= @max(from_row, to_row)) : (r += 1) canvas.line(r, mid, run);
    }
    c = mid;
    while (c <= end) : (c += 1) canvas.line(to_row, c, lineRune(edge.style, false));
    if (from_row != to_row) {
        canvas.put(from_row, mid, if (to_row > from_row) '\u{2510}' else '\u{2518}');
        canvas.put(to_row, mid, if (to_row > from_row) '\u{2514}' else '\u{250c}');
    }
    if (edge.style != .open) canvas.put(to_row, end, '\u{25b6}');
    if (edge.label.len != 0 and from_row > 0) canvas.text(from_row - 1, start + 1, edge.label);
}

// ---------------------------------------------------------------------------
// Sequence diagrams
// ---------------------------------------------------------------------------

const Msg = struct {
    from: u16,
    to: u16,
    text: []const u8,
    dotted: bool,
};

const Seq = struct {
    names: [max_nodes][]const u8 = undefined,
    n: u16 = 0,
    msgs: [max_edges]Msg = undefined,
    m: u16 = 0,

    fn intern(self: *Seq, raw: []const u8) ?u16 {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) return null;
        for (self.names[0..self.n], 0..) |have, i| {
            if (std.mem.eql(u8, have, name)) return @intCast(i);
        }
        if (self.n == max_nodes) return null;
        self.names[self.n] = name;
        self.n += 1;
        return self.n - 1;
    }
};

fn parseSeq(src: []const u8, s: *Seq) bool {
    var seen_header = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '%') continue;
        if (!seen_header) {
            if (!std.mem.eql(u8, line, "sequenceDiagram")) return false;
            seen_header = true;
            continue;
        }
        if (starts(line, "participant ")) {
            const rest = line["participant ".len..];
            const as = std.mem.indexOf(u8, rest, " as ");
            _ = s.intern(if (as) |i| rest[i + 4 ..] else rest);
            continue;
        }
        // Blocks and notes are structure this renderer does not draw; a frame
        // it silently dropped would change what the diagram says.
        if (starts(line, "loop ") or starts(line, "alt ")) return false;
        if (starts(line, "opt ") or starts(line, "par ")) return false;
        if (starts(line, "Note ") or std.mem.eql(u8, line, "end")) return false;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const head = line[0..colon];
        const body = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const dotted = std.mem.indexOf(u8, head, "--") != null;
        const at = std.mem.indexOf(u8, head, "->") orelse continue;
        var arrow_end = at + 2;
        while (arrow_end < head.len and (head[arrow_end] == '>' or head[arrow_end] == ')')) {
            arrow_end += 1;
        }
        const left = std.mem.trimEnd(u8, head[0..at], "-.<");
        const from = s.intern(left) orelse continue;
        const to = s.intern(head[arrow_end..]) orelse continue;
        if (s.m == max_edges) return false;
        s.msgs[s.m] = .{ .from = from, .to = to, .text = body, .dotted = dotted };
        s.m += 1;
    }
    return seen_header and s.n != 0;
}

fn drawSeq(allocator: std.mem.Allocator, s: *Seq, cols: u16) !?[]u8 {
    var slot: u16 = 0;
    for (s.names[0..s.n]) |name| slot = @max(slot, measure.cellsTo(name) + 4);
    // A label sits above its arrow, so the span it crosses has to hold it. The
    // room goes between the lifelines; widening the boxes instead would leave
    // every participant padded out to the longest sentence anyone says.
    var pitch: u16 = slot + gap_cross;
    for (s.msgs[0..s.m]) |msg| {
        const span = if (msg.from == msg.to) 1 else @max(msg.from, msg.to) - @min(msg.from, msg.to);
        const need = (measure.cellsTo(msg.text) + 4) / span;
        pitch = @max(pitch, @min(need, max_cols / @max(s.n, 1)));
    }
    const total_cols: u32 = @as(u32, s.n) * pitch;
    // Header box, then three rows per message: label, arrow, spacer.
    const total_rows: u32 = box_h + 1 + @as(u32, s.m) * 3 + 1;
    if (total_cols > @min(cols, max_cols) or total_rows > max_rows) return null;

    var canvas = try Canvas.init(allocator, @intCast(total_rows), @intCast(total_cols));
    defer canvas.deinit();

    var lifeline: [max_nodes]u16 = @splat(0);
    for (s.names[0..s.n], 0..) |name, i| {
        const col: u16 = @intCast(i * pitch);
        canvas.box(0, col, slot, box_h, name);
        lifeline[i] = col + slot / 2;
    }
    var r: u16 = box_h;
    while (r < total_rows) : (r += 1) {
        for (lifeline[0..s.n]) |c| canvas.line(r, c, '\u{2502}');
    }
    for (s.msgs[0..s.m], 0..) |msg, i| {
        const row: u16 = @intCast(box_h + 2 + i * 3);
        const from = lifeline[msg.from];
        const to = lifeline[msg.to];
        const rune: u21 = if (msg.dotted) '\u{2504}' else '\u{2500}';
        if (msg.from == msg.to) {
            canvas.put(row, from, '\u{2502}');
            canvas.text(row - 1, from + 2, msg.text);
            continue;
        }
        const lo = @min(from, to);
        const hi = @max(from, to);
        var c = lo;
        while (c <= hi) : (c += 1) canvas.put(row, c, rune);
        canvas.put(row, from, '\u{251c}');
        canvas.put(row, to, if (to > from) '\u{25b6}' else '\u{25c0}');
        canvas.text(row - 1, lo + 2, msg.text);
    }
    return try canvas.toOwned(allocator);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// The diagram as rows of box-drawing runes, or null when the source is not
/// something this renderer draws faithfully.
pub fn render(allocator: std.mem.Allocator, cols: u16, src: []const u8) !?[]u8 {
    const head = std.mem.trimStart(u8, src, " \t\r\n");
    if (std.mem.startsWith(u8, head, "sequenceDiagram")) {
        var s = Seq{};
        if (!parseSeq(src, &s)) return null;
        if (s.m == 0) return null;
        return drawSeq(allocator, &s, cols);
    }
    var g = Graph{};
    if (!parseFlow(src, &g)) return null;
    if (g.e == 0 and g.n < 2) return null;
    return drawFlow(allocator, &g, cols);
}

test "a chain of nodes is drawn left to right" {
    const a = std.testing.allocator;
    const out = (try render(a, 80, "graph LR\nA --> B --> C\n")).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{250c}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "C") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{25b6}") != null);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |row| try std.testing.expect(measure.cellsTo(row) <= 80);
}

test "a top-down graph stacks its layers" {
    const a = std.testing.allocator;
    const out = (try render(a, 80, "graph TD\nA[Start] --> B[Finish]\n")).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Finish") != null);
    // Down means the arrowhead points down, and the second box is lower.
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{25bc}") != null);
    const start = std.mem.indexOf(u8, out, "Start").?;
    const finish = std.mem.indexOf(u8, out, "Finish").?;
    try std.testing.expect(start < finish);
}

test "labels ride their edge" {
    const a = std.testing.allocator;
    const out = (try render(a, 80, "graph TD\nA -->|yes| B\n")).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "yes") != null);
}

test "a sequence diagram draws lifelines and messages" {
    const a = std.testing.allocator;
    const src = "sequenceDiagram\nAlice->>Bob: Hello\nBob-->>Alice: Hi\n";
    const out = (try render(a, 80, src)).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{25b6}") != null);
    // The reply is dotted, the way mermaid draws a response.
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2504}") != null);
}

test "what it cannot draw it declines to draw" {
    const a = std.testing.allocator;
    try std.testing.expect(try render(a, 80, "classDiagram\nAnimal <|-- Duck\n") == null);
    try std.testing.expect(try render(a, 80, "graph TD\nsubgraph one\nA-->B\nend\n") == null);
    const looped = "sequenceDiagram\nloop every minute\nA->>B: x\nend\n";
    try std.testing.expect(try render(a, 80, looped) == null);
    try std.testing.expect(try render(a, 80, "not a diagram at all\n") == null);
    // Too wide for the pane is a diagram worth less than its source.
    try std.testing.expect(try render(a, 10, "graph LR\nA --> B --> C --> D\n") == null);
}

test "a cycle settles instead of looping" {
    const a = std.testing.allocator;
    const out = (try render(a, 120, "graph TD\nA --> B\nB --> C\nC --> A\n")).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
}
