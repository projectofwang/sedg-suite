# Protocol, status and safe-action tests for installer.ps1 Task 1.
# These tests never set DNS, services, scheduled tasks or config files.
# Requires Pester 5.2+ on Windows PowerShell 5.1.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

$global:SEDGProtocolInstallerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'installer.ps1'
$global:SEDGProtocolPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $global:SEDGProtocolPowerShellExe -PathType Leaf)) {
    $global:SEDGProtocolPowerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
}

function global:Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function global:Invoke-EngineProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [string]$InputText = '',
        [byte[]]$InputBytes = $null,
        [int]$TimeoutMs = 45000,
        [string]$InstallPath = '',
        [hashtable]$Environment = @{}
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $global:SEDGProtocolPowerShellExe
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = Split-Path -Parent $global:SEDGProtocolInstallerPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($InstallPath)) {
        $psi.EnvironmentVariables['SEDG_INSTALL_PATH'] = $InstallPath
    }
    foreach ($name in $Environment.Keys) {
        $psi.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputBytes) {
            $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        } elseif (-not [string]::IsNullOrEmpty($InputText)) {
            $process.StandardInput.WriteLine($InputText)
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { }
            throw "Engine timed out after $TimeoutMs ms: $Arguments"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.Result
            StdErr   = $stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

function global:Invoke-EngineProtocol {
    param(
        [Parameter(Mandatory = $true)][string]$RequestJson,
        [switch]$AllowSeam,
        [switch]$Utf8Bom,
        [string]$InstallPath = '',
        [int]$TimeoutMs = 45000,
        [hashtable]$Environment = @{}
    )
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $global:SEDGProtocolInstallerPath + '" -Protocol jsonl'
    if ($AllowSeam) { $arguments += ' -AllowSeam' }
    $inputBytes = $null
    if ($Utf8Bom) {
        # Send the BOM a Windows PowerShell pipe writer emits on a UTF-8 code
        # page, through the normal -File path so the engine's own decoding is
        # under test.
        $inputBytes = [System.Text.Encoding]::UTF8.GetBytes([string][char]0xFEFF + $RequestJson + "`r`n")
    }
    return Invoke-EngineProcess -Arguments $arguments -InputText $RequestJson -InputBytes $inputBytes -TimeoutMs $TimeoutMs -InstallPath $InstallPath -Environment $Environment
}

function global:Convert-ProtocolOutput {
    param([Parameter(Mandatory = $true)][string]$StdOut)
    $lines = @($StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $objects = @()
    foreach ($line in $lines) {
        $objects += ($line | ConvertFrom-Json -ErrorAction Stop)
    }
    return [pscustomobject]@{
        Lines   = $lines
        Objects = $objects
        Hello   = @($objects | Where-Object { $_.type -eq 'hello' })
        Results = @($objects | Where-Object { $_.type -eq 'result' })
    }
}

function global:New-ProtocolRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        $Args = @{}
    )
    return ([ordered]@{
        type            = 'request'
        protocolVersion = 1
        action          = $Action
        operationId     = [guid]::NewGuid().ToString()
        args            = $Args
    } | ConvertTo-Json -Compress -Depth 6)
}

