# Pester tests for maintain-readiness paths: verify/manifest/dns/service (all mocked).
# No admin, no network, no real service/registry/adapter calls: destructive paths are
# shadowed by global stubs that record call order into $global:SedgTestCalls.
# Requires Pester 5.2+. Run: Invoke-Pester ./tests
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

# Assert the recorded calls contain $Expected as an ordered subsequence.
# Patterns support -like wildcards (never include TestDrive paths in patterns).
function global:Assert-CallOrder([string[]]$Expected) {
    $pos = -1
    foreach ($e in $Expected) {
        $found = -1
        for ($i = $pos + 1; $i -lt $global:SedgTestCalls.Count; $i++) {
            if ([string]$global:SedgTestCalls[$i] -like $e) { $found = $i; break }
        }
        if ($found -lt 0) {
            throw ("Call order mismatch: expected '{0}' after index {1}. Actual: [{2}]" -f $e, $pos, ($global:SedgTestCalls -join ' | '))
        }
        $pos = $found
    }
}

# Stubs/globals the extracted functions expect (global for scoping).
function global:T([string]$Key) { return $Key }
function global:Get-ViInfo([string]$Text) { return $Text }

Import-InstallerFunction 'Verify-Sha256'
Import-InstallerFunction 'Get-ReleaseAssetUrl'
Import-InstallerFunction 'Get-ApprovedManifest'
Import-InstallerFunction 'Get-ManifestProperty'
Import-InstallerFunction 'Get-ManifestString'
Import-InstallerFunction 'Assert-ManifestComponents'
Import-InstallerFunction 'Test-ConfigValid'
Import-InstallerFunction 'Get-UpstreamBlock'
Import-InstallerFunction 'Get-DefaultWinwsArgs'
Import-InstallerFunction 'Get-WinwsParameters'
Import-InstallerFunction 'Backup-DnsSettings'
Import-InstallerFunction 'Restore-DnsSettings'
Import-InstallerFunction 'Start-AllServices'
Import-InstallerFunction 'Stop-AllServices'
Import-InstallerFunction 'Remove-Services'
Import-InstallerFunction 'Create-Services'
Import-InstallerFunction 'Write-WatchdogFile'
Import-InstallerFunction 'Write-State'

# Global recording stubs for every system-touching command the code under test
# reaches. Installed at run phase only; removed in AfterAll so the shared
# session keeps real cmdlets. No SCM, registry, adapter or ACL changes happen.
BeforeAll {
    # $script: fixtures must be written at run phase: Pester 5 discovery-phase
    # assignments are not visible to Its or to the extracted global functions.
    $script:Lang = 'EN'
    $script:InfoVI = @{}
    $script:AllowedReleaseRepos = @('AdguardTeam/dnsproxy', 'bol-van/zapret')
    $script:DefaultWinwsArgsTemplate = '--wf-tcp=80,443 --wf-udp=443 --hostlist="{0}" --dpi-desync=fake,disorder2 --dpi-desync-fooling=badseq --dpi-desync-repeats=6'
    $script:WinwsService = 'SEDG-Maint-Winws'
    $script:DnsProxyService = 'SEDG-Maint-DnsProxy'
    $script:WatchdogTask = 'SEDG-Maint-Watchdog-Test'

    $global:SedgTestCalls = @()
    $global:SedgServicesPresent = @()
    $global:SedgServiceStatus = 'Stopped'

    # Host/step output silenced (Pester keeps its own cached copies, unaffected).
    function global:Write-Host { param($Object, $ForegroundColor, $BackgroundColor, $NoNewline, $ErrorAction) }
    function global:Write-Step { param([string]$Text) }
    function global:Write-Done { param([string]$Text) }

    # Service control (no SCM). Get-Service is one-shot: it answers from the
    # present-set once per name, then reports absence, so Remove/Create wait
    # loops settle immediately instead of polling until their deadline.
    function global:Get-Service { param($Name, $ErrorAction)
        $global:SedgTestCalls += "Get-Service:$Name"
        if ($global:SedgServicesPresent -contains $Name) {
            $global:SedgServicesPresent = @($global:SedgServicesPresent | Where-Object { $_ -ne $Name })
            return [pscustomobject]@{ Name = [string]$Name; Status = [string]$global:SedgServiceStatus }
        }
    }
    function global:Start-Service { param($Name, $ErrorAction) $global:SedgTestCalls += "Start-Service:$Name" }
    function global:Stop-Service { param($Name, [switch]$Force, $ErrorAction) $global:SedgTestCalls += "Stop-Service:$Name" }
    function global:Stop-Process { param($Id, $Name, [switch]$Force, $ErrorAction) $global:SedgTestCalls += 'Stop-Process' }
    function global:Start-Sleep { param($Seconds, $Milliseconds) $global:SedgTestCalls += 'Start-Sleep' }
    # Remove-Services unregisters the task only when it exists (F2 idempotency).
    # Report it present so ordering assertions still exercise the unregister.
    function global:Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ TaskName = [string]$TaskName } }
    function global:Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) $global:SedgTestCalls += "Unregister-ScheduledTask:$TaskName" }

    # Native helpers (no SCM/ACL/DNS changes; keep $LASTEXITCODE at 0).
    function global:sc.exe { $global:SedgTestCalls += ('sc.exe:' + ($args -join ' ')); $global:LASTEXITCODE = 0 }
    function global:icacls.exe { $global:SedgTestCalls += ('icacls.exe:' + ($args -join ' ')); $global:LASTEXITCODE = 0 }
    function global:ipconfig { $global:SedgTestCalls += ('ipconfig:' + ($args -join ' ')) }

    # Network/adapter/DNS layer (no registry or adapter writes).
    function global:Get-NetAdapter { param($Name, $ErrorAction)
        $global:SedgTestCalls += 'Get-NetAdapter'
        return [pscustomobject]@{ Name = 'Ethernet'; InterfaceGuid = '{00000000-0000-0000-0000-000000000042}'; ifIndex = 7 }
    }
    function global:Get-DnsClientServerAddress { param($InterfaceIndex, $ErrorAction)
        $global:SedgTestCalls += 'Get-DnsClientServerAddress'
        return [pscustomobject]@{ ServerAddresses = @('192.168.50.10') }
    }
    function global:Get-NetworkAdapters { param([switch]$IncludeVirtual)
        $global:SedgTestCalls += 'Get-NetworkAdapters'
        return [pscustomobject]@{ Name = 'Ethernet'; InterfaceGuid = '{00000000-0000-0000-0000-000000000042}'; ifIndex = 7 }
    }
    function global:Get-StaticDnsServers { param($InterfaceGuid, $Stack)
        $global:SedgTestCalls += "Get-StaticDnsServers:$Stack"
        # ,@() mirrors the real contract: an empty array must survive
        # pipeline unrolling instead of reading as $null (unreadable key).
        if ([string]$Stack -eq 'Tcpip') { return ,@('10.0.0.1') }
        return ,@()
    }
    function global:Set-SecureAcl { param($Path, $AdminOnly) $global:SedgTestCalls += 'Set-SecureAcl' }
    function global:Set-AdapterDnsStatic { param($AdapterName, $V4, $V6)
        $global:SedgTestCalls += ('Set-AdapterDnsStatic:' + $AdapterName + ':' + (@($V4) + @($V6) -join ','))
    }
    function global:Set-AdapterDnsBoth { param($AdapterName, $V4, $V6)
        $global:SedgTestCalls += ('Set-AdapterDnsBoth:' + $AdapterName + ':' + (@($V4) + @($V6) -join ','))
    }
    function global:Set-AdapterDnsFamily { param($AdapterName, $AddressFamily, [switch]$Dhcp)
        $global:SedgTestCalls += ('Set-AdapterDnsFamily:' + $AdapterName + ':' + $AddressFamily)
    }
    function global:Reset-DnsToDhcp { param($IncludeVirtual) $global:SedgTestCalls += 'Reset-DnsToDhcp' }
    function global:Clear-DnsClientCache { $global:SedgTestCalls += 'Clear-DnsClientCache' }

    # Installer helpers that would otherwise hit the real system.
    function global:Get-OurProcesses { $global:SedgTestCalls += 'Get-OurProcesses'; return @() }
    function global:Log-Port53Owner { $global:SedgTestCalls += 'Log-Port53Owner' }
    function global:Invoke-Nssm { param($Arguments)
        $global:SedgTestCalls += ('Invoke-Nssm:' + (@($Arguments) -join ' '))
        if (@($Arguments).Count -gt 1 -and [string]$Arguments[0] -eq 'install') {
            $global:SedgServicesPresent = @($global:SedgServicesPresent) + [string]$Arguments[1]
        }
    }
}

