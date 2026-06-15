#Requires -Version 5.1
# Builds a clean zip of the tool (with your B2 config baked in) to send to friends.
# Excludes bin\ (rclone re-downloads itself) and local-backups\.
$src  = $PSScriptRoot
$dest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ValheimSync-for-friends.zip'
$temp = Join-Path $env:TEMP ('vsync-pkg-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $temp 'ValheimSync') | Out-Null
$stage = Join-Path $temp 'ValheimSync'

# VERSION must ship or fresh installs report v1.0 and instantly prompt to
# update; Package.ps1 must ship or friends can't "Share to friends" onward.
# config.json is handled separately below (its key is decrypted for sharing).
$include = @(
    'ValheimSync.ps1', 'ValheimSync-GUI.ps1', 'README.md',
    'Valheim Sync.vbs', 'valheim-sync.ico', 'VERSION', 'Package.ps1',
    'config.example.json'
)
foreach ($f in $include) {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-Item $p $stage }
}

# Your B2 key is stored encrypted with DPAPI (per-user/per-machine), which a
# friend's PC cannot decrypt - so the shared config carries a plaintext key.
function Unprotect-Secret([string]$enc) {
    if (-not $enc) { return '' }
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [Convert]::FromBase64String($enc)
        return [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser'))
    } catch { return '' }
}

$cfgPath = Join-Path $src 'config.json'
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $plain = ''
        if (($cfg.B2.PSObject.Properties.Name -contains 'AppKeyEnc') -and $cfg.B2.AppKeyEnc) { $plain = Unprotect-Secret $cfg.B2.AppKeyEnc }
        elseif ($cfg.B2.PSObject.Properties.Name -contains 'AppKey') { $plain = $cfg.B2.AppKey }
        if ($cfg.B2.PSObject.Properties.Name -contains 'AppKeyEnc') { $cfg.B2.PSObject.Properties.Remove('AppKeyEnc') }
        if ($cfg.B2.PSObject.Properties.Name -contains 'AppKey') { $cfg.B2.AppKey = $plain }
        else { $cfg.B2 | Add-Member -NotePropertyName AppKey -NotePropertyValue $plain -Force }
        $cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $stage 'config.json') -Encoding UTF8
        if (-not $plain) { Write-Host "Warning: couldn't read your B2 key - friends will have to run Setup themselves." -ForegroundColor Yellow }
    } catch {
        Write-Host "Warning: config.json couldn't be processed - copying as-is." -ForegroundColor Yellow
        Copy-Item $cfgPath $stage
    }
} else {
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
