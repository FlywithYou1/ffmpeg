#!/usr/bin/env bash
set -Eeuo pipefail
[ "${GITHUB_ACTIONS:-}" = "true" ] || { echo "This script verifies AVM on GitHub Actions only."; exit 1; }
: "${AVM_PREFIX:?}" "${RUNNER_TEMP:?}"
FFMPEG="${1:?usage: verify-avm.sh <ffmpeg>}"
WORK="${RUNNER_TEMP}/avm-smoke"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=1 -frames:v 1 -pix_fmt yuv420p -f yuv4mpegpipe -y "$WORK/input.y4m"
"$AVM_PREFIX/bin/avmenc" --codec=av2 --ivf --limit=1 --cpu-used=6 --threads=2 --end-usage=q --cq-level=45 -o "$WORK/output.ivf" "$WORK/input.y4m"
"$AVM_PREFIX/bin/avmdec" --codec=av2 --limit=1 -o "$WORK/decoded.y4m" "$WORK/output.ivf"
"$FFMPEG" -hide_banner -loglevel error -i "$WORK/decoded.y4m" -frames:v 1 -f null -
