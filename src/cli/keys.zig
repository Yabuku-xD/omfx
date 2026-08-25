//! Re-exported from `tui/events.zig` so existing `@import("keys.zig")` paths keep working.
pub const events = @import("tui/events.zig");

pub const Event = events.Event;
pub const Click = events.Click;
pub const Perm = events.Perm;
pub const takeEvent = events.takeEvent;
pub const pollEvent = events.pollEvent;
pub const nextEvent = events.nextEvent;
