#Requires -Version 5.1
<#
  ValheimSync - share one Valheim world via Backblaze B2.

  Anyone in the group can host: EXTRACT the latest world before you play,
  UPLOAD it back when you're done. A "lock" in the cloud tracks whose turn
  it is so two people don't host from stale copies and split the world.

  Usage (normally you just double-click the .bat buttons):
    powershell -ExecutionPolicy Bypass -File ValheimSync.ps1 -Action Extract
    powershell -ExecutionPolicy Bypass -File ValheimSync.ps1 -Action Upload
    powershell -ExecutionPolicy Bypass -File ValheimSync.ps1 -Action Status
    powershell -ExecutionPolicy Bypass -File ValheimSync.ps1 -Action Setup

  Flags: -Force skips "are you sure?" confirmations.
#>
[CmdletBinding()]
param(
    [ValidateSet('Extract', 'Upload', 'Status', 'Setup', 'Probe', 'History', 'Restore', 'Worlds')]
    [string]$Action = 'Status',
    [string]$Item,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'
$BinDir = Join-Path $ScriptDir 'bin'
$RclonePath = Join-Path $BinDir 'rclone.exe'

# ---------- pretty output ----------
function Write-Step($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-ErrLine($m) { Write-Host "  [X] $m" -ForegroundColor Red }
function Write-Title($m) {
    Write-Host ''
    Write-Host "=== $m ===" -ForegroundColor White
    Write-Host ''
}

function Confirm-Action($message) {
    if ($Force) { return $true }
    $ans = Read-Host "  $message [y/N]"
    return ($ans -match '^(y|yes)$')
}

# ---------- config ----------
function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        throw "No config.json found. Run the Setup button first."
    }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $cfg.B2.KeyId -or $cfg.B2.KeyId -eq 'PASTE_KEY_ID_HERE') {
        throw "config.json has no B2 credentials yet. Run the Setup button first."
    }
    return $cfg
}

function Get-WorldsPath($cfg) {
    [System.Environment]::ExpandEnvironmentVariables($cfg.WorldsPath)
}

function Get-PlayerName($cfg) {
    if ($cfg.Player -and $cfg.Player -ne '') { return $cfg.Player }
    return $env:USERNAME
}

function Get-LockStaleHours($cfg) {
    if ($cfg.PSObject.Properties.Name -contains 'LockStaleHours' -and $cfg.LockStaleHours) { return [double]$cfg.LockStaleHours }
    return 6
}

function Get-HistoryKeep($cfg) {
    if ($cfg.PSObject.Properties.Name -contains 'HistoryKeep' -and $cfg.HistoryKeep) { return [int]$cfg.HistoryKeep }
    return 20
}

# True if a held lock is older than the stale threshold (likely an abandoned session).
function Test-LockStale($m, $cfg) {
    if (-not $m -or -not $m.hosting -or -not $m.hosting.sinceUtc) { return $false }
    try {
        $since = [datetime]::Parse($m.hosting.sinceUtc).ToUniversalTime()
        return ((Get-Date).ToUniversalTime() - $since).TotalHours -gt (Get-LockStaleHours $cfg)
    } catch { return $false }
}

# Post a message to the group's Discord webhook, if one is configured. Never throws.
function Send-Discord($cfg, $message) {
    $hook = $null
    if ($cfg.PSObject.Properties.Name -contains 'DiscordWebhook') { $hook = $cfg.DiscordWebhook }
    if (-not $hook) { return }
    try {
        $body = @{ content = $message } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri $hook -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
    } catch { Write-Warn2 "(Discord notification failed - $($_.Exception.Message))" }
}

# ---------- rclone ----------
function Ensure-Rclone {
    if (Get-Command rclone -ErrorAction SilentlyContinue) {
        return 'rclone'
    }
    if (Test-Path $RclonePath) { return $RclonePath }

    Write-Step "rclone not found - downloading it once (~20 MB)..."
    $zip = Join-Path $env:TEMP 'rclone-current.zip'
    $url = 'https://downloads.rclone.org/rclone-current-windows-amd64.zip'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $extract = Join-Path $env:TEMP 'rclone-extract'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $exe = Get-ChildItem $extract -Recurse -Filter 'rclone.exe' | Select-Object -First 1
    if (-not $exe) { throw "Could not find rclone.exe in the download." }
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir | Out-Null }
    Copy-Item $exe.FullName $RclonePath -Force
    Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "rclone ready."
    return $RclonePath
}

