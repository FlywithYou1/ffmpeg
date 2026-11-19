#!/usr/bin/env bash
set -Eeuo pipefail

[ "${GITHUB_ACTIONS:-}" = "true" ] || { echo "This script builds AVM on GitHub Actions only."; exit 1; }
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"
ROOT="${RUNNER_TEMP}/avm"
P="${RUNNER_TEMP}/avm-install"
# Follow the av2-enc branch head; libaom remains the separate AV1 implementation.
# The resolved commit is logged and recorded in the package source manifest.
git clone --depth 1 --branch av2-enc https://github.com/AOMediaCodec/avm.git "$ROOT"
echo "AVM commit: $(git -C "$ROOT" rev-parse HEAD)" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
# Encoder, decoder, apps, libyuv, WebM and Lanczos are AVM defaults; NASM is not.
args=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
      -DENABLE_APPS=ON -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=ON -DENABLE_DOCS=OFF
      -DCONFIG_DIP_EXT_PRUNING=0 -DCONFIG_ML_PART_SPLIT=0
      -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_INSTALL_LIBDIR=lib)
if [ "${RUNNER_OS}" = "macOS" ]; then
  args+=(-DCMAKE_OSX_ARCHITECTURES=arm64 "-DCMAKE_OSX_SYSROOT=$(xcrun --sdk macosx --show-sdk-path)")
  THREADS="$(sysctl -n hw.logicalcpu)"
  arm=1
elif [ "${RUNNER_ARCH:-}" = "ARM64" ]; then
  THREADS="$(nproc)"
  arm=1
else
  args+=(-DENABLE_NASM=ON)
  THREADS="$(nproc)"
  arm=0
fi
cmake -S "$ROOT" -B "$ROOT/build" "${args[@]}"
# AVM turns SIMD flavours off quietly when a compiler probe fails; the arm
# defines appear at configure time, x86 asm objects only after the build.
if [ "$arm" = 1 ]; then
  grep -Eq '^#define HAVE_NEON 1' "$ROOT/build/config/avm_config.h" || { echo "错误：AVM 未启用 NEON"; exit 1; }
  grep -Eq '^#define AVM_ARCH_AARCH64 1' "$ROOT/build/config/avm_config.h" || { echo "错误：AVM 未以 AArch64 为目标"; exit 1; }
fi
cmake --build "$ROOT/build" --parallel "$THREADS" --target avmenc avmdec
if [ "$arm" != 1 ]; then
  # ASM_NASM objects are named <source>.asm.o by CMake.
  find "$ROOT/build" -name '*.asm.o' | grep -q . || { echo "错误：AVM 未编译 x86 汇编目标"; exit 1; }
fi
# avm.pc is only produced by the avm_pc target, and install() needs it.
cmake --build "$ROOT/build" --parallel "$THREADS" --target avm_pc
cmake --install "$ROOT/build"
mkdir -p "$P/licenses/avm"
cp "$ROOT/LICENSE" "$ROOT/PATENTS" "$P/licenses/avm/"
[ "${RUNNER_OS}" != "macOS" ] || for bin in avmenc avmdec; do codesign --force --sign - "$P/bin/$bin"; done
"$P/bin/avmenc" --help > /dev/null
"$P/bin/avmdec" --help > /dev/null
echo "AVM_PREFIX=$P" >> "$GITHUB_ENV"
