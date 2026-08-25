//! Terminal input: bytes in, one `Event` out.
//!
//! Split from painting because the two share nothing. This half never allocates
//! and never writes; it only classifies what the terminal sent.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const tty = @import("../tty.zig");

pub const Event = union(enum) {
    byte: u8,
    rune: u21,
    enter,
    backspace,
    delete,
    left,
    right,
    home,
    end,
    kill_line,
    kill_to_start,
    kill_word,
    kill_word_right,
    /// Open the draft in $EDITOR and read it back.
    external_editor,
    yank,
    undo,
    redo,
    newline,
    redraw,
    history_prev,
    history_next,
    word_left,
    word_right,
    shift_tab,
    keys,
    interrupt,
    ctrl_d,
    palette,
    new_session,
    quit,
    yolo,
    sessions,
    ctrl_m,
    ctrl_enter,
    ctrl_b,
    ctrl_t,
    ctrl_r,
    ctrl_j,
    click: Click,
    /// Pointer moved with the left button held: a selection being drawn.
    drag: Click,
    /// Button let go, which is what commits a selection.
    release: Click,
    shift_left,
    shift_right,
    f2,
    paste_start,
    paste_end,
    eof,
    skip,
    esc,
    page_up,
    page_down,
    /// Mouse wheel: a few lines, not a whole page.
    scroll_up,
    scroll_down,
    up,
    down,
    tab,
    resize,
};

fn csiMods(params: []const u8) u32 {
    const semi = std.mem.lastIndexOfScalar(u8, params, ';') orelse return 1;
    return parseU32(params[semi + 1 ..]) orelse 1;
}

fn classifyFinal(final: u8, params: []const u8) Event {
    const mods = csiMods(params);
    const bits = if (mods == 0) @as(u32, 0) else mods - 1;
    const ctrl = bits & 4 != 0;
    const alt = bits & 2 != 0;
    const shift = bits & 1 != 0;
    return switch (final) {
        'A' => if (ctrl) .page_up else .up,
        'B' => if (ctrl) .page_down else .down,
        // Shift moves between turns rather than between characters: in the
        // scrollback there is no caret to walk, and jumping prompt to prompt
        // is what you want a modified arrow for.
        'C' => if (ctrl or alt) .word_right else if (shift) .shift_right else .right,
        'D' => if (ctrl or alt) .word_left else if (shift) .shift_left else .left,
        'H' => .home,
        'F' => .end,
        'Z' => .shift_tab,
        'Q' => .f2,
        'u' => classifyKitty(params),
        '~' => classifyTilde(params),
        'M', 'm' => if (params.len > 0 and params[0] == '<')
            classifyMouse(params, final == 'm')
        else
            .skip,
        else => if (shift and final == 'Z') .shift_tab else .skip,
    };
}

pub const Click = struct { row: u16, col: u16 };

fn mouseCell(params: []const u8, semi: usize) ?Click {
    const rest = params[semi + 1 ..];
    const semi2 = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
    const col = parseU32(rest[0..semi2]) orelse return null;
    const row = parseU32(rest[semi2 + 1 ..]) orelse return null;
    return .{
        .row = @intCast(@min(row, std.math.maxInt(u16))),
        .col = @intCast(@min(col, std.math.maxInt(u16))),
    };
}

