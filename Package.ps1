#Requires -Version 5.1
# Builds a clean zip of the tool (with your B2 config baked in) to send to friends.
# Excludes bin\ (rclone re-downloads itself) and local-backups\.
$src  = $PSScriptRoot
$dest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ValheimSync-for-friends.zip'
$temp = Join-Path $env:TEMP ('vsync-pkg-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $temp 'ValheimSync') | Out-Null
$stage = Join-Path $temp 'ValheimSync'

$include = @(
    'ValheimSync.ps1', 'ValheimSync-GUI.ps1', 'config.json', 'README.md',
    'Valheim Sync.vbs', 'valheim-sync.ico'
)
foreach ($f in $include) {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-Item $p $stage }
}

if (-not (Test-Path (Join-Path $stage 'config.json'))) {
    Write-Host "Warning: no config.json - friends will have to run Setup themselves." -ForegroundColor Yellow
}

if (Test-Path $dest) { Remove-Item $dest -Force }
Compress-Archive -Path $stage -DestinationPath $dest
Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "  Created: $dest" -ForegroundColor Green
Write-Host "  Send that zip to your friends. They unzip it and double-click 'Valheim Sync.vbs'." -ForegroundColor Cyan
Write-Host ''
Start-Process explorer.exe "/select,`"$dest`""
