# Regression tests for F1 (NSSM trust anchor) and F2 (Uninstall-All cleanup).
# All system effects are stubbed: no download, extraction, service, task, ACL
# or registry call. Requires Pester 5.2+. Run: Invoke-Pester ./tests
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }
$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'installer.ps1'
$global:SEDGInstallerPath = $installerPath

function global:Import-InstallerFunction([string]$Name) {
    # M9: AST extraction instead of fragile regex.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:SEDGInstallerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "installer.ps1 has $($errors.Count) parse errors" }
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $fn) { throw "installer function not found: $Name" }
    Invoke-Expression (($fn.Extent.Text) -replace '^function ', 'function global:')
}

# Stubs/globals the extracted functions expect (global for scoping).
function global:T([string]$Key) { return $Key }
function global:Get-ViInfo([string]$Text) { return $Text }

Import-InstallerFunction 'Get-ManifestProperty'
Import-InstallerFunction 'Get-ManifestString'
Import-InstallerFunction 'Test-DownloadUrl'
Import-InstallerFunction 'Get-PinnedNssmSource'
Import-InstallerFunction 'Install-StageNssm'
Import-InstallerFunction 'Verify-Sha256'
Import-InstallerFunction 'Remove-Services'
Import-InstallerFunction 'Uninstall-All'

