#!/usr/bin/env python3
"""Shared mapping between FFmpeg build features and external pkg-config modules.

Both the runtime packager and the dependency source collector must agree on
which external libraries are linked into the binaries. Keeping the mapping in
one place makes an incomplete source collection detectable instead of silent.
"""
import re

# FFmpeg --enable-<feature> -> pkg-config module names that satisfy it.
FEATURE_MODULES = {
    "libaom": ("aom",),
    "libaribb24": ("aribb24",),
    "libass": ("libass",),
    "libbluray": ("libbluray",),
    "libbs2b": ("libbs2b",),
    "libcodec2": ("codec2",),
    "libdav1d": ("dav1d",),
    "libfdk_aac": ("fdk-aac",),
    "libfontconfig": ("fontconfig",),
    "libfreetype": ("freetype2",),
    "libfribidi": ("fribidi",),
    "libharfbuzz": ("harfbuzz",),
    "libjxl": ("libjxl", "libjxl_threads"),
    "libkvazaar": ("kvazaar",),
    "libmp3lame": ("lame",),
    "libopenh264": ("openh264",),
    "libopenjpeg": ("libopenjp2",),
    "libopenmpt": ("libopenmpt",),
    "libopus": ("opus",),
    "libplacebo": ("libplacebo",),
    "librubberband": ("rubberband",),
    "libsnappy": ("snappy",),
    "libsoxr": ("soxr",),
    "libspeex": ("speex",),
    "libtheora": ("theora",),
    "libsvtav1": ("SvtAv1Enc",),
    "libtwolame": ("twolame",),
    "libvidstab": ("vidstab",),
    "libvmaf": ("libvmaf",),
    "libvorbis": ("vorbis", "vorbisenc"),
    "libvpl": ("vpl",),
    "libvpx": ("vpx",),
    "libwebp": ("libwebp",),
    "libx264": ("x264",),
    "libx265": ("x265",),
    "libxml2": ("libxml-2.0",),
    "libxvid": (),
    "libzimg": ("zimg",),
}

# Compression and windowing libraries linked without a dedicated --enable flag.
BASE_MODULES = ("zlib", "liblzma", "bzip2", "sdl2", "iconv")

# libxvid is mapped to no module on purpose: FFmpeg links it with a plain
# -lxvidcore and distributions ship no xvidcore.pc, so there is nothing for the
# collector or the packager to query. It is covered by the bundled library
# attribution instead.


def features_from_buildconf(text):
    """Return the --enable-* features recorded in a configure command line."""
    return sorted(set(re.findall(r"--enable-([A-Za-z0-9_]+)", text)))


def required_modules(features, exists=None):
    """Return every external pkg-config module implied by the given features.

    Features without a known module mapping (opencl, vaapi, lto, ...) are build
    switches rather than libraries, so they contribute no module.
    """
    modules = []
    for feature in features:
        names = FEATURE_MODULES.get(feature)
        if names is None:
            # An unmapped --enable-lib* still names a library, so keep it
            # visible instead of letting a new dependency escape attribution.
            names = (feature,) if feature.startswith("lib") else ()
        for module in names:
            if module not in modules:
                modules.append(module)
    for module in BASE_MODULES:
        if module in modules:
            continue
        if exists is not None and not exists(module):
            continue
        modules.append(module)
    return sorted(modules)


def transitive_modules(modules, query):
    """Expand modules with their pkg-config Requires and Requires.private.

    query(option, module) must return the raw output lines for
    ``--print-requires``/``--print-requires-private`` and may return nothing when
    the module is unknown.
    """
    seen = list(modules)
    queue = list(modules)
    while queue:
        module = queue.pop(0)
        for option in ("--print-requires", "--print-requires-private"):
            for line in query(option, module):
                name = line.split()[0] if line.split() else ""
                if re.fullmatch(r"[A-Za-z0-9_.+-]+", name) and name not in seen:
                    seen.append(name)
                    queue.append(name)
    return sorted(seen)
