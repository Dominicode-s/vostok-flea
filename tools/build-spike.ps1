# Build and deploy the Milestone 0 capability spike VMZ.
#
# A VMZ is just a zip of mod.txt + mods/ with the extension changed. The mod
# loader caches mounted archives by name, so a stale cache entry will happily
# run the previous build -- clearing it is part of deploying, not an optional
# extra.

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SpikeDir = Join-Path $RepoRoot "spike"
$VmzName  = "Flea-Market-Spike.vmz"
$OutVmz   = Join-Path $RepoRoot $VmzName

$GameDir  = "D:\Steam\steamapps\common\Road to Vostok"
$ModsDir  = Join-Path $GameDir "mods"

if (-not (Test-Path $SpikeDir)) { throw "Spike source not found: $SpikeDir" }
if (-not (Test-Path $ModsDir))  { throw "Game mods folder not found: $ModsDir" }

# --- Build ---

$TmpZip = Join-Path $env:TEMP "flea-spike-build.zip"
Remove-Item -Force $TmpZip, $OutVmz -ErrorAction SilentlyContinue

Compress-Archive `
    -Path (Join-Path $SpikeDir "mod.txt"), (Join-Path $SpikeDir "mods") `
    -DestinationPath $TmpZip -Force
Move-Item -Force $TmpZip $OutVmz

Write-Host "Built $VmzName ($([math]::Round((Get-Item $OutVmz).Length / 1KB, 1)) KB)"

# --- Deploy ---

Copy-Item -Force $OutVmz (Join-Path $ModsDir $VmzName)
Write-Host "Deployed to $ModsDir"

# --- Clear mount caches ---
#
# The loader has used a couple of cache locations across versions; clear any
# that exist rather than guessing which one this build uses.
$CacheCandidates = @(
    (Join-Path $env:APPDATA "Road to Vostok\vmz_mount_cache\$($VmzName -replace '\.vmz$', '.zip')"),
    (Join-Path $env:APPDATA "Road to Vostok\vmz_mount_cache"),
    (Join-Path $ModsDir ".mounts")
)
foreach ($c in $CacheCandidates) {
    if (Test-Path $c) {
        Remove-Item -Recurse -Force $c -ErrorAction SilentlyContinue
        Write-Host "Cleared cache: $c"
    }
}

# --- Clear the previous report so a stale one is never mistaken for fresh ---

$Report = Join-Path $env:APPDATA "Road to Vostok\FleaSpike_Report.json"
if (Test-Path $Report) {
    Remove-Item -Force $Report
    Write-Host "Removed previous report"
}

Write-Host ""
Write-Host "Ready. Launch Road to Vostok, wait for the main menu, then quit."
Write-Host "Report will be written to:"
Write-Host "  $Report"
