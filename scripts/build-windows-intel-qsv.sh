#!/usr/bin/env bash
# ============================================================
# FFmpeg + Intel QSV (oneVPL) + VMAF (Windows MSVC)
# VS 2026 Developer Command Prompt 环境下运行 Git Bash
# ============================================================
set -Eeuo pipefail
trap 'echo "错误：第 ${LINENO} 行"; exit 1' ERR

ORIG_DIR="$(pwd)"
THREADS="${THREADS:-$(nproc)}"
P="${INSTALL_PREFIX:-${HOME}/ffmpeg-install}"

command -v cl.exe >/dev/null 2>&1 || { echo "请先运行 vcvars64.bat (VS 2026)"; exit 1; }

# Ensure nasm is discoverable (required by ffmpeg x86/x64 assembly)
for nasm_dir in "/c/Program Files/NASM" "/c/Program Files (x86)/NASM" "/c/ProgramData/chocolatey/bin"; do
  if [ -f "$nasm_dir/nasm.exe" ]; then
    export PATH="$nasm_dir:$PATH"
    echo "nasm: $nasm_dir/nasm.exe"
    break
  fi
done
command -v nasm >/dev/null 2>&1 || echo "警告：未找到 nasm，ffmpeg 配置可能失败"

# Remove Strawberry Perl paths that shadow Git for Windows tools
__clean_path() {
  local __new="" __e
  IFS=':' read -ra __entries <<< "$PATH"
  for __e in "${__entries[@]}"; do
    case "$__e" in
      *[Ss]trawberry*) ;;
      *) __new="${__new:+${__new}:}${__e}" ;;
    esac
  done
  export PATH="$__new"
}
__clean_path

echo "=========================================="
echo "FFmpeg Intel QSV (Windows MSVC)"
echo "PREFIX: $P  THREADS: $THREADS"
echo "Compiler: $(cl.exe 2>&1 | head -n1 || echo MSVC)"
echo "=========================================="

export PATH="${P}/bin:${PATH}"

# Resolve default vcpkg root before pkg-config detection uses it.
VCPKG_INSTALLED="${VCPKG_INSTALLED:-}"
[ -z "${VCPKG_INSTALLED}" ] && [ -d "/c/vcpkg/installed/x64-windows" ] && VCPKG_INSTALLED="/c/vcpkg/installed/x64-windows"
[ -n "${VCPKG_INSTALLED}" ] && echo "vcpkg: $VCPKG_INSTALLED"

export PKG_CONFIG_PATH="${P}/lib/pkgconfig;${PKG_CONFIG_PATH:-}"
# Use Git for Windows' pkg-config; Strawberry Perl's pkg-config is broken.
# Use vcpkg's pkgconf if available, otherwise fall back to Git for Windows' pkg-config
if [ -n "${VCPKG_INSTALLED:-}" ]; then
  for pc in "${VCPKG_INSTALLED}/bin/pkgconf.exe" "${VCPKG_INSTALLED}/tools/pkgconf/pkgconf.exe" "${VCPKG_INSTALLED}/tools/pkgconf/pkg-config.exe"; do
    if [ -f "$pc" ]; then export PKG_CONFIG="$pc"; break; fi
  done
fi
export PKG_CONFIG="${PKG_CONFIG:-/usr/bin/pkg-config}"

# Ensure vcpkg dependencies are discoverable by pkg-config.
# vcpkg ports do not always ship pkg-config files, so create the ones ffmpeg expects.
if [ -n "${VCPKG_INSTALLED}" ] && [ -d "${VCPKG_INSTALLED}/lib/pkgconfig" ]; then
  VCPKG_INSTALLED_MIXED="$(cygpath -m "$VCPKG_INSTALLED" 2>/dev/null || echo "$VCPKG_INSTALLED" | tr '/\\' '/' 2>/dev/null | sed -e 's#^/c/#C:/#' -e 's#^/d/#D:/#')"

  find_import_lib() {
    for name in "$@"; do
      if [ -f "${VCPKG_INSTALLED}/lib/${name}.lib" ]; then
        echo "${name}.lib"
        return 0
      fi
    done
    return 1
  }

  mkdir -p "${VCPKG_INSTALLED}/lib/pkgconfig"

  lame_lib="$(find_import_lib mp3lame libmp3lame)" || { echo "错误：未找到 mp3lame import library"; exit 1; }
  cat > "${VCPKG_INSTALLED}/lib/pkgconfig/libmp3lame.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libmp3lame
Description: LAME MP3 encoder library
Version: 3.100
Libs: ${lame_lib}
EOF

  fdk_lib="$(find_import_lib fdk-aac libfdk-aac fdk-aac-2)" || { echo "错误：未找到 fdk-aac import library"; exit 1; }
  cat > "${VCPKG_INSTALLED}/lib/pkgconfig/libfdk-aac.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libfdk-aac
Description: Fraunhofer FDK AAC codec library
Version: 2.0.2
Libs: ${fdk_lib}
EOF

  vpl_lib="$(find_import_lib vpl libvpl)" || { echo "错误：未找到 vpl import library"; exit 1; }
  cat > "${VCPKG_INSTALLED}/lib/pkgconfig/vpl.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: vpl
