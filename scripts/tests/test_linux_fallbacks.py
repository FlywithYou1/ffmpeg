import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('bash'), 'Bash unavailable')
class LinuxFallbackTests(unittest.TestCase):
    def test_private_metadata_uses_target_architecture(self):
        helper = (ROOT / 'scripts/ci/linux-pc-fallbacks.sh').read_text()
        fixture = r'''
set -Eeuo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/system" "$work/prefix"
printf 'prefix=/system\nName: kvazaar\nVersion: @version@\nLibs: -lkvazaar -lcryptopp\nLibs.private: -lm\n' > "$work/system/kvazaar.pc"
export FAKE_PC_DIR="$work/system" MULTIARCH=aarch64-linux-gnu
pkg-config() {
  case "$1" in
    --exists) return 1 ;;
    --variable=pcfiledir) echo "$FAKE_PC_DIR" ;;
    --modversion) return 0 ;;
  esac
}
dpkg-query() { echo '1:2.5.0-ubuntu1'; }
export -f pkg-config dpkg-query
export FFMPEG_PKG_CONFIG=pkg-config
'''
        body = fixture + '\n(' + helper.replace('P="${1:?Usage: $0 <install_prefix>}"', 'P="$work/prefix"') + ')\n'
        body += r'''
grep -q 'libdir=/usr/lib/aarch64-linux-gnu' "$work/prefix/lib/pkgconfig/libopenjp2.pc"
grep -q 'libdir=/usr/lib/aarch64-linux-gnu' "$work/prefix/lib/pkgconfig/x265.pc"
grep -q 'Version: @version@' "$work/system/kvazaar.pc"
grep -q 'Version: 2.5.0' "$work/prefix/lib/pkgconfig/kvazaar.pc"
grep -q 'Libs: -lkvazaar -lcryptopp' "$work/prefix/lib/pkgconfig/kvazaar.pc"
'''
        result = subprocess.run(['bash'], input=body.encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
