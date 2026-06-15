#Requires -Version 5.1
<#
  ValheimSync GUI - a friendly window over ValheimSync.ps1.
  Big EXTRACT / UPLOAD buttons, a live status panel, and pop-up warnings
  instead of console text. Normally launched via "Valheim Sync.vbs".
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# single instance: a second double-click just tells you it's already open
$script:singleInstance = New-Object System.Threading.Mutex($false, 'Local\ValheimSyncGui')
$gotMutex = $false
try { $gotMutex = $script:singleInstance.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) {
    [System.Windows.Forms.MessageBox]::Show('Valheim Sync is already open - check your taskbar.', 'Valheim Sync',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainScript = Join-Path $ScriptDir 'ValheimSync.ps1'
$ConfigPath = Join-Path $ScriptDir 'config.json'
$RepoSlug   = 'SK000001/valheim-world-sync'
$VersionFile = Join-Path $ScriptDir 'VERSION'
$AppVersion = if (Test-Path $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { '1.0' }
$DefaultWorldsPath = '%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local'

# ---------- shared helpers ----------
function Get-ConfigObj {
    if (Test-Path $ConfigPath) { try { return Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {} }
    return $null
}

# The Valheim saves folder, honouring a customised WorldsPath in config.json
# rather than assuming the default location.
function Get-WorldsFolder {
    $c = Get-ConfigObj
    $p = if ($c -and $c.WorldsPath) { $c.WorldsPath } else { $DefaultWorldsPath }
    [System.Environment]::ExpandEnvironmentVariables($p)
}

# DPAPI helpers (mirror the engine) so Setup can store the B2 key encrypted.
function Protect-Secret([string]$plain) {
    if (-not $plain) { return '' }
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
        return [Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser'))
    } catch { return '' }
}
function Unprotect-Secret([string]$enc) {
    if (-not $enc) { return '' }
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [Convert]::FromBase64String($enc)
        return [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser'))
    } catch { return '' }
}

# ---------- async runner state ----------
$script:busy        = $false
$script:loadingWorlds = $false
$script:proc       = $null
$script:outFile    = $null
$script:errFile    = $null
$script:outOffset  = 0
$script:errOffset  = 0
$script:captured   = $null
$script:onComplete = $null
$script:lastExit   = 0
$script:bucketBytes = 0

# ---------- app icon + desktop shortcut (polish) ----------
$IconPath = Join-Path $ScriptDir 'valheim-sync.ico'

function Ensure-Icon {
    if (Test-Path $IconPath) { return }
    try {
        $bmp = New-Object System.Drawing.Bitmap 64, 64
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::FromArgb(46, 125, 50))
        $font = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString('V', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 64, 64)), $sf)
        $g.Dispose()
        $hicon = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hicon)
        $fs = [System.IO.File]::Open($IconPath, 'Create')
        $icon.Save($fs); $fs.Close()
        $icon.Dispose(); $bmp.Dispose()
    } catch {}
}

function New-DesktopShortcut {
    try {
        Ensure-Icon
        $vbs = Join-Path $ScriptDir 'Valheim Sync.vbs'
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Valheim Sync.lnk'
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = (Join-Path $env:WINDIR 'System32\wscript.exe')
        $sc.Arguments = '"' + $vbs + '"'
        $sc.WorkingDirectory = $ScriptDir
        if (Test-Path $IconPath) { $sc.IconLocation = $IconPath }
        $sc.Description = 'Valheim Sync'
        $sc.Save()
        return $true
    } catch { return $false }
}

# ============================================================
#  Window
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Valheim Sync v$AppVersion"
$form.Size = New-Object System.Drawing.Size(560, 600)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
Ensure-Icon
if (Test-Path $IconPath) { try { $form.Icon = New-Object System.Drawing.Icon($IconPath) } catch {} }

# shared accent colour (Valheim green) used for the header rule and status bar
$cAccent = [System.Drawing.Color]::FromArgb(102, 187, 106)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Valheim Sync'
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 12)
$title.Size = New-Object System.Drawing.Size(250, 28)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'one shared world - no host needs to stay online'
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(130, 134, 144)
$subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
$subtitle.Location = New-Object System.Drawing.Point(22, 40)
$subtitle.Size = New-Object System.Drawing.Size(300, 16)
$form.Controls.Add($subtitle)

# world selector (top-right)
$worldLabel = New-Object System.Windows.Forms.Label
$worldLabel.Text = 'World'
$worldLabel.ForeColor = [System.Drawing.Color]::Gray
$worldLabel.Location = New-Object System.Drawing.Point(332, 22)
$worldLabel.Size = New-Object System.Drawing.Size(44, 18)
$form.Controls.Add($worldLabel)

$worldCombo = New-Object System.Windows.Forms.ComboBox
$worldCombo.Location = New-Object System.Drawing.Point(378, 18)
$worldCombo.Size = New-Object System.Drawing.Size(150, 24)
$worldCombo.DropDownStyle = 'DropDownList'
$worldCombo.FlatStyle = 'Flat'
$worldCombo.BackColor = [System.Drawing.Color]::FromArgb(22, 24, 28)
$worldCombo.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($worldCombo)

# thin accent rule under the header
$headerRule = New-Object System.Windows.Forms.Panel
$headerRule.Location = New-Object System.Drawing.Point(20, 58)
$headerRule.Size = New-Object System.Drawing.Size(508, 2)
$headerRule.BackColor = $cAccent
$form.Controls.Add($headerRule)

# status panel: a state-coloured accent bar on the left + the status text
$statusAccent = New-Object System.Windows.Forms.Panel
$statusAccent.Location = New-Object System.Drawing.Point(20, 62)
$statusAccent.Size = New-Object System.Drawing.Size(5, 124)
$statusAccent.BackColor = [System.Drawing.Color]::FromArgb(70, 74, 84)
$form.Controls.Add($statusAccent)

