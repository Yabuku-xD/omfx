//! Shared SGR. TUI chrome and transcript cards must not drift.
//!
//! One brand hue (mint) plus a single neutral grey ramp. Anything that is not
//! the accent is a step on that ramp, so nothing competes for attention.

pub const reset = "\x1b[0m";
pub const dim = "\x1b[2m";
pub const italic = "\x1b[3m";
pub const bold = "\x1b[1m";

/// Brand + selection. The only saturated colour in the chrome.
pub const accent = "\x1b[38;2;94;234;212m";
/// Accent at rest: gutters, active rules, ok marks.
pub const accent_dim = "\x1b[38;2;56;158;144m";

/// Neutral ramp, dark to light.
pub const border = "\x1b[38;2;58;58;66m";

/// Rules that carry structure rather than framing it: a table's grid and a
/// diagram's edges are part of the content, and at `border`'s weight they
/// vanish before the text they are meant to organise.
pub const grid = asst_fg;
pub const muted = "\x1b[38;2;108;108;120m";
pub const label = "\x1b[38;2;148;148;160m";
pub const asst_fg = "\x1b[38;2;206;212;222m";
pub const user_fg = "\x1b[38;2;232;236;242m";

/// Was a second, clashing green. Kept as a name so call sites read intent.
pub const rule = accent_dim;

/// Inline `code`: a plate, not a colour, so it does not fight the brand hue.
/// Warm dark neutral rather than the blue-grey the rest of the palette uses:
/// an inline span reads as a chip lifted off the page, and a cool background
/// at this lightness disappears into the pane behind it.
pub const code_bg = "\x1b[48;2;68;63;59m";
pub const code_fg = "\x1b[38;2;186;192;204m";
pub const warn = "\x1b[38;2;250;204;21m";
pub const el = "\x1b[K";
pub const add_fg = "\x1b[38;2;110;231;183m";
pub const add_bg = "\x1b[48;2;14;38;30m";
pub const del_fg = "\x1b[38;2;248;113;113m";
pub const del_bg = "\x1b[48;2;44;18;18m";
pub const hunk = "\x1b[38;2;125;211;252m";
/// Marks the row the keyboard is on. Only ever painted over a marker glyph:
/// a whole row cannot carry it, because the row's own resets end it.
pub const sel_bg = "\x1b[48;2;30;58;54m";
pub const think_open = "\n" ++ muted ++ "  Thinking" ++ reset ++ "\n\n";
// Blank row after the thought so the reply is spaced from it the way every
// other block is spaced from its neighbour.
pub const think_close = reset ++ "\n\n";

test "accent is an SGR sequence" {
    const std = @import("std");
    try std.testing.expect(std.mem.startsWith(u8, accent, "\x1b["));
    try std.testing.expectEqualStrings(reset, "\x1b[0m");
}

/// Tool output (shell commands, files, web pages, MCP replies) is untrusted
/// text bound for the user's terminal. Left raw, it can retitle the window
/// (OSC 0), write the clipboard (OSC 52), clear or scroll the screen, move the
/// cursor to overwrite earlier rows, or answer terminal queries as if typed.
///
/// Colour (SGR, `ESC [ ... m`) is kept: it cannot move or query anything, and
/// test runners and omfx's own task list rely on it. Every other escape and C0
/// control except newline and tab becomes visible caret text (`^[`, `^G`), so
/// the bytes stay inspectable. A bare carriage return is dropped: it would let
/// a line paint over itself.
pub fn safeForTerminal(allocator: @import("std").mem.Allocator, s: []const u8) ![]u8 {
    return defang(allocator, s, true);
}

/// For text a decision rests on (the permission box): colour is escaped too,
/// since concealed (`ESC[8m`) or black-on-black text can hide part of a
/// command from the person approving it.
pub fn plainForTerminal(allocator: @import("std").mem.Allocator, s: []const u8) ![]u8 {
    return defang(allocator, s, false);
}

fn defang(allocator: @import("std").mem.Allocator, s: []const u8, keep_sgr: bool) ![]u8 {
    const std = @import("std");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            if (if (keep_sgr) sgrLen(s[i..]) else null) |n| {
                try out.appendSlice(allocator, s[i .. i + n]);
                i += n;
                continue;
            }
            try out.appendSlice(allocator, "^[");
            i += 1;
            continue;
        }
        // UTF-8 encoded C1 controls (U+0080..U+009F): CSI is U+009B, and some
        // terminals honour it exactly like ESC [.
        if (c == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) {
            try out.appendSlice(allocator, "\u{fffd}");
            i += 2;
            continue;
        }
        switch (c) {
            '\n', '\t' => try out.append(allocator, c),
            '\r' => {},
            0...0x08, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f => {
                try out.append(allocator, '^');
                try out.append(allocator, c + 0x40);
            },
            0x7f => try out.appendSlice(allocator, "^?"),
            else => try out.append(allocator, c),
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Length of a complete `ESC [ params m` at the start of `s`, else null.
fn sgrLen(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != 0x1b or s[1] != '[') return null;
    var j: usize = 2;
    while (j < s.len) : (j += 1) {
        const d = s[j];
        if ((d >= '0' and d <= '9') or d == ';' or d == ':') continue;
        if (d == 'm') return j + 1;
        return null;
    }
    return null;
}

test "safeForTerminal keeps colour and defangs everything else" {
    const std = @import("std");
    const a = std.testing.allocator;
    const raw = "ok \x1b[32mgreen\x1b[0m\x1b]0;PWNED\x07\x1b]52;c;ZXZpbA==\x07\x1b[2J\x1b[1;1H\x1b[6n\rspoof\n\ttab\x08\x7f\xc2\x9b2J";
    const got = try safeForTerminal(a, raw);
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "ok \x1b[32mgreen\x1b[0m^[]0;PWNED^G^[]52;c;ZXZpbA==^G^[[2J^[[1;1H^[[6nspoof\n\ttab^H^?\u{fffd}2J",
        got,
    );
    // Nothing that can move, clear, query, or title survives.
    var k: usize = 0;
    while (std.mem.indexOfScalarPos(u8, got, k, 0x1b)) |at| : (k = at + 1) {
        try std.testing.expect(sgrLen(got[at..]) != null);
    }
}

test "safeForTerminal leaves plain text and UTF-8 alone" {
    const std = @import("std");
    const a = std.testing.allocator;
    const text = "héllo — 世界 ✓\nline two\n";
    const got = try safeForTerminal(a, text);
    defer a.free(got);
    try std.testing.expectEqualStrings(text, got);
}

test "plainForTerminal escapes colour as well" {
    const std = @import("std");
    const a = std.testing.allocator;
    const got = try plainForTerminal(a, "rm -rf ~ \x1b[8m# just listing files\x1b[0m");
    defer a.free(got);
    try std.testing.expectEqualStrings("rm -rf ~ ^[[8m# just listing files^[[0m", got);
}
