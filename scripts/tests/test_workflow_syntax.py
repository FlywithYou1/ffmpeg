import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('check_syntax', ROOT / 'scripts/ci/check-syntax.py')
SYNTAX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNTAX)


class WorkflowSyntaxTests(unittest.TestCase):
    def test_extracts_shell_and_indentation(self):
        text = '''jobs:
  build:
    steps:
      - name: Bash
        run: |
          echo "${{ matrix.name }}"
          if true; then
            echo yes
          fi
      - name: PowerShell
        shell: pwsh
        run: |
          $value = '${{ github.ref }}'
          Write-Host $value
'''
        blocks = list(SYNTAX.workflow_blocks(text))
        self.assertEqual(len(blocks), 2)
        self.assertEqual(blocks[0][1], 'bash')
        self.assertIn('  echo yes', blocks[0][2])
        self.assertNotIn('${{', blocks[0][2])
        self.assertEqual(blocks[1][1], 'pwsh')
        self.assertEqual(blocks[1][2].splitlines()[0], "$value = 'workflow_value'")

    def test_required_release_artifacts_are_preserved(self):
        text = (ROOT / '.github/workflows/build-ffmpeg.yml').read_text()
        artifacts = set(re.findall(r'^\s*(?:av2_)?artifact: (ffmpeg-\S+)$', text, re.M))
        expected = {
            'ffmpeg-linux-nvidia.tar.xz', 'ffmpeg-linux-intel-qsv.tar.xz', 'ffmpeg-linux-amd.tar.xz',
            'ffmpeg-linux-arm.tar.xz', 'ffmpeg-linux-x86-all.tar.xz', 'ffmpeg-linux-x86-all-av2.tar.xz',
            'ffmpeg-windows-nvidia.zip', 'ffmpeg-windows-intel-qsv.zip', 'ffmpeg-windows-amd-amf.zip',
            'ffmpeg-windows-arm64.zip', 'ffmpeg-windows-arm64-av2.zip', 'ffmpeg-windows-x86-all.zip',
            'ffmpeg-windows-x86-all-av2.zip', 'ffmpeg-macos-arm.tar.xz', 'ffmpeg-macos-arm-av2.tar.xz',
        }
        self.assertEqual(artifacts, expected)
        self.assertRegex(text, r'(?m)^  release:\n    name: 创建 GitHub Release')
        self.assertNotIn('if: false', text)
        for platform in ('linux', 'windows', 'macos'):
            self.assertIn(f'collect-dependency-sources.py --platform {platform}', text)
        self.assertNotIn('sudo apt-get upgrade', text)
        self.assertNotIn('- id: x86-all-av2', text)
        self.assertNotIn('- id: arm64-av2', text)
        for job, following in (('linux', 'windows'), ('windows', 'macos-arm'), ('macos-arm', 'release')):
            section = text.split(f'\n  {job}:\n', 1)[1].split(f'\n  {following}:\n', 1)[0]
            self.assertIn('--enable-nonfree', section)
        windows = text.split('  windows:', 1)[1].split('  macos-arm:', 1)[0]
        self.assertIn('--enable-libjxl', windows)
        self.assertIn('--enable-cuda-llvm', windows)
        self.assertIn('--disable-cuda-nvcc', windows)


if __name__ == '__main__':
    unittest.main()
