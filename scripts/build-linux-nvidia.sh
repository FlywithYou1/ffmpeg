#!/usr/bin/env bash
# ============================================================
# FFmpeg + NVIDIA NVENC/CUDA + VMAF-CUDA (Ubuntu)
# ============================================================
set -Eeuo pipefail
trap 'echo "错误：第 ${LINENO} 行"; exit 1' ERR

ORIG_DIR="$(pwd)"
THREADS="${THREADS:-$(nproc)}"
P="${INSTALL_PREFIX:-${HOME}/ffmpeg-install}"

CUDA_HOME="${CUDA_HOME:-}"
if [ -z "${CUDA_HOME}" ]; then
  for d in /usr/local/cuda-* /usr/local/cuda /opt/cuda; do
    if [ -d "$d/bin" ] && [ -x "$d/bin/nvcc" ]; then CUDA_HOME="$d"; break; fi
  done
fi
[ -z "${CUDA_HOME}" ] && { echo "错误：未找到 CUDA"; exit 1; }

echo "=========================================="
echo "FFmpeg NVIDIA NVENC/CUDA (Ubuntu)"
echo "PREFIX: $P  THREADS: $THREADS  CUDA: $CUDA_HOME"
echo "=========================================="

export CUDA_PATH="${CUDA_HOME}" CUDACXX="${CUDA_HOME}/bin/nvcc"
export PATH="${CUDA_HOME}/bin:${P}/bin:${PATH}"
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${P}/lib:${LD_LIBRARY_PATH:-}"

# ---- 清理 ----
rm -rf "$P" /tmp/nv-codec-headers /tmp/vmaf /tmp/ffmpeg-src 2>/dev/null || true
mkdir -p "$P"/{bin,lib,include,lib/pkgconfig}

# ---- nv-codec-headers ----
echo "[1/5] nv-codec-headers"
cd /tmp && rm -rf nv-codec-headers
git clone --depth 1 https://git.ffmpeg.org/nv-codec-headers.git
cd nv-codec-headers
make -j"$THREADS" PREFIX=/usr/local && sudo make PREFIX=/usr/local install

# ---- VMAF-CUDA ----
echo "[2/5] VMAF-CUDA"
cd /tmp && rm -rf vmaf
git clone --depth 1 https://github.com/Netflix/vmaf.git
cd vmaf/libvmaf && rm -rf build
# ffnvcodec headers are in /usr/local/include (default path for all compilers)
export C_INCLUDE_PATH="${CUDA_HOME}/include:${C_INCLUDE_PATH:-}"
meson setup build --buildtype release --prefix="$P" --libdir=lib \
  -Denable_cuda=true -Dc_link_args="-lstdc++" -Dcpp_link_args="-lstdc++"
ninja -vC build && ninja -C build install

# ---- FFmpeg ----
echo "[3/5] FFmpeg"
cd /tmp && rm -rf ffmpeg-src
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
cd ffmpeg-src
./configure --prefix="$P" --pkg-config-flags="--static" \
  --extra-cflags="-I${P}/include -I${CUDA_HOME}/include" \
  --extra-ldflags="-L${P}/lib -L${CUDA_HOME}/lib64" \
  --extra-libs="-lpthread -lm -ldl -lstdc++" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-libvmaf --enable-ffnvcodec --enable-cuda-nvcc \
  --enable-cuvid --enable-nvenc --disable-libnpp \
  --enable-libmp3lame --enable-libfdk-aac --enable-sdl2 --disable-doc
make -j"$THREADS" && make install

# ---- 验证 + 输出 ----
echo "[4/5] 验证"
strip "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" 2>/dev/null || true
"$P/bin/ffmpeg" -version 2>&1 | head -n3
echo "--- NVENC ---"
"$P/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -E 'av1_nvenc|hevc_nvenc|h264_nvenc' || echo "(none)"
echo "--- VMAF ---"
"$P/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -i vmaf || echo "(none)"

echo "[5/5] 输出"
mkdir -p "$ORIG_DIR/output"
cp "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" "$ORIG_DIR/output/"
ls -lh "$ORIG_DIR/output/"
cd "$ORIG_DIR"
