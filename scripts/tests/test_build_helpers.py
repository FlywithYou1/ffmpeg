import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('bash'), 'Bash unavailable')
class BuildOwnershipTests(unittest.TestCase):
    def shell(self, body):
        # Feed the file as bytes so PowerShell/Windows CRLF never reaches Bash.
        source = (ROOT / 'scripts/build-env.sh').read_text().replace('\r\n', '\n')
        script = source + '\nset -Eeuo pipefail\n' + body
        return subprocess.run(['bash'], input=script.encode(), capture_output=True)

    def test_rejects_unowned_directory_without_removing_files(self):
        result = self.shell('''
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/prefix"
printf important > "$fixture/prefix/user-file"
INSTALL_PREFIX="$fixture/prefix"
if init_build_env "$PWD/scripts/build-linux-amd.sh"; then exit 99; fi
[ "$(cat "$fixture/prefix/user-file")" = important ]
''')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn('非空目录'.encode(), result.stderr)

    def test_temp_cleanup_preserves_managed_prefix(self):
        result = self.shell('''
fixture=$(mktemp -d)
INSTALL_PREFIX="$fixture/prefix"
init_build_env "$PWD/scripts/build-linux-amd.sh"
work=$BUILD_ROOT
[ -d "$work" ]
printf important > "$P/user-file"
cleanup_build_env
[ ! -e "$work" ]
[ "$(cat "$P/user-file")" = important ]
[ ! -e "$P/.ffmpeg-build-lock" ]
rm -rf "$fixture"
''')
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_second_build_cannot_unlock_first_build(self):
        result = self.shell('''
fixture=$(mktemp -d)
INSTALL_PREFIX="$fixture/prefix"
init_build_env "$PWD/scripts/build-linux-amd.sh"
first_work=$BUILD_ROOT
first_owner=$(cat "$P/.ffmpeg-build-lock/owner")
if (init_build_env "$PWD/scripts/build-linux-amd.sh"); then exit 99; fi
[ "$(cat "$P/.ffmpeg-build-lock/owner")" = "$first_owner" ]
BUILD_ROOT=$first_work
cleanup_build_env
rm -rf "$fixture"
''')
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_rejects_home_prefix(self):
        result = self.shell('INSTALL_PREFIX=$HOME\nif init_build_env "$PWD/scripts/build-linux-amd.sh"; then exit 99; fi\n')
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_rejects_system_prefixes(self):
        result = self.shell('''
for directory in / /usr /usr/local /tmp; do
  INSTALL_PREFIX=$directory
  if init_build_env "$PWD/scripts/build-linux-amd.sh"; then exit 99; fi
done
''')
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_managed_prefix_is_reusable(self):
        result = self.shell('''
fixture=$(mktemp -d)
INSTALL_PREFIX="$fixture/prefix"
init_build_env "$PWD/scripts/build-linux-amd.sh"
first_work=$BUILD_ROOT
cleanup_build_env
INSTALL_PREFIX=$P
init_build_env "$PWD/scripts/build-linux-amd.sh"
[ "$first_work" != "$BUILD_ROOT" ]
cleanup_build_env
rm -rf "$fixture"
''')
        self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
