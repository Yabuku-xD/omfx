const types = @import("../types.zig");

/// One built-in model row. See `models.zig` for vendor effort notes.
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8,
    protocol: types.Protocol,
    base_url: []const u8,
    reasoning: bool,
    context_window: u32,
    max_tokens: u32,
    /// Empty, or comma-separated: minimal,low,medium,high,xhigh,max
    efforts: []const u8,
    vision: bool,
};
