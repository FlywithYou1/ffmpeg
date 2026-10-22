#!/usr/bin/env bash
# Shared Windows /MT engine; wrappers own build-env initialization and cleanup.
windows_die() { echo "错误：$*" >&2; exit 1; }
windows_require() { command -v "$1" >/dev/null 2>&1 || windows_die "缺少工具 $1（不会自动安装）"; }
windows_mixed() { cygpath -m "$1"; }
windows_pwsh() { pwsh -NoProfile -NonInteractive -File "$(cygpath -w "$1")" "${@:2}"; }
windows_meson_array() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }

# Junctions are unique children of the owned BUILD_ROOT, never global aliases.
# Cleanup removes each reparse point without traversing its target, then delegates.
windows_cleanup() {
  local status=$? link detach_failed=0
  trap - EXIT ERR
  set +e
  for link in "${WINDOWS_JUNCTIONS[@]}"; do
    if [ -d "$link" ]; then
      if ! MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c "rmdir \"$(cygpath -w "$link")\"" >/dev/null; then
        # Never let recursive cleanup traverse a junction that failed to detach.
        rm -f -- "$BUILD_ROOT/.ffmpeg-build-temp"
        detach_failed=1
      fi
    fi
  done
  cleanup_build_env
  if [ "$status" -eq 0 ] && [ "$detach_failed" -ne 0 ]; then status=1; fi
  exit "$status"
}
windows_space_free() {
  local path="$1" link="$BUILD_ROOT/$2"
  case "$(windows_mixed "$path")" in
    *' '*)
      case "$(windows_mixed "$BUILD_ROOT")" in *' '*) windows_die "BUILD_ROOT 含空格；请设置无空格 TMPDIR" ;; esac
      [ ! -e "$link" ] || windows_die "拒绝覆盖 junction: $link"
      MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c "mklink /J \"$(cygpath -w "$link")\" \"$(cygpath -w "$path")\"" >/dev/null
      WINDOWS_JUNCTIONS+=("$link")
      WINDOWS_PATH_RESULT="$link"
      ;;
    *) WINDOWS_PATH_RESULT="$path" ;;
  esac
}

windows_init_tools() {
  local entry clean='' target tool
  for tool in cygpath python3 pwsh cl.exe lib.exe link.exe git make meson ninja; do windows_require "$tool"; done
  case "$(windows_mixed "$BUILD_ROOT")" in *' '*) windows_die "BUILD_ROOT 含空格；请设置无空格 TMPDIR（源码编译参数需要）" ;; esac
  IFS=':' read -ra entries <<< "$PATH"
  for entry in "${entries[@]}"; do
    case "$entry" in *[Ss]trawberry*) continue ;; esac
    if [ "$WINDOWS_ARCH" = arm64 ]; then
      case "$entry" in *[Nn][Aa][Ss][Mm]*|*[Yy][Aa][Ss][Mm]*) continue ;; esac
    fi
    clean="${clean:+$clean:}$entry"
  done
  export PATH="$clean"
  hash -r
  [ "${VSCMD_ARG_TGT_ARCH:-}" = "$WINDOWS_ARCH" ] || windows_die "请初始化 MSVC $WINDOWS_ARCH 目标环境（x64: vcvars64.bat；ARM64: vcvarsall.bat amd64_arm64）"
  # Do not inherit runtime-changing compiler environment flags.
  unset CL _CL_
  # Verify the actual compiler target, not just cl.exe presence or host uname.
  target=_M_X64
  [ "$WINDOWS_ARCH" != arm64 ] || target=_M_ARM64
  printf '#ifndef %s\n#error Incorrect MSVC target\n#endif\nint windows_target_probe;\n' "$target" > "$BUILD_ROOT/target-probe.c"
  cl.exe -nologo -MT -c "-Fo$(windows_mixed "$BUILD_ROOT/target-probe.obj")" "$(windows_mixed "$BUILD_ROOT/target-probe.c")"
  export PATH="$(dirname "$(command -v cl.exe)"):$P/bin:$PATH"
  WINDOWS_JUNCTIONS=()
  trap windows_cleanup EXIT
  windows_space_free "$P" prefix
  P_MIXED="$(windows_mixed "$WINDOWS_PATH_RESULT")"
  [ "$WINDOWS_ARCH" = arm64 ] || {
    for entry in '/c/Program Files/NASM' '/c/Program Files (x86)/NASM' '/c/ProgramData/chocolatey/bin'; do
      if [ -f "$entry/nasm.exe" ]; then export PATH="$entry:$PATH"; break; fi
    done
    windows_require nasm
  }
}

