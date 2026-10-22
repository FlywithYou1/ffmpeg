# Preserve upstream metadata; generate only missing MSVC pkg-config files.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [switch]$HasVpl,
    [string]$GithubEnv = $env:GITHUB_ENV,
    [string]$GithubPath = $env:GITHUB_PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$inst = (Resolve-Path -LiteralPath $InstallRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $inst 'lib'))) { throw "Missing dependency lib directory: $inst" }
$instMixed = $inst -replace '\\','/'
$pcDir = Join-Path $inst 'lib\pkgconfig'
New-Item -ItemType Directory -Path $pcDir -Force | Out-Null

function Find-ImportLib($candidates) {
    foreach ($name in $candidates) {
        foreach ($suffix in @('', '-static', '_static')) {
            $p = Join-Path "$inst\lib" "${name}${suffix}.lib"
            if (Test-Path $p) { return "${name}${suffix}.lib" }
        }
    }
    # Never pick similarly named import/debug archives via prefix wildcards.
    return $null
}

function Write-Utf8($path, $lines) {
    [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Write-Utf8Append($path, $lines) {
    [IO.File]::AppendAllLines($path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}

function Get-PortVersion($portName) {
    $json = "$inst\share\$portName\vcpkg.json"
    $control = "$inst\share\$portName\CONTROL"
    $abi = "$inst\share\$portName\vcpkg_abi_info.txt"
    $ver = $null
    if (Test-Path $json) {
        try {
            $data = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @('version', 'version-semver', 'version-string', 'version-date')) {
                $property = $data.PSObject.Properties[$key]
                if ($property -and $property.Value) { $ver = $property.Value; break }
            }
            if ($ver) { $ver = ($ver -split '#')[0] }
        } catch { throw "Cannot parse ${json}: $_" }
    }
    if (-not $ver -and (Test-Path $control)) {
        $m = Select-String -Path $control -Pattern '^Version:\s*(.+)$'
        if ($m) { $ver = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $ver -and (Test-Path $abi)) {
        $m = Select-String -Path $abi -Pattern '^version\s+(.+)$'
        if ($m) { $ver = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $ver) {
        $infoDirs = @("$inst\..\vcpkg\info", "$inst\vcpkg\info", "$inst\share\vcpkg\info")
        foreach ($infoDir in $infoDirs) {
            if (Test-Path $infoDir) {
                $listFile = Get-ChildItem $infoDir -Filter "${portName}_*.list" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($listFile) {
                    $m = [regex]::Match($listFile.BaseName, "^${portName}_(.+?)(?:#[0-9]+)?_")
                    if ($m.Success) { $ver = $m.Groups[1].Value; break }
                }
            }
        }
    }
    if (-not $ver) { throw "Cannot determine installed $portName version; refusing to invent pkg-config metadata" }
    Write-Host "Get-PortVersion $portName -> $ver"
    return $ver
}

foreach ($pcDirWin in @((Join-Path $inst 'lib\pkgconfig'), (Join-Path $inst 'share\pkgconfig'))) {
    if (-not (Test-Path -LiteralPath $pcDirWin)) { continue }
    foreach ($pc in (Get-ChildItem -LiteralPath $pcDirWin -Filter '*.pc')) {
        $content = Get-Content -LiteralPath $pc.FullName -Raw
        $patched = [regex]::Replace($content, '(?m)^Libs(?:\.private)?:[^\r\n]*', {
            param($match)
            [regex]::Replace($match.Value, '(?<!\S)-lm(?=\s|$)', '')
        })
        if ($pc.Name -eq 'SvtAv1Enc.pc') {
            # vcpkg ships -UEB_DLL in public Cflags; it reaches link.exe as
            # /UEB_DLL, and FFmpeg treats the resulting LNK4044 as a failed check.
            $patched = [regex]::Replace($patched, '(?m)^Cflags(?:\.private)?:[^\r\n]*', {
                param($match)
                [regex]::Replace($match.Value, '(?<!\S)-UEB_DLL(?=\s|$)', '')
            })
        }
        if ($patched -ne $content) {
            [IO.File]::WriteAllText($pc.FullName, $patched, [Text.UTF8Encoding]::new($false))
            Write-Host "Patched known MSVC-incompatible tokens in $($pc.Name)"
        }
    }
}

# Preserve SVT's upstream version, flags and dependency graph.
$svtPc = Join-Path $pcDir 'SvtAv1Enc.pc'
if (-not (Test-Path -LiteralPath $svtPc)) {
    $svtLib = Find-ImportLib @('SvtAv1Enc', 'svtav1', 'svt-av1')
    if ($svtLib) {
        $fastfeatLib = Find-ImportLib @('fastfeat')
        $svtLibs = '-L${libdir} ' + $svtLib
        if ($fastfeatLib) { $svtLibs += " $fastfeatLib" }
        Write-Utf8 $svtPc @("prefix=$instMixed", 'libdir=${prefix}/lib', 'includedir=${prefix}/include',
            'Name: SvtAv1Enc', 'Description: SVT-AV1 encoder', "Version: $(Get-PortVersion 'svt-av1')",
            "Libs: $svtLibs", 'Cflags: -I${includedir} -I${includedir}/svt-av1')
    }
}

if (-not (Test-Path "$pcDir/sdl2.pc")) {
    $sdl2Lib = Find-ImportLib @('SDL2','SDL2-static','SDL2_arm64')
    if (-not $sdl2Lib) {
        Write-Host "::warning::SDL2 import library not found under $inst\lib"
    } else {
        $sdl2mainLib = Find-ImportLib @('SDL2main')
        $sdl2Libs = if ($sdl2mainLib) { "$sdl2mainLib $sdl2Lib" } else { "$sdl2Lib" }
        Write-Utf8 "$pcDir/sdl2.pc" @(
            "prefix=$instMixed",
            'exec_prefix=${prefix}',
            'libdir=${prefix}/lib',
            'includedir=${prefix}/include',
            '',
            'Name: sdl2',
            'Description: Simple DirectMedia Layer',
            "Version: $(Get-PortVersion 'sdl2')",
            ('Libs: -L${libdir} ' + $sdl2Libs),
            'Libs.private: -luser32 -lgdi32 -lwinmm -limm32 -lole32 -loleaut32 -lversion -luuid -ladvapi32 -lsetupapi -lshell32',
            'Cflags: -I${includedir} -I${includedir}/SDL2'
        )
        Write-Host "Created fallback sdl2.pc"
    }
} else { Write-Host "Using upstream sdl2.pc" }

$fallbacks = @(
    @{ Var='libx264Lib';   Names=@('x264','libx264');           Pc='x264';   Desc='libx264 library';            Port='x264'; Cflags='-I${includedir} -DX264_API=' }
    @{ Var='libx265Lib';   Names=@('x265','libx265');           Pc='x265';   Desc='libx265 library';            Port='x265'; Cflags='-I${includedir} -UX265_API_IMPORTS' }
    @{ Var='libvpxLib';    Names=@('vpx','libvpx');     Pc='vpx';    Desc='libvpx library';             Port='libvpx' }
    @{ Var='opusLib';      Names=@('opus');                     Pc='opus';      Desc='opus library';               Port='opus'; Cflags='-I${includedir} -I${includedir}/opus' }
    @{ Var='vorbisLib';    Names=@('vorbis','libvorbis');       Pc='vorbis';    Desc='vorbis library';             Port='libvorbis'; Requires='ogg' }
    @{ Var='vorbisencLib'; Names=@('vorbisenc','libvorbisenc'); Pc='vorbisenc'; Desc='vorbisenc library';          Port='libvorbis'; Requires='vorbis' }
    @{ Var='theoraLib';    Names=@('theora','libtheora');       Pc='theora';    Desc='theora library';             Port='libtheora'; Requires='ogg' }
    @{ Var='theoradecLib'; Names=@('theoradec','libtheoradec'); Pc='theoradec'; Desc='theoradec library';          Port='libtheora'; Requires='ogg' }
    @{ Var='theoraencLib'; Names=@('theoraenc','libtheoraenc'); Pc='theoraenc'; Desc='theoraenc library';          Port='libtheora'; Requires='theoradec ogg' }
    @{ Var='libaomLib';    Names=@('aom','libaom');             Pc='aom';       Desc='aom library';                Port='aom' }
    @{ Var='libwebpLib';   Names=@('webp','libwebp');           Pc='libwebp';   Desc='libwebp library';            Port='libwebp' }
    @{ Var='libassLib';    Names=@('ass','libass');             Pc='libass';    Desc='libass library';             Port='libass'; Requires='freetype2' }
    @{ Var='freetype2Lib'; Names=@('freetype','libfreetype');   Pc='freetype2'; Desc='freetype2 library';          Port='freetype'; Cflags='-I${includedir} -I${includedir}/freetype2' }
    @{ Var='fontconfigLib';Names=@('fontconfig','libfontconfig');Pc='fontconfig';Desc='fontconfig library';        Port='fontconfig'; Requires='freetype2' }
    @{ Var='zimgLib';      Names=@('zimg','libzimg');           Pc='zimg';      Desc='zimg library';               Port='zimg' }
    @{ Var='soxrLib';      Names=@('soxr','libsoxr');           Pc='soxr';      Desc='soxr library';               Port='soxr' }
    @{ Var='libopenjp2Lib';Names=@('openjp2','libopenjp2');     Pc='libopenjp2';Desc='libopenjp2 library';         Port='openjpeg'; Cflags='-I${includedir} -DOPJ_STATIC' }
    @{ Var='snappyLib';    Names=@('snappy','libsnappy');       Pc='snappy';    Desc='snappy library';             Port='snappy' }
    @{ Var='libtwolameLib';Names=@('twolame','libtwolame');     Pc='libtwolame';Desc='TwoLAME MP2 encoder library';Port='libtwolame'; Cflags='-I${includedir} -DLIBTWOLAME_STATIC' }
    @{ Var='dav1dLib'; Names=@('dav1d'); Pc='dav1d'; Desc='AV1 decoder'; Port='dav1d'; Cflags='-I${includedir} -DDAV1D_API=' }
    @{ Var='openh264Lib'; Names=@('openh264'); Pc='openh264'; Desc='OpenH264'; Port='openh264' }
    @{ Var='speexLib'; Names=@('speex'); Pc='speex'; Desc='Speex'; Port='speex'; Cflags='-I${includedir} -I${includedir}/speex' }
    @{ Var='oggFallbackLib'; Names=@('ogg','libogg'); Pc='ogg'; Desc='Ogg'; Port='libogg' }
    @{ Var='libopenmptLib';Names=@('openmpt','libopenmpt');     Pc='libopenmpt';Desc='OpenMPT module library';     Port='libopenmpt' }
)

$oggLib = Find-ImportLib @('ogg','libogg','ogg_static','libogg_static')
if ($oggLib) { Write-Host "ogg found: $oggLib" } else { Write-Host '::warning::ogg not found (vorbis will miss oggpack symbols)' }

$sharpyuvLib = Find-ImportLib @('libsharpyuv','sharpyuv','sharpyuv_static','libsharpyuv_static')
if ($sharpyuvLib) { Write-Host "sharpyuv found: $sharpyuvLib" } else { Write-Host '::warning::sharpyuv not found (webp will miss SharpYuv symbols)' }

$expatLib = Find-ImportLib @('expat','libexpat','expat-static')
if ($expatLib) { Write-Host "expat found: $expatLib" } else { Write-Host '::warning::expat not found (fontconfig will miss XML support)' }

$harfbuzzLib = Find-ImportLib @('harfbuzz','libharfbuzz','harfbuzz-static')
$fribidiLib = Find-ImportLib @('fribidi','libfribidi','fribidi-static')
if ($harfbuzzLib) { Write-Host "harfbuzz found: $harfbuzzLib" } else { Write-Host '::warning::harfbuzz not found (libass will miss hb_* symbols)' }
if ($fribidiLib) { Write-Host "fribidi found: $fribidiLib" } else { Write-Host '::warning::fribidi not found (libass will miss fribidi_* symbols)' }

$libpngLib = Find-ImportLib @('libpng16','libpng','png16','png')
$brotliDecLib = Find-ImportLib @('brotlidec','brotlidec-static')
$brotliCommonLib = Find-ImportLib @('brotlicommon','brotlicommon-static')
$bz2Lib = Find-ImportLib @('bz2','libbz2','bzip2','bzip2-static')
$zlibLib = Find-ImportLib @('zlib','z','libz','zlibstatic')
$ftExtraLibs = @()
if ($libpngLib) { $ftExtraLibs += $libpngLib } else { Write-Host '::warning::libpng not found (freetype PNG support disabled)' }
if ($brotliDecLib) { $ftExtraLibs += $brotliDecLib }
if ($brotliCommonLib) { $ftExtraLibs += $brotliCommonLib }
if ($brotliDecLib) { Write-Host "brotli found: $brotliDecLib + $brotliCommonLib" } else { Write-Host '::warning::brotli not found' }
if ($bz2Lib) { $ftExtraLibs += $bz2Lib } else { Write-Host '::warning::bz2 not found' }
if ($zlibLib) { $ftExtraLibs += $zlibLib } else { Write-Host '::warning::zlib not found' }

foreach ($fb in $fallbacks) {
    foreach ($key in @('Requires', 'Cflags')) {
        if (-not $fb.ContainsKey($key)) { $fb[$key] = $null }
    }
    $lib = Find-ImportLib $fb.Names
    if ($lib) {
        $pcFile = "$pcDir/$($fb.Pc).pc"
        Set-Variable -Name $fb.Var -Value $lib -Scope Script
        if (Test-Path -LiteralPath $pcFile) { Write-Host "Using upstream $($fb.Pc).pc"; continue }
        $lines = @(
            "prefix=$instMixed"
            'exec_prefix=${prefix}'
            'libdir=${prefix}/lib'
            'includedir=${prefix}/include'
            ''
            "Name: $($fb.Pc)"
            "Description: $($fb.Desc)"
            "Version: $(Get-PortVersion $fb.Port)"
        )
        if ($fb.Requires) { $lines += "Requires: $($fb.Requires)" }
        $libs = $lib
        if ($fb.Pc -eq 'fontconfig' -and $expatLib) { $libs = "$libs $expatLib" }
        if ($fb.Pc -eq 'freetype2' -and $ftExtraLibs.Count -gt 0) { $libs = "$libs $($ftExtraLibs -join ' ')" }
        if ($fb.Pc -eq 'vorbis' -and $oggLib) { $libs = "$libs $oggLib" }
        if ($fb.Pc -eq 'vorbisenc' -and $oggLib) { $libs = "$libs $oggLib" }
        if ($fb.Pc -eq 'libwebp' -and $sharpyuvLib) { $libs = "$libs $sharpyuvLib" }
        if ($fb.Pc -eq 'libass') {
            if ($harfbuzzLib) { $libs = "$libs $harfbuzzLib" }
            if ($fribidiLib) { $libs = "$libs $fribidiLib" }
        }
        $lines += ('Libs: -L${libdir} ' + $libs)
        $cflags = if ($fb.Cflags) { $fb.Cflags } else { '-I${includedir}' }
        $lines += "Cflags: $cflags"
        Write-Utf8 $pcFile $lines
        Write-Output "Created fallback $($fb.Pc).pc -> $lib"
        Set-Variable -Name $fb.Var -Value $lib -Scope Script
    } else {
        Write-Output "::warning::No $($fb.Pc) archive; skipping fallback .pc"
        Set-Variable -Name $fb.Var -Value $null -Scope Script
    }
}

if ($HasVpl) {
    if (Test-Path "$pcDir/vpl.pc") {
        Write-Host "Using upstream vpl.pc"
    } else {
        throw "vpl.pc not found; install matching libvpl for Intel QSV"
    }
}

function Copy-LibAlias($actual, $alias) {
    if (-not $actual) { Write-Host "::warning::Copy-LibAlias: source is null, skip $alias"; return }
    $actualPath = Join-Path "$inst\lib" $actual
    $aliasPath = Join-Path "$inst\lib" $alias
    if ((Test-Path $actualPath) -and (-not (Test-Path $aliasPath))) {
        Copy-Item $actualPath $aliasPath
        Write-Output "Created alias $alias -> $actual"
    }
}
# Current vcpkg libjxl.pc uses -ljxl-static, while MSVC provides jxl.lib.
# Supply the expected archive name while preserving vcpkg's dependency metadata.
foreach ($name in @('jxl', 'jxl_threads', 'jxl_cms')) {
    $actual = Find-ImportLib @($name)
    if ($actual -and $actual -ne "$name-static.lib") { Copy-LibAlias $actual "$name-static.lib" }
}
if ($libx264Lib) { Copy-LibAlias $libx264Lib "libx264.lib"; Copy-LibAlias $libx264Lib "x264.lib" }
if ($libx265Lib) { Copy-LibAlias $libx265Lib "libx265.lib"; Copy-LibAlias $libx265Lib "x265.lib" }
if ($libvpxLib) { Copy-LibAlias $libvpxLib "libvpx.lib"; Copy-LibAlias $libvpxLib "vpx.lib" }
if ($opusLib) { Copy-LibAlias $opusLib "opus.lib" }
if ($vorbisLib) { Copy-LibAlias $vorbisLib "vorbis.lib" }
if ($vorbisencLib) { Copy-LibAlias $vorbisencLib "vorbisenc.lib" }
if ($theoraLib) { Copy-LibAlias $theoraLib "theora.lib" }
if ($theoradecLib) { Copy-LibAlias $theoradecLib "theoradec.lib" }
if ($theoraencLib) { Copy-LibAlias $theoraencLib "theoraenc.lib" }
if ($libaomLib) { Copy-LibAlias $libaomLib "libaom.lib"; Copy-LibAlias $libaomLib "aom.lib" }
if ($libwebpLib) { Copy-LibAlias $libwebpLib "libwebp.lib"; Copy-LibAlias $libwebpLib "webp.lib" }
if ($libassLib) { Copy-LibAlias $libassLib "libass.lib"; Copy-LibAlias $libassLib "ass.lib" }
if ($freetype2Lib) { Copy-LibAlias $freetype2Lib "freetype.lib" }
if ($fontconfigLib) { Copy-LibAlias $fontconfigLib "fontconfig.lib" }
if ($zimgLib) { Copy-LibAlias $zimgLib "zimg.lib" }
if ($soxrLib) { Copy-LibAlias $soxrLib "soxr.lib" }
if ($libopenjp2Lib) { Copy-LibAlias $libopenjp2Lib "libopenjp2.lib"; Copy-LibAlias $libopenjp2Lib "openjp2.lib" }
if ($snappyLib) { Copy-LibAlias $snappyLib "snappy.lib" }
if ($libtwolameLib) { Copy-LibAlias $libtwolameLib "libtwolame.lib"; Copy-LibAlias $libtwolameLib "twolame.lib" }
if ($libopenmptLib) { Copy-LibAlias $libopenmptLib "libopenmpt.lib"; Copy-LibAlias $libopenmptLib "openmpt.lib" }

# libjxl metadata is not safely reconstructible (brotli/highway/threads/version).
if (-not (Test-Path -LiteralPath (Join-Path $pcDir 'libjxl.pc'))) {
    throw 'Missing upstream libjxl.pc; install libjxl with pkg-config metadata.'
}

$pkgconf = $null
$installed = Split-Path $inst -Parent
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
# pkgconf is a host tool, unlike the target archives in InstallRoot/lib.
$toolRoots = @((Join-Path $installed "$hostArch-windows"), (Join-Path $installed "$hostArch-windows-static"), $inst) | Select-Object -Unique
$candidates = @()
foreach ($root in $toolRoots) {
    $candidates += @((Join-Path $root 'tools\pkgconf\pkgconf.exe'), (Join-Path $root 'tools\pkgconf\pkg-config.exe'), (Join-Path $root 'bin\pkgconf.exe'))
}
foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { $pkgconf = Get-Item -LiteralPath $candidate; break }
}
if (-not $pkgconf) {
    foreach ($candidate in @('pkgconf.exe', 'pkg-config.exe')) {
        $tool = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($tool) { $pkgconf = Get-Item -LiteralPath $tool.Source; break }
    }
}
if (-not $pkgconf) { throw "pkgconf.exe not found for $inst; install pkgconf first" }
$pkgconfDir = (Split-Path $pkgconf.FullName) -replace '\\','/'
$pcMixed = $pcDir -replace '\\','/'
if ($GithubEnv) {
    Write-Utf8Append $GithubEnv @("VCPKG_INSTALLED=$instMixed", "PKG_CONFIG_DIR=$pkgconfDir", "PKG_CONFIG_PATH=$pcMixed")
}
if ($GithubPath) {
    Write-Utf8Append $GithubPath @($pkgconfDir)
    foreach ($root in $toolRoots) {
        $shadercTools = Join-Path $root 'tools\shaderc'
        if (Test-Path -LiteralPath (Join-Path $shadercTools 'glslc.exe')) { Write-Utf8Append $GithubPath @($shadercTools); break }
    }
}
Write-Host "pkg-config: $($pkgconf.FullName)"
