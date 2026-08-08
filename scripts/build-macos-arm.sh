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

# 确保 Vulkan / OpenCL 后端依赖存在
for pkg in molten-vk shaderc; do
  brew list "$pkg" &>/dev/null || brew install "$pkg"
done

# 确保软件编解码器依赖存在
for pkg in lame fdk-aac x264 x265 libvpx opus libvorbis libtheora aom webp libass freetype fontconfig zimg libsoxr openjpeg snappy sdl2 svt-av1 dav1d kvazaar openh264 xvid twolame speex codec2 jpeg-xl libopenmpt libbs2b aribb24 libplacebo rubberband vidstab; do
  brew list "$pkg" &>/dev/null || brew install "$pkg"
done

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
# Homebrew 的 lame 不带 .pc 文件，手动生成 libmp3lame.pc
LAME_PREFIX="$(brew --prefix lame)"
FDK_PREFIX="$(brew --prefix fdk-aac)"
LAME_INCLUDE=$(ls -d "${LAME_PREFIX}/include"/*/ 2>/dev/null | head -1 || echo "${LAME_PREFIX}/include")
LAME_LIB="${LAME_PREFIX}/lib"
cat > "${P}/lib/pkgconfig/libmp3lame.pc" <<LAMEPC
prefix=${LAME_PREFIX}
exec_prefix=\${prefix}
libdir=${LAME_LIB}
includedir=${LAME_INCLUDE}

Name: libmp3lame
Description: LAME MP3 encoder library
Version: 3.100
Libs: -L\${libdir} -lmp3lame
Cflags: -I\${includedir}
LAMEPC
# fdk-aac 有 .pc 但 ffmpeg 需要 libfdk-aac 名
[ -f "${FDK_PREFIX}/lib/pkgconfig/fdk-aac.pc" ] && \
  ln -sf "${FDK_PREFIX}/lib/pkgconfig/fdk-aac.pc" "${P}/lib/pkgconfig/libfdk-aac.pc"
BREW_PREFIX="$(brew --prefix)"
MVK_PREFIX="$(brew --prefix molten-vk 2>/dev/null || true)"
if [ -d "${MVK_PREFIX}/libexec/include" ]; then
  MVK_CFLAGS="-I${MVK_PREFIX}/libexec/include"
  MVK_LDFLAGS="-L${MVK_PREFIX}/lib -Wl,-rpath,${MVK_PREFIX}/lib"
else
  MVK_CFLAGS=""
  MVK_LDFLAGS=""
fi
# 复制并修复 Homebrew 的 .pc（macOS 没有 libstdc++）
for pc_dir in "${BREW_PREFIX}/lib/pkgconfig" /opt/homebrew/opt/*/lib/pkgconfig; do
  [ -d "$pc_dir" ] || continue
  for pc in "$pc_dir"/*.pc; do
    [ -f "$pc" ] || continue
    base=$(basename "$pc")
    sed 's/-lstdc++/-lc++/g' "$pc" > "${P}/lib/pkgconfig/$base"
  done
done
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${LAME_PREFIX}/lib/pkgconfig:${FDK_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
cd /tmp && rm -rf ffmpeg-src
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
cd ffmpeg-src
# macOS 使用 libc++，configure 里 libsnappy 的 -lstdc++ 会导致检测失败
sed -i.bak 's/require libsnappy snappy-c.h snappy_compress -lsnappy -lstdc++/require libsnappy snappy-c.h snappy_compress -lsnappy/' configure
rm -f configure.bak
./configure --prefix="$P" \
  --extra-cflags="-I${P}/include -I${BREW_PREFIX}/include -I${LAME_PREFIX}/include -I${FDK_PREFIX}/include ${MVK_CFLAGS}" \
  --extra-ldflags="-L${P}/lib -L${BREW_PREFIX}/lib -L${LAME_PREFIX}/lib -L${FDK_PREFIX}/lib ${MVK_LDFLAGS}" \
  --extra-libs="-lpthread -lm" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-libvmaf \
  --enable-opencl --enable-vulkan \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis --enable-libtheora --enable-libaom --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libzimg --enable-libsoxr --enable-libopenjpeg --enable-libsnappy \
  --enable-libsvtav1 --enable-libdav1d --enable-libkvazaar --enable-libopenh264 --enable-libxvid --enable-libtwolame --enable-libspeex --enable-libcodec2 --enable-libjxl --enable-libopenmpt --enable-libbs2b --enable-libaribb24 --enable-libplacebo --enable-librubberband --enable-libvidstab \
  --enable-libmp3lame --enable-libfdk-aac --enable-sdl2 \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-hwaccel=h264_videotoolbox --enable-hwaccel=hevc_videotoolbox \
  --enable-hwaccel=vp9_videotoolbox --enable-hwaccel=prores_videotoolbox \
  --enable-hwaccel=av1_videotoolbox --disable-doc
make -j"$THREADS" && make install

# ---- 签名 + 验证 + 输出 ----
echo "[3/4] 签名 + 验证"
strip "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" 2>/dev/null || true
for bin in ffmpeg ffprobe ffplay; do codesign --force --sign - "$P/bin/$bin" 2>/dev/null || true; done
"$P/bin/ffmpeg" -version 2>&1 | head -n3
echo "--- HW Accel Methods ---"
"$P/bin/ffmpeg" -hide_banner -hwaccels 2>&1 || echo "(none)"
echo "--- VideoToolbox encoders ---"
"$P/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -iE 'h264_videotoolbox|hevc_videotoolbox|prores_videotoolbox' || echo "(none)"
echo "--- VT hwaccel decode support (via -hwaccel videotoolbox) ---"
# Modern ffmpeg (6.0+) uses the hwaccel framework for VT decoding, not standalone decoder wrappers.
# Each --enable-hwaccel=xxx_videotoolbox registers a codec backend under the unified 'videotoolbox' hwaccel.
echo "  hwaccel videotoolbox: $("$P/bin/ffmpeg" -hide_banner -hwaccels 2>&1 | grep -q videotoolbox && echo YES || echo NO)"
for c in h264 hevc vp9 prores av1; do
  echo "  hw-codec ${c}: $("$P/bin/ffmpeg" -hide_banner -hwaccel videotoolbox -codecs 2>&1 | grep -i "${c}" | head -1 || echo '(not listed)')"
done
echo "--- VMAF ---"
"$P/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -i vmaf || echo "(none)"

echo "[4/4] 输出"
mkdir -p "$ORIG_DIR/output"
cp "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" "$ORIG_DIR/output/"
ls -lh "$ORIG_DIR/output/"
cd "$ORIG_DIR"