$statusBox = New-Object System.Windows.Forms.Label
$statusBox.Location = New-Object System.Drawing.Point(25, 62)
$statusBox.Size = New-Object System.Drawing.Size(503, 124)
$statusBox.BackColor = [System.Drawing.Color]::FromArgb(22, 24, 28)
$statusBox.ForeColor = [System.Drawing.Color]::Gainsboro
$statusBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$statusBox.TextAlign = 'TopLeft'
$statusBox.Padding = New-Object System.Windows.Forms.Padding(10)
$statusBox.Text = "  Loading status..."
$form.Controls.Add($statusBox)

# nudge a colour brighter (+) or darker (-) for hover/press states
function Shift-Color($c, [int]$d) {
    $r = [Math]::Max(0, [Math]::Min(255, [int]$c.R + $d))
    $g = [Math]::Max(0, [Math]::Min(255, [int]$c.G + $d))
    $b = [Math]::Max(0, [Math]::Min(255, [int]$c.B + $d))
    [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function New-BigButton($text, $x, $y, $w, $h, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = (Shift-Color $color 20)
    $b.FlatAppearance.MouseDownBackColor = (Shift-Color $color -16)
    $b.BackColor = $color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.TextAlign = 'MiddleCenter'
    $form.Controls.Add($b)
    return $b
}

$btnPlay = New-BigButton "$([char]0x25B6)   PLAY   -   latest world, launch Valheim, upload after" 20 196 508 56 ([System.Drawing.Color]::FromArgb(76, 175, 80))
$btnExtract = New-BigButton "$([char]0x2193)  EXTRACT   -   before you play" 20 260 248 40 ([System.Drawing.Color]::FromArgb(46, 125, 50))
$btnExtract.Font = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$btnUpload  = New-BigButton "$([char]0x2191)  UPLOAD   -   after you play"  280 260 248 40 ([System.Drawing.Color]::FromArgb(21, 101, 192))
$btnUpload.Font = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)

$cSmall = [System.Drawing.Color]::FromArgb(52, 56, 64)
function New-SmallButton($text, $x, $w, $y = 308) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = (Shift-Color $cSmall 18)
    $b.FlatAppearance.MouseDownBackColor = (Shift-Color $cSmall -10)
    $b.BackColor = $cSmall
    $b.ForeColor = [System.Drawing.Color]::Gainsboro
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($b)
    return $b
}

$btnRefresh = New-SmallButton 'Refresh'          20  92
$btnSetup   = New-SmallButton 'Setup'            118 72
$btnRestore = New-SmallButton 'Restore'          196 92
$btnShare   = New-SmallButton 'Share to friends' 294 120
$btnOpen    = New-SmallButton 'Save folder'      420 108
# second row
$btnRelease = New-SmallButton 'Release lock'     20  120 342
$btnViewLog = New-SmallButton 'View log'         146 90  342

# log
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Activity'
$logLabel.ForeColor = [System.Drawing.Color]::Gray
$logLabel.Location = New-Object System.Drawing.Point(20, 382)
$logLabel.Size = New-Object System.Drawing.Size(200, 18)
$form.Controls.Add($logLabel)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(20, 402)
$log.Size = New-Object System.Drawing.Size(508, 144)
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.BackColor = [System.Drawing.Color]::FromArgb(16, 17, 20)
$log.ForeColor = [System.Drawing.Color]::FromArgb(170, 200, 170)
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($log)

# ============================================================
#  Helpers
# ============================================================
function Append-Log([string]$text) {
    if (-not $text) { return }
    $text = $text.TrimEnd("`r", "`n")
    if ($text -eq '') { return }
    $log.AppendText($text + "`r`n")
}

function Set-Buttons([bool]$on) {
    $btnPlay.Enabled = $on
    $btnExtract.Enabled = $on
    $btnUpload.Enabled = $on
    $btnRefresh.Enabled = $on
    $btnSetup.Enabled = $on
    $btnRestore.Enabled = $on
    $btnShare.Enabled = $on
    $btnRelease.Enabled = $on
}

function Read-NewText([string]$path, [ref]$offset) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $fs.Seek($offset.Value, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $txt = $sr.ReadToEnd()
        $offset.Value = $fs.Position
        $sr.Close(); $fs.Close()
        return $txt
    } catch { return '' }
}

function Strip-Marker([string]$text) {
    ($text -split "`r?`n" | Where-Object { $_ -notmatch '^__VSYNC_JSON__' }) -join "`r`n"
}

function Parse-Probe([string]$fullOut) {
    foreach ($line in ($fullOut -split "`r?`n")) {
        if ($line -match '^__VSYNC_JSON__(.+)$') {
            try { return $Matches[1] | ConvertFrom-Json } catch { return $null }
        }
    }
    return $null
}

# timer drives the async log/exit pump
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    $o = Read-NewText $script:outFile ([ref]$script:outOffset)
    $e = Read-NewText $script:errFile ([ref]$script:errOffset)
    if ($o) { [void]$script:captured.Append($o); Append-Log (Strip-Marker $o) }
    if ($e) { Append-Log $e }
    if ($script:proc -and $script:proc.HasExited) {
        $o2 = Read-NewText $script:outFile ([ref]$script:outOffset)
        $e2 = Read-NewText $script:errFile ([ref]$script:errOffset)
        if ($o2) { [void]$script:captured.Append($o2); Append-Log (Strip-Marker $o2) }
        if ($e2) { Append-Log $e2 }
        $timer.Stop()
        $full = $script:captured.ToString()
        $cb = $script:onComplete
        $script:lastExit = $script:proc.ExitCode
        Remove-Item $script:outFile, $script:errFile -Force -ErrorAction SilentlyContinue
        $script:proc = $null
        $script:busy = $false
        Set-Buttons $true
        if ($cb) { & $cb $full }
    }
})

