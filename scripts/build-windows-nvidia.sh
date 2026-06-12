#!/usr/bin/env bash
# ============================================================
# FFmpeg + NVIDIA NVENC/CUDA + VMAF-CUDA (Windows MSVC)
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

CUDA_HOME="${CUDA_HOME:-}"
if [ -z "${CUDA_HOME}" ]; then
  for d in "/c/Program Files/NVIDIA GPU Computing Toolkit/CUDA"/v*; do
    d2="$(cygpath -u "$d" 2>/dev/null || echo "$d")"
    if [ -d "${d2}/bin" ] && [ -f "${d2}/bin/nvcc.exe" ]; then CUDA_HOME="${d2}"; break; fi
  done
fi
[ -z "${CUDA_HOME}" ] && { echo "错误：未找到 CUDA"; exit 1; }

echo "=========================================="
echo "FFmpeg NVIDIA NVENC/CUDA (Windows MSVC)"
echo "PREFIX: $P  THREADS: $THREADS  CUDA: $CUDA_HOME"
echo "Compiler: $(cl.exe 2>&1 | head -n1 || echo MSVC)"
echo "=========================================="

export CUDA_PATH="${CUDA_HOME}" CUDACXX="${CUDA_HOME}/bin/nvcc"
export PATH="${CUDA_HOME}/bin:${P}/bin:${PATH}"
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

CL="${CUDA_HOME}/lib/x64"; [ ! -d "$CL" ] && CL="${CUDA_HOME}/lib"

VCPKG_INSTALLED="${VCPKG_INSTALLED:-}"
[ -z "${VCPKG_INSTALLED}" ] && [ -d "/c/vcpkg/installed/x64-windows" ] && VCPKG_INSTALLED="/c/vcpkg/installed/x64-windows"
[ -n "${VCPKG_INSTALLED}" ] && echo "vcpkg: $VCPKG_INSTALLED"

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
Cflags: -I\${includedir}
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
Cflags: -I\${includedir}
EOF

  export PKG_CONFIG_PATH="${VCPKG_INSTALLED}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

# ---- 清理 ----
rm -rf "$P" /tmp/nv-codec-headers /tmp/vmaf /tmp/ffmpeg-src 2>/dev/null || true
mkdir -p "$P"/{bin,lib,include,lib/pkgconfig}

# ---- nv-codec-headers ----
echo "[1/5] nv-codec-headers"
cd /tmp && rm -rf nv-codec-headers
git clone --depth 1 https://git.ffmpeg.org/nv-codec-headers.git
cd nv-codec-headers
make -j"$THREADS" PREFIX="$P" && make PREFIX="$P" install

# ---- VMAF-CUDA ----
echo "[2/5] VMAF-CUDA (MSVC)"
cd /tmp && rm -rf vmaf
git clone --depth 1 https://github.com/Netflix/vmaf.git
cd vmaf/libvmaf && rm -rf build
# nvcc fatbin does not pick up meson's cuda_args; use C_INCLUDE_PATH instead
export C_INCLUDE_PATH="${P}/include:${CUDA_HOME}/include:${C_INCLUDE_PATH:-}"
# Ensure MSVC link.exe before Git's link.EXE for meson
CLDIR=$(dirname "$(which cl.exe 2>/dev/null)" 2>/dev/null || true)
[ -n "$CLDIR" ] && export PATH="${CLDIR}:${PATH}"
meson setup build --buildtype release --prefix="$P" -Denable_cuda=true
ninja -vC build && ninja -C build install

# ---- FFmpeg ----
echo "[3/5] FFmpeg (MSVC)"
cd /tmp && rm -rf ffmpeg-src
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
cd ffmpeg-src

VCPKG_CFLAGS=""; VCPKG_LDFLAGS=""
[ -n "${VCPKG_INSTALLED}" ] && VCPKG_CFLAGS="-I${VCPKG_INSTALLED}/include" && VCPKG_LDFLAGS="-LIBPATH:${VCPKG_INSTALLED}/lib"

./configure --toolchain=msvc --prefix="$P" \
  --extra-cflags="-I${P}/include -I${CUDA_HOME}/include ${VCPKG_CFLAGS}" \
  --extra-ldflags="-LIBPATH:${P}/lib -LIBPATH:${CL} ${VCPKG_LDFLAGS}" \
  --extra-libs="ole32.lib ws2_32.lib user32.lib bcrypt.lib" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-libvmaf --enable-ffnvcodec --enable-cuda-nvcc \
  --enable-cuvid --enable-nvenc --disable-libnpp \
  --enable-libmp3lame --enable-libfdk-aac --enable-sdl2 --disable-doc
make -j"$THREADS" && make install

# ---- 复制 DLL ----
echo "[4/5] DLL"
[ -n "${VCPKG_INSTALLED}" ] && [ -d "${VCPKG_INSTALLED}/bin" ] && \
  for dll in libmp3lame.dll fdk-aac-2.dll SDL2.dll zlib1.dll; do
    [ -f "${VCPKG_INSTALLED}/bin/$dll" ] && cp "${VCPKG_INSTALLED}/bin/$dll" "$P/bin/" && echo "  $dll"
  done

# ---- 验证 + 输出 ----
echo "--- ffmpeg ---"
"$P/bin/ffmpeg.exe" -version 2>&1 | head -n3
echo "--- NVENC ---"
"$P/bin/ffmpeg.exe" -hide_banner -encoders 2>&1 | grep -E 'av1_nvenc|hevc_nvenc|h264_nvenc' || echo "(none)"
echo "--- VMAF ---"
"$P/bin/ffmpeg.exe" -hide_banner -filters 2>&1 | grep -i vmaf || echo "(none)"

echo "[5/5] 输出"
mkdir -p "$ORIG_DIR/output"
cp "$P/bin/ffmpeg.exe" "$P/bin/ffprobe.exe" "$P/bin/ffplay.exe" "$ORIG_DIR/output/"
cp "$P/bin/"*.dll "$ORIG_DIR/output/" 2>/dev/null || true
ls -lh "$ORIG_DIR/output/"
cd "$ORIG_DIR"
