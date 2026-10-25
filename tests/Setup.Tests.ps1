# Pester tests for the one-command bootstrap (setup.ps1): manifest pins, SHA-256
# verification, staging layout, and the refusal paths. No elevation, no window,
# no network beyond a loopback fixture server.
# Requires Pester 5.2+. Run: Invoke-Pester ./tests
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }
$setupPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'setup.ps1'
$global:SEDGSetupPath = $setupPath

function Import-SetupFunction([string]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:SEDGSetupPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "setup.ps1 has $($errors.Count) parse errors" }
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $fn) { throw "setup function not found: $Name" }
    # The extracted copy is defined at global scope, so its `$script:` reads
    # would look at that scope's empty script slot. Point them at the globals
    # this file sets instead.
    Invoke-Expression (($fn.Extent.Text -replace '^function ', 'function global:') -replace '\$script:', '$global:')
}

# Import-SetupFunction defines the extracted functions at global scope, so the
# names they read through `$script:` resolve in the global scope too.
$global:UserAgent = 'test'
$global:ManagerExe = 'sedg-manager.exe'
$global:DefaultManifestUrl = 'https://dl.taiyuanwangjie.dpdns.org/approved-releases.json'
$global:ManifestFallbackUrl = 'https://raw.githubusercontent.com/projectofwang/sedg-suite/main/approved-releases.json'
$global:AllowedManagerRepositories = @('projectofwang/sedg-suite')

Import-SetupFunction 'Test-SetupUrl'
Import-SetupFunction 'Get-SetupAssetBase'
Import-SetupFunction 'Get-SetupManagerPin'
Import-SetupFunction 'Get-SetupManagerPlan'
Import-SetupFunction 'Assert-SetupHash'
Import-SetupFunction 'Expand-SetupManager'
Import-SetupFunction 'Save-SetupFile'
Import-SetupFunction 'Get-SetupManifest'

# A loopback fixture server in a background runspace: the listener lives in this
# process, so plain http is exercised without an external run-time dependency.
function global:Start-SetupFixture([string]$Root) {
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add('http://127.0.0.1:18082/')
    $listener.Start()

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript({
        param($Listener, $Root)
        while ($Listener.IsListening) {
            $context = $null
            try { $context = $Listener.GetContext() } catch { break }
            try {
                $name = $context.Request.Url.AbsolutePath.TrimStart('/')
                $file = Join-Path $Root $name
                if (Test-Path -LiteralPath $file -PathType Leaf) {
                    $bytes = [IO.File]::ReadAllBytes($file)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'application/octet-stream'
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $context.Response.StatusCode = 404
                }
            } catch { }
            try { $context.Response.Close() } catch { }
        }
    }).AddArgument($listener).AddArgument($Root)
    $handle = $shell.BeginInvoke()

    return [pscustomobject]@{ Listener = $listener; Shell = $shell; Handle = $handle; Runspace = $runspace }
}

function global:Stop-SetupFixture($Fixture) {
    if ($null -eq $Fixture) { return }
    try { $Fixture.Listener.Stop() } catch { }
    try { $Fixture.Shell.Stop() } catch { }
    try { $Fixture.Shell.Dispose() } catch { }
    try { $Fixture.Listener.Close() } catch { }
    try { $Fixture.Runspace.Dispose() } catch { }
}

function global:New-SetupFixtureRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('sedg-setup-fixture-' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function global:Write-ManagerArchive([string]$Path, [string]$ExeName = 'sedg-manager.exe') {
    $content = Join-Path ([IO.Path]::GetTempPath()) ('sedg-zip-' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $content -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $content $ExeName), 'not a real executable, never started')
    [IO.File]::WriteAllText((Join-Path $content 'manager-version.txt'), '2.0.0')
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Compress-Archive -Path (Join-Path $content '*') -DestinationPath $Path -Force
    Remove-Item -LiteralPath $content -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-SetupUrl' {
    It 'accepts https and loopback http only' {
        (Test-SetupUrl 'https://dl.taiyuanwangjie.dpdns.org/setup.ps1') | Should -Be $true
        (Test-SetupUrl 'http://127.0.0.1:18082/approved-releases.json') | Should -Be $true
        (Test-SetupUrl 'http://localhost/x') | Should -Be $true
        (Test-SetupUrl 'http://evil.example/x') | Should -Be $false
        (Test-SetupUrl 'ftp://example/x') | Should -Be $false
        (Test-SetupUrl '') | Should -Be $false
    }
}

