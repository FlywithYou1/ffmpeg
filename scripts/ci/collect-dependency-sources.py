#!/usr/bin/env python3
"""Collect the exact upstream source of every dependency linked into FFmpeg.

Usage: collect-dependency-sources.py --platform linux|macos|windows
    --output DIRECTORY --source-dir FFMPEG_SOURCE --install-root PREFIX
    [--vcpkg-root DIR] [--vcpkg-installed DIR] [--manifest-root DIR]

The output directory receives the collected sources plus ``source-inventory.json``:
a manifest of every package, the pkg-config modules it satisfies and the
SHA-256 of every stored file. ``package-runtime.py`` refuses to publish a
package whose inventory is incomplete, and ``verify-runtime.py`` re-checks the
inventory after the package was moved.

Only real, verified sources are recorded. A dependency that cannot be located
is an omission, and an omission makes the whole inventory incomplete.
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
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dependency_modules import features_from_buildconf, required_modules  # noqa: E402

INVENTORY = "source-inventory.json"
SCHEMA = 1
USER_AGENT = "ffmpeg-multi-vendor-build/1.0"


class CollectError(RuntimeError):
    pass


def run(args, *, env=None, cwd=None, check=True, timeout=1800):
    try:
        result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                encoding="utf-8", errors="replace", env=env,
                                cwd=cwd, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CollectError(f"Cannot run {args[0]}: {exc}") from exc
    if check and result.returncode:
        raise CollectError(f"Command failed ({result.returncode}): {' '.join(map(str, args))}\n{result.stdout}")
    return result


def digest(path, algorithm="sha256"):
    hasher = hashlib.new(algorithm)
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def download(url, target, algorithm, expected):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=600) as response, Path(target).open("wb") as stream:
        shutil.copyfileobj(response, stream)
    actual = digest(target, algorithm)
    if expected and actual.lower() != expected.lower():
        Path(target).unlink()
        raise CollectError(f"Checksum mismatch for {url}: expected {expected}, got {actual}")
    return actual


def build_configuration(ffmpeg_binary, source_dir):
    """Return the configure command line recorded in the build."""
    binary = Path(ffmpeg_binary)
    if binary.is_file():
        result = run([binary, "-buildconf"], check=False, timeout=120)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout
    config = Path(source_dir) / "ffbuild" / "config.mak"
    if config.is_file():
        text = config.read_text(encoding="utf-8", errors="replace")
        if "--enable-" in text:
            return text
    raise CollectError("Cannot determine the FFmpeg build configuration")


def collect_required(pkg_config, modules):
    """Expand the module list with the transitive pkg-config requirements."""
    seen = list(modules)
    queue = list(modules)
    while queue:
        module = queue.pop(0)
        for option in ("--print-requires", "--print-requires-private"):
            result = run([pkg_config, option, module], check=False, timeout=60)
            for line in result.stdout.splitlines():
                name = line.split()[0] if line.split() else ""
                if re.fullmatch(r"[A-Za-z0-9_.+-]+", name) and name not in seen:
                    seen.append(name)
                    queue.append(name)
    return sorted(seen)


def resolve_modules(pkg_config, modules, install_root):
    """Resolve modules to their .pc location, skipping locally built ones."""
    resolved = []
    root = Path(install_root).resolve()
    for module in modules:
        query = run([pkg_config, "--variable=pcfiledir", module], check=False, timeout=60)
        directory = query.stdout.strip()
        if query.returncode or not directory:
            continue
        path = Path(directory) / (module + ".pc")
        if not path.is_file():
            continue
        try:
            inside = Path(directory).resolve().is_relative_to(root)
        except (OSError, ValueError):
            inside = False
        if inside:
            # Built by this project (VMAF, zimg); its source is archived already.
            continue
        version = run([pkg_config, "--modversion", module], check=False, timeout=60).stdout.strip()
        resolved.append({"module": module, "pcfile": str(path), "version": version or "unknown"})
    return resolved


def store_tree(root, source, destination):
    """Copy a directory tree, keeping only regular files."""
    source = Path(source)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    stored = []
    for path in sorted(source.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        stored.append(target)
    return stored


def record_files(record, root, files):
    for path in files:
        relative = Path(path).relative_to(root).as_posix()
        record["files"][relative] = digest(path)


# ---------------------------------------------------------------- Linux (apt)

def write_privileged(path, text):
    """Write a file that may live under a root-owned directory (for example /etc/apt)."""
    try:
        path.write_text(text, encoding="utf-8")
        return
    except PermissionError:
        pass
    process = subprocess.run(["sudo", "tee", str(path)], input=text, text=True,
                             encoding="utf-8", stdout=subprocess.DEVNULL,
                             stderr=subprocess.PIPE, check=False)
    if process.returncode:
        raise CollectError(f"Cannot write {path}: {process.stderr.strip()}")


def enable_deb_src(apt_root=Path("/etc/apt")):
    """Add matching deb-src entries so that apt-get source can run."""
    legacy = []
    deb822 = []
    sources_list = apt_root / "sources.list"
    if sources_list.is_file():
        for line in sources_list.read_text(encoding="utf-8", errors="replace").splitlines():
            stripped = line.strip()
            if stripped.startswith("deb ") and "://" in stripped:
                legacy.append(stripped.replace("deb ", "deb-src ", 1))
    directory = apt_root / "sources.list.d"
    if directory.is_dir():
        for path in sorted(directory.glob("*.sources")):
            text = path.read_text(encoding="utf-8", errors="replace")
            for stanza in text.split("\n\n"):
                if "Types: deb" not in stanza:
                    continue
                fields = {}
                for line in stanza.splitlines():
                    if ":" in line and not line.startswith((" ", "\t")):
                        key, _, value = line.partition(":")
                        fields[key.strip()] = value.strip()
                if not fields.get("URIs") or not fields.get("Suites"):
                    continue
                deb822.append("Types: deb-src\nURIs: {0}\nSuites: {1}\nComponents: {2}\n".format(
                    fields.get("URIs"), fields.get("Suites"), fields.get("Components", "main")))
    if legacy:
        try:
            directory.mkdir(parents=True, exist_ok=True)
        except PermissionError:
            pass
        write_privileged(directory / "ffmpeg-deb-src.list", "\n".join(legacy) + "\n")
    if deb822:
        try:
            directory.mkdir(parents=True, exist_ok=True)
        except PermissionError:
            pass
        write_privileged(directory / "ffmpeg-deb-src.sources", "\n".join(deb822))
    if not legacy and not deb822:
        raise CollectError("No deb-src entries could be derived from the apt configuration")
    run(["sudo", "apt-get", "update", "-qq"], timeout=1800)


def dpkg_owner(path):
    """Return the dpkg package owning a file, or None."""
    result = run(["dpkg-query", "-S", str(path)], check=False, timeout=120)
    if result.returncode:
        return None
    match = re.search(r"^(.+?):\s+/", result.stdout, re.M)
    return match[1].split(", ")[0] if match else None


def dpkg_source_package(binary_package):
    fields = "${binary:Package}\t${source:Package}\t${source:Version}\n"
    result = run(["dpkg-query", "-W", "-f=" + fields, binary_package], check=False, timeout=120)
    if result.returncode:
        return None
    parts = result.stdout.strip().split("\t")
    if len(parts) < 3 or not parts[1]:
        return None
    return {"source_package": parts[1], "source_version": parts[2]}


def collect_linux(output, modules):
    records = []
    omissions = []
    work = output / "work"
    work.mkdir(parents=True, exist_ok=True)
    enable_deb_src()
    packages = {}
    for entry in modules:
        owner = dpkg_owner(entry["pcfile"])
        if not owner:
            omissions.append(f"{entry['module']}: no dpkg owner for {entry['pcfile']}")
            continue
        packages.setdefault(owner, []).append(entry["module"])
    for binary, owned in sorted(packages.items()):
        source = dpkg_source_package(binary)
        if not source:
            omissions.append(f"{binary}: no source package")
            continue
        name, version = source["source_package"], source["source_version"]
        result = run(["apt-get", "source", f"{name}={version}"], cwd=work, check=False, timeout=3600)
        if result.returncode:
            omissions.append(f"apt-get source {name}={version} failed: {result.stdout.strip()[:400]}")
            continue
        extracted = work / f"{name}-{version}"
        if not extracted.is_dir():
            candidates = sorted(p for p in work.iterdir() if p.is_dir() and p.name.startswith(name))
            if not candidates:
                omissions.append(f"apt-get source {name}={version} produced no directory")
                continue
            extracted = candidates[0]
        destination = output / "sources" / "dpkg" / f"{name}-{version}"
        files = store_tree(output / "sources" / "dpkg", extracted, destination)
        for extra in sorted(work.glob(f"{name}-{version}*.tar.*")) + sorted(work.glob(f"{name}*.diff.gz")):
            files.append(shutil.copy2(extra, output / "sources" / "dpkg" / extra.name))
        record = {"id": f"dpkg:{name}@{version}", "manager": "dpkg", "package": name,
                  "version": version, "binary_package": binary, "modules": sorted(owned), "files": {}}
        record_files(record, output, files)
        records.append(record)
        shutil.rmtree(extracted, ignore_errors=True)
    return records, omissions


# ---------------------------------------------------------------- macOS (brew)

def brew_formula_source(formula):
    """Return (url, sha256) declared by the installed keg's formula."""
    result = run(["brew", "cat", formula], check=False, timeout=300)
    text = result.stdout if result.returncode == 0 else ""
    urls = re.findall(r'^\s*url\s+"([^"]+)"', text, re.M)
    checksums = re.findall(r'^\s*sha256\s+"([0-9a-fA-F]{64})"', text, re.M)
    if urls and checksums:
        return urls[0], checksums[0]
    return None, None


