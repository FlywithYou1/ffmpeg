#!/usr/bin/env python3
"""Patch FFmpeg's configure for MSYS2 make's backslash folding.

FFmpeg's MSVC dependency extraction emits an awk command containing
`gsub(/\\/, "/")`.  When MSYS2 make reads the recipe it collapses each
`\\\\` pair to `\\`, leaving an unterminated awk regex `/\\/`.

We replace the source pattern with `gsub(/\\\\/, "/")` so that after the
folding the awk interpreter still sees the intended `gsub(/\\/, "/")`.
"""

import pathlib
import sys


def patch(path: str) -> int:
    p = pathlib.Path(path)
    if not p.exists():
        print(f"ERROR: {p} not found", file=sys.stderr)
        return 1

    s = p.read_text(encoding="utf-8")

    old = r'gsub(/\\/, "/")'
    new = r'gsub(/\\\\/, "/")'

    if old not in s:
        # Already patched or file layout has changed.
        print(f"INFO: pattern not found in {p}, nothing to patch")
        return 0

    s = s.replace(old, new)
    p.write_text(s, encoding="utf-8")
    print(f"INFO: patched MSVC dependency awk regex in {p}")
    return 0


if __name__ == "__main__":
    sys.exit(patch(sys.argv[1] if len(sys.argv) > 1 else "configure"))
