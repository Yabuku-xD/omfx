# Gates: cli-design applied to omfx UI/UX

Scope: help leads with examples; errors are code + message + fix; usage is 2; config is 78; piped ask emits no SGR.

- [x] G1: help_text leads with Examples and documents Exit
  CHECK: rg -n "Examples:|Exit:" src/core/cli.zig
  EXPECT: Examples:
  EVIDENCE: 373:    try std.testing.expect(std.mem.indexOf(u8, help_text, "Examples:") != null); | 374:    try std.testing.expect(std.mem.indexOf(u8, help_text, "Exit:") != null);

- [x] G2: unknown command suggests a neighbor
  CHECK: rg -n "fn closestCommand" src/core/cli.zig
  EXPECT: closestCommand
  EVIDENCE: 301:pub fn closestCommand(name: []const u8) ?[]const u8 {

- [x] G3: Fail envelope has Error and Fix
  CHECK: rg -n "writeFail|Error: " src/core/cli.zig
  EXPECT: writeFail
  EVIDENCE: 389:        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Error: MISSING_PROMPT") != null); | 395:        writeFail(&aw.writer, true, fail);

- [x] G4: missing provider names a Fix
  CHECK: rg -n "Fix:" src/cli/run.zig
  EXPECT: Fix:
  EVIDENCE: 12:    \\Fix: omfx login | 84:    try std.testing.expect(std.mem.indexOf(u8, missing_key_text, "Fix: omfx login") != null);

- [x] G5: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -12; zig build --summary all 2>&1 | tail -6; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 52ms MaxRSS:35M | omfx-ok
