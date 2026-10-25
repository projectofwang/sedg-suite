# B11: the manager payload is one exe + one version file in the engine root.
# Stage refuses every other archive layout; commit swaps files with rollback.
# All downloads, hashes and filesystem roots are stubbed/local: no network,
# no Program Files, no elevated call.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }
$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'installer.ps1'
$global:SEDGInstallerPath = $installerPath

function global:Import-InstallerFunction([string]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:SEDGInstallerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "installer.ps1 has $($errors.Count) parse errors" }
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $fn) { throw "installer function not found: $Name" }
    Invoke-Expression (($fn.Extent.Text) -replace '^function ', 'function global:')
}

function global:T([string]$Key) { return $Key }

Import-InstallerFunction 'Get-ManifestProperty'
Import-InstallerFunction 'Get-ManifestString'
Import-InstallerFunction 'Get-PinnedManagerSource'
Import-InstallerFunction 'Install-StageManager'
Import-InstallerFunction 'Test-ManagerHealthy'
Import-InstallerFunction 'Install-CommitManager'

Describe 'Manager stage (B11)' {
    BeforeAll {
        $global:SedgManagerDownloads = @()
        $global:SedgManagerExpands = @()
        $global:SedgRebootDeletes = @()
        $global:SedgManagerFiles = @{}

        function global:Write-Host { param($Object, $ForegroundColor, $BackgroundColor, $NoNewline, $ErrorAction) }
        function global:Write-Step { param([string]$Text) }
        function global:Write-Done { param([string]$Text) }
        function global:Get-ReleaseAssetUrl {
            param($Repository, $Tag, $Asset, [switch]$AllowSeam)
            return ('https://fixture.invalid/{0}/{1}/{2}' -f $Repository, $Tag, $Asset)
        }
        function global:Download-File { param($Url, $Destination)
            $global:SedgManagerDownloads += [string]$Url
            Set-Content -LiteralPath $Destination -Value 'zip-bytes' -Encoding ASCII -NoNewline
        }
        function global:Verify-Sha256 { param($File, $Expected, $Label) return $Expected }
        function global:Expand-Zip { param($ZipFile, $Destination)
            $global:SedgManagerExpands += [string]$Destination
            foreach ($name in $global:SedgManagerFiles.Keys) {
                $path = Join-Path $Destination $name
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value $global:SedgManagerFiles[$name] -Encoding ASCII -NoNewline
            }
        }
        function global:Schedule-DeleteOnReboot { param([string]$Path) $global:SedgRebootDeletes += [string]$Path }
    }

    AfterAll {
        foreach ($n in @('Write-Host', 'Get-ReleaseAssetUrl', 'Download-File', 'Verify-Sha256',
                'Expand-Zip', 'Schedule-DeleteOnReboot')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
        foreach ($n in @('Write-Step', 'Write-Done', 'Schedule-DeleteOnReboot',
                'Get-ReleaseAssetUrl', 'Verify-Sha256', 'Download-File')) {
            try { Import-InstallerFunction $n } catch { }
        }
    }

    BeforeEach {
        $script:ManagerSha256 = ('a' * 64)
        $script:ManagerRepository = 'projectofwang/sedgwz-auto-installer'
        $script:ManagerTag = 'v2.0.0'
        $script:ManagerAsset = 'sedg-manager-win-x64-2.0.0.zip'
        $script:AllowedReleaseRepos = @($script:ManagerRepository)
        $script:ManagerExe = 'sedg-manager.exe'
        $script:TempPath = Join-Path $TestDrive 'manager-temp'
        $script:StageRoot = Join-Path $TestDrive 'manager-stage'
        foreach ($path in @($script:TempPath, $script:StageRoot)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null
        New-Item -ItemType Directory -Path $script:StageRoot -Force | Out-Null

        $global:SedgManagerFiles = @{
            'sedg-manager.exe'    = 'new-manager-binary'
            'manager-version.txt' = '2.0.0'
        }
        $script:Manifest = [pscustomobject]@{
            repository = $script:ManagerRepository
            tag        = $script:ManagerTag
            asset      = $script:ManagerAsset
            sha256     = $script:ManagerSha256
        }
    }

    It 'stages exactly the exe and version file' {
        $stage = Install-StageManager $script:StageRoot $script:Manifest

        (Test-Path -LiteralPath (Join-Path $stage 'sedg-manager.exe') -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $stage 'manager-version.txt') -PathType Leaf) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $stage -File).Count | Should -Be 2
        $global:SedgManagerDownloads.Count | Should -Be 1
    }

    It 'refuses the retired WPF archive layout' {
        $global:SedgManagerFiles = @{
            'Sedg.Desktop.exe'    = 'old'
            'Sedg.Broker.exe'     = 'old'
            'manager-version.txt' = '2.0.0'
        }

        { Install-StageManager $script:StageRoot $script:Manifest } |
            Should -Throw '*Expected exactly one sedg-manager.exe*'
        @(Get-ChildItem -LiteralPath $script:StageRoot -File).Count | Should -Be 0
    }

    It 'refuses a payload whose bundled version disagrees with the pin' {
        $global:SedgManagerFiles['manager-version.txt'] = '1.2.5'

        { Install-StageManager $script:StageRoot $script:Manifest } |
            Should -Throw '*does not match the pinned version*'
        @(Get-ChildItem -LiteralPath $script:StageRoot -File).Count | Should -Be 0
    }
}

