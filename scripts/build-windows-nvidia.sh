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
# vcpkg's mp3lame port does not ship a .pc file, so create one for ffmpeg.
if [ -n "${VCPKG_INSTALLED}" ] && [ -d "${VCPKG_INSTALLED}/lib/pkgconfig" ]; then
  VCPKG_INSTALLED_MIXED="$(cygpath -m "$VCPKG_INSTALLED" 2>/dev/null || echo "$VCPKG_INSTALLED" | tr '/\\' '/' 2>/dev/null | sed -e 's#^/c/#C:/#' -e 's#^/d/#D:/#')"
  if [ ! -f "${VCPKG_INSTALLED}/lib/pkgconfig/libmp3lame.pc" ]; then
    mkdir -p "${VCPKG_INSTALLED}/lib/pkgconfig"
    cat > "${VCPKG_INSTALLED}/lib/pkgconfig/libmp3lame.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libmp3lame
Description: LAME MP3 encoder library
Version: 3.100
Libs: -L\${libdir} libmp3lame.lib
Cflags: -I\${includedir}
EOF
  fi
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
# nvcc fatbin compilation does not pick up CFLAGS/CXXFLAGS; pass includes
# via CUDAFLAGS/CPPFLAGS and meson's cuda_args explicitly.
export CUDAFLAGS="-I${P}/include -I${CUDA_HOME}/include"
export CPPFLAGS="-I${P}/include -I${CUDA_HOME}/include"
PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
CFLAGS="-I${P}/include -I${CUDA_HOME}/include" \
CXXFLAGS="-I${P}/include -I${CUDA_HOME}/include" \
LDFLAGS="-LIBPATH:${P}/lib -LIBPATH:${CL}" \
meson setup build --buildtype release --prefix="$P" -Denable_cuda=true \
  -Dcuda_args="-I${P}/include -I${CUDA_HOME}/include"
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