windows_dependencies() {
  local candidate root flags=()
  VCPKG_INSTALLED="${VCPKG_INSTALLED:-}"
  if [ -z "$VCPKG_INSTALLED" ]; then
    for root in "$REPO_ROOT/vcpkg_installed" "${VCPKG_ROOT:-/c/vcpkg}/installed"; do
      candidate="$root/$WINDOWS_ARCH-windows-static"
      if [ -d "$candidate" ]; then VCPKG_INSTALLED="$candidate"; break; fi
    done
  fi
  [ -n "$VCPKG_INSTALLED" ] || windows_die "请预先安装 $WINDOWS_ARCH-windows-static 依赖，并设置 VCPKG_INSTALLED"
  VCPKG_INSTALLED="$(cygpath -u "$VCPKG_INSTALLED")"
  [ -d "$VCPKG_INSTALLED/include" ] && [ -d "$VCPKG_INSTALLED/lib" ] || windows_die "无效依赖目录 $VCPKG_INSTALLED"
  case "$(basename "$VCPKG_INSTALLED")" in
    "$WINDOWS_ARCH-windows-static") ;;
    *) windows_die "依赖必须使用匹配的 $WINDOWS_ARCH-windows-static (/MT) triplet" ;;
  esac
  [ "$WINDOWS_FLAVOR" != intel-qsv ] || flags+=(-HasVpl)
  windows_pwsh "$REPO_ROOT/scripts/ci/write-fallback-pc.ps1" -InstallRoot "$(cygpath -w "$VCPKG_INSTALLED")" "${flags[@]}"
  windows_space_free "$VCPKG_INSTALLED" dependencies
  VCPKG_MIXED="$(windows_mixed "$WINDOWS_PATH_RESULT")"
  local pc="${PKG_CONFIG:-}" host_arch=x64 tool_roots=()
  [ "${PROCESSOR_ARCHITECTURE:-}" != ARM64 ] || host_arch=arm64
  tool_roots=("$(dirname "$VCPKG_INSTALLED")/$host_arch-windows" "$(dirname "$VCPKG_INSTALLED")/$host_arch-windows-static" "$VCPKG_INSTALLED")
  if [ -z "$pc" ]; then
    for root in "${tool_roots[@]}"; do
      for candidate in "$root/tools/pkgconf/pkgconf.exe" "$root/tools/pkgconf/pkg-config.exe" "$root/bin/pkgconf.exe"; do
        if [ -f "$candidate" ]; then pc="$candidate"; break 2; fi
      done
    done
  fi
  [ -n "$pc" ] || pc="$(command -v pkg-config || command -v pkgconf)"
  PKG_CONFIG="$(cygpath -u "$pc")"
  [ -x "$PKG_CONFIG" ] || windows_die "pkg-config 未找到"
  # Native pkgconf uses Windows path separators; don't export its executable to Meson.
  export PKG_CONFIG_PATH="$P_MIXED/lib/pkgconfig;$VCPKG_MIXED/lib/pkgconfig${PKG_CONFIG_PATH:+;$PKG_CONFIG_PATH}"
  unset PKG_CONFIG
  WINDOWS_PKG_CONFIG="$(cygpath -u "$pc")"
  export PATH="$(dirname "$WINDOWS_PKG_CONFIG"):$PATH"
  for root in "${tool_roots[@]}"; do
    if [ -f "$root/tools/shaderc/glslc.exe" ]; then export PATH="$root/tools/shaderc:$PATH"; break; fi
  done
  windows_require glslc
  glslc --version >/dev/null || windows_die "glslc 无法运行；请提供匹配宿主架构的 shaderc 工具"
  windows_require msbuild
  windows_pwsh "$REPO_ROOT/scripts/ci/build-zimg-windows.ps1" -InstallRoot "$(cygpath -w "$P")" -BuildRoot "$(cygpath -w "$BUILD_ROOT")" -Architecture "$WINDOWS_ARCH" -Ref "${ZIMG_REF:-master}"
  export INCLUDE="$P_MIXED/include;$VCPKG_MIXED/include;${INCLUDE:-}"
  export LIB="$P_MIXED/lib;$VCPKG_MIXED/lib;${LIB:-}"
  windows_pc_overlay
  "$WINDOWS_PKG_CONFIG" --static --exists 'libjxl >= 0.7.0' 'libjxl_threads >= 0.7.0' zimg sdl2
}

