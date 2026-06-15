#Requires -Version 5.1
<#
  Pester tests for ValheimSync.ps1's pure logic (no network, no rclone).
  Run from the valheim-sync folder:
    Invoke-Pester .\Tests
  The engine is dot-sourced, which (thanks to the library guard at the bottom of
  ValheimSync.ps1) exposes its functions without running any action.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\ValheimSync.ps1')

Describe 'Get-RemoteRoot' {
    It 'builds a :b2: root from the bucket by default' {
        $cfg = [pscustomobject]@{ B2 = [pscustomobject]@{ Bucket = 'mybucket' } }
        Get-RemoteRoot $cfg | Should Be ':b2:mybucket'
    }
    It 'uses a custom Remote.Root when present and trims a trailing slash' {
        $cfg = [pscustomobject]@{ Remote = [pscustomobject]@{ Root = 'gd:vsync/' }; B2 = [pscustomobject]@{ Bucket = 'x' } }
        Get-RemoteRoot $cfg | Should Be 'gd:vsync'
    }
}

Describe 'Test-Configured' {
    It 'is true for a filled-in B2 block' {
        $cfg = [pscustomobject]@{ B2 = [pscustomobject]@{ Bucket = 'b'; KeyId = 'k' } }
        Test-Configured $cfg | Should Be $true
    }
    It 'is false for the placeholder key id' {
        $cfg = [pscustomobject]@{ B2 = [pscustomobject]@{ Bucket = 'b'; KeyId = 'PASTE_KEY_ID_HERE' } }
        Test-Configured $cfg | Should Be $false
    }
    It 'is true for a custom Remote even with an empty B2 block' {
        $cfg = [pscustomobject]@{ Remote = [pscustomobject]@{ Root = 'gd:vsync' }; B2 = [pscustomobject]@{ Bucket = ''; KeyId = '' } }
        Test-Configured $cfg | Should Be $true
    }
}

Describe 'config getters' {
    It 'defaults LockStaleHours to 6' {
        Get-LockStaleHours ([pscustomobject]@{}) | Should Be 6
    }
    It 'honours a custom LockStaleHours' {
        Get-LockStaleHours ([pscustomobject]@{ LockStaleHours = 12 }) | Should Be 12
    }
    It 'defaults HistoryKeep to 20' {
        Get-HistoryKeep ([pscustomobject]@{}) | Should Be 20
    }
    It 'defaults AutoUploadOnClose to false' {
        Get-AutoUploadOnClose ([pscustomobject]@{}) | Should Be $false
    }
    It 'reads AutoUploadOnClose when set' {
        Get-AutoUploadOnClose ([pscustomobject]@{ AutoUploadOnClose = $true }) | Should Be $true
    }
}

Describe 'Test-LockStale' {
    It 'is false when nobody is hosting' {
        Test-LockStale ([pscustomobject]@{ hosting = $null }) ([pscustomobject]@{}) | Should Be $false
    }
    It 'is true for an old lock with no heartbeat' {
        $old = (Get-Date).ToUniversalTime().AddHours(-7).ToString('o')
        $m = [pscustomobject]@{ hosting = [pscustomobject]@{ player = 'a'; sinceUtc = $old } }
        Test-LockStale $m ([pscustomobject]@{}) | Should Be $true
    }
    It 'is false for an old start but a recent heartbeat' {
        $old = (Get-Date).ToUniversalTime().AddHours(-7).ToString('o')
        $recent = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
        $m = [pscustomobject]@{ hosting = [pscustomobject]@{ player = 'a'; sinceUtc = $old; heartbeatUtc = $recent } }
        Test-LockStale $m ([pscustomobject]@{}) | Should Be $false
    }
    It 'is false for a fresh lock' {
        $recent = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
        $m = [pscustomobject]@{ hosting = [pscustomobject]@{ player = 'a'; sinceUtc = $recent } }
        Test-LockStale $m ([pscustomobject]@{}) | Should Be $false
    }
}

Describe 'Remove-Shortcodes' {
    It 'strips Discord :emoji: shortcodes' {
        Remove-Shortcodes ':red_circle: hello **world**' | Should Be 'hello **world**'
    }
    It 'leaves plain text untouched' {
        Remove-Shortcodes 'just text' | Should Be 'just text'
    }
}

