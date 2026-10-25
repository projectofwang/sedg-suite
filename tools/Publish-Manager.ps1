#requires -Version 5.1
<#
.SYNOPSIS
    Builds the SEDG Manager (Rust) and packages the pinned asset.
.DESCRIPTION
    Produces sedg-manager-win-x64-<version>.zip holding sedg-manager.exe and
    manager-version.txt, which is exactly the payload installer.ps1 stages.
    Writes only under -OutDir; never edits approved-releases.json or any tracked file.
#>
param(
    [string]$Version = '',
    [string]$OutDir = '',
    [string]$Cargo = 'cargo',
    [string]$TargetDir = '',
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$manifestPath = Join-Path $RepoRoot 'src\rust\Cargo.toml'

if ([string]::IsNullOrWhiteSpace($Version)) {
    # The crate version is the manager's own version; metadata also refreshes
    # Cargo.lock, so a bumped version still builds under --locked below.
    $metadata = & $Cargo metadata --no-deps --format-version 1 --manifest-path $manifestPath
    if ($LASTEXITCODE -ne 0) { throw ("cargo metadata failed with exit code {0}." -f $LASTEXITCODE) }
    $package = (($metadata | Out-String) | ConvertFrom-Json).packages |
        Where-Object { $_.name -eq 'sedg-manager' } | Select-Object -First 1
    if ($null -eq $package) { throw 'cargo metadata has no sedg-manager package; pass -Version.' }
    $Version = [string]$package.version
}
if ($Version -notmatch '^\d+(\.\d+)*$') { throw "Invalid manager version: $Version" }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path ([IO.Path]::GetTempPath()) ('sedg-manager-publish-' + $Version)
}
$OutDir = [IO.Path]::GetFullPath($OutDir)
$appDir = Join-Path $OutDir 'app'
$zip = Join-Path $OutDir ('sedg-manager-win-x64-' + $Version + '.zip')
if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
New-Item -ItemType Directory -Path $appDir -Force | Out-Null

$cargoArgs = @('build', '--release', '--locked', '--manifest-path', $manifestPath)
if (-not [string]::IsNullOrWhiteSpace($TargetDir)) { $cargoArgs += @('--target-dir', [IO.Path]::GetFullPath($TargetDir)) }
Write-Host ("Building sedg-manager {0} (release) ..." -f $Version)
& $Cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw ("cargo build failed with exit code {0}." -f $LASTEXITCODE) }

$targetRoot = if ([string]::IsNullOrWhiteSpace($TargetDir)) { Join-Path $RepoRoot 'src\rust\target' } else { [IO.Path]::GetFullPath($TargetDir) }
$exe = Join-Path $targetRoot 'release\sedg-manager.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw ("Built manager not found: {0}" -f $exe) }

Copy-Item -LiteralPath $exe -Destination (Join-Path $appDir 'sedg-manager.exe') -Force
[IO.File]::WriteAllText((Join-Path $appDir 'manager-version.txt'), $Version, [Text.UTF8Encoding]::new($false))

Compress-Archive -Path (Join-Path $appDir '*') -DestinationPath $zip -Force
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
# The release gate re-runs this check against the downloaded asset, so a local
# build that cannot pass it is never published.
& (Join-Path $PSScriptRoot 'Test-ManagerPayload.ps1') -ZipPath $zip -Version $Version -Sha256 $hash
$size = (Get-Item -LiteralPath $zip).Length
Write-Host ("Published: {0}" -f $zip)
Write-Host ("SHA-256:  {0}" -f $hash)
Write-Host ("Size:     {0:N0} bytes" -f $size)
