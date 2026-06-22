#!/usr/bin/env bash
# ============================================================
# FFmpeg + VMAF (Windows ARM64 / Snapdragon MSVC)
# VS 2026 ARM64 Developer Command Prompt 环境下运行 Git Bash
# 运行前需执行: vcvarsall.bat amd64_arm64
# ============================================================
set -Eeuo pipefail
trap 'echo "错误：第 ${LINENO} 行"; exit 1' ERR

ORIG_DIR="$(pwd)"
THREADS="${THREADS:-$(nproc)}"
P="${INSTALL_PREFIX:-${HOME}/ffmpeg-install}"
P_MIXED="$(cygpath -m "$P" 2>/dev/null || echo "$P")"

command -v cl.exe >/dev/null 2>&1 || { echo "请先运行 vcvarsall.bat amd64_arm64 (VS 2026)"; exit 1; }

# Try to expose nasm if present (usually not required for ARM64, but harmless)
for nasm_dir in "/c/Program Files/NASM" "/c/Program Files (x86)/NASM" "/c/ProgramData/chocolatey/bin"; do
  if [ -f "$nasm_dir/nasm.exe" ]; then
    export PATH="$nasm_dir:$PATH"
    echo "nasm: $nasm_dir/nasm.exe"
    break
  fi
done

# Remove Strawberry Perl paths that shadow Git for Windows tools
__clean_path() {
  local __new="" __e
  IFS=':' read -ra __entries <<< "$PATH"
  for __e in "${__entries[@]}"; do
    case "$__e" in
      *[Ss]trawberry*) ;;
      *) __new="${__new:+${__new}:}${__e}" ;;
    esac
  done
  export PATH="$__new"
}
__clean_path

echo "=========================================="
echo "FFmpeg ARM64 (Windows MSVC)"
echo "PREFIX: $P  THREADS: $THREADS"
echo "ARCH: $(uname -m)"
echo "Compiler: $(cl.exe 2>&1 | head -n1 || echo MSVC)"
echo "=========================================="

export PATH="${P}/bin:${PATH}"

# Resolve default vcpkg root before pkg-config detection uses it.
VCPKG_INSTALLED="${VCPKG_INSTALLED:-}"
[ -z "${VCPKG_INSTALLED}" ] && [ -d "/c/vcpkg/installed/arm64-windows-static" ] && VCPKG_INSTALLED="/c/vcpkg/installed/arm64-windows-static"
[ -n "${VCPKG_INSTALLED}" ] && echo "vcpkg: $VCPKG_INSTALLED"

export PKG_CONFIG_PATH="${P_MIXED}/lib/pkgconfig;${PKG_CONFIG_PATH:-}"
# Use Git for Windows' pkg-config; Strawberry Perl's pkg-config is broken.
# Use vcpkg's pkgconf if available, otherwise fall back to Git for Windows' pkg-config
if [ -n "${VCPKG_INSTALLED:-}" ]; then
  for pc in "${VCPKG_INSTALLED}/bin/pkgconf.exe" "${VCPKG_INSTALLED}/tools/pkgconf/pkgconf.exe" "${VCPKG_INSTALLED}/tools/pkgconf/pkg-config.exe"; do
    if [ -f "$pc" ]; then export PKG_CONFIG="$pc"; break; fi
  done
fi
export PKG_CONFIG="${PKG_CONFIG:-/usr/bin/pkg-config}"

