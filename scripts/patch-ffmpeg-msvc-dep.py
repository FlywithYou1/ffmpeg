#!/usr/bin/env python3
r"""Patch FFmpeg's configure for MSVC dependency generation under MSYS2 make.

MSYS2 make collapses '\\' -> '\' when reading recipes. FFmpeg's configure emits
`gsub(/\\/, "/")` into ffbuild/config.mak, which make then turns into the invalid
awk regex `gsub(/\/, "/")`. We patch configure to emit four backslashes so the
final awk program sees the intended two-backslash regex.
"""
import pathlib
import sys


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("configure")
    s = path.read_text(encoding="utf-8")
    old = 'gsub(/\\\\/, "/")'
    new = 'gsub(/\\\\\\\\/, "/")'
    if old not in s:
        print("patch-ffmpeg-msvc-dep: pattern not found, nothing to do")
        return
    s = s.replace(old, new)
    path.write_text(s, encoding="utf-8")
    print("patch-ffmpeg-msvc-dep: patched MSVC dependency awk command")


if __name__ == "__main__":
    main()
