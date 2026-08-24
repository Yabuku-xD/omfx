# Gates: Composer always shows typing; no vim mode

Scope: Typed keys always land in the composer. No hidden scrollback/vim keymap. Mouse wheel/page still scroll.

- [x] G1: hint bar says tab complete, not tab scroll
  CHECK: rg -n "tab complete" src/cli/tui.zig
  EXPECT: tab complete
  EVIDENCE: 393:    \\keys  enter send  tab complete  shift-tab mode  ctrl-p palette  ctrl-q quit  ? keys | 2124:    try std.testing.expect(std.mem.indexOf(u8, hint_bar, "tab complete") != null);

- [x] G2: no vim scroll letters g G or y-copy-when-focused in keys_sheet
  CHECK: python3 -c "from pathlib import Path; t=Path('src/cli/tui.zig').read_text(); print('gone' if '.name = \"g G\"' not in t and '.name = \"y\"' not in t else 'still-vim')"
  EXPECT: gone
  EVIDENCE: gone

- [x] G3: repl does not steal keys into scrollback focus
  CHECK: python3 -c "from pathlib import Path; t=Path('src/cli/repl.zig').read_text(); print('gone' if 'focus == .scrollback' not in t and 'tui.Focus' not in t else 'still-focus')"
  EXPECT: gone
  EVIDENCE: gone

- [x] G4: formatFooter still paints typed composer text
  CHECK: rg -n "hello world" src/cli/tui.zig
  EXPECT: hello world
  EVIDENCE: 2426:    try d.insertSlice(std.testing.allocator, "hello world"); | 2430:    try std.testing.expectEqualStrings("hello world", d.items());

- [x] G5: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -12; zig build --summary all 2>&1 | tail -6; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 53ms MaxRSS:35M | omfx-ok