AfterAll {
    $stubNames = @(
        'Write-Host', 'Write-Step', 'Write-Done',
        'Get-Service', 'Start-Service', 'Stop-Service', 'Stop-Process', 'Start-Sleep',
        'Unregister-ScheduledTask', 'Get-ScheduledTask', 'sc.exe', 'icacls.exe', 'ipconfig',
        'Get-NetAdapter', 'Get-DnsClientServerAddress', 'Get-NetworkAdapters',
        'Get-StaticDnsServers', 'Set-SecureAcl', 'Set-AdapterDnsStatic',
        'Set-AdapterDnsBoth', 'Set-AdapterDnsFamily', 'Reset-DnsToDhcp',
        'Clear-DnsClientCache', 'Get-OurProcesses', 'Log-Port53Owner', 'Invoke-Nssm'
    )
    foreach ($n in $stubNames) {
        Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
    }
    # Nested blocks in this file stub and import installer functions, then remove
    # them in their own AfterAll. Deleting a stub leaves no function at all, so
    # restore the production versions here for every file that runs after this
    # one (Pester shares one session across files).
    foreach ($n in @(
            'Get-StaticDnsServers', 'Set-SecureAcl', 'Set-AdapterDnsStatic', 'Set-AdapterDnsBoth',
            'Set-AdapterDnsFamily', 'Reset-DnsToDhcp', 'Get-OurProcesses', 'Log-Port53Owner',
            'Invoke-Nssm', 'Get-NetworkAdapters', 'Download-File', 'Exit-InstallerMutex',
            'Stop-OpTranscript', 'Exit-Installer', 'Wait-HandoffClosePrompt', 'Set-LocalDns',
            'Get-AdapterDnsSnapshot', 'Restore-AdapterDnsSnapshot', 'Install-CommitComponents',
            'Test-LiveBinariesHealthy', 'Get-ConfiguredUpstream')) {
        try { Import-InstallerFunction $n } catch { }
    }
    # Restore the shared helpers exactly like Installer.Logic.Tests.ps1 leaves them.
    Import-InstallerFunction 'Write-Step'
    Import-InstallerFunction 'Write-Done'
    $global:SedgTestCalls = @()
    $global:SedgServicesPresent = @()
}