# Use private path-rewritten copies; installed .pc files must never retain temp junctions.
windows_pc_overlay() {
  local overlay="$BUILD_ROOT/pkgconfig"
  mkdir -p "$overlay"
  python3 - "$overlay" "$(windows_mixed "$P")" "$P_MIXED" "$(windows_mixed "$VCPKG_INSTALLED")" "$VCPKG_MIXED" <<'PY'
import pathlib, re, sys
out = pathlib.Path(sys.argv[1])
for actual, alias in ((sys.argv[4], sys.argv[5]), (sys.argv[2], sys.argv[3])):
    for directory in ('lib/pkgconfig', 'share/pkgconfig'):
        for pc in pathlib.Path(actual, directory).glob('*.pc'):
            text = pc.read_text(encoding='utf-8-sig')
            text = re.sub(r'^prefix=.*$', lambda m: 'prefix=' + alias, text, flags=re.M)
            text = text.replace('${pcfiledir}', alias + '/' + directory)
            text = text.replace(actual, alias).replace(actual.replace('/', '\\'), alias)
            (out / pc.name).write_text(text, encoding='utf-8')
PY
  export PKG_CONFIG_PATH="$(windows_mixed "$overlay");$P_MIXED/lib/pkgconfig;$VCPKG_MIXED/lib/pkgconfig${WINDOWS_ORIGINAL_PC_PATH:+;$WINDOWS_ORIGINAL_PC_PATH}"
}

windows_find_clang() {
  local candidate
  CLANG_BIN="${CLANG_BIN:-}"
  if [ -n "$CLANG_BIN" ]; then CLANG_BIN="$(cygpath -u "$CLANG_BIN")"; fi
  if [ -z "$CLANG_BIN" ] && [ -n "${VCINSTALLDIR:-}" ]; then
    candidate="$(cygpath -u "$VCINSTALLDIR")/Tools/Llvm/x64/bin"
    [ ! -f "$candidate/clang-cl.exe" ] || CLANG_BIN="$candidate"
  fi
  if [ -z "$CLANG_BIN" ]; then
    for candidate in '/c/Program Files/Microsoft Visual Studio/18/'{Enterprise,Professional,Community}'/VC/Tools/Llvm/x64/bin' '/c/Program Files/Microsoft Visual Studio/2022/'{Enterprise,Professional,Community}'/VC/Tools/Llvm/x64/bin'; do
      if [ -f "$candidate/clang-cl.exe" ]; then CLANG_BIN="$candidate"; break; fi
    done
  fi
  if [ -n "$CLANG_BIN" ]; then
    windows_space_free "$CLANG_BIN" clang
    CLANG_BIN="$WINDOWS_PATH_RESULT"
  fi
}