Description: Intel oneVPL Dispatcher
Version: 2.16.0
Libs: ${vpl_lib}
EOF

  # 创建库名别名，避免 ffmpeg fallback 找不到文件
  ensure_lib_alias() {
    local actual="$1" alias="$2"
    if [ -f "${VCPKG_INSTALLED}/lib/${actual}" ] && [ ! -f "${VCPKG_INSTALLED}/lib/${alias}" ]; then
      cp "${VCPKG_INSTALLED}/lib/${actual}" "${VCPKG_INSTALLED}/lib/${alias}"
      echo "  alias: ${alias} -> ${actual}"
    fi
  }
  ensure_lib_alias "${lame_lib}" "mp3lame.lib"
  ensure_lib_alias "${lame_lib}" "libmp3lame.lib"
  ensure_lib_alias "${fdk_lib}" "fdk-aac.lib"
  ensure_lib_alias "${fdk_lib}" "libfdk-aac.lib"
  ensure_lib_alias "${vpl_lib}" "vpl.lib"
  ensure_lib_alias "${vpl_lib}" "libvpl.lib"

  export PKG_CONFIG_PATH="${VCPKG_INSTALLED}/lib/pkgconfig;${PKG_CONFIG_PATH:-}"
fi

# ---- 清理 ----
rm -rf "$P" /tmp/vmaf /tmp/ffmpeg-src 2>/dev/null || true
mkdir -p "$P"/{bin,lib,include,lib/pkgconfig}

# ---- VMAF (CPU) ----
echo "[1/4] VMAF"
cd /tmp && rm -rf vmaf
git clone --depth 1 https://github.com/Netflix/vmaf.git
cd vmaf/libvmaf && rm -rf build
# Ensure MSVC link.exe before Git's link.EXE for meson
CLDIR=$(dirname "$(which cl.exe 2>/dev/null)" 2>/dev/null || true)
[ -n "$CLDIR" ] && export PATH="${CLDIR}:${PATH}"
PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
meson setup build --buildtype release --prefix="$P" -Denable_cuda=false
ninja -vC build && ninja -C build install

# Ensure libvmaf.pc exists for ffmpeg configure (meson may omit it on Windows)
P_MIXED="$(cygpath -m "$P" 2>/dev/null || echo "$P")"
vmaf_lib="$(find "$P/lib" -maxdepth 1 \( -name 'vmaf.lib' -o -name 'libvmaf.lib' \) | head -n1)"
[ -z "$vmaf_lib" ] && { echo "错误：未找到 VMAF import library ($P/lib)"; exit 1; }
cat > "$P/lib/pkgconfig/libvmaf.pc" <<EOF
prefix=${P_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libvmaf
Description: Netflix VMAF library
Version: 3.0.0
Libs: $(basename "$vmaf_lib")
Cflags: -I\${includedir}
EOF

# ---- FFmpeg ----
echo "[2/4] FFmpeg (MSVC)"
cd /tmp && rm -rf ffmpeg-src
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
cd ffmpeg-src

VCPKG_CFLAGS=""; VCPKG_LDFLAGS=""
[ -n "${VCPKG_INSTALLED}" ] && VCPKG_CFLAGS="-I${VCPKG_INSTALLED}/include -I${VCPKG_INSTALLED}/include/vpl" && VCPKG_LDFLAGS="-LIBPATH:${VCPKG_INSTALLED}/lib"

./configure --toolchain=msvc --prefix="$P" \
  --extra-cflags="-I${P}/include ${VCPKG_CFLAGS}" \
  --extra-ldflags="-LIBPATH:${P}/lib ${VCPKG_LDFLAGS}" \
  --extra-libs="ole32.lib ws2_32.lib user32.lib bcrypt.lib" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-libvmaf --enable-libvpl \
  --enable-libmp3lame --enable-libfdk-aac --enable-sdl2 --disable-doc
make -j"$THREADS" && make install

# ---- 复制 DLL ----
echo "[3/4] DLL"
[ -n "${VCPKG_INSTALLED}" ] && [ -d "${VCPKG_INSTALLED}/bin" ] && \
  for dll in libmp3lame.dll fdk-aac-2.dll SDL2.dll zlib1.dll libvpl.dll; do
    [ -f "${VCPKG_INSTALLED}/bin/$dll" ] && cp "${VCPKG_INSTALLED}/bin/$dll" "$P/bin/" && echo "  $dll"
  done

# ---- 验证 + 输出 ----
echo "--- ffmpeg ---"
"$P/bin/ffmpeg.exe" -version 2>&1 | head -n3
echo "--- QSV ---"
"$P/bin/ffmpeg.exe" -hide_banner -encoders 2>&1 | grep '_qsv' | head -10 || echo "(none)"
echo "--- VMAF ---"
"$P/bin/ffmpeg.exe" -hide_banner -filters 2>&1 | grep -i vmaf || echo "(none)"

echo "[4/4] 输出"
mkdir -p "$ORIG_DIR/output"
cp "$P/bin/ffmpeg.exe" "$P/bin/ffprobe.exe" "$P/bin/ffplay.exe" "$ORIG_DIR/output/"
cp "$P/bin/"*.dll "$ORIG_DIR/output/" 2>/dev/null || true
ls -lh "$ORIG_DIR/output/"
cd "$ORIG_DIR"