# Runs rclone with B2 creds injected via env (no rclone.conf needed).
# NOTE: the args parameter must NOT be named $Args -- that shadows the
# automatic $args variable and makes @-splatting expand to nothing.
function Invoke-Rclone {
    param([string]$Exe, $Cfg, [string[]]$RcArgs, [switch]$AllowFail)
    $env:RCLONE_B2_ACCOUNT = $Cfg.B2.KeyId
    $env:RCLONE_B2_KEY = $Cfg.B2.AppKey
    $env:RCLONE_CONFIG = 'NUL'  # ignore any user rclone.conf
    # rclone writes progress/info to stderr; under EAP=Stop a 2>&1 capture would
    # turn that into a terminating error, so relax it just for the native call.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @RcArgs 2>&1
    } finally {
        $ErrorActionPreference = $prev
    }
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw "rclone failed (exit $code):`n$($out -join "`n")"
    }
    return [pscustomobject]@{ Code = $code; Output = ($out -join "`n") }
}

function Get-Remote($cfg, $leaf) {
    # e.g.  :b2:my-bucket/valheim/sivandarvin/latest.zip
    ":b2:$($cfg.B2.Bucket)/valheim/$($cfg.WorldName)/$leaf"
}

# ---------- manifest (latest-save metadata + host lock, one JSON in the cloud) ----------
function Get-Manifest($exe, $cfg) {
    $remote = Get-Remote $cfg 'manifest.json'
    $tmp = Join-Path $env:TEMP "vsync-manifest-$([guid]::NewGuid()).json"
    $r = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $remote, $tmp) -AllowFail
    if ($r.Code -ne 0 -or -not (Test-Path $tmp)) { return $null }
    $m = Get-Content $tmp -Raw | ConvertFrom-Json
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $m
}

function Set-Manifest($exe, $cfg, $manifest) {
    $remote = Get-Remote $cfg 'manifest.json'
    $tmp = Join-Path $env:TEMP "vsync-manifest-$([guid]::NewGuid()).json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $tmp, $remote) | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# Keep the bucket lean: drop old hidden file versions, and trim history/ to the
# newest HistoryKeep saves. Best-effort - never blocks an upload.
function Invoke-StorageCleanup($exe, $cfg) {
    try {
        $worldRemote = ":b2:$($cfg.B2.Bucket)/valheim/$($cfg.WorldName)"
        # purge superseded versions of the repeatedly-overwritten files (latest.zip, manifest.json)
        Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('cleanup', $worldRemote) -AllowFail | Out-Null
        # trim history to the newest N
        $keep = Get-HistoryKeep $cfg
        $r = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('lsf', "$worldRemote/history/") -AllowFail
        if ($r.Code -eq 0 -and $r.Output) {
            $files = @($r.Output -split "`r?`n" | Where-Object { $_ -match '\.zip$' } | Sort-Object -Descending)
            if ($files.Count -gt $keep) {
                foreach ($old in ($files | Select-Object -Skip $keep)) {
                    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('deletefile', "$worldRemote/history/$old") -AllowFail | Out-Null
                }
                Write-Ok "Trimmed history to the newest $keep saves."
            }
        }
    } catch { Write-Warn2 "(cleanup skipped - $($_.Exception.Message))" }
}

function Format-Age($utcString) {
    if (-not $utcString) { return 'unknown' }
    try {
        $t = [datetime]::Parse($utcString).ToUniversalTime()
        $span = (Get-Date).ToUniversalTime() - $t
        if ($span.TotalMinutes -lt 1) { return 'just now' }
        if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes) min ago" }
        if ($span.TotalHours -lt 24) { return "$([int]$span.TotalHours) h ago" }
        return "$([int]$span.TotalDays) d ago"
    } catch { return $utcString }
}

