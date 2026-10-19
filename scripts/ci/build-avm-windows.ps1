param()
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS -or -not $env:RUNNER_TEMP -or -not $env:GITHUB_ENV) {
    throw 'This script builds AVM on GitHub Actions only.'
}
$source = Join-Path $env:RUNNER_TEMP 'avm'
$build = Join-Path $source 'build'
$prefix = Join-Path $env:RUNNER_TEMP 'avm-install'
$ref = '966a7d7cd6fcf60360caf5dc413b2aeeb65e144d' # AV2 1.0.0
& git clone --no-checkout https://github.com/AOMediaCodec/avm.git $source
if ($LASTEXITCODE -ne 0) { throw 'AVM clone failed' }
& git -C $source checkout --detach $ref
if ($LASTEXITCODE -ne 0) { throw 'AVM checkout failed' }
$cmakeArgs = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DCONFIG_AV2_ENCODER=1', '-DCONFIG_AV2_DECODER=1',
    '-DENABLE_APPS=ON', '-DENABLE_TESTS=OFF', '-DENABLE_EXAMPLES=ON', '-DENABLE_DOCS=OFF',
    '-DCONFIG_WEBM_IO=0', '-DCONFIG_LIBYUV=0')
if ($env:VSCMD_ARG_TGT_ARCH -eq 'arm64') {
    # AVM's Windows ARM assembly path expects GNU tools, not MSVC armasm64.
    $cmakeArgs += @('-DCMAKE_SYSTEM_NAME=Windows', '-DCMAKE_SYSTEM_PROCESSOR=ARM64', '-DAVM_TARGET_CPU=generic')
} else {
    $cmakeArgs += @('-DAVM_TARGET_CPU=x86_64', '-DENABLE_NASM=ON')
}
& cmake -S $source -B $build @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw 'AVM configuration failed' }
& cmake --build $build --parallel $env:NUMBER_OF_PROCESSORS --target avmenc avmdec
if ($LASTEXITCODE -ne 0) { throw 'AVM build failed' }
# Upstream intentionally omits MSVC install rules.
New-Item -ItemType Directory -Path "$prefix\bin", "$prefix\licenses\avm" -Force | Out-Null
foreach ($tool in @('avmenc', 'avmdec')) {
    $exe = Get-ChildItem -LiteralPath $build -Recurse -Filter "$tool.exe" -File |
        Where-Object { $_.FullName -notmatch '[\\/]CMakeFiles[\\/]' } |
        Select-Object -First 1
    if (-not $exe) { throw "Missing AVM tool: $tool" }
    Copy-Item -LiteralPath $exe.FullName -Destination "$prefix\bin\$tool.exe"
}
Copy-Item -LiteralPath "$source\LICENSE", "$source\PATENTS" -Destination "$prefix\licenses\avm"
"AVM_PREFIX=$($prefix -replace '\\', '/')" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
