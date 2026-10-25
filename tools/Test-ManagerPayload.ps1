#requires -Version 5.1
<#
.SYNOPSIS
    Verifies a built manager zip against the payload layout the engine stages.
.DESCRIPTION
    A release is allowed only when the pinned asset is exactly what
    Install-StageManager accepts: one sedg-manager.exe, one manager-version.txt
    whose value matches the pinned version, and optionally the pinned SHA-256.
    Read-only: opens the zip in memory, never extracts to disk.
#>
param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Sha256 = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "Manager zip not found: $ZipPath" }
$Version = $Version.Trim() -replace '^v', ''
if ($Version -notmatch '^\d+(\.\d+)*$') { throw "Invalid manager version: $Version" }

if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid manager SHA-256: $Sha256" }
    $actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actual -ine $Sha256) { throw "Manager zip SHA-256 mismatch: expected $Sha256, got $actual." }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).ProviderPath)
try {
    $entries = @($zip.Entries | Where-Object { $_.FullName -notmatch '/$' })
    # Zip entry names use '/', but accept '\' so a re-zipped payload still
    # resolves to the same leaf name Install-StageManager copies.
    $leaf = { param($entry) [IO.Path]::GetFileName(($entry.FullName -replace '\\', '/')) }

    $exes = @($entries | Where-Object { (& $leaf $_) -eq 'sedg-manager.exe' })
    if ($exes.Count -ne 1) {
        $found = if ($exes.Count -eq 0) { 'none' } else { ($exes | ForEach-Object { $_.FullName }) -join ', ' }
        throw ("Expected exactly one sedg-manager.exe in the manager archive; found: {0}." -f $found)
    }
    if ($exes[0].Length -le 0) { throw 'Manager payload sedg-manager.exe is empty.' }

    $versionEntries = @($entries | Where-Object { (& $leaf $_) -eq 'manager-version.txt' })
    if ($versionEntries.Count -ne 1) {
        throw ("Expected exactly one manager-version.txt in the manager archive; found {0}." -f $versionEntries.Count)
    }
    $reader = New-Object IO.StreamReader($versionEntries[0].Open(), [Text.Encoding]::UTF8)
    try { $bundled = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    if ($bundled -ne $Version) {
        throw ("Manager payload version '{0}' does not match the pinned version '{1}'." -f $bundled, $Version)
    }
} finally {
    $zip.Dispose()
}

Write-Host ("Manager payload OK: {0} (sedg-manager.exe + manager-version.txt {1})" -f (Split-Path -Leaf $ZipPath), $Version)
