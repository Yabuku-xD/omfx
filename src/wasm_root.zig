//! WASM-safe surface: layout + compaction + cli parse. No HTTP.
pub const compact = @import("core/compact.zig");
pub const tui = @import("cli/tui.zig");
pub const cli = @import("core/cli.zig");

test {
    _ = compact;
    _ = tui;
    _ = cli;
}
