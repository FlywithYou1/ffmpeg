#!/usr/bin/env bash
# ============================================================
# FFmpeg + VideoToolbox + VMAF (macOS ARM / Apple Silicon)
# ============================================================
set -Eeuo pipefail
trap 'echo "错误：第 ${LINENO} 行"; exit 1' ERR

ORIG_DIR="$(pwd)"
THREADS="${THREADS:-$(sysctl -n hw.logicalcpu)}"
P="${INSTALL_PREFIX:-${HOME}/ffmpeg-install}"

echo "=========================================="
echo "FFmpeg VideoToolbox (macOS ARM)"
echo "PREFIX: $P  THREADS: $THREADS  ARCH: $(uname -m)"
echo "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
echo "=========================================="

command -v brew >/dev/null 2>&1 || { echo "请先安装 Homebrew: https://brew.sh"; exit 1; }

export PATH="${P}/bin:${PATH}"
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ---- 清理 ----
rm -rf "$P" /tmp/vmaf /tmp/ffmpeg-src 2>/dev/null || true
mkdir -p "$P"/{bin,lib,include,lib/pkgconfig}

# ---- VMAF (CPU) ----
echo "[1/4] VMAF"
cd /tmp && rm -rf vmaf
git clone --depth 1 https://github.com/Netflix/vmaf.git
cd vmaf/libvmaf && rm -rf build
PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
meson setup build --buildtype release --prefix="$P" -Denable_cuda=false
ninja -vC build && ninja -C build install

# ---- FFmpeg ----
echo "[2/4] FFmpeg"
# Homebrew 的 lame/fdk-aac 提供 lame.pc / fdk-aac.pc，
# 但 ffmpeg 需要 libmp3lame.pc / libfdk-aac.pc
HOMEBREW_PREFIX="$(brew --prefix)"
[ -f "${HOMEBREW_PREFIX}/lib/pkgconfig/lame.pc" ] && \
  ln -sf "${HOMEBREW_PREFIX}/lib/pkgconfig/lame.pc" "${P}/lib/pkgconfig/libmp3lame.pc"
[ -f "${HOMEBREW_PREFIX}/lib/pkgconfig/fdk-aac.pc" ] && \
  ln -sf "${HOMEBREW_PREFIX}/lib/pkgconfig/fdk-aac.pc" "${P}/lib/pkgconfig/libfdk-aac.pc"
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${HOMEBREW_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
cd /tmp && rm -rf ffmpeg-src
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
cd ffmpeg-src
./configure --prefix="$P" \
  --extra-cflags="-I${P}/include" \
  --extra-ldflags="-L${P}/lib" \
  --extra-libs="-lpthread -lm" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-libvmaf --enable-libmp3lame --enable-libfdk-aac \
  --enable-sdl2 --enable-videotoolbox --enable-audiotoolbox \
  --enable-hwaccel=h264_videotoolbox --enable-hwaccel=hevc_videotoolbox \
  --enable-hwaccel=vp9_videotoolbox --enable-hwaccel=prores_videotoolbox \
  --enable-hwaccel=av1_videotoolbox --disable-doc
make -j"$THREADS" && make install

# ---- 签名 + 验证 + 输出 ----
echo "[3/4] 签名 + 验证"
strip "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" 2>/dev/null || true
for bin in ffmpeg ffprobe ffplay; do codesign --force --sign - "$P/bin/$bin" 2>/dev/null || true; done
"$P/bin/ffmpeg" -version 2>&1 | head -n3
echo "--- VideoToolbox encoders ---"
"$P/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -iE 'h264_videotoolbox|hevc_videotoolbox|prores_videotoolbox' || echo "(none)"
echo "--- VideoToolbox decoders ---"
"$P/bin/ffmpeg" -hide_banner -decoders 2>&1 | grep -i videotoolbox || echo "(none)"
echo "--- VMAF ---"
"$P/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -i vmaf || echo "(none)"

echo "[4/4] 输出"
mkdir -p "$ORIG_DIR/output"
cp "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" "$ORIG_DIR/output/"
ls -lh "$ORIG_DIR/output/"
cd "$ORIG_DIR"
