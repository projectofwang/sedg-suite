# Release-gate proof for the manager zip: the verifier must accept exactly the
# payload Install-StageManager stages and refuse everything else.
# Local zips only: no network, no Program Files.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

Describe 'tools/Test-ManagerPayload.ps1' {
    BeforeAll {
        $toolPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Test-ManagerPayload.ps1'
        function New-ManagerZip([string]$Path, [hashtable]$Files) {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            foreach ($name in $Files.Keys) {
                Set-Content -LiteralPath (Join-Path $dir $name) -Value $Files[$name] -Encoding ASCII -NoNewline
            }
            Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $Path -Force
        }
    }

    It 'accepts the two-file engine payload' {
        $zip = Join-Path $TestDrive 'ok.zip'
        New-ManagerZip $zip @{ 'sedg-manager.exe' = 'MZ-binary'; 'manager-version.txt' = '2.0.0' }

        { & $toolPath -ZipPath $zip -Version '2.0.0' } | Should -Not -Throw
    }

    It 'accepts a matching pinned hash' {
        $zip = Join-Path $TestDrive 'hashed.zip'
        New-ManagerZip $zip @{ 'sedg-manager.exe' = 'MZ-binary'; 'manager-version.txt' = '2.0.0' }
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

        { & $toolPath -ZipPath $zip -Version 'v2.0.0' -Sha256 $hash } | Should -Not -Throw
    }

    It 'refuses a zip whose hash does not match the pin' {
        $zip = Join-Path $TestDrive 'bad-hash.zip'
        New-ManagerZip $zip @{ 'sedg-manager.exe' = 'MZ-binary'; 'manager-version.txt' = '2.0.0' }

        { & $toolPath -ZipPath $zip -Version '2.0.0' -Sha256 ('0' * 64) } |
            Should -Throw '*SHA-256 mismatch*'
    }

    It 'refuses the retired WPF archive layout' {
        $zip = Join-Path $TestDrive 'wpf.zip'
        New-ManagerZip $zip @{
            'Sedg.Desktop.exe'    = 'old'
            'Sedg.Broker.exe'     = 'old'
            'manager-version.txt' = '2.0.0'
        }

        { & $toolPath -ZipPath $zip -Version '2.0.0' } |
            Should -Throw '*Expected exactly one sedg-manager.exe*'
    }

    It 'refuses a payload whose bundled version disagrees with the pin' {
        $zip = Join-Path $TestDrive 'bad-version.zip'
        New-ManagerZip $zip @{ 'sedg-manager.exe' = 'MZ-binary'; 'manager-version.txt' = '1.2.5' }

        { & $toolPath -ZipPath $zip -Version '2.0.0' } |
            Should -Throw '*does not match the pinned version*'
    }
}
