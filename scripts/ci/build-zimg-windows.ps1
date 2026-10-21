# Shared CI/local zimg builder. BuildRoot must be a caller-owned scratch directory.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [Parameter(Mandatory=$true)][string]$BuildRoot,
    [ValidateSet('x64', 'arm64')][string]$Architecture = $env:VSCMD_ARG_TGT_ARCH,
    [string]$PlatformToolset = $env:PlatformToolset,
    [string]$Ref = 'master'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Architecture -or $env:VSCMD_ARG_TGT_ARCH -ne $Architecture) {
    throw 'Select a matching x64 or arm64 MSVC developer environment first.'
}
$build = (Resolve-Path -LiteralPath $BuildRoot).Path
$source = Join-Path $build 'zimg-src'
if (Test-Path -LiteralPath $source) { throw "Refusing to overwrite $source" }
$inst = [IO.Path]::GetFullPath($InstallRoot)
$original = Get-Location
try {
    & git clone --depth 1 --recurse-submodules --branch $Ref https://github.com/sekrit-twc/zimg.git $source
    if ($LASTEXITCODE -ne 0) { throw 'zimg clone failed' }
    $match = Select-String -LiteralPath (Join-Path $source 'configure.ac') -Pattern 'AC_INIT\(\[zimg\],\s*\[([^\]]+)\]'
    if (-not $match) { throw 'Cannot determine zimg version from configure.ac' }
    $version = $match.Matches[0].Groups[1].Value
    $props = @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup><WholeProgramOptimization>false</WholeProgramOptimization></PropertyGroup>
  <ItemDefinitionGroup><ClCompile>
    <RuntimeLibrary>MultiThreaded</RuntimeLibrary>
    <WholeProgramOptimization>false</WholeProgramOptimization>
  </ClCompile></ItemDefinitionGroup>
</Project>
'@
    foreach ($file in @('Directory.Build.props', 'Directory.Build.targets')) {
        # The targets import also enforces /MT after project-specific defaults.
        [IO.File]::WriteAllText((Join-Path $source "_msvc\$file"), $props, [Text.UTF8Encoding]::new($false))
    }
    $platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
    $arguments = @((Join-Path $source '_msvc\zimg.sln'), '/p:Configuration=Release', "/p:Platform=$platform", '/t:zimg', '/p:WindowsTargetPlatformVersion=10.0', '/p:WholeProgramOptimization=false', '/m')
    if (-not $PlatformToolset -and $env:VSCMD_VER) {
        switch (($env:VSCMD_VER -split '\.')[0]) {
            '18' { $PlatformToolset = 'v145' }
            '17' { $PlatformToolset = 'v143' }
            '16' { $PlatformToolset = 'v142' }
        }
    }
    if ($PlatformToolset) { $arguments += "/p:PlatformToolset=$PlatformToolset" }
    Set-Location -LiteralPath $source
    & msbuild @arguments
    if ($LASTEXITCODE -ne 0) { throw 'zimg MSBuild failed' }
    $libraries = @(Get-ChildItem -LiteralPath (Join-Path $source '_msvc') -Recurse -Filter 'z.lib' | Where-Object { $_.FullName -match 'Release' })
    if ($libraries.Count -ne 1) { throw "Expected one Release z.lib; found $($libraries.Count)" }
    foreach ($directory in @('include', 'lib', 'lib\pkgconfig', 'share\zimg')) {
        New-Item -ItemType Directory -Path (Join-Path $inst $directory) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $source 'src\zimg\api\zimg.h') -Destination (Join-Path $inst 'include\zimg.h') -Force
    foreach ($header in @('zimg++.hpp', 'zimg++.h')) {
        $path = Join-Path $source "src\zimg\api\$header"
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $inst "include\$header") -Force }
    }
    # Do not create z.lib in the prefix: that name also belongs to zlib.
    Copy-Item -LiteralPath $libraries[0].FullName -Destination (Join-Path $inst 'lib\zimg.lib') -Force
    Copy-Item -LiteralPath (Join-Path $source 'COPYING') -Destination (Join-Path $inst 'share\zimg\copyright') -Force
    $mixed = $inst -replace '\\', '/'
    $pc = @("prefix=$mixed", 'exec_prefix=${prefix}', 'libdir=${prefix}/lib', 'includedir=${prefix}/include', '', 'Name: zimg', 'Description: zimg image processing library', "Version: $version", 'Libs: -L${libdir} -lzimg', 'Cflags: -I${includedir}')
    [IO.File]::WriteAllLines((Join-Path $inst 'lib\pkgconfig\zimg.pc'), $pc, [Text.UTF8Encoding]::new($false))
    Write-Host "zimg $version built for $platform (/MT)"
} finally { Set-Location -LiteralPath $original.Path }
