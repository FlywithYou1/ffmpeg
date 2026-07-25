# 为 vcpkg 安装的依赖生成 FFmpeg 期望的 pkg-config (.pc) 文件和导入库别名。
# 用法: pwsh scripts/ci/write-fallback-pc.ps1 -InstallRoot <path> [-HasVpl]
param(
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [switch]$HasVpl
)

$inst = $InstallRoot
$instMixed = $inst -replace '\\','/'
$pcDir = "$instMixed/lib/pkgconfig"
New-Item -ItemType Directory -Path $pcDir -Force | Out-Null

function Find-ImportLib($candidates) {
    foreach ($name in $candidates) {
        foreach ($suffix in @('', '-static', '_static')) {
            $p = Join-Path "$inst\lib" "${name}${suffix}.lib"
            if (Test-Path $p) { return "${name}${suffix}.lib" }
        }
    }
    # 精确名未匹配时，用通配符搜索（vcpkg 某些 port 会重命名 .lib）
    $allLibs = Get-ChildItem "${inst}\lib\*.lib" -ErrorAction SilentlyContinue
    foreach ($cand in $candidates) {
        $match = $allLibs | Where-Object { $_.Name -match "^${cand}.*\.lib$" } | Select-Object -First 1
        if ($match) { Write-Host "  Find-ImportLib wildcard: $($match.Name)"; return $match.Name }
    }
    Write-Host "${inst}\lib 下可用的 .lib 文件："
    $allLibs | ForEach-Object { Write-Host "  $($_.Name)" }
    return $null
}