windows_hardware() {
  local candidate cuda_flags=()
  HARDWARE_FLAGS=()
  CUDA_LIB_DIR=''
  EXTRA_INCLUDES=()
  EXTRA_LIBPATHS=()
  LICENSE_ROOTS=("$VCPKG_INSTALLED/share" "$BUILD_ROOT/vmaf")
  windows_find_clang
  case "$WINDOWS_FLAVOR" in
    nvidia)
      CUDA_HOME="${CUDA_HOME:-${CUDA_PATH:-}}"
      if [ -z "$CUDA_HOME" ]; then
        for candidate in '/c/Program Files/NVIDIA GPU Computing Toolkit/CUDA'/v*; do
          if [ -f "$candidate/bin/nvcc.exe" ]; then CUDA_HOME="$candidate"; fi
        done
      fi
      [ -n "$CUDA_HOME" ] || windows_die "未找到 CUDA toolkit"
      CUDA_HOME="$(cygpath -u "$CUDA_HOME")"
      windows_space_free "$CUDA_HOME" cuda
      CUDA_HOME="$WINDOWS_PATH_RESULT"
      CUDA_MIXED="$(windows_mixed "$CUDA_HOME")"
      [ -f "$CUDA_HOME/bin/nvcc.exe" ] || windows_die "CUDA nvcc.exe 未找到（VMAF CUDA 需要）"
      if [ "$WINDOWS_POLICY" = local ]; then
        WINDOWS_LICENSE_FLAGS=(--enable-nonfree)
        WINDOWS_PACKAGE_FLAGS=(--local-only)
        HARDWARE_FLAGS=(--enable-ffnvcodec --enable-cuda-nvcc --disable-cuda-llvm "--nvcc=$CUDA_MIXED/bin/nvcc.exe" --enable-cuvid --enable-nvenc)
      else
        [ -f "${CLANG_BIN:-}/clang.exe" ] || windows_die "可发布 CUDA FFmpeg 需要支持 CUDA LLVM 的 VS clang.exe；设置 CLANG_BIN"
        export CUDA_PATH="$CUDA_MIXED" CUDACXX="$CUDA_HOME/bin/nvcc.exe" PATH="$CUDA_HOME/bin:$PATH"
        CUDA_LIB_DIR="$CUDA_MIXED/lib/x64"
        [ -d "$CUDA_LIB_DIR" ] || windows_die "缺少 CUDA x64 库目录"
        export INCLUDE="$CUDA_MIXED/include;$INCLUDE" LIB="$CUDA_LIB_DIR;$LIB"
        # Probe PTX compilation with exactly the FFmpeg CUDA LLVM compiler and flags.
        local clang_targets
        clang_targets="$("$CLANG_BIN/clang.exe" --print-targets)"
        [[ "$clang_targets" == *nvptx* ]] || windows_die "VS Clang 不含 NVPTX 后端；不会回退到 nonfree cuda-nvcc"
        printf '__attribute__((global)) void ffmpeg_cuda_probe(void) {}\n' > "$BUILD_ROOT/cuda-probe.cu"
        cuda_flags=(-S -nocudainc -nocudalib --cuda-gpu-arch=sm_75 -O2)
        "$CLANG_BIN/clang.exe" "${cuda_flags[@]}" -x cuda --cuda-device-only -o "$(windows_mixed "$BUILD_ROOT/cuda-probe.ptx")" "$(windows_mixed "$BUILD_ROOT/cuda-probe.cu")" || windows_die "VS Clang PTX 编译失败；不会回退到 nonfree cuda-nvcc"
        python3 - "$BUILD_ROOT/cuda-probe.ptx" <<'PY'
import pathlib, sys
if '.entry' not in pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'):
    raise SystemExit('CUDA LLVM probe produced no PTX kernel entry')
PY
        HARDWARE_FLAGS=(--enable-ffnvcodec --disable-cuda-nvcc --enable-cuda-llvm "--nvcc=$(windows_mixed "$CLANG_BIN")/clang.exe" "--nvccflags=${cuda_flags[*]}" --enable-cuvid --enable-nvenc)
      fi
      export CUDA_PATH="$CUDA_MIXED" CUDACXX="$CUDA_HOME/bin/nvcc.exe" PATH="$CUDA_HOME/bin:$PATH"
      CUDA_LIB_DIR="$CUDA_MIXED/lib/x64"
      [ -d "$CUDA_LIB_DIR" ] || windows_die "缺少 CUDA x64 库目录"
      export INCLUDE="$CUDA_MIXED/include;$INCLUDE" LIB="$CUDA_LIB_DIR;$LIB"
      EXTRA_INCLUDES+=("$CUDA_MIXED/include")
      EXTRA_LIBPATHS+=("$CUDA_LIB_DIR")
      git clone --depth 1 https://git.ffmpeg.org/nv-codec-headers.git "$BUILD_ROOT/nv-codec-headers"
      (cd "$BUILD_ROOT/nv-codec-headers" && make -j"$THREADS" PREFIX="$P" && make PREFIX="$P" install)
      mkdir -p "$P/share/nv-codec-headers"
      python3 - "$BUILD_ROOT/nv-codec-headers/include/ffnvcodec/nvEncodeAPI.h" "$P/share/nv-codec-headers/copyright" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig')
start, end = text.find('/*'), text.find('*/')
if start < 0 or end <= start:
    raise SystemExit('Cannot locate nv-codec-headers license preamble')
