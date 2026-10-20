# 🎬 FFmpeg Multi-Vendor Build

[![Build FFmpeg Multi-Vendor](https://github.com/FlywithYou1/ffmpeg/actions/workflows/build-ffmpeg.yml/badge.svg)](https://github.com/FlywithYou1/ffmpeg/actions/workflows/build-ffmpeg.yml)

**FFmpeg 静态构建**，支持多种 GPU 硬件加速（NVENC、QSV、AMF、VAAPI、VideoToolbox）和 VMAF 质量评分。

---

## 📦 预构建二进制

从 [Releases](https://github.com/FlywithYou1/ffmpeg/releases) 下载，每个压缩包包含 `ffmpeg.exe` + `ffprobe.exe` + `ffplay.exe`。

Windows 构建使用 **/MT 静态运行时** 并静态链接 vcpkg 依赖，**无需额外 DLL**。AV2 整合构建通过 GitHub Actions 自动安装 CUDA 最新稳定版。

### Linux (x86_64)

| Artifact | GPU | HW Accel | VMAF |
|---|---|---|---|
| `ffmpeg-linux-nvidia.tar.xz` | NVIDIA | NVENC/CUDA | ✅ CUDA |
| `ffmpeg-linux-intel-qsv.tar.xz` | Intel | QSV (oneVPL) + VAAPI | ✅ CPU |
| `ffmpeg-linux-amd.tar.xz` | AMD | VAAPI | ✅ CPU |
| `ffmpeg-linux-x86-all.tar.xz` | NVIDIA + Intel + AMD | NVENC/CUDA + QSV + VAAPI | ✅ CUDA |

### Linux (ARM64)

| Artifact | GPU | HW Accel | VMAF |
|---|---|---|---|
| `ffmpeg-linux-arm.tar.xz` | — | VAAPI / CPU | ✅ CPU |

### Windows (x86_64, MSVC 2026)

| Artifact | GPU | HW Accel | VMAF |
|---|---|---|---|
| `ffmpeg-windows-nvidia.zip` | NVIDIA | NVENC/CUDA | ✅ CUDA |
| `ffmpeg-windows-amd-amf.zip` | AMD | AMF | ✅ CPU |
| `ffmpeg-windows-intel-qsv.zip` | Intel | QSV (oneVPL) | ✅ CPU |
| `ffmpeg-windows-x86-all.zip` | NVIDIA + Intel + AMD | NVENC/CUDA + QSV + AMF | ✅ CUDA |

### Windows (ARM64, MSVC 2026)

| Artifact | CPU | HW Accel | VMAF |
|---|---|---|---|
| `ffmpeg-windows-arm64.zip` | Snapdragon X | D3D11VA / DXVA2 / MF | ✅ CPU |

### macOS (ARM64)

| Artifact | GPU | HW Accel | VMAF |
|---|---|---|---|
| `ffmpeg-macos-arm.tar.xz` | Apple Silicon | VideoToolbox | ✅ CPU |

### 整合版 + AV2（独立 CI 构建项）

保留原有 NVIDIA、AMD、Intel 和不带 AV2 的整合版，不创建 Git 分支。

| Artifact | 平台 | 硬件加速 |
|---|---|---|
| `ffmpeg-linux-x86-all-av2.tar.xz` | Linux x86_64 | NVENC/CUDA + QSV + VAAPI |
| `ffmpeg-windows-x86-all-av2.zip` | Windows x86_64 | NVENC/CUDA + QSV + AMF |
| `ffmpeg-windows-arm64-av2.zip` | Windows ARM64 | D3D11VA / DXVA2 / MF |
| `ffmpeg-macos-arm-av2.tar.xz` | macOS ARM64 | VideoToolbox |

这些产物额外包含 [AOMediaCodec/avm `av2-enc` 分支](https://github.com/AOMediaCodec/avm/tree/av2-enc) 的 `avmenc`、`avmdec` 和许可证，CI 固定到已审阅的分支提交 `224c347d185d85c906df1e69e65bf569fd7e2c23`。该分支提供 AArch64 专用 NEON、CRC、DotProd、I8MM 和 SVE/SVE2 优化；Linux/macOS ARM64 构建显式启用基础 NEON，并让 AVM 根据编译器能力检测高级 flavor。恢复了 AVM 内置 libyuv、WebM I/O 和 Lanczos resampling。AV2 使用独立工具编解码，**不是 FFmpeg 原生 AV2 支持**；原有 libaom 的 AV1 支持保留。Windows ARM64 使用 VS `clang-cl` 和 MSVC ABI，显式指定 `aarch64-pc-windows-msvc` 目标并启用 AVM NEON。CPU 探测使用 Windows ARM64 保证支持的基础 NEON，避开上游 ARM32 `__emit` 探针，并保留 `AVM_SIMD_CAPS`/`AVM_SIMD_CAPS_MASK` 控制；CI 检查生成配置中的 `AVM_ARCH_AARCH64=1` 和 `HAVE_NEON=1`，并执行 AV2 编解码往返测试。

Windows x86_64 的 AVM 同样使用 VS `clang-cl`，保留 Release、`/MT`、NASM 和现有 SIMD 配置；FFmpeg 及其他依赖的编译器不变。

依赖 TensorFlow Lite 的 DIP/ML pruning 保持关闭，以免 XNNPACK ARM kernels 在 Windows ARM64 链接失败；其他基础 AV2 编码/解码路径保持启用。CI 会用 FFmpeg 生成测试帧，经过 AV2 编码、解码后重新读取，失败则不发布产物。AVM 的构建和验证仅在 GitHub Actions runner 执行。

```bash
ffmpeg -i input.mp4 -pix_fmt yuv420p -f yuv4mpegpipe input.y4m
avmenc --codec=av2 --ivf --cpu-used=6 --end-usage=q --cq-level=45 -o output.ivf input.y4m
avmdec --codec=av2 -o decoded.y4m output.ivf
```

---

## 🔧 功能特性

- **软件编解码器**: libx264 (H.264), libx265 (HEVC), libvpx (VP8/VP9), libopus, libvorbis, libtheora, libaom (AV1), libsvtav1 (AV1), libdav1d (AV1 解码), libkvazaar (HEVC), libopenh264, libxvid, libtwolame, libspeex, libcodec2, libjxl (JPEG XL), libopenmpt, libbs2b, libaribb24, libplacebo, librubberband, libvidstab, libwebp, libass (字幕), libfreetype, fontconfig, libzimg, libsoxr, libopenjpeg, libsnappy, SDL2 (ffplay)（Windows 通过 vcpkg 当前可用的扩展编解码器：svt-av1、dav1d、openh264、libtwolame、speex、libjxl）
- **硬件加速**: NVENC/NVDEC, Intel QSV, AMD AMF/VAAPI, VideoToolbox, D3D11VA/D3D12VA/DXVA2
- **CUDA 处理**: libnpp (NVIDIA Performance Primitives)
- **VMAF**: Netflix 视频质量评分（CPU 或 CUDA 加速）
- **容器格式**: MP4, MKV, MOV, AVI, TS, FLV, WebM, OGG 等

---

## 🚀 本地构建

### 前提条件

- [Visual Studio 2026](https://visualstudio.microsoft.com/) (Windows MSVC)
- [Git for Windows](https://git-scm.com/) (提供 Bash 环境)
- [vcpkg](https://github.com/microsoft/vcpkg) (Windows 依赖管理；x64 建议安装 `pkgconf sdl2 libiconv zlib pthreads x264 x265 libvpx opus libvorbis libtheora aom libwebp libass freetype fontconfig soxr openjpeg snappy opencl vulkan-headers svt-av1 dav1d openh264 libtwolame speex libjxl shaderc`)
- [NASM](https://www.nasm.us/) (x86/x64 汇编优化)
- [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads) (NVIDIA GPU 加速；Linux/Windows CI 使用 [mjun0812/setup-cuda](https://github.com/mjun0812/setup-cuda)，每次构建自动安装 NVIDIA 最新稳定版；网络安装失败时自动改用本地安装器，仅在 GitHub Actions runner 执行)
- [Meson](https://mesonbuild.com/) + [Ninja](https://ninja-build.org/) (VMAF 构建)

### Windows (VS 2026 Developer Command Prompt + Git Bash)

```bash
# 1. 打开 "x64 Native Tools Command Prompt for VS 2026"
# 2. 在 cmd 中启动 Git Bash：  bash
# 3. 运行构建脚本

# Intel QSV
bash scripts/build-windows-intel-qsv.sh

# NVIDIA NVENC/CUDA
bash scripts/build-windows-nvidia.sh

# AMD AMF
bash scripts/build-windows-amd-amf.sh

# Snapdragon ARM64
bash scripts/build-windows-arm64.sh
```

### Linux (Ubuntu 26.04 / ARM64)

构建前请安装依赖（示例为 Ubuntu/Debian）：

```bash
sudo apt-get update
sudo apt-get install -y build-essential yasm nasm pkg-config meson ninja-build \
  cmake git wget curl ca-certificates python3 xxd \
  libsdl2-dev \
  libva-dev libdrm-dev libvpl-dev \
  libx264-dev libx265-dev libvpx-dev libopus-dev libvorbis-dev \
  libtheora-dev libaom-dev libwebp-dev libass-dev libfreetype6-dev \
  libfontconfig1-dev libzimg-dev libsoxr-dev libopenjp2-7-dev \
  libsnappy-dev libvulkan-dev opencl-headers ocl-icd-opencl-dev glslc \
  libsvtav1enc-dev libdav1d-dev libkvazaar-dev libopenh264-dev libxvidcore-dev \
  libtwolame-dev libspeex-dev libcodec2-dev libjxl-dev libopenmpt-dev \
  libbs2b-dev libaribb24-dev libplacebo-dev librubberband-dev libvidstab-dev
```

```bash
# NVIDIA (x86_64)
bash scripts/build-linux-nvidia.sh

# Intel QSV + VAAPI (x86_64)
bash scripts/build-linux-intel-qsv.sh

# AMD VAAPI (x86_64)
bash scripts/build-linux-amd.sh

# ARM64 VAAPI / CPU
bash scripts/build-linux-arm.sh
```

输出在 `output/` 目录。

### Linux (Ubuntu 26.04)

通过 GitHub Actions CI 自动构建，详见 [workflow](.github/workflows/build-ffmpeg.yml)。

### Arch Linux (NVIDIA)

```bash
bash ffmpeg-archlinux-nvidia.sh
```

---

## 📁 项目结构

```text
├── .github/workflows/build-ffmpeg.yml   # CI/CD 工作流 (12 jobs)
├── scripts/
│   ├── build-windows-intel-qsv.sh       # Windows Intel QSV
│   ├── build-windows-nvidia.sh          # Windows NVIDIA NVENC/CUDA
│   ├── build-windows-amd-amf.sh         # Windows AMD AMF
│   ├── build-windows-arm64.sh           # Windows ARM64 Snapdragon
│   ├── build-linux-nvidia.sh            # Linux NVIDIA NVENC/CUDA
│   ├── build-linux-intel-qsv.sh         # Linux Intel QSV + VAAPI
│   ├── build-linux-amd.sh               # Linux AMD VAAPI
│   ├── build-linux-arm.sh               # Linux ARM64 VAAPI / CPU
│   └── build-macos-arm.sh               # macOS Apple Silicon
└── ffmpeg-archlinux-nvidia.sh           # Arch Linux NVIDIA NVENC/CUDA
```

---

## 🏷️ 发版

Release 由 Git tag 触发。推送 tag 后 GitHub Actions 会自动构建所有平台并创建 Release：

```bash
git tag v1.0.0
git push origin v1.0.0
```

也可以手动在 Actions 页面点击 **Run workflow** 触发。

---

## ⚠️ 技术说明

### Windows MSVC 运行时

Windows 构建统一使用 **/MT 静态运行时**，避免 FFmpeg 与 VMAF 等 C/C++ 依赖之间出现 `RuntimeLibrary mismatch`。

### Windows ARM64 汇编

ARM64 构建使用 [gas-preprocessor](https://github.com/FFmpeg/gas-preprocessor) 将 FFmpeg 的 GNU 汇编语法转换为 MSVC `armasm64.exe` 可识别的语法，从而保留 NEON 优化。

### Windows pkg-config 路径分隔符

在 Windows MSVC 环境下，vcpkg 提供的 `pkgconf` 是原生 Windows 二进制，期望 `;` 作为 `PKG_CONFIG_PATH` 分隔符（而非 Unix 的 `:`）。同时，Meson (Python) 构建 VMAF 时仍期望 `:` 分隔符。

因此本项目的构建脚本采取双轨策略：
- **Meson 构建步骤**：`PKG_CONFIG_PATH` 使用 `:` 分隔
- **FFmpeg configure / pkgconf**：`PKG_CONFIG_PATH` 使用 `;` 分隔

### 许可

FFmpeg 依据 LGPL/GPL 许可。启用 `--enable-gpl --enable-version3 --enable-nonfree` 后，生成的二进制受 GPL v3 约束。
