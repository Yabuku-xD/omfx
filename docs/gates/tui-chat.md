# Gates: Grok-style transcript UI

Scope: Homemade Zig scrollback chrome for chats, tool cards, diffs, thinking. No Ratatui, no dashboard, no voice, no mermaid.

- [x] G1: chat.formatUser wraps a user turn as a You card with a hugging box, not a single clipped row
  CHECK: rg -n "pub fn formatUser" src/cli/chat.zig
  EXPECT: pub fn formatUser
  EVIDENCE: 84:pub fn formatUser(allocator: std.mem.Allocator, cols: u16, text: []const u8) ![]u8 {

- [x] G2: chat.formatDiff paints + green and - red for unified hunks
  CHECK: rg -n "diff_add|diff_del|formatDiff" src/cli/chat.zig
  EXPECT: formatDiff
  EVIDENCE: 330:    const s = try formatDiff(std.testing.allocator, 40, src); | 357:test "formatTool routes diffs to formatDiff" {

- [x] G3: chat.formatTool uses Grok verbs (Reading/Running/Edited) and truncates long output
  CHECK: rg -n "Reading|Running|Edited|max_preview" src/cli/chat.zig
  EXPECT: Reading
  EVIDENCE: 342:    try std.testing.expect(std.mem.indexOf(u8, s, "Reading") != null); | 361:    try std.testing.expect(std.mem.indexOf(u8, s, "Edited") != null);

- [x] G4: sink.Host.toolOut carries the tool body so the TUI can show results
  CHECK: rg -n "fn toolOut|body: \\[\\]const u8" src/core/sink.zig src/core/agent.zig
  EXPECT: toolOut
  EVIDENCE: src/core/sink.zig:84:        fn onTool(_: ?*anyopaque, name: []const u8, _: []const u8, done: bool, body: []const u8) void { | src/core/agent.zig:135:pub fn parseReflect(body: []const u8) Reflect {

- [x] G5: Live.tool retains a formatted card; formatUserLine uses the chat user block
  CHECK: rg -n "chat.formatTool|chat.formatUser" src/main.zig src/cli/tui.zig
  EXPECT: chat.formatTool
  EVIDENCE: src/main.zig:108:        const card = omfx.chat.formatTool(self.allocator, cols, name, detail, done, body) catch return; | src/cli/tui.zig:559:    return chat.formatUser(allocator, cols, text);

- [x] G6: markdown-lite turns headings, lists, and fences into SGR in assistant text
  CHECK: rg -n "formatAssistant|fence|heading" src/cli/chat.zig
  EXPECT: formatAssistant
  EVIDENCE: 365:test "formatAssistant paints heading list fence and code" { | 366:    const s = try formatAssistant(std.testing.allocator, "# Title\n- item\n```\ncode\n```\nuse `x` here\n");

- [x] G7: tests and release binary
  CHECK: zig build test --summary all 2>&1 | tail -8; zig build --summary all 2>&1 | tail -6; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 49ms MaxRSS:35M | omfx-ok

ABANDON: dashboard / voice / mermaid-in-TUI / syntax-highlighted syntect diffs — no those surfaces in omfx; diffs are unified + color, not syntect
