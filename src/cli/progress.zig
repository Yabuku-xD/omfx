//! Re-export progress rendering from core (update uses this without importing cli).
pub const progress = @import("../core/progress.zig");

pub const barWidth = progress.barWidth;
pub const render = progress.render;