Describe 'Manager commit (B11)' {
    BeforeAll {
        $global:SedgRebootDeletes = @()

        function global:Write-Host { param($Object, $ForegroundColor, $BackgroundColor, $NoNewline, $ErrorAction) }
        function global:Write-Step { param([string]$Text) }
        function global:Write-Done { param([string]$Text) }
        function global:Schedule-DeleteOnReboot { param([string]$Path) $global:SedgRebootDeletes += [string]$Path }
    }

    AfterAll {
        foreach ($n in @('Write-Host', 'Schedule-DeleteOnReboot')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $n) -Force -ErrorAction SilentlyContinue
        }
        foreach ($n in @('Write-Step', 'Write-Done', 'Schedule-DeleteOnReboot')) {
            try { Import-InstallerFunction $n } catch { }
        }
    }

    BeforeEach {
        $script:ManagerTag = 'v2.0.0'
        $script:ManagerExe = 'sedg-manager.exe'
        $script:InstallPath = Join-Path $TestDrive 'engine-root'
        $script:ManagerPath = Join-Path $script:InstallPath $script:ManagerExe
        $script:LegacyManagerPath = Join-Path $TestDrive 'legacy-manager'
        $script:TempPath = Join-Path $TestDrive 'manager-temp'
        $script:StageManager = Join-Path $TestDrive 'manager-staged'
        foreach ($path in @($script:InstallPath, $script:StageManager)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        New-Item -ItemType Directory -Path $script:InstallPath -Force | Out-Null
        New-Item -ItemType Directory -Path $script:StageManager -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:StageManager 'sedg-manager.exe') -Value 'new-manager-binary' -Encoding ASCII -NoNewline
        Set-Content -LiteralPath (Join-Path $script:StageManager 'manager-version.txt') -Value '2.0.0' -Encoding ASCII -NoNewline
        $global:SedgRebootDeletes = @()
    }

    It 'replaces an existing pair by file swap and leaves no aside copy' {
        Set-Content -LiteralPath $script:ManagerPath -Value 'old-manager-binary' -Encoding ASCII -NoNewline
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'manager-version.txt') -Value '1.2.5' -Encoding ASCII -NoNewline

        Install-CommitManager $script:StageManager

        (Get-Content -LiteralPath $script:ManagerPath -Raw).Trim() | Should -Be 'new-manager-binary'
        (Get-Content -LiteralPath (Join-Path $script:InstallPath 'manager-version.txt') -Raw).Trim() | Should -Be '2.0.0'
        @(Get-ChildItem -LiteralPath $script:InstallPath -Filter '*.old-*' -File).Count | Should -Be 0
    }

    It 'installs into an empty engine root' {
        Install-CommitManager $script:StageManager

        (Test-Path -LiteralPath $script:ManagerPath -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:InstallPath 'manager-version.txt') -PathType Leaf) | Should -BeTrue
    }

    It 'restores the previous pair when the live health check fails' {
        Set-Content -LiteralPath $script:ManagerPath -Value 'old-manager-binary' -Encoding ASCII -NoNewline
        Set-Content -LiteralPath (Join-Path $script:InstallPath 'manager-version.txt') -Value '1.2.5' -Encoding ASCII -NoNewline
        Set-Content -LiteralPath (Join-Path $script:StageManager 'manager-version.txt') -Value '9.9.9' -Encoding ASCII -NoNewline

        { Install-CommitManager $script:StageManager } |
            Should -Throw '*Live SEDG Manager commit failed verification*'

        (Get-Content -LiteralPath $script:ManagerPath -Raw).Trim() | Should -Be 'old-manager-binary'
        (Get-Content -LiteralPath (Join-Path $script:InstallPath 'manager-version.txt') -Raw).Trim() | Should -Be '1.2.5'
    }

    It 'refuses an incomplete staged payload before touching the installed pair' {
        Set-Content -LiteralPath $script:ManagerPath -Value 'old-manager-binary' -Encoding ASCII -NoNewline
        Remove-Item -LiteralPath (Join-Path $script:StageManager 'manager-version.txt') -Force

        { Install-CommitManager $script:StageManager } |
            Should -Throw '*Staged manager payload is incomplete*'
        (Get-Content -LiteralPath $script:ManagerPath -Raw).Trim() | Should -Be 'old-manager-binary'
    }
}