function Invoke-Action([string]$action, [scriptblock]$onComplete, [string[]]$extra) {
    if ($script:busy) { return }
    $script:busy = $true
    Set-Buttons $false
    $script:outFile = [System.IO.Path]::GetTempFileName()
    $script:errFile = [System.IO.Path]::GetTempFileName()
    $script:outOffset = 0
    $script:errOffset = 0
    $script:captured = New-Object System.Text.StringBuilder
    $script:onComplete = $onComplete
    if ($action -ne 'Probe') { Append-Log "> $action ..." }
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MainScript, '-Action', $action, '-Force')
    if ($extra) { $psArgs += $extra }
    $script:proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
        -WorkingDirectory $ScriptDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
    $timer.Start()
}

function Confirm-Box([string]$msg) {
    $r = [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Valheim Sync',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Info-Box([string]$msg) {
    [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Valheim Sync',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Format-Age([string]$utc) {
    if (-not $utc) { return 'unknown' }
    try {
        $span = (Get-Date).ToUniversalTime() - [datetime]::Parse($utc).ToUniversalTime()
        if ($span.TotalMinutes -lt 1)  { return 'just now' }
        if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes) min ago" }
        if ($span.TotalHours -lt 24)   { return "$([int]$span.TotalHours) h ago" }
        return "$([int]$span.TotalDays) d ago"
    } catch { return $utc }
}

# colours reused for status text + the left accent bar
$cGold = [System.Drawing.Color]::FromArgb(235, 189, 90)
$cRed  = [System.Drawing.Color]::FromArgb(214, 92, 82)
$cGray = [System.Drawing.Color]::FromArgb(70, 74, 84)
$cBlue = [System.Drawing.Color]::FromArgb(96, 140, 205)

function Set-StatusColor($fore, $bar) { $statusBox.ForeColor = $fore; $statusAccent.BackColor = $bar }

function Update-Status($p) {
    if (-not $p) { Set-StatusColor ([System.Drawing.Color]::Gray) $cGray; $statusBox.Text = "  Status unavailable."; return }
    if ($p.error) { Set-StatusColor $cRed $cRed; $statusBox.Text = "  Problem: $($p.error)"; return }
    if (-not $p.configured) {
        Set-StatusColor $cGold $cGold
        $statusBox.Text = "  Not set up yet.`r`n`r`n  Click 'Setup' and paste your Backblaze bucket + key."
        return
    }
    $lines = @()
    $lines += "  World : $($p.world)        You : $($p.me)"
    if ($p.cloudEmpty) {
        $lines += "  Cloud : empty - press UPLOAD once to seed the world"
    } else {
        $lines += "  Cloud : last saved by $($p.uploadedBy), $(Format-Age $p.uploadedAtUtc)"
    }
    if ($script:bucketBytes -gt 0) {
        $lines += ("  Bucket: {0:N2} GB used (B2 free tier: 10 GB)" -f ($script:bucketBytes / 1GB))
    }
    $dot = [char]0x25CF
    if ($p.hostingPlayer) {
        $lines += ""
        $suffix = if ($p.lockStale) { " - looks abandoned" } else { "" }
        $lines += "  $dot LOCKED  $($p.hostingPlayer) is hosting now (since $(Format-Age $p.hostingSinceUtc))$suffix"
        Set-StatusColor $cGold $cGold
    } elseif (-not $p.cloudEmpty) {
        $lines += ""
        $lines += "  $dot FREE  nobody is hosting - safe to EXTRACT and play"
        Set-StatusColor ([System.Drawing.Color]::FromArgb(150, 210, 150)) $cAccent
    } else {
        Set-StatusColor ([System.Drawing.Color]::Gainsboro) $cBlue
    }
    if ($p.localExists -and $p.localNewer) {
        $lines += "  Note  : your local copy looks NEWER - UPLOAD it if you just played"
    } elseif ($p.localExists -and $p.cloudNewer) {
        $lines += "  Note  : the cloud copy is NEWER - EXTRACT before you play"
    }
    if ($p.watcherActive) {
        $lines += "  Watcher: on duty - you'll be asked to upload when the game closes"
    }
    $statusBox.Text = ($lines -join "`r`n")
}

function Refresh-Status {
    Invoke-Action 'Probe' { param($out) Update-Status (Parse-Probe $out) }
}

function Set-WorldName([string]$name) {
    try {
        $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($c.WorldName -ne $name) {
            $c.WorldName = $name
            ($c | ConvertTo-Json -Depth 6) | Set-Content $ConfigPath -Encoding UTF8
            Append-Log "Switched to world '$name'."
            Refresh-Status
        }
    } catch { Info-Box "Couldn't switch world: $($_.Exception.Message)" }
}

function Load-Worlds {
    Invoke-Action 'Worlds' {
        param($out)
        $w = Parse-Probe $out
        if ($w -and $w.PSObject.Properties.Name -contains 'bucketBytes') { $script:bucketBytes = [long]$w.bucketBytes }
        $script:loadingWorlds = $true
        $worldCombo.Items.Clear()
        $cur = if ($w) { [string]$w.current } else { '' }
        $names = @()
        if ($w -and $w.worlds) { $names = @($w.worlds) }
        if ($cur -and ($names -notcontains $cur)) { $names = @($cur) + $names }
        foreach ($n in $names) { [void]$worldCombo.Items.Add($n) }
        if ($cur -and $worldCombo.Items.Contains($cur)) { $worldCombo.SelectedItem = $cur }
        elseif ($worldCombo.Items.Count -gt 0) { $worldCombo.SelectedIndex = 0 }
        $script:loadingWorlds = $false
        Refresh-Status
    }
}

$worldCombo.Add_SelectedIndexChanged({
    if ($script:loadingWorlds) { return }
    if ($worldCombo.SelectedItem) { Set-WorldName ([string]$worldCombo.SelectedItem) }
})

# ---------- PLAY helpers ----------
function Start-Game {
    try {
        Start-Process 'steam://rungameid/892970'
        Append-Log 'Launching Valheim via Steam...'
    } catch { Info-Box "Couldn't launch Valheim via Steam - start the game yourself, then play as normal." }
}

# Spawn the engine's background watcher directly (used when PLAY skips the
# extract; an extract starts its own watcher).
function Start-SessionWatcher {
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $MainScript, '-Action', 'Watch') | Out-Null
    } catch {}
}

