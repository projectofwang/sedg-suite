#requires -Version 5.1
# SEDG one-command bootstrap.
# Copyright (c) 2026 projectofwang. Licensed under the MIT License - see
# LICENSE in the repository root. Third-party notices: see THIRD-PARTY.md.
#
#   irm https://dl.taiyuanwangjie.dpdns.org/setup.ps1 | iex
#
# Fetches the approved manifest, downloads the pinned manager archive, checks
# its SHA-256 against the pin, expands it under %TEMP%\sedg-setup-<guid>, and
# starts the window. Nothing here elevates: the manager asks for administrator
# approval only when the user starts an install or another machine change.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultManifestUrl = 'https://dl.taiyuanwangjie.dpdns.org/approved-releases.json'
$script:ManifestFallbackUrl = 'https://raw.githubusercontent.com/projectofwang/sedg-suite/main/approved-releases.json'
$script:AllowedManagerRepositories = @('projectofwang/sedg-suite')
$script:ManagerExe = 'sedg-manager.exe'
$script:UserAgent = 'Serverless-Edge-DNS-Gateway-Setup'

# Restore these in `finally` so irm|iex never pollutes the caller session.
$script:SavedErrorAction = $ErrorActionPreference
$script:SavedProgress = $ProgressPreference
try { $script:SavedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol } catch { $script:SavedSecurityProtocol = $null }

# Quiet progress (slow on PS 5.1) and modern TLS. 12288 is the TLS 1.3 flag,
# absent on old .NET (then TLS 1.2 only).
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = ([Net.SecurityProtocolType]::Tls12 -bor 12288)
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Test-SetupUrl([string]$Url) {
    # https is always allowed. Plain http is allowed only for loopback hosts,
    # which is how the CI fixture server is reached; it never widens the
    # surface of a user download.
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($Url -match '^https://') { return $true }
    return ($Url -match '^http://(localhost|127\.0\.0\.1|\[::1\])(/|:|$)')
}

function Get-SetupManifestUrl {
    # Test seam only: unset in production, so the manifest stays on the pinned
    # origin. This script never elevates and stages only under %TEMP%, so the
    # seam cannot raise anyone's privilege; the archive still has to match the
    # SHA-256 the fetched manifest pins.
    if (-not [string]::IsNullOrWhiteSpace($env:SEDG_SETUP_MANIFEST_URL)) {
        Write-Warning 'SEDG_SETUP_MANIFEST_URL test seam is active; the manifest leaves the pinned origin.'
        return $env:SEDG_SETUP_MANIFEST_URL.Trim()
    }
    return $script:DefaultManifestUrl
}

function Get-SetupAssetBase {
    # Same seam contract as the manifest: it changes where bytes come from,
    # never which bytes are accepted.
    if (-not [string]::IsNullOrWhiteSpace($env:SEDG_SETUP_ASSET_BASE_URL)) {
        Write-Warning 'SEDG_SETUP_ASSET_BASE_URL test seam is active; downloads leave the pinned origin.'
        return $env:SEDG_SETUP_ASSET_BASE_URL.TrimEnd('/')
    }
    return 'https://github.com'
}

function Get-SetupManifest([string]$Url) {
    if (-not (Test-SetupUrl $Url)) { throw "Refusing a non-https manifest URL: $Url" }
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = $script:UserAgent } -ErrorAction Stop
    $content = $response.Content
    # Windows PowerShell returns .Content as byte[] when the origin labels the
    # body as binary; decode it ourselves instead of trusting the label.
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    if ([string]::IsNullOrWhiteSpace([string]$content)) { throw "The manifest at $Url is empty." }
    return (([string]$content).TrimStart([char]0xFEFF) | ConvertFrom-Json)
}

function Get-SetupManagerPin($Manifest) {
    if ($null -eq $Manifest) { return $null }
    $manager = $null
    try { $manager = $Manifest.components.manager } catch { $manager = $null }
    if ($null -eq $manager) { return $null }
    return [pscustomobject]@{
        repository = [string]$manager.repository
        tag        = [string]$manager.tag
        asset      = [string]$manager.asset
        sha256     = ([string]$manager.sha256).ToLowerInvariant()
    }
}

function Get-SetupManagerPlan($Manifest) {
    $pin = Get-SetupManagerPin $Manifest
    if ($null -eq $pin) { throw 'The approved manifest has no manager pin; refusing to start a manager this build cannot verify.' }
    if ($script:AllowedManagerRepositories -notcontains $pin.repository) { throw "The manager repository is not allow-listed: $($pin.repository)" }
    if ($pin.tag -notmatch '^(v)?\d+(\.\d+)+$') { throw "Invalid manager tag: $($pin.tag)" }
    if ($pin.asset -notmatch '^[\w][\w.\-]*$') { throw "Invalid manager asset name: $($pin.asset)" }
    if ($pin.sha256 -notmatch '^[0-9a-f]{64}$') { throw "The manager pin has no usable SHA-256: $($pin.sha256)" }

    return [pscustomobject]@{
        Url     = '{0}/{1}/releases/download/{2}/{3}' -f (Get-SetupAssetBase), $pin.repository, $pin.tag, $pin.asset
        Sha256  = $pin.sha256
        Version = $pin.tag.TrimStart('v')
    }
}

