# Elevated end-to-end smoke: runs the real installer as a child process
# (Install -> Status -> Restart -> Uninstall -Purge) against a local fixture
# server and asserts the real system effects: SCM services via NSSM, the
# watchdog scheduled task, DNS mutation and its restore, and file state.
# Requires admin. Isolation comes from the installer's own seams:
#   SEDG_INSTALL_PATH    isolated install directory (this script refuses to run without it)
#   SEDG_MANIFEST_URL    fixture manifest on the loopback fixture server
#   SEDG_ASSET_BASE_URL  loopback origin the installer downloads fixture assets from
# Per-file SHA-256 verification stays enforced for every staged component.
# All configuration comes from environment variables; no parameters needed.
#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installerPath = Join-Path $repoRoot 'installer.ps1'

$installPath = $env:SEDG_INSTALL_PATH
if ([string]::IsNullOrWhiteSpace($installPath)) { throw 'SEDG_INSTALL_PATH must point at an isolated install directory.' }
if (Test-Path -LiteralPath $installPath) { throw "Install dir '$installPath' already exists; refusing to run against a dirty machine." }
$services = @('dnsproxy-service', 'winws-service')
$watchdogTask = 'SEDG-DNS-Watchdog'
$dnsBackupSafe = Join-Path $env:ProgramData 'serverless-edge-dns-gateway\dns-backup.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "SMOKE ASSERT FAILED: $Message" }
}

function Invoke-Installer([string]$Action, [string[]]$Extra = @()) {
    Write-Host "=== installer -Action $Action $($Extra -join ' ') ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerPath -Action $Action -Language en -AllowSeam @Extra
    if ($LASTEXITCODE -ne 0) { throw "installer -Action $Action exited with code $LASTEXITCODE" }
}

function Get-AdaptersUsingLocalDns {
    @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue |
        Where-Object { @($_.ServerAddresses) -contains '127.0.0.1' })
}

try {
    Write-Host '=== Install ==='
    Invoke-Installer 'Install'

    foreach ($name in $services) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        Assert-True ($null -ne $svc) "service $name exists after install"
        Assert-True ($svc.Status -eq 'Running') "service $name is Running (got $($svc.Status))"
    }
    Assert-True ($null -ne (Get-ScheduledTask -TaskName $watchdogTask -ErrorAction SilentlyContinue)) 'watchdog scheduled task exists'
    foreach ($rel in @('dnsproxy\dnsproxy.exe', 'zapret\winws.exe', 'zapret\WinDivert64.sys', 'nssm.exe', 'dnsproxy\config.yaml', 'zapret\blacklist.txt', 'zapret\winws-args.txt', 'state.json', 'Gateway-Manager.bat', 'watchdog.ps1')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $installPath $rel)) "installed file present: $rel"
    }
    Assert-True (@(Get-AdaptersUsingLocalDns).Count -gt 0) 'at least one adapter uses local DNS 127.0.0.1'

    Write-Host '=== Status ==='
    Invoke-Installer 'Status'

    Write-Host '=== Restart ==='
    Invoke-Installer 'Restart'
    foreach ($name in $services) {
        Assert-True ((Get-Service -Name $name).Status -eq 'Running') "service $name Running after restart"
    }

    # Stop any in-flight watchdog instance so Uninstall is not racing a script
    # that runs from the install directory (its every-minute tick).
    Stop-ScheduledTask -TaskName $watchdogTask -ErrorAction SilentlyContinue

    Write-Host '=== Uninstall ==='
    Invoke-Installer 'Uninstall' @('-Purge')

    foreach ($name in $services) {
        Assert-True ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) "service $name removed"
    }
    Assert-True ($null -eq (Get-ScheduledTask -TaskName $watchdogTask -ErrorAction SilentlyContinue)) 'watchdog scheduled task removed'
    # The DNS backup is intentionally kept when the restore could not be
    # fully replayed (e.g. adapters that vanished between backup and restore,
    # like ephemeral docker networks on CI runners), and deleted when the
    # restore succeeded. Both outcomes are correct; the functional guarantee
    # is asserted below: no adapter keeps the local resolver.
    if (Test-Path -LiteralPath $dnsBackupSafe) {
        Write-Host 'note: DNS backup kept (restore was not a full replay); the install dir is gone so re-uninstall will not replay it'
    }
    # Locked-file handling may legitimately delay directory removal; allow a
    # short window before declaring failure.
    $deadline = (Get-Date).AddSeconds(75)
    while ((Test-Path -LiteralPath $installPath) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Seconds 5
    }
    Assert-True (-not (Test-Path -LiteralPath $installPath)) 'install directory removed'
    Assert-True (@(Get-AdaptersUsingLocalDns).Count -eq 0) 'no adapter keeps local DNS after uninstall'

    Write-Host '=== SMOKE OK ==='
    exit 0
} catch {
    Write-Host "=== SMOKE FAILED: $($_.Exception.Message) ===" -ForegroundColor Red
    exit 1
}
