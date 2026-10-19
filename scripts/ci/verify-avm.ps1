param([Parameter(Mandatory = $true)][string]$Ffmpeg)
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS -or -not $env:RUNNER_TEMP -or -not $env:AVM_PREFIX) {
    throw 'Run AVM verification on GitHub Actions after building FFmpeg and AVM.'
}
$suffix = if ($env:RUNNER_OS -eq 'Windows') { '.exe' } else { '' }
$bin = Join-Path $env:AVM_PREFIX 'bin'
$encoder = Join-Path $bin "avmenc$suffix"
$decoder = Join-Path $bin "avmdec$suffix"
$work = Join-Path $env:RUNNER_TEMP 'avm-smoke'
$inputFile = Join-Path $work 'input.y4m'
$encoded = Join-Path $work 'output.ivf'
$decoded = Join-Path $work 'decoded.y4m'
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    & $Ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=64x64:rate=1' -frames:v 1 -pix_fmt yuv420p -f yuv4mpegpipe -y $inputFile
    if ($LASTEXITCODE -ne 0) { throw 'FFmpeg AVM input generation failed' }
    & $encoder --codec=av2 --ivf --limit=1 --cpu-used=6 --threads=2 --end-usage=q --cq-level=45 -o $encoded $inputFile
    if ($LASTEXITCODE -ne 0) { throw 'AV2 encoding failed' }
    & $decoder --codec=av2 --limit=1 -o $decoded $encoded
    if ($LASTEXITCODE -ne 0) { throw 'AV2 decoding failed' }
    & $Ffmpeg -hide_banner -loglevel error -i $decoded -frames:v 1 -f null -
    if ($LASTEXITCODE -ne 0) { throw 'Decoded AV2 frame verification failed' }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