Describe 'installer.ps1 protocol surface (Task 1)' {
    # Defined in BeforeAll, not at file scope: Installer.Maintain.Tests.ps1
    # imports and later removes this shared name, and this file runs last.
    BeforeAll {
        function global:Get-AdapterDnsSnapshot {
            # Comparable snapshot of every adapter DNS assignment on this host.
            try {
                $rows = @(Get-DnsClientServerAddress -ErrorAction Stop | ForEach-Object {
                    '{0}|{1}|{2}' -f $_.InterfaceAlias, $_.AddressFamily, (@($_.ServerAddresses) -join ',')
                } | Sort-Object)
                return ($rows -join "`n")
            } catch {
                return ''
            }
        }
    }

    It 'parses and remains pure ASCII' {
        $parseTokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($global:SEDGProtocolInstallerPath, [ref]$parseTokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $text = [IO.File]::ReadAllText($global:SEDGProtocolInstallerPath)
        ([regex]::Matches($text, '[^\x00-\x7F]')).Count | Should -Be 0
    }

    It 'adds exactly one script parameter and keeps the -Action ValidateSet' {
        $parseTokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:SEDGProtocolInstallerPath, [ref]$parseTokens, [ref]$parseErrors)
        $parameters = @($ast.ParamBlock.Parameters)
        @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) |
            Should -Be @('Action', 'Upstream', 'Language', 'IncludeCdnTest', 'ForceUpdate', 'Clean', 'DnsOnly', 'Purge', 'FailClosed', 'AllowSeam', 'AllowDowngrade', 'Protocol')

        $protocol = $parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Protocol' }
        $protocolSet = @($protocol.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        $protocolSet.Count | Should -Be 1
        @($protocolSet[0].PositionalArguments.Value) | Should -Be @('none', 'jsonl')
        $protocol.DefaultValue.Value | Should -Be 'none'

        $action = $parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Action' }
        $actionSet = @($action.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        $actionSet.Count | Should -Be 1
        @($actionSet[0].PositionalArguments.Value) |
            Should -Be @('Install', 'Update', 'Pause', 'Resume', 'Restart', 'Uninstall', 'Status', 'SetUpstream', 'SetDns', 'Menu')
        $action.DefaultValue.Value | Should -Be 'Menu'
    }

    It 'emits hello, exactly one result, pure stdout and exit 0 for status' {
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'Status')
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 0
        $parsed.Hello.Count | Should -Be 1
        $parsed.Results.Count | Should -Be 1
        $parsed.Objects[0].type | Should -Be 'hello'
        $parsed.Results[0].ok | Should -BeTrue
        $parsed.Results[0].code | Should -Be 'None'
        @($parsed.Lines | Where-Object { $_ -notmatch '^\{' }).Count | Should -Be 0
    }

    It 'accepts a UTF-8 BOM ahead of the request line' {
        # Regression: Windows PowerShell pipe writers emit a UTF-8 BOM when the
        # ANSI code page is 65001, which made the engine reject every request.
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'Status') -Utf8Bom
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 0
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeTrue
    }

    It 'returns all eight status probes with valid discriminants' {
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'Status')
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $snapshot = $parsed.Results[0].data
        $probeNames = @('installPresence', 'services', 'watchdog', 'dnsPerAdapter', 'upstream', 'versions', 'lastUpdate', 'readiness')
        foreach ($name in $probeNames) {
            @($snapshot.PSObject.Properties.Name) | Should -Contain $name
            $snapshot.$name.state | Should -BeIn @('known', 'unknown', 'notApplicable')
            if ($snapshot.$name.state -eq 'unknown') {
                [string]::IsNullOrWhiteSpace([string]$snapshot.$name.reason) | Should -BeFalse
            }
        }
        @($snapshot.PSObject.Properties.Name) | Should -Contain 'phases'
        @($snapshot.PSObject.Properties.Name) | Should -Contain 'observedUtc'
        $unknown = @($probeNames | Where-Object { $snapshot.$_.state -eq 'unknown' })
        if ($unknown.Count -gt 0 -and $snapshot.readiness.state -eq 'known') {
            $snapshot.readiness.value.state | Should -Not -Be 'ready'
        }
    }

    It 'does not fabricate installed probes when the install path is absent' {
        $fakePath = Join-Path $env:TEMP ('sedg-protocol-not-installed-' + [guid]::NewGuid().ToString('N'))
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'Status') -AllowSeam -InstallPath $fakePath
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 0
        $snapshot = $parsed.Results[0].data
        $snapshot.installPresence.state | Should -Be 'known'
        $snapshot.installPresence.value.installed | Should -BeFalse
        foreach ($name in @('services', 'watchdog', 'dnsPerAdapter', 'upstream', 'versions', 'lastUpdate')) {
            $snapshot.$name.state | Should -BeIn @('unknown', 'notApplicable')
        }
        if ($snapshot.readiness.state -eq 'known') {
            $snapshot.readiness.value.state | Should -Not -Be 'ready'
        }
    }

    It 'reports the embedded approved versions and a real match' {
        $fakePath = Join-Path $env:TEMP ('sedg-protocol-versions-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fakePath -Force | Out-Null
        try {
            ([ordered]@{ DnsProxyRelease = 'v0.86.0'; ZapretRelease = 'v72.13' } | ConvertTo-Json) |
                Set-Content -LiteralPath (Join-Path $fakePath 'state.json') -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $fakePath 'manager-version.txt') -Value '1.9.9' -NoNewline
            $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'Status') -AllowSeam -InstallPath $fakePath
            $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
            $snapshot = $parsed.Results[0].data
            $snapshot.versions.state | Should -Be 'known'
            $entries = @{}
            foreach ($entry in @($snapshot.versions.value)) { $entries[[string]$entry.component] = $entry }
            @($entries.Keys).Count | Should -Be 5
            foreach ($name in @('installer', 'dnsproxy', 'zapret', 'nssm')) {
                [string]::IsNullOrWhiteSpace([string]$entries[$name].approved) | Should -BeFalse
                $entries[$name].match | Should -Be 'equal'
            }
            $entries['manager'].installed | Should -Be '1.9.9'
            $entries['manager'].approved | Should -Be '2.0.1'
            $entries['manager'].match | Should -Be 'mismatch'
        } finally {
            Remove-Item -LiteralPath $fakePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'mirrors console steps onto the protocol stream' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:SEDGProtocolInstallerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $step = @($functions | Where-Object { $_.Name -eq 'Write-Step' })
        $done = @($functions | Where-Object { $_.Name -eq 'Write-Done' })
        $emitter = @($functions | Where-Object { $_.Name -eq 'Write-ProtocolEvent' })
        $step.Count | Should -Be 1
        $done.Count | Should -Be 1
        $emitter.Count | Should -Be 1
        $step[0].Extent.Text | Should -Match "Write-ProtocolEvent 'step'"
        $done[0].Extent.Text | Should -Match "Write-ProtocolEvent 'done'"
        # The wire event must carry every field the manager requires.
        $emitter[0].Extent.Text | Should -Match "type\s*=\s*'event'"
        $emitter[0].Extent.Text | Should -Match 'seq\s*=\s*\$script:ProtocolSeq'
        $emitter[0].Extent.Text | Should -Match 'tsUtc\s*='
        $emitter[0].Extent.Text | Should -Match 'phase\s*=\s*\$Phase'
        $emitter[0].Extent.Text | Should -Match 'message\s*=\s*\$Message'
    }

    It 'rejects unknown actions with Protocol and exit 1' {
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'notAnAction')
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 1
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeFalse
        $parsed.Results[0].code | Should -Be 'Protocol'
    }

    It 'rejects a malformed line with Protocol and exit 1' {
        $run = Invoke-EngineProtocol -RequestJson 'this is not json'
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 1
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeFalse
        $parsed.Results[0].code | Should -Be 'Protocol'
    }

    It 'rejects invalid setDns input without touching the host' {
        $before = Get-AdapterDnsSnapshot
        $cases = @(
            @{ servers = @() },
            @{ servers = @('1.1.1.1', '8.8.8.8', '9.9.9.9', '1.0.0.1', '8.8.4.4') },
            @{ servers = @('not-an-ip') }
        )
        foreach ($case in $cases) {
            $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetDns' -Args $case)
            $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
            $run.ExitCode | Should -Be 1
            $parsed.Results.Count | Should -Be 1
            $parsed.Results[0].ok | Should -BeFalse
            $parsed.Results[0].code | Should -Be 'Validation'
            # A rejected request never reaches the interactive DNS prompt.
            $run.StdErr | Should -Not -Match '(?m):\s*$'
        }
        Get-AdapterDnsSnapshot | Should -Be $before
    }

    It 'refuses valid setDns without elevation instead of mutating DNS' {
        if (Test-IsElevated) {
            Set-ItResult -Skipped -Because 'An elevated run could mutate real adapter DNS; this test only exercises the unelevated refusal.'
            return
        }
        $before = Get-AdapterDnsSnapshot
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetDns' -Args @{ servers = @('127.0.0.1') })
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 1
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeFalse
        $parsed.Results[0].code | Should -BeIn @('UacDenied', 'MutexBusy')
        # The refusal happens before the interactive prompt, so nothing was asked.
        $run.StdErr | Should -Not -Match '(?m):\s*$'
        Get-AdapterDnsSnapshot | Should -Be $before
    }

    It 'refuses reset-defaults without elevation instead of changing config' {
        if (Test-IsElevated) {
            Set-ItResult -Skipped -Because 'An elevated run could rewrite the installed upstream config; this test only exercises the unelevated refusal.'
            return
        }
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetUpstream' -Args @{ mode = 'resetDefaults' })
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 1
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeFalse
        $parsed.Results[0].code | Should -BeIn @('UacDenied', 'MutexBusy')
        $run.StdErr | Should -Not -Match '(?m):\s*$'
    }

    It 'rejects invalid custom upstream URLs without touching the host' {
        foreach ($badUrl in @('not-a-url', 'http://dns.example/dns-query')) {
            $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetUpstream' -Args @{ mode = 'custom'; upstreamUrl = $badUrl })
            $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
            $run.ExitCode | Should -Be 1
            $parsed.Results.Count | Should -Be 1
            $parsed.Results[0].ok | Should -BeFalse
            $parsed.Results[0].code | Should -Be 'Validation'
        }
    }

    It 'accepts the engine upstream schemes and refuses them unelevated' {
        if (Test-IsElevated) {
            Set-ItResult -Skipped -Because 'An elevated run could rewrite the installed upstream config; this test only exercises the unelevated refusal.'
            return
        }
        foreach ($url in @('https://dns.example/dns-query', 'tls://dns.example', 'h3://dns.example/dns-query', 'quic://dns.example')) {
            $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetUpstream' -Args @{ mode = 'custom'; upstreamUrl = $url })
            $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
            $run.ExitCode | Should -Be 1
            $parsed.Results.Count | Should -Be 1
            $parsed.Results[0].ok | Should -BeFalse
            $parsed.Results[0].code | Should -BeIn @('UacDenied', 'MutexBusy')
        }
    }

    It 'keeps restoreEngine reserved with an explicit failure code' {
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'RestoreEngine')
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 1
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeFalse
        $parsed.Results[0].code | Should -Be 'EngineGeneric'
    }

    It 'rejects an invalid language without writing settings' {
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetLanguage' -Args @{ language = 'fr' })
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 1
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeFalse
        $parsed.Results[0].code | Should -Be 'Validation'
    }

    It 'returns a structured CDN result without corrupting stdout' {
        $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'TestCdnOptimization') -TimeoutMs 180000
        $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
        $run.ExitCode | Should -Be 0
        $parsed.Results.Count | Should -Be 1
        $parsed.Results[0].ok | Should -BeTrue
        $parsed.Results[0].data.checkedAt | Should -Not -BeNullOrEmpty
        @($parsed.Results[0].data.targets).Count | Should -BeGreaterThan 0
    }

    It 'keeps stdout pure and routes human output to stderr' {
        # A redirected APPDATA keeps the language file out of the real profile.
        $tempAppData = Join-Path $env:TEMP ('sedg-protocol-appdata-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempAppData -Force | Out-Null
        try {
            $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetLanguage' -Args @{ language = 'en' }) -Environment @{ APPDATA = $tempAppData }
            $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
            $run.ExitCode | Should -Be 0
            $parsed.Hello.Count | Should -Be 1
            $parsed.Results.Count | Should -Be 1
            $parsed.Results[0].ok | Should -BeTrue
            # stdout carries JSONL only; the human text lands on stderr.
            $parsed.Lines.Count | Should -Be 2
            @($parsed.Lines | Where-Object { $_ -notmatch '^\{' }).Count | Should -Be 0
            $run.StdErr | Should -Not -BeNullOrEmpty
            $run.StdErr | Should -Not -Match '(?m)^\s*\{'
        } finally {
            Remove-Item -LiteralPath $tempAppData -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'dispatches every mutating action of the closed vocabulary' {
        if (Test-IsElevated) {
            Set-ItResult -Skipped -Because 'An elevated run would really install/pause/uninstall; only the unelevated refusal path is exercised here.'
            return
        }
        foreach ($action in @('Install', 'Update', 'Pause', 'Resume', 'Restart', 'Uninstall', 'Purge')) {
            $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action $action)
            $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
            $run.ExitCode | Should -Be 1
            $parsed.Results.Count | Should -Be 1
            $parsed.Results[0].ok | Should -BeFalse
            $parsed.Results[0].code | Should -Be 'UacDenied'
            $run.StdErr | Should -Not -Match '(?m):\s*$'
        }
    }

    It 'keeps default -Action Status human output separate from protocol mode' {
        $run = Invoke-EngineProcess -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $global:SEDGProtocolInstallerPath + '" -Action Status')
        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Not -BeNullOrEmpty
        $run.StdOut | Should -Not -Match '"type"\s*:\s*"hello"'
        $run.StdOut | Should -Not -Match '"type"\s*:\s*"result"'
    }

    It 'returns MutexBusy when another run already owns the engine mutex' {
        $mutex = $null
        $held = $false
        try {
            $mutex = New-Object System.Threading.Mutex($false, 'Global\SEDG-Installer')
            # A concurrent suite run can own the mutex briefly, so retry a moment.
            for ($attempt = 0; $attempt -lt 20 -and -not $held; $attempt++) {
                try { $held = $mutex.WaitOne(250) } catch [System.Threading.AbandonedMutexException] { $held = $true }
            }
        } catch {
            Set-ItResult -Skipped -Because ('Could not acquire the engine mutex: ' + $_.Exception.Message)
            return
        }
        if (-not $held) {
            Set-ItResult -Skipped -Because 'Another process already owns the engine mutex.'
            return
        }
        try {
            $run = Invoke-EngineProtocol -RequestJson (New-ProtocolRequest -Action 'SetDns' -Args @{ servers = @('127.0.0.1') })
            $parsed = Convert-ProtocolOutput -StdOut $run.StdOut
            $run.ExitCode | Should -Be 1
            $parsed.Results.Count | Should -Be 1
            $parsed.Results[0].ok | Should -BeFalse
            $parsed.Results[0].code | Should -Be 'MutexBusy'
            $run.StdErr | Should -Not -Match '(?m):\s*$'
        } finally {
            if ($held) { $mutex.ReleaseMutex() }
            if ($mutex) { $mutex.Dispose() }
        }
    }
}
