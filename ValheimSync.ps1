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
    [ValidateSet('Extract', 'Upload', 'Status', 'Setup', 'Probe', 'History', 'Restore', 'Worlds', 'Watch', 'Unlock')]
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

# Append a timestamped line to vsync.log - the only window into the otherwise
# invisible background watcher. Never throws; self-trims past 512 KB.
$LogFilePath = Join-Path $ScriptDir 'vsync.log'
function Write-VsyncLog($msg) {
    try {
        if ((Test-Path $LogFilePath) -and (Get-Item $LogFilePath).Length -gt 512KB) {
            Set-Content $LogFilePath (Get-Content $LogFilePath -Tail 200)
        }
        Add-Content $LogFilePath "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    } catch {}
}

function Confirm-Action($message) {
    if ($Force) { return $true }
    $ans = Read-Host "  $message [y/N]"
    return ($ans -match '^(y|yes)$')
}

# ---------- config ----------
# True if config.json carries usable backend credentials (B2 by default, or a
# custom rclone Remote block for advanced users).
function Test-Configured($cfg) {
    if ($cfg.PSObject.Properties.Name -contains 'Remote' -and $cfg.Remote -and $cfg.Remote.Root) { return $true }
    return [bool]($cfg.B2 -and $cfg.B2.Bucket -and $cfg.B2.KeyId -and $cfg.B2.KeyId -ne 'PASTE_KEY_ID_HERE')
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        throw "No config.json found. Run the Setup button first."
    }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not (Test-Configured $cfg)) {
        throw "config.json has no backend credentials yet. Run the Setup button first."
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

function Get-AutoUploadOnClose($cfg) {
    if ($cfg.PSObject.Properties.Name -contains 'AutoUploadOnClose') { return [bool]$cfg.AutoUploadOnClose }
    return $false
}

# ---------- secret at rest (DPAPI) ----------
# The B2 application key is stored encrypted with the Windows DPAPI (CurrentUser)
# in config.json's B2.AppKeyEnc, so a casual reader of the folder can't lift it.
# Plaintext B2.AppKey is still honoured (legacy configs and the friends zip, which
# necessarily ships a usable key). Encryption is per-user/per-machine, so the
# share packager re-writes a plaintext key for friends - see Package.ps1.
function Protect-Secret([string]$plain) {
    if (-not $plain) { return '' }
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser')
        return [Convert]::ToBase64String($enc)
    } catch { return '' }
}

function Unprotect-Secret([string]$enc) {
    if (-not $enc) { return '' }
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [Convert]::FromBase64String($enc)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser')
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch { return '' }
}

# The usable plaintext B2 key, from whichever form config.json carries.
function Get-AppKey($cfg) {
    if ($cfg.B2.PSObject.Properties.Name -contains 'AppKeyEnc' -and $cfg.B2.AppKeyEnc) {
        $k = Unprotect-Secret $cfg.B2.AppKeyEnc
        if ($k) { return $k }
    }
    if ($cfg.B2.PSObject.Properties.Name -contains 'AppKey') { return $cfg.B2.AppKey }
    return ''
}

# ---------- cloud backend (rclone remote) ----------
# Default backend is Backblaze B2 with creds injected via env (no rclone.conf).
# Advanced users can point at any rclone remote by adding a "Remote" block to
# config.json, e.g. { "Type":"drive", "Root":"mygdrive:valheim-sync",
# "Env": { "RCLONE_DRIVE_..." : "..." } } - in which case Root replaces :b2:bucket.
function Get-RemoteRoot($cfg) {
    if ($cfg.PSObject.Properties.Name -contains 'Remote' -and $cfg.Remote -and $cfg.Remote.Root) {
        return ([string]$cfg.Remote.Root).TrimEnd('/')
    }
    ":b2:$($cfg.B2.Bucket)"
}

# Inject the backend credentials into the environment for the next rclone call.
function Set-RcloneEnv($cfg) {
    $env:RCLONE_CONFIG = 'NUL'  # ignore any user rclone.conf
    if ($cfg.PSObject.Properties.Name -contains 'Remote' -and $cfg.Remote -and $cfg.Remote.Root) {
        if ($cfg.Remote.PSObject.Properties.Name -contains 'Env' -and $cfg.Remote.Env) {
            foreach ($p in $cfg.Remote.Env.PSObject.Properties) {
                Set-Item -Path "Env:$($p.Name)" -Value ([string]$p.Value)
            }
        }
        return
    }
    $env:RCLONE_B2_ACCOUNT = $cfg.B2.KeyId
    $env:RCLONE_B2_KEY = Get-AppKey $cfg
}

