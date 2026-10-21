#!/usr/bin/env bash
# Run as a child process so failures never exit or reconfigure an interactive shell.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "请使用 bash ffmpeg-archlinux-nvidia.sh，不要 source。" >&2
  return 1
fi
set -Eeuo pipefail
export CC=gcc CXX=g++ FFMPEG_ARCH_BUILD=1
source "$(dirname "${BASH_SOURCE[0]}")/scripts/build-linux-common.sh"
build_linux nvidia
