#!/usr/bin/env python3
"""Stage relocatable FFmpeg runtimes, attribution and actual modified sources.

Usage: package-runtime.py --platform linux|macos|windows --bin-dir PREFIX/bin
    --output DIRECTORY --source-dir FFMPEG_SOURCE [--avm-prefix PREFIX]
    [--license-dir DIRECTORY ...] [--dependency-source DIRECTORY ...]

Only a marker/manifest-owned, unchanged output may be refreshed. Dependency
inspectors and platform relocation tools must already be installed. Dependency
source arguments are directories; source archives within them are included as
files. Initialized Git submodules are archived recursively, including untracked
non-ignored source files. Source URLs and license copies alone are NOT a
complete GPL corresponding-source offer.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import uuid


class PackageError(RuntimeError):
    pass


MARKER = ".ffmpeg-runtime-owner.json"
MANIFEST = "runtime-manifest.json"
TOOL = "ffmpeg-package-runtime"
LICENSE_RE = re.compile(r"^(?:licen[cs]e|copying|copyright|notice|patents|authors)(?:[._-].*)?$", re.I)
LINUX_BASE = re.compile(r"^(?:linux-vdso\.so(?:\..*)?|ld-linux[^/]*\.so(?:\..*)?|ld64\.so(?:\..*)?|lib(?:c|m|pthread|dl|rt|resolv|util|anl)\.so(?:\..*)?)$")
LINUX_GPU = re.compile(r"^(?:libcuda\.so(?:\..*)?|libnvidia-[^/]+\.so(?:\..*)?|libnvcuvid\.so(?:\..*)?|[^/]+_drv_video\.so)$")
WINDOWS_OS = set("advapi32 avrt bcrypt bcryptprimitives cabinet cfgmgr32 comctl32 comdlg32 crypt32 cryptbase d3d9 d3d11 d3d12 dcomp dbghelp dnsapi dwmapi dxgi dxva2 gdi32 gdi32full glu32 hid imm32 iphlpapi kernel32 kernelbase ksuser mf mfcore mfplat mfreadwrite mfuuid mpr msacm32 msvcrt mswsock ncrypt netapi32 normaliz ntdll ole32 oleaut32 opengl32 powrprof propsys psapi rpcrt4 secur32 setupapi shcore shell32 shlwapi strmiids ucrtbase user32 userenv usp10 version vfw32 win32u winhttp wininet winmm winscard winspool wintrust wldap32 ws2_32 wtsapi32".split())
WINDOWS_OS.update("authz d2d1 d3dcompiler_47 dinput8 dsound dwrite mmdevapi msasn1 msimg32 msvfw32 nsi uxtheme windowscodecs wsock32".split())
WINDOWS_GPU = {"nvcuda", "nvencodeapi", "nvencodeapi64", "nvcuvid", "nvapi", "nvapi64", "amfrt32", "amfrt64", "amdhip64", "vulkan-1", "opencl"}
BUILD_DIRS = {".git", ".svn", "build", "_build", "out", "output", "dist", "CMakeFiles", "meson-private", "meson-logs", "__pycache__"}
BUILD_SUFFIXES = {".o", ".obj", ".a", ".lib", ".dll", ".so", ".dylib", ".exe", ".pdb", ".pyc"}


def run(args, *, env=None, check=True):
    try:
        result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                errors="replace", env=env, timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PackageError(f"Cannot run {args[0]}: {exc}") from exc
    if check and result.returncode:
        raise PackageError(f"Command failed: {' '.join(map(str, args))}\n{result.stdout}\n{result.stderr}")
    return result


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def under(path, root):
    return path == root or root in path.parents


def clean_environment():
    env = os.environ.copy()
    for key in list(env):
        if key.upper().startswith(("LD_", "DYLD_")):
            del env[key]
    return env


def safe_relative(value):
    if not isinstance(value, str) or not value or "\\" in value:
        raise PackageError("Invalid manifest path")
    path = Path(value)
    if path.is_absolute() or value.startswith("/") or any(p in {"", ".", ".."} for p in value.split("/")) or ":" in value:
        raise PackageError(f"Unsafe manifest path: {value}")
    return path


def no_symlink_components(path):
    for parent in [path, *path.parents]:
        if parent.is_symlink() or (hasattr(parent, "is_junction") and parent.is_junction()):
            raise PackageError(f"Symlink/junction output component: {parent}")


def validate_output(output, protected=(), *, inspection=False):
    output = Path(os.path.abspath(output))
    no_symlink_components(output)
    resolved = output.resolve()
    if not inspection:
        forbidden = [Path.home().resolve(), Path.cwd().resolve(), Path(resolved.anchor)]
        if os.name == "nt":
            system_dirs = [Path(value).resolve() for key, value in os.environ.items()
                           if key.upper() in {"SYSTEMROOT", "PROGRAMFILES", "PROGRAMFILES(X86)"}]
        else:
            system_dirs = [Path(p) for p in ("/bin", "/sbin", "/usr", "/etc", "/lib", "/lib64", "/proc", "/sys", "/dev")]
        if resolved in forbidden or ".git" in resolved.parts or any(under(resolved, p) for p in system_dirs):
            raise PackageError(f"Unsafe output directory: {output}")
    for item in protected:
        item = Path(item).resolve()
        if under(item, resolved) or under(resolved, item):
            raise PackageError(f"Output overlaps an input: {item}")
    if output.exists() and not output.is_dir():
        raise PackageError("Output is not a directory")
    if not output.exists() or not any(output.iterdir()):
        return output, None
    try:
        marker = json.loads((output / MARKER).read_text(encoding="utf-8"))
        manifest = json.loads((output / MANIFEST).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise PackageError("Refusing unowned nonempty output directory") from exc
    if marker.get("tool") != TOOL or marker.get("schema") != 1 or not marker.get("id") or manifest.get("owner") != marker["id"]:
        raise PackageError("Output ownership marker and manifest do not match")
    entries = manifest.get("files")
    if not isinstance(entries, dict):
        raise PackageError("Invalid output manifest")
    allowed = {MARKER, MANIFEST}
    directories = set()
    for name, sha in entries.items():
        relative = safe_relative(name)
        allowed.add(relative.as_posix())
        directories.update(p.as_posix() for p in relative.parents if p != Path("."))
        file = output / relative
        if file.is_symlink() or not file.is_file() or digest(file) != sha:
            raise PackageError(f"Owned output has been modified: {name}")
    for file in output.rglob("*"):
        name = file.relative_to(output).as_posix()
        if file.is_symlink() or (hasattr(file, "is_junction") and file.is_junction()) or (not file.is_file() and not file.is_dir()) or (file.is_file() and name not in allowed) or (file.is_dir() and name not in directories):
            raise PackageError(f"Unowned entry in output: {name}")
    return output, manifest


def remove_owned(output, manifest):
    for name in [*manifest["files"], MARKER, MANIFEST]:
        (output / safe_relative(name)).unlink()
    for directory in sorted((p for p in output.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
        directory.rmdir()
    output.rmdir()


class Packager:
    def __init__(self, platform, bin_dir, output, source_dir, avm_prefix=None,
                 license_dirs=(), dependency_sources=(), local_only=False,
                 complete_source_dir=None):
        self.platform = platform
        self.local_only = local_only
        self.complete_source_dir = complete_source_dir
        self.bin_dir = Path(bin_dir).resolve()
        self.source = Path(source_dir).resolve()
        self.avm = Path(avm_prefix).resolve() if avm_prefix else None
        self.license_dirs = [Path(p).resolve() for p in license_dirs]
        self.dependency_sources = [Path(p).resolve() for p in dependency_sources]
        protected = [self.bin_dir, self.source, *self.license_dirs, *self.dependency_sources]
        if self.avm:
            protected.append(self.avm)
        self.output, self.previous = validate_output(output, protected)
        self.stage = self.output.parent / ("." + self.output.name + ".stage-" + uuid.uuid4().hex)
        self.copies = {}
        self.executables = []
        self.dependencies = []
        self.packages = {}
        self.static_links = []
        self.sources = []
        self.gaps = []
        self.inventory = None
        self.inventory_root = None
        self.inventory_modules = set()
        self.built_here = set()
        self.owner = uuid.uuid4().hex

    def copy(self, source, relative):
        source = Path(source).resolve()
        target = self.stage / safe_relative(relative)
        key = relative.casefold()
        sha = digest(source)
        if key in self.copies:
            if self.copies[key][1] != sha or not target.exists():
                raise PackageError(f"Dependency/name collision: {relative}: {source} and {self.copies[key][0]}")
            return target
        if target.exists():
            raise PackageError(f"Destination collision: {relative}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        self.copies[key] = (str(source), sha)
        return target

    def license_tree(self, source, label):
        source = Path(source)
        if not source.is_dir():
            raise PackageError(f"Missing license directory: {source}")
        count = 0
        for root, dirs, names in os.walk(source, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in BUILD_DIRS and not (Path(root) / d).is_symlink())
            for name in sorted(names):
                path = Path(root) / name
                if path.is_symlink() or not path.is_file():
                    continue
                if LICENSE_RE.match(name) or name.lower() in {"vcpkg.json", "vcpkg.spdx.json", "spdx.json", "control"}:
                    self.copy(path, f"licenses/{label}/{path.relative_to(source).as_posix()}")
                    count += 1
        return count

    def metadata_attribution(self, root):
        """Read vcpkg SPDX without treating licenses as source delivery."""
        for path in sorted(Path(root).rglob("vcpkg.spdx.json")):
            if path.is_symlink() or not under(path.resolve(), Path(root).resolve()):
                continue
            try:
                metadata = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise PackageError(f"Invalid SPDX attribution: {path}: {exc}") from exc
            for entry in metadata.get("packages", []):
                name = entry.get("name")
                version = entry.get("versionInfo", "unknown")
                if not isinstance(name, str):
                    continue
                key = "vcpkg:" + name + "@" + str(version)
                location = entry.get("downloadLocation", "")
                urls = [location] if isinstance(location, str) and location.startswith(("https://", "http://")) else []
                self.packages[key] = {"manager": "vcpkg", "package": name, "version": version,
                                      "source_urls": urls, "license": entry.get("licenseConcluded", entry.get("licenseDeclared", "NOASSERTION")),
                                      "patches": "SPDX/port metadata identifies inputs; full matching port sources and patches require review.",
                                      "corresponding_source": "not-included"}
        if not any(key.startswith("vcpkg:") for key in self.packages):
            self.gaps.append(f"License root {Path(root).name}: package version/source attribution absent unless supplied by source archive.")

    def required_inputs(self):
        if not self.source.is_dir():
            raise PackageError(f"Missing FFmpeg source: {self.source}")
        for name in ("LICENSE.md", "COPYING.GPLv3"):
            if not (self.source / name).is_file():
                raise PackageError(f"Missing FFmpeg license: {name}")
        extension = ".exe" if self.platform == "windows" else ""
        inputs = [(self.bin_dir / (n + extension), n + extension) for n in ("ffmpeg", "ffprobe", "ffplay")]
        if self.avm:
            inputs += [(self.avm / "bin" / (n + extension), n + extension) for n in ("avmenc", "avmdec")]
            for name in ("LICENSE", "PATENTS"):
                if not (self.avm / "licenses" / "avm" / name).is_file():
                    raise PackageError(f"Missing AVM license/patent metadata: {name}")
        for path, name in inputs:
            if not path.is_file():
                raise PackageError(f"Missing required binary: {path}")
        return inputs

    def elf_metadata(self, path):
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                raise PackageError(f"Not an ELF file: {path}")
        dynamic = run(["readelf", "-d", str(path)], env=clean_environment()).stdout
        needed = re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic)
        for name in needed:
            if "/" in name or "\\" in name or not re.match(r"^[A-Za-z0-9_.+-]+$", name):
                raise PackageError(f"Unsafe DT_NEEDED name: {name}")
        program = run(["readelf", "-l", str(path)], env=clean_environment()).stdout
        interpreters = re.findall(r"Requesting program interpreter:\s*([^\]]+)\]", program)
        for interpreter in interpreters:
            if ".." in Path(interpreter).parts or not LINUX_BASE.fullmatch(Path(interpreter).name) or not str(interpreter).startswith(("/lib/", "/lib64/", "/usr/lib/", "/usr/lib64/")):
                raise PackageError(f"Unsafe ELF interpreter (ldd could execute it): {interpreter}")
        return needed

    def linux_dependencies(self):
        queue = [(src, dest) for src, dest in self.executables]
        visited = set()
        patches = []
        while queue:
            source, target = queue.pop(0)
            key = (str(source), str(target))
            if key in visited:
                continue
            visited.add(key)
            needed = self.elf_metadata(source)
            if not needed:
                if target.parent.name == "lib":
                    patches.append(target)
                continue
            env = clean_environment()
            search = [str(self.stage / "lib"), str(source.parent), str(source.parent.parent / "lib")]
            env["LD_LIBRARY_PATH"] = os.pathsep.join(search)
            ldd_result = run(["ldd", str(source)], env=env, check=False)
            listing = ldd_result.stdout + ldd_result.stderr
            if ldd_result.returncode:
                raise PackageError(f"Linux dependency inspection failed: {source}\n{listing}")
            resolved = {}
            for line in listing.splitlines():
                match = re.match(r"\s*(\S+)\s+=>\s+(.+?)\s+\(0x[0-9a-fA-F]+\)\s*$", line)
                if match:
                    resolved[match[1]] = Path(match[2])
            patches.append(target)
            for name in needed:
                if LINUX_BASE.fullmatch(name) or LINUX_GPU.fullmatch(name):
                    self.dependencies.append({"from": target.relative_to(self.stage).as_posix(), "name": name,
                                              "disposition": "external-base-os" if LINUX_BASE.fullmatch(name) else "external-gpu-driver"})
                    continue
                path = resolved.get(name)
                if path is None:
                    path = self.stage / "lib" / name
                if not path.is_file():
                    raise PackageError(f"Unresolved Linux dependency: {source}: {name}\n{listing}")
                path = path.resolve()
                # Reuse original bytes, not a previously relocated library.
                previous = self.copies.get(("lib/" + name).casefold())
                if under(path, self.stage) and previous:
                    path = Path(previous[0])
                destination = self.copy(path, "lib/" + name)
                self.dependencies.append({"from": target.relative_to(self.stage).as_posix(), "name": name,
                                          "source": str(path), "disposition": "bundled"})
                self.dpkg_attribution(path)
                queue.append((path, destination))
        for target in dict.fromkeys(patches):
            run(["patchelf", "--set-rpath", "$ORIGIN" if target.parent.name == "lib" else "$ORIGIN/lib", str(target)])

    @staticmethod
    def mac_system(value):
        return value.startswith(("/System/Library/", "/usr/lib/"))

    def mac_metadata(self, source):
        with source.open("rb") as stream:
            if stream.read(4) not in {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}:
                raise PackageError(f"Not a Mach-O file: {source}")
        listing = run(["otool", "-L", str(source)]).stdout
        deps = re.findall(r"^\s+(.+?)\s+\(compatibility version", listing, re.M)
        ids = run(["otool", "-D", str(source)], check=False).stdout.splitlines()[1:]
        deps = [d for d in deps if d not in {s.strip() for s in ids}]
        commands = run(["otool", "-l", str(source)]).stdout
        rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)", commands)
        return deps, rpaths

    @staticmethod
    def expand_mac(value, source, executable):
        if value == "@loader_path" or value.startswith("@loader_path/"):
            return source.parent / value.removeprefix("@loader_path").lstrip("/")
        if value == "@executable_path" or value.startswith("@executable_path/"):
            return executable.parent / value.removeprefix("@executable_path").lstrip("/")
        if value.startswith("@"):
            return None
        return Path(value) if Path(value).is_absolute() else None

    def macos_dependencies(self):
        queue = [(s, d, s, ()) for s, d in self.executables]
        visited = set()
        mutations = {}
        while queue:
            source, target, executable, inherited = queue.pop(0)
            key = (str(source), str(target), str(executable), inherited)
            if key in visited:
                continue
            visited.add(key)
            deps, raw_rpaths = self.mac_metadata(source)
            local = [self.expand_mac(p, source, executable) for p in raw_rpaths]
            search = tuple(dict.fromkeys(str(p.resolve()) for p in local if p is not None))
            search = tuple(dict.fromkeys((*search, *inherited)))
            rewrite = mutations.setdefault(target, {"rpaths": raw_rpaths, "deps": {}})
            for dep in deps:
                if self.mac_system(dep):
                    self.dependencies.append({"from": target.relative_to(self.stage).as_posix(), "name": dep, "disposition": "external-base-os"})
                    continue
                candidates = []
                if dep.startswith("@rpath/"):
                    candidates = [Path(p) / dep.removeprefix("@rpath/") for p in search]
                else:
                    expanded = self.expand_mac(dep, source, executable)
                    if expanded:
                        candidates = [expanded]
                path = next((p.resolve() for p in candidates if p.is_file()), None)
                if path is None and dep.startswith("@rpath/"):
                    # AVM can share an already-collected @rpath dependency.
                    name = Path(dep).name
                    known = self.copies.get(("lib/" + name).casefold())
                    if known:
                        path = Path(known[0])
                if path is None:
                    raise PackageError(f"Unresolved macOS dependency: {source}: {dep}; rpaths={search}")
                if self.mac_system(str(path)):
                    rewrite["deps"][dep] = str(path)
                    continue
                if any(part.endswith(".framework") for part in path.parts) or ".framework/" in dep.replace("\\", "/"):
                    raise PackageError(f"External frameworks require explicit framework packaging: {dep}")
                name = path.name
                if not re.match(r"^[A-Za-z0-9_.+-]+$", name):
                    raise PackageError(f"Unsafe dylib name: {name}")
                destination = self.copy(path, "lib/" + name)
                replacement = ("@loader_path/" if target.parent.name == "lib" else "@loader_path/lib/") + name
                old = rewrite["deps"].get(dep)
                if old is not None and old != replacement:
                    raise PackageError(f"Ambiguous macOS dependency: {dep}")
                rewrite["deps"][dep] = replacement
                self.dependencies.append({"from": target.relative_to(self.stage).as_posix(), "name": dep,
                                          "source": str(path), "disposition": "bundled"})
                self.brew_attribution(path)
                queue.append((path, destination, executable, search))
        for target, changes in mutations.items():
            if target.parent.name == "lib":
                run(["install_name_tool", "-id", "@rpath/" + target.name, str(target)])
            for old, new in changes["deps"].items():
                run(["install_name_tool", "-change", old, new, str(target)])
            for old in dict.fromkeys(changes["rpaths"]):
                run(["install_name_tool", "-delete_rpath", old, str(target)])
            run(["install_name_tool", "-add_rpath", "@loader_path" if target.parent.name == "lib" else "@loader_path/lib", str(target)])
        libraries = [p for p in mutations if p.parent.name == "lib"]
        for target in [*libraries, *(d for _, d in self.executables)]:
            run(["codesign", "--force", "--sign", "-", str(target)])

    def windows_dependencies(self):
        inspector = shutil.which("dumpbin") or shutil.which("dumpbin.exe")
        objdump = shutil.which("objdump") or shutil.which("llvm-objdump")
        if not inspector and not objdump:
            raise PackageError("Windows static import audit requires dumpbin or objdump")
        for source, target in self.executables:
            with source.open("rb") as stream:
                if stream.read(2) != b"MZ":
                    raise PackageError(f"Not a PE executable: {source}")
            if inspector:
                text = run([inspector, "/DEPENDENTS", str(source)]).stdout
                if "dependencies" not in text.lower() and "image has" not in text.lower():
                    raise PackageError(f"Unrecognized dumpbin dependency output: {source}")
                # IMPORTS includes normal and delay-load import tables. Do not
                # mistake an empty normal import table for a static executable.
                imports = run([inspector, "/IMPORTS", str(source)]).stdout
                names = re.findall(r"^\s+([A-Za-z0-9_.+-]+\.dll)\s*$", text + "\n" + imports, re.M | re.I)
            else:
                text = run([objdump, "-p", str(source)]).stdout
                names = re.findall(r"DLL Name:\s*(\S+)", text, re.I)
                if "file format pei-" not in text and "file format pe-" not in text and "file format coff-" not in text:
                    raise PackageError(f"Unrecognized objdump PE output: {source}")
                delay = re.search(r"^\s*Entry\s+d\s+([0-9a-f]+)\s+([0-9a-f]+).*Delay Import", text, re.I | re.M)
                if delay and (int(delay[1], 16) or int(delay[2], 16)):
                    raise PackageError(f"Delay-load DLL table requires dumpbin /IMPORTS audit: {source}")
            for name in dict.fromkeys(names):
                stem = name.lower().removesuffix(".dll")
                if stem in WINDOWS_OS or stem.startswith(("api-ms-win-", "ext-ms-win-")):
                    disposition = "external-base-os"
                elif stem in WINDOWS_GPU:
                    disposition = "external-gpu-driver"
                else:
                    raise PackageError(f"Non-system Windows DLL import; rebuild static /MT: {source}: {name}")
                self.dependencies.append({"from": target.name, "name": name, "disposition": disposition})

    def dpkg_attribution(self, path):
        if not shutil.which("dpkg-query"):
            self.gaps.append(f"No dpkg attribution for {path}")
            return
        candidates = [Path(path)]
        text = str(path)
        if text.startswith("/usr/lib/"):
            candidates.append(Path(text.removeprefix("/usr")))
        match = None
        for candidate in candidates:
            result = run(["dpkg-query", "-S", str(candidate)], check=False)
            if result.returncode == 0:
                match = re.search(r"^(.+?):\s+/", result.stdout, re.M)
                if match:
                    break
        if not match:
            self.gaps.append(f"Unattributed dependency: {path}")
            return
        package = match[1].split(", ")[0]
        if not re.match(r"^[A-Za-z0-9.+:-]+$", package):
            raise PackageError("Invalid dpkg package name")
        if package in self.packages:
            return
        fields = "${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\t${Homepage}\n"
        result = run(["dpkg-query", "-W", "-f=" + fields, package])
        values = result.stdout.strip().split("\t")
        record = {"manager": "dpkg", "package": package, "version": values[1] if len(values) > 1 else "unknown",
                  "source_package": values[2] if len(values) > 2 else package,
                  "source_version": values[3] if len(values) > 3 else "unknown",
                  "source_urls": [values[4]] if len(values) > 4 and values[4] else [],
                  "patches": "Distribution patches are in the matching source package; not included automatically.",
                  "corresponding_source": "not-included"}
        doc = Path("/usr/share/doc") / package.split(":")[0]
        copyright_file = doc / "copyright"
        if copyright_file.is_file():
            if not any(under(copyright_file.resolve(), root.resolve()) for root in (Path("/usr/share/doc"), Path("/usr/share/common-licenses"))):
                raise PackageError(f"Unsafe package copyright symlink: {copyright_file}")
            self.copy(copyright_file, f"licenses/dpkg/{package.replace(':', '_')}/copyright")
            copyright_text = copyright_file.read_text(encoding="utf-8", errors="replace")
            record["source_urls"] += re.findall(r"^Source:\s*(https?://\S+)", copyright_text, re.M)
        else:
            self.gaps.append(f"Missing copyright metadata for {package}")
        self.packages[package] = record

    def brew_attribution(self, path):
        path = Path(path).resolve()
        parts = path.parts
        if "Cellar" not in parts:
            self.gaps.append(f"Non-Homebrew dependency requires source/license attribution: {path}")
            return
        index = parts.index("Cellar")
        if len(parts) < index + 3:
            raise PackageError(f"Invalid Homebrew dependency path: {path}")
        name, version = parts[index + 1:index + 3]
        key = "brew:" + name + "@" + version
        if key in self.packages:
            return
        root = Path(*parts[:index + 3])
        record = {"manager": "homebrew", "package": name, "version": version,
                  "source_urls": [], "license": "See original source/formula license metadata; no redistribution compatibility assertion.",
                  "patches": "See included formula; source and external patches may be absent.",
                  "corresponding_source": "not-included"}
        self.license_tree(root, "homebrew/" + name + "/" + version)
        receipt = root / "INSTALL_RECEIPT.json"
        if receipt.is_file():
            self.copy(receipt, f"licenses/homebrew/{name}/{version}/INSTALL_RECEIPT.json")
        formula = root / ".brew" / (name + ".rb")
        if formula.is_file():
            self.copy(formula, f"licenses/homebrew/{name}/{version}/formula.rb")
            record["source_urls"] = re.findall(r"(?:url|mirror)\s+\"(https?://[^\"]+)\"", formula.read_text(encoding="utf-8", errors="replace"))
        self.packages[key] = record

    def source_status(self):
        if self.local_only:
            return "not-for-distribution"
        if self.inventory is not None and not self.gaps:
            return "complete"
        return "review-required"

    def verify_source_coverage(self):
        """Every statically linked external module must have collected source."""
        if self.inventory is None:
            return
        missing = [entry["module"] for entry in self.static_links
                   if entry["module"] not in self.inventory_modules
                   and entry["module"] not in self.built_here]
        if missing:
            raise PackageError("Dependency source is missing for: " + ", ".join(missing))

    def static_attribution(self):
        # Build flags provide discovery hints, not proof of a complete link closure.
        configuration_result = run([str(self.stage / ("ffmpeg.exe" if self.platform == "windows" else "ffmpeg")), "-buildconf"], env=clean_environment())
        configuration = configuration_result.stdout + configuration_result.stderr
        self.configuration = configuration
        self.copy_text("metadata/ffmpeg-buildconf.txt", configuration)
        features = sorted(set(re.findall(r"--enable-(lib[A-Za-z0-9_-]+)", configuration)))
        mapping = {"libjxl": "libjxl libjxl_threads", "libvmaf": "libvmaf", "libx264": "x264", "libx265": "x265", "libaom": "aom", "libdav1d": "dav1d", "libsvtav1": "SvtAv1Enc", "libopus": "opus", "libvorbis": "vorbis vorbisenc", "libass": "libass", "libfreetype": "freetype2", "libfontconfig": "fontconfig", "libharfbuzz": "harfbuzz", "libfribidi": "fribidi", "libzimg": "zimg", "libvpx": "vpx", "libwebp": "libwebp", "libopenjpeg": "libopenjp2", "libmp3lame": "lame", "libsoxr": "soxr", "libspeex": "speex", "libbluray": "libbluray", "libplacebo": "libplacebo", "libxml2": "libxml-2.0", "libvidstab": "vidstab"}
        nonfree = bool(re.search(r"--enable-nonfree\b|non[- ]?free|unredistributable|not (?:legally )?redistributable", configuration, re.I))
        if nonfree and not self.local_only:
            raise PackageError("FFmpeg is nonfree/unredistributable; refusing redistribution")
        if self.local_only and not nonfree:
            raise PackageError("Local-only packaging requires a nonfree FFmpeg build")
        license_result = run([str(self.stage / ("ffmpeg.exe" if self.platform == "windows" else "ffmpeg")), "-hide_banner", "-L"], env=clean_environment())
        license_output = license_result.stdout + license_result.stderr
        if re.search(r"non[- ]?free|unredistributable|not (?:legally )?redistributable", license_output, re.I) and not self.local_only:
            raise PackageError("FFmpeg license forbids redistribution")
        if not self.local_only and not re.search(r"GNU (?:Lesser )?General Public License", license_output, re.I):
            raise PackageError("FFmpeg license output could not be verified")
        self.copy_text("metadata/ffmpeg-license-output.txt", license_output)
        if self.platform == "windows":
            self.gaps.append("Static vcpkg/custom dependencies require matching source archives and patches; share metadata is attribution only.")
            return
        if not shutil.which("pkg-config"):
            self.gaps.append("pkg-config absent: static dependency package/source attribution is incomplete.")
            return
        modules = set()
        for feature in features:
            modules.update(mapping.get(feature, feature).split())
        # FFmpeg's optional/compression/SDL dependencies may not use enable-lib flags.
        for module in ("zlib", "liblzma", "bzip2", "sdl2"):
            if run(["pkg-config", "--exists", module], check=False).returncode == 0:
                modules.add(module)
        queue = sorted(modules)
        seen = set()
        while queue:
            module = queue.pop(0)
            if module in seen:
                continue
            seen.add(module)
            query = run(["pkg-config", "--variable=pcfiledir", module], check=False)
            directory = query.stdout.strip()
            if query.returncode or not directory:
                self.gaps.append(f"No static package attribution for pkg-config module {module}")
                continue
            pcfile = Path(directory) / (module + ".pc")
            version = run(["pkg-config", "--modversion", module], check=False).stdout.strip()
            link_result = run(["pkg-config", "--libs", "--static", module], check=False)
            libs = link_result.stdout.strip()
            self.static_links.append({"module": module, "version": version or "unknown", "link_flags": libs})
            if pcfile.is_file():
                self.copy(pcfile, f"metadata/pkg-config/{module}.pc")
                try:
                    local_build = Path(directory).resolve().is_relative_to(self.bin_dir.parent.resolve())
                except (OSError, ValueError):
                    local_build = False
                if local_build:
                    # VMAF and zimg are built here; their source is archived separately.
                    self.built_here.add(module)
                elif self.platform == "linux":
                    self.dpkg_attribution(pcfile)
                else:
                    self.brew_attribution(pcfile)
            libdir = run(["pkg-config", "--variable=libdir", module], check=False).stdout.strip()
            directories = [Path(libdir)] if libdir else []
            directories += [Path(match.group(1) or match.group(2))
                            for match in re.finditer(r'(?:^|\s)-L(?:"([^"]+)"|([^\s]+))', libs)]
            for name in re.findall(r"(?:^|\s)-l([A-Za-z0-9_.+-]+)", libs):
                library = next((d / ("lib" + name + suffix) for d in dict.fromkeys(directories)
                                for suffix in (".a", ".dylib", ".so") if (d / ("lib" + name + suffix)).is_file()), None)
                if library:
                    if self.platform == "linux":
                        self.dpkg_attribution(library.resolve())
                    else:
                        self.brew_attribution(library.resolve())
            for option in ("--print-requires", "--print-requires-private"):
                result = run(["pkg-config", option, module], check=False)
                for line in result.stdout.splitlines():
                    name = line.split()[0] if line.split() else ""
                    if re.fullmatch(r"[A-Za-z0-9_.+-]+", name):
                        queue.append(name)

    def copy_text(self, relative, content):
        target = self.stage / safe_relative(relative)
        if target.exists():
            raise PackageError(f"Metadata collision: {relative}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def git_source_files(self, root, selected=None):
        files, submodules = [], []

        def wanted(relative):
            return not selected or any(relative == Path(s) or Path(s) in relative.parents
                                       or relative in Path(s).parents for s in selected)

        def collect(repository, prefix=Path(".")):
            listed = run(["git", "-C", str(repository), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).stdout
            files.extend(prefix / safe_relative(p) for p in listed.split("\0") if p)
            index = run(["git", "-C", str(repository), "ls-files", "--stage", "-z"]).stdout
            for entry in index.split("\0"):
                if not entry.startswith("160000 "):
                    continue
                header, separator, name = entry.partition("\t")
                fields = header.split()
                if not separator or len(fields) != 3 or fields[2] != "0":
                    raise PackageError(f"Unmerged/invalid submodule index entry: {entry}")
                relative = safe_relative(name)
                archive_relative = prefix / relative
                if not wanted(archive_relative) or any(part in BUILD_DIRS for part in archive_relative.parts):
                    continue
                child = repository / relative
                if (not child.is_dir() or not under(child.resolve(), root)
                        or any(p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction())
                               for p in [child, *child.parents] if under(p, root))):
                    raise PackageError(f"Missing or unsafe source submodule: {archive_relative}")
                top = run(["git", "-C", str(child), "rev-parse", "--show-toplevel"], check=False)
                if top.returncode or Path(top.stdout.strip()).resolve() != child.resolve():
                    raise PackageError(f"Uninitialized source submodule: {archive_relative}; initialize it before packaging")
                sha = run(["git", "-C", str(child), "rev-parse", "HEAD"]).stdout.strip()
                dirty = bool(run(["git", "-C", str(child), "status", "--porcelain", "--untracked-files=normal"]).stdout.strip())
                submodules.append({"path": archive_relative.as_posix(), "gitlink_sha": fields[1],
                                   "git_sha": sha, "modified_worktree": dirty})
                collect(child, archive_relative)

        collect(root)
        return files, submodules

    def archive_source(self, root, label, selected=None):
        root = Path(root).resolve()
        if not root.is_dir():
            raise PackageError(f"Missing dependency source: {root}")
        sha, dirty, urls = None, None, []
        files = None
        submodules = []
        if shutil.which("git"):
            top = run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], check=False)
            if top.returncode == 0 and Path(top.stdout.strip()).resolve() == root:
                sha = run(["git", "-C", str(root), "rev-parse", "HEAD"]).stdout.strip()
                dirty = bool(run(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=normal", "--", *(selected or ())]).stdout.strip())
                remote = run(["git", "-C", str(root), "remote", "get-url", "origin"], check=False).stdout.strip()
                # Do not publish embedded remote credentials or private local paths.
                if re.match(r"^https://[^/@\s]+/", remote):
                    urls = [remote.split("?")[0].split("#")[0]]
                files, submodules = self.git_source_files(root, selected)
                diff = run(["git", "-C", str(root), "diff", "--no-ext-diff", "--binary", "HEAD", "--", *(selected or ())]).stdout
                self.copy_text(f"sources/{label}.patch", diff)
        if files is None:
            files = [p.relative_to(root) for p in root.rglob("*") if p.is_file() and not any(part in BUILD_DIRS for part in p.relative_to(root).parts)]
            self.gaps.append(f"Source {label}: git provenance unavailable; filtered source tree archived.")
        if selected:
            files = [p for p in files if any(p == Path(s) or Path(s) in p.parents for s in selected)]
        archive = self.stage / "sources" / (label + ".tar.gz")
        archive.parent.mkdir(parents=True, exist_ok=True)
        included = 0
        omitted = []
        with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as tar:
            for relative in sorted(set(files)):
                relative = safe_relative(relative.as_posix())
                path = root / relative
                if any(part in BUILD_DIRS for part in relative.parts) or path.suffix.lower() in BUILD_SUFFIXES or re.search(r"\.so\.\d", path.name):
                    continue
                if path.is_symlink() or not under(path.resolve(), root) or any((root / parent).is_symlink() for parent in relative.parents if parent != Path(".")):
                    omitted.append(relative.as_posix())
                    continue
                if not path.is_file():
                    continue
                # Archive working-tree bytes, including tracked local patches.
                tar.add(path, arcname=label + "/" + relative.as_posix(), recursive=False)
                included += 1
        self.sources.append({"name": label, "archive": "sources/" + archive.name,
                             "patch_file": f"sources/{label}.patch" if sha else None,
                             "git_sha": sha, "modified_worktree": dirty, "source_urls": urls,
                             "submodules": submodules,
                             "files": included, "omitted_symlinks": omitted,
                             "patches": "Tracked modifications are incorporated in the archive; build scripts are included separately."})
        if omitted:
            self.gaps.append(f"Source {label}: symlinks omitted; review corresponding-source completeness.")

    def complete_source_inventory(self, directory):
        """Load and validate the collected dependency-source inventory."""
        root = Path(directory).resolve()
        inventory_path = root / "source-inventory.json"
        if not inventory_path.is_file():
            raise PackageError(f"Missing dependency-source inventory: {inventory_path}")
        try:
            inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise PackageError(f"Invalid dependency-source inventory: {exc}") from exc
        if inventory.get("schema") != 1:
            raise PackageError("Unsupported dependency-source inventory schema")
        if inventory.get("platform") != self.platform:
            raise PackageError("Dependency-source inventory platform does not match the package")
        coverage = inventory.get("coverage")
        if not isinstance(coverage, dict) or not isinstance(coverage.get("omissions"), list):
            raise PackageError("Invalid dependency-source coverage data")
        if not inventory.get("complete"):
            raise PackageError("Dependency-source inventory is incomplete: "
                               + "; ".join(coverage.get("omissions", [])[:10]))
        packages = inventory.get("packages")
        if not isinstance(packages, list) or not packages:
            raise PackageError("Dependency-source inventory contains no packages")
        provided = set(coverage.get("provided", []))
        for record in packages:
            for name, expected in (record.get("files") or {}).items():
                relative = safe_relative(name)
                path = root / relative
                if not path.is_file():
                    raise PackageError(f"Dependency source file is missing: {name}")
                if digest(path) != expected:
                    raise PackageError(f"Dependency source file was modified: {name}")
        self.inventory = inventory
        self.inventory_root = root
        self.inventory_modules = provided
        return inventory

    def stage_complete_sources(self, directory):
        """Copy the collected dependency sources into the package."""
        inventory = self.complete_source_inventory(directory)
        for record in inventory["packages"]:
            label = re.sub(r"[^A-Za-z0-9_.-]", "_", record["id"])
            for name in (record.get("files") or {}):
                relative = safe_relative(name).as_posix()
                source = self.inventory_root / relative
                self.copy(source, f"sources/dependencies/{label}/{relative}")
        self.copy_text("metadata/dependency-source-inventory.json",
                       json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")

    def source_metadata(self):
        self.archive_source(self.source, "ffmpeg")
        roots = list(self.dependency_sources)
        for name in ("vmaf", "vmaf-compat", "nv-codec-headers", "AMF", "amf", "zimg"):
            candidate = self.source.parent / name
            if candidate.is_dir():
                roots.append(candidate)
        if self.avm:
            for candidate in (self.avm.parent / "avm", self.avm.parent / "avm-src", self.avm.parent / "source"):
                if candidate.is_dir() and candidate != self.avm:
                    roots.append(candidate)
        unique = list(dict.fromkeys(p.resolve() for p in roots))
        labels = {"ffmpeg"}
        for root in unique:
            label = re.sub(r"[^A-Za-z0-9_.-]", "_", root.name)
            if label.casefold() in {n.casefold() for n in labels}:
                label += "-" + hashlib.sha256(str(root).encode()).hexdigest()[:8]
            labels.add(label)
            self.archive_source(root, label)
            self.license_tree(root, "source/" + label)
        repository = Path(__file__).resolve().parents[2]
        self.archive_source(repository, "build-scripts", selected=("scripts", ".github/workflows"))
        if self.inventory is None:
            self.gaps.append("Complete corresponding-source coverage is NOT certified: audit all static/transitive dependencies, package-manager sources, external patches, generated inputs and build instructions before GPL distribution.")
        if self.avm and not any("avm" in record["name"].lower() for record in self.sources):
            self.gaps.append("AVM corresponding source archive missing; pass --dependency-source AVM_SOURCE.")

    def package(self):
        if self.complete_source_dir:
            self.stage_complete_sources(self.complete_source_dir)
        inputs = self.required_inputs()
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.stage.mkdir()
        try:
            for source, name in inputs:
                destination = self.copy(source, name)
                self.executables.append((source.resolve(), destination))
            self.license_tree(self.source, "ffmpeg")
            if self.avm:
                self.license_tree(self.avm / "licenses", "avm-prefix")
            automatic = self.bin_dir.parent / "share"
            roots = list(self.license_dirs)
            if automatic.is_dir() and automatic not in roots:
                roots.insert(0, automatic)
            for index, root in enumerate(roots):
                self.license_tree(root, f"dependency-{index}-{root.name}")
                self.metadata_attribution(root)
            getattr(self, self.platform + "_dependencies")()
            self.static_attribution()
            self.source_metadata()
            self.verify_source_coverage()
            marker = {"tool": TOOL, "schema": 1, "id": self.owner}
            self.copy_text(MARKER, json.dumps(marker, indent=2) + "\n")
            files = {p.relative_to(self.stage).as_posix(): digest(p) for p in sorted(self.stage.rglob("*")) if p.is_file() and p.name != MARKER}
            manifest = {"schema": 1, "owner": self.owner, "platform": self.platform,
                        "binaries": [d.name for _, d in self.executables], "files": files,
                        "dependencies": self.dependencies, "packages": list(self.packages.values()),
                        "static_link_metadata": self.static_links,
                        "sources": self.sources, "distribution": "local-only-unredistributable" if self.local_only else "public",
                        "corresponding_source": {"status": self.source_status(),
                                                 "gaps": sorted(set(self.gaps))},
                        "dependency_source_inventory": self.inventory,
                        "windows_crt_policy": "non-OS DLL imports rejected; /MT is a build requirement" if self.platform == "windows" else None}
            self.copy_text(MANIFEST, json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
            # Revalidate immediately before replacing, including user-added entries.
            _, current = validate_output(self.output, [self.bin_dir, self.source])
            if current != self.previous:
                raise PackageError("Output ownership changed during packaging; refusing to overwrite")
            if current:
                remove_owned(self.output, current)
            elif self.output.exists():
                self.output.rmdir()
            self.stage.rename(self.output)
            print(f"Packaged {len(inputs)} binaries, {len(files)} files: {self.output}")
            if self.local_only:
                print("LOCAL-ONLY — nonfree/unredistributable; do not publish or redistribute.")
            return manifest
        finally:
            if self.stage.exists():
                # This unique, newly-created staging directory is wholly ours.
                shutil.rmtree(self.stage)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("linux", "macos", "windows"))
    parser.add_argument("--bin-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--avm-prefix")
    parser.add_argument("--license-dir", action="append", default=[])
    parser.add_argument("--dependency-source", action="append", default=[])
    parser.add_argument("--local-only", action="store_true",
                        help="Stage unredistributable nonfree binaries for private local use only")
    parser.add_argument("--complete-source-dir",
                        help="Directory produced by collect-dependency-sources.py")
    args = parser.parse_args(argv)
    try:
        Packager(args.platform, args.bin_dir, args.output, args.source_dir, args.avm_prefix,
                 args.license_dir, args.dependency_source, args.local_only,
                 args.complete_source_dir).package()
    except (PackageError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
