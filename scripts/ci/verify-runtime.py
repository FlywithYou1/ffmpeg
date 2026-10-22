#!/usr/bin/env python3
"""Verify a relocated package (or install bin directory) without build PATHs.

Usage: verify-runtime.py --platform linux|macos|windows --directory DIRECTORY
    [--require-encoder NAME ...] [--avm]

Checks all three programs headlessly, license, libvmaf and libjxl registration,
software/VMAF/JPEG XL smoke tests, and optional packaged AVM roundtrip. Hardware
encoders are inspected for registration only; no GPU or ffplay GUI is required.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid


class VerificationError(RuntimeError):
    pass


def run(args, *, env, cwd, timeout=120):
    try:
        result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                errors="replace", env=env, cwd=cwd, timeout=timeout,
                                check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise VerificationError(f"Cannot launch {args[0]}: {exc}") from exc
    if result.returncode:
        raise VerificationError(f"Command failed ({result.returncode}): {' '.join(map(str, args))}\n{result.stdout}\n{result.stderr}")
    return result


def clean_environment(platform, directory, inherited=None):
    env = dict(os.environ if inherited is None else inherited)
    for key in list(env):
        upper = key.upper()
        if upper.startswith(("LD_", "DYLD_")) or upper in {"LIBPATH", "SHLIB_PATH", "PYTHONPATH", "PYTHONHOME", "FFREPORT", "SDL_AUDIODRIVER", "SDL_VIDEODRIVER"}:
            del env[key]
        if upper == "PATH":
            del env[key]
    # An allowlist, not removal heuristics: no install/build/AVM/vcpkg paths.
    if platform == "windows":
        system_root = next((v for k, v in env.items() if k.upper() == "SYSTEMROOT"), r"C:\Windows")
        env["PATH"] = os.pathsep.join([str(Path(system_root) / "System32"), str(Path(system_root))])
    else:
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    env["LC_ALL"] = "C"
    env["LANG"] = "C"
    env["SDL_VIDEODRIVER"] = "dummy"
    env["SDL_AUDIODRIVER"] = "dummy"
    # No media commands open an ffplay window, even with inherited display state.
    return env


def recognized_license(text):
    # Nonfree builds report the unredistributable notice instead of the GPL text.
    return bool(re.search(r"(?:GNU (?:Lesser )?General Public License|\b[AL]?GPL\b)", text, re.I)
                or re.search(r"--enable-nonfree\b|non[- ]?free|unredistributable|not (?:legally )?redistributable", text, re.I))


def registry_names(text):
    return set(re.findall(r"^\s*[A-Z.]{3,8}\s+([A-Za-z0-9_]+)\s", text, re.M))


def load_packager():
    path = Path(__file__).with_name("package-runtime.py")
    spec = importlib.util.spec_from_file_location("ffmpeg_runtime_packager", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Verifier:
    def __init__(self, platform, directory, require_encoders=(), avm=False, local_only=False,
                 require_complete_source=False):
        self.platform = platform
        self.local_only = local_only
        self.require_complete_source = require_complete_source
        self.directory = Path(directory).resolve()
        extension = ".exe" if platform == "windows" else ""
        self.binaries = {n: self.directory / (n + extension) for n in ("ffmpeg", "ffprobe", "ffplay")}
        if avm:
            self.binaries.update({n: self.directory / (n + extension) for n in ("avmenc", "avmdec")})
        self.avm = avm
        self.require_encoders = tuple(require_encoders)
        for name in self.require_encoders:
            if not re.fullmatch(r"[A-Za-z0-9_]+", name):
                raise VerificationError(f"Invalid required encoder name: {name}")
        self.env = clean_environment(platform, self.directory)
        self.work = self.directory / (".runtime-check-" + uuid.uuid4().hex)

    def command(self, name, *args):
        return run([str(self.binaries[name]), *args], env=self.env, cwd=self.work if self.work.exists() else self.directory)

    def check_required(self):
        for name, binary in self.binaries.items():
            if not binary.is_file():
                raise VerificationError(f"Missing required binary: {name}: {binary}")
        manifest_path = self.directory / "runtime-manifest.json"
        if manifest_path.is_file():
            package = load_packager()
            try:
                _, manifest = package.validate_output(self.directory, inspection=True)
            except package.PackageError as exc:
                raise VerificationError(f"Package integrity failed: {exc}") from exc
            if not manifest or manifest.get("platform") != self.platform:
                raise VerificationError("Package platform/manifest mismatch")
            if self.local_only != (manifest.get("distribution") == "local-only-unredistributable"):
                raise VerificationError("Package distribution policy does not match verifier policy")
            # Manifest can be moved anywhere; all executable/library paths are relative.
            if self.require_complete_source:
                status = manifest.get("corresponding_source", {}).get("status")
                if status != "complete":
                    raise VerificationError(f"Corresponding source is not complete: {status}")
                inventory = manifest.get("dependency_source_inventory")
                if not isinstance(inventory, dict) or not inventory.get("complete"):
                    raise VerificationError("Missing complete dependency-source inventory")
                for name in inventory.get("files", {}):
                    if not (self.directory / "sources" / "dependencies").is_dir():
                        raise VerificationError("Dependency sources are missing from the package")
                    break
                for record in inventory.get("packages", []):
                    label = re.sub(r"[^A-Za-z0-9_.-]", "_", record["id"])
                    for relative in record.get("files", {}):
                        if not (self.directory / "sources" / "dependencies" / label / relative).is_file():
                            raise VerificationError(f"Dependency source is missing: {label}/{relative}")
            bundled = [d for d in manifest.get("dependencies", []) if d.get("disposition") == "bundled"]
            for dep in bundled:
                name = Path(dep["source"]).name if self.platform == "macos" else dep["name"]
                if not (self.directory / "lib" / name).is_file():
                    raise VerificationError(f"Bundled dependency is missing: {name}")
        if manifest_path.is_file() and self.platform in {"linux", "macos"}:
            self.audit_relocation()
        if self.platform == "windows":
            package = load_packager()
            audit = object.__new__(package.Packager)
            audit.executables = [(p, p) for p in self.binaries.values()]
            audit.dependencies = []
            try:
                audit.windows_dependencies()
            except package.PackageError as exc:
                raise VerificationError(str(exc)) from exc

    def audit_relocation(self):
        package = load_packager()
        audit = object.__new__(package.Packager)
        files = [*self.binaries.values()]
        library_dir = self.directory / "lib"
        if library_dir.is_dir():
            files += [p for p in sorted(library_dir.iterdir()) if p.is_file()]
        if self.platform == "linux":
            for binary in files:
                try:
                    needed = audit.elf_metadata(binary)
                except package.PackageError as exc:
                    raise VerificationError(str(exc)) from exc
                dynamic = run(["readelf", "-d", str(binary)], env=self.env, cwd=self.directory).stdout
                rpaths = re.findall(r"\((?:RUNPATH|RPATH)\).*?\[([^\]]*)\]", dynamic)
                expected = "$ORIGIN" if binary.parent == library_dir else "$ORIGIN/lib"
                if needed and rpaths != [expected]:
                    raise VerificationError(f"Non-relocatable ELF search path: {binary}: {rpaths}")
                if not needed:
                    continue
                listing = run(["ldd", str(binary)], env=self.env, cwd=self.directory).stdout
                for name in needed:
                    if package.LINUX_BASE.fullmatch(name) or package.LINUX_GPU.fullmatch(name):
                        continue
                    match = re.search(r"^\s*" + re.escape(name) + r"\s+=>\s+(.+?)\s+\(0x[0-9a-fA-F]+\)\s*$", listing, re.M)
                    if not match or not package.under(Path(match.group(1)).resolve(), library_dir.resolve()):
                        raise VerificationError(f"ELF dependency escaped bundle: {binary}: {name}\n{listing}")
        else:
            for binary in files:
                try:
                    deps, rpaths = audit.mac_metadata(binary)
                except package.PackageError as exc:
                    raise VerificationError(str(exc)) from exc
                expected = "@loader_path" if binary.parent == library_dir else "@loader_path/lib"
                if rpaths != [expected]:
                    raise VerificationError(f"Non-relocatable Mach-O rpath: {binary}: {rpaths}")
                for dep in deps:
                    if package.Packager.mac_system(dep):
                        continue
                    if not dep.startswith(expected + "/"):
                        raise VerificationError(f"Mach-O dependency escaped bundle: {binary}: {dep}")
                    target = binary.parent / dep.removeprefix("@loader_path/")
                    if not target.is_file() or not package.under(target.resolve(), library_dir.resolve()):
                        raise VerificationError(f"Missing bundled Mach-O dependency: {binary}: {dep}")
                run(["codesign", "--verify", "--strict", str(binary)], env=self.env, cwd=self.directory)

    def registrations(self):
        for name in ("ffmpeg", "ffprobe", "ffplay"):
            result = self.command(name, "-version")
            if not re.search(rf"\b{re.escape(name)} version\b", result.stdout + result.stderr):
                raise VerificationError(f"Unexpected {name} version output")
            # Capture the complete pipe before slicing; never use head/SIGPIPE.
            print((result.stdout + result.stderr)[:700].rstrip())
        license_result = self.command("ffmpeg", "-hide_banner", "-L")
        license_text = license_result.stdout + license_result.stderr
        if not self.local_only and not recognized_license(license_text):
            raise VerificationError("Missing recognized FFmpeg license output")
        encoders = self.command("ffmpeg", "-hide_banner", "-encoders").stdout
        filters = self.command("ffmpeg", "-hide_banner", "-filters").stdout
        codecs = self.command("ffmpeg", "-hide_banner", "-codecs").stdout
        decoders = self.command("ffmpeg", "-hide_banner", "-decoders").stdout
        encoder_names = registry_names(encoders)
        decoder_names = registry_names(decoders)
        filter_names = registry_names(filters)
        if "libvmaf" not in filter_names:
            raise VerificationError("Required libvmaf filter is missing")
        if "libjxl" not in encoder_names or "libjxl" not in decoder_names:
            raise VerificationError("Required libjxl JPEG XL encoder/decoder is missing")
        if not re.search(r"^\s*DE[A-Z.]*\s+jpegxl\s", codecs, re.M):
            raise VerificationError("JPEG XL codec does not register encoding AND decoding")
        for name in self.require_encoders:
            if name not in encoder_names:
                raise VerificationError(f"Required encoder is missing: {name}")
        print("Required registrations: libvmaf, libjxl encode/decode" + (", " + ", ".join(self.require_encoders) if self.require_encoders else ""))

    def smoke(self):
        common = ("-hide_banner", "-nostdin", "-v", "error", "-y", "-threads", "1", "-filter_threads", "1")
        self.command("ffmpeg", *common, "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=2:duration=1",
                     "-frames:v", "2", "-f", "null", "-")
        vmaf = self.work / "vmaf.json"
        # Standard libvmaf model embedded in libvmaf; no build-directory model path.
        self.command("ffmpeg", *common, "-filter_complex_threads", "1", "-f", "lavfi", "-i",
                     "testsrc2=size=192x108:rate=2:duration=1", "-filter_complex",
                     "[0:v]split=2[dist][ref];[dist][ref]libvmaf=n_threads=1:log_fmt=json:log_path=vmaf.json",
                     "-frames:v", "2", "-f", "null", "-")
        if not vmaf.is_file():
            raise VerificationError("VMAF smoke produced no metrics")
        try:
            metrics = json.loads(vmaf.read_text(encoding="utf-8"))
            frames = metrics.get("frames", [])
            score = metrics.get("pooled_metrics", {}).get("vmaf", {}).get("mean")
            if not frames or not isinstance(score, (int, float)) or not 0 <= score <= 100.01:
                raise ValueError("No valid VMAF score")
        except (OSError, ValueError, TypeError) as exc:
            raise VerificationError(f"Invalid VMAF metrics: {exc}") from exc
        image = self.work / "roundtrip.jxl"
        self.command("ffmpeg", *common, "-f", "lavfi", "-i", "testsrc=size=32x32:rate=1",
                     "-frames:v", "1", "-pix_fmt", "rgb24", "-c:v", "libjxl", "-distance", "0", str(image))
        if not image.is_file() or not image.stat().st_size:
            raise VerificationError("JPEG XL smoke produced no image")
        self.command("ffmpeg", *common, "-c:v", "libjxl", "-i", str(image), "-frames:v", "1", "-f", "null", "-")
        probe = self.command("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                             "stream=codec_name,width,height", "-of", "json", str(image))
        try:
            stream = json.loads(probe.stdout)["streams"][0]
            if stream.get("codec_name") != "jpegxl" or stream.get("width") != 32 or stream.get("height") != 32:
                raise ValueError("Unexpected JPEG XL stream")
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise VerificationError(f"ffprobe JPEG XL verification failed: {exc}") from exc
        print("Software, VMAF metrics, JPEG XL encode/decode and ffprobe smoke passed")

    def avm_smoke(self):
        # AVM media arguments use the scratch cwd, avoiding drive-path parsing.
        raw = self.work / "avm-input.y4m"
        encoded = self.work / "avm-output.ivf"
        decoded = self.work / "avm-decoded.y4m"
        self.command("ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                     "testsrc2=size=64x64:rate=1", "-frames:v", "1", "-pix_fmt", "yuv420p", "-f", "yuv4mpegpipe", str(raw))
        self.command("avmenc", "--codec=av2", "--ivf", "--limit=1", "--cpu-used=6", "--threads=2",
                     "--end-usage=q", "--cq-level=45", "-o", encoded.name, raw.name)
        if not encoded.is_file() or not encoded.stat().st_size:
            raise VerificationError("AVM encoder produced no data")
        self.command("avmdec", "--codec=av2", "--limit=1", "-o", decoded.name, encoded.name)
        if not decoded.is_file():
            raise VerificationError("AVM decoder produced no data")
        with decoded.open("rb") as stream:
            header = stream.readline()
            if not header.startswith(b"YUV4MPEG2 ") or b" W64 " not in header or b" H64 " not in header or stream.read(6) != b"FRAME\n" or len(stream.read()) < 64 * 64 * 3 // 2:
                raise VerificationError("Invalid AVM decoded frame")
        self.command("ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "json", str(decoded))
        print("Packaged AVM encode/decode roundtrip passed")

    def verify(self):
        self.check_required()
        self.registrations()
        self.work.mkdir()
        try:
            self.smoke()
            if self.avm:
                self.avm_smoke()
        finally:
            shutil.rmtree(self.work)
        print(f"Verified runtime: {self.directory}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("linux", "macos", "windows"))
    parser.add_argument("--directory", required=True)
    parser.add_argument("--require-encoder", action="append", default=[])
    parser.add_argument("--avm", action="store_true")
    parser.add_argument("--local-only", action="store_true")
    parser.add_argument("--require-complete-source", action="store_true")
    args = parser.parse_args(argv)
    try:
        Verifier(args.platform, args.directory, args.require_encoder, args.avm, args.local_only,
                 args.require_complete_source).verify()
    except (VerificationError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