# Ensure vcpkg dependencies are discoverable by pkg-config.
# vcpkg ports do not always ship pkg-config files, so create the ones ffmpeg expects.
if [ -n "${VCPKG_INSTALLED}" ] && [ -d "${VCPKG_INSTALLED}/lib/pkgconfig" ]; then
  VCPKG_INSTALLED_MIXED="$(cygpath -m "$VCPKG_INSTALLED" 2>/dev/null || echo "$VCPKG_INSTALLED" | tr '/\\' '/' 2>/dev/null | sed -e 's#^/c/#C:/#' -e 's#^/d/#D:/#')"

  find_import_lib() {
    for name in "$@"; do
      for suffix in "" "-static" "_static"; do
        if [ -f "${VCPKG_INSTALLED}/lib/${name}${suffix}.lib" ]; then
          echo "${name}${suffix}.lib"
          return 0
        fi
      done
    done
    return 1
  }

  mkdir -p "${VCPKG_INSTALLED}/lib/pkgconfig"

  # mp3lame 的 static triplet 在 MSVC 下缺少 mpglib 内部符号，改用 dynamic triplet 的 import lib + DLL
  VCPKG_INSTALLED_DYNAMIC="${VCPKG_INSTALLED/%static/dynamic}"
  if [ -d "${VCPKG_INSTALLED_DYNAMIC}/lib" ]; then
    cp "${VCPKG_INSTALLED_DYNAMIC}/lib/libmp3lame.lib" "${VCPKG_INSTALLED}/lib/libmp3lame.lib" 2>/dev/null || true
    cp "${VCPKG_INSTALLED_DYNAMIC}/lib/mp3lame.lib" "${VCPKG_INSTALLED}/lib/mp3lame.lib" 2>/dev/null || true
    mkdir -p "${VCPKG_INSTALLED}/bin"
    cp "${VCPKG_INSTALLED_DYNAMIC}/bin/"*.dll "${VCPKG_INSTALLED}/bin/" 2>/dev/null || true
  fi

  lame_lib="$(find_import_lib libmp3lame mp3lame)" || { echo "错误：未找到 mp3lame import library"; exit 1; }
  cat > "${VCPKG_INSTALLED}/lib/pkgconfig/libmp3lame.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libmp3lame
Description: LAME MP3 encoder library
Version: 3.100
Libs: ${lame_lib}
EOF

  fdk_lib="$(find_import_lib fdk-aac libfdk-aac fdk-aac-2)" || { echo "错误：未找到 fdk-aac import library"; exit 1; }
  cat > "${VCPKG_INSTALLED}/lib/pkgconfig/libfdk-aac.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libfdk-aac
Description: Fraunhofer FDK AAC codec library
Version: 2.0.2
Libs: ${fdk_lib}
EOF

  # SDL2 (ffplay 需要)
  if [ ! -f "${VCPKG_INSTALLED}/lib/pkgconfig/sdl2.pc" ]; then
    sdl2_lib="$(find_import_lib SDL2)" || { echo "错误：未找到 SDL2 import library"; exit 1; }
    sdl2main_lib="$(find_import_lib SDL2main)" || sdl2main_lib=""
    cat > "${VCPKG_INSTALLED}/lib/pkgconfig/sdl2.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: sdl2
