# Sync the vcpkg registry to the latest baseline (origin/master)
param(
    [string]$VcpkgRoot = ''
)

$ErrorActionPreference = 'Stop'

$v = if ($VcpkgRoot) {
    $VcpkgRoot
} elseif (Test-Path 'C:\vcpkg') {
    'C:\vcpkg'
} else {
    $env:VCPKG_INSTALLATION_ROOT
}

if (-not $v) {
    throw 'Cannot locate vcpkg root directory.'
}
if (-not (Test-Path $v)) {
    throw "vcpkg root does not exist: $v"
}
if (-not (Test-Path (Join-Path $v '.git'))) {
    throw "vcpkg root does not appear to be a git repository: $v"
}

Write-Host "vcpkg root: $v"

$git = 'git'

function Get-GitCommit($repo) {
    $commit = & $git -C $repo rev-parse HEAD
    return $commit.Trim()
}

$before = Get-GitCommit $v
Write-Host "vcpkg baseline before update: $before"

# Some runner images ship a shallow clone; deepen it before pulling
& $git -C $v fetch origin --unshallow 2>&1 | Out-Null

# Fast-forward to the latest upstream baseline
& $git -C $v pull --ff-only origin master

$after = Get-GitCommit $v
if ($before -ne $after) {
    Write-Host "vcpkg baseline updated: $before -> $after"
} else {
    Write-Host "vcpkg baseline is already up to date."
}

# Rebuild the vcpkg executable to match the updated repository version
$bootstrap = Join-Path $v 'bootstrap-vcpkg.bat'
if (Test-Path $bootstrap) {
    & $bootstrap
}

$vcpkgExe = Join-Path $v 'vcpkg.exe'
& $vcpkgExe --version
