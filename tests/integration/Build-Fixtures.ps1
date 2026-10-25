# Builds the local fixture assets served by the integration smoke test.
# Produces in -OutDir (a plain HTTP server root):
#   approved-releases.json         approved-only manifest pointing at the fixtures
#   version.json                   distribution metadata served next to installer.ps1
#   installer.ps1                  copy of the repo installer
#   <GitHub-like layout>/...       component fixture zips under REPO/releases/download/TAG/
#   nssm-2.24.zip                  the REAL NSSM archive, re-served locally so CI
#                                  never depends on nssm.cc availability
# All hashes are computed at build time, so SHA-256 pinning stays enforced.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$AssetBaseUrl
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installerPath = Join-Path $repoRoot 'installer.ps1'

if ([string]::IsNullOrWhiteSpace($AssetBaseUrl)) { $AssetBaseUrl = $env:SEDG_ASSET_BASE_URL }
if ([string]::IsNullOrWhiteSpace($AssetBaseUrl)) { throw 'AssetBaseUrl is required (or set SEDG_ASSET_BASE_URL).' }
$AssetBaseUrl = $AssetBaseUrl.TrimEnd('/')

$dnsTag = 'v0.86.0'
$zapTag = 'v72.13'
$dnsAsset = 'dnsproxy-windows-amd64-v0.86.0.zip'
$zapAsset = 'zapret-v72.13.zip'
# Preferred origin first, then the Internet Archive copy (verified to be
# byte-identical to the pinned nssm SHA-256 727d1e42...6743): CI must not
# depend on nssm.cc uptime. Whichever archive is downloaded is hash-pinned
# into the fixture manifest and re-served from the loopback fixture server.
$nssmCandidates = @(
    'https://nssm.cc/release/nssm-2.24.zip',
    'https://web.archive.org/web/2id_/https://nssm.cc/release/nssm-2.24.zip'
)

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('sedg-fixtures-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Get-FileSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

try {
    # Component stubs are compiled from the C# below so no binaries live in
    # the repo and every CI run builds them from reviewable source.
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw 'csc.exe not found (need .NET Framework 4.x).' }

    $dnsStubCs = Join-Path $work 'stub-dnsproxy.cs'
    Set-Content -LiteralPath $dnsStubCs -Encoding ASCII -Value @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

// Stand-in for dnsproxy.exe: listens on 127.0.0.1:53 (UDP and DNS-over-TCP)
// and answers every query with a single A record 127.0.0.1. Enough for the
// installer listener check and the watchdog health check. Fixture only.
class StubDnsProxy {
    static void Main() {
        var udp = new UdpClient(AddressFamily.InterNetwork);
        udp.Client.Bind(new IPEndPoint(IPAddress.Loopback, 53));
        var tcp = new TcpListener(IPAddress.Loopback, 53);
        tcp.Start();
        new Thread(TcpLoop) { IsBackground = true }.Start(tcp);
        var from = new IPEndPoint(IPAddress.Any, 0);
        while (true) {
            byte[] q = udp.Receive(ref from);
            byte[] r = Reply(q, q.Length);
            if (r != null) udp.Send(r, r.Length, from);
        }
    }
    static void TcpLoop(object state) {
        var tcp = (TcpListener)state;
        while (true) {
            TcpClient c = tcp.AcceptTcpClient();
            new Thread(o => {
                TcpClient client = (TcpClient)o;
                try {
                    var s = client.GetStream();
                    byte[] len = new byte[2];
                    while (s.Read(len, 0, 2) == 2) {
                        int n = (len[0] << 8) | len[1];
                        byte[] q = new byte[n];
                        int got = 0;
                        while (got < n) { int k = s.Read(q, got, n - got); if (k <= 0) break; got += k; }
                        byte[] r = Reply(q, n);
                        if (r != null) {
                            byte[] rl = { (byte)(r.Length >> 8), (byte)(r.Length & 0xFF) };
                            s.Write(rl, 0, 2); s.Write(r, 0, r.Length);
                        }
                    }
                } catch {}
                finally { client.Close(); }
            }) { IsBackground = true }.Start(c);
        }
    }
    static byte[] Reply(byte[] q, int len) {
        if (len < 13) return null;
        int i = 12;
        while (i < len && q[i] != 0) i += q[i] + 1;
        if (i + 5 > len) return null;
        int qEnd = i + 5;
        var ms = new MemoryStream();
        ms.Write(q, 0, qEnd);
        byte[] answer = { 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1E, 0x00, 0x04, 0x7F, 0x00, 0x00, 0x01 };
        ms.Write(answer, 0, answer.Length);
        byte[] r = ms.ToArray();
        r[2] = 0x81; r[3] = 0x80;
        r[6] = 0; r[7] = 1;
        r[8] = 0; r[9] = 0; r[10] = 0; r[11] = 0;
        return r;
    }
}
'@

    $winwsStubCs = Join-Path $work 'stub-winws.cs'
    Set-Content -LiteralPath $winwsStubCs -Encoding ASCII -Value @'
using System;
using System.Threading;

// Stand-in for winws.exe: runs forever so the NSSM service stays Running.
// Never touches the WinDivert driver. Fixture only.
class StubWinws {
    static void Main() { Thread.Sleep(Timeout.Infinite); }
}
'@

    $dnsExeDir = Join-Path $work 'dns-stub'
    $zapExeDir = Join-Path $work 'zap-stub'
    New-Item -ItemType Directory -Path $dnsExeDir -Force | Out-Null
    New-Item -ItemType Directory -Path $zapExeDir -Force | Out-Null
    $dnsOutArg = '/out:' + (Join-Path $dnsExeDir 'dnsproxy.exe')
    & $csc /nologo $dnsOutArg $dnsStubCs
    if ($LASTEXITCODE -ne 0) { throw 'csc failed for the dnsproxy stub.' }
    $zapOutArg = '/out:' + (Join-Path $zapExeDir 'winws.exe')
    & $csc /nologo $zapOutArg $winwsStubCs
    if ($LASTEXITCODE -ne 0) { throw 'csc failed for the winws stub.' }

    # Component zips live under their GitHub-like path layout: the asset
    # base seam only swaps the origin (github.com -> fixture server), so the
    # URL paths (/REPO/releases/download/TAG/ASSET) must exist on disk.
    function New-AssetUrlDir([string]$Repo, [string]$Tag) {
        $dir = Join-Path $OutDir ($Repo.Replace('/', '\') + '\releases\download\' + $Tag)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    # dnsproxy fixture zip: the installer finds dnsproxy.exe anywhere inside.
    $dnsZip = Join-Path (New-AssetUrlDir 'AdguardTeam/dnsproxy' $dnsTag) $dnsAsset
    Compress-Archive -Path (Join-Path $dnsExeDir 'dnsproxy.exe') -DestinationPath $dnsZip -Force

    # zapret fixture zip: exactly one windows-x86_64 directory, containing the
    # files the stage validation step requires (winws.exe, cygwin1.dll,
    # WinDivert.dll, WinDivert64.sys). The .dll/.sys entries are dummy bytes:
    # the stub never loads the driver.
    $zapSrc = Join-Path $work 'zapret-v72.13'
    $zapRuntime = Join-Path $zapSrc 'windows-x86_64'
    New-Item -ItemType Directory -Path $zapRuntime -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $zapExeDir 'winws.exe') -Destination $zapRuntime -Force
    foreach ($name in @('cygwin1.dll', 'WinDivert.dll', 'WinDivert64.sys')) {
        [IO.File]::WriteAllBytes((Join-Path $zapRuntime $name), [byte[]](0x00))
    }
    $zapZip = Join-Path (New-AssetUrlDir 'bol-van/zapret' $zapTag) $zapAsset
    Compress-Archive -Path (Join-Path $work 'zapret-v72.13') -DestinationPath $zapZip -Force

    # Real NSSM archive: download from the first reachable origin, pin its
    # SHA-256 into the fixture manifest and serve it locally.
    $nssmZip = Join-Path $OutDir 'nssm-2.24.zip'
    $nssmErrors = @()
    $nssmHash = $null
    foreach ($candidate in $nssmCandidates) {
        Remove-Item -LiteralPath $nssmZip -Force -ErrorAction SilentlyContinue
        & curl.exe --fail --location --proto '=https' --proto-redir '=https' --retry 1 --retry-delay 2 --connect-timeout 20 --max-time 300 --output $nssmZip $candidate
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $nssmZip)) {
            $nssmHash = Get-FileSha256 $nssmZip
            break
        }
        $nssmErrors += $candidate
    }
    if (-not $nssmHash) { throw "Could not download NSSM from any origin: $($nssmErrors -join ', ')." }

    # Installer version must match the manifest exactly (the installer throws
    # otherwise), so it is extracted from installer.ps1 itself.
    $ivLine = (Select-String -LiteralPath $installerPath -Pattern "InstallerVersion = '" | Select-Object -First 1).Line
    $installerVersion = ($ivLine -replace "^.*'([^']+)'.*", '$1').Trim()
    if ([string]::IsNullOrWhiteSpace($installerVersion)) { throw 'Could not read InstallerVersion from installer.ps1.' }

    $manifest = [ordered]@{
        schema = 1
        policy = 'approved-only'
        installer = [ordered]@{ version = $installerVersion }
        components = [ordered]@{
            dnsproxy = [ordered]@{
                repository = 'AdguardTeam/dnsproxy'
                tag = $dnsTag
                asset = $dnsAsset
                sha256 = (Get-FileSha256 $dnsZip)
            }
            zapret = [ordered]@{
                repository = 'bol-van/zapret'
                tag = $zapTag
                asset = $zapAsset
                sha256 = (Get-FileSha256 $zapZip)
            }
            nssm = [ordered]@{
                version = '2.24'
                asset = 'nssm-2.24.zip'
                url = ($AssetBaseUrl + '/nssm-2.24.zip')
                sha256 = $nssmHash
            }
        }
    }
    # Named approved-releases.json (not manifest.json) so the installer's
    # distribution-base derivation (manifest URL minus the file name) resolves
    # to the fixture server root and the manager self-update probe works.
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $OutDir 'approved-releases.json') -Encoding ASCII

    # Distribution metadata served next to installer.ps1 (the manager
    # self-update path reads it; versions match so self-update stays idle).
    $versionInfo = [ordered]@{
        version = $installerVersion
        commit = 'local-fixture'
        sha256 = (Get-FileSha256 $installerPath)
        built = (Get-Date).ToUniversalTime().ToString('o')
    }
    ($versionInfo | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $OutDir 'version.json') -Encoding ASCII
    Copy-Item -LiteralPath $installerPath -Destination (Join-Path $OutDir 'installer.ps1') -Force

    Write-Host "Fixtures built in $OutDir (installer $installerVersion)"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