# ---------- auto-update from GitHub ----------
function Install-Update([string]$url, [string]$expectedHash) {
    try {
        Append-Log "Downloading update..."
        $tmpzip = Join-Path $env:TEMP ("vsync-update-" + [guid]::NewGuid() + ".zip")
        Invoke-WebRequest -Uri $url -OutFile $tmpzip -UseBasicParsing
        # Verify against the checksum published in the release, when present, so a
        # tampered or truncated download can never overwrite the running engine.
        if ($expectedHash) {
            $got = (Get-FileHash $tmpzip -Algorithm SHA256).Hash
            if ($got -ne $expectedHash) {
                Remove-Item $tmpzip -Force -ErrorAction SilentlyContinue
                Info-Box "Update aborted: the download's checksum did not match the one published with the release.`r`n`r`nNothing was changed. Try again later."
                return
            }
            Append-Log "Update verified (SHA256 matches the release)."
        }
        $tmpdir = Join-Path $env:TEMP ("vsync-update-" + [guid]::NewGuid())
        Expand-Archive -Path $tmpzip -DestinationPath $tmpdir -Force
        $root = Get-ChildItem $tmpdir -Directory | Select-Object -First 1
        $src = if ($root) { $root.FullName } else { $tmpdir }
        Get-ChildItem $src -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
            if ($rel -ieq 'config.json') { return }   # never touch the user's key/config
            $dest = Join-Path $ScriptDir $rel
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Copy-Item $_.FullName $dest -Force
        }
        Info-Box "Updated! Click OK to close Valheim Sync, then reopen it to use the new version."
        $form.Close()
    } catch {
        Info-Box "Update failed: $($_.Exception.Message)"
    }
}

function Check-Update {
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -Headers @{ 'User-Agent' = 'valheim-sync' } -TimeoutSec 8
        $latest = ($rel.tag_name -replace '^v', '')
        if (-not $latest) { return }
        if ([version]$latest -gt [version]$AppVersion) {
            $asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
            if (-not $asset) { return }
            # Find a published checksum: either <zip>.sha256 or a SHA256SUMS file.
            $expected = ''
            try {
                $sumAsset = $rel.assets | Where-Object { $_.name -ieq ($asset.name + '.sha256') -or $_.name -ieq 'SHA256SUMS' -or $_.name -ieq 'checksums.txt' } | Select-Object -First 1
                if ($sumAsset) {
                    $txt = Invoke-RestMethod -Uri $sumAsset.browser_download_url -Headers @{ 'User-Agent' = 'valheim-sync' } -TimeoutSec 8
                    foreach ($line in ([string]$txt -split "`r?`n")) {
                        if ($line -match '([0-9A-Fa-f]{64})') {
                            $h = $Matches[1]
                            if ($line -match [regex]::Escape($asset.name) -or $sumAsset.name -ieq ($asset.name + '.sha256')) { $expected = $h.ToUpper(); break }
                            if (-not $expected) { $expected = $h.ToUpper() }
                        }
                    }
                }
            } catch {}
            if (Confirm-Box "A new version is available: v$latest (you have v$AppVersion).`r`n`r`nDownload and install it now? Your config and saves are kept.") {
                Install-Update $asset.browser_download_url $expected
            }
        }
    } catch {}
}

$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 2500
$updateTimer.Add_Tick({ $updateTimer.Stop(); Check-Update })

# Keep the lock status current without clicking Refresh. 5 min, not faster:
# every probe downloads the manifest from B2, which has daily free-tier caps.
$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = 300000
$autoTimer.Add_Tick({ if (-not $script:busy) { Refresh-Status } })

# ============================================================
#  Button behaviour
# ============================================================
$btnPlay.Add_Click({
    Invoke-Action 'Probe' {
        param($out)
        $p = Parse-Probe $out
        Update-Status $p
        if (-not $p) { Info-Box "Couldn't read the cloud status. Check your internet and try Refresh."; return }
        if (-not $p.configured) { Info-Box "Not set up yet. Click 'Setup' first."; return }
        if ($p.cloudEmpty) { Info-Box "There is no world in the cloud yet. Someone needs to press UPLOAD first."; return }
        if ($p.gameRunning) { Info-Box "Valheim is already running."; return }
        # Resume your own session: you hold the lock and your local copy is the
        # newest, so there is nothing to download - just play on.
        if ($p.hostingPlayer -eq $p.me -and $p.localNewer) {
            Append-Log "Resuming your session (your local copy is newest) - skipping the extract."
            Start-SessionWatcher
            Start-Game
            return
        }
        if ($p.hostingPlayer -and $p.hostingPlayer -ne $p.me -and -not $p.lockStale -and
            -not (Confirm-Box "$($p.hostingPlayer) is currently hosting.`r`n`r`nIf you both host, the world will split into two copies. Take over anyway?")) { return }
        if ($p.hostingPlayer -and $p.hostingPlayer -ne $p.me -and $p.lockStale -and
            -not (Confirm-Box "$($p.hostingPlayer)'s session looks abandoned (lock is old).`r`n`r`nTake over and host?")) { return }
        if ($p.localNewer -and
            -not (Confirm-Box "Your local copy looks NEWER than the cloud.`r`n`r`nExtracting will overwrite it with the (older) cloud copy. Continue?")) { return }
        Invoke-Action 'Extract' {
            param($o)
            if ($script:lastExit -ne 0) { Refresh-Status; Info-Box "Extract failed - see the Activity log. The game was not launched."; return }
            Refresh-Status
            Start-Game
        }
    }
})

