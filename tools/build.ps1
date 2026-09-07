# Build and deploy a mod from this repo to the game's mods folder.
#
#   pwsh -File tools\build.ps1            # the market mod (default)
#   pwsh -File tools\build.ps1 -Spike     # the M0 capability spike
#
# A VMZ is a zip of mod.txt + mods/ with the extension changed. The loader
# caches mounted archives by name, so clearing that cache is part of deploying
# rather than an optional extra -- a stale entry will happily run the previous
# build and cost you an hour wondering why a fix did nothing.

param(
    [switch]$Spike
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

if ($Spike) {
    $SourceDir = Join-Path $RepoRoot "spike"
    $VmzName   = "Flea-Market-Spike.vmz"
} else {
    $SourceDir = $RepoRoot
    $VmzName   = "Vostok-Flea-Market.vmz"
}

$OutVmz  = Join-Path $RepoRoot $VmzName
$GameDir = "D:\Steam\steamapps\common\Road to Vostok"
$ModsDir = Join-Path $GameDir "mods"

$ModTxt  = Join-Path $SourceDir "mod.txt"
$ModsSrc = Join-Path $SourceDir "mods"

if (-not (Test-Path $ModTxt))  { throw "mod.txt not found: $ModTxt" }
if (-not (Test-Path $ModsSrc)) { throw "mods/ not found: $ModsSrc" }
if (-not (Test-Path $ModsDir)) { throw "Game mods folder not found: $ModsDir" }

# --- Build ---

$TmpZip = Join-Path $env:TEMP "flea-build-$([guid]::NewGuid().ToString('N')).zip"
Remove-Item -Force $OutVmz -ErrorAction SilentlyContinue

Compress-Archive -Path $ModTxt, $ModsSrc -DestinationPath $TmpZip -Force
Move-Item -Force $TmpZip $OutVmz

$version = (Select-String -Path $ModTxt -Pattern '^version="([^"]+)"').Matches[0].Groups[1].Value
$sizeKb  = [math]::Round((Get-Item $OutVmz).Length / 1KB, 1)
Write-Host "Built $VmzName v$version ($sizeKb KB)"

# --- Deploy ---

Copy-Item -Force $OutVmz (Join-Path $ModsDir $VmzName)
Write-Host "Deployed to $ModsDir"

# --- Clear this archive's mount cache only ---
#
# Scoped to the one file on purpose. Wiping the whole loader state (pass state,
# hook packs) drops the loader into its setup flow and costs a launch cycle.

$CacheEntry = Join-Path $env:APPDATA "Road to Vostok\vmz_mount_cache\$($VmzName -replace '\.vmz$', '.zip')"
if (Test-Path $CacheEntry) {
    Remove-Item -Force $CacheEntry
    Write-Host "Cleared mount cache entry"
}

Write-Host ""
Write-Host "Launch the game. If this mod is new, enable it in the mod loader"
Write-Host "screen first -- newly-dropped mods are not in the active profile."
