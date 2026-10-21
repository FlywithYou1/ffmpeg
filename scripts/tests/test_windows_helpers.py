#!/usr/bin/env python3
"""Focused Windows helper tests; fixtures stay in the repository, never system temp."""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import unittest
import uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
CI = REPO / 'scripts' / 'ci'
spec = importlib.util.spec_from_file_location("vmaf_windows", CI / "prepare-vmaf-windows.py")
vmaf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vmaf)


class FixtureTest(unittest.TestCase):
    def setUp(self):
        self.root = CI / (".windows-test-" + uuid.uuid4().hex)
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)

    def put(self, name, text=""):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_helper(self, script, *arguments, success=True):
        command = [shutil.which("pwsh") or "powershell", "-NoProfile", "-NonInteractive", "-File", str(CI / script), *map(str, arguments)]
        env = os.environ.copy()
        env.pop("GITHUB_ENV", None)
        env.pop("GITHUB_PATH", None)
        result = subprocess.run(command, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result


class FFmpegPatchTests(FixtureTest):
    def test_shared_patch_idempotency_and_exact_tokens(self):
        configure = self.put("ffmpeg/configure", r'gsub(/\\/, "/")' + '\n' +
            'require libsnappy snappy-c.h snappy_compress -lsnappy -lstdc++\n' +
            'require libtwolame twolame.h twolame_init -ltwolame\n' +
            'check_lib libtwolame twolame.h twolame_encode_buffer_float32_interleaved -ltwolame\n' +
            'check_lib math math.h sin -lm -lmfplat -lmfuuid\n')
        library = self.put("ffmpeg/ffbuild/library.mak", 'ifeq ($(RESPONSE_FILES),yes)\n\t$(Q)echo $^ > $@.objs\n\t$(AR) $(ARFLAGS) $(AR_O) @$@.objs\nelse\nendif\n')
        common = self.put("ffmpeg/ffbuild/common.mak", 'INSTALL_FILES = @$(foreach F,$(2),printf "INSTALL %s" $(F)); $(INSTALL) $(1) $(2) "$(3)"\n')
        command = [os.sys.executable, str(CI / "patch-ffmpeg-msvc.py"), str(configure.parent)]
        subprocess.run(command, check=True, capture_output=True)
        files = [configure, library, common]
        first = [p.read_bytes() for p in files]
        subprocess.run(command, check=True, capture_output=True)
        self.assertEqual(first, [p.read_bytes() for p in files])
        text = configure.read_text()
        self.assertNotIn('-lstdc++', text)
        self.assertNotIn(' -lm ', text)
        self.assertIn('-lmfplat -lmfuuid', text)
        self.assertEqual(text.count('-DLIBTWOLAME_STATIC'), 2)
        self.assertIn('$(file > $@.objs', library.read_text())
        self.assertIn('$(call ECHO,INSTALL', common.read_text())


class VmafPatchTests(FixtureTest):
    def test_private_shims_and_idempotent_cuda(self):
        source = self.root / 'libvmaf'
        compat = self.root / 'private headers'
        self.put('libvmaf/src/predict.c', '#ifdef HAVE_ALLOCA_H\n#include <alloca.h>\n#endif\ndouble scores[model_collection->cnt];\nchar name[name_sz];\n')
        self.put('libvmaf/src/feature/integer_vif.c', 'data += n;\n')
        self.put('libvmaf/src/feature/integer_vif.h', '#ifdef _MSC_VER\n#define clz(x) __lzcnt(x)\n#endif\n')
        self.put('libvmaf/src/feature/integer_adm.h', 'const double values[] = { .a = 1, .b = 2 };\n')
        self.put('libvmaf/src/feature/mkdirp.c', '#include <unistd.h>\n#include <sys/types.h>\nint rc = mkdir(pathname);\n')
        self.put('libvmaf/src/meson.build', "command: ['-I', '../src/' + cuda_dir,]\n")
        vmaf.prepare(source, compat, 'x64', True, ['C:/dependency/include'])
        paths = [p for p in source.rglob('*') if p.is_file()]
        first = {p: p.read_bytes() for p in paths}
        vmaf.prepare(source, compat, 'x64', True, ['C:/dependency/include'])
        self.assertEqual(first, {p: p.read_bytes() for p in paths})
        self.assertFalse((source / 'include/pthread.h').exists())
        self.assertFalse((compat / 'getopt.h').exists())
        self.assertIn('_beginthreadex', (compat / 'pthread_shim.c').read_text())
        self.assertNotIn('LPTHREAD_START_ROUTINE', (compat / 'pthread_shim.c').read_text())
        self.assertIn('void *result', (compat / 'pthread_shim.c').read_text())
        self.assertIn('_alloca(name_sz)', (source / 'src/predict.c').read_text())
        self.assertNotIn('malloc(', (source / 'src/predict.c').read_text())
        self.assertIn('&& HAVE_ALLOCA_H', (source / 'src/predict.c').read_text())
        self.assertIn('unsigned char *)data', (source / 'src/feature/integer_vif.c').read_text())
        self.assertIn('ALIGN(n)', (source / 'src/compat/msvc/common/attributes.h').read_text())
        self.assertIn('usleep(', (compat / 'unistd.h').read_text())
        self.assertIn('#include <unistd.h>', (source / 'src/feature/mkdirp.c').read_text())

    def test_arm_neon_and_real_intrinsics(self):
        source = self.root / 'libvmaf'
        self.put('libvmaf/src/feature/integer_vif.h', '#define __builtin_clz(x) __lzcnt(x)\n#define __builtin_clzll(x) __lzcnt64(x)\n__lzcnt64(y);\n')
        self.put('libvmaf/src/feature/integer_adm.c', '__builtin_clz(value);\n')
        self.put('libvmaf/src/feature/arm64/adm_neon.c', 'const int32x4_t lanes = { 0, 1, 2, 3 };\n')
        vmaf.prepare(source, self.root / 'compat', 'arm64')
        self.assertIn('_CountLeadingZeros64(y)', (source / 'src/feature/integer_vif.h').read_text())
        self.assertNotIn('#define _CountLeadingZeros(', (source / 'src/feature/integer_vif.h').read_text())
        self.assertIn('#include <intrin.h>', (source / 'src/feature/integer_adm.c').read_text())
        self.assertIn('vld1q_s32(lane_values)', (source / 'src/feature/arm64/adm_neon.c').read_text())


@unittest.skipUnless(shutil.which('pwsh') or shutil.which('powershell'), 'PowerShell unavailable')
class PowerShellHelperTests(FixtureTest):
    def fixture_install(self, arch='x64'):
        prefix = self.root / (arch + '-windows-static')
        self.put(f'{prefix.name}/lib/pkgconfig/libjxl.pc', 'Name: libjxl\nVersion: 0.11.1\nRequires.private: libhwy libbrotlidec\nLibs: -ljxl-static\nCflags: -DJXL_STATIC_DEFINE -fkeep-this\n')
        self.put(f'{prefix.name}/lib/pkgconfig/libjxl_threads.pc', 'Version: 0.11.1\nLibs: -ljxl_threads-static\n')
        self.put(f'{prefix.name}/tools/pkgconf/pkgconf.exe')
        self.put(f'{prefix.name}/lib/jxl.lib')
        self.put(f'{prefix.name}/lib/jxl_threads.lib')
        return prefix

    def test_preserves_upstream_and_removes_only_exact_msvc_tokens(self):
        prefix = self.fixture_install('arm64')
        pc = self.put(f'{prefix.name}/lib/pkgconfig/vpl.pc', 'Name: vpl\nVersion: 2.17.0\nLibs: -lvpl -lmfplat -lmfuuid\nCflags: -DVPL_STATIC -keep\n')
        svt = self.put(f'{prefix.name}/lib/pkgconfig/SvtAv1Enc.pc', 'Name: SVT\nVersion: 3.1.2\nRequires.private: retained\nLibs.private: -lm -lmfplat -lother\nCflags.private: -UEB_DLL -DKEEP -UOTHER\n')
        jxl = prefix / 'lib/pkgconfig/libjxl.pc'
        original = jxl.read_bytes(), pc.read_bytes()
        host = 'arm64' if os.environ.get('PROCESSOR_ARCHITECTURE') == 'ARM64' else 'x64'
        self.put(f'{host}-windows/tools/pkgconf/pkgconf.exe')
        self.put(f'{host}-windows/tools/shaderc/glslc.exe')
        path_export = self.root / 'host-path'
        self.run_helper('write-fallback-pc.ps1', '-InstallRoot', prefix, '-HasVpl', '-GithubPath', path_export)
        self.assertIn(f'{host}-windows', path_export.read_text())
        self.assertIn('shaderc', path_export.read_text())
        self.assertEqual(original, (jxl.read_bytes(), pc.read_bytes()))
        self.assertTrue((prefix / 'lib/jxl-static.lib').is_file())
        self.assertTrue((prefix / 'lib/jxl_threads-static.lib').is_file())
        text = svt.read_text()
        self.assertIn('Requires.private: retained', text)
        self.assertIn('-lmfplat -lother', text)
        self.assertIn('-DKEEP -UOTHER', text)
        self.assertNotIn('-UEB_DLL', text)
        self.assertNotIn(' -lm ', text)

    def test_fallback_names_versions_lib_search_path_and_optional_exports(self):
        prefix = self.fixture_install()
        for port, lib, version in [('x264', 'x264', '0.164'), ('x265', 'x265', '4.1'), ('libvpx', 'vpx', '1.15.0'), ('aom', 'aom', '3.12.1'), ('dav1d', 'dav1d', '1.5.1')]:
            self.put(f'{prefix.name}/lib/{lib}.lib')
            self.put(f'{prefix.name}/share/{port}/vcpkg.json', json.dumps({'version-semver': version}))
        env, path = self.root / 'github-env', self.root / 'github-path'
        self.run_helper('write-fallback-pc.ps1', '-InstallRoot', prefix, '-GithubEnv', env, '-GithubPath', path)
        for name, version in [('x264', '0.164'), ('x265', '4.1'), ('vpx', '1.15.0'), ('aom', '3.12.1'), ('dav1d', '1.5.1')]:
            text = (prefix / f'lib/pkgconfig/{name}.pc').read_text()
            self.assertIn('Version: ' + version, text)
            self.assertIn('Libs: -L${libdir}', text)
        self.assertFalse((prefix / 'lib/pkgconfig/libx264.pc').exists())
        self.assertNotIn('arm64', env.read_text())
        self.assertIn('PKG_CONFIG_DIR=', env.read_text())
        self.assertIn('pkgconf', path.read_text())

    def test_missing_version_fails_instead_of_inventing_minimum(self):
        prefix = self.fixture_install()
        self.put(f'{prefix.name}/lib/aom.lib')
        result = self.run_helper('write-fallback-pc.ps1', '-InstallRoot', prefix, success=False)
        self.assertIn('Cannot determine installed aom version', result.stderr)
        self.assertFalse((prefix / 'lib/pkgconfig/aom.pc').exists())

    def test_zimg_shared_builder_with_mock_native_tools(self):
        driver = self.put('zimg-driver.ps1', r'''$ErrorActionPreference='Stop'
$env:VSCMD_ARG_TGT_ARCH='arm64'
$env:VSCMD_VER='18.1.0'
$env:PlatformToolset=''
function global:git {
    $source=$args[-1]
    New-Item -ItemType Directory -Path "$source\_msvc\ARM64\Release", "$source\src\zimg\api" -Force | Out-Null
    Set-Content -LiteralPath "$source\configure.ac" -Value 'AC_INIT([zimg], [3.0.8])'
    Set-Content -LiteralPath "$source\_msvc\zimg.sln" -Value 'fixture'
    Set-Content -LiteralPath "$source\src\zimg\api\zimg.h" -Value 'fixture header'
    Set-Content -LiteralPath "$source\COPYING" -Value 'fixture license'
    $global:LASTEXITCODE=0
}
function global:msbuild {
    if ($args -notcontains '/p:Platform=ARM64') { throw 'Wrong architecture' }
    if ($args -notcontains '/p:PlatformToolset=v145') { throw 'Wrong toolset' }
    $source=Split-Path (Split-Path $args[0])
    $props=Get-Content -LiteralPath "$source\_msvc\Directory.Build.props" -Raw
    if ($props -notmatch '<RuntimeLibrary>MultiThreaded</RuntimeLibrary>') { throw 'Not /MT' }
    Set-Content -LiteralPath "$source\_msvc\ARM64\Release\z.lib" -Value 'fixture static zimg'
    $global:LASTEXITCODE=0
}
$original=(Get-Location).Path
& $args[0] -InstallRoot $args[1] -BuildRoot $args[2] -Architecture arm64
if ((Get-Location).Path -ne $original) { throw 'Builder changed cwd' }
''')
        prefix = self.root / 'installed'
        result = subprocess.run([shutil.which('pwsh') or 'powershell', '-NoProfile', '-File', str(driver), str(CI / 'build-zimg-windows.ps1'), str(prefix), str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((prefix / 'lib/zimg.lib').read_text().strip(), 'fixture static zimg')
        self.assertFalse((prefix / 'lib/z.lib').exists())
        self.assertIn('Version: 3.0.8', (prefix / 'lib/pkgconfig/zimg.pc').read_text())
        self.assertTrue((prefix / 'share/zimg/copyright').is_file())

    def test_syntax_and_zimg_target_refusal(self):
        script = self.put('parse.ps1', '''$ErrorActionPreference='Stop'
foreach ($p in $args) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
''')
        result = subprocess.run([shutil.which('pwsh') or 'powershell', '-NoProfile', '-File', str(script), str(CI / 'write-fallback-pc.ps1'), str(CI / 'build-zimg-windows.ps1')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_helper('build-zimg-windows.ps1', '-InstallRoot', self.root / 'prefix', '-BuildRoot', self.root, '-Architecture', 'arm64', success=False)
        self.assertIn('matching x64 or arm64', result.stderr)
        self.assertFalse((self.root / 'zimg-src').exists())


class WindowsCleanupTests(FixtureTest):
    def test_cleanup_unlocks_once_and_preserves_failure_status(self):
        git_bash = pathlib.Path(os.environ.get('ProgramFiles', 'C:\\Program Files')) / 'Git' / 'bin' / 'bash.exe'
        bash = str(git_bash) if git_bash.is_file() else shutil.which('bash')
        if not bash:
            self.skipTest('Bash unavailable')
        script = self.put('cleanup-test.sh', r'''#!/usr/bin/env bash
set -Eeuo pipefail
engine="$WINDOWS_ENGINE"
environment="$BUILD_ENV_SCRIPT"
if command -v cygpath >/dev/null; then
  engine="$(cygpath -u "$engine")"
  environment="$(cygpath -u "$environment")"
fi
source "$environment"
source "$engine"
REPO_ROOT="$PWD"
P="$PWD/prefix"
BUILD_ROOT="$PWD/build"
ORIG_DIR="$PWD/original"
CALLS="$PWD/cleanup-calls"
mkdir -p "$P/.ffmpeg-build-lock" "$BUILD_ROOT/junction" "$ORIG_DIR"
printf '%s\n' "$BUILD_ROOT" > "$P/.ffmpeg-build-lock/owner"
printf 'ffmpeg-multi-vendor:%s\n' "$REPO_ROOT" > "$BUILD_ROOT/.ffmpeg-build-temp"
eval "$(declare -f cleanup_build_env | sed '1s/cleanup_build_env/actual_cleanup_build_env/')"
cleanup_build_env() {
  printf 'called\n' >> "$CALLS"
  actual_cleanup_build_env
}
cygpath() { printf '%s\n' "${@: -1}"; }
cmd.exe() {
  if [ "$DETACH_FAIL" = 1 ]; then return 1; fi
  rmdir "$BUILD_ROOT/junction"
}
WINDOWS_JUNCTIONS=("$BUILD_ROOT/junction")
trap 'exit 93' ERR
trap windows_cleanup EXIT
exit "$REQUESTED_STATUS"
''')
        for status, detach_failure in ((0, 0), (7, 0), (0, 1), (7, 1)):
            with self.subTest(status=status, detach_failure=detach_failure):
                case = self.root / f'case-{status}-{detach_failure}'
                case.mkdir()
                env = os.environ.copy()
                env.update(WINDOWS_ENGINE=str(CI.parent / 'build-windows-common.sh'), BUILD_ENV_SCRIPT=str(CI.parent / 'build-env.sh'), REQUESTED_STATUS=str(status), DETACH_FAIL=str(detach_failure))
                # Bash accepts the fixture's native script argument under Git for Windows.
                result = subprocess.run([bash, str(script)], cwd=case, env=env, capture_output=True, text=True)
                expected = status or detach_failure
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertFalse((case / 'prefix/.ffmpeg-build-lock').exists())
                self.assertEqual((case / 'cleanup-calls').read_text(), 'called\n')
                self.assertEqual((case / 'build').exists(), bool(detach_failure))
                if detach_failure:
                    self.assertTrue((case / 'build/junction').is_dir())
                    self.assertFalse((case / 'build/.ffmpeg-build-temp').exists())


class ShellContractTests(unittest.TestCase):
    def test_wrappers_and_static_engine_contract(self):
        for flavor in ('nvidia', 'intel-qsv', 'amd-amf', 'arm64'):
            wrapper = CI.parent / f'build-windows-{flavor}.sh'
            self.assertNotIn(b'\r', wrapper.read_bytes())
            text = wrapper.read_text()
            self.assertIn('init_build_env "$0"', text)
            self.assertIn('windows_build ' + flavor, text)
            self.assertLess(len(text.splitlines()), 12)
        text = (CI.parent / 'build-windows-common.sh').read_text()
        self.assertNotIn('/tmp', text)
        self.assertNotIn('rm -rf', text)
        self.assertIn('WINDOWS_LICENSE_FLAGS=(--enable-nonfree)', text)
        self.assertIn('WINDOWS_PACKAGE_FLAGS=(--local-only)', text)
        self.assertIn('if [ "$WINDOWS_POLICY" = local ]; then', text)
        self.assertIn('HARDWARE_FLAGS=(--enable-ffnvcodec --enable-cuda-nvcc', text)
        self.assertNotIn('--enable-libnpp', text)
        self.assertIn('--disable-cuda-nvcc --enable-cuda-llvm', text)
        self.assertIn('target=_M_ARM64', text)
        self.assertIn('-Db_vscrt=mt', text)
        self.assertIn('cl.exe -nologo -MT -c', text)
        self.assertIn('gas-preprocessor.pl -arch aarch64 -as-type armasm', text)
        self.assertIn('--enable-libjxl', text)
        self.assertIn('--directory "$output"', text)
        self.assertIn('"$BUILD_ROOT/vmaf-compat"; do', text)


if __name__ == '__main__':
    unittest.main()