/// Left press becomes a click; wheel scrolls the transcript a few lines;
/// everything else is consumed and dropped.
///
/// Wheel reports (bit 64) used to be thrown away so their printable payload
/// never landed in the composer — but that also meant the wheel did nothing.
/// Map them to scroll_up / scroll_down (line steps), not page keys: a full
/// page jump on every notch feels like teleporting to the ends.
/// Right and middle buttons stay ignored.
fn classifyMouse(raw: []const u8, release: bool) Event {
    // SGR reports lead with `<`; the numbers start after it.
    const params = if (raw.len != 0 and raw[0] == '<') raw[1..] else raw;
    const semi = std.mem.indexOfScalar(u8, params, ';') orelse return .skip;
    const btn = parseU32(params[0..semi]) orelse return .skip;
    // Bit 64 is the wheel: 64 up, 65 down (and 66/67 for tilt, ignored).
    if (btn & 64 != 0) {
        if (release) return .skip;
        // Low bit distinguishes up (0) from down (1); tilt has bits 0+1 set.
        if ((btn & 3) == 2 or (btn & 3) == 3) return .skip;
        return if ((btn & 1) == 0) .scroll_up else .scroll_down;
    }
    // Low two bits name the button; only the left one drives anything here.
    if (btn & 3 != 0) return .skip;
    const cell = mouseCell(params, semi) orelse return .skip;
    if (release) return .{ .release = cell };
    // Bit 32 is motion, which with a button held is a drag.
    if (btn & 32 != 0) return .{ .drag = cell };
    return .{ .click = cell };
}

/// X10 mouse: `ESC [ M` then three bytes each offset by 32. All three are
/// printable, so the sequence has to be consumed whole or it arrives as text.
/// omfx asks for SGR, so this only fires for a terminal that ignored that.
fn classifyX10(btn_c: u8, col_c: u8, row_c: u8) Event {
    const btn: u32 = if (btn_c >= 32) @as(u32, btn_c) - 32 else return .skip;
    if (btn & 64 != 0) {
        if ((btn & 3) == 2 or (btn & 3) == 3) return .skip;
        return if ((btn & 1) == 0) .scroll_up else .scroll_down;
    }
    if (btn & 32 != 0 or btn & 3 != 0) return .skip;
    return .{ .click = .{
        .col = if (col_c >= 32) @as(u16, col_c) - 32 else 1,
        .row = if (row_c >= 32) @as(u16, row_c) - 32 else 1,
    } };
}

fn classifyTilde(params: []const u8) Event {
    var nums: [3]u32 = .{ 0, 1, 0 };
    const n = csiInts(params, &nums);
    if (n == 0) return .skip;
    const code = nums[0];
    if (code == 27) {
        const bits = if (nums[1] == 0) @as(u32, 0) else nums[1] - 1;
        return decodeKey(nums[2], bits);
    }
    return switch (code) {
        3 => .delete,
        5 => .page_up,
        6 => .page_down,
        1, 7 => .home,
        4, 8 => .end,
        12 => .f2,
        200 => .paste_start,
        201 => .paste_end,
        else => .skip,
    };
}

fn csiInts(params: []const u8, out: *[3]u32) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |part| {
        if (n == out.len) break;
        const cut = std.mem.indexOfScalar(u8, part, ':') orelse part.len;
        out[n] = parseU32(part[0..cut]) orelse 0;
        n += 1;
    }
    return n;
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// CSI unicode-key-code ; modifiers : event-type u
fn classifyKitty(params: []const u8) Event {
    var nums: [3]u32 = .{ 0, 1, 1 };
    _ = csiInts(params, &nums);
    const code = nums[0];
    const mods = if (nums[1] == 0) @as(u32, 1) else nums[1];
    var ev_type: u32 = 1;
    const semi = std.mem.indexOfScalar(u8, params, ';') orelse 0;
    if (semi > 0) {
        const rest = params[semi + 1 ..];
        const colon2 = std.mem.indexOfScalar(u8, rest, ':');
        if (colon2) |c| {
            if (c + 1 < rest.len) ev_type = parseU32(rest[c + 1 ..]) orelse 1;
        }
    }
    if (ev_type == 3) return .skip;
    const bits = if (mods == 0) @as(u32, 0) else mods - 1;
    return decodeKey(code, bits);
}

