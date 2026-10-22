# 🎬 FFmpeg Multi-Vendor Build

[![Build FFmpeg Multi-Vendor](https://github.com/FlywithYou1/ffmpeg/actions/workflows/build-ffmpeg.yml/badge.svg)](https://github.com/FlywithYou1/ffmpeg/actions/workflows/build-ffmpeg.yml)

**FFmpeg 多平台构建**，支持多种 GPU 硬件加速（NVENC、QSV、AMF、VAAPI、VideoToolbox）和 VMAF 质量评分。

---

## 📦 预构建二进制

从 [Releases](https://github.com/FlywithYou1/ffmpeg/releases) 下载，每个压缩包包含 `ffmpeg` + `ffprobe` + `ffplay`（Windows 为 `.exe`），以及许可证和依赖清单。

Windows 使用 **/MT 静态运行时** 和 vcpkg 静态依赖；显卡驱动、系统组件仍须由操作系统提供。Linux 优先链接可用的静态库，未能静态链接的非系统共享库随包携带；macOS 携带非系统 dylib，并修正相对加载路径、重新签名。请保留整个解压目录（包括 `lib/`），不要只复制可执行文件。Linux 仍要求兼容的 glibc，GPU 驱动不随包分发。

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
- **CUDA 处理**: 公开发布版由 Clang/LLVM 编译 PTX（不启用非自由的 `cuda-nvcc` / `libnpp`），NVENC/NVDEC 和 VMAF-CUDA 保留；本地构建可用 `BUILD_POLICY=local` 启用 `cuda-nvcc`（产物不可再分发）
- **VMAF**: Netflix 视频质量评分（CPU 或 CUDA 加速）
- **容器格式**: MP4, MKV, MOV, AVI, TS, FLV, WebM, OGG 等

---

## 🚀 本地构建

### 前提条件

- [Visual Studio 2026](https://visualstudio.microsoft.com/) (Windows MSVC)
- [Git for Windows](https://git-scm.com/) (提供 Bash 环境)
- [vcpkg](https://github.com/microsoft/vcpkg)（Windows 使用本仓库 `vcpkg.json` 锁定依赖；包括 libjxl、x64 的 libvpl。zimg 通过共享脚本从源码编译）
- [NASM](https://www.nasm.us/) (x86/x64 汇编优化)
- [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads) (NVIDIA GPU 加速；Linux/Windows CI 使用 [mjun0812/setup-cuda](https://github.com/mjun0812/setup-cuda)，每次构建自动安装 NVIDIA 最新稳定版；网络安装失败时自动改用本地安装器，仅在 GitHub Actions runner 执行)
- [Meson](https://mesonbuild.com/) + [Ninja](https://ninja-build.org/) (VMAF 构建)
- Python 3、CMake；NVIDIA FFmpeg 需要具备 NVPTX 后端的 Clang（Windows 可使用 VS LLVM，Linux 安装 `clang`）

### Windows (VS 2026 Developer Command Prompt + Git Bash)

先在仓库根目录用锁定的清单安装静态 triplet（脚本不会自动安装或切换 vcpkg 版本）：

```powershell
$baseline = (Get-Content .\vcpkg.json -Raw | ConvertFrom-Json).'builtin-baseline'
git -C C:\vcpkg fetch origin $baseline
# 使用独立的 vcpkg clone；不要切换正在供其他项目使用的工作树
git -C C:\vcpkg checkout --detach $baseline
C:\vcpkg\bootstrap-vcpkg.bat -disableMetrics
C:\vcpkg\vcpkg.exe install --triplet x64-windows-static --x-manifest-root=.
# ARM64 改用 --triplet arm64-windows-static
```

默认检测仓库的 `vcpkg_installed/<triplet>` 或 `VCPKG_ROOT/installed/<triplet>`；也可显式设置 `VCPKG_INSTALLED`。编译器目标与 triplet 必须一致。请使用无空格的 `TMPDIR`；含空格的工具/依赖路径通过构建私有 junction 处理，不覆盖全局 `C:\cuda`。

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

# Snapdragon ARM64：另开 ARM64 Developer Command Prompt，执行
# vcvarsall.bat amd64_arm64，然后再启动 Git Bash
bash scripts/build-windows-arm64.sh
```

### Linux (Ubuntu 26.04 / ARM64)

构建前请安装依赖（示例为 Ubuntu/Debian）：

```bash
sudo apt-get update
sudo apt-get install -y build-essential yasm nasm pkg-config meson ninja-build \
  cmake git wget curl ca-certificates python3 xxd clang patchelf \
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

输出在 `output/` 目录（本地 `BUILD_POLICY=local` 的 NVIDIA 构建输出到 `output-local-only/`）。安装缓存默认使用 `~/ffmpeg-install`；可设置 `INSTALL_PREFIX`、`THREADS`。脚本只接受空目录或本仓库标记过的安装目录，不会递归删除安装目录或系统文件。旧版留下的非空目录请保留，改用新的 `INSTALL_PREFIX`。临时源码使用唯一目录，退出自动清理；同一安装目录禁止并行构建。

### macOS (Apple Silicon)

安装 Homebrew 后执行：

```bash
bash scripts/build-macos-arm.sh
```

通过 GitHub Actions CI 自动构建，详见 [workflow](.github/workflows/build-ffmpeg.yml)。基础版和 AV2 整合版复用同一次 FFmpeg 编译，保留全部既有产物名称。

### Arch Linux (NVIDIA)

先自行完成系统更新并安装构建工具、CUDA、Clang、patchelf 和相应编解码依赖。脚本不再执行 `pacman -Syu`、全局安装或删除 `/usr/local`；使用同一套用户目录构建和打包流程。只用 `bash` 执行，不要 `source`。

```bash
bash ffmpeg-archlinux-nvidia.sh
```

---

## 📁 项目结构

```text
├── .github/workflows/build-ffmpeg.yml   # CI/CD 工作流与多平台矩阵
├── scripts/
│   ├── build-windows-intel-qsv.sh       # Windows Intel QSV
│   ├── build-windows-nvidia.sh          # Windows NVIDIA NVENC/CUDA
│   ├── build-windows-amd-amf.sh         # Windows AMD AMF
│   ├── build-windows-arm64.sh           # Windows ARM64 Snapdragon
│   ├── build-linux-nvidia.sh            # Linux NVIDIA NVENC/CUDA
│   ├── build-linux-intel-qsv.sh         # Linux Intel QSV + VAAPI
│   ├── build-linux-amd.sh               # Linux AMD VAAPI
│   ├── build-linux-arm.sh               # Linux ARM64 VAAPI / CPU
│   ├── build-macos-arm.sh               # macOS Apple Silicon
│   ├── build-env.sh                     # 安装目录归属、并发锁、临时目录
│   ├── build-linux-common.sh            # Linux/Arch 公共构建
│   ├── build-windows-common.sh          # Windows 公共构建
│   ├── ci/                             # 链接、源码修补、源码收集、运行时打包和验证
│   └── tests/                          # Python unittest 回归测试
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

在 Windows MSVC 环境下，vcpkg 的原生 `pkgconf` 使用 `;` 分隔 `PKG_CONFIG_PATH`。本项目在调用 Meson 和 FFmpeg 时都使用与所选原生工具相匹配的 Windows 路径，不依赖 Unix 的 `:` 分隔方式。

### 验证

```bash
python scripts/ci/check-syntax.py
python -m unittest discover -s scripts/tests -p 'test_*.py'
```

可选：手动复核依赖源码收集（需要 `apt-get source` / `brew` / `vcpkg` 权限）

```bash
python scripts/ci/collect-dependency-sources.py --platform linux \
  --output /tmp/dependency-sources --source-dir <ffmpeg 源码目录> --install-root <安装前缀>
```

CI 在移动后的发布目录验证三个可执行文件、libvmaf、JPEG XL 编解码往返及平台声明的编码器；AV2 另做编码/解码往返。仅检查编码器注册，不要求构建机器有可用显卡。

### 许可

公开发布构建使用 `--enable-gpl --enable-version3 --enable-nonfree`。启用 `--enable-nonfree` 后 FFmpeg 会把自身标记为 **nonfree and unredistributable**（`ffmpeg -L` 输出 "This version of FFmpeg has nonfree parts compiled in"），因此这些产物**不能当作普通 GPL v3 二进制再分发**，仅限自行使用。FFmpeg 本身的 `static=yes` 也不表示全部外部依赖已经静态链接。

**本地构建与公开发布共用 nonfree 配置**：

| | 本地（`BUILD_POLICY=local`，默认） | 公开 Release（`BUILD_POLICY=release`） |
|---|---|---|
| NVIDIA CUDA | `--enable-nonfree` + `cuda-nvcc` | CUDA LLVM（Clang 编译 PTX） |
| nonfree 标记 | 有 | 有 |
| NVENC / NVDEC / VMAF-CUDA | 有 | 有 |
| 产物目录 | `output-local-only/` | `output/` |

本地脚本（`scripts/build-*.sh`）与 CI 一致，固定启用 `--enable-nonfree`；`BUILD_POLICY` 只决定 CUDA 实现方式、产物目录，以及是否用 `--local-only` 标记清单。`package-runtime.py` 与 `verify-runtime.py` 接受 nonfree 产物，把 `ffmpeg -L` 的许可证输出记录进 `metadata/ffmpeg-license-output.txt`，不再以许可证为由中止打包。`--local-only` 仍要求构建必须是 nonfree，并把清单里的 `distribution` 标为 `local-only-unredistributable`。

**对应源码**：每个公开包都包含 `scripts/ci/collect-dependency-sources.py` 收集并校验的完整依赖源码（apt 的 deb-src 源码包、Homebrew formula 源码、vcpkg port 与下载的源码包），以及修改后的 FFmpeg / VMAF / AVM 源码和本仓库构建脚本。清单记录在 `runtime-manifest.json`（`corresponding_source.status` 为 `complete`）和 `metadata/dependency-source-inventory.json`。CI 在移动后的发布目录用 `verify-runtime.py --require-complete-source` 复核；任何依赖缺失都会使构建失败，从而阻止发布不完整的包。

压缩包还应保留 FFmpeg、AVM 及随附第三方依赖的许可证、实际版本和对应源码信息。再分发者仍需满足 GPL v3 的完整对应源码及第三方许可要求。系统框架和 GPU 驱动不随包分发。参见 [FFmpeg 许可说明](https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md)。
