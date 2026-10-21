#!/usr/bin/env bash
build_linux() {
  set -Eeuo pipefail
  trap 'echo "错误：第 ${LINENO} 行" >&2; exit 1' ERR
  source "$(dirname "${BASH_SOURCE[0]}")/build-env.sh"
  init_build_env "$0"
  local vendor="$1" configure_extra=() verify_extra=() extra_cflags="" extra_ldflags=""
  local policy="${BUILD_POLICY:-local}" license_flags=(--disable-nonfree) package_flags=()
  local output_dir=output
  case "$policy" in
    local|release) ;;
    *) echo "BUILD_POLICY 必须为 local 或 release" >&2; return 1 ;;
  esac
  THREADS="${THREADS:-$(nproc)}"
  [[ "$THREADS" =~ ^[1-9][0-9]*$ ]] || { echo "THREADS 必须为正整数" >&2; return 1; }
  export PATH="$P/bin:$PATH"
  export PKG_CONFIG_PATH="$P/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$P/lib:${LD_LIBRARY_PATH:-}"
  case "$P $REPO_ROOT $BUILD_ROOT" in
    *' '*) echo "Linux 编译目录不能包含空格" >&2; return 1 ;;
  esac
  for tool in cc c++ git make meson ninja pkg-config python3 patchelf; do
    command -v "$tool" >/dev/null || { echo "缺少工具: $tool" >&2; return 1; }
  done
  export FFMPEG_PKG_CONFIG="$(command -v pkg-config)"
  case "$vendor" in
    arm)
      [ "$(uname -m)" = aarch64 ] || { echo "ARM64 构建必须在 AArch64 主机运行" >&2; return 1; }
      ;;
  esac
  case "$vendor" in
    nvidia)
      CUDA_HOME="${CUDA_HOME:-${CUDA_PATH:-}}"
      if [ -z "$CUDA_HOME" ]; then
        for d in /usr/local/cuda /opt/cuda /usr/local/cuda-*; do
          [ -x "$d/bin/nvcc" ] && { CUDA_HOME="$d"; break; }
        done
      fi
      [ -x "${CUDA_HOME}/bin/nvcc" ] || { echo "未找到 CUDA Toolkit" >&2; return 1; }
      if [ "$policy" = local ]; then
        license_flags=(--enable-nonfree)
        package_flags=(--local-only)
        output_dir=output-local-only
        configure_extra+=(--enable-ffnvcodec --enable-cuda-nvcc --disable-cuda-llvm \
          "--nvcc=$CUDA_HOME/bin/nvcc" "--nvccflags=${NVCCFLAGS:--gencode arch=compute_75,code=sm_75 -O2}" --enable-cuvid --enable-nvenc)
      else
        CUDA_CLANG="${CUDA_CLANG:-$(command -v clang || true)}"
        [ -n "$CUDA_CLANG" ] || { echo "可发布 CUDA 构建需要支持 NVPTX 的 Clang" >&2; return 1; }
        "$CUDA_CLANG" --print-targets | grep nvptx >/dev/null
        printf '%s\n' '__attribute__((global)) void ffmpeg_cuda_probe(void) {}' > "$BUILD_ROOT/cuda-probe.cu"
        "$CUDA_CLANG" -S -x cuda --cuda-device-only -nocudainc -nocudalib --cuda-gpu-arch=sm_75 \
          "$BUILD_ROOT/cuda-probe.cu" -o "$BUILD_ROOT/cuda-probe.ptx"
        grep '\.entry' "$BUILD_ROOT/cuda-probe.ptx" >/dev/null
        configure_extra+=(--enable-ffnvcodec --disable-cuda-nvcc --enable-cuda-llvm "--nvcc=$CUDA_CLANG" \
          "--nvccflags=-S -nocudainc -nocudalib --cuda-gpu-arch=sm_75 -O2" --enable-cuvid --enable-nvenc)
      fi
      verify_extra+=(--require-encoder h264_nvenc --require-encoder hevc_nvenc --require-encoder av1_nvenc)
      export CUDA_PATH="$CUDA_HOME" CUDACXX="$CUDA_HOME/bin/nvcc"
      export PATH="$CUDA_HOME/bin:$PATH"
      export C_INCLUDE_PATH="$P/include:$CUDA_HOME/include:${C_INCLUDE_PATH:-}"
      extra_cflags="-I$CUDA_HOME/include"
      extra_ldflags="-L$CUDA_HOME/lib64"
      git clone --depth 1 https://github.com/FFmpeg/nv-codec-headers.git "$BUILD_ROOT/nv-codec-headers"
      make -C "$BUILD_ROOT/nv-codec-headers" PREFIX="$P" install
      ;;
    intel-qsv)
      configure_extra+=(--enable-libvpl --enable-vaapi --disable-ffnvcodec --disable-cuda-nvcc --disable-cuda-llvm --disable-cuvid --disable-nvenc)
      verify_extra+=(--require-encoder h264_qsv --require-encoder hevc_qsv)
      ;;
    amd|arm)
      configure_extra+=(--enable-vaapi --disable-ffnvcodec --disable-cuda-nvcc --disable-cuda-llvm --disable-cuvid --disable-nvenc)
      verify_extra+=(--require-encoder h264_vaapi)
      ;;
    *) echo "Unknown Linux vendor: $vendor" >&2; return 1 ;;
  esac
  if [ "${FFMPEG_ARCH_BUILD:-0}" != 1 ]; then
    bash "$REPO_ROOT/scripts/ci/prepare-linux-link.sh" "$P" "$BUILD_ROOT/linux-link"
    export PKG_CONFIG_PATH="$P/lib/pkgconfig:/usr/lib/$("${CC:-cc}" -print-multiarch)/pkgconfig:${PKG_CONFIG_PATH:-}"
  else
    mkdir -p "$BUILD_ROOT/linux-link/static-libs"
    for archive in /usr/lib/*.a; do
      [ -f "$archive" ] || continue
      name="$(basename "$archive")"
      case "$name" in libc.a|libm.a|libm-*.a|libdl.a|libpthread.a|librt.a|libcuda.a|libnvidia-*.a) continue ;; esac
      ln -sf "$archive" "$BUILD_ROOT/linux-link/static-libs/$name"
    done
  fi
  if [ "${FFMPEG_ARCH_BUILD:-0}" = 1 ]; then
    configure_extra+=(--enable-libwavpack)
  fi
  git clone --depth 1 https://github.com/Netflix/vmaf.git "$BUILD_ROOT/vmaf"
  cd "$BUILD_ROOT/vmaf/libvmaf"
  meson setup build --buildtype release --prefix="$P" --libdir=lib -Ddefault_library=static \
    -Denable_cuda="$([ "$vendor" = nvidia ] && echo true || echo false)" \
    -Denable_tests=false -Denable_tools=false -Denable_docs=false \
    -Dc_link_args=-lstdc++ -Dcpp_link_args=-lstdc++
  ninja -C build && ninja -C build install
  mkdir -p "$P/share/libvmaf"
  cp "$BUILD_ROOT/vmaf/LICENSE" "$P/share/libvmaf/copyright"
  if [ -d "$BUILD_ROOT/nv-codec-headers" ]; then
    mkdir -p "$P/share/nv-codec-headers"
    cp "$BUILD_ROOT/nv-codec-headers/include/ffnvcodec/nvEncodeAPI.h" "$P/share/nv-codec-headers/copyright"
  fi
  git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git "$BUILD_ROOT/ffmpeg-src"
  cd "$BUILD_ROOT/ffmpeg-src"
  printf '#!/usr/bin/env bash\nexec python3 "%s/scripts/ci/prefer-static-pkg-config.py" "$@"\n' "$REPO_ROOT" > "$BUILD_ROOT/pkg-config-static"
  chmod +x "$BUILD_ROOT/pkg-config-static"
  ./configure --prefix="$P" --disable-shared --enable-static --cc="${CC:-cc}" --cxx="${CXX:-c++}" \
    --pkg-config="$BUILD_ROOT/pkg-config-static" --pkg-config-flags=--static \
    --extra-cflags="-I$P/include $extra_cflags" \
    --extra-ldflags="-L$P/lib -L$BUILD_ROOT/linux-link/static-libs $extra_ldflags" --extra-libs="-lpthread -lm -ldl -lstdc++" \
    --enable-gpl --enable-version3 "${license_flags[@]}" --enable-libvmaf "${configure_extra[@]}" \
    --enable-opencl --enable-vulkan \
    --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis --enable-libtheora \
    --enable-libaom --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libzimg \
    --enable-libsoxr --enable-libopenjpeg --enable-libsnappy --enable-libsvtav1 --enable-libdav1d \
    --enable-libkvazaar --enable-libopenh264 --enable-libxvid --enable-libtwolame --enable-libspeex \
    --enable-libcodec2 --enable-libjxl --enable-libopenmpt --enable-libbs2b --enable-libaribb24 \
    --enable-libplacebo --enable-librubberband --enable-libvidstab --enable-sdl2 --disable-doc
  make -j"$THREADS" && make install
  strip "$P/bin/ffmpeg" "$P/bin/ffprobe" "$P/bin/ffplay"
  local source_args=()
  if [ -d "$BUILD_ROOT/nv-codec-headers" ]; then
    source_args+=(--dependency-source "$BUILD_ROOT/nv-codec-headers")
  fi
  python3 "$REPO_ROOT/scripts/ci/package-runtime.py" --platform linux --bin-dir "$P/bin" \
    --source-dir "$BUILD_ROOT/ffmpeg-src" --output "$ORIG_DIR/$output_dir" --license-dir "$P/share" "${source_args[@]}" "${package_flags[@]}"
  python3 "$REPO_ROOT/scripts/ci/verify-runtime.py" --platform linux --directory "$ORIG_DIR/$output_dir" "${verify_extra[@]}" "${package_flags[@]}"
}
