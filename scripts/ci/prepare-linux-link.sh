#!/usr/bin/env bash
set -Eeuo pipefail
P="${1:?Usage: $0 <prefix> <work_dir>}"
WORK="${2:?Usage: $0 <prefix> <work_dir>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
mkdir -p "$WORK"
export FFMPEG_PKG_CONFIG="${FFMPEG_PKG_CONFIG:-$(command -v pkg-config)}"
MULTIARCH="$("${CC:-cc}" -print-multiarch)"
export PKG_CONFIG_PATH="$P/lib/pkgconfig:/usr/lib/$MULTIARCH/pkgconfig:${PKG_CONFIG_PATH:-}"
bash "$REPO_ROOT/scripts/ci/linux-pc-fallbacks.sh" "$P"
printf '#!/usr/bin/env bash\nexec python3 "%s/scripts/ci/prefer-static-pkg-config.py" "$@"\n' "$REPO_ROOT" > "$WORK/pkg-config-static"
chmod +x "$WORK/pkg-config-static"
mkdir -p "$WORK/static-libs"
for archive in /usr/lib/"$MULTIARCH"/*.a /usr/local/lib/*.a; do
  [ -f "$archive" ] || continue
  name="$(basename "$archive")"
  case "$name" in
    libc.a|libm.a|libm-*.a|libdl.a|libpthread.a|librt.a|libcuda.a|libnvidia-*.a) continue ;;
  esac
  ln -sf "$archive" "$WORK/static-libs/$name"
done
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'FFMPEG_PKG_CONFIG=%s\nPKG_CONFIG_PATH=%s\n' "$FFMPEG_PKG_CONFIG" "$PKG_CONFIG_PATH" >> "$GITHUB_ENV"
fi
