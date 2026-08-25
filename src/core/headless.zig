const std = @import("std");
const builtin = @import("builtin");

/// True when GUI apps (IDE, OS default handler, browser, $EDITOR) must not launch.
/// Tests always run headless; set `OMFX_HEADLESS=1` for scripted runs of the binary.
pub fn guiBlocked() bool {
    if (builtin.is_test) return true;
    const raw = std.c.getenv("OMFX_HEADLESS") orelse return false;
    const s = std.mem.span(raw);
    return s.len != 0 and !std.mem.eql(u8, s, "0");
}

test "tests always block gui" {
    try std.testing.expect(guiBlocked());
}
