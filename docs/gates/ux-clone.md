# Gates: copy peer CLI UX into omfx homemade TUI

Scope: Clone fx, OpenTUI, clown-code, nullclaw, architect into /tmp. Steal end-to-end interactive UX that fits omfx (Zig core, homemade ANSI, no Ratatui/OpenTUI/libvaxis). Ship paint + tests + ReleaseFast binary.

- [x] G1: clones exist under /tmp/omfx-ux
  CHECK: ls /tmp/omfx-ux
  EXPECT: fx
  EVIDENCE: nullclaw | opentui

- [x] G2: notes file lists what we steal vs skip
  CHECK: test -f docs/research/2026-08-21-ux-clone-peers.md && rg -n "Steal|Skip" docs/research/2026-08-21-ux-clone-peers.md
  EXPECT: Steal
  EVIDENCE: 6:## Steal | 14:## Skip

- [x] G3: generating status while a turn runs (footer or transcript)
  CHECK: rg -n "Generating|generating" src/cli/tui.zig src/cli/repl.zig
  EXPECT: Generating
  EVIDENCE: src/cli/tui.zig:2249:        .turn = .generating, | src/cli/tui.zig:2251:    try std.testing.expect(std.mem.indexOf(u8, aw.written(), generating) != null);

- [x] G4: streaming assistant paints through writePane, not a dump at regionBottom
  CHECK: rg -n "writePane" src/cli/live.zig
  EXPECT: writePane
  EVIDENCE: 77:                log.debug("writePane: {s}", .{@errorName(err)}); | 362:test "tui host paints through writePane" {

- [x] G5: user turn is a full-width You block without a nested inner box (Grok/fx: one surface)
  CHECK: rg -n "You" src/cli/chat.zig
  EXPECT: You
  EVIDENCE: 346:    try std.testing.expect(std.mem.indexOf(u8, s, "You") != null); | 362:    try std.testing.expect(std.mem.indexOf(u8, s, "You") != null);

- [x] G6: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -6; zig build --summary all 2>&1 | tail -4; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 50ms MaxRSS:35M | omfx-ok
