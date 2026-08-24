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
pub const think_open = muted ++ "  Thinking" ++ reset ++ "\n";
// One blank row after the thought, so the reply is spaced from it the way
// every other block is spaced from its neighbour.
pub const think_close = reset ++ "\n\n";

test "accent is an SGR sequence" {
    const std = @import("std");
    try std.testing.expect(std.mem.startsWith(u8, accent, "\x1b["));
    try std.testing.expectEqualStrings(reset, "\x1b[0m");
}
