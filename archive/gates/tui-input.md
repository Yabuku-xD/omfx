# Gates: Grok-style TUI keyboard and mouse

Scope: Port Grok Build CLI keyboard shortcuts and mouse functions into homemade Zig omfx (no Ratatui, no dashboard, no voice).

- [x] G1: Mouse SGR press, release, drag, hover, and wheel decode
  CHECK: rg -n "hover|right_click|classifyMouse" src/cli/tui.zig
  EXPECT: hover
  EVIDENCE: 2269:        .hover => |c| try std.testing.expectEqual(@as(u16, 3), c.col), | 2273:        .right_click => |c| try std.testing.expectEqual(@as(u16, 2), c.row),

- [x] G2: takeEvent maps Grok chords (ctrl-p palette, ctrl-n new, ctrl-q quit, ctrl-o yolo, ctrl-s sessions, ctrl-m, ctrl-enter, shift-enter, alt-enter, f2, ctrl-dot, 27;mod;key tilde)
  CHECK: rg -n "Event.palette|Event.ctrl_enter|Event.ctrl_m" src/cli/tui.zig
  EXPECT: Event.palette
  EVIDENCE: 2290:    try std.testing.expectEqual(Event.ctrl_enter, takeEvent("\x1b[27;5;13~").ev); | 2330:    try std.testing.expectEqual(Event.palette, takeEvent("\x10").ev);

- [x] G3: Hit-test helpers: composer row, transcript band, palette hover/click, caret-from-click
  CHECK: rg -n "caretFromClick|inComposer|inTranscript" src/cli/tui.zig
  EXPECT: caretFromClick
  EVIDENCE: 2303:    try std.testing.expect(inTranscript(layout, layout.transcript_start_row)); | 2304:    try std.testing.expect(!inTranscript(layout, layout.footer_start_row));

- [x] G4: tty enter enables button-event and all-motion mouse (1002/1003) plus 1000/1006
  CHECK: rg -n "1002h|1003h|1000h|1006h" src/cli/tty.zig
  EXPECT: 1002h
  EVIDENCE: 171:    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "1000h") != null); | 172:    try std.testing.expect(std.mem.indexOf(u8, enter_seq, "1006h") != null);

- [x] G5: keys_sheet lists chords (tab complete, shift-tab mode, ctrl-q quit, ctrl-p palette)
  CHECK: rg -n "tab complete|ctrl-q|ctrl-p palette|shift-tab" src/cli/tui.zig
  EXPECT: ctrl-p palette
  EVIDENCE: 1084:            .quit => "ctrl-q again to quit", | 2311:    try std.testing.expectEqualStrings("ctrl-q again to quit", a.note());

- [x] G6: command palette pick kind exists and applyPick dispatches the slash name
  CHECK: rg -n "fn fillCommands" src/cli/cmds.zig
  EXPECT: fillCommands
  EVIDENCE: 1108:pub fn fillCommands(state: *State) void {

- [x] G7: full test suite and release binary
  CHECK: zig build test 2>&1 | tail -6; zig build 2>&1 | tail -4; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: failed command: ./.zig-cache/o/f0fe0b69ea087bacdfc175bc7c7e1901/test --cache-dir=./.zig-cache --seed=0xddfbeab5 --listen=- | omfx-ok

- [x] G8: Feature sheet no longer says empty line quits; quit is a confirmed chord
  CHECK: rg -n "empty line quits|ctrl-q" src/cli/tui.zig
  EXPECT: ctrl-q
  EVIDENCE: 1084:            .quit => "ctrl-q again to quit", | 2311:    try std.testing.expectEqualStrings("ctrl-q again to quit", a.note());

ABANDON: dashboard Ctrl+\ and in-dashboard chords — omfx has no agent dashboard
ABANDON: voice Ctrl+Space / F8 — omfx has no mic pipeline
ABANDON: mermaid block viewer / fold / link o,O — omfx has no scrollback block model
ABANDON: tasks pane Ctrl+G and queue Ctrl+; — no side panes
ABANDON: vim-mode letter nav while typing — letters on scrollback-focus only; prompt still inserts
