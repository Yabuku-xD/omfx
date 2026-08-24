# Troubleshooting

Common install, auth, and terminal problems.

## `omfx: command not found`

Add the install directory to `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Confirm with `omfx version`. Prefer `./zig-out/bin/omfx` when developing from this tree.

## Install checksum failure

The installer refuses a tarball that does not match `SHA256SUMS`. Retry when the release assets finish uploading, or set `OMFX_VERSION` to a known-good tag.

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

## Still stuck

`/doctor` (or `omfx doctor`), `/trace`, and `/feedback` collect local diagnostics. Traces stay on disk and do not upload prompts by default.
