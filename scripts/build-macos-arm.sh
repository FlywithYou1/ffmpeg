#!/usr/bin/env bash
# ============================================================
# FFmpeg + VideoToolbox + VMAF (macOS ARM / Apple Silicon)
# ============================================================
set -Eeuo pipefail
trap 'echo "错误：第 ${LINENO} 行"; exit 1' ERR

source "$(dirname "${BASH_SOURCE[0]}")/build-env.sh"
init_build_env "$0"
THREADS="${THREADS:-$(sysctl -n hw.logicalcpu)}"
[ "$(uname -m)" = arm64 ] || { echo "This build requires Apple Silicon" >&2; exit 1; }

echo "=========================================="
echo "FFmpeg VideoToolbox (macOS ARM)"
echo "PREFIX: $P  THREADS: $THREADS  ARCH: $(uname -m)"
echo "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
echo "=========================================="

command -v brew >/dev/null 2>&1 || { echo "请先安装 Homebrew: https://brew.sh"; exit 1; }

# 确保 Vulkan / OpenCL 后端依赖存在
for pkg in meson ninja pkg-config cmake molten-vk shaderc nasm; do
  brew list "$pkg" &>/dev/null || brew install "$pkg"
done

# 确保软件编解码器依赖存在
for pkg in x264 x265 libvpx opus libvorbis theora aom webp libass freetype fontconfig zimg libsoxr openjpeg snappy sdl2 svt-av1 dav1d kvazaar openh264 xvid twolame speex codec2 jpeg-xl libopenmpt libbs2b aribb24 libplacebo rubberband libvidstab; do
  brew list "$pkg" &>/dev/null || brew install "$pkg"
done

export PATH="${P}/bin:${PATH}"
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"


export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC=clang CXX=clang++ OBJC=clang
export CFLAGS="${CFLAGS:-} -isysroot $SDKROOT"
export CXXFLAGS="${CXXFLAGS:-} -isysroot $SDKROOT"
export LDFLAGS="${LDFLAGS:-} -isysroot $SDKROOT"

# ---- VMAF (CPU) ----
echo "[1/4] VMAF"
git clone --depth 1 https://github.com/Netflix/vmaf.git "$BUILD_ROOT/vmaf"
cd "$BUILD_ROOT/vmaf/libvmaf"
PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
meson setup build --buildtype release --prefix="$P" --libdir=lib -Ddefault_library=static \
  -Denable_cuda=false -Denable_tests=false -Denable_tools=false -Denable_docs=false
ninja -vC build && ninja -C build install
mkdir -p "$P/share/libvmaf"
cp "$BUILD_ROOT/vmaf/LICENSE" "$P/share/libvmaf/copyright"

# ---- FFmpeg ----
echo "[2/4] FFmpeg"
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
    [ "$base" != libvmaf.pc ] || continue
    sed 's/-lstdc++/-lc++/g' "$pc" > "${P}/lib/pkgconfig/$base"
  done
done
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git "$BUILD_ROOT/ffmpeg-src"
cd "$BUILD_ROOT/ffmpeg-src"
# macOS 使用 libc++，configure 里 libsnappy 的 -lstdc++ 会导致检测失败
sed -i.bak 's/require libsnappy snappy-c.h snappy_compress -lsnappy -lstdc++/require libsnappy snappy-c.h snappy_compress -lsnappy/' configure
rm -f configure.bak
./configure --prefix="$P" --disable-shared --enable-static \
  --extra-cflags="-I${P}/include -I${BREW_PREFIX}/include ${MVK_CFLAGS}" \
  --extra-ldflags="-L${P}/lib -L${BREW_PREFIX}/lib ${MVK_LDFLAGS}" \
  --extra-libs="-lpthread -lm" \
  --enable-gpl --enable-version3 \
  --enable-libvmaf \
  --enable-opencl --enable-vulkan \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis --enable-libtheora --enable-libaom --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libzimg --enable-libsoxr --enable-libopenjpeg --enable-libsnappy \
  --enable-libsvtav1 --enable-libdav1d --enable-libkvazaar --enable-libopenh264 --enable-libxvid --enable-libtwolame --enable-libspeex --enable-libcodec2 --enable-libjxl --enable-libopenmpt --enable-libbs2b --enable-libaribb24 --enable-libplacebo --enable-librubberband --enable-libvidstab \
  --enable-sdl2 \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-hwaccel=h264_videotoolbox --enable-hwaccel=hevc_videotoolbox \
  --enable-hwaccel=vp9_videotoolbox --enable-hwaccel=prores_videotoolbox \
  --enable-hwaccel=av1_videotoolbox --disable-doc
make -j"$THREADS" && make install

# Dependency rewriting changes Mach-O signatures; package-runtime signs last.
strip "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay"
python3 "$REPO_ROOT/scripts/ci/package-runtime.py" --platform macos --bin-dir "$P/bin" \
  --source-dir "$BUILD_ROOT/ffmpeg-src" --output "$ORIG_DIR/output" --license-dir "$P/share"
python3 "$REPO_ROOT/scripts/ci/verify-runtime.py" --platform macos --directory "$ORIG_DIR/output" \
  --require-encoder h264_videotoolbox --require-encoder hevc_videotoolbox
