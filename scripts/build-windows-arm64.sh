#!/usr/bin/env bash
# Windows arm64: initialize owned paths before loading the shared /MT engine.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/build-env.sh"
init_build_env "$0"
source "$REPO_ROOT/scripts/build-windows-common.sh"
windows_build arm64
