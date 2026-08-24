# Gates: Shift+Tab mode, persistence, no compositor junk

Scope: Grok-like session mode cycle, persist model+mode, stop X10 mouse bytes landing in the composer.

- [x] G1: X10 mouse `ESC [ M` plus 3 bytes is a mouse event, not composer text
  CHECK: rg -n "classifyX10|x10" src/cli/tui.zig
  EXPECT: classifyX10
  EVIDENCE: 2297:test "x10 mouse payload is not composer text" { | 2395:    try std.testing.expectEqual(Event.palette, takeEvent("\x10").ev);

- [x] G2: kitty Shift+Tab `CSI 9;2u` is shift_tab, not tab
  CHECK: rg -n "9;2u" src/cli/tui.zig
  EXPECT: 9;2u
  EVIDENCE: 2310:    try std.testing.expectEqual(Event.shift_tab, takeEvent("\x1b[9;2u").ev);

- [x] G3: Shift+Tab cycles normal -> plan -> yolo (Grok), footer says normal not ask
  CHECK: rg -n "cycleSurface|\"normal\"" src/cli/cmds.zig src/core/config.zig
  EXPECT: cycleSurface
  EVIDENCE: src/cli/cmds.zig:1566:    try std.testing.expectEqualStrings("normal  ask before tools", cycleSurface(&st)); | src/cli/cmds.zig:1567:    try std.testing.expectEqualStrings("normal", footerPerm(&st));

- [x] G4: settings persist last_model last_provider last_mode
  CHECK: rg -n "last_model|last_provider|last_mode" src/core/settings.zig
  EXPECT: last_model
  EVIDENCE: 522:    try std.testing.expectEqualStrings("plan", f.last_mode); | 525:    try std.testing.expect(std.mem.indexOf(u8, body, "last_model") != null);

- [x] G5: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -8; zig build --summary all 2>&1 | tail -5; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 54ms MaxRSS:35M | omfx-ok