Describe 'F1 NSSM trust anchor' {
    BeforeAll {
        $script:SavedNssmVersion = $script:NssmVersion
        $script:SavedNssmSha256 = $script:NssmSha256
        $script:SavedSources = $script:Sources
        $script:SavedTempPath = $script:TempPath

        $script:Lang = 'EN'
        $script:NssmVersion = '2.24'
        $script:NssmSha256 = ('7' * 64)
        $script:Sources = @{ NssmZip = 'https://nssm.cc/release/nssm-2.24.zip' }
        $script:TempPath = Join-Path $TestDrive 'nssm-temp'
        New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null
        $script:StageRoot = Join-Path $TestDrive 'nssm-stage'
        New-Item -ItemType Directory -Path $script:StageRoot -Force | Out-Null

        $global:SedgDownloads = @()
        $global:SedgExpands = @()
        $global:SedgDownloadPayload = 'pinned-nssm-bytes'
        $global:SedgDownloadFailUrls = @()

        function global:Write-Host { param($Object, $ForegroundColor, $BackgroundColor, $NoNewline, $ErrorAction) }
        function global:Write-Step { param([string]$Text) }
        function global:Write-Done { param([string]$Text) }
        function global:Download-File { param($Url, $Destination)
            $global:SedgDownloads += [string]$Url
            if ($global:SedgDownloadFailUrls -contains [string]$Url) { throw ("download blocked: {0}" -f $Url) }
            Set-Content -LiteralPath $Destination -Value $global:SedgDownloadPayload -Encoding ASCII -NoNewline
        }
        function global:Expand-Zip { param($ZipFile, $Destination)
            $global:SedgExpands += [string]$Destination
        }
        function global:Invoke-Nssm { param($Arguments) $global:SedgTestCalls += ('Invoke-Nssm:' + (@($Arguments) -join ' ')) }
    }

    AfterAll {
        $script:NssmVersion = $script:SavedNssmVersion
        $script:NssmSha256 = $script:SavedNssmSha256
        $script:Sources = $script:SavedSources
        $script:TempPath = $script:SavedTempPath
        # Restore the real functions this file shadowed so later test files
        # exercise production code, not these stubs.
        foreach ($n in @('Write-Host')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
        foreach ($n in @('Write-Step', 'Write-Done', 'Download-File', 'Expand-Zip', 'Invoke-Nssm')) {
            try { Import-InstallerFunction $n } catch { }
        }
    }

    BeforeEach {
        $script:NssmVersion = '2.24'
        $script:NssmSha256 = ('7' * 64)
        $global:SedgDownloads = @()
        $global:SedgExpands = @()
        $global:SedgTestCalls = @()
        $global:SedgDownloadFailUrls = @()
        Get-ChildItem -LiteralPath $script:StageRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'accepts a manifest that confirms the embedded NSSM pin' {
        $m = [pscustomobject]@{
            version = '2.24'; asset = 'nssm-2.24.zip'
            url = 'https://nssm.cc/release/nssm-2.24.zip'; sha256 = ('7' * 64); mirror = ''
        }
        $pin = Get-PinnedNssmSource $m
        $pin.Url | Should -Be 'https://nssm.cc/release/nssm-2.24.zip'
        $pin.Sha256 | Should -Be ('7' * 64)
        $pin.Version | Should -Be '2.24'
    }

    It 'rejects a manifest that changes the NSSM URL and checksum together' {
        $m = [pscustomobject]@{
            version = '2.24'; asset = 'nssm-2.24.zip'
            url = 'https://attacker.example/nssm-2.24.zip'; sha256 = ('e' * 64); mirror = ''
        }
        { Get-PinnedNssmSource $m } | Should -Throw '*embedded NSSM pin*'
    }

    It 'rejects any single-field NSSM change from the manifest' {
        $base = @{ version = '2.24'; asset = 'nssm-2.24.zip'; url = 'https://nssm.cc/release/nssm-2.24.zip'; sha256 = ('7' * 64); mirror = '' }
        foreach ($field in @('version', 'asset', 'url', 'sha256')) {
            $m = [pscustomobject]$base.Clone()
            $m.$field = if ($field -eq 'sha256') { 'f' * 64 } else { 'tampered-value' }
            { Get-PinnedNssmSource $m } | Should -Throw '*embedded NSSM pin*'
        }
    }

    It 'fails closed when the manifest component or embedded pin is invalid' {
        { Get-PinnedNssmSource $null } | Should -Throw '*missing the nssm component*'
        $m = [pscustomobject]@{ version = '2.24'; asset = 'nssm-2.24.zip'; url = 'https://nssm.cc/release/nssm-2.24.zip'; sha256 = ('7' * 64) }
        $saved = $script:NssmSha256
        try {
            $script:NssmSha256 = 'not-a-sha256'
            { Get-PinnedNssmSource $m } | Should -Throw '*SHA-256 pin*'
        } finally { $script:NssmSha256 = $saved }
    }

    It 'stages NSSM only after the pinned digest verifies' {
        $payloadFile = Join-Path $script:TempPath 'source-payload.bin'
        Set-Content -LiteralPath $payloadFile -Value $global:SedgDownloadPayload -Encoding ASCII -NoNewline
        $script:NssmSha256 = (Get-FileHash -LiteralPath $payloadFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $m = [pscustomobject]@{
            version = '2.24'; asset = 'nssm-2.24.zip'
            url = 'https://nssm.cc/release/nssm-2.24.zip'; sha256 = $script:NssmSha256; mirror = ''
        }
        function global:Expand-Zip { param($ZipFile, $Destination)
            $global:SedgExpands += [string]$Destination
            New-Item -ItemType Directory -Path (Join-Path $Destination 'win64') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path (Join-Path $Destination 'win64') 'nssm.exe') -Value 'stub-nssm' -Encoding ASCII -NoNewline
        }
        try {
            $stage = Install-StageNssm $script:StageRoot $m
            (Test-Path -LiteralPath $stage) | Should -Be $true
            @($global:SedgExpands).Count | Should -Be 1
            $global:SedgDownloads | Should -Be @('https://nssm.cc/release/nssm-2.24.zip')
        } finally {
            Remove-Item -LiteralPath ("Function:\Expand-Zip") -Force -ErrorAction SilentlyContinue
            function global:Expand-Zip { param($ZipFile, $Destination) $global:SedgExpands += [string]$Destination }
        }
    }

    It 'does not extract, copy or run NSSM when the digest does not match' {
        $m = [pscustomobject]@{
            version = '2.24'; asset = 'nssm-2.24.zip'
            url = 'https://nssm.cc/release/nssm-2.24.zip'; sha256 = ('7' * 64); mirror = ''
        }
        { Install-StageNssm $script:StageRoot $m } | Should -Throw '*SHA-256 mismatch*'
        @($global:SedgExpands).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:StageRoot 'nssm.exe')) | Should -Be $false
        @($global:SedgTestCalls | Where-Object { $_ -like 'Invoke-Nssm:*' }).Count | Should -Be 0
    }

    It 'verifies the mirror fallback with the same pinned digest' {
        $m = [pscustomobject]@{
            version = '2.24'; asset = 'nssm-2.24.zip'
            url = 'https://nssm.cc/release/nssm-2.24.zip'
            mirror = 'https://mirror.example/nssm-2.24.zip'
            sha256 = ('7' * 64)
        }
        $global:SedgDownloadFailUrls = @('https://nssm.cc/release/nssm-2.24.zip')
        { Install-StageNssm $script:StageRoot $m } | Should -Throw '*SHA-256 mismatch*'
        $global:SedgDownloads | Should -Be @('https://nssm.cc/release/nssm-2.24.zip', 'https://mirror.example/nssm-2.24.zip')
        @($global:SedgExpands).Count | Should -Be 0
    }

    It 'keeps the staging flow wired to the pin (no direct manifest url/sha use)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:SEDGInstallerPath, [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-StageComponents' }, $true)
        $text = $fn.Extent.Text
        $text | Should -Match 'Get-PinnedNssmSource \$manifest\.components\.nssm'
        $text | Should -Match 'Install-StageNssm \$stageRoot \$manifest\.components\.nssm'
        $text | Should -Not -Match 'components\.nssm\.(url|sha256)'
    }
}