fn decodeKey(code: u32, bits: u32) Event {
    const ctrl = bits & 4 != 0;
    const alt = bits & 2 != 0;
    const shift = bits & 1 != 0;
    if (code == 13) {
        if (ctrl) return .ctrl_enter;
        if (shift or alt) return .newline;
        return .enter;
    }
    if (code == 9) return if (shift) .shift_tab else .tab;
    if (ctrl and shift and (code == 'z' or code == 'Z')) return .redo;
    if (ctrl) return ctrlLetter(@truncate(if (code <= 126) code else 0));
    return switch (code) {
        27 => .esc,
        127, 8 => .backspace,
        'Z', 'z' => if (shift) .shift_tab else .{ .byte = @intCast(code) },
        else => printable(code),
    };
}

fn printable(code: u32) Event {
    if (code >= 32 and code <= 126) return .{ .byte = @intCast(code) };
    if (code > 127 and code <= std.math.maxInt(u21)) return .{ .rune = @intCast(code) };
    return .skip;
}

fn ctrlLetter(code: u8) Event {
    const c = std.ascii.toLower(code);
    return switch (c) {
        'a' => .home,
        'e' => .end,
        'k' => .kill_line,
        'u' => .kill_to_start,
        'w' => .kill_word,
        'd' => .ctrl_d,
        'g' => .external_editor,
        'c' => .interrupt,
        'p' => .palette,
        'n' => .new_session,
        'y' => .yank,
        'l' => .redraw,
        'x', '.' => .keys,
        'b' => .ctrl_b,
        'f' => .right,
        'm' => .ctrl_m,
        'o' => .yolo,
        's' => .sessions,
        'q' => .quit,
        'r' => .ctrl_r,
        't' => .ctrl_t,
        'j' => .ctrl_j,
        'z' => .undo,
        '_' => .undo,
        ',' => .f2,
        'i' => .ctrl_enter,
        else => .skip,
    };
}

/// One key or CSI sequence. Unknown CSI is `.skip` (never inserted).
pub fn takeEvent(src: []const u8) struct { ev: Event, n: usize } {
    if (src.len == 0) return .{ .ev = .eof, .n = 0 };
    const c = src[0];
    if (c == 0x1b) {
        if (src.len >= 2 and src[1] == '[') {
            var i: usize = 2;
            while (i < src.len) : (i += 1) {
                if (src[i] >= 0x40 and src[i] <= 0x7E) {
                    const params = src[2..i];
                    if ((src[i] == 'M' or src[i] == 'm') and (params.len == 0 or params[0] != '<')) {
                        if (src.len < i + 4) return .{ .ev = .skip, .n = src.len };
                        return .{ .ev = classifyX10(src[i + 1], src[i + 2], src[i + 3]), .n = i + 4 };
                    }
                    const ev = classifyFinal(src[i], params);
                    return .{ .ev = ev, .n = i + 1 };
                }
            }
            return .{ .ev = .skip, .n = src.len };
        }
        if (src.len >= 3 and src[1] == 'O') {
            return .{ .ev = classifyFinal(src[2], ""), .n = 3 };
        }
        if (src.len >= 2 and src[1] == 'O') return .{ .ev = .skip, .n = 2 };
        if (src.len >= 2) {
            if (altLetter(src[1])) |ev| return .{ .ev = ev, .n = 2 };
        }
        return .{ .ev = .esc, .n = 1 };
    }
    if (c == '\r' or c == '\n') return .{ .ev = .enter, .n = 1 };
    if (c == 0x7f or c == 0x08) return .{ .ev = .backspace, .n = 1 };
    if (c == 0x03) return .{ .ev = .interrupt, .n = 1 };
    if (c == 0x04) return .{ .ev = .ctrl_d, .n = 1 };
    if (c == 0x01) return .{ .ev = .home, .n = 1 };
    if (c == 0x05) return .{ .ev = .end, .n = 1 };
    if (c == 0x02) return .{ .ev = .ctrl_b, .n = 1 };
    if (c == 0x06) return .{ .ev = .right, .n = 1 };
    if (c == 0x0b) return .{ .ev = .kill_line, .n = 1 };
    if (c == 0x15) return .{ .ev = .kill_to_start, .n = 1 };
    if (c == 0x17) return .{ .ev = .kill_word, .n = 1 };
    // 0x07 is ctrl-g: hand the draft to $EDITOR.
    if (c == 0x07) return .{ .ev = .external_editor, .n = 1 };
    if (c == 0x0c) return .{ .ev = .redraw, .n = 1 };
    if (c == 0x10) return .{ .ev = .palette, .n = 1 };
    if (c == 0x0e) return .{ .ev = .new_session, .n = 1 };
    if (c == 0x0f) return .{ .ev = .yolo, .n = 1 };
    if (c == 0x11) return .{ .ev = .quit, .n = 1 };
    if (c == 0x12) return .{ .ev = .ctrl_r, .n = 1 };
    if (c == 0x13) return .{ .ev = .sessions, .n = 1 };
    if (c == 0x14) return .{ .ev = .ctrl_t, .n = 1 };
    if (c == 0x1a) return .{ .ev = .undo, .n = 1 };
    if (c == 0x18) return .{ .ev = .keys, .n = 1 };
    if (c == 0x19) return .{ .ev = .yank, .n = 1 };
    if (c == 0x1f) return .{ .ev = .undo, .n = 1 };
    if (c == '\t') return .{ .ev = .tab, .n = 1 };
    if (c < 0x20) return .{ .ev = .skip, .n = 1 };
    return .{ .ev = .{ .byte = c }, .n = 1 };
}

