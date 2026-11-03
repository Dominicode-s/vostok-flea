# Snapshot the game's save state before exercising a flow that destroys things.
#
# M3 (selling) and M4 (buying) destroy real items and real cash by design. The
# brief is explicit: back up before running them, because an early bug in a
# two-phase flow eats things for real. This is cheap insurance, so take it every
# time rather than when you remember.
#
# Restores are deliberately manual: unzip over %APPDATA%\Road to Vostok with the
# game closed. A scripted restore is a scripted way to overwrite a good save
# with a stale one.
#
#   pwsh -File tools\backup-save.ps1
#   pwsh -File tools\backup-save.ps1 -Label before-first-sale

param(
    [string]$Label = ""
)

$ErrorActionPreference = "Stop"

$SaveDir = Join-Path $env:APPDATA "Road to Vostok"
if (-not (Test-Path $SaveDir)) { throw "Save directory not found: $SaveDir" }

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$BackupDir = Join-Path $RepoRoot "save-backups"
New-Item -ItemType Directory -Force $BackupDir | Out-Null

$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$name  = if ($Label) { "save_${stamp}_$Label" } else { "save_$stamp" }
$dest  = Join-Path $BackupDir "$name.zip"

# Staged rather than zipped in place: Compress-Archive has no exclude, and the
# shader cache and logs are large, regenerable, and pure noise in a diff.
$staging = Join-Path $env:TEMP "flea-save-$stamp"
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $staging | Out-Null

$skip = @("shader_cache", "logs", "vmz_mount_cache", "modloader_hooks")
Get-ChildItem $SaveDir | Where-Object { $skip -notcontains $_.Name } | ForEach-Object {
    Copy-Item $_.FullName -Destination $staging -Recurse -Force -ErrorAction SilentlyContinue
}

Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $dest -Force
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue

$sizeMb = [math]::Round((Get-Item $dest).Length / 1MB, 2)
Write-Host "Backed up to $dest ($sizeMb MB)"

# What actually matters in there, called out so a restore can be selective.
foreach ($f in @("Character.tres", "Cabin.tres", "Bunker.tres", "Tent.tres", "Attic.tres")) {
    $p = Join-Path $SaveDir $f
    if (Test-Path $p) {
        Write-Host ("  {0,-16} {1,8:N0} bytes  {2}" -f $f, (Get-Item $p).Length,
            (Get-Item $p).LastWriteTime.ToString("HH:mm:ss"))
    }
}

$keep = 20
$old = Get-ChildItem $BackupDir -Filter "save_*.zip" | Sort-Object LastWriteTime -Descending |
       Select-Object -Skip $keep
if ($old) {
    $old | Remove-Item -Force
    Write-Host "Pruned $($old.Count) backup(s), keeping the newest $keep"
}