Describe 'Get-SetupManagerPlan' {
    BeforeEach {
        Remove-Item Env:SEDG_SETUP_ASSET_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'builds the release URL from the pinned manager entry' {
        $manifest = @{ components = @{ manager = @{
            repository = 'projectofwang/sedg-suite'
            tag        = '2.0.0'
            asset      = 'sedg-manager-win-x64-2.0.0.zip'
            sha256     = ('a' * 64)
        } } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json

        $plan = Get-SetupManagerPlan $manifest
        $plan.Url | Should -Be 'https://github.com/projectofwang/sedg-suite/releases/download/2.0.0/sedg-manager-win-x64-2.0.0.zip'
        $plan.Sha256 | Should -Be ('a' * 64)
        $plan.Version | Should -Be '2.0.0'
    }

    It 'refuses a manifest with no manager pin and never starts anything' {
        $manifest = @{ components = @{ dnsproxy = @{ tag = 'v0.86.0' } } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        { Get-SetupManagerPlan $manifest } | Should -Throw '*no manager pin*'
    }

    It 'refuses a repository outside the allow-list' {
        $manifest = @{ components = @{ manager = @{
            repository = 'attacker/not-this-one'
            tag        = '2.0.0'
            asset      = 'sedg-manager-win-x64-2.0.0.zip'
            sha256     = ('a' * 64)
        } } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        { Get-SetupManagerPlan $manifest } | Should -Throw '*not allow-listed*'
    }

    It 'refuses a malformed tag, asset, or hash' {
        $base = @{
            repository = 'projectofwang/sedg-suite'
            tag        = '2.0.0'
            asset      = 'sedg-manager-win-x64-2.0.0.zip'
            sha256     = ('a' * 64)
        }
        foreach ($case in @(
                @{ Field = 'tag'; Value = '2.0.0/../../evil' },
                @{ Field = 'asset'; Value = '../evil.zip' },
                @{ Field = 'sha256'; Value = 'not-a-hash' })) {
            $manager = $base.Clone()
            $manager[$case.Field] = $case.Value
            $manifest = @{ components = @{ manager = $manager } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            { Get-SetupManagerPlan $manifest } | Should -Throw
        }
    }
}

Describe 'Assert-SetupHash' {
    It 'accepts the pinned hash and rejects any other' {
        $file = Join-Path ([IO.Path]::GetTempPath()) ('sedg-hash-' + [guid]::NewGuid().ToString())
        [IO.File]::WriteAllText($file, 'payload')
        try {
            $expected = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            { Assert-SetupHash $file $expected 'fixture' } | Should -Not -Throw
            { Assert-SetupHash $file ('0' * 64) 'fixture' } | Should -Throw '*SHA-256 mismatch*'
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Expand-SetupManager' {
    It 'extracts sedg-manager.exe from the archive root' {
        $root = New-SetupFixtureRoot
        try {
            $zip = Join-Path $root 'manager.zip'
            Write-ManagerArchive $zip
            $target = Join-Path $root 'staged'
            $exe = Expand-SetupManager $zip $target
            $exe | Should -Be (Join-Path $target 'sedg-manager.exe')
            (Test-Path -LiteralPath $exe -PathType Leaf) | Should -Be $true
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses an archive built by the old packaging, which has no sedg-manager.exe' {
        $root = New-SetupFixtureRoot
        try {
            $zip = Join-Path $root 'manager.zip'
            Write-ManagerArchive $zip 'Sedg.Desktop.exe'
            { Expand-SetupManager $zip (Join-Path $root 'staged') } | Should -Throw '*does not contain sedg-manager.exe*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-SetupManifest' {
    It 'refuses a non-https origin' {
        { Get-SetupManifest 'http://example.invalid/approved-releases.json' } | Should -Throw '*non-https*'
    }
}

Describe 'the bootstrap against a fixture server' {
    BeforeAll {
        $global:fixtureRoot = New-SetupFixtureRoot
        $global:fixture = Start-SetupFixture $global:fixtureRoot
        $global:base = 'http://127.0.0.1:18082'
        $global:manifestPath = Join-Path $global:fixtureRoot 'approved-releases.json'
        $global:assetDir = Join-Path $global:fixtureRoot 'projectofwang/sedg-suite/releases/download/2.0.0'
        New-Item -ItemType Directory -Path $global:assetDir -Force | Out-Null
        Write-ManagerArchive (Join-Path $global:assetDir 'sedg-manager-win-x64-2.0.0.zip')
        $global:zipHash = (Get-FileHash -LiteralPath (Join-Path $global:assetDir 'sedg-manager-win-x64-2.0.0.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        $global:fixtureManifest = @{ components = @{ manager = @{
            repository = 'projectofwang/sedg-suite'
            tag        = '2.0.0'
            asset      = 'sedg-manager-win-x64-2.0.0.zip'
            sha256     = $global:zipHash
        } } } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($global:manifestPath, $global:fixtureManifest)
        # A short settle so the listener is accepting before the first request.
        Start-Sleep -Milliseconds 300
    }

    AfterAll {
        Stop-SetupFixture $global:fixture
        Remove-Item -LiteralPath $global:fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Remove-Item Env:SEDG_SETUP_ASSET_BASE_URL -ErrorAction SilentlyContinue
        $env:SEDG_SETUP_ASSET_BASE_URL = $global:base
    }

    AfterEach {
        Remove-Item Env:SEDG_SETUP_ASSET_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'parses the manifest the origin served, even when it labels the body binary' {
        # The fixture server sends application/octet-stream, which Windows
        # PowerShell hands back as byte[]; the pin must still be readable.
        $manifest = Get-SetupManifest "$($global:base)/approved-releases.json"
        $manifest.components.manager.sha256 | Should -Be $global:zipHash
    }

    It 'downloads the pinned archive, verifies it, and stages the manager' {
        $manifest = @{ components = @{ manager = @{
            repository = 'projectofwang/sedg-suite'
            tag        = '2.0.0'
            asset      = 'sedg-manager-win-x64-2.0.0.zip'
            sha256     = $global:zipHash
        } } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json

        $plan = Get-SetupManagerPlan $manifest
        $staging = Join-Path ([IO.Path]::GetTempPath()) ('sedg-setup-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            $zip = Join-Path $staging 'manager.zip'
            Save-SetupFile $plan.Url $zip
            { Assert-SetupHash $zip $plan.Sha256 'manager 2.0.0' } | Should -Not -Throw
            $exe = Expand-SetupManager $zip $staging
            (Test-Path -LiteralPath $exe -PathType Leaf) | Should -Be $true
            (Get-Item -LiteralPath $exe).Directory.Name | Should -Match '^sedg-setup-[0-9a-f-]{36}$'
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'stops before staging when the manifest hash does not match the archive' {
        $manifest = @{ components = @{ manager = @{
            repository = 'projectofwang/sedg-suite'
            tag        = '2.0.0'
            asset      = 'sedg-manager-win-x64-2.0.0.zip'
            sha256     = ('0' * 64)
        } } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json

        $plan = Get-SetupManagerPlan $manifest
        $staging = Join-Path ([IO.Path]::GetTempPath()) ('sedg-setup-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            $zip = Join-Path $staging 'manager.zip'
            Save-SetupFile $plan.Url $zip
            { Assert-SetupHash $zip $plan.Sha256 'manager 2.0.0' } | Should -Throw '*SHA-256 mismatch*'
            # The verifier ran before extraction, so no executable was staged.
            (Test-Path -LiteralPath (Join-Path $staging 'sedg-manager.exe')) | Should -Be $false
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails when the manifest origin is unreachable, staging nothing' {
        { Get-SetupManifest 'http://127.0.0.1:18082/missing-manifest.json' } | Should -Throw
    }

    It 'fails when the archive is missing from the pinned origin' {
        $staging = Join-Path ([IO.Path]::GetTempPath()) ('sedg-setup-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            $zip = Join-Path $staging 'manager.zip'
            { Save-SetupFile 'http://127.0.0.1:18082/projectofwang/sedg-suite/releases/download/9.9.9/sedg-manager-win-x64-9.9.9.zip' $zip } | Should -Throw '*Download failed*'
            (Test-Path -LiteralPath $zip) | Should -Be $false
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'setup.ps1 gates' {
    It 'stays pure ASCII so irm|iex on a non-UTF-8 console is safe' {
        $text = Get-Content -LiteralPath $global:SEDGSetupPath -Raw
        $nonAscii = ([regex]::Matches($text, '[^\x00-\x7F]')).Count
        $nonAscii | Should -Be 0
    }

    It 'starts the manager with no arguments, so the binary picks the screen from the machine' {
        $text = Get-Content -LiteralPath $global:SEDGSetupPath -Raw
        $text | Should -Match 'Start-Process -FilePath \$exe'
        $text | Should -Not -Match "Start-Process[^\r\n]*-ArgumentList"
    }
}