Describe 'F2 Uninstall-All cleanup' {
    BeforeAll {
        $script:Lang = 'EN'
        $script:WinwsService = 'SEDG-F2-Winws'
        $script:DnsProxyService = 'SEDG-F2-DnsProxy'
        $script:WatchdogTask = 'SEDG-F2-Watchdog'
        $script:Purge = $false

        $global:SedgTestCalls = @()
        $global:SedgServicesPresent = @()
        $global:SedgStickyServices = @()
        $global:SedgTaskPresent = $false
        $global:SedgFailUnregister = $false
        $global:SedgFakeClock = $false
        $global:SedgClock = [datetime]'2020-01-01'

        function global:Write-Host { param($Object, $ForegroundColor, $BackgroundColor, $NoNewline, $ErrorAction) }
        function global:Write-Step { param([string]$Text) }
        function global:Write-Done { param([string]$Text) }
        function global:Write-CreditBanner { }
        function global:Write-Title { param($Text) }
        function global:Ensure-Administrator { }
        function global:Test-Platform { }
        function global:Enter-InstallerMutex { }
        function global:Exit-InstallerMutex { }
        function global:Start-OpTranscript { param($ForAction) }
        function global:Stop-OpTranscript { }
        function global:Stop-AllServices { $global:SedgTestCalls += 'Stop-AllServices' }
        function global:Restore-DnsSettings { $global:SedgTestCalls += 'Restore-DnsSettings'; $script:DnsRestoreIncomplete = $false }
        function global:Set-GatewayEnabled { param([bool]$Enabled) $global:SedgTestCalls += ('Set-GatewayEnabled:' + $Enabled) }
        function global:Clear-WatchdogState { $global:SedgTestCalls += 'Clear-WatchdogState' }
        function global:Remove-OwnWinDivertDriver { param([switch]$ScheduleIfLocked) $global:SedgTestCalls += 'Remove-OwnWinDivertDriver' }
        function global:Schedule-DeleteTreeOnReboot { param($Path) $global:SedgTestCalls += ('Schedule-DeleteTreeOnReboot:' + $Path) }
        function global:Start-Sleep { param($Seconds, $Milliseconds) $global:SedgTestCalls += 'Start-Sleep' }
        function global:Get-Date {
            if ($global:SedgFakeClock) {
                $global:SedgClock = $global:SedgClock.AddSeconds(1)
                return $global:SedgClock
            }
            return [datetime]::Now
        }
        function global:Get-ScheduledTask { param($TaskName, $ErrorAction)
            $global:SedgTestCalls += "Get-ScheduledTask:$TaskName"
            if ($global:SedgTaskPresent) { return [pscustomobject]@{ TaskName = [string]$TaskName } }
        }
        function global:Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction)
            $global:SedgTestCalls += "Unregister-ScheduledTask:$TaskName"
            if ($global:SedgFailUnregister) { throw 'access denied (test)' }
            $global:SedgTaskPresent = $false
        }
        function global:Get-Service { param($Name, $ErrorAction)
            $global:SedgTestCalls += "Get-Service:$Name"
            if ($global:SedgStickyServices -contains $Name) {
                return [pscustomobject]@{ Name = [string]$Name; Status = 'Stopped' }
            }
            if ($global:SedgServicesPresent -contains $Name) {
                $global:SedgServicesPresent = @($global:SedgServicesPresent | Where-Object { $_ -ne $Name })
                return [pscustomobject]@{ Name = [string]$Name; Status = 'Stopped' }
            }
        }
        function global:Stop-Service { param($Name, [switch]$Force, $ErrorAction) $global:SedgTestCalls += "Stop-Service:$Name" }
        function global:sc.exe { $global:SedgTestCalls += ('sc.exe:' + ($args -join ' ')); $global:LASTEXITCODE = 0 }
    }

    AfterAll {
        # Restore the real functions this file shadowed so later test files
        # exercise production code, not these stubs.
        foreach ($n in @('Write-Host', 'Start-Sleep', 'Get-Date', 'Get-ScheduledTask',
                'Unregister-ScheduledTask', 'Get-Service', 'Stop-Service', 'sc.exe')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
        foreach ($n in @(
                'Write-Step', 'Write-Done', 'Write-CreditBanner', 'Write-Title',
                'Ensure-Administrator', 'Test-Platform', 'Enter-InstallerMutex', 'Exit-InstallerMutex',
                'Start-OpTranscript', 'Stop-OpTranscript', 'Stop-AllServices', 'Restore-DnsSettings',
                'Set-GatewayEnabled', 'Clear-WatchdogState', 'Remove-OwnWinDivertDriver',
                'Schedule-DeleteTreeOnReboot')) {
            try { Import-InstallerFunction $n } catch { }
        }
        $global:SedgTestCalls = @()
    }

    BeforeEach {
        $global:SedgTestCalls = @()
        $global:SedgServicesPresent = @()
        $global:SedgStickyServices = @()
        $global:SedgTaskPresent = $false
        $global:SedgFailUnregister = $false
        $global:SedgFakeClock = $false
        $global:SedgClock = [datetime]'2020-01-01'
        $script:DnsRestoreIncomplete = $false
        $script:Purge = $false

        $script:InstallPath = Join-Path $TestDrive 'uninstall-root'
        $script:ZapretPath = Join-Path $script:InstallPath 'zapret'
        $script:NssmPath = Join-Path $script:InstallPath 'nssm.exe'
        $script:DnsBackupDir = Join-Path $TestDrive 'programdata'
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path $script:InstallPath 'dns-backup.json'
        $script:LangFile = Join-Path $TestDrive 'lang.txt'
        $script:TempPath = Join-Path $TestDrive 'staging'
        if (Test-Path -LiteralPath $script:InstallPath) { Remove-Item -LiteralPath $script:InstallPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'unregisters the watchdog task even when a service never disappears' {
        $global:SedgTaskPresent = $true
        $global:SedgStickyServices = @($script:DnsProxyService)
        $global:SedgServicesPresent = @($script:DnsProxyService)
        $global:SedgFakeClock = $true

        { Remove-Services } | Should -Throw '*Timed out waiting for services*'

        $unregister = [array]::IndexOf($global:SedgTestCalls, "Unregister-ScheduledTask:$($script:WatchdogTask)")
        $delete = [array]::IndexOf($global:SedgTestCalls, "sc.exe:delete $($script:DnsProxyService)")
        $unregister | Should -BeGreaterOrEqual 0
        $delete | Should -BeGreaterOrEqual 0
        $unregister | Should -BeLessThan $delete
    }

    It 'is idempotent when the task and services are already gone' {
        { Remove-Services } | Should -Not -Throw
        $global:SedgTestCalls | Should -Not -Contain "Unregister-ScheduledTask:$($script:WatchdogTask)"
    }

    It 'reports a real task unregister failure instead of swallowing it' {
        $global:SedgTaskPresent = $true
        $global:SedgFailUnregister = $true
        { Remove-Services } | Should -Throw '*Failed to unregister scheduled task*'
    }

    It 'cleans services and the task when the install directory is already gone' {
        $global:SedgTaskPresent = $true
        $global:SedgServicesPresent = @($script:DnsProxyService, $script:WinwsService)

        { Uninstall-All } | Should -Not -Throw

        $global:SedgTestCalls | Should -Contain "Unregister-ScheduledTask:$($script:WatchdogTask)"
        $global:SedgTestCalls | Should -Contain "sc.exe:delete $($script:WinwsService)"
        $global:SedgTestCalls | Should -Contain "sc.exe:delete $($script:DnsProxyService)"
        $global:SedgTestCalls | Should -Not -Contain 'Remove-OwnWinDivertDriver'
    }

    It 'continues independent cleanup after a service timeout and reports failure' {
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:InstallPath 'state.json') -Force | Out-Null
        $global:SedgTaskPresent = $true
        $global:SedgStickyServices = @($script:DnsProxyService)
        $global:SedgServicesPresent = @($script:DnsProxyService)
        $global:SedgFakeClock = $true

        { Uninstall-All } | Should -Throw '*Uninstall incomplete*'

        $global:SedgTestCalls | Should -Contain "Unregister-ScheduledTask:$($script:WatchdogTask)"
        $global:SedgTestCalls | Should -Contain 'Remove-OwnWinDivertDriver'
        (Test-Path -LiteralPath $script:InstallPath) | Should -Be $false
    }

    It 'keeps the normal uninstall flow working and touches only app resources' {
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:InstallPath 'state.json') -Force | Out-Null
        $global:SedgTaskPresent = $true
        $global:SedgServicesPresent = @($script:DnsProxyService, $script:WinwsService)

        { Uninstall-All } | Should -Not -Throw

        (Test-Path -LiteralPath $script:InstallPath) | Should -Be $false
        $global:SedgTestCalls | Should -Contain "Unregister-ScheduledTask:$($script:WatchdogTask)"
        $global:SedgTestCalls | Should -Contain 'Restore-DnsSettings'
        $global:SedgTestCalls | Should -Not -Contain 'Schedule-DeleteTreeOnReboot'
        foreach ($call in @($global:SedgTestCalls | Where-Object { $_ -like 'Get-Service:*' })) {
            $call | Should -Match ('^Get-Service:({0}|{1})$' -f [regex]::Escape($script:WinwsService), [regex]::Escape($script:DnsProxyService))
        }
    }

    It 'schedules reboot deletion instead of claiming success when the tree is locked' {
        # The manager now lives in the engine root, so a running manager holds
        # its own image and the uninstall cannot delete the tree synchronously.
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        $locked = Join-Path $script:InstallPath 'state.json'
        Set-Content -LiteralPath $locked -Value 'locked-by-running-manager' -Encoding ASCII -NoNewline
        $handle = [IO.File]::Open($locked, 'Open', 'Read', 'None')
        try {
            { Uninstall-All } | Should -Not -Throw

            $global:SedgTestCalls | Should -Contain ('Schedule-DeleteTreeOnReboot:' + $script:InstallPath)
            (Test-Path -LiteralPath $script:InstallPath) | Should -BeTrue
        } finally {
            $handle.Dispose()
        }
    }
}