function Assert-SetupManifestCrossCheck($Manifest) {
    # TOFU same-origin cross-check: the primary origin supplies the pin, so a
    # compromised primary could pin its own bytes. The GitHub fallback is read
    # out-of-band and must agree on the manager pin. An unreachable fallback is
    # a warning, not a forgery: the download still has to match the pin.
    # shortcut: TOFU, upgrade to a signed manifest when key infrastructure exists
    try {
        $other = Get-SetupManifest $script:ManifestFallbackUrl
    } catch {
        Write-Warning ("The GitHub fallback manifest could not be read ({0}); continuing on the primary pin only." -f $_.Exception.Message)
        return
    }
    $mine = Get-SetupManagerPin $Manifest
    $theirs = Get-SetupManagerPin $other
    foreach ($field in @('repository', 'tag', 'asset', 'sha256')) {
        if ([string]$mine.$field -ne [string]$theirs.$field) {
            throw ("Manifest cross-check mismatch on manager.{0}: primary '{1}' vs GitHub fallback '{2}'. Refusing to continue." -f $field, $mine.$field, $theirs.$field)
        }
    }
}

function Save-SetupFile([string]$Url, [string]$Destination) {
    if (-not (Test-SetupUrl $Url)) { throw "Refusing a non-https download URL: $Url" }
    # GitHub release downloads occasionally reset a PowerShell connection;
    # prefer curl.exe with retries, then fall back to Invoke-WebRequest.
    $curl = Join-Path (Join-Path $env:SystemRoot 'System32') 'curl.exe'
    $loopback = ($Url -match '^http://')
    $lastError = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        try {
            if (Test-Path -LiteralPath $curl) {
                $protocols = '=https'
                $extra = @()
                if ($loopback) {
                    $protocols = '=https,http'
                    $extra = @('--noproxy', '*')
                }
                & $curl --silent --show-error --fail --location --proto $protocols --proto-redir $protocols @extra --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 600 --output $Destination $Url
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination)) { return }
                throw "curl.exe exited with code $LASTEXITCODE"
            }

            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600 -Headers @{ 'User-Agent' = $script:UserAgent } -ErrorAction Stop
            if (Test-Path -LiteralPath $Destination) { return }
            throw 'The download produced no file.'
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }

    throw ("Download failed: {0} ({1})" -f $Url, $lastError)
}

function Assert-SetupHash([string]$File, [string]$Expected, [string]$Label) {
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw ("SHA-256 mismatch for {0}. Expected {1}, got {2}." -f $Label, $Expected, $actual)
    }
}

function Expand-SetupManager([string]$Zip, [string]$Directory) {
    # The archive itself lives in this directory, so create it but never wipe it.
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    Expand-Archive -LiteralPath $Zip -DestinationPath $Directory -Force
    # A different exe name means this archive is not the manager build the
    # release tooling publishes; refuse it instead of guessing.
    $exe = Join-Path $Directory $script:ManagerExe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw ("The published manager archive does not contain {0}." -f $script:ManagerExe)
    }
    return $exe
}

function Exit-Setup([int]$Code) {
    # `irm | iex` has no script path, and exit there would close the user's
    # console. Surface the failure as an error instead.
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { exit $Code }
    throw ("SEDG setup stopped (exit {0})." -f $Code)
}

$script:ExitCode = 0
$staging = $null
try {
    $manifestUrl = Get-SetupManifestUrl
    $manifest = Get-SetupManifest $manifestUrl
    if ($manifestUrl -eq $script:DefaultManifestUrl) { Assert-SetupManifestCrossCheck $manifest }
    $plan = Get-SetupManagerPlan $manifest

    $staging = Join-Path ([IO.Path]::GetTempPath()) ('sedg-setup-' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $zip = Join-Path $staging 'manager.zip'
    Save-SetupFile $plan.Url $zip
    Assert-SetupHash $zip $plan.Sha256 ("manager {0}" -f $plan.Version)
    $exe = Expand-SetupManager $zip $staging
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    Write-Host ("Starting SEDG Manager {0} ..." -f $plan.Version)
    Start-Process -FilePath $exe -WorkingDirectory $staging | Out-Null
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    if ($null -ne $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    $script:ExitCode = 1
} finally {
    try { $ErrorActionPreference = $script:SavedErrorAction } catch { }
    try { $ProgressPreference = $script:SavedProgress } catch { }
    try { if ($null -ne $script:SavedSecurityProtocol) { [Net.ServicePointManager]::SecurityProtocol = $script:SavedSecurityProtocol } } catch { }
}

if ($script:ExitCode -ne 0) { Exit-Setup $script:ExitCode }
