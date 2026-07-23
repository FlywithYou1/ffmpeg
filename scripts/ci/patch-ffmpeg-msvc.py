#!/usr/bin/env python3
"""为 Windows MSVC 构建修补 FFmpeg 源码"""
import pathlib
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

print("Patched configure and ffbuild/library.mak")
