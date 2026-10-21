#!/usr/bin/env python3
"""Prefer available Linux archives without forcing drivers/libc to be static."""
import os
from pathlib import Path
import shlex
import subprocess
import sys


def prefer_archives(flags, search_dirs):
    dirs = [Path(p) for p in search_dirs]
    dirs = [Path(flag[2:]) for flag in flags if flag.startswith('-L')] + dirs
    result = []
    for flag in flags:
        # libc, dynamic loaders and GPU drivers remain system runtime components.
        if flag.startswith('-l') and flag[2:] not in {'c', 'm', 'dl', 'pthread', 'rt', 'cuda', 'nvidia-encode', 'nvidia-opticalflow'}:
            name = flag[2:]
            archive = next((p / f'lib{name}.a' for p in dirs if (p / f'lib{name}.a').is_file()), None)
            result.append(str(archive) if archive else flag)
        else:
            result.append(flag)
    return result


def main(argv):
    real = os.environ.get('FFMPEG_PKG_CONFIG', 'pkg-config')
    completed = subprocess.run([real, *argv], capture_output=True, text=True)
    if completed.returncode:
        sys.stderr.write(completed.stderr)
        return completed.returncode
    if '--libs' in argv and '--static' in argv:
        flags = shlex.split(completed.stdout)
        cc = shlex.split(os.environ.get('CC', 'cc'))
        query = subprocess.run([*cc, '-print-search-dirs'], capture_output=True, text=True, check=True)
        dirs = []
        for line in query.stdout.splitlines():
            if line.startswith('libraries: ='):
                dirs.extend(line.split('=', 1)[1].split(os.pathsep))
        sys.stdout.write(' '.join(prefer_archives(flags, dirs)) + '\n')
    else:
        sys.stdout.write(completed.stdout)
    sys.stderr.write(completed.stderr)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
