const footer_mod = @import("footer.zig");
const paint_mod = @import("paint.zig");

pub const Transcript = paint_mod.Transcript;
pub const Layout = footer_mod.Layout;
pub const moveTo = footer_mod.moveTo;

pub const hide_cursor = paint_mod.hide_cursor;
pub const show_cursor = paint_mod.show_cursor;
pub const sync_begin = paint_mod.sync_begin;
pub const sync_end = paint_mod.sync_end;
pub const enter_alt = paint_mod.enter_alt;
pub const leave_alt = paint_mod.leave_alt;

pub const PaintError = paint_mod.PaintError;
pub const setScrollRegion = paint_mod.setScrollRegion;

pub const Turn = footer_mod.Turn;
pub const Hint = footer_mod.Hint;
pub const Footer = footer_mod.Footer;
pub const generating = footer_mod.generating;
pub const stop_hint = footer_mod.stop_hint;
pub const queued_hint = footer_mod.queued_hint;

pub const welcome = footer_mod.welcome;
pub const min_card_cols = footer_mod.min_card_cols;
pub const min_menu_cols = footer_mod.min_menu_cols;

pub const hintFor = footer_mod.hintFor;
pub const formatHeader = footer_mod.formatHeader;
pub const contextRow = footer_mod.contextRow;
pub const shortTokens = footer_mod.shortTokens;
pub const formatSlashMenu = footer_mod.formatSlashMenu;
pub const formatWelcome = footer_mod.formatWelcome;
pub const formatFooter = footer_mod.formatFooter;

pub const writeWelcome = paint_mod.writeWelcome;
pub const writeFooter = paint_mod.writeFooter;
pub const writeChrome = paint_mod.writeChrome;
pub const formatJumpPill = paint_mod.formatJumpPill;
pub const paintSequence = paint_mod.paintSequence;
pub const Sel = paint_mod.Sel;
pub const sel_off = paint_mod.sel_off;
pub const writeSelected = paint_mod.writeSelected;
pub const plainCells = paint_mod.plainCells;
pub const chromeOverlay = paint_mod.chromeOverlay;
pub const writeTranscript = paint_mod.writeTranscript;
pub const writeTranscriptOverlay = paint_mod.writeTranscriptOverlay;
pub const writePane = paint_mod.writePane;
pub const composerRow = paint_mod.composerRow;
pub const inComposer = paint_mod.inComposer;
pub const jump_label = paint_mod.jump_label;
