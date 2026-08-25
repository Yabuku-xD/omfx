const std = @import("std");

const width = @import("../../width.zig");
const paint = @import("../../../core/ansi.zig");

const cellsTo = width.cellsTo;
const indexAtCell = width.indexAtCell;
const skipEsc = width.skipEsc;

pub const Window = struct { slice: []const u8, park: u16, from: usize };

pub fn widestRow(bytes: []const u8) u16 {
    var widest: u16 = 0;
    var row: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\n' or bytes[i] == '\r') {
            widest = @max(widest, cellsTo(bytes[row..i]));
            i += 1;
            row = i;
            continue;
        }
        if (bytes[i] == 0x1b) {
            const end = skipEsc(bytes, i);
            if (end > i + 1 and (bytes[end - 1] == 'H' or bytes[end - 1] == 'f')) {
                widest = @max(widest, cellsTo(bytes[row..i]));
                row = end;
            }
            i = end;
            continue;
        }
        i += 1;
    }
    return @max(widest, cellsTo(bytes[row..]));
}

pub fn composerWindow(src: []const u8, caret: usize, cols: u16) Window {
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

pub fn sanitizeRow(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, src.len);
    for (src, 0..) |b, i| {
        out[i] = if (b == '\n' or b == '\r') ' ' else b;
    }
    return out;
}

pub fn padCells(allocator: std.mem.Allocator, src: []const u8, cols: u16) ![]u8 {
    const w = cellsTo(src);
    const extra: usize = if (w >= cols) 0 else cols - w;
    const out = try allocator.alloc(u8, src.len + extra);
    @memcpy(out[0..src.len], src);
    @memset(out[src.len..], ' ');
    return out;
}

pub fn clipCells(src: []const u8, cols: u16) []const u8 {
    if (cellsTo(src) <= cols) return src;
    return src[0..indexAtCell(src, cols)];
}

pub fn ruleLine(allocator: std.mem.Allocator, cols: u16) ![]u8 {
    const cell = "─";
    const n = if (cols == 0) 1 else cols;
    const out = try allocator.alloc(u8, cell.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        @memcpy(out[i * cell.len ..][0..cell.len], cell);
    }
    return out;
}

pub fn boxEdgeIn(allocator: std.mem.Allocator, cols: u16, left: []const u8, right: []const u8, color: []const u8) ![]u8 {
    const inner: u16 = if (cols >= 2) cols - 2 else 1;
    const mid = try ruleLine(allocator, inner);
    defer allocator.free(mid);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{ color, left, mid, right, paint.reset });
}

pub fn boxEdge(allocator: std.mem.Allocator, cols: u16, left: []const u8, right: []const u8) ![]u8 {
    return boxEdgeIn(allocator, cols, left, right, paint.border);
}

/// `left` flush left, `right` flush right, padded to `inner` cells.
///
/// When the pair does not fit, the right side wins and the left is trimmed to
/// what remains: the model and mode on the right identify the session, while
/// the hint on the left is a reminder you can lose. Previously neither was
/// clipped and the row simply ran past the terminal, tearing the footer at any
/// width narrower than hint + meta.
pub fn padPair(allocator: std.mem.Allocator, left: []const u8, right: []const u8, inner: u16) ![]u8 {
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