Describe 'Format-Age' {
    It 'reports just now for the current time' {
        Format-Age ((Get-Date).ToUniversalTime().ToString('o')) | Should Be 'just now'
    }
    It 'reports minutes for a recent time' {
        Format-Age ((Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')) | Should Match 'min ago'
    }
    It 'reports hours within a day' {
        Format-Age ((Get-Date).ToUniversalTime().AddHours(-5).ToString('o')) | Should Match 'h ago'
    }
    It 'returns unknown for an empty value' {
        Format-Age '' | Should Be 'unknown'
    }
}

Describe 'DPAPI secret round-trip' {
    It 'unprotects what it protects' {
        $enc = Protect-Secret 'super-secret-123'
        Unprotect-Secret $enc | Should Be 'super-secret-123'
    }
    It 'Get-AppKey reads an encrypted key' {
        $enc = Protect-Secret 'enc-key'
        $cfg = [pscustomobject]@{ B2 = [pscustomobject]@{ KeyId = 'k'; AppKeyEnc = $enc } }
        Get-AppKey $cfg | Should Be 'enc-key'
    }
    It 'Get-AppKey falls back to a plaintext key' {
        $cfg = [pscustomobject]@{ B2 = [pscustomobject]@{ KeyId = 'k'; AppKey = 'plain-key' } }
        Get-AppKey $cfg | Should Be 'plain-key'
    }
}

Describe 'history filename parsing' {
    It 'splits a stamped history name into time and player' {
        $name = '20260615-143000_alice.zip'
        ($name -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})_(.+)\.zip$') | Should Be $true
        $Matches[7] | Should Be 'alice'
    }
    It 'keeps underscores in the player name' {
        $name = '20260615-143000_bob_the_builder.zip'
        [void]($name -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})_(.+)\.zip$')
        $Matches[7] | Should Be 'bob_the_builder'
    }
}

Describe 'Get-Freshness' {
    It 'fallback: flags a newer local copy by mtime when there is no version' {
        $WorldStatePath = Join-Path $env:TEMP "vsync-test-nostate-$([guid]::NewGuid()).json"
        $db = Join-Path $env:TEMP "vsync-test-$([guid]::NewGuid()).db"
        Set-Content $db 'x'
        (Get-Item $db).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
        $m = [pscustomobject]@{ uploadedAtUtc = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o') }
        $f = Get-Freshness ([pscustomobject]@{ WorldName = 'w' }) $m $db
        $f.localNewer | Should Be $true
        $f.cloudNewer | Should Be $false
        Remove-Item $db -Force -ErrorAction SilentlyContinue
    }
    It 'fallback: flags a newer cloud copy by mtime when there is no version' {
        $WorldStatePath = Join-Path $env:TEMP "vsync-test-nostate-$([guid]::NewGuid()).json"
        $db = Join-Path $env:TEMP "vsync-test-$([guid]::NewGuid()).db"
        Set-Content $db 'x'
        (Get-Item $db).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)
        $m = [pscustomobject]@{ uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $f = Get-Freshness ([pscustomobject]@{ WorldName = 'w' }) $m $db
        $f.cloudNewer | Should Be $true
        $f.localNewer | Should Be $false
        Remove-Item $db -Force -ErrorAction SilentlyContinue
    }
    It 'version: cloudNewer when the manifest version is ahead of our marker' {
        $WorldStatePath = Join-Path $env:TEMP "vsync-test-state-$([guid]::NewGuid()).json"
        $db = Join-Path $env:TEMP "vsync-test-$([guid]::NewGuid()).db"
        Set-Content $db 'x'
        $state = [pscustomobject]@{ w = [pscustomobject]@{ version = 2; syncedMtimeUtc = (Get-Item $db).LastWriteTimeUtc.ToString('o'); sha256 = 'h' } }
        $state | ConvertTo-Json -Depth 6 | Set-Content $WorldStatePath -Encoding UTF8
        $m = [pscustomobject]@{ version = 3; uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $f = Get-Freshness ([pscustomobject]@{ WorldName = 'w' }) $m $db
        $f.cloudNewer | Should Be $true
        Remove-Item $db, $WorldStatePath -Force -ErrorAction SilentlyContinue
    }
    It 'version: localNewer when in sync but the db changed since the marker' {
        $WorldStatePath = Join-Path $env:TEMP "vsync-test-state-$([guid]::NewGuid()).json"
        $db = Join-Path $env:TEMP "vsync-test-$([guid]::NewGuid()).db"
        Set-Content $db 'x'
        $synced = (Get-Date).ToUniversalTime().AddHours(-1)
        $state = [pscustomobject]@{ w = [pscustomobject]@{ version = 3; syncedMtimeUtc = $synced.ToString('o'); sha256 = 'h' } }
        $state | ConvertTo-Json -Depth 6 | Set-Content $WorldStatePath -Encoding UTF8
        (Get-Item $db).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
        $m = [pscustomobject]@{ version = 3; uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $f = Get-Freshness ([pscustomobject]@{ WorldName = 'w' }) $m $db
        $f.cloudNewer | Should Be $false
        $f.localNewer | Should Be $true
        Remove-Item $db, $WorldStatePath -Force -ErrorAction SilentlyContinue
    }
}