# True if a held lock is older than the stale threshold (likely an abandoned session).
# The session watcher refreshes hosting.heartbeatUtc while the game runs, so a
# genuine marathon session is judged by its last heartbeat, not its start time.
function Test-LockStale($m, $cfg) {
    if (-not $m -or -not $m.hosting -or -not $m.hosting.sinceUtc) { return $false }
    try {
        $ts = $m.hosting.sinceUtc
        if ($m.hosting.PSObject.Properties.Name -contains 'heartbeatUtc' -and $m.hosting.heartbeatUtc) { $ts = $m.hosting.heartbeatUtc }
        $since = [datetime]::Parse($ts).ToUniversalTime()
        return ((Get-Date).ToUniversalTime() - $since).TotalHours -gt (Get-LockStaleHours $cfg)
    } catch { return $false }
}

# Strip Discord :emoji: shortcodes for plain-text channels like ntfy.
function Remove-Shortcodes([string]$s) { ($s -replace ':[a-z0-9_]+:\s*', '').Trim() }

# Notify the group across whatever channels are configured (all optional, none
# ever throws): a Discord webhook (as a coloured embed, with an optional role
# @mention) and/or an ntfy topic URL for non-Discord groups.
#   $color : Discord embed colour - 'red' (in use), 'green' (free), 'orange' (rollback)
function Send-Notify($cfg, [string]$message, [string]$color = 'green') {
    $palette = @{ red = 15158332; green = 3066993; blue = 3447003; orange = 15105570 }
    $intColor = $palette[$color]; if (-not $intColor) { $intColor = $palette['green'] }

    $hook = $null
    if ($cfg.PSObject.Properties.Name -contains 'DiscordWebhook') { $hook = $cfg.DiscordWebhook }
    if ($hook) {
        try {
            $payload = @{ embeds = @(@{ description = $message; color = $intColor }) }
            if ($cfg.PSObject.Properties.Name -contains 'DiscordRoleId' -and $cfg.DiscordRoleId) {
                $payload.content = "<@&$($cfg.DiscordRoleId)>"
                $payload.allowed_mentions = @{ roles = @([string]$cfg.DiscordRoleId) }
            }
            $body = $payload | ConvertTo-Json -Depth 6
            Invoke-RestMethod -Method Post -Uri $hook -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
        } catch { Write-Warn2 "(Discord notification failed - $($_.Exception.Message))" }
    }

    $ntfy = $null
    if ($cfg.PSObject.Properties.Name -contains 'NtfyUrl' -and $cfg.NtfyUrl) { $ntfy = $cfg.NtfyUrl }
    if ($ntfy) {
        try {
            Invoke-RestMethod -Method Post -Uri $ntfy -Body (Remove-Shortcodes $message) `
                -Headers @{ Title = 'Valheim Sync' } -TimeoutSec 10 | Out-Null
        } catch { Write-Warn2 "(ntfy notification failed - $($_.Exception.Message))" }
    }
}

# ---------- rclone ----------
function Ensure-Rclone {
    if (Get-Command rclone -ErrorAction SilentlyContinue) {
        return 'rclone'
    }
    if (Test-Path $RclonePath) { return $RclonePath }

    Write-Step "rclone not found - downloading it once (~20 MB)..."
    $zip = Join-Path $env:TEMP 'rclone-current.zip'
    # Pinned, known-good version first so a breaking rclone release can't take
    # down every machine on the same day; fall back to current if it vanishes.
    $urls = @(
        'https://downloads.rclone.org/v1.68.2/rclone-v1.68.2-windows-amd64.zip',
        'https://downloads.rclone.org/rclone-current-windows-amd64.zip'
    )
    $downloaded = $false
    foreach ($url in $urls) {
        try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing; $downloaded = $true; break }
        catch { Write-Warn2 "(download failed from $url - trying the next mirror)" }
    }
    if (-not $downloaded) { throw "Could not download rclone. Check your internet connection." }
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
    Set-RcloneEnv $Cfg
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
    "$(Get-RemoteRoot $cfg)/valheim/$($cfg.WorldName)/$leaf"
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

# ---------- local world-state marker (skew-proof freshness) ----------
# Comparing a local file's mtime against the cloud's uploadedAtUtc means comparing
# two clocks on two machines - drift > 2 min gives false "newer/older" verdicts.
# Instead we record, per world, the manifest "version" we last synced to and the
# local .db mtime at that moment. Both later comparisons are same-machine:
#   cloudNewer  = manifest.version > the version we last synced
#   localNewer  = our .db changed since we synced AND the cloud hasn't moved on
# The old timestamp heuristic stays as a fallback for pre-version manifests.
$WorldStatePath = Join-Path $ScriptDir '.worldstate.json'

function Get-WorldState($cfg) {
    if (-not (Test-Path $WorldStatePath)) { return $null }
    try {
        $all = Get-Content $WorldStatePath -Raw | ConvertFrom-Json
        $name = $cfg.WorldName
        if ($all.PSObject.Properties.Name -contains $name) { return $all.$name }
    } catch {}
    return $null
}

function Set-WorldState($cfg, [int]$version, [string]$mtimeUtc, [string]$sha) {
    $all = $null
    if (Test-Path $WorldStatePath) { try { $all = Get-Content $WorldStatePath -Raw | ConvertFrom-Json } catch {} }
    if (-not $all) { $all = [pscustomobject]@{} }
    $entry = [pscustomobject]@{ version = $version; syncedMtimeUtc = $mtimeUtc; sha256 = $sha }
    if ($all.PSObject.Properties.Name -contains $cfg.WorldName) { $all.$($cfg.WorldName) = $entry }
    else { $all | Add-Member -NotePropertyName $cfg.WorldName -NotePropertyValue $entry -Force }
    try { $all | ConvertTo-Json -Depth 6 | Set-Content $WorldStatePath -Encoding UTF8 } catch {}
}

# Decide whether the local copy or the cloud copy is the newer one. Returns
# @{ localNewer; cloudNewer }. Prefers the version counter; falls back to mtimes.
function Get-Freshness($cfg, $m, $dbPath) {
    $res = @{ localNewer = $false; cloudNewer = $false }
    if (-not $m) { return $res }
    $localExists = ($dbPath -and (Test-Path $dbPath))
    $cloudVer = 0
    if ($m.PSObject.Properties.Name -contains 'version' -and $m.version) { try { $cloudVer = [int]$m.version } catch {} }
    $state = Get-WorldState $cfg
    if ($cloudVer -gt 0 -and $state -and ($state.PSObject.Properties.Name -contains 'version')) {
        $myVer = 0; try { $myVer = [int]$state.version } catch {}
        $res.cloudNewer = ($cloudVer -gt $myVer)
        if (-not $res.cloudNewer -and $localExists -and $state.syncedMtimeUtc) {
            try {
                $synced = [datetime]::Parse($state.syncedMtimeUtc).ToUniversalTime()
                $now = (Get-Item $dbPath).LastWriteTimeUtc
                $res.localNewer = ($now -gt $synced.AddSeconds(5))
            } catch {}
        }
        return $res
    }
    # fallback: cross-machine timestamp heuristic (pre-version manifests)
    if ($localExists -and $m.uploadedAtUtc) {
        try {
            $local = (Get-Item $dbPath).LastWriteTimeUtc
            $cloud = [datetime]::Parse($m.uploadedAtUtc).ToUniversalTime()
            $res.localNewer = ($local -gt $cloud.AddMinutes(2))
            $res.cloudNewer = ($cloud -gt $local.AddMinutes(2))
        } catch {}
    }
    return $res
}

# Keep the bucket lean: drop old hidden file versions, and trim history/ to the
# newest HistoryKeep saves. Best-effort - never blocks an upload.
function Invoke-StorageCleanup($exe, $cfg) {
    try {
        $worldRemote = "$(Get-RemoteRoot $cfg)/valheim/$($cfg.WorldName)"
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

function Format-Span([timespan]$span) {
    if ($span.TotalMinutes -lt 1) { return 'under a minute' }
    if ($span.TotalMinutes -lt 60) { return "$([int][math]::Floor($span.TotalMinutes)) min" }
    return "$([int][math]::Floor($span.TotalHours)) h $($span.Minutes) min"
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
        $fresh = Get-Freshness $cfg $m $db
        if ($fresh.localNewer) {
            Write-Warn2 "Your local copy is NEWER than the cloud. If you just hosted, press UPLOAD."
        } elseif ($fresh.cloudNewer) {
            Write-Warn2 "The cloud copy is NEWER than yours. Press EXTRACT before you play."
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
        if ((Get-Freshness $cfg $m $db).localNewer) {
            Write-Warn2 "Your local copy is NEWER than the cloud version."
            Write-Warn2 "Extracting will overwrite your local world with the (older) cloud one."
            if (-not (Confirm-Action "Overwrite local with the cloud copy?")) { throw "Aborted - run UPLOAD if your local copy is the good one." }
        }
    }

    Backup-Local $cfg 'pre-extract'

    # Download, unpack to a temp dir and verify against the manifest hash BEFORE
    # touching the live save. A mismatch is retried once (transfer glitch); a
    # second mismatch means latest.zip and manifest.json genuinely disagree,
    # i.e. the last upload died between the two writes.
    $tmpDir = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Write-Step "Downloading latest world from B2..."
        $zip = Join-Path $env:TEMP "vsync-latest-$([guid]::NewGuid()).zip"
        Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', (Get-Remote $cfg 'latest.zip'), $zip, '--progress') | Out-Null
        $tmpDir = Join-Path $env:TEMP "vsync-extract-$([guid]::NewGuid())"
        Expand-Archive -Path $zip -DestinationPath $tmpDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        if (-not $m.sha256) { break }
        $xdb = Get-ChildItem $tmpDir -File | Where-Object { $_.Name -eq "$($cfg.WorldName).db" } | Select-Object -First 1
        $dbOk = (-not $xdb) -or ((Get-FileHash $xdb.FullName -Algorithm SHA256).Hash -eq $m.sha256)
        # Verify the .fwl (world seed/metadata) too when the manifest records its hash.
        $fwlOk = $true
        if ($m.PSObject.Properties.Name -contains 'fwlSha256' -and $m.fwlSha256) {
            $xfwl = Get-ChildItem $tmpDir -File | Where-Object { $_.Name -eq "$($cfg.WorldName).fwl" } | Select-Object -First 1
            $fwlOk = $xfwl -and ((Get-FileHash $xfwl.FullName -Algorithm SHA256).Hash -eq $m.fwlSha256)
        }
        if ($dbOk -and $fwlOk) {
            if ($xdb) { Write-Ok "Download verified (SHA256 matches the manifest)." }
            break
        }
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        $tmpDir = $null
        if ($attempt -ge 2) {
            throw "The cloud world doesn't match its manifest even after a re-download. The last UPLOAD (by $($m.uploadedBy)) was probably interrupted partway - ask them to press UPLOAD again, or use Restore to roll back to an earlier save. Your local world was NOT changed."
        }
        Write-Warn2 "Integrity check failed - re-downloading once in case the transfer glitched..."
    }

    $worlds = Get-WorldsPath $cfg
    if (-not (Test-Path $worlds)) { New-Item -ItemType Directory -Path $worlds | Out-Null }
    Write-Step "Installing into $worlds ..."
    Copy-Item (Join-Path $tmpDir '*') $worlds -Force
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "World '$($cfg.WorldName)' is ready to play."

    # Re-read the manifest right before claiming: someone may have pressed
    # EXTRACT at the same time and grabbed the lock while we were downloading.
    # Deliberately a hard abort (not a -Force-able confirm) - this is an active,
    # seconds-old conflict, not a maybe-stale one.
    $m2 = Get-Manifest $exe $cfg
    if ($m2) {
        $sameLock = $m.hosting -and $m.hosting.player -and $m2.hosting -and
                    $m.hosting.player -eq $m2.hosting.player -and $m.hosting.sinceUtc -eq $m2.hosting.sinceUtc
        if ($m2.hosting -and $m2.hosting.player -and $m2.hosting.player -ne $me -and -not $sameLock) {
            throw "$($m2.hosting.player) claimed the host lock while you were downloading. Coordinate who hosts, then try again."
        }
        $m = $m2
    }

    # Record what we just synced to, for skew-proof freshness checks later.
    $localDb = Get-LocalDb $cfg
    if (Test-Path $localDb) {
        $cloudVer = 0; if ($m.PSObject.Properties.Name -contains 'version' -and $m.version) { try { $cloudVer = [int]$m.version } catch {} }
        Set-WorldState $cfg $cloudVer ((Get-Item $localDb).LastWriteTimeUtc.ToString('o')) $m.sha256
    }

    # Claim the lock - it's your turn to host. Stamp a unique nonce so we can
    # confirm OUR write won: B2/rclone is last-write-wins with no compare-and-swap,
    # so two near-simultaneous claims can race past the re-read above. After
    # writing we read back; if our nonce isn't there, someone overwrote us.
    $nonce = [guid]::NewGuid().ToString('N')
    if (-not $m.hosting) { $m | Add-Member -NotePropertyName hosting -NotePropertyValue $null -Force }
    $m.hosting = [pscustomobject]@{ player = $me; sinceUtc = (Get-Date).ToUniversalTime().ToString('o'); nonce = $nonce }
    Set-Manifest $exe $cfg $m
    Start-Sleep -Milliseconds 1500
    $confirm = Get-Manifest $exe $cfg
    if ($confirm -and $confirm.hosting -and ($confirm.hosting.PSObject.Properties.Name -contains 'nonce') -and
        $confirm.hosting.nonce -ne $nonce -and $confirm.hosting.player -ne $me) {
        throw "$($confirm.hosting.player) claimed the host lock at the same moment. Coordinate who hosts, then press EXTRACT again. Your local world is downloaded and ready."
    }
    if ($confirm) { $m = $confirm }
    Write-Ok "Lock claimed - you're marked as the host."
    Send-Notify $cfg ":red_circle: **$me** is now hosting **$($cfg.WorldName)** - world is in use (picking up $($m.uploadedBy)'s save from $(Format-Age $m.uploadedAtUtc))." 'red'
    Start-Watcher
    Write-Host ''
    Write-Host "  >> Host the world in-game now. When you're done, press UPLOAD. <<" -ForegroundColor Cyan
    Write-Host "  >> (When Valheim closes, you'll be asked if you want to upload right away.) <<" -ForegroundColor DarkCyan
    Write-Host ''
}

# Spawn the detached background session watcher (see Do-Watch).
function Start-Watcher {
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', (Join-Path $ScriptDir 'ValheimSync.ps1'), '-Action', 'Watch'
        ) | Out-Null
        Write-Ok "Session watcher started - it will offer to UPLOAD when Valheim closes."
    } catch { Write-Warn2 "(couldn't start the session watcher - $($_.Exception.Message))" }
}

function Show-WatcherBox([string]$msg, $buttons, $icon) {
    # DefaultDesktopOnly keeps the box on top even though we run window-less
    return [System.Windows.Forms.MessageBox]::Show(
        $msg, 'Valheim Sync', $buttons, $icon,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
        [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

# Background session watcher, spawned by EXTRACT. Waits for Valheim to start,
# refreshes the host-lock heartbeat while it runs (so long sessions don't look
# abandoned), and offers to UPLOAD the moment the game closes - the easiest
# step to forget, now hard to miss.
function Do-Watch {
    Add-Type -AssemblyName System.Windows.Forms
    $cfg = Get-Config
    $me = Get-PlayerName $cfg
    $world = $cfg.WorldName

    # single instance: a fresh EXTRACT replaces any previous watcher
    $pidFile = Join-Path $ScriptDir '.watcher.pid'
    try {
        if (Test-Path $pidFile) {
            $old = 0
            if ([int]::TryParse(((Get-Content $pidFile -ErrorAction SilentlyContinue) | Select-Object -First 1), [ref]$old) -and $old -and $old -ne $PID) {
                Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
    Set-Content $pidFile $PID

    try {
        Write-VsyncLog "watcher: started for '$world' (pid $PID), waiting for Valheim..."
        # wait up to 2 h for the game to start (they may have extracted and walked away)
        $deadline = (Get-Date).AddHours(2)
        while (-not (Get-Process -Name 'valheim', 'valheim_server' -ErrorAction SilentlyContinue)) {
            if ((Get-Date) -gt $deadline) { Write-VsyncLog "watcher: game never started within 2 h - standing down."; return }
            Start-Sleep -Seconds 20
        }
        Write-VsyncLog "watcher: Valheim is running - heartbeating the lock every 15 min."

        # game is running: bump the lock heartbeat every 15 min
        $exe = Ensure-Rclone
        $lastBeat = Get-Date
        while (Get-Process -Name 'valheim', 'valheim_server' -ErrorAction SilentlyContinue) {
            Start-Sleep -Seconds 30
            if (((Get-Date) - $lastBeat).TotalMinutes -lt 15) { continue }
            $lastBeat = Get-Date
            try {
                $m = Get-Manifest $exe $cfg
                if ($m -and $m.hosting -and $m.hosting.player -eq $me) {
                    $beat = (Get-Date).ToUniversalTime().ToString('o')
                    if ($m.hosting.PSObject.Properties.Name -contains 'heartbeatUtc') { $m.hosting.heartbeatUtc = $beat }
                    else { $m.hosting | Add-Member -NotePropertyName heartbeatUtc -NotePropertyValue $beat }
                    Set-Manifest $exe $cfg $m
                    Write-VsyncLog "watcher: lock heartbeat refreshed."
                } else {
                    Write-VsyncLog "watcher: lock no longer held by $me - heartbeat skipped."
                }
            } catch { Write-VsyncLog "watcher: heartbeat failed - $($_.Exception.Message)" }
        }

        # game closed: give the save a moment to flush, then offer to upload
        Write-VsyncLog "watcher: Valheim closed."
        Start-Sleep -Seconds 10
        $m = Get-Manifest $exe $cfg
        if (-not $m -or -not $m.hosting -or $m.hosting.player -ne $me) { Write-VsyncLog "watcher: lock already released/taken - standing down."; return }
        if ((Get-Config).WorldName -ne $world) { Write-VsyncLog "watcher: world switched since extract - standing down."; return }

        # With AutoUploadOnClose set, skip the prompt and just upload (the user
        # has opted in to always uploading when they close the game).
        if (Get-AutoUploadOnClose $cfg) {
            Write-VsyncLog "watcher: AutoUploadOnClose is on - uploading without prompting."
        } else {
            $ans = Show-WatcherBox "Valheim closed and you still hold the host lock for '$world'.`n`nUpload the world to the cloud now so the next person can play?" `
                ([System.Windows.Forms.MessageBoxButtons]::YesNo) ([System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { Write-VsyncLog "watcher: user declined the upload prompt."; return }
        }
        try {
            $script:Force = $true   # the popup was the confirmation
            Do-Upload
            Write-VsyncLog "watcher: upload succeeded - lock released."
            Show-WatcherBox "World uploaded - the lock is free for the next host." `
                ([System.Windows.Forms.MessageBoxButtons]::OK) ([System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } catch {
            Write-VsyncLog "watcher: upload FAILED - $($_.Exception.Message)"
            Show-WatcherBox "Upload failed: $($_.Exception.Message)`n`nOpen Valheim Sync and press UPLOAD manually." `
                ([System.Windows.Forms.MessageBoxButtons]::OK) ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    } finally {
        try {
            if (((Get-Content $pidFile -ErrorAction SilentlyContinue) | Select-Object -First 1) -eq "$PID") {
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
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
    if ($m -and (Get-Freshness $cfg $m $db).cloudNewer) {
        Write-Warn2 "The cloud world (saved by $($m.uploadedBy)) is NEWER than your local copy."
        Write-Warn2 "Uploading now would overwrite their progress. Did you forget to EXTRACT first?"
        if (-not (Confirm-Action "Upload anyway and overwrite the newer cloud world?")) {
            throw "Aborted - run EXTRACT to get the latest world before playing."
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
    $fwlHash = (Get-FileHash $fwl -Algorithm SHA256).Hash

    Write-Step "Uploading to the cloud..."
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $zip, (Get-Remote $cfg 'latest.zip'), '--progress') | Out-Null

    # Versioned history copy (so a bad save can be rolled back from the B2 web UI)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $histLeaf = "history/$stamp`_$me.zip"
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $zip, (Get-Remote $cfg $histLeaf)) | Out-Null
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    # Monotonic version counter: increments on every publish, the skew-proof basis
    # for "is the cloud newer than me?" (see Get-Freshness).
    $newVer = 1
    if ($m -and $m.PSObject.Properties.Name -contains 'version' -and $m.version) { try { $newVer = [int]$m.version + 1 } catch {} }

    # New manifest, lock released.
    $manifest = [pscustomobject]@{
        world        = $cfg.WorldName
        version      = $newVer
        uploadedBy   = $me
        uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        dbSize       = (Get-Item $db).Length
        sha256       = $hash
        fwlSha256    = $fwlHash
        hosting      = $null
    }
    Set-Manifest $exe $cfg $manifest
    # We are now in sync with the version we just published.
    Set-WorldState $cfg $newVer ((Get-Item $db).LastWriteTimeUtc.ToString('o')) $hash
    Write-Ok "World uploaded. Lock released - anyone can EXTRACT and host next."
    $details = @('world is {0:N1} MB' -f ((Get-Item $db).Length / 1MB))
    if ($m -and $m.hosting -and $m.hosting.player -eq $me -and $m.hosting.sinceUtc) {
        try { $details = @("played $(Format-Span ((Get-Date).ToUniversalTime() - [datetime]::Parse($m.hosting.sinceUtc).ToUniversalTime()))") + $details } catch {}
    }
    Send-Notify $cfg ":green_circle: **$me** finished playing **$($cfg.WorldName)** - world is free to host ($($details -join ', '))." 'green'
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
    if ($plain) {
        # store encrypted at rest; drop any legacy plaintext copy
        if ($cfg.B2.PSObject.Properties.Name -contains 'AppKeyEnc') { $cfg.B2.AppKeyEnc = (Protect-Secret $plain) }
        else { $cfg.B2 | Add-Member -NotePropertyName AppKeyEnc -NotePropertyValue (Protect-Secret $plain) -Force }
        if ($cfg.B2.PSObject.Properties.Name -contains 'AppKey') { $cfg.B2.AppKey = '' }
    }
    $detected = @()
    try {
        $wl = Get-WorldsPath $cfg
        if (Test-Path $wl) {
            $detected = @(Get-ChildItem $wl -File | Where-Object { $_.Extension -eq '.db' } |
                ForEach-Object { $_.BaseName } | Sort-Object -Unique)
        }
    } catch {}
    if ($detected) { Write-Host "  Worlds found on this PC: $($detected -join ', ')" -ForegroundColor Gray }
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
    $r = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('lsd', (Get-RemoteRoot $cfg)) -AllowFail
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
        $r.watcherActive = $false
        try {
            $pidFile = Join-Path $ScriptDir '.watcher.pid'
            if (Test-Path $pidFile) {
                $wpid = 0
                if ([int]::TryParse(((Get-Content $pidFile -ErrorAction SilentlyContinue) | Select-Object -First 1), [ref]$wpid) -and $wpid) {
                    $r.watcherActive = [bool](Get-Process -Id $wpid -ErrorAction SilentlyContinue)
                }
            }
        } catch {}
        $db = Get-LocalDb $cfg
        $r.localExists = Test-Path $db
        if ($r.localExists) { $r.localDbSize = (Get-Item $db).Length }
        $hasCreds = Test-Configured $cfg
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
        if ($r.localExists) {
            $fresh = Get-Freshness $cfg $m $db
            $r.localNewer = $fresh.localNewer
            $r.cloudNewer = $fresh.cloudNewer
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
        $remote = "$(Get-RemoteRoot $cfg)/valheim/$($cfg.WorldName)/history/"
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
    $base = "$(Get-RemoteRoot $cfg)/valheim/$($cfg.WorldName)"

    $player = 'unknown'
    if ($Item -match '^\d{8}-\d{6}_(.+)\.zip$') { $player = $Matches[1] }

    Write-Step "Fetching '$Item' from history..."
    $zip = Join-Path $env:TEMP "vsync-restore-$([guid]::NewGuid()).zip"
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', "$base/history/$Item", $zip, '--progress') | Out-Null
    if (-not (Test-Path $zip)) { throw "Could not download '$Item' from history." }

    # read db/fwl for accurate manifest fields
    $dir = Join-Path $env:TEMP "vsync-restore-$([guid]::NewGuid())"
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    $rdb = Get-ChildItem $dir -Filter '*.db' | Select-Object -First 1
    $rfwl = Get-ChildItem $dir -Filter '*.fwl' | Select-Object -First 1

    # bump the version past the current cloud one so others see "cloud is newer"
    $prev = Get-Manifest $exe $cfg
    $newVer = 1
    if ($prev -and $prev.PSObject.Properties.Name -contains 'version' -and $prev.version) { try { $newVer = [int]$prev.version + 1 } catch {} }

    Write-Step "Publishing it as the current world..."
    Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('copyto', $zip, "$base/latest.zip", '--progress') | Out-Null

    $manifest = [pscustomobject]@{
        world         = $cfg.WorldName
        version       = $newVer
        uploadedBy    = "$player (restored)"
        uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        dbSize        = $(if ($rdb) { $rdb.Length } else { 0 })
        sha256        = $(if ($rdb) { (Get-FileHash $rdb.FullName -Algorithm SHA256).Hash } else { '' })
        fwlSha256     = $(if ($rfwl) { (Get-FileHash $rfwl.FullName -Algorithm SHA256).Hash } else { '' })
        hosting       = $null
    }
    Set-Manifest $exe $cfg $manifest
    Remove-Item $zip, $dir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Ok "Restored $player's save as the current world. Lock is free."
    Send-Notify $cfg ":rewind: World **$($cfg.WorldName)** was rolled back to **$player**'s earlier save." 'orange'
    Write-Host ''
    Write-Host "  >> Press EXTRACT to download the restored world. <<" -ForegroundColor Cyan
    Write-Host ''
}

# Manually release the host lock without uploading - for when a session is stuck
# (someone forgot to upload, or a watcher died) and the group wants the world freed.
function Do-Unlock {
    $cfg = Get-Config
    $exe = Ensure-Rclone
    $me = Get-PlayerName $cfg
    Write-Title "RELEASE LOCK - free the world for the next host"
    $m = Get-Manifest $exe $cfg
    if (-not $m) { throw "There is no world in the cloud yet - nothing to unlock." }
    if (-not $m.hosting -or -not $m.hosting.player) {
        Write-Ok "The lock is already free - nobody is marked as hosting."
        return
    }
    $holder = $m.hosting.player
    if ($holder -ne $me -and -not $Force) {
        Write-Warn2 "$holder holds the lock, not you."
        if (-not (Confirm-Action "Release $holder's lock anyway?")) { throw "Aborted." }
    }
    $m.hosting = $null
    Set-Manifest $exe $cfg $m
    Write-Ok "Lock released - anyone can EXTRACT and host next."
    Send-Notify $cfg ":unlock: **$me** released the host lock on **$($cfg.WorldName)** - world is free to host." 'green'
    Write-Host ''
}

# Machine-readable list of worlds that exist in the cloud bucket, for the GUI
# dropdown - plus the total bucket size so the GUI can show free-tier usage.
function Do-Worlds {
    $worlds = @()
    $current = ''
    $bucketBytes = 0
    try {
        $cfg = Get-Config
        $current = $cfg.WorldName
        $exe = Ensure-Rclone
        $r = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('lsf', '--dirs-only', "$(Get-RemoteRoot $cfg)/valheim/") -AllowFail
        if ($r.Code -eq 0 -and $r.Output) {
            foreach ($d in ($r.Output -split "`r?`n")) {
                $name = $d.Trim().TrimEnd('/')
                if ($name) { $worlds += $name }
            }
        }
        $sz = Invoke-Rclone -Exe $exe -Cfg $cfg -RcArgs @('size', (Get-RemoteRoot $cfg), '--json') -AllowFail
        if ($sz.Code -eq 0 -and $sz.Output -match '\{.+\}') {
            try { $bucketBytes = [long]((($Matches[0]) | ConvertFrom-Json).bytes) } catch {}
        }
    } catch {}
    Emit-Probe ([ordered]@{ worlds = @($worlds | Sort-Object -Unique); current = $current; bucketBytes = $bucketBytes })
}

# ============================================================
# When dot-sourced (e.g. by the Pester tests or Package.ps1 to reuse helpers),
# $MyInvocation.InvocationName is '.' - skip the action dispatch and just expose
# the functions. A normal -File launch runs the requested action.
if ($MyInvocation.InvocationName -ne '.') {
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
            'Watch'   { Do-Watch }
            'Unlock'  { Do-Unlock }
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
}