def collect_macos(output, modules):
    records = []
    omissions = []
    cache = output / "work" / "brew-cache"
    cache.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["HOMEBREW_CACHE"] = str(cache)
    formulas = {}
    for entry in modules:
        parts = Path(entry["pcfile"]).parent.parts
        if "Cellar" not in parts:
            omissions.append(f"{entry['module']}: {entry['pcfile']} is not a Homebrew keg")
            continue
        index = parts.index("Cellar")
        if len(parts) < index + 3:
            omissions.append(f"{entry['module']}: malformed Homebrew path {entry['pcfile']}")
            continue
        formulas.setdefault((parts[index + 1], parts[index + 2]), []).append(entry["module"])
    for (formula, version), owned in sorted(formulas.items()):
        url, checksum = brew_formula_source(formula)
        if not url:
            omissions.append(f"{formula}: no source url in the installed formula")
            continue
        destination = output / "sources" / "homebrew" / f"{formula}-{version}"
        destination.mkdir(parents=True, exist_ok=True)
        archive = destination / Path(url.split("?")[0]).name
        try:
            download(url, archive, "sha256", checksum)
        except (OSError, CollectError) as exc:
            omissions.append(f"{formula}: {exc}")
            continue
        files = [archive]
        result = run(["brew", "cat", formula], check=False, timeout=300, env=env)
        if result.returncode == 0:
            formula_copy = destination / f"{formula}.rb"
            formula_copy.write_text(result.stdout, encoding="utf-8")
            files.append(formula_copy)
        record = {"id": f"homebrew:{formula}@{version}", "manager": "homebrew",
                  "package": formula, "version": version, "modules": sorted(owned),
                  "source_urls": [url], "files": {}}
        record_files(record, output, files)
        records.append(record)
    return records, omissions