$btnExtract.Add_Click({
    Invoke-Action 'Probe' {
        param($out)
        $p = Parse-Probe $out
        Update-Status $p
        if (-not $p) { Info-Box "Couldn't read the cloud status. Check your internet and try Refresh."; return }
        if (-not $p.configured) { Info-Box "Not set up yet. Click 'Setup' first."; return }
        if ($p.cloudEmpty) { Info-Box "There is no world in the cloud yet. Someone needs to press UPLOAD first."; return }
        if ($p.gameRunning -and -not (Confirm-Box "Valheim appears to be running. Close it fully first.`r`n`r`nContinue anyway?")) { return }
        if ($p.hostingPlayer -and $p.hostingPlayer -ne $p.me -and -not $p.lockStale -and
            -not (Confirm-Box "$($p.hostingPlayer) is currently hosting.`r`n`r`nIf you both host, the world will split into two copies. Take over anyway?")) { return }
        if ($p.hostingPlayer -and $p.hostingPlayer -ne $p.me -and $p.lockStale -and
            -not (Confirm-Box "$($p.hostingPlayer)'s session looks abandoned (lock is old).`r`n`r`nTake over and host?")) { return }
        if ($p.localNewer -and
            -not (Confirm-Box "Your local copy looks NEWER than the cloud.`r`n`r`nExtracting will overwrite it with the (older) cloud copy. Continue?")) { return }
        Invoke-Action 'Extract' {
            param($o)
            Refresh-Status
            if ($script:lastExit -ne 0) { Info-Box "Extract failed - see the Activity log for details."; return }
            Info-Box "Done! The world is downloaded and you're marked as host.`r`n`r`nStart Valheim and host the world. When you close the game, you'll be asked whether to upload right away (or press UPLOAD here)."
        }
    }
})

$btnUpload.Add_Click({
    Invoke-Action 'Probe' {
        param($out)
        $p = Parse-Probe $out
        Update-Status $p
        if (-not $p) { Info-Box "Couldn't read the cloud status. Check your internet and try Refresh."; return }
        if (-not $p.configured) { Info-Box "Not set up yet. Click 'Setup' first."; return }
        if (-not $p.localExists) { Info-Box "No local world '$($p.world)' found to upload. Did you play it?"; return }
        if ($p.gameRunning -and -not (Confirm-Box "Valheim appears to be running. Close it fully first.`r`n`r`nContinue anyway?")) { return }
        if ($p.cloudNewer -and
            -not (Confirm-Box "The cloud world (saved by $($p.uploadedBy)) is NEWER than your local copy.`r`n`r`nUploading now would overwrite their progress - did you forget to EXTRACT first?`r`n`r`nUpload anyway and overwrite it?")) { return }
        if ($p.cloudDbSize -gt 204800 -and $p.localDbSize -gt 0 -and $p.localDbSize -lt ($p.cloudDbSize * 0.5) -and
            -not (Confirm-Box ("The world you're uploading is much smaller than the cloud copy ({0:N1} MB vs {1:N1} MB).`r`n`r`nThat can mean a wrong or corrupted world. Upload anyway?" -f ($p.localDbSize / 1MB), ($p.cloudDbSize / 1MB)))) { return }
        if ($p.hostingPlayer -and $p.hostingPlayer -ne $p.me -and
            -not (Confirm-Box "$($p.hostingPlayer) holds the host lock, not you.`r`n`r`nUpload your copy as the new latest anyway?")) { return }
        Invoke-Action 'Upload' {
            param($o)
            Load-Worlds   # also refreshes bucket usage + status
            if ($script:lastExit -ne 0) { Info-Box "Upload failed - see the Activity log for details."; return }
            Info-Box "Uploaded! The world is saved to the cloud and the lock is free.`r`n`r`nAnyone can EXTRACT and host next."
        }
    }
})

$btnRefresh.Add_Click({ Refresh-Status })

$btnViewLog.Add_Click({
    $logPath = Join-Path $ScriptDir 'vsync.log'
    if (Test-Path $logPath) { Start-Process notepad.exe $logPath }
    else { Info-Box "No activity log yet ($logPath).`r`n`r`nThe background watcher writes here once you've hosted a session." }
})

$btnRelease.Add_Click({
    Invoke-Action 'Probe' {
        param($out)
        $p = Parse-Probe $out
        Update-Status $p
        if (-not $p) { Info-Box "Couldn't read the cloud status. Check your internet and try Refresh."; return }
        if (-not $p.configured) { Info-Box "Not set up yet. Click 'Setup' first."; return }
        if (-not $p.hostingPlayer) { Info-Box "The lock is already free - nobody is marked as hosting."; return }
        $who = if ($p.hostingPlayer -eq $p.me) { "your" } else { "$($p.hostingPlayer)'s" }
        if (-not (Confirm-Box "Release $who host lock on '$($p.world)'?`r`n`r`nThis frees the world WITHOUT uploading. Use it only if a session is stuck and the holder is not going to upload.")) { return }
        Invoke-Action 'Unlock' {
            param($o)
            Refresh-Status
            if ($script:lastExit -ne 0) { Info-Box "Couldn't release the lock - see the Activity log."; return }
            Info-Box "Lock released - anyone can EXTRACT and host next."
        }
    }
})

