# Installation

Install omfx, review what the installer does, and verify the binary.

## Script install

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

By default the binary lands in `~/.local/bin/omfx`. Override with `OMFX_BIN_DIR`. Pin a release with `OMFX_VERSION=<tag>`.

Supported targets: macOS and Linux, `aarch64` and `x86_64`. The script checks `SHA256SUMS` before installing. Language servers and IDE CLIs used by omfx are not installed by this script — add them to `PATH` yourself if you want one-shot LSP or `/ide open`.

If the shell cannot find `omfx`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Build from source

```sh
zig build
./zig-out/bin/omfx version
```

Use the binary at `./zig-out/bin/omfx`, not an older copy on your `PATH`. `zig build` produces ReleaseFast; `zig build test` stays Debug.

## Verify

```sh
omfx version
omfx doctor
omfx --help
```

## Upgrade

```sh
omfx update
omfx update --check    # report whether a newer release exists
omfx update --force    # reinstall even when already current
```

`omfx update` fetches the latest GitHub release and runs the same install path as a fresh install (checksum verified). It keeps the binary in the directory of the running executable when that can be detected, otherwise `~/.local/bin`.

If GitHub rate-limits release metadata, set `GITHUB_TOKEN` or `GH_TOKEN`.

You can still re-run the install script directly; it always fetches the latest release unless `OMFX_VERSION` is set.