# ---------- guards ----------
function Assert-GameClosed {
    $procs = Get-Process -Name 'valheim', 'valheim_server' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Warn2 "Valheim is running. Close the game fully first (the save file is locked while playing)."
        if (-not (Confirm-Action "Continue anyway?")) { throw "Aborted: game still running." }
    }
}

function Get-LocalDb($cfg) {
    $worlds = Get-WorldsPath $cfg
    Join-Path $worlds "$($cfg.WorldName).db"
}

# The world's files worth syncing: .db + .fwl, plus Valheim's own .old rollback
# copies when present - they let the game recover from a mid-write/corrupted .db.
function Get-WorldFiles($db, $fwl) {
    @($db, $fwl) + @(@("$db.old", "$fwl.old") | Where-Object { Test-Path $_ })
}

function Backup-Local($cfg, $tag) {
    $worlds = Get-WorldsPath $cfg
    $db = Join-Path $worlds "$($cfg.WorldName).db"
    $fwl = Join-Path $worlds "$($cfg.WorldName).fwl"
    if (-not (Test-Path $db)) { return }
    $backupDir = Join-Path $ScriptDir 'local-backups'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $backupDir "$($cfg.WorldName)_$tag`_$stamp.zip"
    Compress-Archive -Path (Get-WorldFiles $db $fwl) -DestinationPath $dest -Force
    # keep only the newest 10 local backups
    Get-ChildItem $backupDir -Filter "$($cfg.WorldName)_*.zip" |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Ok "Local backup saved: $(Split-Path $dest -Leaf)"
}

# ============================================================
#  ACTIONS
# ============================================================

function Do-Status {
    $cfg = Get-Config
    $exe = Ensure-Rclone
    $me = Get-PlayerName $cfg
    Write-Title "Valheim world: $($cfg.WorldName)"
    Write-Host "  You are: $me" -ForegroundColor Gray

    $m = Get-Manifest $exe $cfg
    if (-not $m) {
        Write-Warn2 "No world in the cloud yet. The first host should press UPLOAD to seed it."
    } else {
        Write-Host ''
        Write-Host "  Cloud save:" -ForegroundColor White
        Write-Host "    last uploaded by : $($m.uploadedBy)" -ForegroundColor Gray
        Write-Host "    when             : $(Format-Age $m.uploadedAtUtc) ($($m.uploadedAtUtc))" -ForegroundColor Gray
        if ($m.hosting -and $m.hosting.player) {
            Write-Host ''
            Write-Host "    LOCK: $($m.hosting.player) is currently hosting (since $(Format-Age $m.hosting.sinceUtc))" -ForegroundColor Yellow
        } else {
            Write-Host ''
            Write-Host "    LOCK: free - nobody is hosting right now" -ForegroundColor Green
        }
    }

    $db = Get-LocalDb $cfg
    Write-Host ''
    if (Test-Path $db) {
        $local = (Get-Item $db).LastWriteTimeUtc
        Write-Host "  Your local copy: $($cfg.WorldName).db, modified $(Format-Age $local.ToString('o'))" -ForegroundColor Gray
        if ($m -and $m.uploadedAtUtc) {
            $cloud = [datetime]::Parse($m.uploadedAtUtc).ToUniversalTime()
            if ($local -gt $cloud.AddMinutes(2)) {
                Write-Warn2 "Your local copy is NEWER than the cloud. If you just hosted, press UPLOAD."
            }
        }
    } else {
        Write-Host "  Your local copy: none yet - press EXTRACT to download the world." -ForegroundColor Gray
    }
    Write-Host ''
}