pathlib.Path(sys.argv[2]).write_text(text[start:end + 2] + '\n', encoding='utf-8')
PY
      LICENSE_ROOTS+=("$BUILD_ROOT/nv-codec-headers")
      ;;
    intel-qsv)
      "$WINDOWS_PKG_CONFIG" --static --exists 'vpl >= 2.6.0'
      HARDWARE_FLAGS=(--enable-libvpl)
      EXTRA_INCLUDES+=("$VCPKG_MIXED/include/vpl")
      ;;
    amd-amf)
      git clone --depth 1 https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git "$BUILD_ROOT/AMF"
      mkdir -p "$BUILD_ROOT/AMF/amf/public/include/AMF"
      cp -r "$BUILD_ROOT/AMF/amf/public/include/core" "$BUILD_ROOT/AMF/amf/public/include/components" "$BUILD_ROOT/AMF/amf/public/include/AMF/"
      HARDWARE_FLAGS=(--enable-amf)
      EXTRA_INCLUDES+=("$(windows_mixed "$BUILD_ROOT/AMF/amf/public/include")")
      LICENSE_ROOTS+=("$BUILD_ROOT/AMF")
      ;;
    arm64)
      windows_require perl
      windows_require armasm64.exe
      git clone --depth 1 https://github.com/FFmpeg/gas-preprocessor.git "$BUILD_ROOT/gas-preprocessor"
      mkdir -p "$BUILD_ROOT/tools"
      printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$(command -v perl)" "$BUILD_ROOT/gas-preprocessor/gas-preprocessor.pl" > "$BUILD_ROOT/tools/gas-preprocessor.pl"
      chmod +x "$BUILD_ROOT/tools/gas-preprocessor.pl"
      export PATH="$BUILD_ROOT/tools:$PATH"
      HARDWARE_FLAGS=(--enable-neon "--as=gas-preprocessor.pl -arch aarch64 -as-type armasm -- armasm64.exe")
      ;;
    *) windows_die "未知 Windows 构建类型: $WINDOWS_FLAVOR" ;;
  esac
}

windows_vmaf() {
  local asm=false cc=cl.exe cuda=false candidate version
  local cargs=(-D_USE_MATH_DEFINES -D_CRT_SECURE_NO_WARNINGS -DHAVE_ALLOCA_H=0 -DHAVE_STRSEP=0)
  local cppargs=() linkargs=() prepare_args=()
  git clone --depth 1 --branch "${VMAF_REF:-master}" https://github.com/Netflix/vmaf.git "$BUILD_ROOT/vmaf"
  VMAF_SOURCE="$BUILD_ROOT/vmaf/libvmaf"
  VMAF_COMPAT="$BUILD_ROOT/vmaf-compat"
  [ "$WINDOWS_FLAVOR" != nvidia ] || cuda=true
  [ "$cuda" != true ] || prepare_args+=(--cuda --include-dir "$P_MIXED/include" --include-dir "$VCPKG_MIXED/include")
  python3 "$REPO_ROOT/scripts/ci/prepare-vmaf-windows.py" "$VMAF_SOURCE" "$VMAF_COMPAT" --architecture "$WINDOWS_ARCH" "${prepare_args[@]}"
  local compat_mixed="$(windows_mixed "$VMAF_COMPAT")"
  cargs+=("-I$compat_mixed" "-I$P_MIXED/include" "-I$VCPKG_MIXED/include")
  if [ "$WINDOWS_ARCH" = arm64 ]; then
    asm=true
    cargs+=(-DHAVE_FEATURES_H=0 -DHAVE_LOCALTIME_R=0 -DHAVE_LOCALTIME_S=1)
  elif [ -f "${CLANG_BIN:-}/clang-cl.exe" ]; then
    cc="$CLANG_BIN/clang-cl.exe"
    asm=true
  fi
  cppargs=("${cargs[@]}")
  if [ "$cc" = cl.exe ]; then cargs+=(-experimental:c11atomics); fi
  # Never publish shim headers into P/include or mix a dynamic PThreads4W ABI.
  cl.exe -nologo -MT -c "-I$compat_mixed" "-Fo$compat_mixed/pthread_shim.obj" "$compat_mixed/pthread_shim.c"
  lib.exe -nologo "-out:$P_MIXED/lib/pthread_shim.lib" "$compat_mixed/pthread_shim.obj"
  linkargs+=("$P_MIXED/lib/pthread_shim.lib")
  (cd "$VMAF_SOURCE" && CC="$cc" CXX="$cc" meson setup build --buildtype release --prefix="$P_MIXED" \
    -Denable_cuda="$cuda" -Denable_asm="$asm" -Db_vscrt=mt -Ddefault_library=static \
    -Denable_tests=false -Denable_tools=false -Denable_docs=false -Dcpp_std=c++14 \
    "-Dc_args=$(windows_meson_array "${cargs[@]}")" "-Dcpp_args=$(windows_meson_array "${cppargs[@]}")" \
    "-Dc_link_args=$(windows_meson_array "${linkargs[@]}")" "-Dcpp_link_args=$(windows_meson_array "${linkargs[@]}")" && \
    ninja -C build)
  candidate=''
  for candidate in "$VMAF_SOURCE/build/src/libvmaf.a" "$VMAF_SOURCE/build/src/vmaf.lib" "$VMAF_SOURCE/build/src/libvmaf.lib"; do
    if [ -f "$candidate" ]; then break; fi
  done
  [ -f "$candidate" ] || windows_die "未找到 VMAF 静态库"
  mkdir -p "$P/include/libvmaf"
  cp "$candidate" "$P/lib/vmaf.lib"
  cp "$VMAF_SOURCE/include/libvmaf/"*.h "$P/include/libvmaf/"
  for candidate in "$VMAF_SOURCE/build/include/version.h" "$VMAF_SOURCE/build/include/libvmaf/version.h"; do
    [ ! -f "$candidate" ] || cp "$candidate" "$P/include/libvmaf/version.h"
  done
  version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$VMAF_SOURCE/build/meson-info/intro-projectinfo.json")"
  cat > "$P/lib/pkgconfig/libvmaf.pc" <<EOF
prefix=$(windows_mixed "$P")
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libvmaf
Description: Netflix VMAF static Windows library
Version: $version
Libs: -L\${libdir} -lvmaf
Libs.private: -lpthread_shim -ladvapi32${CUDA_LIB_DIR:+ -lcuda}
Cflags: -I\${includedir} -I\${includedir}/libvmaf
EOF
  mkdir -p "$P/share/libvmaf"
  cp "$BUILD_ROOT/vmaf/LICENSE" "$P/share/libvmaf/copyright"
  windows_pc_overlay
  "$WINDOWS_PKG_CONFIG" --static --exists 'libvmaf >= 2.0.0'
}

