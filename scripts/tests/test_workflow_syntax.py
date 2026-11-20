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
            'ffmpeg-linux-arm.tar.xz', 'ffmpeg-linux-arm-av2.tar.xz', 'ffmpeg-linux-arm-nvidia.tar.xz',
            'ffmpeg-linux-x86-all.tar.xz', 'ffmpeg-linux-x86-all-av2.tar.xz',
            'ffmpeg-windows-nvidia.zip', 'ffmpeg-windows-intel-qsv.zip', 'ffmpeg-windows-amd-amf.zip',
            'ffmpeg-windows-arm64.zip', 'ffmpeg-windows-arm64-av2.zip', 'ffmpeg-windows-arm64-nvidia.zip',
            'ffmpeg-windows-arm64-nvidia-av2.zip', 'ffmpeg-windows-x86-all.zip',
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
        self.assertIn('--enable-cuda-nvcc', windows)
        self.assertNotIn('--enable-cuda-llvm', windows)

    def test_avm_follows_the_branch_head(self):
        for name in ('build-avm.sh', 'build-avm-windows.ps1'):
            script = (ROOT / 'scripts/ci' / name).read_text()
            self.assertIn('--branch av2-enc', script)
            self.assertNotRegex(script, r'\b224c347d')
        self.assertFalse((ROOT / 'scripts/ci/avm-ref.txt').exists())

    def test_pwsh_blocks_avoid_readonly_variables(self):
        # $HOME/$Host/$Error etc. are read-only in PowerShell; assigning them
        # fails at runtime, which a syntax check cannot catch.
        text = (ROOT / '.github/workflows/build-ffmpeg.yml').read_text()
        reserved = ('home', 'host', 'error', 'input', 'args', 'this', 'true', 'false', 'null', 'pid')
        for line, shell, source in SYNTAX.workflow_blocks(text):
            if shell != 'pwsh':
                continue
            for match in re.finditer(r'(?m)^\s*\$(\w+)\s*=', source):
                self.assertNotIn(match.group(1).lower(), reserved,
                                 f'workflow:{line} assigns read-only ${match.group(1)}')

    def test_hardware_expectations_match_each_artifact(self):
        text = (ROOT / '.github/workflows/build-ffmpeg.yml').read_text()
        rows = dict(re.findall(r'(?m)^\s+- id: (\S+)\n(.*?)(?=^\s+- id: |^    steps:)', text, re.S))
        self.assertIn('--require-hwaccel cuda', rows['nvidia'])
        self.assertIn('--require-hwaccel vaapi', rows['arm'])
        self.assertIn('--require-hwaccel d3d11va', rows['arm64'])
        self.assertIn('--require-hwaccel videotoolbox', text)
        self.assertNotRegex(text, r"verify_args: ''")


if __name__ == '__main__':
    unittest.main()
