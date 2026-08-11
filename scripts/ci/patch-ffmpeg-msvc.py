#!/usr/bin/env python3
"""为 Windows MSVC 构建修补 FFmpeg 源码"""
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/ffmpeg-src")

# 1. configure: gsub 路径分隔符修复
configure = src / "configure"
s = configure.read_text(encoding="utf-8")
s = s.replace(r'gsub(/\\/, "/")', r'gsub(/\\\\/, "/")')
configure.write_text(s, encoding="utf-8")

# 2. ffbuild/library.mak: lib.exe 响应文件路径修复
libmak = src / "ffbuild" / "library.mak"
s = libmak.read_text(encoding="utf-8")
old = """ifeq ($(RESPONSE_FILES),yes)
\t$(Q)echo $^ > $@.objs
\t$(AR) $(ARFLAGS) $(AR_O) @$@.objs
else"""
new = """ifeq ($(RESPONSE_FILES),yes)
ifeq ($(findstring lib.exe,$(AR)),lib.exe)
\t$(Q)$(file > $@.objs,$(subst /,\\\\,$^))
\t$(AR) $(ARFLAGS) $(AR_O) "@$(shell python3 -c "import os; print(os.path.abspath(\\"$@.objs\\"))")"
else
\t$(Q)echo $^ > $@.objs
\t$(AR) $(ARFLAGS) $(AR_O) @$@.objs
endif
else"""
s = s.replace(old, new, 1)
libmak.write_text(s, encoding="utf-8")

# 3. ffbuild/common.mak: 还原 INSTALL_FILES 宏为短命令
#    FFmpeg master 33d5616 (2026-08-10) 把安装输出改成"每个文件一条 printf"
#    展开，libavutil 有 60+ 个头文件，导致 install-libavutil-headers 的
#    recipe 命令超长，Windows Git Bash 的 sh 解析时被截断，报：
#      /usr/bin/sh: -c: line 1: unexpected EOF while looking for matching `"'
#    这里改回旧式"每目标打印一次 + 直接 install"，命令长度与旧版一致。
#    （该宏被 Makefile / fftools / doc / library.mak 全树共用，改一处即全部生效）
commonmak = src / "ffbuild" / "common.mak"
s = commonmak.read_text(encoding="utf-8")
s = re.sub(
    r"^INSTALL_FILES = @\$\(foreach F,\$\(2\),printf .*$",
    'INSTALL_FILES = @$(call ECHO,INSTALL,$(2:$(SRC_PATH)/%=%)); $(INSTALL) $(1) $(2) "$(3)"',
    s,
    flags=re.M,
)
commonmak.write_text(s, encoding="utf-8")

print("Patched configure, ffbuild/library.mak and ffbuild/common.mak")
