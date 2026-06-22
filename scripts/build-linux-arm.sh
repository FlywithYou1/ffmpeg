#!/usr/bin/env bash
# ============================================================
# FFmpeg + VAAPI + VMAF (Ubuntu ARM64 / AArch64)
# ============================================================
set -Eeuo pipefail
trap 'echo "错误：第 ${LINENO} 行"; exit 1' ERR

ORIG_DIR="$(pwd)"
THREADS="${THREADS:-$(nproc)}"
P="${INSTALL_PREFIX:-${HOME}/ffmpeg-install}"
ARCH_LIBDIR=/usr/lib/aarch64-linux-gnu

echo "=========================================="
echo "FFmpeg ARM64 VAAPI (Ubuntu)"
echo "PREFIX: $P  THREADS: $THREADS"
echo "=========================================="

export PATH="${P}/bin:${PATH}"
export PKG_CONFIG_PATH="${P}/lib/pkgconfig:${ARCH_LIBDIR}/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${P}/lib:${LD_LIBRARY_PATH:-}"

# 优先使用 GCC 16 作为默认编译器
export CC="${CC:-gcc-16}"
export CXX="${CXX:-g++-16}"

# ---- 清理 ----
rm -rf "$P" /tmp/vmaf /tmp/ffmpeg-src 2>/dev/null || true
mkdir -p "$P"/{bin,lib,include,lib/pkgconfig}

# ---- 兜底 pkg-config ----
printf 'prefix=/usr\nexec_prefix=${prefix}\nlibdir=%s\nincludedir=%s\nName: libopenjp2\nDescription: OpenJPEG JPEG 2000 library\nVersion: 2.5.0\nLibs: -L${libdir} -lopenjp2\nCflags: -I${includedir}\n' \
  "$ARCH_LIBDIR" "$(ls -d /usr/include/openjpeg-* 2>/dev/null | head -1 || echo /usr/include)" \
  > "$P/lib/pkgconfig/libopenjp2.pc"
printf 'prefix=/usr\nexec_prefix=${prefix}\nlibdir=%s\nincludedir=/usr/include\nName: x265\nDescription: H.265/HEVC encoder\nVersion: 1.0.0\nLibs: -L${libdir} -lx265\nLibs.private: -lstdc++ -lm -lgcc -lpthread\nCflags: -I${includedir}\n' \
  "$ARCH_LIBDIR" > "$P/lib/pkgconfig/x265.pc"

# ---- VMAF (CPU) ----
echo "[1/4] VMAF"
cd /tmp && rm -rf vmaf
git clone --depth 1 https://github.com/Netflix/vmaf.git
cd vmaf/libvmaf && rm -rf build
PKG_CONFIG_PATH="${P}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
meson setup build --buildtype release --prefix="$P" --libdir=lib -Denable_cuda=false
ninja -vC build && ninja -C build install

# ---- FFmpeg ----
echo "[2/4] FFmpeg"
cd /tmp && rm -rf ffmpeg-src
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
cd ffmpeg-src

# 验证 libplacebo 静态链接
echo "=== manual libplacebo static link test ==="
printf '%s\n' '#include <libplacebo/vulkan.h>' 'int main(void) { pl_gpu_create(NULL, NULL); return 0; }' > /tmp/pl_test.c
"$CC" /tmp/pl_test.c $(pkg-config --static --cflags --libs libplacebo) -o /tmp/pl_test 2>&1 && echo "manual link OK" || echo "manual link FAIL"

./configure --prefix="$P" --pkg-config-flags="--static" \
  --extra-cflags="-I${P}/include" \
  --extra-ldflags="-L${P}/lib -Wl,-rpath,${P}/lib" \
  --extra-libs="-lpthread -lm -ldl" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-libvmaf --enable-vaapi --enable-opencl --enable-vulkan \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis --enable-libtheora --enable-libaom --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libzimg --enable-libsoxr --enable-libopenjpeg --enable-libsnappy --enable-libsvtav1 --enable-libdav1d --enable-libkvazaar --enable-libopenh264 --enable-libxvid --enable-libtwolame --enable-libspeex --enable-libcodec2 --enable-libjxl --enable-libopenmpt --enable-libbs2b --enable-libaribb24 --enable-libplacebo --enable-librubberband --enable-libvidstab --enable-libmp3lame --enable-libfdk-aac --enable-sdl2 --disable-doc
make -j"$THREADS" && make install

# ---- 验证 + 输出 ----
echo "[3/4] 验证"
strip "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" 2>/dev/null || true
"$P/bin/ffmpeg" -version 2>&1 | head -n3
echo "--- VAAPI ---"
"$P/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep '_vaapi' | head -10 || echo "(none)"
echo "--- VMAF ---"
"$P/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -i vmaf || echo "(none)"

echo "[4/4] 输出"
mkdir -p "$ORIG_DIR/output"
cp "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay" "$ORIG_DIR/output/"
ls -lh "$ORIG_DIR/output/"
cd "$ORIG_DIR"
