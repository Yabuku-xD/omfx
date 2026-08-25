#!/bin/sh
# Install a local zig build into ~/.local/bin without corrupting a live binary.
# Never `cp` over omfx — macOS will SIGKILL the next launch (exit 137).
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
zig build
bin_dir="${OMFX_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$bin_dir"
mv "$root/zig-out/bin/omfx" "$bin_dir/omfx.new"
mv "$bin_dir/omfx.new" "$bin_dir/omfx"
chmod +x "$bin_dir/omfx"
echo "installed $("$bin_dir/omfx" version) -> $bin_dir/omfx"