function Write-Utf8($path, $lines) {
    [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Get-PortVersion($portName) {
    $json = "$inst\share\$portName\vcpkg.json"
    $control = "$inst\share\$portName\CONTROL"
    $abi = "$inst\share\$portName\vcpkg_abi_info.txt"
    $ver = $null
    if (Test-Path $json) {
        try {
            $data = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
            $ver = $data.version
            if (-not $ver) { $ver = $data.'version-semver' }
            if (-not $ver) { $ver = $data.'version-string' }
            if (-not $ver) { $ver = $data.'version-date' }
            if ($ver) { $ver = ($ver -split '#')[0] }
        } catch { Write-Host "警告：无法解析 $json : $_" }
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
    if (-not $ver) { $ver = 'unknown' }
    # vcpkg 无法提取版本时的兜底：已知满足 FFmpeg 最低版本要求的默认值
    $knownVersions = @{ 'aom' = '3.0.0' }
    if ($ver -eq 'unknown' -and $knownVersions.ContainsKey($portName)) {
        $ver = $knownVersions[$portName]
        Write-Host "Get-PortVersion $portName fallback -> $ver"
    }
    Write-Host "Get-PortVersion $portName -> $ver"
    return $ver
}

# 修复 vcpkg .pc 文件：MSVC 静态构建中 -lm 会链接成不存在的 m.lib
$pcDirWin = "$inst/lib/pkgconfig"
if (Test-Path $pcDirWin) {
    foreach ($pc in (Get-ChildItem $pcDirWin -Filter '*.pc')) {
        $content = Get-Content $pc.FullName -Raw
        if ($content -match ' -lm') {
            $content = $content -replace ' -lm',''
            [System.IO.File]::WriteAllText($pc.FullName, $content, [System.Text.UTF8Encoding]::new($false))
            Write-Output "Patched $($pc.Name) : removed -lm"
        }
    }
}

# 重写 SvtAv1Enc.pc
# 注意：vcpkg 的 svt-av1 在 Windows ARM64 上强制 COMPILE_C_ONLY=ON，
# 不生成 SvtAv1Enc.lib（只有 x86/x64 或 Linux ARM64 才有 SIMD 库）。
# 因此 ARM64 构建跳过 SvtAv1Enc.pc 生成。
$svtLibName = $null
foreach ($cand in @('SvtAv1Enc','svtav1','svt-av1')) {
    foreach ($suffix in @('','-static','_static')) {
        $p = Join-Path "$inst\lib" "${cand}${suffix}.lib"
        if (Test-Path $p) { $svtLibName = "${cand}${suffix}"; break }
    }
    if ($svtLibName) { break }
}
$fastfeatLibName = $null
foreach ($suffix in @('','-static','_static')) {
    $p = Join-Path "$inst\lib" "fastfeat${suffix}.lib"
    if (Test-Path $p) { $fastfeatLibName = "fastfeat${suffix}"; break }
}
if (-not $svtLibName) {
    Write-Output "::warning::SvtAv1Enc import library not found under $inst\lib（ARM64 上正常，跳过）"
} else {
    if (-not $fastfeatLibName) {
        Write-Host "::warning::fastfeat import library not found under $inst\lib"
    } else {
    $svtLibs = "$svtLibName.lib $fastfeatLibName.lib"
    $svtVersion = Get-PortVersion 'svt-av1'
    if ($svtVersion -eq 'unknown') {
        $svtHeader = Join-Path "$inst\include" "EbSvtAv1Enc.h"
        if (Test-Path $svtHeader) {
            $major = $null; $minor = $null; $patch = $null
            foreach ($match in (Select-String -Path $svtHeader -Pattern '#define\s+SVT_AV1_VERSION_(MAJOR|MINOR|PATCH)\s+(\d+)')) {
                switch ($match.Matches[0].Groups[1].Value) {
                    'MAJOR' { $major = $match.Matches[0].Groups[2].Value }
                    'MINOR' { $minor = $match.Matches[0].Groups[2].Value }
                    'PATCH' { $patch = $match.Matches[0].Groups[2].Value }
                }
            }
            if ($major -and $minor -and $patch) { $svtVersion = "$major.$minor.$patch" }
        }
    }
    Write-Host "SvtAv1Enc.pc Version: $svtVersion"
    Write-Utf8 "$pcDir/SvtAv1Enc.pc" @(
        "prefix=$instMixed",
        'exec_prefix=${prefix}',
        'libdir=${prefix}/lib',
        'includedir=${prefix}/include',
        '',
        'Name: SvtAv1Enc',
        'Description: SVT-AV1 encoder library',
        "Version: $svtVersion",
        "Libs: $svtLibs",
        'Cflags: -I${includedir} -I${includedir}/svt-av1'
    )
    Write-Host "已重写 SvtAv1Enc.pc -> $svtLibs"
    }
}

# libmp3lame
$mp3lameLib = Find-ImportLib @('libmp3lame-static','libmp3lame','mp3lame','lame','libmp3lame-0')
if (-not $mp3lameLib) {
    Write-Host "::warning::mp3lame import library not found under $inst\lib"
} else {
Write-Utf8 "$pcDir/libmp3lame.pc" @(
    "prefix=$instMixed",
    'exec_prefix=${prefix}',
    'libdir=${prefix}/lib',
    'includedir=${prefix}/include',
    '',
    'Name: libmp3lame',
    'Description: LAME MP3 encoder library',
    "Version: $(Get-PortVersion 'mp3lame')",
    "Libs: $mp3lameLib"
)
Write-Host "已创建 libmp3lame.pc -> $mp3lameLib"
}

# libfdk-aac
$fdkLib = Find-ImportLib @('fdk-aac','libfdk-aac','fdk-aac-2','fdk-aac-2-static')
if (-not $fdkLib) {
    Write-Host "::warning::fdk-aac import library not found under $inst\lib"
} else {
Write-Utf8 "$pcDir/libfdk-aac.pc" @(
    "prefix=$instMixed",
    'exec_prefix=${prefix}',
    'libdir=${prefix}/lib',
    'includedir=${prefix}/include',
    '',
    'Name: libfdk-aac',
    'Description: Fraunhofer FDK AAC codec library',
    "Version: $(Get-PortVersion 'fdk-aac')",
    "Libs: $fdkLib"
)
Write-Host "已创建 libfdk-aac.pc -> $fdkLib"
}

# sdl2（仅在缺失时创建回退）
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
            "Libs: $sdl2Libs",
            'Cflags: -I${includedir} -I${includedir}/SDL2'
        )
        Write-Host "已创建回退 sdl2.pc"
    }
} else { Write-Host "使用 vcpkg 提供的 sdl2.pc" }