fn altLetter(c: u8) ?Event {
    return switch (c) {
        'b' => .word_left,
        'f' => .word_right,
        'd' => .kill_word_right,
        '\r', '\n' => .newline,
        else => null,
    };
}

pub const Perm = enum { allow, deny, always, quit };

pub fn pollEvent(reader: *Io.Reader, timeout_ms: i32) Event {
    if (builtin.os.tag == .windows) return nextEvent(reader);
    if (tty.takeResize()) return .resize;
    if (reader.bufferedLen() > 0) return nextEvent(reader);
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&fds, timeout_ms) catch return .skip;
    if (n == 0) {
        if (tty.takeResize()) return .resize;
        return .skip;
    }
    return nextEvent(reader);
}

pub fn nextEvent(reader: *Io.Reader) Event {
    const c = reader.takeByte() catch return .eof;
    if (c != 0x1b) {
        var one: [1]u8 = .{c};
        return takeEvent(&one).ev;
    }
    const second = reader.takeByte() catch return .skip;
    if (second == 'O') {
        const d = reader.takeByte() catch return .skip;
        return classifyFinal(d, "");
    }
    if (second != '[') return altLetter(second) orelse if (second == '\r' or second == '\n') .newline else .esc;
    var params: [64]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const d = reader.takeByte() catch return .skip;
        if (d >= 0x40 and d <= 0x7E) {
            if ((d == 'M' or d == 'm') and (n == 0 or params[0] != '<')) {
                const b0 = reader.takeByte() catch return .skip;
                const b1 = reader.takeByte() catch return .skip;
                const b2 = reader.takeByte() catch return .skip;
                return classifyX10(b0, b1, b2);
            }
            return classifyFinal(d, params[0..n]);
        }
        if (n < params.len) {
            params[n] = d;
            n += 1;
        }
    }
}

