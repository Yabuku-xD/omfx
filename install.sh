#!/bin/sh
# Install omfx. Prefer `omfx update` once installed; re-running this script
# also upgrades (it always fetches the latest release unless OMFX_VERSION is set).
#
#   curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
#
# OMFX_VERSION pins a tag, OMFX_BIN_DIR moves the install directory.
set -eu

repo="Yabuku-xD/omfx"
bin_dir="${OMFX_BIN_DIR:-$HOME/.local/bin}"

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Darwin) os=macos ;;
  Linux) os=linux-musl ;;
  *) echo "omfx: no build for $os" >&2; exit 1 ;;
esac
case "$arch" in
  arm64 | aarch64) arch=aarch64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) echo "omfx: no build for $arch" >&2; exit 1 ;;
esac
target="$arch-$os"

if [ -n "${OMFX_VERSION:-}" ]; then
  base="https://github.com/$repo/releases/download/$OMFX_VERSION"
else
  base="https://github.com/$repo/releases/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar_name="omfx-$target.tar.gz"

echo "omfx: fetching $target"
curl -fsSL "$base/$tar_name" -o "$tmp/$tar_name"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"

# A tarball that runs as your user is worth checking before it does.
if command -v sha256sum >/dev/null 2>&1; then
  want=$(grep " $tar_name\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
  got=$(sha256sum "$tmp/$tar_name" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  want=$(grep " $tar_name\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
  got=$(shasum -a 256 "$tmp/$tar_name" | cut -d' ' -f1)
else
  echo "omfx: no sha256sum or shasum to verify with" >&2
  exit 1
fi
[ -n "$want" ] || { echo "omfx: $tar_name missing from SHA256SUMS" >&2; exit 1; }
[ "$want" = "$got" ] || { echo "omfx: checksum mismatch for $tar_name" >&2; exit 1; }

mkdir -p "$bin_dir"
tar -C "$tmp" -xzf "$tmp/$tar_name"
mv "$tmp/omfx" "$bin_dir/omfx"
chmod +x "$bin_dir/omfx"

echo "omfx: installed $("$bin_dir/omfx" version) to $bin_dir/omfx"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "omfx: add it to PATH -- export PATH=\"$bin_dir:\$PATH\"" ;;
esac