function Do-Extract {
    $cfg = Get-Config
    $exe = Ensure-Rclone
    $me = Get-PlayerName $cfg
    Write-Title "EXTRACT - download the world before you host"
    Assert-GameClosed

    $m = Get-Manifest $exe $cfg
    if (-not $m) { throw "There is no world in the cloud yet. The first host should press UPLOAD instead." }

    # Lock check: is someone else hosting?
    if ($m.hosting -and $m.hosting.player -and $m.hosting.player -ne $me) {
        if (Test-LockStale $m $cfg) {
            Write-Warn2 "$($m.hosting.player)'s session looks abandoned (lock is $(Format-Age $m.hosting.sinceUtc), older than $(Get-LockStaleHours $cfg)h) - taking over."
        } else {
            Write-Warn2 "$($m.hosting.player) is marked as currently hosting (since $(Format-Age $m.hosting.sinceUtc))."
            Write-Warn2 "If you both host, the world will split into two diverging copies."
            if (-not (Confirm-Action "Take over the world anyway?")) { throw "Aborted." }
        }
    }

    # Freshness check: would we clobber newer local progress?
    $db = Get-LocalDb $cfg
    if (Test-Path $db) {
        $local = (Get-Item $db).LastWriteTimeUtc
        $cloud = [datetime]::Parse($m.uploadedAtUtc).ToUniversalTime()
        if ($local -gt $cloud.AddMinutes(2)) {
            Write-Warn2 "Your local copy is NEWER than the cloud version."
            Write-Warn2 "Extracting will overwrite your local world with the (older) cloud one."
            if (-not (Confirm-Action "Overwrite local with the cloud copy?")) { throw "Aborted - run UPLOAD if your local copy is the good one." }
        }
    }

    Backup-Local $cfg 'pre-extract'

    Write-Step "Downloading latest world from B2..."
    $zip = Join-Path $env:TEMP "vsync-latest-$([guid]::NewGuid()).zip"
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', (Get-Remote $cfg 'latest.zip'), $zip, '--progress') | Out-Null

    # Unpack to a temp dir and verify against the manifest hash BEFORE touching
    # the live save - a truncated/corrupt download must never be installed.
    $tmpDir = Join-Path $env:TEMP "vsync-extract-$([guid]::NewGuid())"
    Expand-Archive -Path $zip -DestinationPath $tmpDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    if ($m.sha256) {
        $xdb = Get-ChildItem $tmpDir -File | Where-Object { $_.Name -eq "$($cfg.WorldName).db" } | Select-Object -First 1
        if ($xdb -and (Get-FileHash $xdb.FullName -Algorithm SHA256).Hash -ne $m.sha256) {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            throw "The downloaded world failed its integrity check (hash mismatch). Your local world was NOT changed - try EXTRACT again."
        }
        Write-Ok "Download verified (SHA256 matches the manifest)."
    }

    $worlds = Get-WorldsPath $cfg
    if (-not (Test-Path $worlds)) { New-Item -ItemType Directory -Path $worlds | Out-Null }
    Write-Step "Installing into $worlds ..."
    Copy-Item (Join-Path $tmpDir '*') $worlds -Force
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "World '$($cfg.WorldName)' is ready to play."

    # Claim the lock - it's your turn to host.
    if (-not $m.hosting) { $m | Add-Member -NotePropertyName hosting -NotePropertyValue $null -Force }
    $m.hosting = [pscustomobject]@{ player = $me; sinceUtc = (Get-Date).ToUniversalTime().ToString('o') }
    Set-Manifest $exe $cfg $m
    Write-Ok "Lock claimed - you're marked as the host."
    Send-Discord $cfg ":red_circle: **$me** is now hosting **$($cfg.WorldName)** - world is in use."
    Write-Host ''
    Write-Host "  >> Host the world in-game now. When you're done, press UPLOAD. <<" -ForegroundColor Cyan
    Write-Host ''
}