test "arrows are left and right not inserted" {
    try std.testing.expectEqual(Event.right, takeEvent("\x1b[C").ev);
    try std.testing.expectEqual(Event.left, takeEvent("\x1b[D").ev);
    try std.testing.expectEqual(Event.right, takeEvent("\x1bOC").ev);
    try std.testing.expectEqual(Event.home, takeEvent("\x1b[H").ev);
    try std.testing.expectEqual(Event.end, takeEvent("\x1b[F").ev);
    try std.testing.expectEqual(Event.delete, takeEvent("\x1b[3~").ev);
    try std.testing.expectEqual(Event.page_up, takeEvent("\x1b[5~").ev);
    try std.testing.expectEqual(Event.page_down, takeEvent("\x1b[6~").ev);
    try std.testing.expectEqual(Event.up, takeEvent("\x1b[A").ev);
    try std.testing.expectEqual(Event.down, takeEvent("\x1b[B").ev);
    try std.testing.expectEqual(Event.tab, takeEvent("\t").ev);
}
test "csi sequences do not become bytes" {
    try std.testing.expectEqual(Event.esc, takeEvent("\x1b").ev);
    try std.testing.expectEqual(Event.esc, takeEvent("\x1b[27u").ev);
    try std.testing.expectEqual(Event.esc, takeEvent("\x1b[27;1u").ev);
    try std.testing.expectEqual(Event.home, takeEvent("\x1b[97;5u").ev);
    try std.testing.expectEqual(Event.paste_start, takeEvent("\x1b[200~").ev);
    try std.testing.expectEqual(Event.paste_end, takeEvent("\x1b[201~").ev);
    try std.testing.expectEqual(Event.page_up, takeEvent("\x1b[1;5A").ev);
    try std.testing.expectEqual(Event.tab, takeEvent("\x1b[27;5;9~").ev);
}
test "kitty ctrl keys and unicode rune" {
    try std.testing.expectEqual(Event.end, takeEvent("\x1b[101;5u").ev);
    try std.testing.expectEqual(Event.kill_line, takeEvent("\x1b[107;5u").ev);
    try std.testing.expectEqual(Event.enter, takeEvent("\x1b[13u").ev);
    try std.testing.expectEqual(Event.skip, takeEvent("\x1b[97;5:3u").ev);
    switch (takeEvent("\x1b[12354u").ev) {
        .rune => |cp| try std.testing.expectEqual(@as(u21, 12354), cp),
        else => try std.testing.expect(false),
    }
}
test "enter and backspace decode" {
    try std.testing.expectEqual(Event.enter, takeEvent("\r").ev);
    try std.testing.expectEqual(Event.backspace, takeEvent("\x7f").ev);
    switch (takeEvent("a").ev) {
        .byte => |b| try std.testing.expectEqual(@as(u8, 'a'), b),
        else => try std.testing.expect(false),
    }
}
test "kitty shift-tab is shift_tab" {
    try std.testing.expectEqual(Event.shift_tab, takeEvent("\x1b[9;2u").ev);
    try std.testing.expectEqual(Event.shift_tab, takeEvent("\x1b[1;2Z").ev);
    try std.testing.expectEqual(Event.tab, takeEvent("\x1b[9u").ev);
}
test "grok chords decode from kitty and modify-other-keys" {
    try std.testing.expectEqual(Event.palette, takeEvent("\x1b[112;5u").ev);
    try std.testing.expectEqual(Event.new_session, takeEvent("\x1b[110;5u").ev);
    try std.testing.expectEqual(Event.ctrl_m, takeEvent("\x1b[109;5u").ev);
    try std.testing.expectEqual(Event.yolo, takeEvent("\x1b[111;5u").ev);
    try std.testing.expectEqual(Event.sessions, takeEvent("\x1b[115;5u").ev);
    try std.testing.expectEqual(Event.quit, takeEvent("\x1b[113;5u").ev);
    try std.testing.expectEqual(Event.keys, takeEvent("\x1b[46;5u").ev);
    try std.testing.expectEqual(Event.f2, takeEvent("\x1b[44;5u").ev);
    try std.testing.expectEqual(Event.f2, takeEvent("\x1b[12~").ev);
    try std.testing.expectEqual(Event.f2, takeEvent("\x1bOQ").ev);
    try std.testing.expectEqual(Event.ctrl_enter, takeEvent("\x1b[13;5u").ev);
    try std.testing.expectEqual(Event.ctrl_enter, takeEvent("\x1b[27;5;13~").ev);
    try std.testing.expectEqual(Event.newline, takeEvent("\x1b[27;2;13~").ev);
    try std.testing.expectEqual(Event.newline, takeEvent("\x1b[27;3;13~").ev);
    try std.testing.expectEqual(Event.redo, takeEvent("\x1b[122;6u").ev);
}
test "ctrl and alt letters map to editor verbs" {
    try std.testing.expectEqual(Event.palette, takeEvent("\x10").ev);
    try std.testing.expectEqual(Event.new_session, takeEvent("\x0e").ev);
    try std.testing.expectEqual(Event.yolo, takeEvent("\x0f").ev);
    try std.testing.expectEqual(Event.quit, takeEvent("\x11").ev);
    try std.testing.expectEqual(Event.sessions, takeEvent("\x13").ev);
    try std.testing.expectEqual(Event.ctrl_r, takeEvent("\x12").ev);
    try std.testing.expectEqual(Event.ctrl_t, takeEvent("\x14").ev);
    try std.testing.expectEqual(Event.ctrl_b, takeEvent("\x02").ev);
    try std.testing.expectEqual(Event.yank, takeEvent("\x19").ev);
    try std.testing.expectEqual(Event.undo, takeEvent("\x1f").ev);
    try std.testing.expectEqual(Event.undo, takeEvent("\x1a").ev);
    try std.testing.expectEqual(Event.redraw, takeEvent("\x0c").ev);
    try std.testing.expectEqual(Event.keys, takeEvent("\x18").ev);
    try std.testing.expectEqual(Event.interrupt, takeEvent("\x03").ev);
    try std.testing.expectEqual(Event.ctrl_d, takeEvent("\x04").ev);
    try std.testing.expectEqual(Event.word_left, takeEvent("\x1bb").ev);
    try std.testing.expectEqual(Event.word_right, takeEvent("\x1bf").ev);
    try std.testing.expectEqual(Event.kill_word_right, takeEvent("\x1bd").ev);
    try std.testing.expectEqual(Event.word_left, takeEvent("\x1b[1;5D").ev);
    try std.testing.expectEqual(Event.shift_tab, takeEvent("\x1b[Z").ev);
    try std.testing.expectEqual(Event.newline, takeEvent("\x1b[13;2u").ev);
    try std.testing.expectEqual(Event.newline, takeEvent("\x1b\r").ev);
}

