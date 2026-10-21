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
    "libaribb24": ("libaribb24",),
    "libass": ("libass",),
    "libbluray": ("libbluray",),
    "libbs2b": ("libbs2b",),
    "libcodec2": ("codec2",),
    "libdav1d": ("libdav1d",),
    "libfdk_aac": ("fdk-aac",),
    "libfontconfig": ("fontconfig",),
    "libfreetype": ("freetype2",),
    "libfribidi": ("fribidi",),
    "libharfbuzz": ("harfbuzz",),
    "libjxl": ("libjxl", "libjxl_threads"),
    "libkvazaar": ("kvazaar",),
    "libmp3lame": ("lame",),
    "libopenjpeg": ("libopenjp2",),
    "libopenmpt": ("libopenmpt"),
    "libopenh264": ("openh264",),
    "libplacebo": ("libplacebo",),
    "librubberband": ("librubberband",),
    "libsoxr": ("soxr",),
    "libspeex": ("speex",),
    "libsvtav1": ("SvtAv1Enc",),
    "libtwolame": ("libtwolame",),
    "libvmaf": ("libvmaf",),
    "libvorbis": ("vorbis", "vorbisenc"),
    "libvpx": ("vpx",),
    "libwebp": ("libwebp",),
    "libx264": ("x264",),
    "libx265": ("x265",),
    "libxml2": ("libxml-2.0",),
    "libxvid": ("xvid",),
    "libzimg": ("zimg",),
}

# Compression and windowing libraries linked without a dedicated --enable flag.
BASE_MODULES = ("zlib", "liblzma", "bzip2", "sdl2", "iconv")


def features_from_buildconf(text):
    """Return the --enable-* features recorded in a configure command line."""
    return sorted(set(re.findall(r"--enable-([A-Za-z0-9_]+)", text)))


def required_modules(features):
    """Return every external pkg-config module implied by the given features."""
    modules = []
    for feature in features:
        for module in FEATURE_MODULES.get(feature, (feature,)):
            if module not in modules:
                modules.append(module)
    for module in BASE_MODULES:
        if module not in modules:
            modules.append(module)
    return sorted(modules)
