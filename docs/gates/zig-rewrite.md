# Gates: Zig rewrite of TUI/input/chat/mode

Scope: composition-root main, tagged-union Live, shared SGR, exclusive Surface. No leaf TUI in main.zig.

- [x] G1: main.zig has no Live struct and no runInteractive
  CHECK: python3 -c "from pathlib import Path; t=Path('src/main.zig').read_text(); print('gone' if 'fn runInteractive' not in t and 'const Live' not in t else 'still-there')"
  EXPECT: gone
  EVIDENCE: gone

- [x] G2: interactive path is omfx.repl.run
  CHECK: rg -n "repl\.run" src/main.zig
  EXPECT: repl.run
  EVIDENCE: 167:            try omfx.repl.run(gpa, arena, io, stdout, home, workspace, lookup, model_name, resolved, mode, parsed);

- [x] G3: Live is tagged union json | stream | tui
  CHECK: rg -n "json: Json|stream: Stream|tui: Tty" src/cli/live.zig
  EXPECT: stream: Stream
  EVIDENCE: 12:    stream: Stream, | 13:    tui: Tty,

- [x] G4: tui.zig does not import chat.zig
  CHECK: python3 -c "from pathlib import Path; t=Path('src/cli/tui.zig').read_text(); print('no-chat' if 'chat.zig' not in t else 'imports-chat')"
  EXPECT: no-chat
  EVIDENCE: no-chat

- [x] G5: tests and binary
  CHECK: zig build test --summary all 2>&1 | tail -12; zig build --summary all 2>&1 | tail -6; test -x zig-out/bin/omfx && echo omfx-ok
  EXPECT: omfx-ok
  EVIDENCE: +- compile exe omfx ReleaseFast native cached 53ms MaxRSS:35M | omfx-ok
