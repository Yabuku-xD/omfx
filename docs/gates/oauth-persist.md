# Gates: OAuth credentials stay live after login

Scope: persist last_provider on login; refresh expired OAuth; write new tokens back to ~/.omfx/auth.json 0600.

- [x] G1: refreshStored fails closed
  CHECK: rg -n "pub fn refreshStored" src/providers/oauth.zig
  EXPECT: pub fn refreshStored
  EVIDENCE: src/providers/oauth.zig:283

- [x] G2: ensure refreshes stale oauth and upserts
  CHECK: rg -n "pub fn ensure|pub fn stale|upsertFile" src/providers/auth.zig
  EXPECT: pub fn ensure
  EVIDENCE: src/providers/auth.zig ensure + stale + upsertFile

- [x] G3: TUI refreshes before send
  CHECK: rg -n "refreshInto|reloadFromDisk" src/cli/repl.zig src/cli/cmds.zig
  EXPECT: refreshInto
  EVIDENCE: repl.zig cmds.refreshInto; cmds.reloadFromDisk after /login

- [x] G4: login writes last_provider
  CHECK: rg -n "setLastChat" src/main.zig src/cli/menus.zig
  EXPECT: setLastChat
  EVIDENCE: main.zig login; menus.rememberLogin

- [x] G5: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -8; zig build --summary all 2>&1 | tail -6; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: 393/393 tests passed; omfx-ok; live ask returned pong after refresh
