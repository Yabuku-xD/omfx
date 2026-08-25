//! Re-export display-cell arithmetic from core (shared with mermaid and CLI paint).
pub const measure = @import("../core/measure.zig");

pub const runeWidth = measure.runeWidth;
pub const utf8LenAt = measure.utf8LenAt;
pub const runeAt = measure.runeAt;
pub const utf8CompletePrefix = measure.utf8CompletePrefix;
pub const skipEsc = measure.skipEsc;
pub const cellsTo = measure.cellsTo;
pub const indexAtCell = measure.indexAtCell;
pub const utf8Prev = measure.utf8Prev;
pub const utf8Next = measure.utf8Next;
pub const wordByte = measure.wordByte;
pub const Fold = measure.Fold;
