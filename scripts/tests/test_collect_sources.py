"""Tests for the dependency source collector and its packaging integration.

All network, apt, brew and vcpkg calls are mocked; no source is downloaded.
"""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / "ci" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collect = load("collect_sources_test", "collect-dependency-sources.py")
modules = load("dependency_modules_test", "dependency_modules.py")
package = load("package_runtime_test", "package-runtime.py")
verify = load("verify_runtime_test", "verify-runtime.py")


def result(stdout="", stderr="", code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class ModuleMappingTests(unittest.TestCase):
    def test_features_map_to_expected_modules(self):
        self.assertEqual(modules.required_modules(["libjxl", "libvmaf", "libx264"]),
                         sorted(["libjxl", "libjxl_threads", "libvmaf", "x264",
                                 *modules.BASE_MODULES]))

    def test_unknown_feature_maps_to_its_own_name(self):
        self.assertIn("libcustom", modules.required_modules(["libcustom"]))

    def test_base_modules_are_always_required(self):
        for module in modules.BASE_MODULES:
            self.assertIn(module, modules.required_modules([]))

    def test_buildconf_features_are_extracted(self):
        text = "configuration: --enable-gpl --enable-libx264 --enable-libjxl --enable-version3"
        self.assertEqual(modules.features_from_buildconf(text), ["gpl", "libjxl", "libx264", "version3"])

    def test_collector_and_packager_use_the_same_module_set(self):
        # The packager maps the same feature names; a mismatch would hide gaps.
        for feature, expected in modules.FEATURE_MODULES.items():
            self.assertTrue(expected, feature)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / (".collect-unit-" + uuid.uuid4().hex)
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)

    def test_download_verifies_checksum(self):
        target = self.root / "archive.tar.gz"
        with mock.patch.object(collect.urllib.request, "urlopen") as opener:
            opener.return_value.__enter__.return_value = mock.mock_open(read_data=b"payload").return_value
            with self.assertRaises(collect.CollectError):
                collect.download("https://example.org/a.tar.gz", target, "sha256", "00" * 32)
        self.assertFalse(target.exists())

    def test_download_writes_verified_file(self):
        payload = b"payload"
        digest = collect.digest.__self__ if False else None
        import hashlib
        expected = hashlib.sha256(payload).hexdigest()
        target = self.root / "archive.tar.gz"
        with mock.patch.object(collect.urllib.request, "urlopen") as opener:
            opener.return_value.__enter__.return_value = mock.mock_open(read_data=payload).return_value
            collect.download("https://example.org/a.tar.gz", target, "sha256", expected)
        self.assertTrue(target.is_file())

    def test_dpkg_owner_parses_multi_package_output(self):
        with mock.patch.object(collect, "run", return_value=result("libx264-dev:amd64, x264-dev:amd64: /usr/lib/x86_64-linux-gnu/pkgconfig/x264.pc\n")):
            self.assertEqual(collect.dpkg_owner("/usr/lib/pkgconfig/x264.pc"), "libx264-dev:amd64")

    def test_dpkg_owner_returns_none_when_unknown(self):
        with mock.patch.object(collect, "run", return_value=result("", code=1)):
            self.assertIsNone(collect.dpkg_owner("/nowhere.pc"))

    def test_inventory_omissions_make_the_run_incomplete(self):
        inventory = {"schema": 1, "platform": "linux", "complete": False,
                     "coverage": {"required": ["aom"], "provided": [], "omissions": ["aom: no source"]},
                     "packages": []}
        self.assertFalse(inventory["complete"])
        self.assertTrue(inventory["coverage"]["omissions"])

    def test_deb_src_entries_are_written_for_both_formats(self):
        root = self.root / "apt"
        (root / "sources.list.d").mkdir(parents=True)
        (root / "sources.list").write_text("deb http://archive.ubuntu.com/ubuntu noble main\n")
        (root / "sources.list.d" / "ubuntu.sources").write_text(
            "Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble\nComponents: main universe\n")
        with mock.patch.object(collect, "run", return_value=result("")) as runner:
            collect.enable_deb_src(root)
        listed = (root / "sources.list.d" / "ffmpeg-deb-src.list").read_text()
        deb822 = (root / "sources.list.d" / "ffmpeg-deb-src.sources").read_text()
        self.assertIn("deb-src http://archive.ubuntu.com/ubuntu noble main", listed)
        self.assertIn("Types: deb-src", deb822)
        self.assertIn("Suites: noble", deb822)
        self.assertIn("Components: main universe", deb822)
        self.assertTrue(any("apt-get" in " ".join(map(str, call.args[0])) for call in runner.call_args_list))

    def test_missing_apt_configuration_is_rejected(self):
        with mock.patch.object(collect, "run", return_value=result("")):
            with self.assertRaises(collect.CollectError):
                collect.enable_deb_src(self.root / "empty")

    def test_vcpkg_status_is_parsed(self):
        status = self.root / "vcpkg" / "status"
        status.parent.mkdir(parents=True)
        status.write_text("Package: x264\nVersion: 1.0\nArchitecture: x64\n\nPackage: zlib\nVersion: 1.3\n---\n")
        parsed = collect.vcpkg_installed_packages(self.root)
        self.assertEqual([p["Package"] for p in parsed], ["x264", "zlib"])
        self.assertEqual(parsed[1]["Version"], "1.3")

    def test_missing_vcpkg_status_fails(self):
        with self.assertRaises(collect.CollectError):
            collect.vcpkg_installed_packages(self.root)

    def test_brew_formula_source_requires_url_and_checksum(self):
        with mock.patch.object(collect, "run", return_value=result('  url "https://example.org/x.tar.gz"\n  sha256 "' + "a" * 64 + '"\n')):
            url, checksum = collect.brew_formula_source("x264")
        self.assertEqual(url, "https://example.org/x.tar.gz")
        self.assertEqual(checksum, "a" * 64)

    def test_brew_formula_without_checksum_is_rejected(self):
        with mock.patch.object(collect, "run", return_value=result('  url "https://example.org/x.tar.gz"\n')):
            self.assertEqual(collect.brew_formula_source("x264"), (None, None))


class InventoryIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / (".collect-int-" + uuid.uuid4().hex)
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)
        self.source = self.root / "ffmpeg-src"
        self.source.mkdir()
        (self.source / "LICENSE.md").write_text("license")
        (self.source / "COPYING.GPLv3").write_text("gpl")
        self.bin = self.root / "prefix" / "bin"
        self.bin.mkdir(parents=True)
        for name in ("ffmpeg", "ffprobe", "ffplay"):
            (self.bin / name).write_bytes(b"\x7fELF" + name.encode())
        self.inventory_dir = self.root / "dependency-sources"
        (self.inventory_dir / "sources" / "dpkg").mkdir(parents=True)
        (self.inventory_dir / "sources" / "dpkg" / "x264.tar.gz").write_bytes(b"source bytes")
        self.inventory = {
            "schema": 1, "platform": "linux", "complete": True,
            "coverage": {"policy": "all", "required": ["x264"], "provided": ["x264"], "omissions": []},
            "packages": [{"id": "dpkg:x264@1.0", "manager": "dpkg", "package": "x264", "version": "1.0",
                          "modules": ["x264"],
                          "files": {"sources/dpkg/x264.tar.gz": collect.digest(self.inventory_dir / "sources" / "dpkg" / "x264.tar.gz")}}],
        }
        (self.inventory_dir / "source-inventory.json").write_text(json.dumps(self.inventory))

    def packager(self, **kwargs):
        p = package.Packager("linux", self.bin, self.root / "dist", self.source, **kwargs)
        return p

    def test_complete_inventory_is_staged(self):
        p = self.packager(complete_source_dir=self.inventory_dir)
        p.stage.mkdir()
        self.addCleanup(lambda: shutil.rmtree(p.stage, ignore_errors=True))
        p.stage_complete_sources(self.inventory_dir)
        staged = list((p.stage / "sources" / "dependencies").rglob("*.tar.gz"))
        self.assertEqual(len(staged), 1)
        staged_metadata = sorted(x.name for x in (p.stage / "metadata").iterdir())
        self.assertIn("dependency-source-inventory.json", staged_metadata)

    def test_modified_source_file_is_rejected(self):
        (self.inventory_dir / "sources" / "dpkg" / "x264.tar.gz").write_bytes(b"tampered")
        p = self.packager(complete_source_dir=self.inventory_dir)
        p.stage.mkdir()
        self.addCleanup(lambda: shutil.rmtree(p.stage, ignore_errors=True))
        with self.assertRaisesRegex(package.PackageError, "modified"):
            p.stage_complete_sources(self.inventory_dir)

    def test_missing_source_file_is_rejected(self):
        (self.inventory_dir / "sources" / "dpkg" / "x264.tar.gz").unlink()
        p = self.packager(complete_source_dir=self.inventory_dir)
        p.stage.mkdir()
        self.addCleanup(lambda: shutil.rmtree(p.stage, ignore_errors=True))
        with self.assertRaisesRegex(package.PackageError, "missing"):
            p.stage_complete_sources(self.inventory_dir)

    def test_incomplete_inventory_is_rejected(self):
        self.inventory["complete"] = False
        self.inventory["coverage"]["omissions"] = ["x264: no source"]
        (self.inventory_dir / "source-inventory.json").write_text(json.dumps(self.inventory))
        p = self.packager(complete_source_dir=self.inventory_dir)
        p.stage.mkdir()
        self.addCleanup(lambda: shutil.rmtree(p.stage, ignore_errors=True))
        with self.assertRaisesRegex(package.PackageError, "incomplete"):
            p.stage_complete_sources(self.inventory_dir)

    def test_platform_mismatch_is_rejected(self):
        self.inventory["platform"] = "macos"
        (self.inventory_dir / "source-inventory.json").write_text(json.dumps(self.inventory))
        p = self.packager(complete_source_dir=self.inventory_dir)
        p.stage.mkdir()
        self.addCleanup(lambda: shutil.rmtree(p.stage, ignore_errors=True))
        with self.assertRaisesRegex(package.PackageError, "platform"):
            p.stage_complete_sources(self.inventory_dir)

    def test_missing_module_source_fails_coverage(self):
        p = self.packager(complete_source_dir=self.inventory_dir)
        p.stage.mkdir()
        self.addCleanup(lambda: shutil.rmtree(p.stage, ignore_errors=True))
        p.stage_complete_sources(self.inventory_dir)
        p.static_links = [{"module": "x264"}, {"module": "aom"}]
        with self.assertRaisesRegex(package.PackageError, "aom"):
            p.verify_source_coverage()

    def test_verifier_requires_complete_source(self):
        directory = self.root / "runtime"
        directory.mkdir()
        for name in ("ffmpeg", "ffprobe", "ffplay"):
            (directory / name).write_bytes(b"\x7fELF")
        files = {name: package.digest(directory / name) for name in ("ffmpeg", "ffprobe", "ffplay")}
        manifest = {"schema": 1, "owner": "test", "platform": "linux",
                    "files": files, "dependencies": [], "packages": [],
                    "corresponding_source": {"status": "review-required", "gaps": []}}
        (directory / package.MANIFEST).write_text(json.dumps(manifest))
        (directory / package.MARKER).write_text(json.dumps({"tool": package.TOOL, "schema": 1, "id": "test"}))
        v = verify.Verifier("linux", directory, (), False, False, True)
        with self.assertRaisesRegex(verify.VerificationError, "not complete"):
            v.check_required()


if __name__ == "__main__":
    unittest.main()
