#!/usr/bin/env bash
# Shared ownership and temporary-directory rules for local builds.
init_build_env() {
  local script_path="$1" marker expected actual
  ORIG_DIR="$(pwd -P)"
  REPO_ROOT="$(cd "$(dirname "$script_path")" && pwd -P)"
  [ -d "$REPO_ROOT/scripts" ] || REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd -P)"
  P="${INSTALL_PREFIX:-${HOME}/ffmpeg-install}"
  if command -v cygpath >/dev/null 2>&1; then
    P="$(cygpath -u "$P")"
  fi
  case "$P" in
    /*) ;;
    *) P="$ORIG_DIR/$P" ;;
  esac
  [ ! -L "$P" ] || { echo "错误：安装目录不能是符号链接: $P" >&2; return 1; }
  case "$P" in
    /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/System|/System/*|/Library|/Library/*|/c/Windows|/c/Windows/*|/c/Program\ Files|/c/Program\ Files/*)
      echo "错误：不能使用系统目录作为安装目录: $P" >&2; return 1 ;;
  esac
  case "$(printf '%s' "$P" | tr '[:upper:]' '[:lower:]')" in
    /[a-z]|/[a-z]/windows|/[a-z]/windows/*|/[a-z]/program\ files|/[a-z]/program\ files/*|/[a-z]/program\ files\ \(x86\)|/[a-z]/program\ files\ \(x86\)/*)
      echo "错误：不能使用 Windows 系统目录作为安装目录: $P" >&2; return 1 ;;
  esac
  mkdir -p "$P"
  P="$(cd "$P" && pwd -P)"
  case "$P" in
    "$REPO_ROOT"|"$REPO_ROOT/scripts"|"$REPO_ROOT/scripts/"*|"$REPO_ROOT/.git"|"$REPO_ROOT/.git/"*)
      echo "错误：安装目录不能覆盖源码: $P" >&2; return 1 ;;
  esac
  case "$P" in
    /|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/System|/System/*|/Library|/Library/*|/opt|/tmp|/var|/home|/c|/d|/c/Windows|/c/Windows/*|/c/Program\ Files|/c/Program\ Files/*|/c/Program\ Files\ \(x86\)|/c/Program\ Files\ \(x86\)/*)
      echo "错误：不能使用系统目录作为安装目录: $P" >&2; return 1 ;;
  esac
  [ "$P" != "$(cd "$HOME" && pwd -P)" ] && [ "$P" != "$REPO_ROOT" ] && [ "$P" != "$ORIG_DIR" ] || {
    echo "错误：不能使用用户目录或项目目录作为安装目录: $P" >&2; return 1;
  }
  marker="$P/.ffmpeg-build-owner"
  expected="ffmpeg-multi-vendor:$REPO_ROOT"
  if [ -e "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    actual="$(cat "$marker")"
    [ "$actual" = "$expected" ] || { echo "错误：安装目录属于其他构建: $P" >&2; return 1; }
  elif [ -n "$(find "$P" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "错误：拒绝覆盖未标记的非空目录: $P。请使用新的 INSTALL_PREFIX。" >&2
    return 1
  else
    printf '%s\n' "$expected" > "$marker"
  fi
  # Never recursively remove the prefix: it may contain files added by the user.
  mkdir -p "$P/bin" "$P/lib/pkgconfig" "$P/include"
  BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-build.XXXXXXXX")"
  printf '%s\n' "$expected" > "$BUILD_ROOT/.ffmpeg-build-temp"
  export REPO_ROOT P BUILD_ROOT
  trap cleanup_build_env EXIT
  if ! mkdir "$P/.ffmpeg-build-lock" 2>/dev/null; then
    echo "错误：安装目录已有构建正在使用: $P" >&2
    return 1
  fi
  printf '%s\n' "$BUILD_ROOT" > "$P/.ffmpeg-build-lock/owner"
}

cleanup_build_env() {
  local status=$?
  trap - EXIT
  cd "${ORIG_DIR:-/}" || true
  if [ -n "${P:-}" ] && [ -f "$P/.ffmpeg-build-lock/owner" ] &&
     [ "$(cat "$P/.ffmpeg-build-lock/owner")" = "${BUILD_ROOT:-}" ]; then
    rm -f -- "$P/.ffmpeg-build-lock/owner"
    rmdir -- "$P/.ffmpeg-build-lock" || true
  fi
  if [ -n "${BUILD_ROOT:-}" ] && [ -d "$BUILD_ROOT" ] && [ ! -L "$BUILD_ROOT" ] &&
     [ -f "$BUILD_ROOT/.ffmpeg-build-temp" ] &&
     [ "$(cat "$BUILD_ROOT/.ffmpeg-build-temp")" = "ffmpeg-multi-vendor:$REPO_ROOT" ]; then
    rm -rf -- "$BUILD_ROOT"
  fi
  return "$status"
}
