# Gates: match fx/Grok chat spacing and Generating

Scope: Pin the transcript above the composer, put Generating in the pane while a turn runs, restore the Grok You card with one blank row between turns.

- [x] G1: short chats sit above the footer, not under the header
  CHECK: rg -n -A6 "pub fn transcriptFirstRow" src/cli/tui.zig
  EXPECT: rows - vis
  EVIDENCE: 1927-pub fn restoreSequence() []const u8 { | 1928-    return leave_alt;

- [x] G2: Generating is a transcript line while the turn runs
  CHECK: rg -n "generating_line" src/cli/tui.zig src/cli/live.zig
  EXPECT: generating_line
  EVIDENCE: src/cli/tui.zig:198:pub const generating_line = paint.dim ++ generating ++ paint.reset ++ "\n"; | src/cli/tui.zig:1914:            try with_status.append(allocator, generating_line);

- [x] G3: You card is a full-width box with inset text, not a flush gray bar
  CHECK: rg -n "╭|You" src/cli/chat.zig
  EXPECT: ╭
  EVIDENCE: 396:    try std.testing.expect(std.mem.indexOf(u8, s, "╭") != null); | 405:test "formatUser has a blank row before You and after the box" {

- [x] G4: formatUser has a blank row before You and after the box
  CHECK: rg -n "blank row" src/cli/chat.zig
  EXPECT: blank row
  EVIDENCE: 93:/// User turn: blank row, You, full-width box with inset text, blank row. | 405:test "formatUser has a blank row before You and after the box" {

- [x] G5: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -6; zig build --summary all 2>&1 | tail -4; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 49ms MaxRSS:35M | omfx-ok
