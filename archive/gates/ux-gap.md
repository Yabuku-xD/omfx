# Gates: stop wiping the chat above the composer

Scope: writeChrome must not erase the transcript band unless a slash overlay is open. Generating stays visible. /copy must not flood the transcript.

- [x] G1: chrome only erases the overlay band when a menu is open
  CHECK: rg -n "overlayFor|\\.menu" src/cli/tui.zig
  EXPECT: overlayFor
  EVIDENCE: 852:    if (overlay_h > 0) {

- [x] G2: Generating transcript line is label-colored, not dim
  CHECK: rg -n "generating_line" src/cli/tui.zig
  EXPECT: paint.label
  EVIDENCE: 198:pub const generating_line = paint.label ++ generating ++ paint.reset ++ "\n"; | 1911:            try with_status.append(allocator, generating_line);

- [x] G3: copy does not append a second "copied last reply"
  CHECK: rg -n "copyNoteShown|copied last reply" src/cli/cmds.zig
  EXPECT: copyNoteShown
  EVIDENCE: 1771:    try std.testing.expect(copyNoteShown(&.{"copied last reply\n"})); | 1772:    try std.testing.expect(copyNoteShown(&.{ "hello\n", "copied last reply\n" }));

- [x] G4: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -6; zig build --summary all 2>&1 | tail -4; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 49ms MaxRSS:35M | omfx-ok