test "ctrl-g asks for the external editor" {
    try std.testing.expectEqual(Event.external_editor, takeEvent("\x07").ev);
}

test "the pointer speaks click, drag, and release; the rest is swallowed" {
    switch (takeEvent("\x1b[<0;10;5M").ev) {
        .click => |c| {
            try std.testing.expectEqual(@as(u16, 10), c.col);
            try std.testing.expectEqual(@as(u16, 5), c.row);
        },
        else => try std.testing.expect(false),
    }
    // Bit 32 with the left button held: a drag, which draws a selection.
    switch (takeEvent("\x1b[<32;12;5M").ev) {
        .drag => |c| try std.testing.expectEqual(@as(u16, 12), c.col),
        else => try std.testing.expect(false),
    }
    // Lowercase final is the release, which commits the selection.
    switch (takeEvent("\x1b[<0;12;5m").ev) {
        .release => |c| try std.testing.expectEqual(@as(u16, 12), c.col),
        else => try std.testing.expect(false),
    }
    // Wheel scrolls a few lines; PageUp/Down stay full-page.
    try std.testing.expectEqual(Event.scroll_up, takeEvent("\x1b[<64;10;5M").ev);
    try std.testing.expectEqual(Event.scroll_down, takeEvent("\x1b[<65;10;5M").ev);
    try std.testing.expectEqual(Event.skip, takeEvent("\x1b[<2;10;5M").ev);
    // X10, for a terminal that ignored the SGR request.
    switch (takeEvent("\x1b[M !!").ev) {
        .click => {},
        else => try std.testing.expect(false),
    }
}