Describe 'Verify-Sha256' {
    It 'returns the real SHA-256 when the digest matches' {
        $file = Join-Path $env:TEMP ("sedg-maint-verify-ok-{0}.bin" -f $PID)
        try {
            'verify-payload-ok' | Set-Content -LiteralPath $file -Encoding ASCII -NoNewline
            $expected = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            (Verify-Sha256 -File $file -Expected $expected -Label 'maint-ok') | Should -Be $expected
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    # Guard: without the real function these Should -Throw tests would pass
    # vacuously (CommandNotFound also throws).
    It 'guards: Verify-Sha256 is defined' {
        Get-Command Verify-Sha256 | Should -Not -BeNullOrEmpty
    }
    It 'throws when the digest does not match' {
        $file = Join-Path $env:TEMP ("sedg-maint-verify-bad-{0}.bin" -f $PID)
        try {
            'verify-payload-bad' | Set-Content -LiteralPath $file -Encoding ASCII -NoNewline
            { Verify-Sha256 -File $file -Expected ('0' * 64) -Label 'maint-bad' } | Should -Throw
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    It 'throws when the target file does not exist' {
        $file = Join-Path $env:TEMP ("sedg-maint-verify-missing-{0}.bin" -f $PID)
        { Verify-Sha256 -File $file -Expected ('0' * 64) -Label 'maint-missing' } | Should -Throw
    }
    It 'throws when the expected digest is malformed' {
        $file = Join-Path $env:TEMP ("sedg-maint-verify-malformed-{0}.bin" -f $PID)
        try {
            'verify-payload-malformed' | Set-Content -LiteralPath $file -Encoding ASCII -NoNewline
            { Verify-Sha256 -File $file -Expected 'not-a-sha256' -Label 'maint-malformed' } | Should -Throw
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Approved manifest release URLs' {
    BeforeAll {
        $manifestPath = Join-Path (Split-Path -Parent $global:SEDGInstallerPath) 'approved-releases.json'
        $script:ApprovedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    It 'builds the pinned dnsproxy asset URL from the manifest' {
        $c = $script:ApprovedManifest.components.dnsproxy
        $url = Get-ReleaseAssetUrl $c.repository $c.tag $c.asset
        $url | Should -Be ('https://github.com/{0}/releases/download/{1}/{2}' -f $c.repository, $c.tag, $c.asset)
        $url | Should -Match '^https://github\.com/AdguardTeam/dnsproxy/releases/download/v\d+(\.\d+)*/dnsproxy-windows-amd64-v\d+(\.\d+)*\.zip$'
    }
    It 'builds the pinned zapret asset URL from the manifest' {
        $c = $script:ApprovedManifest.components.zapret
        $url = Get-ReleaseAssetUrl $c.repository $c.tag $c.asset
        $url | Should -Be ('https://github.com/{0}/releases/download/{1}/{2}' -f $c.repository, $c.tag, $c.asset)
        $url | Should -Match '^https://github\.com/bol-van/zapret/releases/download/v\d+(\.\d+)*/zapret-v\d+(\.\d+)*\.zip$'
    }
    It 'uses the pinned https nssm url from the manifest' {
        $c = $script:ApprovedManifest.components.nssm
        $c.url | Should -Match '^https://'
        (Get-ManifestString $c 'url') | Should -Be $c.url
        (Get-ManifestString $c 'mirror') | Should -Be ''
    }
}

Describe 'Get-ApprovedManifest offline' {
    BeforeAll {
        # Save shared maintain state this Describe overwrites, restore after.
        $script:SavedSources = $script:Sources
        $script:SavedManifestCache = $script:ManifestCache
        $script:SavedInstallerVersion = $script:InstallerVersion
        $script:SavedNssmVersion = $script:NssmVersion
        $script:SavedNssmSha256 = $script:NssmSha256
    }
    AfterAll {
        $script:Sources = $script:SavedSources
        $script:ManifestCache = $script:SavedManifestCache
        $script:InstallerVersion = $script:SavedInstallerVersion
        $script:NssmVersion = $script:SavedNssmVersion
        $script:NssmSha256 = $script:SavedNssmSha256
    }
    It 'returns the cache without touching the network' {
        $script:ManifestCache = [pscustomobject]@{ schema = 1; policy = 'approved-only'; cached = $true }
        (Get-ApprovedManifest).cached | Should -Be $true
    }
    It 'falls back to the embedded manifest when no source uri is configured' {
        $script:ManifestCache = $null
        $script:InstallerVersion = '9.9.9-maint-test'
        $script:NssmVersion = '2.24'
        $script:NssmSha256 = ('a' * 64)
        $script:Sources = [pscustomobject]@{ Manifest = ''; ManifestFallback = ''; NssmZip = 'https://nssm.cc/release/nssm-2.24.zip' }
        $m = Get-ApprovedManifest
        $m.schema | Should -Be 1
        $m.policy | Should -Be 'approved-only'
        $m.installer.version | Should -Be '9.9.9-maint-test'
        Assert-ManifestComponents $m
        $m.components.dnsproxy.tag | Should -Be 'v0.86.0'
    }
    It 'hard-fails on a remote manifest older than the last baseline unless -AllowDowngrade' {
        function global:Invoke-WebRequest { param($Uri, $Headers, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
            return [pscustomobject]@{ Content = $global:SedgRemoteManifestJson }
        }
        function global:Write-Warning { param($Message) $global:SedgRemoteWarnings += [string]$Message }
        $savedStateFile = $script:StateFile
        try {
            $global:SedgRemoteWarnings = @()
            $script:ManifestCache = $null
            $script:InstallerVersion = '1.1.0'
            $script:NssmVersion = '2.24'
            $script:NssmSha256 = ('a' * 64)
            $script:Sources = [pscustomobject]@{ Manifest = 'https://manifest.example/approved-releases.json'; ManifestFallback = ''; NssmZip = 'https://nssm.cc/release/nssm-2.24.zip' }
            $global:SedgRemoteManifestJson = (@{
                schema = 1; policy = 'approved-only'
                installer = @{ version = '1.1.0' }
                components = @{ dnsproxy = @{ tag = 'v0.86.0' }; zapret = @{ tag = 'v72.13' } }
            } | ConvertTo-Json -Depth 5)
            $script:StateFile = Join-Path $TestDrive 'r1-state.json'
            '{"InstallerVersion":"1.2.0"}' | Set-Content -LiteralPath $script:StateFile -Encoding UTF8

            { Get-ApprovedManifest } | Should -Throw '*AllowDowngrade*'

            $global:SedgRemoteWarnings = @()
            $script:ManifestCache = $null
            $m = Get-ApprovedManifest -AllowDowngrade
            $m.installer.version | Should -Be '1.1.0'
            (@($global:SedgRemoteWarnings | Where-Object { $_ -match 'older than baseline' }).Count -gt 0) | Should -Be $true
        } finally {
            Remove-Item function:global:Invoke-WebRequest -ErrorAction SilentlyContinue
            Remove-Item function:global:Write-Warning -ErrorAction SilentlyContinue
            $script:StateFile = $savedStateFile
        }
    }
    It 'fails when the primary manifest and the GitHub fallback disagree (TOFU cross-check)' {
        function global:Invoke-WebRequest { param($Uri, $Headers, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
            if ([string]$Uri -match 'raw.githubusercontent') {
                return [pscustomobject]@{ Content = $global:SedgFallbackManifestJson }
            }
            return [pscustomobject]@{ Content = $global:SedgRemoteManifestJson }
        }
        $savedStateFile = $script:StateFile
        try {
            $script:ManifestCache = $null
            $script:InstallerVersion = '1.1.0'
            $script:NssmVersion = '2.24'
            $script:NssmSha256 = ('a' * 64)
            $script:Sources = [pscustomobject]@{ Manifest = 'https://manifest.example/approved-releases.json'; ManifestFallback = 'https://raw.githubusercontent.com/x/y/main/approved-releases.json'; NssmZip = 'https://nssm.cc/release/nssm-2.24.zip' }
            $base = @{
                schema = 1; policy = 'approved-only'
                installer = @{ version = '1.1.0' }
                components = @{
                    dnsproxy = @{ tag = 'v0.86.0'; sha256 = ('b' * 64) }
                    zapret = @{ tag = 'v72.13'; sha256 = ('c' * 64) }
                }
            }
            $global:SedgRemoteManifestJson = ($base | ConvertTo-Json -Depth 5)
            $evil = (@{ schema = 1; policy = 'approved-only'
                installer = @{ version = '1.1.0' }
                components = @{
                    dnsproxy = @{ tag = 'v0.85.0'; sha256 = ('d' * 64) }
                    zapret = @{ tag = 'v72.13'; sha256 = ('c' * 64) }
                } } | ConvertTo-Json -Depth 5)
            $global:SedgFallbackManifestJson = $evil
            $script:StateFile = Join-Path $TestDrive 'r1-xcheck-state.json'
            '{"InstallerVersion":"1.1.0"}' | Set-Content -LiteralPath $script:StateFile -Encoding UTF8

            { Get-ApprovedManifest } | Should -Throw '*cross-check mismatch*'

            $global:SedgFallbackManifestJson = ($base | ConvertTo-Json -Depth 5)
            $script:ManifestCache = $null
            $m = Get-ApprovedManifest
            $m.installer.version | Should -Be '1.1.0'
        } finally {
            Remove-Item function:global:Invoke-WebRequest -ErrorAction SilentlyContinue
            $script:StateFile = $savedStateFile
        }
    }
}

Describe 'Test-ConfigValid' {
    It 'accepts a minimal valid config' {
        $script:ConfigFile = Join-Path $TestDrive 'maint-ok.yaml'
        "listen-ports:`n  - 53`nupstream:`n  - https://x/dns-query`n" | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8 -NoNewline
        (Test-ConfigValid) | Should -Be $true
    }
    It 'rejects junk' {
        $script:ConfigFile = Join-Path $TestDrive 'maint-junk.yaml'
        "hello`n" | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8 -NoNewline
        (Test-ConfigValid) | Should -Be $false
    }
}

Describe 'Winws deployment arguments' {
    It 'default args point the hostlist at the deployed blacklist' {
        $script:ZapretPath = Join-Path $TestDrive 'maint-zapret'
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        $expected = $script:DefaultWinwsArgsTemplate -f (Join-Path $script:ZapretPath 'blacklist.txt')
        (Get-DefaultWinwsArgs) | Should -Be $expected
        (Get-DefaultWinwsArgs) | Should -Match '--hostlist="'
    }
    It 'Get-WinwsParameters falls back to defaults and honors a custom line' {
        $script:ZapretPath = Join-Path $TestDrive 'maint-zapret-2'
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        $script:WinwsArgsFile = Join-Path $script:ZapretPath 'winws-args.txt'
        if (Test-Path -LiteralPath $script:WinwsArgsFile) { Remove-Item -LiteralPath $script:WinwsArgsFile -Force }
        $expected = $script:DefaultWinwsArgsTemplate -f (Join-Path $script:ZapretPath 'blacklist.txt')
        (Get-WinwsParameters) | Should -Be $expected
        '--wf-tcp=443 --custom=1' | Set-Content -LiteralPath $script:WinwsArgsFile -Encoding ASCII
        (Get-WinwsParameters) | Should -Be '--wf-tcp=443 --custom=1'
    }
}

Describe 'DNS backup/restore (mocked)' {
    It 'Backup-DnsSettings snapshots through stubs only' {
        $global:SedgTestCalls = @()
        $script:TempPath = Join-Path $TestDrive 'dns-e1-temp'
        $script:DnsBackupDir = Join-Path $TestDrive 'dns-e1-backup'
        New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path (Join-Path $TestDrive 'dns-e1-legacy') 'dns-backup.json'
        $script:BootstrapTainted = @('1.1.1.1', '8.8.8.8', '2606:4700:4700::1111')

        Backup-DnsSettings

        (Test-Path -LiteralPath $script:DnsBackupSafe -PathType Leaf) | Should -Be $true
        $saved = Get-Content -LiteralPath $script:DnsBackupSafe -Raw | ConvertFrom-Json
        @($saved.Adapters).Count | Should -Be 1
        @($saved.Adapters)[0].InterfaceGuid | Should -Be '{00000000-0000-0000-0000-000000000042}'
        (@($saved.Adapters)[0].V4Static -join ',') | Should -Be '10.0.0.1'
        ($global:SedgTestCalls -join "`n") | Should -Be (@(
            'Get-NetworkAdapters',
            'Get-DnsClientServerAddress',
            'Get-StaticDnsServers:Tcpip',
            'Get-StaticDnsServers:Tcpip6',
            'Set-SecureAcl'
        ) -join "`n")
    }
    It 'Restore-DnsSettings replays the backup through stubs in order' {
        $global:SedgTestCalls = @()
        $script:TempPath = Join-Path $TestDrive 'dns-e2-temp'
        $script:DnsBackupDir = Join-Path $TestDrive 'dns-e2-backup'
        New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path (Join-Path $TestDrive 'dns-e2-legacy') 'dns-backup.json'
        $script:BootstrapTainted = @('1.1.1.1', '8.8.8.8', '2606:4700:4700::1111')

        Backup-DnsSettings
        Restore-DnsSettings

        ($global:SedgTestCalls -join "`n") | Should -Be (@(
            'Get-NetworkAdapters',
            'Get-DnsClientServerAddress',
            'Get-StaticDnsServers:Tcpip',
            'Get-StaticDnsServers:Tcpip6',
            'Set-SecureAcl',
            'Get-NetAdapter',
            'Set-AdapterDnsBoth:Ethernet:10.0.0.1',
            'Clear-DnsClientCache',
            'ipconfig:/flushdns'
        ) -join "`n")
        $global:SedgTestCalls | Should -Not -Contain 'Reset-DnsToDhcp'
        $global:SedgTestCalls | Should -Not -Contain 'Set-AdapterDnsFamily:Ethernet:IPv4'
    }
    It 'tainted first-time backup writes diagnostics but no safe file' {
        $global:SedgTestCalls = @()
        $script:TempPath = Join-Path $TestDrive 'dns-r5-temp'
        $script:DnsBackupDir = Join-Path $TestDrive 'dns-r5-backup'
        New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path (Join-Path $TestDrive 'dns-r5-legacy') 'dns-backup.json'
        $script:BootstrapTainted = @('192.168.50.10')

        Backup-DnsSettings

        (Test-Path -LiteralPath $script:DnsBackupSafe -PathType Leaf) | Should -Be $false
    }
    It 'all-DHCP baseline restore replays per-adapter without a global reset' {
        $global:SedgTestCalls = @()
        $script:TempPath = Join-Path $TestDrive 'dns-r4a-temp'
        $script:DnsBackupDir = Join-Path $TestDrive 'dns-r4a-backup'
        New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path (Join-Path $TestDrive 'dns-r4a-legacy') 'dns-backup.json'
        $script:BootstrapTainted = @('1.1.1.1', '8.8.8.8', '2606:4700:4700::1111')
        @{ Adapters = @(@{ Name = 'Ethernet'; InterfaceGuid = '{00000000-0000-0000-0000-000000000042}'; ifIndex = 7; V4Addresses = @('1.1.1.1'); V6Addresses = @(); V4Static = $null; V6Static = $null }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:DnsBackupSafe -Encoding UTF8

        Restore-DnsSettings

        $global:SedgTestCalls | Should -Contain 'Set-AdapterDnsFamily:Ethernet:IPv4'
        $global:SedgTestCalls | Should -Contain 'Set-AdapterDnsFamily:Ethernet:IPv6'
        $global:SedgTestCalls | Should -Contain 'Clear-DnsClientCache'
        $global:SedgTestCalls | Should -Not -Contain 'Reset-DnsToDhcp'
    }
    It 'restore without any backup file leaves adapters untouched' {
        $global:SedgTestCalls = @()
        $script:TempPath = Join-Path $TestDrive 'dns-r4b-temp'
        $script:DnsBackupDir = Join-Path $TestDrive 'dns-r4b-backup'
        New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path (Join-Path $TestDrive 'dns-r4b-legacy') 'dns-backup.json'
        $script:BootstrapTainted = @('1.1.1.1')

        Restore-DnsSettings

        $global:SedgTestCalls | Should -BeNullOrEmpty
    }
}

Describe 'Service lifecycle (mocked)' {
    It 'Stop-AllServices stops every service in order without touching SCM' {
        $global:SedgTestCalls = @()
        $global:SedgServiceStatus = 'Stopped'
        $global:SedgServicesPresent = @($script:DnsProxyService, $script:WinwsService)

        Stop-AllServices

        ($global:SedgTestCalls -join "`n") | Should -Be (@(
            'Log-Port53Owner',
            "Stop-Service:$($script:DnsProxyService)",
            "Stop-Service:$($script:WinwsService)",
            'Get-OurProcesses',
            "Get-Service:$($script:DnsProxyService)",
            "Get-Service:$($script:WinwsService)",
            'Get-OurProcesses'
        ) -join "`n")
        $global:SedgTestCalls | Should -Not -Contain 'Stop-Process'
    }
    It 'Start-AllServices starts winws then dnsproxy and verifies status' {
        $global:SedgTestCalls = @()
        $global:SedgServiceStatus = 'Running'
        $global:SedgServicesPresent = @($script:DnsProxyService, $script:WinwsService)
        $script:DnsOnly = $false
        $script:DnsProxyPath = Join-Path $TestDrive 'svc-dnsproxy'
        $script:ZapretPath = Join-Path $TestDrive 'svc-zapret'
        $script:ConfigFile = Join-Path $TestDrive 'svc-config.yaml'
        $script:NssmPath = Join-Path (Join-Path $TestDrive 'svc-nssm') 'nssm.cmd'
        New-Item -ItemType Directory -Path $script:DnsProxyPath -Force | Out-Null
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:NssmPath) -Force | Out-Null
        '@exit 0' | Set-Content -LiteralPath $script:NssmPath -Encoding ASCII

        Start-AllServices -DnsOnly:$script:DnsOnly

        ($global:SedgTestCalls -join "`n") | Should -Be (@(
            "Start-Service:$($script:WinwsService)",
            'Start-Sleep',
            "Get-Service:$($script:WinwsService)",
            "Start-Service:$($script:DnsProxyService)",
            'Start-Sleep',
            "Get-Service:$($script:DnsProxyService)"
        ) -join "`n")
    }
    It 'Remove-Services stops then deletes each service via the sc stub' {
        $global:SedgTestCalls = @()
        $global:SedgServiceStatus = 'Stopped'
        $global:SedgServicesPresent = @($script:DnsProxyService, $script:WinwsService)
        $script:NssmPath = Join-Path (Join-Path $TestDrive 'remove-nssm') 'nssm.exe'

        Remove-Services

        ($global:SedgTestCalls -join "`n") | Should -Be (@(
            "Unregister-ScheduledTask:$($script:WatchdogTask)",
            "Get-Service:$($script:WinwsService)",
            "Stop-Service:$($script:WinwsService)",
            "sc.exe:delete $($script:WinwsService)",
            "Get-Service:$($script:DnsProxyService)",
            "Stop-Service:$($script:DnsProxyService)",
            "sc.exe:delete $($script:DnsProxyService)",
            "Get-Service:$($script:WinwsService)",
            "Get-Service:$($script:DnsProxyService)"
        ) -join "`n")
    }
    It 'Create-Services removes, installs and configures through stubs in order' {
        $global:SedgTestCalls = @()
        $global:SedgServiceStatus = 'Stopped'
        $global:SedgServicesPresent = @($script:DnsProxyService, $script:WinwsService)
        $script:DnsOnly = $false
        $script:ZapretPath = Join-Path $TestDrive 'create-zapret'
        $script:DnsProxyPath = Join-Path $TestDrive 'create-dnsproxy'
        $script:InstallPath = Join-Path $TestDrive 'create-install'
        $script:ConfigFile = Join-Path $TestDrive 'create-config.yaml'
        $script:WinwsArgsFile = Join-Path $script:ZapretPath 'winws-args.txt'
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        New-Item -ItemType Directory -Path $script:DnsProxyPath -Force | Out-Null
        New-Item -ItemType Directory -Path $script:InstallPath -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:ZapretPath 'winws.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:DnsProxyPath 'dnsproxy.exe') -Force | Out-Null
        $script:NssmPath = Join-Path $script:InstallPath 'nssm.cmd'
        '@exit 0' | Set-Content -LiteralPath $script:NssmPath -Encoding ASCII

        Create-Services -DnsOnly:$script:DnsOnly

        Assert-CallOrder @(
            "Unregister-ScheduledTask:$($script:WatchdogTask)",
            "Get-Service:$($script:WinwsService)",
            "Stop-Service:$($script:WinwsService)",
            "Get-Service:$($script:DnsProxyService)",
            "Stop-Service:$($script:DnsProxyService)",
            "Invoke-Nssm:install $($script:WinwsService)*",
            "sc.exe:config $($script:WinwsService) depend= Tcpip",
            "Invoke-Nssm:install $($script:DnsProxyService)*",
            "sc.exe:config $($script:DnsProxyService) depend= Tcpip",
            "sc.exe:config $($script:DnsProxyService) start= auto",
            'icacls.exe*',
            "Invoke-Nssm:set $($script:DnsProxyService) ObjectName*",
            "Invoke-Nssm:set $($script:WinwsService) AppExit*",
            "sc.exe:failure $($script:WinwsService)*",
            "Invoke-Nssm:set $($script:DnsProxyService) AppExit*",
            "sc.exe:failureflag $($script:DnsProxyService)*",
            "Get-Service:$($script:WinwsService)",
            "Get-Service:$($script:DnsProxyService)"
        )
        @($global:SedgTestCalls | Where-Object { $_ -like 'Invoke-Nssm:install*' }).Count | Should -Be 2
        @($global:SedgTestCalls | Where-Object { $_ -like 'icacls.exe*' }).Count | Should -Be 2
        @($global:SedgTestCalls | Where-Object { $_ -like 'sc.exe:failure *' }).Count | Should -Be 2
        @($global:SedgTestCalls | Where-Object { $_ -like 'sc.exe:failureflag*' }).Count | Should -Be 2
        $global:SedgTestCalls | Should -Not -Contain 'Stop-Process'
    }
}

Describe 'Cloudflare deploy config parity' {
    It 'wrangler.toml and cloudflare.config.ts agree on name, compat date, route and zone' {
        $root = Split-Path -Parent $PSScriptRoot
        $toml = Get-Content -LiteralPath (Join-Path $root 'cloudflare/wrangler.toml') -Raw
        $ts = Get-Content -LiteralPath (Join-Path $root 'cloudflare/cloudflare.config.ts') -Raw
        $tomlName = [regex]::Match($toml, '(?m)^\s*name\s*=\s*"([^"]+)"').Groups[1].Value
        $tsName = [regex]::Match($ts, 'name:\s*"([^"]+)"').Groups[1].Value
        $tomlName | Should -Not -BeNullOrEmpty
        $tomlName | Should -Be $tsName
        $tomlDate = [regex]::Match($toml, '(?m)^\s*compatibility_date\s*=\s*"([^"]+)"').Groups[1].Value
        $tsDate = [regex]::Match($ts, 'compatibilityDate:\s*"([^"]+)"').Groups[1].Value
        $tomlDate | Should -Not -BeNullOrEmpty
        $tomlDate | Should -Be $tsDate
        $tomlPattern = [regex]::Match($toml, 'pattern\s*=\s*"([^"]+)"').Groups[1].Value
        $tsPattern = [regex]::Match($ts, 'pattern:\s*"([^"]+)"').Groups[1].Value
        $tomlPattern | Should -Not -BeNullOrEmpty
        $tomlPattern | Should -Be $tsPattern
        $tomlZone = [regex]::Match($toml, 'zone_name\s*=\s*"([^"]+)"').Groups[1].Value
        $tsZone = [regex]::Match($ts, 'zone:\s*"([^"]+)"').Groups[1].Value
        $tomlZone | Should -Not -BeNullOrEmpty
        $tomlZone | Should -Be $tsZone
    }
    It 'wrangler.toml and wrangler.config.ts agree on the assets directory' {
        $root = Split-Path -Parent $PSScriptRoot
        $toml = Get-Content -LiteralPath (Join-Path $root 'cloudflare/wrangler.toml') -Raw
        $wts = Get-Content -LiteralPath (Join-Path $root 'cloudflare/wrangler.config.ts') -Raw
        $tomlDir = [regex]::Match($toml, '(?m)^\s*directory\s*=\s*"([^"]+)"').Groups[1].Value
        $wtsDir = [regex]::Match($wts, 'assetsDirectory:\s*"([^"]+)"').Groups[1].Value
        $tomlDir | Should -Not -BeNullOrEmpty
        $tomlDir | Should -Be $wtsDir
    }
}

Describe 'Watchdog script (generated, executed against stubs)' {
    BeforeAll {
        # The generated script calls exit; the call operator keeps that inside
        # the script. Bypass policy so in-process script execution always runs.
        Set-ExecutionPolicy -Scope Process Bypass -Force
        $global:SedgServices = @{}
        $global:SedgWatchdogDns = @('127.0.0.1')
        $global:SedgDnsHealthy = $true
        $global:SedgWatchdogCalls = @()

        function global:Get-Service { param($Name, $ErrorAction)
            $global:SedgWatchdogCalls += "Get-Service:$Name"
            return $global:SedgServices[$Name]
        }
        function global:Start-Service { param($Name, $ErrorAction) $global:SedgWatchdogCalls += "Start-Service:$Name" }
        function global:Start-Sleep { param($Seconds) }
        function global:Resolve-DnsName { param($Name, $Server, [switch]$DnsOnly, [switch]$QuickTimeout, $ErrorAction)
            $global:SedgWatchdogCalls += "Resolve:$Name"
            if (-not $global:SedgDnsHealthy) { throw 'DNS query timed out' }
            return [pscustomobject]@{ Name = $Name }
        }
        function global:Get-NetAdapter { param([switch]$Physical, $ErrorAction)
            $global:SedgWatchdogCalls += ('Get-NetAdapter:' + [bool]$Physical)
            return [pscustomobject]@{ Name = 'Ethernet'; ifIndex = 7; Status = 'Up'; InterfaceDescription = 'Realtek PCIe GbE' }
        }
        function global:Get-DnsClientServerAddress { param($InterfaceIndex, $ErrorAction)
            $global:SedgWatchdogCalls += 'Get-DnsClientServerAddress'
            return [pscustomobject]@{ ServerAddresses = $global:SedgWatchdogDns }
        }
        function global:Set-DnsClientServerAddress { param($InterfaceIndex, $ServerAddresses, $ErrorAction)
            $global:SedgWatchdogCalls += ('SetDnsLocal:' + (@($ServerAddresses) -join ','))
        }
        function global:netsh.exe { $global:SedgWatchdogCalls += ('netsh:' + ($args -join ' ')); $global:LASTEXITCODE = 0 }
        function global:ipconfig { $global:SedgWatchdogCalls += 'ipconfig' }
        function global:Clear-DnsClientCache { $global:SedgWatchdogCalls += 'Clear-DnsClientCache' }

        # Generate the real script through the real writer into $TestDrive.
        $script:InstallPath = Join-Path $TestDrive 'watchdog-install'
        New-Item -ItemType Directory -Path $script:InstallPath -Force | Out-Null
        $script:WatchdogScript = Join-Path $script:InstallPath 'watchdog.ps1'
        Write-WatchdogFile
    }
    AfterAll {
        foreach ($n in @('Get-Service', 'Start-Service', 'Start-Sleep', 'Resolve-DnsName',
                'Get-NetAdapter', 'Get-DnsClientServerAddress', 'Set-DnsClientServerAddress',
                'netsh.exe', 'ipconfig', 'Clear-DnsClientCache')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
    }

    It 'healthy run restarts stopped auto services and clears the failure counter' {
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'gateway-enabled') -Value 'on' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'state.json') -Value '{"Upstream":"https://dns.example/dns-query"}' -Encoding ASCII
        $global:SedgServices = @{
            $script:WinwsService    = [pscustomobject]@{ Name = $script:WinwsService; Status = 'Stopped'; StartType = 'Automatic' }
            $script:DnsProxyService = [pscustomobject]@{ Name = $script:DnsProxyService; Status = 'Stopped'; StartType = 'Automatic' }
        }
        $global:SedgWatchdogDns = @('127.0.0.1')
        $global:SedgDnsHealthy = $true
        Remove-Item -LiteralPath (Join-Path $script:InstallPath 'watchdog-count.txt'), (Join-Path $script:InstallPath 'watchdog-fallback.flag'), (Join-Path $script:InstallPath 'fail-closed') -Force -ErrorAction SilentlyContinue
        $global:SedgWatchdogCalls = @()

        & $script:WatchdogScript

        $global:SedgWatchdogCalls | Should -Contain ('Start-Service:' + $script:WinwsService)
        $global:SedgWatchdogCalls | Should -Contain ('Start-Service:' + $script:DnsProxyService)
        $global:SedgWatchdogCalls | Should -Contain 'Resolve:dns.example'
        Test-Path -LiteralPath (Join-Path $script:InstallPath 'watchdog-count.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:InstallPath 'watchdog-fallback.flag') | Should -BeFalse
    }

    It 'fails open to DHCP after 3 consecutive health-check failures' {
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'gateway-enabled') -Value 'on' -Encoding ASCII
        $global:SedgServices = @{
            'winws-service'    = [pscustomobject]@{ Name = 'winws-service'; Status = 'Running'; StartType = 'Automatic' }
            'dnsproxy-service' = [pscustomobject]@{ Name = 'dnsproxy-service'; Status = 'Running'; StartType = 'Automatic' }
        }
        $global:SedgWatchdogDns = @('127.0.0.1')
        $global:SedgDnsHealthy = $false
        Remove-Item -LiteralPath (Join-Path $script:InstallPath 'watchdog-fallback.flag'), (Join-Path $script:InstallPath 'fail-closed') -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'watchdog-count.txt') -Value '2' -Encoding ASCII -NoNewline
        $global:SedgWatchdogCalls = @()

        & $script:WatchdogScript

        Get-Content -LiteralPath (Join-Path $script:InstallPath 'watchdog-count.txt') -Raw | Should -Be '3'
        @($global:SedgWatchdogCalls | Where-Object { $_ -like 'netsh:*source=dhcp*' }).Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $script:InstallPath 'watchdog-fallback.flag') | Should -BeTrue
    }

    It 'fail-closed marker keeps local DNS instead of falling back' {
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'gateway-enabled') -Value 'on' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'fail-closed') -Value 'fail-closed' -Encoding ASCII
        $global:SedgServices = @{
            'winws-service'    = [pscustomobject]@{ Name = 'winws-service'; Status = 'Running'; StartType = 'Automatic' }
            'dnsproxy-service' = [pscustomobject]@{ Name = 'dnsproxy-service'; Status = 'Running'; StartType = 'Automatic' }
        }
        $global:SedgWatchdogDns = @('127.0.0.1')
        $global:SedgDnsHealthy = $false
        Remove-Item -LiteralPath (Join-Path $script:InstallPath 'watchdog-fallback.flag') -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'watchdog-count.txt') -Value '2' -Encoding ASCII -NoNewline
        $global:SedgWatchdogCalls = @()

        & $script:WatchdogScript

        Get-Content -LiteralPath (Join-Path $script:InstallPath 'watchdog-count.txt') -Raw | Should -Be '3'
        @($global:SedgWatchdogCalls | Where-Object { $_ -like 'netsh:*' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:InstallPath 'watchdog-fallback.flag') | Should -BeFalse
    }

    It 'recovers adapters and clears the flag when DNS is healthy after a fallback' {
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'gateway-enabled') -Value 'on' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'watchdog-fallback.flag') -Value 'fallback' -Encoding ASCII
        $global:SedgServices = @{
            'winws-service'    = [pscustomobject]@{ Name = 'winws-service'; Status = 'Running'; StartType = 'Automatic' }
            'dnsproxy-service' = [pscustomobject]@{ Name = 'dnsproxy-service'; Status = 'Running'; StartType = 'Automatic' }
        }
        # Adapter was switched to DHCP DNS by the earlier fail-open.
        $global:SedgWatchdogDns = @('192.168.50.1')
        $global:SedgDnsHealthy = $true
        Remove-Item -LiteralPath (Join-Path $script:InstallPath 'fail-closed') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:InstallPath 'watchdog-count.txt') -Force -ErrorAction SilentlyContinue
        $global:SedgWatchdogCalls = @()

        & $script:WatchdogScript

        $global:SedgWatchdogCalls | Should -Contain 'SetDnsLocal:127.0.0.1,::1'
        Test-Path -LiteralPath (Join-Path $script:InstallPath 'watchdog-fallback.flag') | Should -BeFalse
    }

    It 'does nothing when the gateway is disabled' {
        Remove-Item -LiteralPath (Join-Path $script:InstallPath 'gateway-enabled') -Force -ErrorAction SilentlyContinue
        $global:SedgWatchdogCalls = @()

        & $script:WatchdogScript

        $global:SedgWatchdogCalls | Should -BeNullOrEmpty
    }

    It 'generated watchdog embeds the configured service names' {
        $gen = Get-Content -LiteralPath $script:WatchdogScript -Raw
        $gen | Should -Match ('\$WinwsService = ''' + $script:WinwsService + '''')
        $gen | Should -Match ('\$DnsProxyService = ''' + $script:DnsProxyService + '''')
        $gen | Should -Not -Match '%%WINWSSERVICE%%'
        $gen | Should -Not -Match '%%DNSPROXYSERVICE%%'
    }
}

Describe 'DNS CIM-to-netsh fallback (mocked)' {
    # Some adapters (CI runner images, freshly reset interfaces) have no
    # MSFT_DNSClientServerAddress objects, so the CIM setter and getter fail.
    # The installer must fall back to netsh instead of aborting.
    BeforeAll {
        $global:SedgDnsFbCalls = @()
        function global:Get-DnsClientServerAddress { param($InterfaceIndex, $ErrorAction)
            throw "No MSFT_DNSClientServerAddress objects found with property 'InterfaceIndex' equal to '$InterfaceIndex'."
        }
        function global:Set-DnsClientServerAddress { param($InterfaceIndex, $ServerAddresses, $ErrorAction)
            throw "No MSFT_DNSClientServerAddress objects found with property 'InterfaceIndex' equal to '$InterfaceIndex'."
        }
        function global:Get-NetAdapter { param($Name, $ErrorAction)
            return [pscustomobject]@{ Name = [string]$Name; ifIndex = 7 }
        }
        function global:netsh.exe { $global:SedgDnsFbCalls += ('netsh:' + ($args -join ' ')); $global:LASTEXITCODE = 0 }

        Import-InstallerFunction 'Set-AdapterDnsFamily'
        Import-InstallerFunction 'Set-AdapterDnsStatic'
        Import-InstallerFunction 'Set-AdapterDnsBoth'
        Import-InstallerFunction 'Get-AdapterDnsSnapshot'
        Import-InstallerFunction 'Restore-AdapterDnsSnapshot'
    }
    AfterAll {
        foreach ($n in @('Get-DnsClientServerAddress', 'Set-DnsClientServerAddress', 'Get-NetAdapter', 'netsh.exe')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Set-AdapterDnsBoth falls back to per-family netsh static sets when CIM objects are absent' {
        $global:SedgDnsFbCalls = @()
        Set-AdapterDnsBoth 'Ethernet' @('127.0.0.1') @('::1')
        ($global:SedgDnsFbCalls | Where-Object { $_ -like 'netsh:interface ipv4 set dnsservers name=Ethernet static 127.0.0.1 primary*' }).Count | Should -Be 1
        ($global:SedgDnsFbCalls | Where-Object { $_ -like 'netsh:interface ipv6 set dnsservers name=Ethernet static ::1 primary*' }).Count | Should -Be 1
    }

    It 'Get-AdapterDnsSnapshot returns an empty snapshot when the adapter has no DNS client entries' {
        $s = Get-AdapterDnsSnapshot 7
        $s | Should -Not -BeNullOrEmpty
        @($s.V4).Count | Should -Be 0
        @($s.V6).Count | Should -Be 0
    }

    It 'Restore-AdapterDnsSnapshot restores DHCP for an empty snapshot' {
        $global:SedgDnsFbCalls = @()
        Restore-AdapterDnsSnapshot 'Ethernet' @{ V4 = @(); V6 = @() }
        ($global:SedgDnsFbCalls | Where-Object { $_ -like 'netsh:interface ipv4 set dnsservers name=Ethernet source=dhcp*' }).Count | Should -Be 1
        ($global:SedgDnsFbCalls | Where-Object { $_ -like 'netsh:interface ipv6 set dnsservers name=Ethernet source=dhcp*' }).Count | Should -Be 1
    }
}

Describe 'Manager self-update (mocked)' {
    # After a manager self-update the process must hand control back to the
    # user (message + Exit-Installer), never re-exec a nested menu and never
    # keep running with a stale version number.
    BeforeAll {
        Import-InstallerFunction 'Update-ManagerFromDist'
        Import-InstallerFunction 'Test-OwnsProcessInvocation'
        $global:SedgUpdateCalls = @()
        function global:Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec, $ErrorAction)
            $global:SedgUpdateCalls += "Invoke-RestMethod:$Uri"
            return [pscustomobject]@{ version = '9.9.9'; sha256 = ('a' * 64) }
        }
        function global:Download-File { param($Url, $Destination)
            $global:SedgUpdateCalls += "Download-File:$Url"
            'new-manager-content' | Set-Content -LiteralPath $Destination -Encoding ASCII
        }
        function global:Get-FileHash { param($LiteralPath, $Algorithm, $ErrorAction)
            return [pscustomobject]@{ Hash = ('a' * 64) }
        }
        function global:Set-SecureAcl { param($Path, $AdminOnly) }
        function global:Exit-InstallerMutex { $global:SedgUpdateCalls += 'Exit-InstallerMutex' }
        function global:Stop-OpTranscript { $global:SedgUpdateCalls += 'Stop-OpTranscript' }
        function global:Exit-Installer { param([int]$Code) $global:SedgUpdateCalls += "Exit-Installer:$Code" }
        function global:Wait-HandoffClosePrompt { $global:SedgUpdateCalls += 'Wait-HandoffClosePrompt' }

        $script:InstallPath = Join-Path $TestDrive 'selfupdate-install'
        $script:TempPath = Join-Path $TestDrive 'selfupdate-staging'
        New-Item -ItemType Directory -Path $script:InstallPath -Force | Out-Null
        $script:InstallerVersion = '1.0.9'
        $script:Sources = @{ Manifest = 'http://127.0.0.1:1/approved-releases.json' }
        $script:Lang = 'EN'
        $script:ForceUpdate = $false
        $script:Clean = $false
        $script:DnsOnly = $false
    }
    AfterAll {
        foreach ($n in @('Invoke-RestMethod', 'Download-File', 'Get-FileHash', 'Set-SecureAcl',
                'Exit-InstallerMutex', 'Stop-OpTranscript', 'Exit-Installer', 'Wait-HandoffClosePrompt')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
    }

    It 'updates the manager, adopts the dist version, and ends the process for script invocations' {
        $global:SedgUpdateCalls = @()
        $script:OwnsProcessOverride = $true
        $result = Update-ManagerFromDist 'Update'
        $result | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:InstallPath 'manager.ps1') | Should -BeTrue
        $script:InstallerVersion | Should -Be '9.9.9'
        $global:SedgUpdateCalls | Should -Contain 'Exit-InstallerMutex'
        $global:SedgUpdateCalls | Should -Contain 'Stop-OpTranscript'
        $global:SedgUpdateCalls | Should -Contain 'Wait-HandoffClosePrompt'
        $global:SedgUpdateCalls | Should -Contain 'Exit-Installer:0'
    }

    It 'skips entirely when the dist version matches the running manager' {
        $global:SedgUpdateCalls = @()
        $script:InstallerVersion = '1.0.9'
        $script:Sources = @{ Manifest = 'http://127.0.0.1:1/approved-releases.json' }
        # Invoke-RestMethod now reports the same version as the installer.
        function global:Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec, $ErrorAction)
            return [pscustomobject]@{ version = '1.0.9'; sha256 = ('a' * 64) }
        }
        $result = Update-ManagerFromDist 'Update'
        $result | Should -BeFalse
        $global:SedgUpdateCalls | Should -Not -Contain 'Exit-Installer:0'
        $global:SedgUpdateCalls | Should -Not -Contain 'Download-File:http://127.0.0.1:1/installer.ps1'
    }
}

Describe 'Manager menu UI (rendered)' {
    BeforeAll {
        Import-InstallerFunction 'Show-MainMenu'
        Import-InstallerFunction 'Get-MenuStatusPanel'
        Import-InstallerFunction 'Write-CreditBanner'
        Import-InstallerFunction 'Write-BoxTop'
        Import-InstallerFunction 'Write-BoxLine'
        Import-InstallerFunction 'Write-BoxSeparator'
        Import-InstallerFunction 'Write-BoxBottom'
        $global:SedgMenuLines = @()
        # Recording Write-Host: capture text + color instead of silencing.
        function global:Write-Host { param($Object, $ForegroundColor, $BackgroundColor, $NoNewline, $Separator)
            $global:SedgMenuLines += @{ Text = ([string]$Object); Fg = $ForegroundColor }
        }
        $global:SedgMenuTexts = @{
            MenuTitle = 'Serverless Edge DNS Gateway + Zapret DPI Bypass'
            MiInstall = 'Install'; MiUpdate = 'Update'; MiStatus = 'Status'; MiRestart = 'Restart'
            MiPause = 'Pause'; MiResume = 'Resume'; MiUpstream = 'Upstream DNS'; MiSysDns = 'System DNS'
            MiCdn = 'CDN test'; MiUninstall = 'Uninstall'; MiLang = 'Language'; MiExit = 'Exit'
            StServices = 'Services'; StNetwork = 'Network'; MnUpstream = 'Upstream'
            MnLocalDns = 'Local DNS active (127.0.0.1)'; MnOtherDns = 'System DNS / DHCP'
            StVerPath = 'Version: {0}    Path: {1}'
        }
        function global:T([string]$Key) { return $global:SedgMenuTexts[$Key] }
        function global:Get-Service { param($Name, $ErrorAction)
            return [pscustomobject]@{ Name = $Name; Status = 'Running' }
        }
        function global:Get-ConfiguredUpstream { return 'https://sdns.example/dns-query' }
        function global:Get-DnsClientServerAddress { param($ErrorAction)
            return [pscustomobject]@{ ServerAddresses = @('127.0.0.1') }
        }
        $script:InstallerVersion = '1.0.9'
        $script:InstallPath = Join-Path $TestDrive 'menu-install'
        $script:DnsProxyService = 'dnsproxy-service'
        $script:WinwsService = 'winws-service'
    }
    AfterAll {
        foreach ($n in @('Get-Service', 'Get-ConfiguredUpstream', 'Get-DnsClientServerAddress')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
        # Restore the key-returning T stub shared with Installer.Logic.Tests.ps1.
        function global:T([string]$Key) { return $Key }
    }

    It 'renders a well-formed box: every border line is exactly 70 columns' {
        $global:SedgMenuLines = @()
        Show-MainMenu
        $borderLines = @($global:SedgMenuLines | Where-Object { $_.Text -match '^[\u2550\u2551\u2554\u2557\u255A\u255D\u2560\u2563]' })
        $borderLines.Count | Should -BeGreaterThan 10
        foreach ($line in $borderLines) {
            $line.Text.Length | Should -Be 70
        }
    }

    It 'renders the full action grid, status panel, and version footer' {
        $global:SedgMenuLines = @()
        Show-MainMenu
        $text = (($global:SedgMenuLines | ForEach-Object { $_.Text }) -join "`n")
        # 1-9 read row-major: [1][2][3] share the first row.
        $row1 = @($global:SedgMenuLines | Where-Object { $_.Text -match '\[ 1\] Install' })[0].Text
        $row1 | Should -Match '\[ 2\] Update'
        $row1 | Should -Match '\[ 3\] Status'
        $text | Should -Match '\[ 4\] Restart'
        $text | Should -Match '\[ 7\] Upstream DNS'
        $text | Should -Match '\[10\] Uninstall'
        $text | Should -Match '\[11\] Language'
        $text | Should -Match '\[OK\] dnsproxy   \[OK\] winws'
        $text | Should -Match 'Local DNS active \(127\.0\.0\.1\)'
        $text | Should -Match 'sdns\.example'
        $text | Should -Match 'THANKS TO BIBICADOTNET'
        $text | Should -Match 'Version: 1\.0\.9'
        # Known labels must fit their columns: no truncation, no empty cells.
        $text | Should -Not -Match '\.\.\.'
        $text | Should -Not -Match '\[ {2}\]'
    }

    It 'keeps Exit in its own band between two double-rule separators' {
        $global:SedgMenuLines = @()
        Show-MainMenu
        $lines = @($global:SedgMenuLines | ForEach-Object { $_.Text })
        $exitIdx = [array]::IndexOf($lines, ($lines | Where-Object { $_ -match '\[ 0\] Exit' } | Select-Object -First 1))
        $exitIdx | Should -BeGreaterThan 0
        $sep = [string][char]0x2560
        $lines[$exitIdx - 1] | Should -BeLike "$sep*"
        $lines[$exitIdx + 1] | Should -BeLike "$sep*"
        # The exit bracket column must align with the action grid's column.
        $vt = [string][char]0x2551
        $lines[$exitIdx] | Should -Match ("^$vt \[ 0\] Exit\s*$vt$")
        $gridIdx = [array]::IndexOf($lines, ($lines | Where-Object { $_ -match '\[ 1\] Install' } | Select-Object -First 1))
        $lines[$gridIdx] | Should -Match "^$vt \[ 1\] Install"
    }

    It 'colors the status rows by state' {
        $global:SedgMenuLines = @()
        Show-MainMenu
        $svcRow = @($global:SedgMenuLines | Where-Object { $_.Text -match '\[OK\] dnsproxy' })[0]
        $svcRow.Fg | Should -Be 'Green'
        $dnsRow = @($global:SedgMenuLines | Where-Object { $_.Text -match 'Local DNS active' })[0]
        $dnsRow.Fg | Should -Be 'Green'
    }
}

Describe 'Write-State upstream_list' {
    It 'writes upstream_list additively alongside legacy fields' {
        $script:InstallerVersion = '9.9.9-test'
        $script:StateFile = Join-Path $TestDrive 'state-list.json'
        Write-State 'dns-v1' 'zap-v2' 'https://a.example/dns-query' @('https://a.example/dns-query', 'https://b.example/dns-query')
        $s = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        $s.InstallerVersion | Should -Be '9.9.9-test'
        $s.DnsProxyRelease | Should -Be 'dns-v1'
        $s.Upstream | Should -Be 'https://a.example/dns-query'
        @($s.upstream_list) | Should -HaveCount 2
        $s.upstream_list[0] | Should -Be 'https://a.example/dns-query'
        $s.upstream_list[1] | Should -Be 'https://b.example/dns-query'
    }
    It 'omits upstream_list when empty (old-reader shape)' {
        $script:InstallerVersion = '9.9.9-test'
        $script:StateFile = Join-Path $TestDrive 'state-nolist.json'
        function global:Get-UpstreamList { return @() }
        try {
            Write-State 'dns-v1' 'zap-v2' 'https://a.example/dns-query'
        } finally {
            Remove-Item function:global:Get-UpstreamList -ErrorAction SilentlyContinue
        }
        $s = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        $s.Upstream | Should -Be 'https://a.example/dns-query'
        ($null -eq $s.upstream_list) | Should -Be $true
    }
}

Describe 'Rollback and live-binary gates (mocked)' {
    BeforeAll {
        Import-InstallerFunction 'Set-LocalDns'
        Import-InstallerFunction 'Get-AdapterDnsSnapshot'
        Import-InstallerFunction 'Restore-AdapterDnsSnapshot'
        Import-InstallerFunction 'Install-CommitComponents'
        Import-InstallerFunction 'Test-LiveBinariesHealthy'
        # Earlier Describes remove/override these shared stubs in their
        # AfterAll, so (re)define them per-It via Reset-F11Stubs instead of
        # relying on any inherited global state.
        function global:Reset-F11Stubs {
            function global:Get-NetAdapter { param($Name, $ErrorAction)
                $global:SedgTestCalls += 'Get-NetAdapter'
                return [pscustomobject]@{ Name = 'Ethernet'; InterfaceGuid = '{00000000-0000-0000-0000-000000000042}'; ifIndex = 7 }
            }
            function global:Get-DnsClientServerAddress { param($InterfaceIndex, $ErrorAction)
                $global:SedgTestCalls += 'Get-DnsClientServerAddress'
                return [pscustomobject]@{ ServerAddresses = @('192.168.50.10') }
            }
            function global:Get-NetworkAdapters { param([switch]$IncludeVirtual)
                $global:SedgTestCalls += 'Get-NetworkAdapters'
                return [pscustomobject]@{ Name = 'Ethernet'; InterfaceGuid = '{00000000-0000-0000-0000-000000000042}'; ifIndex = 7 }
            }
            function global:Set-AdapterDnsStatic { param($AdapterName, $V4, $V6)
                $global:SedgTestCalls += ('Set-AdapterDnsStatic:' + $AdapterName + ':' + (@($V4) + @($V6) -join ','))
            }
            function global:Set-AdapterDnsBoth { param($AdapterName, $V4, $V6)
                $global:SedgTestCalls += ('Set-AdapterDnsBoth:' + $AdapterName + ':' + (@($V4) + @($V6) -join ','))
            }
            function global:Set-AdapterDnsFamily { param($AdapterName, $AddressFamily, [switch]$Dhcp)
                $global:SedgTestCalls += ('Set-AdapterDnsFamily:' + $AdapterName + ':' + $AddressFamily)
            }
        }
    }
    AfterAll {
        foreach ($n in @('Set-LocalDns', 'Get-AdapterDnsSnapshot', 'Restore-AdapterDnsSnapshot', 'Install-CommitComponents', 'Test-LiveBinariesHealthy', 'Reset-F11Stubs')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
    }

    It 'restore matches by GUID when the adapter was renamed' {
        Reset-F11Stubs
        $global:SedgTestCalls = @()
        $script:TempPath = Join-Path $TestDrive 'f11-guid-temp'
        $script:DnsBackupDir = Join-Path $TestDrive 'f11-guid-backup'
        New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path (Join-Path $TestDrive 'f11-guid-legacy') 'dns-backup.json'
        $script:BootstrapTainted = @('1.1.1.1')
        @{ Adapters = @(@{ Name = 'OldEthernet'; InterfaceGuid = '{00000000-0000-0000-0000-000000000042}'; ifIndex = 7; V4Addresses = @('10.0.0.1'); V6Addresses = @(); V4Static = @('10.0.0.1'); V6Static = @() }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:DnsBackupSafe -Encoding UTF8

        Restore-DnsSettings

        $global:SedgTestCalls | Should -Contain 'Set-AdapterDnsBoth:Ethernet:10.0.0.1'
        $global:SedgTestCalls | Should -Not -Contain 'Reset-DnsToDhcp'
    }
    It 'restore falls back to name when the GUID is unknown' {
        Reset-F11Stubs
        $global:SedgTestCalls = @()
        $script:TempPath = Join-Path $TestDrive 'f11-name-temp'
        $script:DnsBackupDir = Join-Path $TestDrive 'f11-name-backup'
        New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null
        $script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
        $script:DnsBackupFile = Join-Path (Join-Path $TestDrive 'f11-name-legacy') 'dns-backup.json'
        $script:BootstrapTainted = @('1.1.1.1')
        @{ Adapters = @(@{ Name = 'Ethernet'; InterfaceGuid = '{99999999-0000-0000-0000-000000000099}'; ifIndex = 7; V4Addresses = @('10.0.0.1'); V6Addresses = @(); V4Static = @('10.0.0.1'); V6Static = @() }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:DnsBackupSafe -Encoding UTF8

        Restore-DnsSettings

        $global:SedgTestCalls | Should -Contain 'Set-AdapterDnsBoth:Ethernet:10.0.0.1'
        $global:SedgTestCalls | Should -Not -Contain 'Reset-DnsToDhcp'
    }
    It 'Set-LocalDns rolls back applied adapters on a mid-loop failure' {
        Reset-F11Stubs
        function global:Get-NetworkAdapters { param([switch]$IncludeVirtual)
            $global:SedgTestCalls += 'Get-NetworkAdapters'
            return @(
                [pscustomobject]@{ Name = 'Eth0'; InterfaceGuid = '{00000000-0000-0000-0000-000000000070}'; ifIndex = 70 },
                [pscustomobject]@{ Name = 'Eth1'; InterfaceGuid = '{00000000-0000-0000-0000-000000000071}'; ifIndex = 71 }
            )
        }
        function global:Set-AdapterDnsBoth { param($AdapterName, $V4, $V6)
            $global:SedgTestCalls += ('Set-AdapterDnsBoth:' + $AdapterName + ':' + (@($V4) + @($V6) -join ','))
            if ([string]$AdapterName -eq 'Eth1') { throw 'simulated Eth1 failure' }
        }
        try {
            $global:SedgTestCalls = @()
            $script:DnsBackupDir = Join-Path $TestDrive 'f11-partial-backup'
            New-Item -ItemType Directory -Path $script:DnsBackupDir -Force | Out-Null

            { Set-LocalDns } | Should -Throw '*Eth1*'
            # Eth0 applied then restored to its 192.168.50.10 snapshot; Eth1 failed once.
            @($global:SedgTestCalls | Where-Object { $_ -eq 'Set-AdapterDnsBoth:Eth0:127.0.0.1,::1' }).Count | Should -Be 1
            $global:SedgTestCalls | Should -Contain 'Set-AdapterDnsBoth:Eth0:192.168.50.10'
            @($global:SedgTestCalls | Where-Object { $_ -eq 'Set-AdapterDnsBoth:Eth1:127.0.0.1,::1' }).Count | Should -Be 1
        } finally {
            Reset-F11Stubs
        }
    }
    It 'commit rollback keeps an identical locked WinDivert64.sys' {
        $root = Join-Path $TestDrive 'f11-commit'
        $script:TempPath = Join-Path $root 'staging'
        $script:DnsProxyPath = Join-Path $root 'live/dnsproxy'
        $script:ZapretPath = Join-Path $root 'live/zapret'
        $script:NssmPath = Join-Path $root 'live/nssm.exe'
        $stageDns = Join-Path $root 'stage/dnsproxy'
        $stageZap = Join-Path $root 'stage/zapret'
        foreach ($d in @($script:DnsProxyPath, $script:ZapretPath, $stageDns, $stageZap)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
        'live-dnsproxy' | Set-Content -LiteralPath (Join-Path $script:DnsProxyPath 'dnsproxy.exe') -Encoding ASCII -NoNewline
        'live-winws' | Set-Content -LiteralPath (Join-Path $script:ZapretPath 'winws.exe') -Encoding ASCII -NoNewline
        'driver-v1' | Set-Content -LiteralPath (Join-Path $script:ZapretPath 'WinDivert64.sys') -Encoding ASCII -NoNewline
        'live-nssm' | Set-Content -LiteralPath $script:NssmPath -Encoding ASCII -NoNewline
        'staged-dnsproxy' | Set-Content -LiteralPath (Join-Path $stageDns 'dnsproxy.exe') -Encoding ASCII -NoNewline
        'staged-winws' | Set-Content -LiteralPath (Join-Path $stageZap 'winws.exe') -Encoding ASCII -NoNewline
        'driver-v1' | Set-Content -LiteralPath (Join-Path $stageZap 'WinDivert64.sys') -Encoding ASCII -NoNewline
        $staged = @{ StageDns = $stageDns; StageZap = $stageZap; StageNssm = (Join-Path $root 'stage/missing-nssm.exe') }

        # Production runs with $ErrorActionPreference='Stop'; the test host
        # defaults to Continue, so force Stop to make the missing-file copy throw.
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            { Install-CommitComponents $staged } | Should -Throw
        } finally {
            $ErrorActionPreference = $oldEap
        }

        (Get-Content -LiteralPath (Join-Path $script:ZapretPath 'WinDivert64.sys') -Raw) | Should -Be 'driver-v1'
        (Get-Content -LiteralPath (Join-Path $script:ZapretPath 'winws.exe') -Raw) | Should -Be 'live-winws'
        (Get-Content -LiteralPath (Join-Path $script:DnsProxyPath 'dnsproxy.exe') -Raw) | Should -Be 'live-dnsproxy'
    }
    It 'Test-LiveBinariesHealthy rejects missing, empty and unreadable binaries' {
        $root = Join-Path $TestDrive 'f11-live'
        $script:DnsProxyPath = Join-Path $root 'dnsproxy'
        $script:ZapretPath = Join-Path $root 'zapret'
        $script:NssmPath = Join-Path $root 'nssm.exe'
        New-Item -ItemType Directory -Path $script:DnsProxyPath -Force | Out-Null
        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
        foreach ($f in @((Join-Path $script:DnsProxyPath 'dnsproxy.exe'), (Join-Path $script:ZapretPath 'winws.exe'), (Join-Path $script:ZapretPath 'cygwin1.dll'), (Join-Path $script:ZapretPath 'WinDivert.dll'), (Join-Path $script:ZapretPath 'WinDivert64.sys'), $script:NssmPath)) {
            'payload' | Set-Content -LiteralPath $f -Encoding ASCII -NoNewline
        }
        (Test-LiveBinariesHealthy) | Should -Be $true
        '' | Set-Content -LiteralPath (Join-Path $script:ZapretPath 'winws.exe') -Encoding ASCII -NoNewline
        (Test-LiveBinariesHealthy) | Should -Be $false
        Remove-Item -LiteralPath (Join-Path $script:ZapretPath 'WinDivert64.sys') -Force
        (Test-LiveBinariesHealthy) | Should -Be $false
    }
}

Describe 'Regression pins (findings 18/19)' {
    BeforeAll {
        # Earlier Describes shadow then remove these globals (menu upstream
        # stub, Write-State list stub), so re-import for run-phase use.
        Import-InstallerFunction 'Test-ConfigValid'
        Import-InstallerFunction 'Get-UpstreamBlock'
        Import-InstallerFunction 'Get-UpstreamList'
        Import-InstallerFunction 'Get-ConfiguredUpstream'
        Import-InstallerFunction 'Set-UpstreamInConfig'
        Import-InstallerFunction 'Ensure-Administrator'
        Import-InstallerFunction 'Get-ApprovedManifest'
    }
    It 'writes a $ upstream exactly once through a comment-first block (no $$ doubling)' {
        $script:ConfigFile = Join-Path $TestDrive 'comment-first-dollar.yaml'
        $script:StateFile = Join-Path $TestDrive 'comment-first-dollar-state.json'
        $script:OptionalUpstreams = @{}
        function global:Ensure-Config { }
        try {
            @"
listen-ports:
  - 53
upstream:
  # rotated weekly, keep standby below
  - https://old.example/dns-query
timeout: 5s
fallback:
  - https://cloudflare-dns.com/dns-query
"@ | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
            $new = 'https://new.example/dns-query?token=abc$def'
            Set-UpstreamInConfig $new
            $out = Get-Content -LiteralPath $script:ConfigFile -Raw
            $out | Should -Match ([regex]::Escape($new))
            $out | Should -Not -Match '\$\$'
            (Get-ConfiguredUpstream) | Should -Be $new
        } finally {
            Remove-Item function:global:Ensure-Config -ErrorAction SilentlyContinue
        }
    }
    It 'commented ::1 and bootstrap 2606:4700:4700::1111 do not imply IPv6' {
        $script:ConfigFile = Join-Path $TestDrive 'commented-v6.yaml'
        @"
listen-addrs:
  - 127.0.0.1
  # - ::1
listen-ports:
  - 53
upstream:
  - https://x.example/dns-query
bootstrap:
  - 2606:4700:4700::1111
"@ | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
        (Test-ConfigValid) | Should -Be $true
        $raw = Get-Content -LiteralPath $script:ConfigFile -Raw
        ([bool]($raw -match '(?m)^\s*-\s*::1\s*$')) | Should -Be $false
    }
    It 'forwards -AllowDowngrade to the elevated process' {
        function global:Test-Administrator { return $false }
        function global:Start-Process { param($FileName, $Verb, $ArgumentList) $global:SedgElevArgs = @($ArgumentList) }
        function global:Exit-Installer { param([int]$Code) }
        $savedSelfPath = $script:SelfPath
        try {
            $script:SelfPath = Join-Path $TestDrive 'elev-self.ps1'
            '# self' | Set-Content -LiteralPath $script:SelfPath -Encoding ASCII
            $global:Action = 'Install'
            $global:AllowDowngrade = $true
            $global:SedgElevArgs = @()
            { Ensure-Administrator } | Should -Throw '*Elevation launched*'
            $global:SedgElevArgs | Should -Contain '-AllowDowngrade'
        } finally {
            Remove-Item function:global:Test-Administrator -ErrorAction SilentlyContinue
            Remove-Item function:global:Start-Process -ErrorAction SilentlyContinue
            Remove-Item function:global:Exit-Installer -ErrorAction SilentlyContinue
            $script:SelfPath = $savedSelfPath
            Remove-Variable -Name Action -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name AllowDowngrade -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name SedgElevArgs -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'fails when the primary manifest and the GitHub fallback disagree on nssm (TOFU cross-check)' {
        function global:Invoke-WebRequest { param($Uri, $Headers, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
            if ([string]$Uri -match 'raw.githubusercontent') {
                return [pscustomobject]@{ Content = $global:SedgFallbackManifestJson }
            }
            return [pscustomobject]@{ Content = $global:SedgRemoteManifestJson }
        }
        $savedStateFile = $script:StateFile
        try {
            $script:ManifestCache = $null
            $script:InstallerVersion = '1.1.0'
            $script:NssmVersion = '2.24'
            $script:NssmSha256 = ('a' * 64)
            $script:Sources = [pscustomobject]@{ Manifest = 'https://manifest.example/approved-releases.json'; ManifestFallback = 'https://raw.githubusercontent.com/x/y/main/approved-releases.json'; NssmZip = 'https://nssm.cc/release/nssm-2.24.zip' }
            $nssmOk = @{ version = '2.24'; asset = 'nssm-2.24.zip'; url = 'https://nssm.cc/release/nssm-2.24.zip'; sha256 = ('e' * 64) }
            $base = @{
                schema = 1; policy = 'approved-only'
                installer = @{ version = '1.1.0' }
                components = @{
                    dnsproxy = @{ repository = 'AdguardTeam/dnsproxy'; tag = 'v0.86.0'; asset = 'dnsproxy-windows-amd64-v0.86.0.zip'; sha256 = ('b' * 64) }
                    zapret = @{ repository = 'bol-van/zapret'; tag = 'v72.13'; asset = 'zapret-v72.13.zip'; sha256 = ('c' * 64) }
                    nssm = $nssmOk
                }
            }
            $global:SedgRemoteManifestJson = ($base | ConvertTo-Json -Depth 5)
            $evilNssm = @{ version = '2.24'; asset = 'nssm-2.24.zip'; url = 'https://nssm.cc/release/nssm-2.24.zip'; sha256 = ('f' * 64) }
            $evil = @{
                schema = 1; policy = 'approved-only'
                installer = @{ version = '1.1.0' }
                components = @{
                    dnsproxy = @{ repository = 'AdguardTeam/dnsproxy'; tag = 'v0.86.0'; asset = 'dnsproxy-windows-amd64-v0.86.0.zip'; sha256 = ('b' * 64) }
                    zapret = @{ repository = 'bol-van/zapret'; tag = 'v72.13'; asset = 'zapret-v72.13.zip'; sha256 = ('c' * 64) }
                    nssm = $evilNssm
                }
            }
            $global:SedgFallbackManifestJson = ($evil | ConvertTo-Json -Depth 5)
            $script:StateFile = Join-Path $TestDrive 'r1-nssm-xcheck-state.json'
            '{"InstallerVersion":"1.1.0"}' | Set-Content -LiteralPath $script:StateFile -Encoding UTF8

            { Get-ApprovedManifest } | Should -Throw '*cross-check mismatch*'
        } finally {
            Remove-Item function:global:Invoke-WebRequest -ErrorAction SilentlyContinue
            $script:StateFile = $savedStateFile
        }
    }
}
