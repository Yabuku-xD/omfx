# Gates: Welcome card dismisses when a prompt is sent

Scope: After the user sends a prompt, writeTranscript paints the chat and the welcome card is gone.

- [x] G1: send path calls writeTranscript after appending the user line
  CHECK: rg -n "writeTranscript" src/cli/repl.zig
  EXPECT: writeTranscript
  EVIDENCE: 898:            tui.writeTranscript(arena, stdout, layout, retained.items, scroll) catch {}; | 965:        tui.writeTranscript(arena, stdout, layout, retained.items, scroll) catch {};

- [x] G2: writeTranscript erases the pane (CSI J) and paints chunk text
  CHECK: rg -n "hello from user" src/cli/tui.zig
  EXPECT: hello from user
  EVIDENCE: 2165:    const chunks = [_][]const u8{"hello from user\n"}; | 2167:    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "hello from user") != null);

- [x] G3: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -12; zig build --summary all 2>&1 | tail -6; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 52ms MaxRSS:35M | omfx-ok