# 软件编解码器回退 .pc（vcpkg 不总是提供）
$fallbacks = @(
    @{ Var='libx264Lib';   Names=@('x264','libx264');           Pc='libx264';   Desc='libx264 library';            Port='x264' }
    @{ Var='libx265Lib';   Names=@('x265','libx265');           Pc='libx265';   Desc='libx265 library';            Port='x265' }
    @{ Var='libvpxLib';    Names=@('vpx','libvpx','vpxmd');     Pc='libvpx';    Desc='libvpx library';             Port='libvpx' }
    @{ Var='opusLib';      Names=@('opus');                     Pc='opus';      Desc='opus library';               Port='opus' }
    @{ Var='vorbisLib';    Names=@('vorbis','libvorbis');       Pc='vorbis';    Desc='vorbis library';             Port='libvorbis' }
    @{ Var='vorbisencLib'; Names=@('vorbisenc','libvorbisenc'); Pc='vorbisenc'; Desc='vorbisenc library';          Port='libvorbis'; Requires='vorbis' }
    @{ Var='theoraLib';    Names=@('theora','libtheora');       Pc='theora';    Desc='theora library';             Port='libtheora' }
    @{ Var='theoradecLib'; Names=@('theoradec','libtheoradec'); Pc='theoradec'; Desc='theoradec library';          Port='libtheora' }
    @{ Var='theoraencLib'; Names=@('theoraenc','libtheoraenc'); Pc='theoraenc'; Desc='theoraenc library';          Port='libtheora' }
    @{ Var='libaomLib';    Names=@('aom','libaom');             Pc='aom';       Desc='aom library';                Port='aom' }
    @{ Var='libwebpLib';   Names=@('webp','libwebp');           Pc='libwebp';   Desc='libwebp library';            Port='libwebp' }
    @{ Var='libassLib';    Names=@('ass','libass');             Pc='libass';    Desc='libass library';             Port='libass' }
    @{ Var='freetype2Lib'; Names=@('freetype','libfreetype');   Pc='freetype2'; Desc='freetype2 library';          Port='freetype'; Cflags='-I${includedir} -I${includedir}/freetype2' }
    @{ Var='fontconfigLib';Names=@('fontconfig','libfontconfig');Pc='fontconfig';Desc='fontconfig library';        Port='fontconfig'; Requires='freetype2' }
    @{ Var='zimgLib';      Names=@('zimg','libzimg');           Pc='zimg';      Desc='zimg library';               Port='zimg' }
    @{ Var='soxrLib';      Names=@('soxr','libsoxr');           Pc='soxr';      Desc='soxr library';               Port='soxr' }
    @{ Var='libopenjp2Lib';Names=@('openjp2','libopenjp2');     Pc='libopenjp2';Desc='libopenjp2 library';         Port='openjpeg' }
    @{ Var='snappyLib';    Names=@('snappy','libsnappy');       Pc='snappy';    Desc='snappy library';             Port='snappy' }
    @{ Var='libtwolameLib';Names=@('twolame','libtwolame');     Pc='libtwolame';Desc='TwoLAME MP2 encoder library';Port='libtwolame'; Cflags='-I${includedir} -DLIBTWOLAME_STATIC' }
    @{ Var='libopenmptLib';Names=@('openmpt','libopenmpt');     Pc='libopenmpt';Desc='OpenMPT module library';     Port='libopenmpt' }
)

# fontconfig 需要 expat（XML 解析），由 vcpkg 作为传递依赖提供
$expatLib = Find-ImportLib @('expat','libexpat','expatMD','expat-static')
if ($expatLib) { Write-Host "expat found: $expatLib" } else { Write-Host '::warning::expat not found (fontconfig will miss XML support)' }

foreach ($fb in $fallbacks) {
    $lib = Find-ImportLib $fb.Names
    if ($lib) {
        $pcFile = "$pcDir/$($fb.Pc).pc"
        # Always overwrite: vcpkg's generated .pc may have wrong paths or Unix-style flags for MSVC static builds
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
        # fontconfig 额外需要 expat.lib（XML 解析）
        $libs = if ($fb.Pc -eq 'fontconfig' -and $expatLib) { "$lib $expatLib" } else { $lib }
        $lines += "Libs: $libs"
        $cflags = if ($fb.Cflags) { $fb.Cflags } else { '-I${includedir}' }
        $lines += "Cflags: $cflags"
        Write-Utf8 $pcFile $lines
        Write-Output "已覆写 $($fb.Pc).pc -> $lib"
        Set-Variable -Name $fb.Var -Value $lib -Scope Script
    } else {
        Write-Output "::warning::未找到 $($fb.Pc) 导入库；跳过 .pc"
        Set-Variable -Name $fb.Var -Value $null -Scope Script
    }
}

