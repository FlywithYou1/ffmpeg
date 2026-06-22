#!/usr/bin/env bash

# 判断脚本是否被 source 执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # 直接作为子进程执行
  set -Eeuo pipefail
  trap 'echo "错误：第 ${LINENO} 行执行失败。"; exit 1' ERR
else
  # 被 source 或 . 执行：禁用 -e，避免退出当前交互式 shell
  set -uo pipefail
  trap 'echo "错误：第 ${LINENO} 行执行失败。"; set +e; trap - ERR; return 1' ERR
  # 捕获 Ctrl+C (SIGINT)，防止 source 时直接关闭终端
  trap 'echo "已取消操作。"; trap - INT; return 130' INT
fi

# 保存原始目录，脚本结束时返回
ORIG_DIR="$(pwd)"

THREADS="${THREADS:-$(nproc)}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"

# Arch Linux 的 CUDA 通常安装在 /opt/cuda
if [ -d /opt/cuda ] && [ ! -d /usr/local/cuda ]; then
  echo "[INFO] 检测到 Arch Linux 默认 CUDA 路径 /opt/cuda，自动设置 CUDA_HOME=/opt/cuda"
  CUDA_HOME="/opt/cuda"
fi

echo "=========================================="
echo "FFmpeg + NVIDIA + VMAF-CUDA 安装脚本 (Arch Linux)"
echo "安装目标: /usr/local"
echo "编译线程: ${THREADS}"
echo "CUDA路径: ${CUDA_HOME}"
echo "策略: 强制使用系统 gcc"
echo "=========================================="

echo "[0/12] 检查 sudo 权限..."
if ! command -v sudo >/dev/null 2>&1; then
  echo "错误：未找到 sudo。Arch Linux 请安装 sudo 并配置用户权限。"
  exit 1
fi
sudo -v

echo "[1/12] 更新系统并安装基础依赖..."
sudo pacman -Syu --noconfirm
sudo pacman -S --needed --noconfirm \
  base-devel \
  yasm \
  nasm \
  pkgconf \
  meson \
  ninja \
  cmake \
  git \
  wget \
  python \
  python-pip \
  xxd \
  ca-certificates-utils \
  gnupg \
  lsb-release \
  lame \
  libfdk-aac \
  x264 \
  x265 \
  libvpx \
  opus \
  libvorbis \
  libtheora \
  aom \
  libwebp \
  libass \
  freetype2 \
  fontconfig \
  zimg \
  libsoxr \
  openjpeg2 \
  snappy \
  sdl2 \
  opencl-headers \
  ocl-icd \
  vulkan-headers \
  vulkan-icd-loader \
  shaderc \
  svt-av1 \
  dav1d \
  kvazaar \
  openh264 \
  xvidcore \
  twolame \
  speex \
  codec2 \
  libjxl \
  libopenmpt \
  wavpack \
  libbs2b \
  aribb24 \
  libplacebo \
  rubberband \
  vidstab

echo "[2/12] 确保 GCC 可用..."
# Arch 滚动发行版：gcc 包始终为最新版
sudo pacman -S --needed --noconfirm gcc

CC_BIN="$(command -v gcc || true)"
CXX_BIN="$(command -v g++ || true)"
if [ -z "${CC_BIN}" ] || [ -z "${CXX_BIN}" ]; then
  echo "错误：未找到 gcc / g++。"
  exit 1
fi

AR_BIN="$(command -v gcc-ar || command -v ar)"
NM_BIN="$(command -v gcc-nm || command -v nm)"
RANLIB_BIN="$(command -v gcc-ranlib || command -v ranlib)"

echo "gcc: ${CC_BIN}"
echo "g++: ${CXX_BIN}"
"${CC_BIN}" --version | head -n1
"${CXX_BIN}" --version | head -n1

if [ ! -x "${CUDA_HOME}/bin/nvcc" ]; then
  echo "错误：未找到 nvcc: ${CUDA_HOME}/bin/nvcc"
  echo "Arch Linux 请安装 CUDA: sudo pacman -S cuda"
  echo "或设置正确的 CUDA_HOME（例如 /opt/cuda）"
  exit 1
fi

echo "[3/12] 清理旧产物..."
rm -rf "${HOME}/ffmpeg" "${HOME}/vmaf" "${HOME}/nv-codec-headers"

sudo rm -f /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffplay 2>/dev/null || true
sudo rm -f /usr/local/lib/libav* /usr/local/lib/libsw* /usr/local/lib/libpostproc* /usr/local/lib/libvmaf* 2>/dev/null || true
sudo rm -f /usr/local/lib/pkgconfig/libav*.pc /usr/local/lib/pkgconfig/libsw*.pc /usr/local/lib/pkgconfig/libpostproc.pc /usr/local/lib/pkgconfig/libvmaf.pc 2>/dev/null || true
sudo rm -rf /usr/local/include/libvmaf /usr/local/share/vmaf /usr/local/share/doc/ffmpeg 2>/dev/null || true
sudo ldconfig

echo "[4/12] 编译并安装 nv-codec-headers..."
cd "${HOME}"
git clone --depth 1 https://git.ffmpeg.org/nv-codec-headers.git
cd "${HOME}/nv-codec-headers"
make -j"${THREADS}" PREFIX=/usr/local
sudo make PREFIX=/usr/local install