# Replace the LOCAL world with a zip from local-backups/ (the cloud is not
# touched). The current local world is zipped first as a safety net.
function Restore-LocalBackup {
    $bdir = Join-Path $ScriptDir 'local-backups'
    $pick = New-Object System.Windows.Forms.OpenFileDialog
    $pick.Title = 'Pick a local backup zip'
    $pick.Filter = 'Backup zips (*.zip)|*.zip'
    if (Test-Path $bdir) { $pick.InitialDirectory = $bdir }
    if ($pick.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    if (-not (Confirm-Box "Replace your LOCAL world with this backup?`r`n`r`n$(Split-Path $pick.FileName -Leaf)`r`n`r`nThe cloud is not touched, and your current local world is backed up first.")) { return }
    try {
        $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $worlds = [System.Environment]::ExpandEnvironmentVariables($c.WorldsPath)
        $db = Join-Path $worlds "$($c.WorldName).db"
        $fwl = Join-Path $worlds "$($c.WorldName).fwl"
        if (Test-Path $db) {
            if (-not (Test-Path $bdir)) { New-Item -ItemType Directory -Path $bdir | Out-Null }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $keep = @($db, $fwl, "$db.old", "$fwl.old") | Where-Object { Test-Path $_ }
            Compress-Archive -Path $keep -DestinationPath (Join-Path $bdir "$($c.WorldName)_pre-localrestore_$stamp.zip") -Force
        }
        Expand-Archive -Path $pick.FileName -DestinationPath $worlds -Force
        Append-Log "Restored local backup: $(Split-Path $pick.FileName -Leaf)"
        Refresh-Status
        Info-Box "Done - your local world was replaced with the backup.`r`n`r`nIf this is the good copy, press UPLOAD to publish it for the group."
    } catch { Info-Box "Local restore failed: $($_.Exception.Message)" }
}

$btnRestore.Add_Click({
    Invoke-Action 'History' {
        param($out)
        $h = Parse-Probe $out
        if (-not $h -or -not $h.history -or $h.history.Count -eq 0) {
            if (Confirm-Box "No saved versions in the cloud history yet.`r`n`r`nRestore your LOCAL world from this PC's backups instead?") { Restore-LocalBackup }
            return
        }

        # build a picker dialog
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Restore a previous save'
        $dlg.Size = New-Object System.Drawing.Size(440, 360)
        $dlg.StartPosition = 'CenterParent'
        $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
        $dlg.BackColor = [System.Drawing.Color]::FromArgb(40, 42, 48)
        $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = 'Pick a save to make the current world (newest first):'
        $lbl.ForeColor = [System.Drawing.Color]::Gainsboro
        $lbl.Location = New-Object System.Drawing.Point(16, 12)
        $lbl.Size = New-Object System.Drawing.Size(400, 18)
        $dlg.Controls.Add($lbl)

        $list = New-Object System.Windows.Forms.ListBox
        $list.Location = New-Object System.Drawing.Point(16, 36)
        $list.Size = New-Object System.Drawing.Size(400, 230)
        $list.BackColor = [System.Drawing.Color]::FromArgb(22, 24, 28)
        $list.ForeColor = [System.Drawing.Color]::Gainsboro
        $files = @()
        foreach ($e in $h.history) {
            $when = $e.when
            try { $when = [datetime]::Parse($e.when).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch {}
            [void]$list.Items.Add("$when    -    $($e.player)")
            $files += $e.file
        }
        $list.SelectedIndex = 0
        $dlg.Controls.Add($list)

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = 'Restore'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $ok.Location = New-Object System.Drawing.Point(232, 278); $ok.Size = New-Object System.Drawing.Size(90, 30)
        $ok.FlatStyle = 'Flat'; $ok.BackColor = [System.Drawing.Color]::FromArgb(176, 96, 21); $ok.ForeColor = 'White'
        $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Cancel'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $cancel.Location = New-Object System.Drawing.Point(328, 278); $cancel.Size = New-Object System.Drawing.Size(88, 30)
        $cancel.FlatStyle = 'Flat'; $cancel.BackColor = [System.Drawing.Color]::FromArgb(55, 58, 66); $cancel.ForeColor = 'Gainsboro'
        $dlg.Controls.Add($cancel); $dlg.CancelButton = $cancel

        $localBtn = New-Object System.Windows.Forms.Button
        $localBtn.Text = 'From this PC...'
        $localBtn.Location = New-Object System.Drawing.Point(16, 278); $localBtn.Size = New-Object System.Drawing.Size(110, 30)
        $localBtn.FlatStyle = 'Flat'; $localBtn.BackColor = [System.Drawing.Color]::FromArgb(55, 58, 66); $localBtn.ForeColor = 'Gainsboro'
        # $this = the button; tag the form so the caller knows to go local
        $localBtn.Add_Click({ $this.FindForm().Tag = 'local'; $this.FindForm().Close() })
        $dlg.Controls.Add($localBtn)

        $dlgResult = $dlg.ShowDialog($form)
        if ($dlg.Tag -eq 'local') { Restore-LocalBackup; return }
        if ($dlgResult -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedIndex -ge 0) {
            $chosen = $files[$list.SelectedIndex]
            if (-not (Confirm-Box "Make this save the current world for everyone?`r`n`r`n$($list.SelectedItem)`r`n`r`nThe current latest stays safe in history.")) { return }
            Invoke-Action 'Restore' {
                param($o)
                Refresh-Status
                if ($script:lastExit -ne 0) { Info-Box "Restore failed - see the Activity log for details."; return }
                Info-Box "Restored. It's now the current world.`r`n`r`nClick EXTRACT to download the restored save."
            } @('-Item', $chosen)
        }
    }
})

$btnShare.Add_Click({
    if (-not (Confirm-Box "This builds a zip on your Desktop (with your B2 key inside) to send to friends.`r`n`r`nOnly share it with people you trust to play on the world. Continue?")) { return }
    $pkg = Join-Path $ScriptDir 'Package.ps1'
    if (-not (Test-Path $pkg)) { Info-Box "Package.ps1 is missing from this folder - re-download Valheim Sync."; return }
    $dest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ValheimSync-for-friends.zip'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pkg | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $dest)) {
        Info-Box "Created 'ValheimSync-for-friends.zip' on your Desktop.`r`n`r`nSend it to your friends - they unzip it and double-click 'Valheim Sync.vbs'."
    } else {
        Info-Box "Couldn't build the zip (exit code $LASTEXITCODE). Try running Package.ps1 in a PowerShell window to see the error."
    }
})

$btnOpen.Add_Click({
    $worlds = Get-WorldsFolder
    if (Test-Path $worlds) { Start-Process explorer.exe $worlds } else { Info-Box "Save folder not found:`r`n$worlds" }
})

# Worlds that exist in the local save folder (one .db per world).
function Get-DetectedWorlds {
    try {
        $wl = Get-WorldsFolder
        if (Test-Path $wl) {
            return @(Get-ChildItem $wl -File | Where-Object { $_.Extension -eq '.db' } |
                ForEach-Object { $_.BaseName } | Sort-Object -Unique)
        }
    } catch {}
    return @()
}

# ---------- Setup dialog ----------
function Show-SetupDialog {
    $cfg = $null
    if (Test-Path $ConfigPath) { try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {} }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Setup - Backblaze B2'
    $dlg.Size = New-Object System.Drawing.Size(440, 560)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(40, 42, 48)
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    function Add-Field($label, $y, $value, $isPassword) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label; $l.ForeColor = [System.Drawing.Color]::Gainsboro
        $l.Location = New-Object System.Drawing.Point(20, $y)
        $l.Size = New-Object System.Drawing.Size(380, 18)
        $dlg.Controls.Add($l)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(20, ($y + 20))
        $t.Size = New-Object System.Drawing.Size(380, 24)
        if ($value) { $t.Text = [string]$value }
        if ($isPassword) { $t.UseSystemPasswordChar = $true }
        $dlg.Controls.Add($t)
        return $t
    }

    # decrypt the stored key for prefill (DPAPI), falling back to a legacy plaintext key
    $existingApp = ''
    if ($cfg) {
        if (($cfg.B2.PSObject.Properties.Name -contains 'AppKeyEnc') -and $cfg.B2.AppKeyEnc) { $existingApp = Unprotect-Secret $cfg.B2.AppKeyEnc }
        elseif (($cfg.B2.PSObject.Properties.Name -contains 'AppKey') -and $cfg.B2.AppKey -and $cfg.B2.AppKey -ne 'PASTE_APP_KEY_HERE') { $existingApp = $cfg.B2.AppKey }
    }

    $tBucket = Add-Field 'Bucket name'        14  ($(if($cfg){$cfg.B2.Bucket})) $false
    $tKey    = Add-Field 'keyID'              62  ($(if($cfg -and $cfg.B2.KeyId -ne 'PASTE_KEY_ID_HERE'){$cfg.B2.KeyId})) $false
    $tApp    = Add-Field 'applicationKey'     110 $existingApp $true

    # world name: editable dropdown pre-filled with the worlds found on this PC,
    # so nobody has to type (and typo) the name by hand
    $lWorld = New-Object System.Windows.Forms.Label
    $lWorld.Text = 'World name (detected from your save folder)'
    $lWorld.ForeColor = [System.Drawing.Color]::Gainsboro
    $lWorld.Location = New-Object System.Drawing.Point(20, 158)
    $lWorld.Size = New-Object System.Drawing.Size(380, 18)
    $dlg.Controls.Add($lWorld)
    $tWorld = New-Object System.Windows.Forms.ComboBox
    $tWorld.DropDownStyle = 'DropDown'
    $tWorld.Location = New-Object System.Drawing.Point(20, 178)
    $tWorld.Size = New-Object System.Drawing.Size(380, 24)
    foreach ($n in (Get-DetectedWorlds)) { [void]$tWorld.Items.Add($n) }
    $tWorld.Text = $(if ($cfg) { $cfg.WorldName } elseif ($tWorld.Items.Count -gt 0) { [string]$tWorld.Items[0] } else { 'sivandarvin' })
    $dlg.Controls.Add($tWorld)
    $tPlayer = Add-Field 'Your name (host lock)' 206 ($(if($cfg -and $cfg.Player){$cfg.Player}else{$env:USERNAME})) $false
    $existingHook = if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'DiscordWebhook')) { $cfg.DiscordWebhook } else { '' }
    $tDiscord = Add-Field 'Discord webhook URL (optional)' 254 $existingHook $false
    $tDiscord.Size = New-Object System.Drawing.Size(300, 24)
    $testBtn = New-Object System.Windows.Forms.Button
    $testBtn.Text = 'Test'
    $testBtn.Location = New-Object System.Drawing.Point(328, 273); $testBtn.Size = New-Object System.Drawing.Size(72, 26)
    $testBtn.FlatStyle = 'Flat'; $testBtn.BackColor = [System.Drawing.Color]::FromArgb(55, 58, 66); $testBtn.ForeColor = 'Gainsboro'
    $testBtn.Tag = $tDiscord   # $this.Tag = the textbox, scope-safe in the handler
    $testBtn.Add_Click({
        $hook = $this.Tag.Text.Trim()
        if (-not $hook) { Info-Box "Paste a Discord webhook URL first."; return }
        try {
            Invoke-RestMethod -Method Post -Uri $hook -ContentType 'application/json' `
                -Body (@{ content = 'Valheim Sync: webhook test - it works!' } | ConvertTo-Json) -TimeoutSec 10 | Out-Null
            Info-Box "Sent! Check the Discord channel."
        } catch { Info-Box "Test failed: $($_.Exception.Message)" }
    })
    $dlg.Controls.Add($testBtn)

    $existingRole = if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'DiscordRoleId')) { $cfg.DiscordRoleId } else { '' }
    $tRole = Add-Field 'Discord role ID to @mention (optional)' 302 $existingRole $false
    $existingNtfy = if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'NtfyUrl')) { $cfg.NtfyUrl } else { '' }
    $tNtfy = Add-Field 'ntfy topic URL (optional, non-Discord groups)' 350 $existingNtfy $false

    $cAuto = New-Object System.Windows.Forms.CheckBox
    $cAuto.Text = 'Upload automatically when I close the game (no prompt)'
    $cAuto.ForeColor = [System.Drawing.Color]::Gainsboro
    $cAuto.Location = New-Object System.Drawing.Point(20, 400)
    $cAuto.Size = New-Object System.Drawing.Size(390, 24)
    $cAuto.Checked = [bool]($cfg -and ($cfg.PSObject.Properties.Name -contains 'AutoUploadOnClose') -and $cfg.AutoUploadOnClose)
    $dlg.Controls.Add($cAuto)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Save & Test'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(224, 440); $ok.Size = New-Object System.Drawing.Size(90, 30)
    $ok.FlatStyle = 'Flat'; $ok.BackColor = [System.Drawing.Color]::FromArgb(21, 101, 192); $ok.ForeColor = 'White'
    $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(320, 440); $cancel.Size = New-Object System.Drawing.Size(80, 30)
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = [System.Drawing.Color]::FromArgb(55, 58, 66); $cancel.ForeColor = 'Gainsboro'
    $dlg.Controls.Add($cancel); $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        if (-not $tBucket.Text -or -not $tKey.Text -or -not $tApp.Text) {
            Info-Box "Bucket, keyID and applicationKey are all required."
            return
        }
        $new = [pscustomobject]@{
            WorldName        = $(if ($tWorld.Text) { $tWorld.Text } else { 'sivandarvin' })
            WorldsPath       = $(if ($cfg -and $cfg.WorldsPath) { $cfg.WorldsPath } else { $DefaultWorldsPath })
            Player           = $tPlayer.Text
            DiscordWebhook   = $tDiscord.Text
            DiscordRoleId    = $tRole.Text.Trim()
            NtfyUrl          = $tNtfy.Text.Trim()
            AutoUploadOnClose = [bool]$cAuto.Checked
            LockStaleHours   = $(if ($cfg -and $cfg.PSObject.Properties.Name -contains 'LockStaleHours' -and $cfg.LockStaleHours) { $cfg.LockStaleHours } else { 6 })
            HistoryKeep      = $(if ($cfg -and $cfg.PSObject.Properties.Name -contains 'HistoryKeep' -and $cfg.HistoryKeep) { $cfg.HistoryKeep } else { 20 })
            # B2 key stored encrypted at rest (DPAPI); Package.ps1 writes plaintext for the friends zip
            B2               = [pscustomobject]@{ Bucket = $tBucket.Text; KeyId = $tKey.Text; AppKeyEnc = (Protect-Secret $tApp.Text) }
        }
        # preserve an advanced custom rclone Remote block if the user added one by hand
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'Remote') -and $cfg.Remote) {
            $new | Add-Member -NotePropertyName Remote -NotePropertyValue $cfg.Remote -Force
        }
        $new | ConvertTo-Json -Depth 6 | Set-Content $ConfigPath -Encoding UTF8
        Append-Log "Saved config.json - testing connection..."
        if (New-DesktopShortcut) { Append-Log "Created a 'Valheim Sync' shortcut on your Desktop." }
        Load-Worlds
    }
}

$btnSetup.Add_Click({ Show-SetupDialog })

# ---------- minimize to tray ----------
# Keep Valheim Sync running quietly as a lock/presence indicator: minimizing
# hides it to the notification area; double-click (or the menu) brings it back.
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Valheim Sync'
if (Test-Path $IconPath) { try { $tray.Icon = New-Object System.Drawing.Icon($IconPath) } catch {} }
if (-not $tray.Icon) { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Visible = $false

function Restore-FromTray {
    $form.Show(); $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate(); $tray.Visible = $false
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Open', $null, { Restore-FromTray })
[void]$trayMenu.Items.Add('Exit', $null, { $tray.Visible = $false; $form.Close() })
$tray.ContextMenuStrip = $trayMenu
$tray.Add_DoubleClick({ Restore-FromTray })

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide(); $tray.Visible = $true
        $tray.ShowBalloonTip(1500, 'Valheim Sync', 'Still running - double-click the tray icon to reopen.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# ============================================================
$form.Add_Shown({
    if (Test-Path $ConfigPath) {
        Load-Worlds
    } else {
        # first run: open Setup straight away instead of a hint in the status box
        Show-SetupDialog   # calls Load-Worlds itself after a successful save
        if (-not (Test-Path $ConfigPath)) { Refresh-Status }
    }
    $updateTimer.Start(); $autoTimer.Start()
})
$form.Add_FormClosing({ if ($timer) { $timer.Stop() }; if ($updateTimer) { $updateTimer.Stop() }; if ($autoTimer) { $autoTimer.Stop() }; if ($tray) { $tray.Visible = $false; $tray.Dispose() } })
[void]$form.ShowDialog()