function Do-Upload {
    $cfg = Get-Config
    $exe = Ensure-Rclone
    $me = Get-PlayerName $cfg
    Write-Title "UPLOAD - save the world to the cloud for the next host"
    Assert-GameClosed

    $worlds = Get-WorldsPath $cfg
    $db = Join-Path $worlds "$($cfg.WorldName).db"
    $fwl = Join-Path $worlds "$($cfg.WorldName).fwl"
    if (-not (Test-Path $db) -or -not (Test-Path $fwl)) {
        throw "Can't find $($cfg.WorldName).db / .fwl in $worlds. Wrong world name in config.json?"
    }

    $m = Get-Manifest $exe $cfg

    # Guard: the cloud already has a NEWER world than your local copy. Uploading
    # now would overwrite whoever saved it last (you forgot to EXTRACT first).
    if ($m -and $m.uploadedAtUtc) {
        $localMtime = (Get-Item $db).LastWriteTimeUtc
        $cloud = [datetime]::Parse($m.uploadedAtUtc).ToUniversalTime()
        if ($cloud -gt $localMtime.AddMinutes(2)) {
            Write-Warn2 "The cloud world (saved by $($m.uploadedBy)) is NEWER than your local copy."
            Write-Warn2 "Uploading now would overwrite their progress. Did you forget to EXTRACT first?"
            if (-not (Confirm-Action "Upload anyway and overwrite the newer cloud world?")) {
                throw "Aborted - run EXTRACT to get the latest world before playing."
            }
        }
    }

    # Size-sanity guard: uploading a much smaller world usually means the wrong
    # world or a corrupted save - flag it before it overwrites a bigger cloud one.
    if ($m -and $m.dbSize -and $m.dbSize -gt 204800) {
        $localSize = (Get-Item $db).Length
        if ($localSize -lt ($m.dbSize * 0.5)) {
            Write-Warn2 ("The world you're uploading ({0:N1} MB) is much smaller than the cloud copy ({1:N1} MB)." -f ($localSize / 1MB), ($m.dbSize / 1MB))
            Write-Warn2 "That can mean a wrong or corrupted world. Double-check before overwriting."
            if (-not (Confirm-Action "Upload the smaller world anyway?")) { throw "Aborted - looked like a wrong/corrupted world." }
        }
    }

    # Warn if someone else holds the lock (you're uploading over their turn)
    if ($m -and $m.hosting -and $m.hosting.player -and $m.hosting.player -ne $me) {
        Write-Warn2 "Heads up: $($m.hosting.player) holds the host lock, not you."
        if (-not (Confirm-Action "Upload your copy as the new latest anyway?")) { throw "Aborted." }
    }

    Write-Step "Packing $($cfg.WorldName).db + .fwl ..."
    $zip = Join-Path $env:TEMP "vsync-upload-$([guid]::NewGuid()).zip"
    Compress-Archive -Path (Get-WorldFiles $db $fwl) -DestinationPath $zip -Force
    $hash = (Get-FileHash $db -Algorithm SHA256).Hash

    Write-Step "Uploading to B2..."
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $zip, (Get-Remote $cfg 'latest.zip'), '--progress') | Out-Null

    # Versioned history copy (so a bad save can be rolled back from the B2 web UI)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $histLeaf = "history/$stamp`_$me.zip"
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $zip, (Get-Remote $cfg $histLeaf)) | Out-Null
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    # New manifest, lock released.
    $manifest = [pscustomobject]@{
        world        = $cfg.WorldName
        uploadedBy   = $me
        uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        dbSize       = (Get-Item $db).Length
        sha256       = $hash
        hosting      = $null
    }
    Set-Manifest $exe $cfg $manifest
    Write-Ok "World uploaded. Lock released - anyone can EXTRACT and host next."
    Send-Discord $cfg ":green_circle: **$me** finished playing **$($cfg.WorldName)** - world is free to host."
    Invoke-StorageCleanup $exe $cfg
    Write-Host ''
}