Description: Simple DirectMedia Layer
Version: 2.30.0
Libs: ${sdl2main_lib:+$sdl2main_lib }$sdl2_lib
Cflags: -I\${includedir} -I\${includedir}/SDL2
EOF
  fi

  # 创建库名别名，避免 ffmpeg fallback 找不到文件
  ensure_lib_alias() {
    local actual="$1" alias="$2"
    if [ -f "${VCPKG_INSTALLED}/lib/${actual}" ] && [ ! -f "${VCPKG_INSTALLED}/lib/${alias}" ]; then
      cp "${VCPKG_INSTALLED}/lib/${actual}" "${VCPKG_INSTALLED}/lib/${alias}"
      echo "  alias: ${alias} -> ${actual}"
    fi
  }
  ensure_lib_alias "${lame_lib}" "mp3lame.lib"
  ensure_lib_alias "${lame_lib}" "libmp3lame.lib"
  ensure_lib_alias "${fdk_lib}" "fdk-aac.lib"
  ensure_lib_alias "${fdk_lib}" "libfdk-aac.lib"

  # 为 FFmpeg 的 --enable-libxxx 选项提供 pkg-config 回退（vcpkg 并不总是自带 .pc）
  write_pc() {
    local pc_name="$1" pc_desc="$2" pc_libs="$3" pc_cflags="${4:-}" pc_requires="${5:-}"
    local pc_path="${VCPKG_INSTALLED}/lib/pkgconfig/${pc_name}.pc"
    [ -f "$pc_path" ] && return 0
    cat > "$pc_path" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: ${pc_name}
Description: ${pc_desc}
Version: 1.0.0
${pc_requires:+Requires: ${pc_requires}}
Libs: ${pc_libs}
${pc_cflags:+Cflags: ${pc_cflags}}
EOF
  }
  write_pc "libx264" "libx264 library" "-lx264"
  write_pc "libx265" "libx265 library" "-lx265"
  write_pc "libvpx" "libvpx library" "-lvpx"
  write_pc "opus" "opus library" "-lopus"
  write_pc "vorbis" "vorbis library" "-lvorbis"
  write_pc "vorbisenc" "vorbisenc library" "-lvorbisenc" "" "vorbis"
  write_pc "theora" "theora library" "-ltheora"
  write_pc "theoradec" "theoradec library" "-ltheoradec"
  write_pc "theoraenc" "theoraenc library" "-ltheoraenc" "" "theoradec"
  write_pc "libaom" "libaom library" "-laom"
  write_pc "libwebp" "libwebp library" "-lwebp"
  write_pc "libass" "libass library" "-lass"
  write_pc "freetype2" "freetype2 library" "-lfreetype" "-I\${includedir}/freetype2"
  write_pc "fontconfig" "fontconfig library" "-lfontconfig"
  write_pc "zimg" "zimg library" "-lzimg"
  write_pc "soxr" "soxr library" "-lsoxr"
  write_pc "libopenjp2" "OpenJPEG JPEG 2000 library" "-lopenjp2"
  write_pc "snappy" "snappy library" "-lsnappy"
  # 重写 SvtAv1Enc.pc：vcpkg 生成的 .pc 会携带 Cflags.private: -UEB_DLL，
  # MSVC 链接器会把它当成未知选项；同时修正库名与实际导入库一致。
  svt_lib="$(find_import_lib SvtAv1Enc svtav1)" || { echo "错误：未找到 SvtAv1Enc import library"; exit 1; }
  fastfeat_lib="$(find_import_lib fastfeat)" || { echo "错误：未找到 fastfeat import library"; exit 1; }
  svt_json="${VCPKG_INSTALLED}/share/svt-av1/vcpkg.json"
  svt_version=$(python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
    for k in ("version","version-semver","version-string","version-date"):
        v=data.get(k)
        if v:
            print(v.split("#")[0])
            sys.exit(0)
except Exception as e:
    pass
print("unknown")
' < "$svt_json" 2>/dev/null || echo unknown)
  if [ "$svt_version" = "unknown" ]; then
    svt_abi="${VCPKG_INSTALLED}/share/svt-av1/vcpkg_abi_info.txt"
    if [ -f "$svt_abi" ]; then
      svt_version_abi=$(grep -E '^version[[:space:]]+' "$svt_abi" | head -1 | awk '{print $2}')
      [ -n "$svt_version_abi" ] && svt_version="$svt_version_abi"
    fi
  fi
  if [ "$svt_version" = "unknown" ]; then
    for info_dir in "${VCPKG_INSTALLED}/../vcpkg/info" "${VCPKG_INSTALLED}/vcpkg/info"; do
      [ -d "$info_dir" ] || continue
      list_file=$(find "$info_dir" -maxdepth 1 -name 'svt-av1_*.list' | head -1)
      if [ -n "$list_file" ]; then
        svt_version_list=$(basename "$list_file" | sed -E 's/^svt-av1_([^_]+)_.*/\1/')
        [ -n "$svt_version_list" ] && { svt_version="$svt_version_list"; break; }
      fi
    done
  fi
  if [ "$svt_version" = "unknown" ]; then
    svt_header="${VCPKG_INSTALLED}/include/EbSvtAv1Enc.h"
    if [ -f "$svt_header" ]; then
      svt_major=$(grep -E '#define[[:space:]]+SVT_AV1_VERSION_MAJOR[[:space:]]+[0-9]+' "$svt_header" | head -1 | awk '{print $3}')
      svt_minor=$(grep -E '#define[[:space:]]+SVT_AV1_VERSION_MINOR[[:space:]]+[0-9]+' "$svt_header" | head -1 | awk '{print $3}')
      svt_patch=$(grep -E '#define[[:space:]]+SVT_AV1_VERSION_PATCH[[:space:]]+[0-9]+' "$svt_header" | head -1 | awk '{print $3}')
      if [ -n "$svt_major" ] && [ -n "$svt_minor" ] && [ -n "$svt_patch" ]; then
        svt_version="${svt_major}.${svt_minor}.${svt_patch}"
      fi
    fi
  fi
  echo "SvtAv1Enc.pc Version: $svt_version"
  cat > "${VCPKG_INSTALLED}/lib/pkgconfig/SvtAv1Enc.pc" <<EOF
prefix=${VCPKG_INSTALLED_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: SvtAv1Enc
Description: SVT-AV1 encoder library
Version: ${svt_version}
Libs: ${svt_lib} ${fastfeat_lib}
Cflags: -I\${includedir} -I\${includedir}/svt-av1
EOF
  write_pc "libdav1d" "dav1d AV1 decoder library" "-ldav1d"
  write_pc "libopenh264" "OpenH264 library" "-lopenh264"
  write_pc "libtwolame" "TwoLAME MP2 encoder library" "-ltwolame"
  write_pc "libspeex" "Speex codec library" "-lspeex"
  write_pc "libjxl" "JPEG XL library" "-ljxl"

  export PKG_CONFIG_PATH="${VCPKG_INSTALLED}/lib/pkgconfig;${PKG_CONFIG_PATH:-}"
fi

# ---- 清理 ----
rm -rf "$P" /tmp/vmaf /tmp/ffmpeg-src 2>/dev/null || true
mkdir -p "$P"/{bin,lib,include,lib/pkgconfig}

# ---- VMAF (CPU) ----
echo "[1/4] VMAF"
cd /tmp && rm -rf vmaf
git clone --depth 1 https://github.com/Netflix/vmaf.git
cd vmaf/libvmaf && rm -rf build
# Ensure MSVC link.exe before Git's link.EXE for meson
CLDIR=$(dirname "$(which cl.exe 2>/dev/null)" 2>/dev/null || true)
[ -n "$CLDIR" ] && export PATH="${CLDIR}:${PATH}"
# Patch VMAF for Windows ARM64 MSVC: missing POSIX headers, ARM64 intrinsics,
# and void* arithmetic which MSVC does not allow.
python3 -c '
import pathlib
for path in ("src/feature/mkdirp.c", "src/feature/mkdirp.h", "src/log.c",
             "src/feature/cuda/integer_adm_cuda.c", "src/feature/integer_vif.h",
             "src/feature/integer_vif.c", "src/feature/integer_adm.c"):
    p = pathlib.Path(path)
    if not p.exists():
        continue
    s = p.read_text(encoding="utf-8")
    s = s.replace("#include <unistd.h>", "#ifdef _WIN32\n#include <direct.h>\n#include <io.h>\n#else\n#include <unistd.h>\n#endif")
    s = s.replace("#include <sys/types.h>", "#ifdef _WIN32\n#include <direct.h>\ntypedef int mode_t;\n#else\n#include <sys/types.h>\n#endif")
    s = s.replace("int rc = mkdir(pathname);", "int rc = _mkdir(pathname);")
    s = s.replace(
        "#ifdef _MSC_VER\n#include <intrin.h>\n\nstatic inline int __builtin_clz(unsigned x) {\n    return (int)__lzcnt(x);\n}\n\nstatic inline int __builtin_clzll(unsigned long long x) {\n    return (int)__lzcnt64(x);\n}\n\n#endif",
        "#if defined(_MSC_VER) && defined(_M_ARM64)\n#include <intrin.h>\n\nstatic inline int __builtin_clz(unsigned x) {\n    return (int)_CountLeadingZeros(x);\n}\n\nstatic inline int __builtin_clzll(unsigned long long x) {\n    return (int)_CountLeadingZeros64(x);\n}\n\n#elif defined(_MSC_VER)\n#include <intrin.h>\n\nstatic inline int __builtin_clz(unsigned x) {\n    return (int)__lzcnt(x);\n}\n\nstatic inline int __builtin_clzll(unsigned long long x) {\n    return (int)__lzcnt64(x);\n}\n\n#endif"
    )
    s = s.replace(
        "void *data = aligned_malloc(data_sz, MAX_ALIGN);",
        "char *data = (char *)aligned_malloc(data_sz, MAX_ALIGN);"
    )
    s = s.replace(
        "#include \"integer_adm.h\"",
        "#include \"integer_adm.h\"\n\n#if defined(_MSC_VER) && defined(_M_ARM64)\n#include <intrin.h>\n#define __builtin_clz(x) _CountLeadingZeros(x)\n#endif"
    )
    p.write_text(s, encoding="utf-8")
compat_dir = pathlib.Path("src/compat/msvc/common")
compat_dir.mkdir(parents=True, exist_ok=True)
(compat_dir / "attributes.h").write_text(
    "#ifndef COMPAT_COMMON_ATTRIBUTES_H_\n"
    "#define COMPAT_COMMON_ATTRIBUTES_H_\n"
    "#endif\n"
)
'
# Patch C99 VLAs for MSVC C11: MSVC does not support variable-length arrays.
python3 -c '
import pathlib
for path in ("src/predict.c", "src/libvmaf.c", "src/read_json_model.c"):
    p = pathlib.Path(path)
    if not p.exists():
        continue
    s = p.read_text(encoding="utf-8")
    if "#include <malloc.h>" not in s:
        s = "#include <malloc.h>\n" + s
    s = s.replace("double scores[model_collection->cnt];", "double *scores = (double *)_alloca(sizeof(double) * model_collection->cnt);")
    s = s.replace("char name[name_sz];", "char *name = (char *)_alloca(name_sz);")
    s = s.replace("char cfg_name[cfg_name_sz];", "char *cfg_name = (char *)_alloca(cfg_name_sz);")
    s = s.replace("char generated_key[generated_key_sz];", "char generated_key[5];")
    p.write_text(s, encoding="utf-8")
'
# PThreads4W (vcpkg) provides pthread.h on Windows
PTHREAD_CFLAGS=""
PTHREAD_LDFLAGS=""
if [ -n "${VCPKG_INSTALLED:-}" ] && [ -f "${VCPKG_INSTALLED}/include/pthread.h" ]; then
  PTHREAD_CFLAGS="-I${VCPKG_INSTALLED_MIXED}/include"
  PTHREAD_LIB="$(find "${VCPKG_INSTALLED}/lib" -maxdepth 1 -name 'pthreadVC*.lib' | head -n1)"
  [ -z "$PTHREAD_LIB" ] && PTHREAD_LIB="$(find "${VCPKG_INSTALLED}/lib" -maxdepth 1 -name 'pthread*.lib' | head -n1)"
  if [ -n "$PTHREAD_LIB" ]; then
    PTHREAD_LDFLAGS="$(cygpath -m "$PTHREAD_LIB" 2>/dev/null || echo "$PTHREAD_LIB")"
    echo "使用 PThreads4W: $PTHREAD_LIB"
    # 让 pthreadVC3.dll 在运行时可被找到（如 meson 编译器自检）
    if [ -d "${VCPKG_INSTALLED}/bin" ]; then
      export PATH="${VCPKG_INSTALLED}/bin:${PATH}"
    fi
  else
    echo "错误：找到 pthread.h 但未找到 pthread*.lib (${VCPKG_INSTALLED}/lib)"; exit 1
  fi
fi
# Helper: build a Meson array literal from positional args (handles spaces safely)
__meson_array() {
  local arr="[" first=1
  for x in "$@"; do
    [ "$first" -eq 1 ] || arr="$arr,"
    first=0
    arr="$arr\"$x\""
  done
  arr="$arr]"
  printf '%s' "$arr"
}

VMAF_C_ARGS=$(__meson_array "-D_USE_MATH_DEFINES" ${PTHREAD_CFLAGS:+"$PTHREAD_CFLAGS"})
VMAF_LINK_ARGS=$(__meson_array ${PTHREAD_LDFLAGS:+"$PTHREAD_LDFLAGS"})
PKG_CONFIG_PATH="${P_MIXED}/lib/pkgconfig;${PKG_CONFIG_PATH:-}" \
meson setup build --buildtype release --prefix="$P" -Denable_cuda=false -Denable_asm=false -Db_vscrt=mt -Ddefault_library=static \
  -Denable_tests=false -Denable_tools=false -Denable_docs=false -Dcpp_std=c++17 \
  -Dc_args="$VMAF_C_ARGS" \
  -Dc_link_args="$VMAF_LINK_ARGS"
ninja -vC build

# Manual install: build a static libvmaf on Windows/MSVC to avoid DLL import-library issues.
mkdir -p "$P/lib" "$P/lib/pkgconfig" "$P/include/libvmaf"

vmaf_static_lib=""
for cand in build/src/libvmaf.a build/src/vmaf.lib build/src/libvmaf.lib; do
  [ -f "$cand" ] && { vmaf_static_lib="$cand"; break; }
done
[ -z "$vmaf_static_lib" ] && { echo "错误：未找到 VMAF static library (build/src)"; ls -la build/src; exit 1; }

cp "$vmaf_static_lib" "$P/lib/vmaf.lib"
cp include/libvmaf/*.h "$P/include/libvmaf/"
[ -f build/include/version.h ] && cp build/include/version.h "$P/include/libvmaf/"
[ -f build/include/libvmaf/version.h ] && cp build/include/libvmaf/version.h "$P/include/libvmaf/"

P_MIXED="$(cygpath -m "$P" 2>/dev/null || echo "$P")"
cat > "$P/lib/pkgconfig/libvmaf.pc" <<EOF
prefix=${P_MIXED}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libvmaf
Description: Netflix VMAF library
Version: 3.0.0
Libs: -lvmaf ${PTHREAD_LDFLAGS} -ladvapi32
Cflags: -I\${includedir}/libvmaf
EOF

export PKG_CONFIG_PATH="$P_MIXED/lib/pkgconfig${PKG_CONFIG_PATH:+;$PKG_CONFIG_PATH}"
echo "libvmaf.pc contents:"
cat "$P/lib/pkgconfig/libvmaf.pc"
echo "pkg-config check: $($PKG_CONFIG --modversion libvmaf 2>&1 || true)"
echo "pkg-config --libs: $($PKG_CONFIG --libs libvmaf 2>&1 || true)"

# ---- FFmpeg ----
echo "[2/4] FFmpeg (MSVC ARM64)"
cd /tmp && rm -rf gas-preprocessor
git clone --depth 1 https://github.com/FFmpeg/gas-preprocessor.git gas-preprocessor
export PATH="/tmp/gas-preprocessor:$PATH"

cd /tmp && rm -rf ffmpeg-src
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
cd ffmpeg-src
# Patch MSVC dependency awk command for MSYS2 make
python3 -c 'import pathlib; p = pathlib.Path("configure"); s = p.read_text(encoding="utf-8"); s = s.replace(r'\''gsub(/\\/, "/")'\'', r'\''gsub(/\\\\/, "/")'\''); p.write_text(s, encoding="utf-8")'
# Patch ffbuild/library.mak so lib.exe receives a Windows-absolute response file path.
python3 -c 'import pathlib; p=pathlib.Path("ffbuild/library.mak"); s=p.read_text(encoding="utf-8"); old="ifeq ($(RESPONSE_FILES),yes)\n\t$(Q)echo $^ > $@.objs\n\t$(AR) $(ARFLAGS) $(AR_O) @$@.objs\nelse"; new="ifeq ($(RESPONSE_FILES),yes)\nifeq ($(findstring lib.exe,$(AR)),lib.exe)\n\t$(Q)$(file > $@.objs,$(subst /,\\\\,$^))\n\t$(AR) $(ARFLAGS) $(AR_O) \"@$(shell python3 -c \"import os; print(os.path.abspath(\\\"$@.objs\\\"))\")\"\nelse\n\t$(Q)echo $^ > $@.objs\n\t$(AR) $(ARFLAGS) $(AR_O) @$@.objs\nendif\nelse"; p.write_text(s.replace(old,new,1),encoding="utf-8")'

VCPKG_CFLAGS=""; VCPKG_LDFLAGS=""
[ -n "${VCPKG_INSTALLED}" ] && VCPKG_CFLAGS="-I${VCPKG_INSTALLED}/include" && VCPKG_LDFLAGS="-LIBPATH:${VCPKG_INSTALLED}/lib"

./configure --toolchain=msvc --prefix="$P" --arch=arm64 \
  --pkg-config-flags="--static" \
  --extra-cflags="-I${P_MIXED}/include ${VCPKG_CFLAGS}" \
  --extra-ldflags="-LIBPATH:${P_MIXED}/lib ${VCPKG_LDFLAGS}" \
  --extra-libs="advapi32.lib ole32.lib ws2_32.lib user32.lib bcrypt.lib cfgmgr32.lib gdi32.lib shell32.lib libcpmt.lib" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-libvmaf \
  --enable-opencl --enable-vulkan \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis --enable-libtheora --enable-libaom --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libzimg --enable-libsoxr --enable-libopenjpeg --enable-libsnappy \
  --enable-libsvtav1 --enable-libdav1d --enable-libopenh264 --enable-libtwolame --enable-libspeex --enable-libjxl \
  --enable-libmp3lame --enable-libfdk-aac --enable-sdl2 \
  --enable-d3d11va --enable-d3d12va --enable-dxva2 --enable-mediafoundation \
  --disable-doc
make -j"$THREADS" && make install

# ---- 复制 DLL ----
echo "[3/4] DLL"
[ -n "${VCPKG_INSTALLED}" ] && [ -d "${VCPKG_INSTALLED}/bin" ] && \
  for dll in libmp3lame.dll fdk-aac-2.dll SDL2.dll zlib1.dll; do
    [ -f "${VCPKG_INSTALLED}/bin/$dll" ] && cp "${VCPKG_INSTALLED}/bin/$dll" "$P/bin/" && echo "  $dll"
  done

# ---- 验证 + 输出 ----
echo "--- ffmpeg ---"
"$P/bin/ffmpeg.exe" -version 2>&1 | head -n3
echo "--- HW Accel ---"
"$P/bin/ffmpeg.exe" -hide_banner -hwaccels 2>&1 || echo "(none)"
echo "--- Decoders (hw) ---"
"$P/bin/ffmpeg.exe" -hide_banner -decoders 2>&1 | grep -iE '_d3d11va|_dxva2|_mf' | head -10 || echo "(none)"
echo "--- All decoders (first 50) ---"
"$P/bin/ffmpeg.exe" -hide_banner -decoders 2>&1 | head -50 || echo "(none)"
echo "--- Encoders ---"
"$P/bin/ffmpeg.exe" -hide_banner -encoders 2>&1 | grep -iE 'libmp3lame|libfdk_aac|_mf' || echo "(none)"
echo "--- VMAF ---"
"$P/bin/ffmpeg.exe" -hide_banner -filters 2>&1 | grep -i vmaf || echo "(none)"

echo "[4/4] 输出"
mkdir -p "$ORIG_DIR/output"
cp "$P/bin/ffmpeg.exe" "$P/bin/ffprobe.exe" "$P/bin/ffplay.exe" "$ORIG_DIR/output/"
cp "$P/bin/"*.dll "$ORIG_DIR/output/" 2>/dev/null || true
ls -lh "$ORIG_DIR/output/"
