#!/usr/bin/env bash
# 为 Linux 构建生成缺失的 pkg-config 回退文件。
# 用法: bash scripts/ci/linux-pc-fallbacks.sh <install_prefix>
set -euo pipefail

P="${1:?Usage: $0 <install_prefix>}"
mkdir -p "$P/lib/pkgconfig"

# libopenjp2.pc — 在自定义安装目录强制覆盖不带 -DOPJ_STATIC。
# 不在系统目录（/usr）操作，避免权限问题。
if [ "$P" != "/usr" ] && [ "$P" != "/usr/local" ]; then
    OPENJP2_INCLUDE=$(ls -d /usr/include/openjpeg-* 2>/dev/null | head -1 || echo /usr/include)
    printf 'prefix=/usr\nexec_prefix=${prefix}\nlibdir=/usr/lib/x86_64-linux-gnu\nincludedir=%s\nName: libopenjp2\nDescription: OpenJPEG JPEG 2000 library\nVersion: 2.5.0\nLibs: -L${libdir} -lopenjp2\nCflags: -I${includedir}\n' "$OPENJP2_INCLUDE" > "$P/lib/pkgconfig/libopenjp2.pc"
    echo "Created libopenjp2.pc (without -DOPJ_STATIC)"
fi

# x265.pc — 某些发行版不附带
if ! pkg-config --exists x265 2>/dev/null; then
    printf 'prefix=/usr\nexec_prefix=${prefix}\nlibdir=/usr/lib/x86_64-linux-gnu\nincludedir=/usr/include\nName: x265\nDescription: H.265/HEVC encoder\nVersion: 1.0.0\nLibs: -L${libdir} -lx265\nLibs.private: -lstdc++ -lm -lgcc -lpthread\nCflags: -I${includedir}\n' > "$P/lib/pkgconfig/x265.pc"
    echo "Created x265.pc"
fi

# kvazaar.pc — Ubuntu 26.04 版本占位符修复
kvazaar_ver=$(dpkg-query -W -f='${Version}' libkvazaar-dev 2>/dev/null | sed -E 's/^[0-9]+://; s/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
for pc in $(find /usr/lib /usr/local/lib -name kvazaar.pc 2>/dev/null); do
    echo "Found kvazaar.pc: $pc"
    pc_dir=$(dirname "$pc")
    if [[ ":${PKG_CONFIG_PATH:-}:" != *":$pc_dir:"* ]]; then
        export PKG_CONFIG_PATH="${pc_dir}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
    if [ -n "$kvazaar_ver" ]; then
        sudo sed -i -E "s/^Version:.*/Version: $kvazaar_ver/" "$pc"
        echo "Patched $pc -> Version: $kvazaar_ver"
    fi
done
echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}" | tee -a "${GITHUB_ENV:-/dev/null}"
pkg-config --modversion kvazaar || true