# vpl.pc — vcpkg libvpl 使用 cmake-config，ffmpeg 需要 pkg-config
if ($HasVpl) {
    $vplLib = Find-ImportLib @('vpl','libvpl','vpl_arm64','vpl-shared')
    if (-not $vplLib) {
        Write-Host "::warning::vpl import library not found under $inst\lib"
    } else {
        $vplVer = Get-PortVersion 'libvpl'
        if (-not $vplVer -or $vplVer -eq 'unknown') { $vplVer = '2.14.0' }
        Remove-Item "$pcDir/vpl.pc" -ErrorAction SilentlyContinue
        Write-Utf8 "$pcDir/vpl.pc" @(
            "prefix=$instMixed",
            'exec_prefix=${prefix}',
            'libdir=${prefix}/lib',
            'includedir=${prefix}/include',
            '',
            'Name: vpl',
            'Description: Intel oneVPL library',
            "Version: $vplVer",
            "Libs: $vplLib",
            'Cflags: -I${includedir} -I${includedir}/vpl'
        )
        Write-Host "已创建 vpl.pc"
    }
}

# 导入库别名
function Copy-LibAlias($actual, $alias) {
    if (-not $actual) { Write-Host "::warning::Copy-LibAlias: source is null, skip $alias"; return }
    $actualPath = Join-Path "$inst\lib" $actual
    $aliasPath = Join-Path "$inst\lib" $alias
    if ((Test-Path $actualPath) -and (-not (Test-Path $aliasPath))) {
        Copy-Item $actualPath $aliasPath
        Write-Output "Created alias $alias -> $actual"
    }
}
Copy-LibAlias $mp3lameLib "libmp3lame.lib"
Copy-LibAlias $mp3lameLib "mp3lame.lib"
Copy-LibAlias $fdkLib "fdk-aac.lib"
Copy-LibAlias $fdkLib "libfdk-aac.lib"
if ($HasVpl -and $vplLib) { Copy-LibAlias $vplLib "vpl.lib"; Copy-LibAlias $vplLib "libvpl.lib" }
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

# 输出环境变量
$vcpkgRoot = Split-Path (Split-Path $inst) -Parent
$pkgconf = Get-ChildItem -Path @(
    "$inst\bin\pkgconf.exe",
    "$inst\tools\pkgconf\pkgconf.exe",
    "$inst\tools\pkgconf\pkg-config.exe",
    "$vcpkgRoot\packages\pkgconf_*\tools\pkgconf\pkgconf.exe"
) -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkgconf) { throw "pkgconf.exe not found under $inst or $vcpkgRoot\packages" }
$pkgconfDir = (Split-Path $pkgconf.FullName) -replace '\\','/'
$pkgconfMixed = ($pkgconf.FullName -replace '\\','/')
Write-Output "pkg-config: $pkgconfMixed"

Write-Output "已安装的导入库："
Get-ChildItem "$inst\lib\*.lib" | Select-Object -ExpandProperty Name
Write-Output "已生成的 .pc 文件："
Get-ChildItem "$pcDir\*.pc" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
Write-Output "libmp3lame.pc:"
Get-Content "$pcDir/libmp3lame.pc"
Write-Output "libfdk-aac.pc:"
Get-Content "$pcDir/libfdk-aac.pc"
Write-Output "aom.pc status:"
if (Test-Path "$pcDir\aom.pc") {
    Get-Content "$pcDir\aom.pc"
} else {
    Write-Host "::warning::aom.pc was NOT generated (aom.lib may not be found)"
}

Write-Output "VCPKG_INSTALLED=$instMixed" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
# 不设全局 PKG_CONFIG：Meson 会尝试解析为脚本导致 utf-8 错误。
# PKG_CONFIG 仅在 FFmpeg configure 步骤中临时设置。
Write-Output "PKG_CONFIG_DIR=$pkgconfDir" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
Write-Output "PKG_CONFIG_PATH=$pcDir" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
Write-Output "$pkgconfDir" | Out-File $env:GITHUB_PATH -Encoding utf8 -Append
$shadercTools = "$inst\tools\shaderc"
if (Test-Path "$shadercTools\glslc.exe") { Write-Output "$shadercTools" | Out-File $env:GITHUB_PATH -Encoding utf8 -Append; Write-Output "shaderc tools: $shadercTools" }