function Do-Setup {
    Write-Title "Setup - connect to Backblaze B2"
    if (Test-Path $ConfigPath) {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    } else {
        $cfg = [pscustomobject]@{
            WorldName  = 'sivandarvin'
            WorldsPath = '%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local'
            Player     = ''
            B2         = [pscustomobject]@{ Bucket = ''; KeyId = ''; AppKey = '' }
        }
    }

    Write-Host "  Get these from Backblaze: B2 Cloud Storage > Buckets (name)," -ForegroundColor Gray
    Write-Host "  and Application Keys > Add a New Application Key (keyID + key)." -ForegroundColor Gray
    Write-Host ''
    $bucket = Read-Host "  Bucket name [$($cfg.B2.Bucket)]"
    if ($bucket) { $cfg.B2.Bucket = $bucket }
    $keyId = Read-Host "  keyID [$($cfg.B2.KeyId)]"
    if ($keyId) { $cfg.B2.KeyId = $keyId }
    $appKey = Read-Host "  applicationKey (hidden)" -AsSecureString
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($appKey))
    if ($plain) { $cfg.B2.AppKey = $plain }
    $world = Read-Host "  World name [$($cfg.WorldName)]"
    if ($world) { $cfg.WorldName = $world }
    $player = Read-Host "  Your name (for the host lock) [$(if($cfg.Player){$cfg.Player}else{$env:USERNAME})]"
    if ($player) { $cfg.Player = $player }
    $existingHook = if ($cfg.PSObject.Properties.Name -contains 'DiscordWebhook') { $cfg.DiscordWebhook } else { '' }
    $hook = Read-Host "  Discord webhook URL (optional, Enter to skip) [$existingHook]"
    if ($hook) {
        if ($cfg.PSObject.Properties.Name -contains 'DiscordWebhook') { $cfg.DiscordWebhook = $hook }
        else { $cfg | Add-Member -NotePropertyName DiscordWebhook -NotePropertyValue $hook -Force }
    }

    $cfg | ConvertTo-Json -Depth 6 | Set-Content $ConfigPath -Encoding UTF8
    Write-Ok "Saved config.json"

    Write-Step "Testing connection to B2..."
    $exe = Ensure-Rclone
    $r = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('lsd', ":b2:$($cfg.B2.Bucket)") -AllowFail
    if ($r.Code -eq 0) {
        Write-Ok "Connected to bucket '$($cfg.B2.Bucket)' successfully."
        Write-Host ''
        Write-Host "  Next: the first host presses UPLOAD to seed the world." -ForegroundColor Cyan
        Write-Host "  Then share this whole folder with your friends." -ForegroundColor Cyan
    } else {
        Write-ErrLine "Could not reach the bucket. Double-check the bucket name and key."
        Write-Host $r.Output -ForegroundColor DarkGray
    }
    Write-Host ''
}

# Machine-readable state for the GUI. Never throws; prints one marker line of JSON.
function Emit-Probe($h) {
    Write-Output ('__VSYNC_JSON__' + (([pscustomobject]$h) | ConvertTo-Json -Compress -Depth 5))
}

function Do-Probe {
    $r = [ordered]@{ configured = $false; cloudEmpty = $false; localExists = $false; localNewer = $false; cloudNewer = $false; lockStale = $false; gameRunning = $false; cloudDbSize = 0; localDbSize = 0 }
    try {
        if (-not (Test-Path $ConfigPath)) { Emit-Probe $r; return }
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $r.world = $cfg.WorldName
        $r.me = Get-PlayerName $cfg
        $procs = Get-Process -Name 'valheim', 'valheim_server' -ErrorAction SilentlyContinue
        $r.gameRunning = [bool]$procs
        $db = Get-LocalDb $cfg
        $r.localExists = Test-Path $db
        if ($r.localExists) { $r.localDbSize = (Get-Item $db).Length }
        $hasCreds = $cfg.B2.KeyId -and $cfg.B2.KeyId -ne 'PASTE_KEY_ID_HERE' -and $cfg.B2.Bucket
        $r.configured = [bool]$hasCreds
        if (-not $hasCreds) { Emit-Probe $r; return }
        $exe = Ensure-Rclone
        $m = Get-Manifest $exe $cfg
        if (-not $m) { $r.cloudEmpty = $true; Emit-Probe $r; return }
        $r.uploadedBy = $m.uploadedBy
        $r.uploadedAtUtc = $m.uploadedAtUtc
        if ($m.dbSize) { $r.cloudDbSize = $m.dbSize }
        if ($m.hosting -and $m.hosting.player) {
            $r.hostingPlayer = $m.hosting.player
            $r.hostingSinceUtc = $m.hosting.sinceUtc
            $r.lockStale = Test-LockStale $m $cfg
        }
        if ($r.localExists -and $m.uploadedAtUtc) {
            $local = (Get-Item $db).LastWriteTimeUtc
            $cloud = [datetime]::Parse($m.uploadedAtUtc).ToUniversalTime()
            $r.localNewer = ($local -gt $cloud.AddMinutes(2))
            $r.cloudNewer = ($cloud -gt $local.AddMinutes(2))
        }
    } catch {
        $r.error = $_.Exception.Message
    }
    Emit-Probe $r
}