windows_ffmpeg() {
  local path cflags="-MT -I$P_MIXED/include -I$VCPKG_MIXED/include -DLIBTWOLAME_STATIC" ldflags="-LIBPATH:$P_MIXED/lib -LIBPATH:$VCPKG_MIXED/lib"
  for path in "${EXTRA_INCLUDES[@]}"; do cflags+=" -I$path"; done
  for path in "${EXTRA_LIBPATHS[@]}"; do ldflags+=" -LIBPATH:$path"; done
  git clone --depth 1 --branch "${FFMPEG_REF:-master}" https://git.ffmpeg.org/ffmpeg.git "$BUILD_ROOT/ffmpeg-src"
  python3 "$REPO_ROOT/scripts/ci/patch-ffmpeg-msvc.py" "$BUILD_ROOT/ffmpeg-src"
  (cd "$BUILD_ROOT/ffmpeg-src" && ./configure --toolchain=msvc --prefix="$(windows_mixed "$P")" --arch="$WINDOWS_FFMPEG_ARCH" \
    --pkg-config="$WINDOWS_PKG_CONFIG" --pkg-config-flags=--static \
    "--extra-cflags=$cflags" "--extra-cxxflags=$cflags" "--extra-ldflags=$ldflags" \
    --extra-libs='advapi32.lib ole32.lib ws2_32.lib user32.lib bcrypt.lib cfgmgr32.lib gdi32.lib shell32.lib libcpmt.lib' \
    --enable-gpl --enable-version3 "${WINDOWS_LICENSE_FLAGS[@]}" --disable-shared --enable-static \
    --enable-libvmaf --enable-libjxl "${HARDWARE_FLAGS[@]}" --enable-opencl --enable-vulkan \
    --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis --enable-libtheora --enable-libaom \
    --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libzimg --enable-libsoxr --enable-libopenjpeg \
    --enable-libsnappy --enable-libsvtav1 --enable-libdav1d --enable-libopenh264 --enable-libtwolame --enable-libspeex \
    --enable-sdl2 --enable-ffmpeg --enable-ffprobe --enable-ffplay --enable-d3d11va --enable-d3d12va --enable-dxva2 --enable-mediafoundation --disable-doc && \
    make -j"$THREADS" && make install)
}

