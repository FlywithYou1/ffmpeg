#!/usr/bin/env bash
# Prepare pkg-config search paths and private fallback .pc overrides.
#
# System libraries link through their shared objects: distro .pc files often omit
# Libs.private, so force-static linking of those archives fails at configure time.
# package-runtime.py bundles the resulting shared deps and records their source.
set -Eeuo pipefail
P="${1:?Usage: $0 <prefix>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export FFMPEG_PKG_CONFIG="${FFMPEG_PKG_CONFIG:-$(command -v pkg-config)}"
MULTIARCH="$("${CC:-cc}" -print-multiarch)"
export PKG_CONFIG_PATH="$P/lib/pkgconfig:/usr/lib/$MULTIARCH/pkgconfig:${PKG_CONFIG_PATH:-}"
bash "$REPO_ROOT/scripts/ci/linux-pc-fallbacks.sh" "$P"
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'FFMPEG_PKG_CONFIG=%s\nPKG_CONFIG_PATH=%s\n' "$FFMPEG_PKG_CONFIG" "$PKG_CONFIG_PATH" >> "$GITHUB_ENV"
fi