# Machine-readable list of saved versions in history/ (newest first) for the GUI.
function Do-History {
    $list = @()
    try {
        $cfg = Get-Config
        $exe = Ensure-Rclone
        $remote = ":b2:$($cfg.B2.Bucket)/valheim/$($cfg.WorldName)/history/"
        $r = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('lsf', $remote) -AllowFail
        if ($r.Code -eq 0 -and $r.Output) {
            foreach ($name in ($r.Output -split "`r?`n")) {
                $name = $name.Trim()
                if ($name -notmatch '\.zip$') { continue }
                $player = ''; $when = ''
                if ($name -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})_(.+)\.zip$') {
                    $when = "$($Matches[1])-$($Matches[2])-$($Matches[3])T$($Matches[4]):$($Matches[5]):$($Matches[6])Z"
                    $player = $Matches[7]
                }
                $list += [pscustomobject]@{ file = $name; player = $player; when = $when }
            }
            $list = @($list | Sort-Object when -Descending)
        }
    } catch {}
    Emit-Probe ([ordered]@{ history = $list })
}

# Roll the cloud "latest" back to a chosen history/ file (passed via -Item).
function Do-Restore {
    $cfg = Get-Config
    $exe = Ensure-Rclone
    Write-Title "RESTORE - roll the world back to an earlier save"
    if (-not $Item) { throw "No history file given (-Item)." }
    $base = ":b2:$($cfg.B2.Bucket)/valheim/$($cfg.WorldName)"

    $player = 'unknown'
    if ($Item -match '^\d{8}-\d{6}_(.+)\.zip$') { $player = $Matches[1] }

    Write-Step "Fetching '$Item' from history..."
    $zip = Join-Path $env:TEMP "vsync-restore-$([guid]::NewGuid()).zip"
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', "$base/history/$Item", $zip, '--progress') | Out-Null
    if (-not (Test-Path $zip)) { throw "Could not download '$Item' from history." }

    # read db for accurate manifest fields
    $dir = Join-Path $env:TEMP "vsync-restore-$([guid]::NewGuid())"
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    $rdb = Get-ChildItem $dir -Filter '*.db' | Select-Object -First 1

    Write-Step "Publishing it as the current world..."
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $zip, "$base/latest.zip", '--progress') | Out-Null

    $manifest = [pscustomobject]@{
        world         = $cfg.WorldName
        uploadedBy    = "$player (restored)"
        uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        dbSize        = $(if ($rdb) { $rdb.Length } else { 0 })
        sha256        = $(if ($rdb) { (Get-FileHash $rdb.FullName -Algorithm SHA256).Hash } else { '' })
        hosting       = $null
    }
    Set-Manifest $exe $cfg $manifest
    Remove-Item $zip, $dir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Ok "Restored $player's save as the current world. Lock is free."
    Send-Discord $cfg ":rewind: World **$($cfg.WorldName)** was rolled back to **$player**'s earlier save."
    Write-Host ''
    Write-Host "  >> Press EXTRACT to download the restored world. <<" -ForegroundColor Cyan
    Write-Host ''
}

# Machine-readable list of worlds that exist in the cloud bucket, for the GUI dropdown.
function Do-Worlds {
    $worlds = @()
    $current = ''
    try {
        $cfg = Get-Config
        $current = $cfg.WorldName
        $exe = Ensure-Rclone
        $r = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('lsf', '--dirs-only', ":b2:$($cfg.B2.Bucket)/valheim/") -AllowFail
        if ($r.Code -eq 0 -and $r.Output) {
            foreach ($d in ($r.Output -split "`r?`n")) {
                $name = $d.Trim().TrimEnd('/')
                if ($name) { $worlds += $name }
            }
        }
    } catch {}
    Emit-Probe ([ordered]@{ worlds = @($worlds | Sort-Object -Unique); current = $current })
}

# ============================================================
try {
    switch ($Action) {
        'Status'  { Do-Status }
        'Extract' { Do-Extract }
        'Upload'  { Do-Upload }
        'Setup'   { Do-Setup }
        'Probe'   { Do-Probe }
        'History' { Do-History }
        'Restore' { Do-Restore }
        'Worlds'  { Do-Worlds }
    }
} catch {
    Write-Host ''
    Write-ErrLine $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-Host "      at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 1
}
