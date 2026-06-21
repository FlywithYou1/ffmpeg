# 🎬 FFmpeg Multi-Vendor Build

[![Build FFmpeg Multi-Vendor](https://github.com/FlywithYou1/ffmpeg/actions/workflows/build-ffmpeg.yml/badge.svg)](https://github.com/FlywithYou1/ffmpeg/actions/workflows/build-ffmpeg.yml)

**FFmpeg 静态构建**，支持多种 GPU 硬件加速（NVENC、QSV、AMF、VAAPI、VideoToolbox）和 VMAF 质量评分。

---

## 📦 预构建二进制

从 [Releases](https://github.com/FlywithYou1/ffmpeg/releases) 下载，每个压缩包包含 `ffmpeg.exe` + `ffprobe.exe` + `ffplay.exe`。

Windows 构建使用 **/MT 静态运行时** 并静态链接 vcpkg 依赖，**无需额外 DLL**。

### Linux (x86_64)

| Artifact | GPU | HW Accel | VMAF |
|---|---|---|---|
| `ffmpeg-linux-nvidia.tar.xz` | NVIDIA | NVENC/CUDA | ✅ CUDA |
| `ffmpeg-linux-intel-qsv.tar.xz` | Intel | QSV (oneVPL) + VAAPI | ✅ CPU |
| `ffmpeg-linux-amd.tar.xz` | AMD | VAAPI | ✅ CPU |
| `ffmpeg-linux-x86-all.tar.xz` | NVIDIA + Intel + AMD | NVENC/CUDA + QSV + VAAPI | ✅ CUDA |

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

---

## 🔧 功能特性

- **软件编解码器**: libmp3lame (MP3), libfdk-aac (AAC), libx264 (H.264), libx265 (HEVC), libvpx (VP8/VP9), libopus, libvorbis, libtheora, libaom (AV1), libwebp, libass (字幕), libfreetype, fontconfig, libzimg, libsoxr, libopenjpeg, libsnappy, SDL2 (ffplay)
- **硬件加速**: NVENC/NVDEC, Intel QSV, AMD AMF/VAAPI, VideoToolbox, D3D11VA/DXVA2
- **CUDA 处理**: libnpp (NVIDIA Performance Primitives)
- **VMAF**: Netflix 视频质量评分（CPU 或 CUDA 加速）
- **容器格式**: MP4, MKV, MOV, AVI, TS, FLV, WebM, OGG 等

---

## 🚀 本地构建

### 前提条件

- [Visual Studio 2026](https://visualstudio.microsoft.com/) (Windows MSVC)
- [Git for Windows](https://git-scm.com/) (提供 Bash 环境)
- [vcpkg](https://github.com/microsoft/vcpkg) (Windows 依赖管理)
- [NASM](https://www.nasm.us/) (x86/x64 汇编优化)
- [CUDA Toolkit 13.3](https://developer.nvidia.com/cuda-downloads) (NVIDIA GPU 加速)
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

输出在 `output/` 目录。

### Linux (Ubuntu 26.04)

通过 GitHub Actions CI 自动构建，详见 [workflow](.github/workflows/build-ffmpeg.yml)。

### Arch Linux (NVIDIA)

```bash
bash ffmpeg-archlinux-nvidia.sh
```

---

## 📁 项目结构

```
├── .github/workflows/build-ffmpeg.yml   # CI/CD 工作流 (11 jobs)
├── scripts/
│   ├── build-windows-intel-qsv.sh       # Windows Intel QSV
│   ├── build-windows-nvidia.sh          # Windows NVIDIA NVENC/CUDA
│   ├── build-windows-amd-amf.sh         # Windows AMD AMF
│   ├── build-windows-arm64.sh           # Windows ARM64 Snapdragon
│   ├── build-linux-nvidia.sh            # Linux NVIDIA NVENC/CUDA
│   ├── build-linux-intel-qsv.sh         # Linux Intel QSV + VAAPI
│   ├── build-linux-amd.sh               # Linux AMD VAAPI
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