windows_verify_and_package() {
  local output="$ORIG_DIR/output" root
  if [ "$WINDOWS_POLICY" = local ] && [ "$WINDOWS_FLAVOR" = nvidia ]; then output="$ORIG_DIR/output-local-only"; fi
  local license_args=() source_args=() verify_args=()
  # Required feature/runtime checks are not grep pipelines or best-effort logs.
  local hardware_output
  case "$WINDOWS_FLAVOR" in
    nvidia)
      hardware_output="$("$P/bin/ffmpeg.exe" -hide_banner -encoders)"
      [[ "$hardware_output" == *h264_nvenc* && "$hardware_output" == *hevc_nvenc* ]] || windows_die "缺少 NVENC 编码器"
      hardware_output="$("$P/bin/ffmpeg.exe" -hide_banner -decoders)"
      [[ "$hardware_output" == *h264_cuvid* && "$hardware_output" == *hevc_cuvid* ]] || windows_die "缺少 NVDEC 解码器"
      hardware_output="$("$P/bin/ffmpeg.exe" -hide_banner -hwaccels)"
      [[ "$hardware_output" == *cuda* ]] || windows_die "缺少 CUDA 硬件加速"
      hardware_output="$("$P/bin/ffmpeg.exe" -hide_banner -filters)"
      [[ "$hardware_output" == *libvmaf_cuda* ]] || windows_die "缺少 libvmaf_cuda"
      ;;
    intel-qsv|amd-amf)
      hardware_output="$("$P/bin/ffmpeg.exe" -hide_banner -encoders)"
      if [ "$WINDOWS_FLAVOR" = intel-qsv ]; then
        [[ "$hardware_output" == *h264_qsv* ]] || windows_die "缺少 Intel QSV"
      else
        [[ "$hardware_output" == *h264_amf* ]] || windows_die "缺少 AMD AMF"
      fi
      ;;
  esac
  for root in "${LICENSE_ROOTS[@]}"; do license_args+=(--license-dir "$root"); done
  for root in "$BUILD_ROOT/zimg-src" "$BUILD_ROOT/nv-codec-headers" "$BUILD_ROOT/AMF" "$BUILD_ROOT/vmaf-compat"; do
    [ ! -d "$root" ] || source_args+=(--dependency-source "$root")
  done
  python3 "$REPO_ROOT/scripts/ci/package-runtime.py" --platform windows --bin-dir "$P/bin" --output "$output" \
    --source-dir "$BUILD_ROOT/ffmpeg-src" --license-dir "$P/share" "${license_args[@]}" "${source_args[@]}" "${WINDOWS_PACKAGE_FLAGS[@]}"
  case "$WINDOWS_FLAVOR" in
    nvidia) verify_args=(--require-encoder h264_nvenc --require-encoder hevc_nvenc) ;;
    intel-qsv) verify_args=(--require-encoder h264_qsv) ;;
    amd-amf) verify_args=(--require-encoder h264_amf) ;;
  esac
  python3 "$REPO_ROOT/scripts/ci/verify-runtime.py" --platform windows --directory "$output" "${verify_args[@]}" "${WINDOWS_PACKAGE_FLAGS[@]}"
  echo "输出：$output"
}

windows_build() {
  WINDOWS_FLAVOR="$1"
  WINDOWS_POLICY="${BUILD_POLICY:-local}"
  case "$WINDOWS_POLICY" in local|release) ;; *) windows_die "BUILD_POLICY 必须为 local 或 release" ;; esac
  WINDOWS_LICENSE_FLAGS=(--enable-nonfree)
  WINDOWS_PACKAGE_FLAGS=()
  WINDOWS_ARCH=x64
  WINDOWS_FFMPEG_ARCH=x86_64
  if [ "$WINDOWS_FLAVOR" = arm64 ]; then WINDOWS_ARCH=arm64; WINDOWS_FFMPEG_ARCH=aarch64; fi
  THREADS="${THREADS:-$(nproc)}"
  WINDOWS_ORIGINAL_PC_PATH="${PKG_CONFIG_PATH:-}"
  [[ "$THREADS" =~ ^[1-9][0-9]*$ ]] || windows_die "THREADS 必须为正整数"
  windows_init_tools
  windows_dependencies
  windows_hardware
  windows_vmaf
  windows_ffmpeg
  windows_verify_and_package
}