# -------------------------------------------------------------- Windows (vcpkg)

def vcpkg_installed_packages(vcpkg_installed):
    base = Path(vcpkg_installed)
    # Manifest mode keeps the status file beside the triplet directories;
    # older layouts nested it inside the triplet directory itself.
    candidates = [base / "vcpkg" / "status", base.parent / "vcpkg" / "status"]
    status = next((candidate for candidate in candidates if candidate.is_file()), None)
    if status is None:
        raise CollectError(f"vcpkg status file not found: {candidates[0]}")
    packages = []
    current = {}
    for line in status.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line == "---":
            if current.get("Package"):
                packages.append(current)
            current = {}
        elif ":" in line and not line.startswith("#"):
            key, _, value = line.partition(":")
            key = key.strip()
            if key == "Package" and current.get("Package"):
                packages.append(current)
                current = {}
            current[key] = value.strip()
    if current.get("Package"):
        packages.append(current)
    return packages


def vcpkg_git_sha(vcpkg_root):
    result = run(["git", "-C", str(vcpkg_root), "rev-parse", "HEAD"], check=False, timeout=120)
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def collect_windows(output, vcpkg_root, vcpkg_installed, manifest_root, triplet):
    records = []
    omissions = []
    packages = vcpkg_installed_packages(vcpkg_installed)
    downloads = output / "sources" / "vcpkg" / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    buildtrees = output / "work" / "vcpkg-buildtrees"
    buildtrees.mkdir(parents=True, exist_ok=True)
    result = run([str(Path(vcpkg_root) / "vcpkg.exe"), "install", "--only-downloads",
                  f"--x-downloads-root={downloads}", f"--x-buildtrees-root={buildtrees}",
                  f"--triplet={triplet}", f"--x-manifest-root={manifest_root}"],
                 cwd=manifest_root, check=False, timeout=5400)
    if result.returncode:
        omissions.append("vcpkg --only-downloads failed: " + result.stdout.strip()[:400])
    sha = vcpkg_git_sha(vcpkg_root)
    ports_root = Path(vcpkg_root) / "ports"
    for package in packages:
        name = package["Package"]
        version = package.get("Version", "unknown")
        destination = output / "sources" / "vcpkg" / name
        destination.mkdir(parents=True, exist_ok=True)
        files = []
        port = ports_root / name
        if port.is_dir():
            files.extend(store_tree(output / "sources" / "vcpkg", port, destination / "port"))
        else:
            omissions.append(f"vcpkg {name}: no port directory")
        matched = [a for a in sorted(downloads.rglob("*")) if a.is_file() and a.name.lower().startswith(name.lower())]
        for archive in matched:
            files.append(shutil.copy2(archive, destination / "downloads" / archive.name))
        if not matched:
            omissions.append(f"vcpkg {name}: no downloaded source archive")
        record = {"id": f"vcpkg:{name}@{version}", "manager": "vcpkg", "package": name,
                  "version": version, "modules": [], "vcpkg_sha": sha, "files": {}}
        record_files(record, output, files)
        records.append(record)
    return records, omissions


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("linux", "macos", "windows"))
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--install-root", required=True)
    parser.add_argument("--vcpkg-root")
    parser.add_argument("--vcpkg-installed")
    parser.add_argument("--manifest-root")
    parser.add_argument("--triplet", default="x64-windows-static")
    args = parser.parse_args(argv)
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    install_root = Path(args.install_root).resolve()
    try:
        if args.platform == "windows":
            if not args.vcpkg_root or not args.vcpkg_installed:
                raise CollectError("--vcpkg-root and --vcpkg-installed are required on Windows")
            records, omissions = collect_windows(output, Path(args.vcpkg_root), Path(args.vcpkg_installed),
                                                 Path(args.manifest_root or "."), args.triplet)
            required = []
        else:
            pkg_config = os.environ.get("FFMPEG_PKG_CONFIG") or "pkg-config"
            binary = install_root / "bin" / "ffmpeg"
            configuration = build_configuration(binary, args.source_dir)
            features = features_from_buildconf(configuration)
            modules = required_modules(features)
            modules = collect_required(pkg_config, modules)
            resolved = resolve_modules(pkg_config, modules, install_root)
            required = [entry["module"] for entry in resolved]
            if args.platform == "linux":
                records, omissions = collect_linux(output, resolved)
            else:
                records, omissions = collect_macos(output, resolved)
    except CollectError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    covered = {module for record in records for module in record["modules"]}
    for module in required:
        if module not in covered:
            omissions.append(f"{module}: no collected package provides this module")
    inventory = {
        "schema": SCHEMA,
        "platform": args.platform,
        "complete": not omissions,
        "coverage": {
            "policy": "every statically linked external dependency ships its upstream source",
            "required": required,
            "provided": sorted(covered),
            "omissions": sorted(set(omissions)),
        },
        "packages": records,
    }
    (output / INVENTORY).write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Collected {len(records)} package sources; omissions: {len(inventory['coverage']['omissions'])}")
    for omission in inventory["coverage"]["omissions"]:
        print(f"  - {omission}")
    return 0 if inventory["complete"] else 2


if __name__ == "__main__":
    sys.exit(main())
