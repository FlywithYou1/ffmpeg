#!/usr/bin/env python3
"""为 Windows MSVC 构建修补 FFmpeg 源码"""
import pathlib
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: patch-ffmpeg-msvc.py SOURCE_DIR")
src = pathlib.Path(sys.argv[1]).resolve()

configure = src / "configure"
s = configure.read_text(encoding="utf-8")

# MSVC's runtime provides libm; preserve unrelated -lmfplat/-lmfuuid flags.
s, removed_lm = re.subn(r"(?<!\S)-lm(?=\s|$)", "", s)
# Snappy exposes its stable C API; the C++ header probe is not MSVC-compatible.
s, replaced_snappy = re.subn(
    r'(require(?:_cpp)? libsnappy) (?:snappy\.h|snappy-c\.h) "?snappy::(?:MaxCompressedLength|RawCompress)"? -lsnappy',
    'require libsnappy snappy-c.h snappy_compress -lsnappy', s,
)
if not replaced_snappy:
    s, replaced_snappy = re.subn(
        re.escape('require libsnappy snappy-c.h snappy_compress -lsnappy -lstdc++'),
        'require libsnappy snappy-c.h snappy_compress -lsnappy', s)
# twolame must be linked against its static import library.
s, replaced_twolame = re.subn(
    r'((?:require|check_lib) libtwolame twolame\.h \S+ -ltwolame)(?! -DLIBTWOLAME_STATIC)',
    r'\1 -DLIBTWOLAME_STATIC', s,
)
configure.write_text(s, encoding="utf-8")

# ffbuild/common.mak: 还原 INSTALL_FILES 宏为短命令。
# FFmpeg master 33d5616 (2026-08-10) 把安装输出改成"每个文件一条 printf"
# 展开，libavutil 有 60+ 个头文件，导致 install-libavutil-headers 的 recipe
# 命令超长，Windows Git Bash 的 sh 解析时被截断，报：
#   /usr/bin/sh: -c: line 1: unexpected EOF while looking for matching `"'
# 这里改回旧式"每目标打印一次 + 直接 install"，命令长度与旧版一致。
# （该宏被 Makefile / fftools / doc / library.mak 全树共用，改一处即全部生效）
commonmak = src / "ffbuild" / "common.mak"
s = commonmak.read_text(encoding="utf-8")
s, replaced_install = re.subn(
    r"^INSTALL_FILES = @\$\(foreach F,\$\(2\),printf .*$",
    'INSTALL_FILES = @$(call ECHO,INSTALL,$(2:$(SRC_PATH)/%=%)); $(INSTALL) $(1) $(2) "$(3)"',
    s,
    flags=re.M,
)
if not replaced_install and "$(call ECHO,INSTALL" not in s:
    raise SystemExit("INSTALL_FILES macro changed upstream; review the MSVC patch")
commonmak.write_text(s, encoding="utf-8")

# Upstream drops these rules every so often; report instead of patching blind.
if not removed_lm:
    print("WARN: configure has no -lm to strip; skip")
if not replaced_snappy or not replaced_twolame:
    print("WARN: snappy/twolame probe changed upstream; review the MSVC patch")

print("Patched configure and ffbuild/common.mak")
