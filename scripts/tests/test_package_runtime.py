"""Portable stdlib tests: python -m unittest discover -s scripts/tests -v.

All native inspection, relocation and executable commands are mocked. Scratch
files stay under this repository; no compiler, GPU or Unix runtime is needed.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import unittest
from unittest import mock
import uuid


ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / "ci" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


package = load("package_runtime_test", "package-runtime.py")
verify = load("verify_runtime_test", "verify-runtime.py")


def result(stdout="", stderr="", code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class ScratchTest(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / (".runtime-unit-" + uuid.uuid4().hex)
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)
        self.source = self.root / "ffmpeg-src"
        self.source.mkdir()
        self.write(self.source / "LICENSE.md", b"FFmpeg GPL license")
        self.write(self.source / "COPYING.GPLv3", b"GPLv3 license")
        self.write(self.source / "tracked.c", b"modified actual source bytes")
        self.bin = self.root / "prefix" / "bin"
        self.bin.mkdir(parents=True)
        self.output = self.root / "dist"

    def write(self, path, content=b"data"):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def packager(self, platform="linux", avm=None):
        extension = ".exe" if platform == "windows" else ""
        magic = b"MZ" if platform == "windows" else b"\x7fELF" if platform == "linux" else b"\xcf\xfa\xed\xfe"
        for name in ("ffmpeg", "ffprobe", "ffplay"):
            self.write(self.bin / (name + extension), magic + name.encode())
        p = package.Packager(platform, self.bin, self.output, self.source, avm)
        p.stage.mkdir()
        self.addCleanup(lambda: shutil.rmtree(p.stage) if p.stage.exists() else None)
        for src, name in p.required_inputs():
            p.executables.append((src, p.copy(src, name)))
        return p

    def owned(self):
        self.output.mkdir()
        file = self.write(self.output / "lib" / "dep.so")
        marker = {"tool": package.TOOL, "schema": 1, "id": "test-owner"}
        manifest = {"owner": "test-owner", "platform": "linux", "files": {"lib/dep.so": package.digest(file)}}
        (self.output / package.MARKER).write_text(json.dumps(marker))
        (self.output / package.MANIFEST).write_text(json.dumps(manifest))
        return manifest


class OutputSafetyTests(ScratchTest):
    def test_reject_root_cwd_input_and_parent(self):
        for path, protected in [(Path(self.root.anchor), []), (ROOT, []), (self.source, [self.source]), (self.root, [self.source]), (self.source / "dist", [self.source])]:
            with self.subTest(path=path), self.assertRaises(package.PackageError):
                package.validate_output(path, protected)

    def test_nonempty_unowned_directory_is_not_deleted(self):
        self.write(self.output / "keep.txt", b"user data")
        with self.assertRaises(package.PackageError):
            package.validate_output(self.output)
        self.assertEqual((self.output / "keep.txt").read_bytes(), b"user data")

    def test_owned_can_refresh_even_after_relocation(self):
        manifest = self.owned()
        moved = self.root / "moved"
        self.output.rename(moved)
        _, found = package.validate_output(moved)
        self.assertEqual(found, manifest)
        package.remove_owned(moved, found)
        self.assertFalse(moved.exists())

    def test_modified_file_extra_file_extra_directory_and_mismatch_fail(self):
        for kind in ("modified", "extra-file", "extra-dir", "owner"):
            with self.subTest(kind=kind):
                if self.output.exists():
                    shutil.rmtree(self.output)
                self.owned()
                if kind == "modified":
                    (self.output / "lib" / "dep.so").write_bytes(b"changed")
                elif kind == "extra-file":
                    self.write(self.output / "mine.txt")
                elif kind == "extra-dir":
                    (self.output / "mine").mkdir()
                else:
                    (self.output / package.MARKER).write_text(json.dumps({"tool": package.TOOL, "schema": 1, "id": "different"}))
                with self.assertRaises(package.PackageError):
                    package.validate_output(self.output)

    def test_manifest_traversal_rejected(self):
        for value in ("../keep", "/absolute", "C:/keep", "lib\\keep", "a/../b", "a//b"):
            with self.subTest(value=value), self.assertRaises(package.PackageError):
                package.safe_relative(value)

    def test_name_collision_different_bytes_and_case(self):
        p = self.packager()
        one = self.write(self.root / "one.so", b"one")
        two = self.write(self.root / "two.so", b"two")
        p.copy(one, "lib/dep.so")
        p.copy(one, "lib/dep.so")
        with self.assertRaises(package.PackageError):
            p.copy(two, "lib/DEP.so")

    def test_missing_required_binary_and_avm_licenses(self):
        p = self.packager()
        (self.bin / "ffplay").unlink()
        with self.assertRaisesRegex(package.PackageError, "Missing required binary"):
            p.required_inputs()
        prefix = self.root / "avm-prefix"
        for name in ("avmenc", "avmdec"):
            self.write(prefix / "bin" / name)
        with self.assertRaisesRegex(package.PackageError, "AVM license"):
            self.packager(avm=prefix)

    def test_successful_package_sources_and_safe_refresh(self):
        p = self.packager()
        shutil.rmtree(p.stage)
        def command(args, **kwargs):
            if "-L" in args:
                return result("GNU General Public License version 3")
            if "-buildconf" in args:
                return result(stderr="configuration: --enable-gpl --enable-version3")
            return result("no dependencies")
        for repeat in range(2):
            p = package.Packager("linux", self.bin, self.output, self.source)
            with mock.patch.object(p, "linux_dependencies"), mock.patch.object(package.shutil, "which", return_value=None), \
                 mock.patch.object(package, "run", side_effect=command), mock.patch("builtins.print"):
                manifest = p.package()
            self.assertEqual(package.validate_output(self.output)[1], manifest)
            self.assertEqual(manifest["binaries"], ["ffmpeg", "ffprobe", "ffplay"])
            self.assertEqual(manifest["corresponding_source"]["status"], "review-required")
            self.assertTrue((self.output / "sources" / "ffmpeg.tar.gz").is_file())
            self.assertTrue((self.output / "sources" / "build-scripts.tar.gz").is_file())
            self.assertTrue((self.output / "metadata" / "ffmpeg-license-output.txt").is_file())
        self.assertFalse(p.stage.exists())

    def test_failed_package_preserves_previous_owned_output(self):
        previous = self.owned()
        p = self.packager()
        shutil.rmtree(p.stage)
        with mock.patch.object(p, "linux_dependencies", side_effect=package.PackageError("unresolved")):
            with self.assertRaises(package.PackageError):
                p.package()
        self.assertEqual(package.validate_output(self.output)[1], previous)
        self.assertFalse(p.stage.exists())


class LinuxTests(ScratchTest):
    def test_recursive_needed_rpaths_and_gpu_exclusions(self):
        p = self.packager()
        a = self.write(self.root / "deps" / "liba.so.1", b"\x7fELFa")
        b = self.write(self.root / "deps" / "libva.so.2", b"\x7fELFb")
        c = self.write(self.root / "deps" / "libstdc++.so.6", b"\x7fELFc")
        graph = {"ffmpeg": ["liba.so.1", "libcuda.so.1", "libc.so.6"], "ffprobe": ["liba.so.1"], "ffplay": [],
                 "liba.so.1": ["libva.so.2"], "libva.so.2": ["libstdc++.so.6"], "libstdc++.so.6": []}
        paths = {x.name: x for x in (a, b, c)}
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            if args[0] == "readelf":
                file = Path(args[-1])
                if args[1] == "-l":
                    return result("[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]")
                return result("\n".join(f"(NEEDED) Shared library: [{n}]" for n in graph[file.name]))
            if args[0] == "ldd":
                return result("\n".join(f" {n} => {paths[n]} (0x1234)" if n in paths else f" {n} => not found" for n in graph[Path(args[-1]).name]))
            return result()
        with mock.patch.object(package, "run", side_effect=command), mock.patch.object(p, "dpkg_attribution"):
            p.linux_dependencies()
        self.assertTrue((p.stage / "lib" / "libva.so.2").is_file())
        self.assertTrue((p.stage / "lib" / "libstdc++.so.6").is_file())
        self.assertFalse((p.stage / "lib" / "libcuda.so.1").exists())
        patches = [a for a in calls if a[0] == "patchelf"]
        self.assertIn(["patchelf", "--set-rpath", "$ORIGIN/lib", str(p.stage / "ffmpeg")], patches)
        self.assertIn(["patchelf", "--set-rpath", "$ORIGIN", str(p.stage / "lib" / "liba.so.1")], patches)
        self.assertEqual(sum(a[0] == "readelf" and a[1] == "-d" and Path(a[-1]).name == "liba.so.1" for a in calls), 1)

    def test_unresolved_dependency_is_failure(self):
        p = self.packager()
        def command(args, **kwargs):
            if args[0] == "readelf" and args[1] == "-d":
                return result("(NEEDED) Shared library: [libmissing.so.1]")
            return result("libmissing.so.1 => not found")
        with mock.patch.object(package, "run", side_effect=command), self.assertRaisesRegex(package.PackageError, "Unresolved Linux"):
            p.linux_dependencies()

    def test_unsafe_interpreter_rejected_before_ldd(self):
        p = self.packager()
        def command(args, **kwargs):
            if args[1] == "-l":
                return result("[Requesting program interpreter: /evil/loader]")
            return result("(NEEDED) Shared library: [liba.so]")
        with mock.patch.object(package, "run", side_effect=command) as runner, self.assertRaisesRegex(package.PackageError, "Unsafe ELF interpreter"):
            p.linux_dependencies()
        self.assertFalse(any(c.args[0][0] == "ldd" for c in runner.call_args_list))

    def test_avm_merge_uses_already_bundled_library(self):
        p = self.packager()
        dep = self.write(self.root / "libavm.so", b"\x7fELFdep")
        staged = p.copy(dep, "lib/libavm.so")
        with mock.patch.object(p, "elf_metadata", side_effect=lambda path: ["libavm.so"] if path.name == "ffmpeg" else []), \
             mock.patch.object(package, "run", side_effect=lambda args, **kw: result(f"libavm.so => {staged} (0x1234)") if args[0] == "ldd" else result()), \
             mock.patch.object(p, "dpkg_attribution"):
            p.linux_dependencies()
        self.assertEqual(p.copies["lib/libavm.so"][0], str(dep))


class MacTests(ScratchTest):
    def test_recursive_rpath_loader_executable_rewrite_and_sign_order(self):
        p = self.packager("macos")
        a = self.write(self.root / "external" / "liba.dylib", b"\xcf\xfa\xed\xfea")
        b = self.write(self.root / "external" / "libb.dylib", b"\xcf\xfa\xed\xfeb")
        c = self.write(self.bin / "libc.dylib", b"\xcf\xfa\xed\xfec")
        calls = []
        def metadata(path):
            if path.name == "ffmpeg":
                return ["@rpath/liba.dylib", "/usr/lib/libSystem.B.dylib"], [str(a.parent)]
            if path == a:
                return ["@loader_path/libb.dylib", "@executable_path/libc.dylib"], []
            return [], []
        with mock.patch.object(p, "mac_metadata", side_effect=metadata), mock.patch.object(p, "brew_attribution"), \
             mock.patch.object(package, "run", side_effect=lambda args, **kw: calls.append(args) or result()):
            p.macos_dependencies()
        for dep in (a, b, c):
            self.assertTrue((p.stage / "lib" / dep.name).is_file())
        self.assertIn(["install_name_tool", "-change", "@rpath/liba.dylib", "@loader_path/lib/liba.dylib", str(p.stage / "ffmpeg")], calls)
        self.assertIn(["install_name_tool", "-change", "@loader_path/libb.dylib", "@loader_path/libb.dylib", str(p.stage / "lib" / "liba.dylib")], calls)
        self.assertIn(["install_name_tool", "-delete_rpath", str(a.parent), str(p.stage / "ffmpeg")], calls)
        signed = [Path(args[-1]) for args in calls if args[0] == "codesign"]
        self.assertTrue(all(p.parent.name == "lib" for p in signed[:3]))
        self.assertEqual([p.name for p in signed[3:]], ["ffmpeg", "ffprobe", "ffplay"])
        first_sign = next(i for i, a in enumerate(calls) if a[0] == "codesign")
        self.assertTrue(all(a[0] == "install_name_tool" for a in calls[:first_sign]))

    def test_external_framework_fails(self):
        p = self.packager("macos")
        framework = self.write(self.root / "Foo.framework" / "Versions" / "A" / "Foo")
        with mock.patch.object(p, "mac_metadata", return_value=([str(framework)], [])), self.assertRaisesRegex(package.PackageError, "External frameworks"):
            p.macos_dependencies()

    def test_inherited_rpath_and_missing_library(self):
        p = self.packager("macos")
        a = self.write(self.root / "deps" / "a.dylib")
        b = self.write(self.root / "deps" / "b.dylib")
        def metadata(path):
            if path.name == "ffmpeg":
                return ["@rpath/a.dylib"], [str(a.parent)]
            if path == a:
                return ["@rpath/b.dylib"], []
            return [], []
        with mock.patch.object(p, "mac_metadata", side_effect=metadata), mock.patch.object(p, "brew_attribution"), mock.patch.object(package, "run", return_value=result()):
            p.macos_dependencies()
        self.assertTrue((p.stage / "lib" / "b.dylib").exists())
        with mock.patch.object(p, "mac_metadata", return_value=(["@rpath/absent.dylib"], [])), self.assertRaisesRegex(package.PackageError, "Unresolved macOS"):
            p.macos_dependencies()


class WindowsTests(ScratchTest):
    def test_known_os_and_gpu_only(self):
        p = self.packager("windows")
        text = "Image has the following dependencies:\n KERNEL32.dll\n api-ms-win-crt-runtime-l1-1-0.dll\n nvEncodeAPI64.dll\n"
        with mock.patch.object(package.shutil, "which", return_value="dumpbin"), mock.patch.object(package, "run", return_value=result(text)):
            p.windows_dependencies()
        self.assertEqual({d["disposition"] for d in p.dependencies}, {"external-base-os", "external-gpu-driver"})
        for name in ("VCRUNTIME140.dll", "MSVCP140.dll", "SDL2.dll", "libjxl.dll"):
            with self.subTest(name=name), mock.patch.object(package.shutil, "which", return_value="dumpbin"), \
                 mock.patch.object(package, "run", return_value=result("Image has the following dependencies:\n " + name + "\n")), \
                 self.assertRaisesRegex(package.PackageError, "static /MT"):
                p.windows_dependencies()

    def test_inspector_required_and_unrecognized_output_fails(self):
        p = self.packager("windows")
        with mock.patch.object(package.shutil, "which", return_value=None), self.assertRaisesRegex(package.PackageError, "requires dumpbin"):
            p.windows_dependencies()
        with mock.patch.object(package.shutil, "which", return_value="dumpbin"), mock.patch.object(package, "run", return_value=result("nonsense")), self.assertRaisesRegex(package.PackageError, "Unrecognized"):
            p.windows_dependencies()

    def test_delay_load_dll_is_rejected(self):
        p = self.packager("windows")
        def command(args, **kwargs):
            if "/IMPORTS" in args:
                return result("Section contains the following delay load imports:\n    third-party.dll\n")
            return result("Image has the following dependencies:\n KERNEL32.dll\n")
        with mock.patch.object(package.shutil, "which", return_value="dumpbin"), \
             mock.patch.object(package, "run", side_effect=command), self.assertRaisesRegex(package.PackageError, "third-party.dll"):
            p.windows_dependencies()
        with mock.patch.object(package.shutil, "which", side_effect=lambda n: "objdump" if n == "objdump" else None), \
             mock.patch.object(package, "run", return_value=result("file format pei-x86-64\n Entry d 000000001234 0000000030 Delay Import Directory\n")), \
             self.assertRaisesRegex(package.PackageError, "Delay-load DLL"):
            p.windows_dependencies()

    def test_objdump_fallback(self):
        p = self.packager("windows")
        with mock.patch.object(package.shutil, "which", side_effect=lambda n: "objdump" if n == "objdump" else None), \
             mock.patch.object(package, "run", return_value=result("file format pei-x86-64\n DLL Name: kernel32.dll\n")):
            p.windows_dependencies()


class LicenseSourceTests(ScratchTest):
    def test_license_tree_is_curated(self):
        p = self.packager()
        licenses = self.root / "metadata"
        self.write(licenses / "libfoo" / "copyright", b"license")
        self.write(licenses / "libfoo" / "vcpkg.json", b"{}")
        self.write(licenses / "libfoo" / "secret.txt", b"not metadata")
        self.write(licenses / "build" / "COPYING", b"build artifact")
        self.write(licenses / "PATENTS", b"patents")
        self.assertEqual(p.license_tree(licenses, "dependency"), 3)
        self.assertFalse((p.stage / "licenses" / "dependency" / "libfoo" / "secret.txt").exists())

    def test_archive_uses_modified_git_files_excludes_artifacts(self):
        p = self.packager()
        self.write(self.source / ".git" / "config", b"secret remote")
        self.write(self.source / "build" / "out.c")
        self.write(self.source / "lib.o")
        def command(args, **kwargs):
            if "--show-toplevel" in args:
                return result(str(self.source))
            if "HEAD" in args:
                return result("a" * 40)
            if "status" in args:
                return result(" M tracked.c\n")
            if "remote" in args:
                return result("https://credential@example.com/repo.git")
            if "ls-files" in args:
                return result("tracked.c\0LICENSE.md\0.git/config\0build/out.c\0lib.o\0")
            return result()
        with mock.patch.object(package.shutil, "which", return_value="git"), mock.patch.object(package, "run", side_effect=command):
            p.archive_source(self.source, "ffmpeg")
        with tarfile.open(p.stage / "sources" / "ffmpeg.tar.gz") as tar:
            self.assertEqual(tar.getnames(), ["ffmpeg/LICENSE.md", "ffmpeg/tracked.c"])
            self.assertEqual(tar.extractfile("ffmpeg/tracked.c").read(), b"modified actual source bytes")
        self.assertTrue(p.sources[0]["modified_worktree"])
        self.assertEqual(p.sources[0]["git_sha"], "a" * 40)
        self.assertEqual(p.sources[0]["source_urls"], [])

    def test_archive_recurses_submodules_and_nested_untracked_sources(self):
        p = self.packager()
        child = self.source / "third_party" / "codec"
        nested = child / "vendor" / "math"
        self.write(child / ".git", b"gitdir: external metadata")
        self.write(child / "codec.c", b"modified codec source")
        self.write(child / "local.h", b"untracked source")
        self.write(child / "codec.o", b"compiled artifact")
        self.write(nested / ".git", b"gitdir: nested metadata")
        self.write(nested / "math.c", b"nested tracked source")
        self.write(nested / "extra.h", b"nested untracked source")
        expected = "b" * 40
        actual = "c" * 40
        listings = {self.source: "tracked.c\0third_party/codec\0",
                    child: "codec.c\0local.h\0codec.o\0vendor/math\0",
                    nested: "math.c\0extra.h\0"}
        indexes = {self.source: f"160000 {expected} 0\tthird_party/codec\0",
                   child: f"160000 {expected} 0\tvendor/math\0", nested: ""}
        def command(args, **kwargs):
            repository = Path(args[2])
            if "--show-toplevel" in args:
                return result(str(repository))
            if "ls-files" in args:
                return result(indexes[repository] if "--stage" in args else listings[repository])
            if "rev-parse" in args:
                return result(actual)
            if "status" in args:
                return result(" M codec.c\n?? local.h\n" if repository == child else "")
            return result()
        with mock.patch.object(package.shutil, "which", return_value="git"), mock.patch.object(package, "run", side_effect=command) as commands:
            p.archive_source(self.source, "avm")
        with tarfile.open(p.stage / "sources" / "avm.tar.gz") as tar:
            names = tar.getnames()
            self.assertIn("avm/third_party/codec/local.h", names)
            self.assertIn("avm/third_party/codec/vendor/math/extra.h", names)
            self.assertIn("avm/third_party/codec/vendor/math/math.c", names)
            self.assertEqual(tar.extractfile("avm/third_party/codec/codec.c").read(), b"modified codec source")
            self.assertFalse(any(name.endswith((".git", ".o")) for name in names))
        modules = p.sources[0]["submodules"]
        self.assertEqual([m["path"] for m in modules], ["third_party/codec", "third_party/codec/vendor/math"])
        self.assertEqual(modules[0]["gitlink_sha"], expected)
        self.assertEqual(modules[0]["git_sha"], actual)
        self.assertTrue(modules[0]["modified_worktree"])
        for call in commands.call_args_list:
            if "ls-files" in call.args[0] and "--stage" not in call.args[0]:
                self.assertIn("--others", call.args[0])
                self.assertIn("--exclude-standard", call.args[0])

    def test_source_submodule_must_be_initialized(self):
        p = self.packager()
        (self.source / "third_party").mkdir()
        def command(args, **kwargs):
            if "--stage" in args:
                return result(f"160000 {'a' * 40} 0\tthird_party\0")
            if "--show-toplevel" in args:
                return result(str(self.source))
            return result()
        with mock.patch.object(package.shutil, "which", return_value="git"), mock.patch.object(package, "run", side_effect=command), \
             self.assertRaisesRegex(package.PackageError, "Uninitialized source submodule"):
            p.archive_source(self.source, "avm")

    def test_selected_source_archive_skips_unrelated_submodule(self):
        p = self.packager()
        self.write(self.source / "scripts" / "build.sh")
        def command(args, **kwargs):
            self.assertEqual(Path(args[2]), self.source)
            if "--stage" in args:
                return result(f"160000 {'a' * 40} 0\tthird_party\0")
            if "ls-files" in args:
                return result("scripts/build.sh\0third_party\0")
            if "--show-toplevel" in args:
                return result(str(self.source))
            return result()
        with mock.patch.object(package.shutil, "which", return_value="git"), mock.patch.object(package, "run", side_effect=command):
            p.archive_source(self.source, "scripts", selected=("scripts",))
        with tarfile.open(p.stage / "sources" / "scripts.tar.gz") as tar:
            self.assertEqual(tar.getnames(), ["scripts/scripts/build.sh"])

    def test_dependency_evidence_directory_preserves_source_archives(self):
        p = self.packager()
        evidence = self.root / "source-evidence"
        archive = self.write(evidence / "foo" / "foo-1.0.tar.xz", b"original source archive")
        self.write(evidence / "foo" / "distribution.patch", b"package patches")
        with mock.patch.object(package.shutil, "which", return_value=None):
            p.archive_source(evidence, "dependency-sources")
        with tarfile.open(p.stage / "sources" / "dependency-sources.tar.gz") as tar:
            self.assertEqual(tar.extractfile("dependency-sources/foo/foo-1.0.tar.xz").read(), archive.read_bytes())
            self.assertIn("dependency-sources/foo/distribution.patch", tar.getnames())

    def test_dpkg_package_version_and_copyright(self):
        p = self.packager()
        original_is_file = package.Path.is_file
        original_read = package.Path.read_text
        copyright_path = Path("/usr/share/doc/libfoo1/copyright")
        def command(args, **kwargs):
            if "-S" in args:
                return result("libfoo1:amd64: /usr/lib/libfoo.so.1\n")
            return result("libfoo1:amd64\t1.2-3\tfoo\t1.2-3\thttps://example.org/foo\n")
        with mock.patch.object(package.shutil, "which", return_value="dpkg-query"), mock.patch.object(package, "run", side_effect=command), \
             mock.patch.object(package.Path, "is_file", lambda path: True if path == copyright_path else original_is_file(path)), \
             mock.patch.object(package.Path, "read_text", lambda path, **kw: "Source: https://example.org/src\n" if path == copyright_path else original_read(path, **kw)), \
             mock.patch.object(p, "copy") as copy:
            p.dpkg_attribution(Path("/usr/lib/libfoo.so.1"))
        record = p.packages["libfoo1:amd64"]
        self.assertEqual(record["version"], "1.2-3")
        self.assertEqual(record["source_package"], "foo")
        self.assertEqual(record["corresponding_source"], "not-included")
        self.assertIn("https://example.org/src", record["source_urls"])
        copy.assert_called_once()

    def test_vcpkg_spdx_version_sources_and_gaps(self):
        p = self.packager("windows")
        root = self.root / "share"
        metadata = {"packages": [{"name": "jxl", "versionInfo": "1.2", "downloadLocation": "https://example.org/jxl.tar.gz", "licenseConcluded": "BSD-3-Clause"}]}
        self.write(root / "jxl" / "vcpkg.spdx.json", json.dumps(metadata).encode())
        p.metadata_attribution(root)
        record = p.packages["vcpkg:jxl@1.2"]
        self.assertEqual(record["license"], "BSD-3-Clause")
        self.assertEqual(record["source_urls"], ["https://example.org/jxl.tar.gz"])
        self.assertEqual(record["corresponding_source"], "not-included")

    def test_static_pkgconfig_attribution_closure(self):
        p = self.packager()
        pc = self.write(self.root / "pc" / "libvmaf.pc")
        child = self.write(self.root / "pc" / "child.pc")
        def command(args, **kwargs):
            if args[0] != "pkg-config":
                return result("GNU General Public License version 3" if "-L" in args else "configuration: --enable-gpl --enable-libvmaf")
            if "--exists" in args:
                return result(code=1)
            if "--variable=pcfiledir" in args:
                return result(str(pc.parent))
            if "--modversion" in args:
                return result("1.2")
            if "--libs" in args:
                return result("-lvmaf")
            if "--print-requires-private" in args and args[-1] == "libvmaf":
                return result("child >= 1.0\n")
            return result()
        with mock.patch.object(package.shutil, "which", return_value="pkg-config"), \
             mock.patch.object(package, "run", side_effect=command), mock.patch.object(p, "dpkg_attribution") as attribution:
            p.static_attribution()
        self.assertEqual({r["module"] for r in p.static_links}, {"libvmaf", "child"})
        self.assertEqual({c.args[0] for c in attribution.call_args_list}, {pc, child})

    def test_static_pkgconfig_library_directories_whitespace_and_quoting(self):
        p = self.packager()
        pc = self.write(self.root / "pc" / "libvmaf.pc")
        first = self.write(self.root / "libs" / "libvmaf.a")
        quoted = self.write(self.root / "libs with spaces" / "libquoted.a")
        last = self.write(self.root / "last" / "liblast.a")
        # Separate by both spaces and tabs, with -L also at the start.
        flags = f'-L{first.parent} -lvmaf\t-L"{quoted.parent}" -lquoted -L{last.parent}\t-llast'
        def command(args, **kwargs):
            if args[0] != "pkg-config":
                return result("GNU General Public License version 3" if "-L" in args else "configuration: --enable-libvmaf")
            if "--exists" in args:
                return result(code=1)
            if "--variable=pcfiledir" in args:
                return result(str(pc.parent))
            if "--libs" in args:
                return result(flags)
            # Leave libdir empty: every archive must be discovered via -L.
            return result()
        with mock.patch.object(package.shutil, "which", return_value="pkg-config"), \
             mock.patch.object(package, "run", side_effect=command), mock.patch.object(p, "dpkg_attribution") as attribution:
            p.static_attribution()
        self.assertEqual({call.args[0] for call in attribution.call_args_list}, {pc, first, quoted, last})

    def test_nonfree_configuration_rejected(self):
        p = self.packager()
        with mock.patch.object(package, "run", return_value=result("configuration: --enable-gpl --enable-nonfree")), self.assertRaisesRegex(package.PackageError, "nonfree"):
            p.static_attribution()


class VerificationTests(ScratchTest):
    def verifier(self, encoders=(), avm=False):
        directory = self.root / "runtime"
        for name in ("ffmpeg", "ffprobe", "ffplay", *( ("avmenc", "avmdec") if avm else ())):
            self.write(directory / name)
        return verify.Verifier("linux", directory, encoders, avm)

    def registration_command(self, name, *args):
        if "-version" in args:
            return result(name + " version unit-test\n" + "full output\n" * 1000)
        if "-L" in args:
            return result("GNU General Public License version 3")
        if "-encoders" in args:
            return result(" V..... libjxl JPEG XL\n V....D h264_nvenc NVENC\n")
        if "-decoders" in args:
            return result(" V..... libjxl JPEG XL\n")
        if "-filters" in args:
            return result(" ... libvmaf VV->V VMAF\n")
        if "-codecs" in args:
            return result(" DEVILS jpegxl JPEG XL\n")
        return result()

    def test_clean_environment_uses_allowlisted_path(self):
        inherited = {"PATH": str(self.bin) + os.pathsep + "C:\\vcpkg\\bin", "Path": "build-dir", "LD_LIBRARY_PATH": "deps", "LD_PRELOAD": "unsafe", "DYLD_LIBRARY_PATH": "build", "DYLD_FALLBACK_LIBRARY_PATH": "deps", "LIBPATH": "x", "FFREPORT": "file=outside.log", "SystemRoot": r"C:\Windows"}
        for platform in ("linux", "macos", "windows"):
            env = verify.clean_environment(platform, self.bin, inherited)
            self.assertFalse(any(k.startswith(("LD_", "DYLD_")) for k in env))
            self.assertNotIn("Path", env)
            self.assertNotIn(str(self.bin), env["PATH"])
            self.assertNotIn("vcpkg", env["PATH"])
            self.assertNotIn("FFREPORT", env)

    def test_licenses_reject_nonfree_missing_output(self):
        for text in ("--enable-nonfree", "nonfree and unredistributable", "not legally redistributable"):
            with self.subTest(text=text), self.assertRaises(verify.VerificationError):
                verify.reject_nonfree(text)
        v = self.verifier()
        with mock.patch.object(v, "command", return_value=result("")), self.assertRaises(verify.VerificationError):
            v.registrations()

    def test_required_binaries_and_avm(self):
        v = self.verifier(avm=True)
        v.check_required()
        v.binaries["ffplay"].unlink()
        with self.assertRaisesRegex(verify.VerificationError, "Missing required binary: ffplay"):
            v.check_required()
        v = self.verifier(avm=True)
        v.binaries["avmdec"].unlink()
        with self.assertRaisesRegex(verify.VerificationError, "Missing required binary: avmdec"):
            v.check_required()

    def test_repeatable_hardware_registration_without_gpu_execution(self):
        v = self.verifier(["h264_nvenc"])
        with mock.patch.object(v, "command", side_effect=self.registration_command) as commands, mock.patch("builtins.print"):
            v.registrations()
        self.assertFalse(any("-c:v" in c.args for c in commands.call_args_list))
        v = self.verifier(["hevc_qsv"])
        with mock.patch.object(v, "command", side_effect=self.registration_command), mock.patch("builtins.print"), self.assertRaisesRegex(verify.VerificationError, "hevc_qsv"):
            v.registrations()

    def test_missing_feature_fails(self):
        for option in ("-encoders", "-decoders", "-filters", "-codecs"):
            v = self.verifier()
            def command(name, *args):
                return result("") if option in args else self.registration_command(name, *args)
            with self.subTest(option=option), mock.patch.object(v, "command", side_effect=command), mock.patch("builtins.print"), self.assertRaises(verify.VerificationError):
                v.registrations()

    def test_linux_relocation_audit_rejects_build_dependency(self):
        v = self.verifier()
        dep = self.write(v.directory / "lib" / "libfoo.so")
        outside = self.write(self.root / "build" / "libfoo.so")
        def metadata(binary):
            return ["libfoo.so"] if binary.name == "ffmpeg" else []
        def command(args, **kwargs):
            if args[0] == "readelf":
                return result("(RUNPATH) Library runpath: [$ORIGIN/lib]")
            return result(f" libfoo.so => {outside} (0x1234)\n")
        with mock.patch.object(verify, "load_packager", return_value=package), \
             mock.patch.object(package.Packager, "elf_metadata", side_effect=metadata), \
             mock.patch.object(verify, "run", side_effect=command), self.assertRaisesRegex(verify.VerificationError, "escaped bundle"):
            v.audit_relocation()
        with mock.patch.object(verify, "load_packager", return_value=package), \
             mock.patch.object(package.Packager, "elf_metadata", side_effect=metadata), \
             mock.patch.object(verify, "run", side_effect=lambda a, **kw: result("(RUNPATH) Library runpath: [$ORIGIN/lib]") if a[0] == "readelf" else result(f" libfoo.so => {dep} (0x1234)\n")):
            v.audit_relocation()

    def test_macos_relocation_audit_rejects_absolute_path(self):
        v = self.verifier()
        v.platform = "macos"
        with mock.patch.object(verify, "load_packager", return_value=package), \
             mock.patch.object(package.Packager, "mac_metadata", return_value=(["/opt/homebrew/lib/libfoo.dylib"], ["@loader_path/lib"])), \
             self.assertRaisesRegex(verify.VerificationError, "escaped bundle"):
            v.audit_relocation()

    def test_capture_full_stdout_no_shell_or_head(self):
        output = "ffmpeg version test\n" + "line\n" * 10000
        with mock.patch.object(verify.subprocess, "run", return_value=result(output)) as runner:
            actual = verify.run(["ffmpeg", "-version"], env={}, cwd=self.root)
        self.assertEqual(actual.stdout, output)
        self.assertEqual(runner.call_args.kwargs["stdout"], subprocess.PIPE)
        self.assertNotIn("shell", runner.call_args.kwargs)

    def test_software_smoke_vmaf_jxl_probe(self):
        v = self.verifier()
        v.work.mkdir()
        calls = []
        def command(name, *args):
            calls.append((name, args))
            if any("libvmaf=" in a for a in args):
                (v.work / "vmaf.json").write_text(json.dumps({"frames": [{"metrics": {"vmaf": 100}}], "pooled_metrics": {"vmaf": {"mean": 100}}}))
            if args[-1].endswith("roundtrip.jxl"):
                self.write(v.work / "roundtrip.jxl", b"encoded")
            if name == "ffprobe":
                return result(json.dumps({"streams": [{"codec_name": "jpegxl", "width": 32, "height": 32}]}))
            return result()
        with mock.patch.object(v, "command", side_effect=command), mock.patch("builtins.print"):
            v.smoke()
        self.assertTrue(any("-distance" in args for _, args in calls))
        self.assertTrue(any(name == "ffprobe" for name, _ in calls))
        self.assertFalse(any(name == "ffplay" for name, _ in calls))
        self.assertFalse(any("cuda" in str(args) or "nvenc" in str(args) for _, args in calls))

    def test_smoke_requires_actual_outputs(self):
        v = self.verifier()
        v.work.mkdir()
        with mock.patch.object(v, "command", return_value=result()), self.assertRaisesRegex(verify.VerificationError, "VMAF smoke produced no metrics"):
            v.smoke()

    def test_avm_roundtrip_uses_packaged_pair(self):
        v = self.verifier(avm=True)
        v.work.mkdir()
        calls = []
        def command(name, *args):
            calls.append(name)
            if name == "avmenc":
                self.write(v.work / "avm-output.ivf", b"ivf")
            if name == "avmdec":
                self.write(v.work / "avm-decoded.y4m", b"YUV4MPEG2 W64 H64 F1:1 Ip C420\nFRAME\n" + b"\0" * (64 * 64 * 3 // 2))
            return result()
        with mock.patch.object(v, "command", side_effect=command), mock.patch("builtins.print"):
            v.avm_smoke()
        self.assertIn("avmenc", calls)
        self.assertIn("avmdec", calls)

    def test_verification_cleans_scratch_on_failure(self):
        v = self.verifier()
        with mock.patch.object(v, "registrations"), mock.patch.object(v, "smoke", side_effect=verify.VerificationError("smoke failed")), self.assertRaises(verify.VerificationError):
            v.verify()
        self.assertFalse(v.work.exists())


if __name__ == "__main__":
    unittest.main()
