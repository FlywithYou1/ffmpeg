param()
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS -or -not $env:RUNNER_TEMP -or -not $env:GITHUB_ENV) {
    throw 'This script builds AVM on GitHub Actions only.'
}
$source = Join-Path $env:RUNNER_TEMP 'avm'
$build = Join-Path $source 'build'
$prefix = Join-Path $env:RUNNER_TEMP 'avm-install'
$ref = '224c347d185d85c906df1e69e65bf569fd7e2c23' # reviewed av2-enc branch tip
& git clone --no-checkout https://github.com/AOMediaCodec/avm.git $source
if ($LASTEXITCODE -ne 0) { throw 'AVM clone failed' }
& git -C $source checkout --detach $ref
if ($LASTEXITCODE -ne 0) { throw 'AVM checkout failed' }
$cmakeArgs = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW',
    '-DCONFIG_AV2_ENCODER=1', '-DCONFIG_AV2_DECODER=1',
    '-DENABLE_APPS=ON', '-DENABLE_TESTS=OFF', '-DENABLE_EXAMPLES=ON', '-DENABLE_DOCS=OFF',
    '-DCONFIG_WEBM_IO=1', '-DCONFIG_LIBYUV=1', '-DCONFIG_LANCZOS_RESAMPLE=1',
    '-DCONFIG_DIP_EXT_PRUNING=0', '-DCONFIG_ML_PART_SPLIT=0', '-DCONFIG_TENSORFLOW_LITE=0')
$isArm64 = $env:VSCMD_ARG_TGT_ARCH -eq 'arm64'
if ($isArm64) {
    if (-not $env:CLANG_BIN) { throw 'VS Clang is required for AVM ARM64 NEON' }
    $clangCl = Join-Path $env:CLANG_BIN 'clang-cl.exe'
    $clangAsm = Join-Path $env:CLANG_BIN 'clang.exe'
    if (-not (Test-Path $clangCl) -or -not (Test-Path $clangAsm)) {
        throw "AVM ARM64 NEON requires clang-cl.exe and clang.exe under $env:CLANG_BIN"
    }
    $env:CC = $clangCl
    $env:CXX = $clangCl
    # Windows ARM64 guarantees baseline NEON; retain AVM_SIMD_CAPS and its mask
    # without executing the ARM32-only __emit probe in the MSVC detection path.
    $cpuDetectPath = Join-Path $source 'avm_ports\arm_cpudetect.c'
    $cpuDetect = Get-Content -LiteralPath $cpuDetectPath -Raw
    $cpuDetectGuard = '#if !CONFIG_RUNTIME_CPU_DETECT || defined(__APPLE__)'
    if ([regex]::Matches($cpuDetect, [regex]::Escape($cpuDetectGuard)).Count -ne 1) {
        throw 'AVM CPU detection guard changed; review the Windows ARM64 patch'
    }
    $cpuDetect = $cpuDetect.Replace($cpuDetectGuard,
        "$cpuDetectGuard || (defined(_WIN32) && defined(_M_ARM64))")
    [IO.File]::WriteAllText($cpuDetectPath, $cpuDetect, [Text.UTF8Encoding]::new($false))
    # Use Clang's NEON vector support with the MSVC ABI and ARM64 SDK libraries.
    $cmakeArgs += @("-DCMAKE_C_COMPILER=$clangCl", "-DCMAKE_CXX_COMPILER=$clangCl",
        '-DCMAKE_C_COMPILER_TARGET=aarch64-pc-windows-msvc', '-DCMAKE_CXX_COMPILER_TARGET=aarch64-pc-windows-msvc',
        "-DCMAKE_ASM_COMPILER=$clangAsm", '-DCMAKE_ASM_FLAGS=--target=aarch64-pc-windows-msvc',
        '-DCMAKE_SYSTEM_NAME=Windows', '-DCMAKE_SYSTEM_PROCESSOR=ARM64',
        '-DAVM_TARGET_CPU=arm64', '-DENABLE_NEON=ON', '-DENABLE_NASM=OFF')
} else {
    $env:CC = 'cl.exe'
    $env:CXX = 'cl.exe'
    $cmakeArgs += @('-DCMAKE_C_COMPILER=cl.exe', '-DCMAKE_CXX_COMPILER=cl.exe',
        '-DAVM_TARGET_CPU=x86_64', '-DENABLE_NASM=ON')
}
& cmake -S $source -B $build @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw 'AVM configuration failed' }
if ($isArm64) {
    $config = Get-Content -LiteralPath "$build\config\avm_config.h" -Raw
    foreach ($flag in @('AVM_ARCH_AARCH64', 'HAVE_NEON')) {
        if ($config -notmatch "(?m)^\s*#define\s+$flag\s+1\s*$") {
            throw "AVM ARM64 configuration did not enable $flag"
        }
    }
    Write-Host 'AVM ARM64 NEON enabled'
}
& cmake --build $build --parallel $env:NUMBER_OF_PROCESSORS --target avmenc avmdec
if ($LASTEXITCODE -ne 0) { throw 'AVM build failed' }
# AVM intentionally omits pkg-config/install rules under MSVC.
# Stage the two application binaries directly from the build tree.
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
