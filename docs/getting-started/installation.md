# Installation

Install omfx, review what the installer does, and verify the binary.

## Script install

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

By default the binary lands in `~/.local/bin/omfx`. Override with `OMFX_BIN_DIR`. Pin a release with `OMFX_VERSION=<tag>`.

Supported targets: macOS and Linux, `aarch64` and `x86_64`. The script checks `SHA256SUMS` before installing.

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

Re-run the install script. It always fetches the latest release unless `OMFX_VERSION` is set.
