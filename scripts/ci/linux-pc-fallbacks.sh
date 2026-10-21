#!/usr/bin/env bash
# Create private overrides; never modify distribution-owned pkg-config files.
set -Eeuo pipefail
P="${1:?Usage: $0 <install_prefix>}"
case "$P" in /|/usr|/usr/local) echo "Use a private install prefix" >&2; exit 1 ;; esac
mkdir -p "$P/lib/pkgconfig"
REAL_PKG_CONFIG="${FFMPEG_PKG_CONFIG:-pkg-config}"
MULTIARCH="${MULTIARCH:-$("${CC:-cc}" -print-multiarch)}"
[ -n "$MULTIARCH" ] || { echo "Unable to determine target multiarch" >&2; exit 1; }
export PKG_CONFIG_PATH="$P/lib/pkgconfig:/usr/lib/$MULTIARCH/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

port_version() {
  dpkg-query -W -f='${Version}' "$1" | sed -E 's/^[0-9]+://; s/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/'
}

for spec in 'libopenjp2:libopenjp2-7-dev:openjp2' 'x265:libx265-dev:x265'; do
  IFS=: read -r pc_name package library <<< "$spec"
  if "$REAL_PKG_CONFIG" --exists "$pc_name"; then
    continue
  fi
  version="$(port_version "$package")"
  include=/usr/include
  if [ "$pc_name" = libopenjp2 ]; then
    for candidate in /usr/include/openjpeg-*; do
      [ -d "$candidate" ] && { include="$candidate"; break; }
    done
  fi
  printf 'prefix=/usr\nlibdir=/usr/lib/%s\nincludedir=%s\nName: %s\nDescription: %s library\nVersion: %s\nLibs: -L${libdir} -l%s\nCflags: -I${includedir}\n' \
    "$MULTIARCH" "$include" "$pc_name" "$library" "$version" "$library" > "$P/lib/pkgconfig/$pc_name.pc"
  if [ "$pc_name" = x265 ]; then
    printf 'Libs.private: -lstdc++ -lm -lgcc -lpthread\n' >> "$P/lib/pkgconfig/$pc_name.pc"
  fi
 done

kvazaar_dir="$("$REAL_PKG_CONFIG" --variable=pcfiledir kvazaar)"
[ -f "$kvazaar_dir/kvazaar.pc" ] || { echo "Missing kvazaar.pc" >&2; exit 1; }
kvazaar_ver="$(port_version libkvazaar-dev)"
sed -E "s/^Version:.*/Version: $kvazaar_ver/" "$kvazaar_dir/kvazaar.pc" > "$P/lib/pkgconfig/kvazaar.pc.tmp"
mv "$P/lib/pkgconfig/kvazaar.pc.tmp" "$P/lib/pkgconfig/kvazaar.pc"
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'PKG_CONFIG_PATH=%s\n' "$PKG_CONFIG_PATH" >> "$GITHUB_ENV"
fi
"$REAL_PKG_CONFIG" --modversion libopenjp2 x265 kvazaar
