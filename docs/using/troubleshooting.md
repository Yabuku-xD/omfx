# Troubleshooting

Common install, auth, diagnostics, and terminal problems.

## `omfx: command not found`

Add the install directory to `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Confirm with `omfx version`. Prefer `./zig-out/bin/omfx` when developing from this tree.

## Install checksum failure

The installer refuses a tarball that does not match `SHA256SUMS`. Retry when the release assets finish uploading, or set `OMFX_VERSION` to a known-good tag.

## `omfx update` fails

Confirm network access to `api.github.com` and `github.com`. If you hit rate limits on release metadata, set `GITHUB_TOKEN` or `GH_TOKEN`. Prefer `omfx update --check` before installing. From a source build, `update` still installs into the detected binary directory or `~/.local/bin` — it does not replace `./zig-out/bin/omfx` unless that is where the running binary lives.

## Not signed in

Run `/login` and finish OAuth or paste a key. Check `~/.omfx/auth.json` exists and is readable by your user. Stored OAuth wins over env API keys.

## Wrong model or empty list

`/models` uses the provider you are signed into. `/models refresh` refetches the live catalog. Some logins cap context length (`authCap`); the confirmation after picking a model names the window.

## Terminal looks broken

omfx uses an alt screen and raw mode. If an external editor or crash left the terminal odd:

```sh
reset
```

Mouse support is press, release, and drag only — not any-event tracking — so terminal drag-select still works.

## Permission denied on tools

Check `/permissions` and `/allowlist`. Plan mode blocks writes until `/plan go`. Yolo is session-only.

## Edits undone after write

The parse gate undoes an edit that left a previously clean file unparseable. Read the file again and make the edit whole. Type errors from `lsp:` lines do not undo the edit — only `diagnostics: findings` does.

## No `lsp:` lines after edits

One-shot LSP runs only after a clean parse, and only when that language's server is on `PATH` (for example `zls`, `gopls`, `rust-analyzer`, `typescript-language-server`). Missing binaries are skipped silently. Install the server you care about; omfx never bundles one.

## `/ide open` finds nothing

Install the editor's shell command (`code`, `cursor`, `zed`, …) so it appears on `PATH`. `/ide list` shows what omfx can see. Pin with `/ide cursor` or `/settings ide=cursor`.

## MCP server missing

Confirm the entry under `mcp` in `~/.omfx/settings.json` and that the `command` is on `PATH`. `/mcp` lists configured servers.

## Still stuck

`omfx doctor`, `/trace`, and `/feedback` collect local diagnostics. Traces stay on disk and do not upload prompts by default.