echo "[5/12] 编译并安装 VMAF（强制 gcc）..."
cd "${HOME}"
if ! git clone --depth 1 https://gh-proxy.org/https://github.com/Netflix/vmaf.git; then
  git clone --depth 1 https://github.com/Netflix/vmaf.git
fi

cd "${HOME}/vmaf/libvmaf"
rm -rf build

export CUDA_PATH="${CUDA_HOME}"
export CUDACXX="${CUDA_HOME}/bin/nvcc"
export PATH="${CUDA_HOME}/bin:${PATH}"

CC="${CC_BIN}" \
CXX="${CXX_BIN}" \
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
CFLAGS="-I/usr/local/include -I${CUDA_HOME}/include" \
CXXFLAGS="-I/usr/local/include -I${CUDA_HOME}/include" \
LDFLAGS="-L/usr/local/lib -L${CUDA_HOME}/lib64 -lstdc++" \
meson setup build \
  --buildtype release \
  --prefix=/usr/local \
  -Denable_cuda=true \
  -Dc_link_args="-lstdc++" \
  -Dcpp_link_args="-lstdc++"

ninja -vC build
sudo ninja -C build install
sudo ldconfig

if ! grep -Ei "C compiler for the host machine: .*gcc|C\+\+ compiler for the host machine: .*g\+\+" build/meson-logs/meson-log.txt >/dev/null 2>&1; then
  echo "错误：libvmaf 不是 gcc/g++ 编译。"
  exit 1
fi

echo "[6/12] 编译并安装 FFmpeg（强制 gcc）..."
cd "${HOME}"
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git
cd "${HOME}/ffmpeg"

unset CC CXX
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

CC="${CC_BIN}" \
CXX="${CXX_BIN}" \
AR="${AR_BIN}" \
NM="${NM_BIN}" \
RANLIB="${RANLIB_BIN}" \
./configure \
  --prefix=/usr/local \
  --docdir=/usr/local/share/doc/ffmpeg \
  --cc="${CC_BIN}" \
  --cxx="${CXX_BIN}" \
  --extra-cflags="-I/usr/local/include -I${CUDA_HOME}/include" \
  --extra-ldflags="-L/usr/local/lib -L${CUDA_HOME}/lib64" \
  --extra-libs="-lpthread -lm -ldl -lstdc++" \
  --enable-gpl \
  --enable-version3 \
  --enable-nonfree \
  --enable-libvmaf \
  --enable-ffnvcodec \
  --enable-cuda-nvcc \
  --enable-cuvid \
  --enable-nvenc \
  --enable-libnpp \
  --enable-opencl --enable-vulkan \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis --enable-libtheora --enable-libaom --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libzimg --enable-libsoxr --enable-libopenjpeg --enable-libsnappy \
  --enable-libsvtav1 --enable-libdav1d --enable-libkvazaar --enable-libopenh264 --enable-libxvid --enable-libtwolame --enable-libspeex --enable-libcodec2 --enable-libjxl --enable-libopenmpt --enable-libwavpack --enable-libbs2b --enable-libaribb24 --enable-libplacebo --enable-librubberband --enable-libvidstab \
  --enable-libmp3lame \
  --enable-libfdk-aac \
  --enable-sdl2

echo "[7/12] 校验 configure 输出..."
CFG_MAK=""
if [ -f "config.mak" ]; then
  CFG_MAK="config.mak"
elif [ -f "ffbuild/config.mak" ]; then
  CFG_MAK="ffbuild/config.mak"
else
  echo "错误：configure 未生成 config.mak。"
  exit 1
fi

echo "使用配置文件: ${CFG_MAK}"
grep -E '^(CC|CXX)=' "${CFG_MAK}" || true
if ! grep -E "^CC=.*gcc" "${CFG_MAK}" >/dev/null 2>&1; then
  echo "错误：FFmpeg configure 未使用 gcc。"
  exit 1
fi

echo "[8/12] 编译安装 FFmpeg..."
make -j"${THREADS}"
sudo make install
sudo ldconfig
hash -r

echo "[9/12] 验证最终二进制..."
if [ ! -x /usr/local/bin/ffmpeg ]; then
  echo "错误：/usr/local/bin/ffmpeg 不存在。"
  exit 1
fi

/usr/local/bin/ffmpeg -version | head -n3
if ! /usr/local/bin/ffmpeg -version | head -n2 | grep -Ei 'built with .*gcc' >/dev/null 2>&1; then
  echo "警告：未在前两行明确匹配到 gcc，请手动检查完整 version 输出。"
fi

echo "[10/12] 编码器能力检查..."
/usr/local/bin/ffmpeg -hide_banner -encoders | grep -E 'av1_nvenc|hevc_nvenc|h264_nvenc' || true

echo "[11/12] 音频编码器检查..."
/usr/local/bin/ffmpeg -hide_banner -encoders | grep -E 'libmp3lame|libfdk_aac' || true

echo "[12/12] 完成"
echo "=========================================="
echo "完成：安装到 /usr/local，VMAF + FFmpeg 均为 gcc 编译"
echo "新增: MP3 (libmp3lame) + AAC (libfdk-aac) 编码支持"
echo "=========================================="

# 返回脚本执行前的目录
cd "${ORIG_DIR}"