# Oh My Fx

Tiny native coding agent (`omfx`). Native Zig core, full-screen sticky footer.

```bash
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

Re-run it to upgrade. Or build it:

```bash
zig build
./zig-out/bin/omfx --help
```

Requires [Zig 0.16.0+](https://ziglang.org/download/).

## Commands

```
omfx                         Interactive full-screen session
omfx ask <prompt>            One-shot request (no alt screen)
omfx doctor                  Print runtime status
omfx version                 Print version
omfx help [command]          Show help
```

Inside a session:

```
/login    numbered list of model providers; paste a key or complete OAuth
/web      numbered list of 23 search backends; keys, on/off, fallback order
/session  list or resume saved sessions
/help     more slash commands
```

`/web` stores keys in `~/.omfx/auth.json` and order in `~/.omfx/settings.json`. First working provider in the order wins; the rest are fallbacks. `order exa,tavily,duckduckgo` sets that chain. `off google` skips one. `test zig 0.16` runs the chain now.

Flags: `--provider <id>`, `--model <name>`, `--effort <none|low|medium|high>`, `--auto`, `--yolo`, `--prompt-permissions`, `--resume [last|id]`, `-h` / `--help`, `-V` / `--version`.

Authenticate inside a session with `/login` (native Zig, no Node). SuperGrok: pick `xai-oauth` from `/login`, then `./zig-out/bin/omfx --provider xai-oauth`.

Also: `anthropic`, `openai-codex`, `github-copilot`, `kimi-code`, or paste a key for Groq/OpenRouter/Ollama/…. Vercel is optional.

See `docs/plans/2026-08-20-001-feat-unix-coding-agent-plan.md`.
