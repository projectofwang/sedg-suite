#requires -Version 5.1
# Serverless Edge DNS Gateway with Zapret DPI Bypass - Auto Installer.
# Copyright (c) 2026 projectofwang. Licensed under the MIT License - see
# LICENSE in the repository root. Third-party notices: see THIRD-PARTY.md.
param(
    [ValidateSet('Install','Update','Pause','Resume','Restart','Uninstall','Status','SetUpstream','SetDns','Menu')]
    [string]$Action = 'Menu',
    [string]$Upstream,
    [string]$Language = '',
    [switch]$IncludeCdnTest,
    [switch]$ForceUpdate,
    [switch]$Clean,
    [switch]$DnsOnly,
    [switch]$Purge,
    [switch]$FailClosed,
    [switch]$AllowSeam,
    [switch]$AllowDowngrade,
    [ValidateSet('none','jsonl')][string]$Protocol = 'none'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The jsonl protocol owns stdout. Capture it before any diagnostic output,
# then move managed and native console output to stderr so the machine stream
# stays pure. Default mode never enters this block.
$script:ProtocolOut = $null
$script:ProtocolResultSent = $false
$script:ProtocolMode = $false
$script:CdnStructured = $false
if ($Protocol -eq 'jsonl') {
    # The protocol wire format is UTF-8. A host console on an OEM code page
    # would decode a BOM or non-ASCII argument into garbage before parsing.
    try { [Console]::InputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    $script:ProtocolOut = [Console]::Out
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SedgProtocolConsole {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetStdHandle(int nStdHandle, IntPtr handle);
}
'@
        [void][SedgProtocolConsole]::SetStdHandle(-11, [SedgProtocolConsole]::GetStdHandle(-12))
    } catch { }
    try { [Console]::SetOut([Console]::Error) } catch { }
}

# Restore these in `finally` so irm|iex never pollutes the caller session.
$script:SavedErrorAction = $ErrorActionPreference
$script:SavedProgress = $ProgressPreference
try { $script:SavedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol } catch { $script:SavedSecurityProtocol = $null }
try { $script:SavedOutputEncoding = [Console]::OutputEncoding } catch { $script:SavedOutputEncoding = $null }

# Quiet progress (slow on PS 5.1) and modern TLS. 12288 is the TLS 1.3
# flag, absent on old .NET (then TLS 1.2).
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = ([Net.SecurityProtocolType]::Tls12 -bor 12288)
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Prefer UTF-8 console output so box-drawing UI renders; silently keep the
# current encoding on hosts that do not allow the switch.
try {
    if ([Console]::OutputEncoding.IsSingleByte) {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    }
} catch { Write-Warning ('SEDG:script: if ([Console]::OutputEncoding.IsSingleByte) { [Console]::Out... (' + $_.Exception.Message + ')'); Write-Verbose $_ }

$script:ManifestCache = $null

# Also runs via irm|iex. There $MyInvocation is only a stub snippet, never
# source material: elevation and manager install re-fetch hash-verified
# copies (see Ensure-Administrator / Get-ManagerSourceContent).
$script:SelfPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($script:SelfPath)) {
    # irm ... | iex has no stable script path. Use a fresh temporary path so
    # elevation can never execute a stale installer left by an older run.
    $tempInstallerName = 'serverless-edge-dns-gateway-installer-{0}.ps1' -f ([guid]::NewGuid().ToString('N'))
    $script:SelfPath = Join-Path $env:TEMP $tempInstallerName
}
# In-memory copy taken before any wipe, so Write-Manager can restore
# manager.ps1 even when the running file was deleted.
$script:SelfContent = $null
try {
    if (Test-Path -LiteralPath $script:SelfPath -PathType Leaf) {
        $script:SelfContent = Get-Content -LiteralPath $script:SelfPath -Raw -ErrorAction Stop
    }
} catch { $script:SelfContent = $null }

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#region MaintainConfig
# Single source of truth for install layout, pinned versions and upstream
# sources. Values below are the historical defaults and never change here;
# SEDG_INSTALL_PATH / SEDG_MANIFEST_URL only override them when explicitly
# set (optional, for tests and packaging - nothing requires them). The seams
# are ignored when elevated unless -AllowSeam is passed.

$script:InstallerVersion = '2.0.0'
if ((-not [string]::IsNullOrWhiteSpace($env:SEDG_INSTALL_PATH)) -and ($AllowSeam -or (-not (Test-Administrator)))) {
    Write-Warning 'SEDG_INSTALL_PATH test seam is active; install layout leaves the default.'
    $script:InstallPath = $env:SEDG_INSTALL_PATH
} else {
    # F2: the seam is locked when elevated unless -AllowSeam; say so when
    # the env var is set but ignored so a dirty env never applies silently.
    if (-not [string]::IsNullOrWhiteSpace($env:SEDG_INSTALL_PATH)) { Write-Warning 'SEDG_INSTALL_PATH is set but ignored; test seams require -AllowSeam when elevated.' }
    $script:InstallPath = 'C:\serverless-edge-dns-gateway'
}
$script:ObsoleteInstallPaths = @(
    'C:\dns-doh',
    'C:\dns-bibica-net-doh'
)
$script:DnsProxyPath = Join-Path $script:InstallPath 'dnsproxy'
$script:ZapretPath = Join-Path $script:InstallPath 'zapret'
$script:NssmPath = Join-Path $script:InstallPath 'nssm.exe'
$script:ManagerExe = 'sedg-manager.exe'
$script:ManagerPath = Join-Path $script:InstallPath $script:ManagerExe
$script:LegacyManagerPath = Join-Path $env:ProgramFiles 'SEDG Manager'
$script:DnsBackupDir = Join-Path $env:ProgramData 'serverless-edge-dns-gateway'
# H1: staging lives in an admin-only directory under ProgramData, never %TEMP%.
$script:TempPath = Join-Path $script:DnsBackupDir 'staging'
$script:ConfigFile = Join-Path $DnsProxyPath 'config.yaml'
$script:BlacklistFile = Join-Path $ZapretPath 'blacklist.txt'
$script:WinwsArgsFile = Join-Path $ZapretPath 'winws-args.txt'
$script:StateFile = Join-Path $script:InstallPath 'state.json'
$script:DnsBackupFile = Join-Path $script:InstallPath 'dns-backup.json'
$script:DnsBackupSafe = Join-Path $script:DnsBackupDir 'dns-backup.json'
$script:GatewayFlag = Join-Path $script:InstallPath 'gateway-enabled'
$script:FailClosedFile = Join-Path $script:InstallPath 'fail-closed'
$script:BootstrapTainted = @('127.0.0.1', '::1', '1.1.1.1', '8.8.8.8', '2606:4700:4700::1111', '2001:4860:4860::8888')
$script:DefaultWinwsArgsTemplate = '--wf-tcp=80,443 --wf-udp=443 --hostlist="{0}" --dpi-desync=fake,disorder2 --dpi-desync-fooling=badseq --dpi-desync-repeats=6'
$script:DnsProxyService = 'dnsproxy-service'
$script:WinwsService = 'winws-service'
$script:WatchdogTask = 'SEDG-DNS-Watchdog'
$script:WatchdogScript = Join-Path $script:InstallPath 'watchdog.ps1'
$script:WatchdogFlag = Join-Path $script:InstallPath 'watchdog-fallback.flag'
$script:WatchdogCount = Join-Path $script:InstallPath 'watchdog-count.txt'

$script:manifestUrl = 'https://dl.taiyuanwangjie.dpdns.org/approved-releases.json'
if ((-not [string]::IsNullOrWhiteSpace($env:SEDG_MANIFEST_URL)) -and ($AllowSeam -or (-not (Test-Administrator)))) {
    Write-Warning 'SEDG_MANIFEST_URL test seam is active; manifest source leaves the default.'
    $script:manifestUrl = $env:SEDG_MANIFEST_URL
} else {
    # F2: locked when elevated unless -AllowSeam; warn when ignored.
    if (-not [string]::IsNullOrWhiteSpace($env:SEDG_MANIFEST_URL)) { Write-Warning 'SEDG_MANIFEST_URL is set but ignored; test seams require -AllowSeam when elevated.' }
}
$script:Sources = @{
    Manifest         = $script:manifestUrl
    ManifestFallback = 'https://raw.githubusercontent.com/projectofwang/sedg-suite/main/approved-releases.json'
    NssmZip     = 'https://nssm.cc/release/nssm-2.24.zip'
}
$script:NssmVersion = '2.24'
$script:NssmSha256 = '727d1e42275c605e0f04aba98095c38a8e1e46def453cdffce42869428aa6743'
$script:ManagerRepository = 'projectofwang/sedg-suite'
$script:ManagerTag = '2.0.0'
$script:ManagerAsset = 'sedg-manager-win-x64-2.0.0.zip'
$script:ManagerSha256 = '0dfef898b47e2f26f8b65ade4e5ffeac270a10b65bbc41f793ae3f95d9f5ee8d'
$script:LangDir = Join-Path $env:APPDATA 'serverless-edge-dns-gateway'
$script:LangFile = Join-Path $script:LangDir 'lang.txt'

# Preset DoH upstreams offered by the menu; the first entry is the default.
$script:OptionalUpstreams = [ordered]@{
    'SDEG (Default)' = 'https://sdns.taiyuanwangjie.dpdns.org/dns-query'
    'NextDNS (735d22)' = 'https://ultralow2.dns2.nextdns.io/735d22'
    'NextDNS (9fcbfc)' = 'https://ultralow2.dns2.nextdns.io/9fcbfc'
    'Cloudflare' = 'https://cloudflare-dns.com/dns-query'
    'Google' = 'https://dns.google/dns-query'
    'Quad9' = 'https://dns.quad9.net/dns-query'
    'AdGuard' = 'https://dns.adguard-dns.com/dns-query'
}

#endregion MaintainConfig

$script:Texts = @{
  EN = @{
    MenuTitle='Serverless Edge DNS Gateway + Zapret DPI Bypass'; MiInstall='Install'; MiUpdate='Update'; MiStatus='Status'
    MiRestart='Restart'; MiPause='Pause'; MiResume='Resume'; MiUpstream='DNS Upstream';
    MiSysDns='System DNS'; MiCdn='CDN test'; MiUninstall='Uninstall'; MiLang='Language / Ng\u00F4n ng\u1EEF'; MiExit='Exit'
    PmtSelect='Select'; PmtContinue='Press Enter to continue'; MsgInvalid='Invalid selection.'
    UpTitle='DNS Upstream'; UpOpt2='Custom DNS - enter your own upstream URL'; UpOptReset='Reset to defaults'
    UpSelect='Select upstream'; UpEnter='Enter custom DNS Upstream URL (https://, tls://, h3:// or quic://)'
    UpInvalid='Invalid upstream selection.'; UpBad='Invalid DNS Upstream. Use an absolute https://, tls://, h3:// or quic:// URL.'
    UpChanging='Changing DNS Upstream...'; UpChanged='DNS Upstream changed: ';
    EdCurrent='Current: ';
    DnsTitle='System DNS'; DnsIntro1='Set DNS directly on all active network adapters.'
    DnsIntro2='Enter an IPv4 address for the primary DNS.'; DnsPrimary='Primary IPv4 DNS'
    DnsPrimaryReq='Primary IPv4 DNS is required.'; DnsSecondary='Secondary IPv4 DNS (optional)'
    DnsV6='IPv6 DNS (optional, press Enter to keep DHCP)'; DnsV6Sec='Secondary IPv6 DNS (optional)'
    DnsBadV4='Invalid IPv4 DNS address: '; DnsBadV6='Invalid IPv6 DNS address: '
    DnsApplying='Applying system DNS...'; DnsDoneV4='System IPv4 DNS set to: '; DnsDoneV6='System IPv6 DNS set to: '
    DnsDoneDhcp='System IPv6 DNS set to DHCP.'
    StTitle='System Status'; StInstall='Installation'; StServices='Services'; StNetwork='Network'; StVersions='Versions'
    StLastUpdate='Last update'; StStatus='Status'; StLocation='Install location'
    VInstalled='Installed'; VNotInstalled='Not installed'; VNA='Not available'; VNotActive='Not active'
    VActive='Active'; VAttention='Attention required'; VReady='READY'; VAttReq='ATTENTION REQUIRED'
    TChecking='Checking services and DNS...'; SvcRunning='Running'; SvcNotFound='service not found'
    LocalDnsOk='Local DNS IPv4 127.0.0.1: enabled'; LocalDnsFail='Local DNS IPv4 127.0.0.1: not enabled'
    SumDone='INSTALLATION COMPLETE'; SumZap='Zapret: Running'; SumProxy='DNSProxy: Running'
    CdnAsk='Run CDN connectivity test? Queries api.ip.sb/ipinfo.io (y/N)'
    CdnSkip='CDN test skipped (opt-in via menu [9] or -IncludeCdnTest).'
    PauseDone='Pause completed.'; PauseKept='DNS reset to DHCP; local proxy is paused.'
    UpdDone='Update completed successfully.'; UpdKept='Binaries updated; local config and blacklist preserved.'
    ResumeDone='Resume completed successfully.'; RestartDone='Restart completed successfully.'
    UninstDone='Uninstall completed successfully.'; UninstRemoved='DNS reset to DHCP; removed '
    UninstStarted='Uninstall started successfully.'; UninstSched='DNS reset to DHCP; cleanup of '
    UninstSched2=' is scheduled (locked files remain).'; NotInstalled='Not installed.'
    NotFound='Installation not found.'; LangTitle='Language / Ng\u00F4n ng\u1EEF'; LangOptE='English'; LangOptV='Ti\u1EBFng Vi\u1EC7t'
    LangSelect='Select language'; LangInvalid='Invalid language selection. Choose 1 or 2.'
    LangDone='Language applied.'; NoAdapters='No active network adapters were found.';
    WarnManifestFallback='WARNING: Approved manifest could not be downloaded; using embedded approved versions.';
    WarnRetrying='Retrying download ({0}/3)...';
    InfoRemovingWinDivert='Removing old WinDivert...';
    WarnWinDivertScheduled='WinDivert is still marked for deletion; driver removal was scheduled for the next reboot.';
    WarnDriverLocked='WinDivert64.sys is still locked; deletion was scheduled for the next reboot.';
    WarnDnsResetFailed='DNS DHCP reset failed for {0}';
    DoneVerified='{0} verified.';
    LblDnsArchive='DNSProxy archive';
    LblZapArchive='Zapret archive';
    LblNssmArchive='NSSM archive';
    StDlDnsproxy='Downloading DNSProxy {0}...';
    StDlZapret='Downloading Zapret {0}...';
    StPrepNssm='Preparing NSSM {0}...';
    DoneNssmStaged='NSSM {0} staged.';
    DoneDnsStaged='DNSProxy executable staged: {0}';
    InfoPreserveConfig='Existing user config and blacklist will be preserved.';
    WarnRollingBack='Installation failed; rolling back...';
    WarnRollback='Rollback warning: {0}';
    DoneUpstreamChanged='dnsproxy upstream changed to {0}; all other config content preserved.';
    WarnDirBlocked='Full directory removal blocked (likely locked driver); clearing unlocked files...';
    WarnDriverKept='Locked driver kept for reboot cleanup: {0}';
    WarnRebootRequired='A reboot is required after install to load the new driver version.';
    InfoRemovingExisting='Removing existing installation: {0}';
    InfoRemovingObsolete='Removing obsolete installation directory: {0}';
    DoneRemoved='Removed: {0}';
    InfoVerifyReboot='Verify after reboot: the directory should be gone.';
    CdnLoc='Your Location: {0}';
    CdnIsp='Your ISP:      {0}';
    CdnErr='{0} Error / Timeout';
    CdnPingBlocked='{0} (DNS OK, ping blocked: {1}{2})';
    InfoDnsTarget='DNS target: 127.0.0.1:53';
    InfoTmpV4='Temporary DNS IPv4: 1.1.1.1, 8.8.8.8';
    InfoTmpV6='Temporary DNS IPv6: 2606:4700:4700::1111, 2001:4860:4860::8888';
    InfoExtracting='Extracting verified archive...';
    InfoExtractingZapret='Extracting verified archive and selecting Windows x64 runtime...';
    StVerPath='Version: {0}    Path: {1}';
    StLocalV4='Local DNS IPv4';
    StGw='DNS Gateway';
    MnUpstream='Upstream';
    MnLocalDns='Local DNS active (127.0.0.1)'; MnOtherDns='System DNS / DHCP';
    StConfig='Config file';
    SumHint='Manage later with Gateway-Manager.bat in the install folder.';
    LbService='Service';
    LbExecutable='Executable';
    LbConfig='Config';
    LbFile='File';
    LbPath='Path';
    LbTarget='Target';
    LbStaging='Staging directory';
    LbSource='Source';
    LbDest='Destination';
    LbSize='Archive size';
    LbBytes='bytes';
    LbRuntime='Runtime';
    LbAdapter='Adapter';
    LbApproved='Approved {0}';
    LbVersions='Versions';
    LbAssetDns='DNSProxy asset';
    LbAssetZap='Zapret asset';
    UpdSkipped='Components already up to date; skipping download.';
    WarnObsoleteKept='Skipping locked obsolete path, continuing.';
    MutexBusy='Another install/update operation is already running.';
    WarnAdapterUncovered='Active adapter without local DNS: {0}';
    CfgInvalid='Existing DNSProxy config is invalid; backed up and rewritten.'
  }
  VI = @{
    MenuTitle='Serverless Edge DNS Gateway + Zapret DPI Bypass'; MiInstall='C\u00E0i \u0111\u1EB7t'; MiUpdate='C\u1EADp nh\u1EADt'; MiStatus='Tr\u1EA1ng th\u00E1i'
    MiRestart='Kh\u1EDFi \u0111\u1ED9ng l\u1EA1i'; MiPause='T\u1EA1m d\u1EEBng'; MiResume='Ti\u1EBFp t\u1EE5c'; MiUpstream='Upstream DNS';
    MiSysDns='DNS h\u1EC7 th\u1ED1ng'; MiCdn='Ki\u1EC3m tra CDN'; MiUninstall='G\u1EE1 c\u00E0i \u0111\u1EB7t'; MiLang='Language / Ng\u00F4n ng\u1EEF'; MiExit='Tho\u00E1t'
    PmtSelect='Ch\u1ECDn'; PmtContinue='Nh\u1EA5n Enter \u0111\u1EC3 ti\u1EBFp t\u1EE5c'; MsgInvalid='L\u1EF1a ch\u1ECDn kh\u00F4ng h\u1EE3p l\u1EC7.'
    UpTitle='Upstream DNS'; UpOpt2='Custom DNS - t\u1EF1 nh\u1EADp upstream URL'; UpOptReset='Reset v\u1EC1 defaults'
    UpSelect='Ch\u1ECDn upstream'; UpEnter='Nh\u1EADp URL upstream DNS (https://, tls://, h3:// ho\u1EB7c quic://)'
    UpInvalid='L\u1EF1a ch\u1ECDn upstream kh\u00F4ng h\u1EE3p l\u1EC7.'; UpBad='Upstream DNS kh\u00F4ng h\u1EE3p l\u1EC7. D\u00F9ng URL tuy\u1EC7t \u0111\u1ED1i https://, tls://, h3:// ho\u1EB7c quic://.'
    UpChanging='\u0110ang \u0111\u1ED5i upstream DNS...'; UpChanged='\u0110\u00E3 \u0111\u1ED5i upstream DNS: ';
    EdCurrent='Hi\u1EC7n t\u1EA1i: ';
    DnsTitle='DNS h\u1EC7 th\u1ED1ng'; DnsIntro1='\u0110\u1EB7t DNS tr\u1EF1c ti\u1EBFp cho m\u1ECDi adapter \u0111ang ho\u1EA1t \u0111\u1ED9ng.'
    DnsIntro2='Nh\u1EADp \u0111\u1ECBa ch\u1EC9 IPv4 cho DNS ch\u00EDnh.'; DnsPrimary='DNS IPv4 ch\u00EDnh'
    DnsPrimaryReq='B\u1EAFt bu\u1ED9c nh\u1EADp DNS IPv4 ch\u00EDnh.'; DnsSecondary='DNS IPv4 ph\u1EE5 (t\u00F9y ch\u1ECDn)'
    DnsV6='DNS IPv6 (t\u00F9y ch\u1ECDn, Enter \u0111\u1EC3 gi\u1EEF DHCP)'; DnsV6Sec='DNS IPv6 ph\u1EE5 (t\u00F9y ch\u1ECDn)'
    DnsBadV4='\u0110\u1ECBa ch\u1EC9 DNS IPv4 kh\u00F4ng h\u1EE3p l\u1EC7: '; DnsBadV6='\u0110\u1ECBa ch\u1EC9 DNS IPv6 kh\u00F4ng h\u1EE3p l\u1EC7: '
    DnsApplying='\u0110ang \u00E1p d\u1EE5ng DNS h\u1EC7 th\u1ED1ng...'; DnsDoneV4='\u0110\u00E3 \u0111\u1EB7t DNS IPv4 h\u1EC7 th\u1ED1ng: '; DnsDoneV6='\u0110\u00E3 \u0111\u1EB7t DNS IPv6 h\u1EC7 th\u1ED1ng: '
    DnsDoneDhcp='DNS IPv6 h\u1EC7 th\u1ED1ng: DHCP.'
    StTitle='Tr\u1EA1ng th\u00E1i h\u1EC7 th\u1ED1ng'; StInstall='C\u00E0i \u0111\u1EB7t'; StServices='D\u1ECBch v\u1EE5'; StNetwork='M\u1EA1ng'; StVersions='Phi\u00EAn b\u1EA3n'
    StLastUpdate='C\u1EADp nh\u1EADt l\u1EA7n cu\u1ED1i'; StStatus='Tr\u1EA1ng th\u00E1i'; StLocation='V\u1ECB tr\u00ED c\u00E0i \u0111\u1EB7t'
    VInstalled='\u0110\u00E3 c\u00E0i'; VNotInstalled='Ch\u01B0a c\u00E0i'; VNA='Kh\u00F4ng c\u00F3'; VNotActive='Kh\u00F4ng ho\u1EA1t \u0111\u1ED9ng'
    VActive='Ho\u1EA1t \u0111\u1ED9ng'; VAttention='C\u1EA7n ki\u1EC3m tra'; VReady='S\u1EB4N S\u00C0NG'; VAttReq='C\u1EA6N KI\u1EC2M TRA'
    TChecking='\u0110ang ki\u1EC3m tra d\u1ECBch v\u1EE5 v\u00E0 DNS...'; SvcRunning='\u0110ang ch\u1EA1y'; SvcNotFound='kh\u00F4ng t\u00ECm th\u1EA5y d\u1ECBch v\u1EE5'
    LocalDnsOk='Local DNS IPv4 127.0.0.1: \u0111\u00E3 b\u1EADt'; LocalDnsFail='Local DNS IPv4 127.0.0.1: ch\u01B0a b\u1EADt'
    SumDone='C\u00C0I \u0110\u1EB6T HO\u00C0N T\u1EA4T'; SumZap='Zapret: \u0110ang ch\u1EA1y'; SumProxy='DNSProxy: \u0110ang ch\u1EA1y'
    CdnAsk='Ch\u1EA1y ki\u1EC3m tra CDN? S\u1EBD g\u1ECDi api.ip.sb/ipinfo.io (y/N)'
    CdnSkip='\u0110\u00E3 b\u1ECF qua ki\u1EC3m tra CDN (b\u1EADt \u1EDF menu [9] ho\u1EB7c -IncludeCdnTest).'
    PauseDone='\u0110\u00E3 t\u1EA1m d\u1EEBng.'; PauseKept='DNS \u0111\u00E3 v\u1EC1 DHCP; proxy local \u0111ang d\u1EEBng.'
    UpdDone='C\u1EADp nh\u1EADt th\u00E0nh c\u00F4ng.'; UpdKept='\u0110\u00E3 c\u1EADp nh\u1EADt binary; gi\u1EEF nguy\u00EAn config v\u00E0 blacklist.'
    ResumeDone='\u0110\u00E3 ti\u1EBFp t\u1EE5c th\u00E0nh c\u00F4ng.'; RestartDone='\u0110\u00E3 kh\u1EDFi \u0111\u1ED9ng l\u1EA1i th\u00E0nh c\u00F4ng.'
    UninstDone='G\u1EE1 c\u00E0i \u0111\u1EB7t th\u00E0nh c\u00F4ng.'; UninstRemoved='DNS \u0111\u00E3 v\u1EC1 DHCP; \u0111\u00E3 x\u00F3a '
    UninstStarted='\u0110\u00E3 b\u1EAFt \u0111\u1EA7u g\u1EE1 c\u00E0i \u0111\u1EB7t.'; UninstSched='DNS \u0111\u00E3 v\u1EC1 DHCP; d\u1ECDn d\u1EB9p '
    UninstSched2=' \u0111\u00E3 \u0111\u01B0\u1EE3c l\u00EAn l\u1ECBch (c\u00F2n file b\u1ECB kh\u00F3a).'; NotInstalled='Ch\u01B0a c\u00E0i \u0111\u1EB7t.'
    NotFound='Kh\u00F4ng t\u00ECm th\u1EA5y c\u00E0i \u0111\u1EB7t.'; LangTitle='Language / Ng\u00F4n ng\u1EEF'; LangOptE='English'; LangOptV='Ti\u1EBFng Vi\u1EC7t'
    LangSelect='Ch\u1ECDn ng\u00F4n ng\u1EEF'; LangInvalid='L\u1EF1a ch\u1ECDn ng\u00F4n ng\u1EEF kh\u00F4ng h\u1EE3p l\u1EC7. Ch\u1ECDn 1 ho\u1EB7c 2.'
    LangDone='\u0110\u00E3 \u00E1p d\u1EE5ng ng\u00F4n ng\u1EEF.'; NoAdapters='Kh\u00F4ng t\u00ECm th\u1EA5y adapter m\u1EA1ng \u0111ang ho\u1EA1t \u0111\u1ED9ng.';
    WarnManifestFallback='C\u1EA2NH B\u00C1O: Kh\u00F4ng t\u1EA3i \u0111\u01B0\u1EE3c manifest \u0111\u00E3 duy\u1EC7t; d\u00F9ng phi\u00EAn b\u1EA3n \u0111i k\u00E8m.';
    WarnRetrying='\u0110ang th\u1EED t\u1EA3i l\u1EA1i ({0}/3)...';
    InfoRemovingWinDivert='\u0110ang g\u1EE1 WinDivert c\u0169...';
    WarnWinDivertScheduled='WinDivert v\u1EABn \u0111ang ch\u1EDD x\u00F3a; \u0111\u00E3 h\u1EB9n g\u1EE1 driver \u1EDF l\u1EA7n kh\u1EDFi \u0111\u1ED9ng l\u1EA1i t\u1EDBi.';
    WarnDriverLocked='WinDivert64.sys v\u1EABn b\u1ECB kh\u00F3a; \u0111\u00E3 h\u1EB9n x\u00F3a \u1EDF l\u1EA7n kh\u1EDFi \u0111\u1ED9ng l\u1EA1i t\u1EDBi.';
    WarnDnsResetFailed='\u0110\u1EB7t l\u1EA1i DNS v\u1EC1 DHCP th\u1EA5t b\u1EA1i cho {0}';
    DoneVerified='\u0110\u00E3 x\u00E1c minh {0}.';
    LblDnsArchive='g\u00F3i DNSProxy';
    LblZapArchive='g\u00F3i Zapret';
    LblNssmArchive='g\u00F3i NSSM';
    StDlDnsproxy='\u0110ang t\u1EA3i DNSProxy {0}...';
    StDlZapret='\u0110ang t\u1EA3i Zapret {0}...';
    StPrepNssm='\u0110ang chu\u1EA9n b\u1ECB NSSM {0}...';
    DoneNssmStaged='\u0110\u00E3 chu\u1EA9n b\u1ECB xong NSSM {0}.';
    DoneDnsStaged='\u0110\u00E3 \u0111\u01B0a file DNSProxy v\u00E0o v\u1ECB tr\u00ED: {0}';
    InfoPreserveConfig='S\u1EBD gi\u1EEF nguy\u00EAn c\u1EA5u h\u00ECnh v\u00E0 blacklist hi\u1EC7n c\u00F3 c\u1EE7a b\u1EA1n.';
    WarnRollingBack='C\u00E0i \u0111\u1EB7t th\u1EA5t b\u1EA1i; \u0111ang kh\u00F4i ph\u1EE5c l\u1EA1i...';
    WarnRollback='C\u1EA3nh b\u00E1o khi kh\u00F4i ph\u1EE5c: {0}';
    DoneUpstreamChanged='\u0110\u00E3 \u0111\u1ED5i upstream dnsproxy sang {0}; gi\u1EEF nguy\u00EAn ph\u1EA7n c\u00F2n l\u1EA1i c\u1EE7a c\u1EA5u h\u00ECnh.';
    WarnDirBlocked='Kh\u00F4ng x\u00F3a h\u1EBFt \u0111\u01B0\u1EE3c th\u01B0 m\u1EE5c (c\u00F3 th\u1EC3 driver \u0111ang b\u1ECB kh\u00F3a); \u0111ang d\u1ECDn c\u00E1c file c\u00F2n l\u1EA1i...';
    WarnDriverKept='Gi\u1EEF driver \u0111ang b\u1ECB kh\u00F3a \u0111\u1EC3 d\u1ECDn khi kh\u1EDFi \u0111\u1ED9ng l\u1EA1i: {0}';
    WarnRebootRequired='C\u1EA7n kh\u1EDFi \u0111\u1ED9ng l\u1EA1i m\u00E1y sau khi c\u00E0i \u0111\u1EC3 n\u1EA1p driver m\u1EDBi.';
    InfoRemovingExisting='\u0110ang g\u1EE1 b\u1EA3n c\u00E0i hi\u1EC7n c\u00F3: {0}';
    InfoRemovingObsolete='\u0110ang x\u00F3a th\u01B0 m\u1EE5c c\u00E0i \u0111\u1EB7t c\u0169: {0}';
    DoneRemoved='\u0110\u00E3 x\u00F3a: {0}';
    InfoVerifyReboot='Sau khi kh\u1EDFi \u0111\u1ED9ng l\u1EA1i, h\u00E3y ki\u1EC3m tra th\u01B0 m\u1EE5c \u0111\u00E3 \u0111\u01B0\u1EE3c x\u00F3a.';
    CdnLoc='V\u1ECB tr\u00ED c\u1EE7a b\u1EA1n: {0}';
    CdnIsp='Nh\u00E0 m\u1EA1ng c\u1EE7a b\u1EA1n: {0}';
    CdnErr='{0} L\u1ED7i / Timeout';
    CdnPingBlocked='{0} (DNS OK, ping b\u1ECB ch\u1EB7n: {1}{2})';
    InfoDnsTarget='DNS \u0111\u00EDch: 127.0.0.1:53';
    InfoTmpV4='DNS t\u1EA1m IPv4: 1.1.1.1, 8.8.8.8';
    InfoTmpV6='DNS t\u1EA1m IPv6: 2606:4700:4700::1111, 2001:4860:4860::8888';
    InfoExtracting='\u0110ang gi\u1EA3i n\u00E9n g\u00F3i \u0111\u00E3 ki\u1EC3m ch\u1EE9ng...';
    InfoExtractingZapret='\u0110ang gi\u1EA3i n\u00E9n g\u00F3i v\u00E0 ch\u1ECDn b\u1EA3n Windows x64...';
    StVerPath='Phi\u00EAn b\u1EA3n: {0}    \u0110\u01B0\u1EDDng d\u1EABn: {1}';
    StLocalV4='DNS n\u1ED9i b\u1ED9 IPv4';
    StGw='C\u1ED5ng DNS';
    MnUpstream='Upstream';
    MnLocalDns='DNS n\u1ED9i b\u1ED9 \u0111ang ho\u1EA1t \u0111\u1ED9ng (127.0.0.1)'; MnOtherDns='DNS h\u1EC7 th\u1ED1ng / DHCP';
    StConfig='T\u1EC7p c\u1EA5u h\u00ECnh';
    SumHint='Qu\u1EA3n l\u00FD sau n\u00E0y b\u1EB1ng Gateway-Manager.bat trong th\u01B0 m\u1EE5c c\u00E0i \u0111\u1EB7t.';
    LbService='D\u1ECBch v\u1EE5';
    LbExecutable='File ch\u1EA1y';
    LbConfig='C\u1EA5u h\u00ECnh';
    LbFile='T\u1EC7p';
    LbPath='\u0110\u01B0\u1EDDng d\u1EABn';
    LbTarget='\u0110\u00EDch';
    LbStaging='Th\u01B0 m\u1EE5c t\u1EA1m';
    LbSource='Ngu\u1ED3n';
    LbDest='\u0110\u00EDch \u0111\u1EBFn';
    LbSize='Dung l\u01B0\u1EE3ng g\u00F3i';
    LbBytes='byte';
    LbRuntime='B\u1EA3n ch\u1EA1y';
    LbAdapter='Card m\u1EA1ng';
    LbApproved='\u0110\u00E3 duy\u1EC7t {0}';
    LbVersions='Phi\u00EAn b\u1EA3n';
    LbAssetDns='G\u00F3i DNSProxy';
    LbAssetZap='G\u00F3i Zapret';
    UpdSkipped='Th\u00E0nh ph\u1EA7n \u0111\u00E3 m\u1EDBi nh\u1EA5t; b\u1ECF qua t\u1EA3i xu\u1ED1ng.';
    WarnObsoleteKept='\u0110ang b\u1ECF qua \u0111\u01B0\u1EDDng d\u1EABn c\u0169 b\u1ECB kh\u00F3a, ti\u1EBFp t\u1EE5c.';
    MutexBusy='M\u1ED9t thao t\u00E1c c\u00E0i \u0111\u1EB7t/c\u1EADp nh\u1EADt kh\u00E1c \u0111ang ch\u1EA1y.';
    WarnAdapterUncovered='Card m\u1EA1ng \u0111ang ho\u1EA1t \u0111\u1ED9ng nh\u01B0ng ch\u01B0a d\u00F9ng DNS n\u1ED9i b\u1ED9: {0}';
    CfgInvalid='C\u1EA5u h\u00ECnh DNSProxy hi\u1EC7n c\u00F3 kh\u00F4ng h\u1EE3p l\u1EC7; \u0111\u00E3 sao l\u01B0u v\u00E0 vi\u1EBFt l\u1EA1i.'
  }
}

# Tables above use \uXXXX escapes to stay pure ASCII: PS 5.1 decodes BOM-less
# scripts with the system codepage, corrupting raw UTF-8. Decoded once at load.
foreach ($table in @($script:Texts['EN'], $script:Texts['VI'])) {
    foreach ($k in @($table.Keys)) {
        $table[$k] = [System.Text.RegularExpressions.Regex]::Unescape($table[$k])
    }
}

$script:InfoVI = @{
    'Stopping existing services...' = '\u0110ang d\u1EEBng c\u00E1c d\u1ECBch v\u1EE5 hi\u1EC7n c\u00F3...';
    'Checking WinDivert...' = '\u0110ang ki\u1EC3m tra WinDivert...';
    'Starting Zapret...' = '\u0110ang kh\u1EDFi \u0111\u1ED9ng Zapret...';
    'Starting DNSProxy...' = '\u0110ang kh\u1EDFi \u0111\u1ED9ng DNSProxy...';
    'Resetting DNS settings to DHCP...' = '\u0110ang \u0111\u1EB7t l\u1EA1i DNS v\u1EC1 DHCP...';
    'Switching to local DNS...' = '\u0110ang chuy\u1EC3n sang DNS n\u1ED9i b\u1ED9...';
    'Checking download connection...' = '\u0110ang ki\u1EC3m tra k\u1EBFt n\u1ED1i t\u1EA3i xu\u1ED1ng...';
    'Applying temporary DNS for downloads...' = '\u0110ang \u0111\u1EB7t DNS t\u1EA1m \u0111\u1EC3 t\u1EA3i xu\u1ED1ng...';
    'Preparing component installation...' = '\u0110ang chu\u1EA9n b\u1ECB c\u00E0i \u0111\u1EB7t th\u00E0nh ph\u1EA7n...';
    'Checking approved component versions...' = '\u0110ang ki\u1EC3m tra phi\u00EAn b\u1EA3n \u0111\u00E3 duy\u1EC7t...';
    'Preparing DNSProxy...' = '\u0110ang chu\u1EA9n b\u1ECB DNSProxy...';
    'Preparing Zapret...' = '\u0110ang chu\u1EA9n b\u1ECB Zapret...';
    'Validating staged components...' = '\u0110ang ki\u1EC3m ch\u1EE9ng c\u00E1c th\u00E0nh ph\u1EA7n \u0111\u00E3 chu\u1EA9n b\u1ECB...';
    'Installing verified components...' = '\u0110ang c\u00E0i \u0111\u1EB7t c\u00E1c th\u00E0nh ph\u1EA7n \u0111\u00E3 ki\u1EC3m ch\u1EE9ng...';
    'Installing DNSProxy configuration...' = '\u0110ang c\u00E0i \u0111\u1EB7t c\u1EA5u h\u00ECnh DNSProxy...';
    'Checking Zapret blacklist...' = '\u0110ang ki\u1EC3m tra blacklist c\u1EE7a Zapret...';
    'Removing existing Windows services...' = '\u0110ang g\u1EE1 c\u00E1c d\u1ECBch v\u1EE5 Windows hi\u1EC7n c\u00F3...';
    'Creating and configuring Windows services...' = '\u0110ang t\u1EA1o v\u00E0 c\u1EA5u h\u00ECnh c\u00E1c d\u1ECBch v\u1EE5 Windows...';
    'Installing local manager scripts...' = '\u0110ang c\u00E0i \u0111\u1EB7t script qu\u1EA3n l\u00FD n\u1ED9i b\u1ED9...';
    'Verifying DNSProxy IPv4 listeners...' = '\u0110ang ki\u1EC3m tra c\u1ED5ng l\u1EAFng nghe IPv4 c\u1EE7a DNSProxy...';
    'Preparing fresh installation...' = '\u0110ang chu\u1EA9n b\u1ECB c\u00E0i \u0111\u1EB7t m\u1EDBi...';
    'Creating installation directory...' = '\u0110ang t\u1EA1o th\u01B0 m\u1EE5c c\u00E0i \u0111\u1EB7t...';
    'Checking DNSProxy configuration...' = '\u0110ang ki\u1EC3m tra c\u1EA5u h\u00ECnh DNSProxy...';
    'Starting configured services...' = '\u0110ang kh\u1EDFi \u0111\u1ED9ng c\u00E1c d\u1ECBch v\u1EE5 \u0111\u00E3 c\u1EA5u h\u00ECnh...';
    'Preparing update...' = '\u0110ang chu\u1EA9n b\u1ECB c\u1EADp nh\u1EADt...';
    'Stopping services before update...' = '\u0110ang d\u1EEBng d\u1ECBch v\u1EE5 tr\u01B0\u1EDBc khi c\u1EADp nh\u1EADt...';
    'Stopping services and restoring DNS...' = '\u0110ang d\u1EEBng d\u1ECBch v\u1EE5 v\u00E0 kh\u00F4i ph\u1EE5c DNS...';
    'Verifying CDN Vietnam Optimization...' = '\u0110ang ki\u1EC3m tra t\u1ED1i \u01B0u CDN Vi\u1EC7t Nam...';
    'Existing services stopped.' = '\u0110\u00E3 d\u1EEBng c\u00E1c d\u1ECBch v\u1EE5 hi\u1EC7n c\u00F3.';
    'Zapret is running.' = 'Zapret \u0111ang ch\u1EA1y.';
    'DNSProxy is running.' = 'DNSProxy \u0111ang ch\u1EA1y.';
    'DNS settings reset to DHCP.' = '\u0110\u00E3 \u0111\u1EB7t l\u1EA1i DNS v\u1EC1 DHCP.';
    'Local DNS 127.0.0.1 enabled.' = '\u0110\u00E3 b\u1EADt DNS n\u1ED9i b\u1ED9 127.0.0.1.';
    'Download connection OK.' = 'K\u1EBFt n\u1ED1i t\u1EA3i xu\u1ED1ng \u1ED5n \u0111\u1ECBnh.';
    'Temporary DNS is ready.' = 'DNS t\u1EA1m \u0111\u00E3 s\u1EB5n s\u00E0ng.';
    'Zapret prepared.' = '\u0110\u00E3 chu\u1EA9n b\u1ECB xong Zapret.';
    'Services prepared.' = '\u0110\u00E3 chu\u1EA9n b\u1ECB xong d\u1ECBch v\u1EE5.';
    'Components validated.' = 'C\u00E1c th\u00E0nh ph\u1EA7n \u0111\u00E3 \u0111\u01B0\u1EE3c ki\u1EC3m ch\u1EE9ng.';
    'Components installed.' = '\u0110\u00E3 c\u00E0i \u0111\u1EB7t xong th\u00E0nh ph\u1EA7n.';
    'DNSProxy configuration installed.' = '\u0110\u00E3 c\u00E0i \u0111\u1EB7t c\u1EA5u h\u00ECnh DNSProxy.';
    'Existing DNSProxy configuration preserved.' = 'Gi\u1EEF nguy\u00EAn c\u1EA5u h\u00ECnh DNSProxy hi\u1EC7n c\u00F3.';
    'zapret blacklist ready.' = 'Blacklist Zapret \u0111\u00E3 s\u1EB5n s\u00E0ng.';
    'Existing Windows services removed.' = '\u0110\u00E3 g\u1EE1 c\u00E1c d\u1ECBch v\u1EE5 Windows hi\u1EC7n c\u00F3.';
    'Windows services configured.' = '\u0110\u00E3 c\u1EA5u h\u00ECnh xong d\u1ECBch v\u1EE5 Windows.';
    'DNSProxy is listening on UDP/TCP 127.0.0.1:53.' = 'DNSProxy \u0111ang l\u1EAFng nghe UDP/TCP 127.0.0.1:53.';
    'Existing installation removed.' = '\u0110\u00E3 g\u1EE1 b\u1EA3n c\u00E0i \u0111\u1EB7t hi\u1EC7n c\u00F3.';
    'Installing DNS watchdog...' = '\u0110ang c\u00E0i \u0111\u1EB7t watchdog DNS...';
    'DNS watchdog installed.' = '\u0110\u00E3 c\u00E0i \u0111\u1EB7t watchdog DNS.';
    'DNS watchdog active.' = 'Watchdog DNS \u0111ang ho\u1EA1t \u0111\u1ED9ng.';
    'Updating local manager...' = '\u0110ang c\u1EADp nh\u1EADt manager n\u1ED9i b\u1ED9...';
    'Local manager updated.' = '\u0110\u00E3 c\u1EADp nh\u1EADt manager n\u1ED9i b\u1ED9.';
    'Securing installation directory...' = '\u0110ang ph\u00E2n quy\u1EC1n th\u01B0 m\u1EE5c c\u00E0i \u0111\u1EB7t...';
    'Installation directory secured.' = '\u0110\u00E3 ph\u00E2n quy\u1EC1n th\u01B0 m\u1EE5c c\u00E0i \u0111\u1EB7t.';
    'Migrating DNSProxy cache setting...' = '\u0110ang chuy\u1EC3n \u0111\u1ED5i c\u00E0i \u0111\u1EB7t cache DNSProxy...';
    'DNSProxy cache setting migrated.' = '\u0110\u00E3 chuy\u1EC3n \u0111\u1ED5i c\u00E0i \u0111\u1EB7t cache DNSProxy.';
    'Local DNS IPv6 ::1: not listening.' = 'DNS n\u1ED9i b\u1ED9 IPv6 ::1: ch\u01B0a l\u1EAFng nghe.';
    'CDN connectivity verification completed.' = '\u0110\u00E3 ki\u1EC3m tra k\u1EBFt n\u1ED1i CDN xong.';
    'Checking Zapret arguments...' = '\u0110ang ki\u1EC3m tra tham s\u1ED1 Zapret...';
    'zapret arguments ready.' = 'Tham s\u1ED1 Zapret \u0111\u00E3 s\u1EB5n s\u00E0ng.';
    'Approved manifest loaded.' = '\u0110\u00E3 t\u1EA3i manifest \u0111\u00E3 duy\u1EC7t.';
}
foreach ($k in @($script:InfoVI.Keys)) {
    $script:InfoVI[$k] = [System.Text.RegularExpressions.Regex]::Unescape($script:InfoVI[$k])
}

function Get-ViInfo([string]$Text) {
    if ($script:Lang -eq 'VI' -and $script:InfoVI.ContainsKey($Text)) { return $script:InfoVI[$Text] }
    return $Text
}

function T([string]$Key) {
    $lang = if ($script:Lang -eq 'VI') { 'VI' } else { 'EN' }
    if ($script:Texts[$lang].ContainsKey($Key)) { return $script:Texts[$lang][$Key] }
    if ($script:Texts['EN'].ContainsKey($Key)) { return $script:Texts['EN'][$Key] }
    return $Key
}

function Get-SavedLang {
    try {
        $v = ((Get-Content -LiteralPath $script:LangFile -Raw -ErrorAction Stop).Trim().ToUpperInvariant())
        if ($v -in @('EN','VI')) { return $v }
    } catch { Write-Warning ('SEDG:Get-SavedLang: $v = ((Get-Content -LiteralPath $script:LangFile -Raw -Error... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    return 'EN'
}

function Save-Lang([string]$Lang) {
    New-Item -ItemType Directory -Path $script:LangDir -Force | Out-Null
    $Lang | Set-Content -LiteralPath $script:LangFile -Encoding ASCII -NoNewline
}

$script:Lang = Get-SavedLang
if ($Language.ToUpperInvariant() -in @('EN','VI')) {
    $script:Lang = $Language.ToUpperInvariant()
    try { Save-Lang $script:Lang } catch { Write-Warning ('SEDG:script: Save-Lang $script:Lang (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Write-Step([string]$Text) {
    Write-Host (("  " + ([string][char]0x25BA) + " " + (Get-ViInfo $Text))) -ForegroundColor Cyan
}

function Write-Done([string]$Text) {
    Write-Host (("  " + ([string][char]0x2714) + " " + (Get-ViInfo $Text))) -ForegroundColor Green
}

function Write-CreditBanner {
    # Frame only - the credited lines below must stay unchanged.
    $tl = [string][char]0x2554; $tr = [string][char]0x2557; $bl = [string][char]0x255A; $br = [string][char]0x255D
    $hz = [string][char]0x2550; $vt = [string][char]0x2551
    $width = 70
    $innerWidth = $width - 2
    $lines = @(
        'THANKS TO BIBICADOTNET',
        '',
        'Thanks for the original automatic installation script.'
    )

    Write-Host ''
    Write-Host ($tl + ($hz * $innerWidth) + $tr) -ForegroundColor Yellow
    foreach ($line in $lines) {
        $padding = $innerWidth - $line.Length
        $left = [math]::Floor($padding / 2)
        $right = $padding - $left
        $fg = if ($line -eq 'THANKS TO BIBICADOTNET') { 'Yellow' } else { 'DarkYellow' }
        Write-Host ($vt + (' ' * $left) + $line + (' ' * $right) + $vt) -ForegroundColor $fg
    }
    Write-Host ($bl + ($hz * $innerWidth) + $br) -ForegroundColor Yellow
    Write-Host ''
}

function Write-BoxTop([int]$Width = 70) {
    Write-Host ([string][char]0x2554 + (([string][char]0x2550) * ($Width - 2)) + ([string][char]0x2557)) -ForegroundColor Cyan
}

function Write-BoxBottom([int]$Width = 70) {
    Write-Host ([string][char]0x255A + (([string][char]0x2550) * ($Width - 2)) + ([string][char]0x255D)) -ForegroundColor Cyan
}

function Write-BoxLine([string]$Text, [int]$Width = 70, [string]$Color = 'Cyan') {
    $inner = $Width - 2
    $t = [string]$Text
    if ($t.Length -gt $inner) { $t = $t.Substring(0, $inner - 3) + '...' }
    Write-Host ([string][char]0x2551 + $t.PadRight($inner) + ([string][char]0x2551)) -ForegroundColor $Color
}

function Write-BoxSeparator([int]$Width = 70) {
    Write-Host ([string][char]0x2560 + (([string][char]0x2550) * ($Width - 2)) + ([string][char]0x2563)) -ForegroundColor Cyan
}

function Write-Title([string]$Text) {
    Write-Host ""
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("  " + (([string][char]0x2500) * [Math]::Min(60, [Math]::Max(20, $Text.Length)))) -ForegroundColor DarkGray
}

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host ("  " + ([string][char]0x25B8) + " " + $Text) -ForegroundColor Cyan
}

function Write-StatusLine([bool]$Ok, [string]$Label, [string]$Value) {
    $mark = if ($Ok) { '[OK]' } else { '[--]' }
    $color = if ($Ok) { 'Green' } else { 'DarkGray' }
    Write-Host ("  {0,-5} {1,-24}: {2}" -f $mark, $Label, $Value) -ForegroundColor $color
}

function Ensure-Administrator {
    if (Test-Administrator) { return }
    # M5/iex: materialize the running script so elevation never executes stale code.
    if (-not (Test-Path -LiteralPath $script:SelfPath -PathType Leaf)) {
        if (-not [string]::IsNullOrWhiteSpace($script:SelfContent) -and ($script:SelfContent -match 'InstallerVersion')) {
            try { [IO.File]::WriteAllText($script:SelfPath, $script:SelfContent, [Text.UTF8Encoding]::new($false)) } catch { Write-Warning ('SEDG:Ensure-Administrator: [IO.File]::WriteAllText($script:SelfPath, $script:SelfConten... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        }
    }
    if (-not (Test-Path -LiteralPath $script:SelfPath -PathType Leaf)) {
        throw 'Administrator rights are required. Open PowerShell as Administrator and run the install command again.'
    }
    # PS 5.1 Start-Process does not quote ArgumentList elements, so quote
    # paths here (TEMP under usernames with spaces would break elevation).
    $elevArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:SelfPath + '"'), '-Action', $Action)
    if (-not [string]::IsNullOrWhiteSpace($Upstream)) {
        # Strip quotes (never valid in a URL) so the value cannot break out
        # of its quoted argument; downstream validation still rejects bad input.
        $elevArgs += @('-Upstream', ('"' + (([string]$Upstream) -replace '"', '') + '"'))
    }
    if ($IncludeCdnTest) { $elevArgs += '-IncludeCdnTest' }
    if ($ForceUpdate) { $elevArgs += '-ForceUpdate' }
    if ($Clean) { $elevArgs += '-Clean' }
    if ($DnsOnly) { $elevArgs += '-DnsOnly' }
    if ($Purge) { $elevArgs += '-Purge' }
    if ($FailClosed) { $elevArgs += '-FailClosed' }
    if ($AllowDowngrade) { $elevArgs += '-AllowDowngrade' }
    if ($AllowSeam) { $elevArgs += '-AllowSeam' }
    if ($script:Lang -in @('EN','VI')) { $elevArgs += @('-Language', $script:Lang) }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $elevArgs
    Exit-Installer 0
    # Fall through for iex hosts where exit is suppressed; stop further work.
    throw 'Elevation launched. Continue in the elevated window.'
}

function Clear-StaleTempInstallers {
    try {
        Get-ChildItem -LiteralPath $env:TEMP -Filter 'serverless-edge-dns-gateway-installer-*.ps1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $script:SelfPath -and $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Write-Warning ('SEDG:Clear-StaleTempInstallers: Get-ChildItem -LiteralPath $env:TEMP -Filter ''serverless-edg... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

$script:InstallerMutex = $null
$script:MutexDepth = 0
$script:OpTranscript = $null

function Enter-InstallerMutex {
    # Prevent parallel Install/Update/Uninstall runs in any process.
    # Same-thread recursion (Update -> Install) only bumps the depth.
    if ($script:MutexDepth -gt 0) { $script:MutexDepth++; return }
    $mutex = New-Object System.Threading.Mutex($false, 'Global\SEDG-Installer')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        try { $mutex.Dispose() } catch { Write-Warning ('SEDG:Enter-InstallerMutex: $mutex.Dispose() (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        throw (T 'MutexBusy')
    }
    $script:InstallerMutex = $mutex
    $script:MutexDepth = 1
}

function Exit-InstallerMutex {
    if ($script:MutexDepth -gt 1) { $script:MutexDepth--; return }
    try {
        if ($script:InstallerMutex) {
            $script:InstallerMutex.ReleaseMutex()
            $script:InstallerMutex.Dispose()
        }
    } catch { Write-Warning ('SEDG:Exit-InstallerMutex: if ($script:InstallerMutex) { $script:InstallerMutex.Release... (' + $_.Exception.Message + ')'); Write-Verbose $_ } finally {
        $script:InstallerMutex = $null
        $script:MutexDepth = 0
    }
}

function Start-OpTranscript([string]$ForAction) {
    # Best-effort transcript into the admin-only ProgramData dir (survives
    # install wipes). Never throws; logging must not block the operation.
    if ($Protocol -eq 'jsonl') { return }
    if ($script:OpTranscript) { return }
    try {
        $logDir = Join-Path $script:DnsBackupDir 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        try {
            Get-ChildItem -LiteralPath $logDir -Filter 'transcript-*.txt' -File -ErrorAction Stop |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip 10 |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { Write-Warning ('SEDG:Start-OpTranscript: Get-ChildItem -LiteralPath $logDir -Filter ''transcript-*.txt... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $script:OpTranscript = Join-Path $logDir ("transcript-" + $ForAction + "-" + $stamp + ".txt")
        Start-Transcript -LiteralPath $script:OpTranscript -ErrorAction Stop | Out-Null
    } catch { $script:OpTranscript = $null }
}

function Stop-OpTranscript {
    if (-not $script:OpTranscript) { return }
    $script:OpTranscript = $null
    try { Stop-Transcript -ErrorAction Stop | Out-Null } catch { Write-Warning ('SEDG:Stop-OpTranscript: Stop-Transcript -ErrorAction Stop | Out-Null (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Test-Platform {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This installer requires 64-bit Windows.'
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        throw 'This installer supports x64 Windows only. WinDivert has no ARM64 driver, so Zapret cannot run on ARM64 Windows.'
    }
    # README requires Windows 10 1803+ (build 17134).
    try {
        $build = [System.Environment]::OSVersion.Version.Build
        if ($build -lt 17134) { throw ("Windows build {0} is below the minimum 17134 (1803)." -f $build) }
    } catch {
        if ($_.Exception.Message -match 'minimum 17134') { throw }
    }
}

$script:AllowedReleaseRepos = @('AdguardTeam/dnsproxy', 'bol-van/zapret', 'projectofwang/sedg-suite')

function Get-ManifestProperty($ManifestObject, [string]$Name) {
    if ($null -eq $ManifestObject) { return $null }
    $property = $ManifestObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ManifestString($ManifestObject, [string]$Name) {
    return [string](Get-ManifestProperty $ManifestObject $Name)
}

function Assert-ManifestComponents($Manifest) {
    $components = Get-ManifestProperty $Manifest 'components'
    if ($null -eq $components) { throw 'Approved manifest is missing required components.' }
    $requiredFields = @{
        dnsproxy = @('repository', 'tag', 'asset', 'sha256')
        zapret = @('repository', 'tag', 'asset', 'sha256')
        manager = @('repository', 'tag', 'asset', 'sha256')
        nssm = @('version', 'asset', 'url', 'sha256')
    }
    foreach ($componentName in @('dnsproxy', 'zapret', 'manager', 'nssm')) {
        $component = Get-ManifestProperty $components $componentName
        if ($null -eq $component) { throw "Approved manifest is missing required component: $componentName." }
        foreach ($fieldName in $requiredFields[$componentName]) {
            if ([string]::IsNullOrWhiteSpace((Get-ManifestString $component $fieldName))) {
                throw "Approved manifest component '$componentName' is missing required field '$fieldName'."
            }
        }
    }
    # M12: primary NSSM URL must be https (loopback http allowed for the CI
    # fixture server, see Test-DownloadUrl); mirror (if present) likewise.
    $nssm = Get-ManifestProperty $components 'nssm'
    $url = Get-ManifestString $nssm 'url'
    if (-not (Test-DownloadUrl $url)) { throw "Approved manifest nssm.url must be https." }
    $mirror = Get-ManifestString $nssm 'mirror'
    if ((-not [string]::IsNullOrWhiteSpace($mirror)) -and (-not (Test-DownloadUrl $mirror))) {
        throw "Approved manifest nssm.mirror must be https."
    }
}

function Test-DownloadUrl([string]$Url) {
    # https is always allowed. Plain http is allowed only for loopback hosts
    # (the CI fixture server); loopback is local-machine only, so this never
    # widens the attack surface for a user download path.
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($Url -match '^https://') { return $true }
    return ($Url -match '^http://(localhost|127\.0\.0\.1|\[::1\])(/|:|$)')
}

function Get-AssetDownloadBase {
    param([switch]$AllowSeam)
    # Test/packaging seam: SEDG_ASSET_BASE_URL redirects component downloads
    # to an alternative origin (a CI fixture server). Unset in production:
    # downloads stay pinned to https://github.com. Repository/tag/asset
    # allow-listing and per-file SHA-256 pinning still apply regardless of
    # the origin, so the seam only changes where bytes come from, not which
    # bytes are accepted. Ignored when elevated unless -AllowSeam is passed.
    $base = [string]$env:SEDG_ASSET_BASE_URL
    if ([string]::IsNullOrWhiteSpace($base)) { return 'https://github.com' }
    if ($AllowSeam -or (-not (Test-Administrator))) {
        Write-Warning 'SEDG_ASSET_BASE_URL test seam is active; downloads leave the pinned origin.'
        return $base.TrimEnd('/')
    }
    # F2: locked when elevated unless -AllowSeam; warn when ignored.
    if (-not [string]::IsNullOrWhiteSpace($base)) { Write-Warning 'SEDG_ASSET_BASE_URL is set but ignored; test seams require -AllowSeam when elevated.' }
    return 'https://github.com'
}

function Get-ReleaseAssetUrl([string]$Repository, [string]$Tag, [string]$Asset, [switch]$AllowSeam) {
    # Direct release download: no unauthenticated GitHub API calls, so no
    # 60 req/hour rate-limit failures behind shared IPs (CGNAT).
    if ($script:AllowedReleaseRepos -notcontains $Repository) {
        throw "Release repository is not allow-listed: $Repository"
    }
    if ([string]::IsNullOrWhiteSpace($Tag) -or ($Tag -notmatch '^(v)?\d+(\.\d+)*$')) {
        throw "Invalid release tag: $Tag"
    }
    if ([string]::IsNullOrWhiteSpace($Asset) -or ($Asset -notmatch '^[\w][\w.\-]*$')) {
        throw "Invalid release asset name: $Asset"
    }
    return "{0}/{1}/releases/download/{2}/{3}" -f (Get-AssetDownloadBase -AllowSeam:$AllowSeam), $Repository, $Tag, $Asset
}

function Get-ApprovedManifest {
    param([switch]$AllowDowngrade)
    try { if (-not $AllowDowngrade -and $script:AllowDowngrade) { $AllowDowngrade = $true } } catch { }
    if ($script:ManifestCache) { return $script:ManifestCache }
    $embedded = [pscustomobject]@{
        schema = 1
        policy = 'approved-only'
        installer = [pscustomobject]@{ version = $script:InstallerVersion }
        components = [pscustomobject]@{
            dnsproxy = [pscustomobject]@{
                repository = 'AdguardTeam/dnsproxy'
                tag = 'v0.86.0'
                asset = 'dnsproxy-windows-amd64-v0.86.0.zip'
                sha256 = 'dedc186ddd4b96bf92474f91d972f67da0824e0141d09e3102fd96db9f8a0dbc'
            }
            zapret = [pscustomobject]@{
                repository = 'bol-van/zapret'
                tag = 'v72.13'
                asset = 'zapret-v72.13.zip'
                sha256 = 'c493e33a0dc4eba23a8686efdaba55f59755ad6ade3564aebd9d13f4c65e2e0c'
            }
            manager = [pscustomobject]@{
                repository = 'projectofwang/sedg-suite'
                tag = '2.0.0'
                asset = 'sedg-manager-win-x64-2.0.0.zip'
                sha256 = '0dfef898b47e2f26f8b65ade4e5ffeac270a10b65bbc41f793ae3f95d9f5ee8d'
            }
            nssm = [pscustomobject]@{
                version = $script:NssmVersion
                asset = 'nssm-2.24.zip'
                url = $script:Sources.NssmZip
                sha256 = $script:NssmSha256
            }
        }
    }

    $m = $null
    $fromRemote = $false
    $remoteUri = ''
    $fetchErrors = @()
    foreach ($uri in @($script:Sources.Manifest, $script:Sources.ManifestFallback)) {
        if ([string]::IsNullOrWhiteSpace($uri)) { continue }
        try {
            $response = Invoke-WebRequest -Uri $uri -Headers @{ 'User-Agent' = 'Serverless-Edge-DNS-Gateway-Installer' } -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $m = $response.Content | ConvertFrom-Json
            $fromRemote = $true
            $remoteUri = [string]$uri
            break
        } catch {
            $fetchErrors += ('{0}: {1}' -f $uri, $_.Exception.Message)
        }
    }
    # TOFU same-origin cross-check: when the primary (dl.*) answered, fetch
    # the GitHub fallback out-of-band and compare the pinned subset. A
    # mismatch means one origin is serving a forged manifest.
    # shortcut: TOFU, upgrade to signed manifest when key infra exists
    if ($fromRemote -and ($remoteUri -eq [string]$script:Sources.Manifest) -and (-not [string]::IsNullOrWhiteSpace([string]$script:Sources.ManifestFallback))) {
        try {
            $xb = (Invoke-WebRequest -Uri ([string]$script:Sources.ManifestFallback) -Headers @{ 'User-Agent' = 'Serverless-Edge-DNS-Gateway-Installer' } -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content | ConvertFrom-Json
            $mc = Get-ManifestProperty $m 'components'
            $xc = Get-ManifestProperty $xb 'components'
            $mn = Get-ManifestProperty $mc 'nssm'
            $xn = Get-ManifestProperty $xc 'nssm'
            $mm = Get-ManifestProperty $mc 'manager'
            $xm = Get-ManifestProperty $xc 'manager'
            foreach ($field in @(@{ P = 'installer.version'; A = $m.installer.version; B = $xb.installer.version },
                    @{ P = 'dnsproxy'; A = ($m.components.dnsproxy.tag, $m.components.dnsproxy.sha256 -join '|'); B = ($xb.components.dnsproxy.tag, $xb.components.dnsproxy.sha256 -join '|') },
                    @{ P = 'zapret'; A = ($m.components.zapret.tag, $m.components.zapret.sha256 -join '|'); B = ($xb.components.zapret.tag, $xb.components.zapret.sha256 -join '|') },
                    @{ P = 'manager'; A = ((Get-ManifestString $mm 'repository'), (Get-ManifestString $mm 'tag'), (Get-ManifestString $mm 'asset'), (Get-ManifestString $mm 'sha256') -join '|'); B = ((Get-ManifestString $xm 'repository'), (Get-ManifestString $xm 'tag'), (Get-ManifestString $xm 'asset'), (Get-ManifestString $xm 'sha256') -join '|') },
                    @{ P = 'nssm'; A = ((Get-ManifestString $mn 'url'), (Get-ManifestString $mn 'sha256') -join '|'); B = ((Get-ManifestString $xn 'url'), (Get-ManifestString $xn 'sha256') -join '|') })) {
                if ([string]$field.A -ne [string]$field.B) {
                    throw ("Manifest cross-check mismatch on {0}: primary {1} vs GitHub fallback. Refusing to continue." -f $field.P, $remoteUri)
                }
            }
        } catch {
            if ($_.Exception.Message -match 'cross-check mismatch') { throw }
            try {
                # Fallback unreachable: compare the pinned subset against the
                # in-memory embedded manifest instead of failing open.
                $memA = @((Get-ManifestString (Get-ManifestProperty $m 'installer') 'version'))
                $memB = @((Get-ManifestString (Get-ManifestProperty $embedded 'installer') 'version'))
                foreach ($cn in @('dnsproxy', 'zapret')) {
                    $ca = Get-ManifestProperty (Get-ManifestProperty $m 'components') $cn
                    $cb = Get-ManifestProperty (Get-ManifestProperty $embedded 'components') $cn
                    $memA += ((Get-ManifestString $ca 'tag'), (Get-ManifestString $ca 'sha256') -join '|')
                    $memB += ((Get-ManifestString $cb 'tag'), (Get-ManifestString $cb 'sha256') -join '|')
                }
                $ma = Get-ManifestProperty (Get-ManifestProperty $m 'components') 'manager'
                $em = Get-ManifestProperty (Get-ManifestProperty $embedded 'components') 'manager'
                $memA += ((Get-ManifestString $ma 'repository'), (Get-ManifestString $ma 'tag'), (Get-ManifestString $ma 'asset'), (Get-ManifestString $ma 'sha256') -join '|')
                $memB += ((Get-ManifestString $em 'repository'), (Get-ManifestString $em 'tag'), (Get-ManifestString $em 'asset'), (Get-ManifestString $em 'sha256') -join '|')
                $na = Get-ManifestProperty (Get-ManifestProperty $m 'components') 'nssm'
                $nb = Get-ManifestProperty (Get-ManifestProperty $embedded 'components') 'nssm'
                $memA += ((Get-ManifestString $na 'url'), (Get-ManifestString $na 'sha256') -join '|')
                $memB += ((Get-ManifestString $nb 'url'), (Get-ManifestString $nb 'sha256') -join '|')
                if (($memA -join "`n") -ne ($memB -join "`n")) { throw 'Manifest pinned subset mismatch with embedded manifest while fallback is unreachable. Refusing to continue.' }
            } catch {
                if ($_.Exception.Message -match 'pinned subset mismatch') { throw }
            }
            Write-Warning ("Manifest cross-check skipped (fallback unreachable): {0}" -f $_.Exception.Message)
        }
    }
    if (-not $m) {
        # Offline fallback: last-known-good manifest embedded in the installer.
        # Keep it in sync with approved-releases.json when updating components.
        $m = $embedded
        Write-Host (('  ' + (T 'WarnManifestFallback'))) -ForegroundColor Yellow
        foreach ($reason in $fetchErrors) {
            Write-Host (('  ' + $reason)) -ForegroundColor DarkGray
        }
    }

    if ($null -eq $m) {
        throw 'Approved manifest is empty.'
    }

    # R1/Opt-C (warn-only): the manifest host is trusted, so a compromised
    # host can replay an older but valid manifest (downgrade). Warn when the
    # remote trails the embedded or last-run baseline; validation below keeps
    # its hard-throw policy and legitimate flows are unchanged.
    if ($fromRemote) {
        try {
            $remoteVer = [string]$m.installer.version
            $baselines = @([string]$embedded.installer.version)
            try { if (Test-Path -LiteralPath $script:StateFile -PathType Leaf) { $baselines += [string](Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json).InstallerVersion } } catch { Write-Verbose $_ }
            foreach ($base in $baselines) {
                try {
                    if ((-not [string]::IsNullOrWhiteSpace($remoteVer)) -and (-not [string]::IsNullOrWhiteSpace($base)) -and (([System.Version]$remoteVer) -lt ([System.Version]$base))) {
                        $msg = "Remote manifest declares installer version $remoteVer, older than baseline $base."
                        if ($AllowDowngrade) {
                            Write-Warning ($msg + ' Continuing with the remote manifest (downgrade allowed, confirm this was intended).')
                            break
                        }
                        throw ($msg + ' Pass -AllowDowngrade only if this downgrade was intended.')
                    }
                } catch {
                    if ($_.Exception.Message -match 'Pass -AllowDowngrade') { throw }
                    Write-Verbose $_
                }
            }
        } catch {
            if ($_.Exception.Message -match 'Pass -AllowDowngrade') { throw }
            Write-Verbose $_
        }
    }

    if ($m.schema -eq 1 -and $m.policy -eq 'approved-only') {
        if ([string]$m.installer.version -ne $script:InstallerVersion) {
            throw ("Installer version mismatch: installer.ps1 is {0}, approved-releases.json declares {1}." -f $script:InstallerVersion, $m.installer.version)
        }
        Write-Done 'Approved manifest loaded.'
        $script:ManifestCache = $m
        return $m
    }

    throw ("Approved manifest has unexpected schema/policy (schema={0}, policy={1}). Refusing to fall back silently." -f $m.schema, $m.policy)
}

function Verify-Sha256([string]$File,[string]$Expected,[string]$Label){
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "SHA-256 verification target does not exist: $File"
    }

    $expectedNormalized = ([string]$Expected).Trim().ToLowerInvariant()
    if ($expectedNormalized.Length -ne 64 -or $expectedNormalized -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid expected SHA-256 for $Label. Expected value must contain exactly 64 hexadecimal characters."
    }

    $size = (Get-Item -LiteralPath $File -ErrorAction Stop).Length

    # Stream the file so large archives do not load fully into memory.
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($File)
        try {
            $digest = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
        $actual = ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }

    if ($actual.Length -ne 64 -or $actual -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid SHA-256 result for $Label. Computed digest has length $($actual.Length), expected 64."
    }

    if ($actual -ne $expectedNormalized) {
        throw "SHA-256 mismatch for $Label. File: $File ; Size: $size bytes ; Expected: $expectedNormalized ; Actual: $actual ; ActualLength: $($actual.Length)"
    }

    Write-Done (((T 'DoneVerified') -f $Label))
    return $actual
}
function Download-File([string]$Url, [string]$Destination) {
    # M12: every download URL must be https; curl enforces it, IWR branch too.
    # Test seam: plain http is accepted only for loopback hosts (the CI
    # fixture server) via Test-DownloadUrl.
    $isLoopbackHttp = (-not ($Url -match '^https://'))
    if ([string]::IsNullOrWhiteSpace($Url) -or (-not (Test-DownloadUrl $Url))) {
        throw "Refusing non-https download URL: $Url"
    }
    # GitHub release downloads can occasionally reset a PowerShell HTTP connection.
    # Prefer curl.exe on Windows, with retries, then fall back to PowerShell.
    $curl = Join-Path (Join-Path $env:SystemRoot 'System32') 'curl.exe'
    $lastError = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        try {
            if (Test-Path $curl) {
                $proto = '=https'
                $extra = @()
                if ($isLoopbackHttp) { $proto = '=https,http'; $extra = @('--noproxy', '*') }
                & $curl --fail --location --proto $proto --proto-redir $proto @extra --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 600 --output $Destination $Url
                if ($LASTEXITCODE -eq 0 -and (Test-Path $Destination)) {
                    return
                }
                throw "curl.exe exited with code $LASTEXITCODE"
            }

            try {
                [Net.ServicePointManager]::SecurityProtocol = ([Net.SecurityProtocolType]::Tls12 -bor 12288)
            } catch {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = 'Serverless-Edge-DNS-Gateway-Installer' } -TimeoutSec 600
            if (Test-Path $Destination) {
                return
            }
            throw 'PowerShell download produced no output file.'
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt 3) {
                Write-Host (('  ' + ((T 'WarnRetrying') -f $attempt))) -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }

    throw (("Download failed after 3 attempts: {0}{1}{2}" -f $Url, [Environment]::NewLine, $lastError))
}

function Expand-Zip([string]$ZipFile, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $ZipFile -DestinationPath $Destination -Force
    # F11: ZipSlip guard (hash pinning stays the real gate). Every expanded
    # entry must resolve under $Destination; absolute paths and `..`
    # escapes abort instead of writing outside the staging dir.
    # NOTE: base comes from Get-Item (same provider form as the entries
    # below); Resolve-Path can return 8.3 short names and break the compare.
    $destFull = (Get-Item -LiteralPath $Destination).FullName
    $prefix = $destFull.TrimEnd('\') + '\'
    foreach ($entry in @(Get-ChildItem -LiteralPath $Destination -Recurse -Force -ErrorAction Stop)) {
        $p = $entry.FullName
        if (($p -ne $destFull) -and (-not $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
            throw ("Archive entry escaped the destination directory: {0}" -f $entry.Name)
        }
    }
}

function Find-File([string]$Root, [string]$Name) {
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Get-NetworkAdapters([switch]$IncludeVirtual) {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' })
    if (-not $IncludeVirtual) {
        # Physical adapters only by default; virtual/VPN keep their own DNS
        # unless the caller explicitly opts in.
        $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' } |
            Select-Object -ExpandProperty ifIndex)
        if ($physical.Count -gt 0) {
            $adapters = @($adapters | Where-Object { $physical -contains $_.ifIndex })
        }
    }
    return @($adapters)
}

function Stop-AllServices {
    Write-Step 'Stopping existing services...'
    Log-Port53Owner
    foreach ($name in @($script:DnsProxyService, $script:WinwsService)) {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
    }
    @(Get-OurProcesses) | ForEach-Object {
        $_ | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # WinDivert can keep its kernel driver loaded briefly after winws exits.
    # Wait for services and user-mode processes to stop before replacing WinDivert64.sys.
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $runningServices = @($script:DnsProxyService, $script:WinwsService) |
            ForEach-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } |
            Where-Object { $_.Status -ne 'Stopped' }
        $runningProcesses = @(Get-OurProcesses)
        if (@($runningServices).Count -eq 0 -and @($runningProcesses).Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if (@($runningProcesses).Count -gt 0) {
        $runningProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    if (@($runningServices).Count -gt 0) {
        throw 'Timed out waiting for DNSProxy/Zapret services to stop.'
    }
    Write-Done 'Existing services stopped.'
}

function Get-WinDivertImagePath {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDivert'
    if (-not (Test-Path $key)) { return $null }
    try {
        return (Get-ItemProperty -LiteralPath $key -Name ImagePath -ErrorAction Stop).ImagePath
    } catch {
        return $null
    }
}

function Normalize-WinDivertPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $path = $Value.Trim()
    # Windows kernel-driver ImagePath commonly uses the NT prefix \??\C:\... .
    # Normalize both \??\ and \\?\ prefixes before comparing ownership.
    $path = $path -replace '^\\\?\?\\', ''
    $path = $path -replace '^\\\?\\', ''
    $path = $path.Trim('"')
    try {
        return [System.IO.Path]::GetFullPath($path)
    } catch {
        return $path
    }
}

function Remove-OwnWinDivertDriver([switch]$ScheduleIfLocked) {
    Write-Step 'Checking WinDivert...'
    $servicePath = Normalize-WinDivertPath (Get-WinDivertImagePath)
    if (-not $servicePath) { return }

    $ourDriver = [System.IO.Path]::GetFullPath((Join-Path $script:ZapretPath 'WinDivert64.sys'))
    if (-not [string]::Equals($servicePath, $ourDriver, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("A WinDivert service already exists for another path: {0}. " +
            "It was not modified because another application may depend on it. " +
            "Stop/remove that conflicting WinDivert installation first.") -f $servicePath
    }

    Write-Host (('  ' + (T 'InfoRemovingWinDivert'))) -ForegroundColor DarkGray
    & sc.exe stop WinDivert 2>$null | Out-Null
    & sc.exe delete WinDivert 2>$null | Out-Null

    $deadline = (Get-Date).AddSeconds(5)
    do {
        $imagePath = Get-WinDivertImagePath
        if (-not $imagePath) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if (Get-WinDivertImagePath) {
        if ($ScheduleIfLocked) {
            Schedule-DeleteOnReboot $ourDriver
            Write-Host (('  ' + (T 'WarnWinDivertScheduled'))) -ForegroundColor Yellow
            return
        }
        throw 'WinDivert service could not be removed. Reboot Windows, then retry the operation.'
    }

    # The service can be gone while the driver file is still held open briefly.
    if (Test-Path $ourDriver) {
        try {
            Remove-Item -LiteralPath $ourDriver -Force -ErrorAction Stop
        } catch {
            if ($ScheduleIfLocked) {
                Schedule-DeleteOnReboot $ourDriver
                Write-Host (('  ' + (T 'WarnDriverLocked'))) -ForegroundColor Yellow
            } else {
                throw 'WinDivert64.sys is still locked after the driver service was removed. Reboot Windows, then retry the operation.'
            }
        }
    }
}

function Schedule-DeleteOnReboot([string]$Path) {
    if (-not (Test-Path $Path)) { return }

    if (-not ('DnsDohInstaller.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace DnsDohInstaller {    public static class NativeMethods {        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]        public static extern bool MoveFileEx(
            string lpExistingFileName,            string lpNewFileName,
            uint dwFlags);
    }
}
'@
    }

    $MOVEFILE_DELAY_UNTIL_REBOOT = 0x00000004
    if (-not [DnsDohInstaller.NativeMethods]::MoveFileEx($Path, $null, $MOVEFILE_DELAY_UNTIL_REBOOT)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not schedule locked file for deletion at reboot. Win32 error: $code"
    }
}

function Schedule-DeleteTreeOnReboot([string]$Path) {
    # MoveFileEx deletes files only: schedule children before parents
    # (deepest first) so a whole install tree is gone after reboot.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $entries = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
        $ordered = @($entries | Where-Object { -not $_.PSIsContainer }) +
            @($entries | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($entry in @($ordered)) {
            try { Schedule-DeleteOnReboot $entry.FullName } catch { Write-Warning ('SEDG:Schedule-DeleteTreeOnReboot: Schedule-DeleteOnReboot $entry.FullName (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        }
    } catch { Write-Warning ('SEDG:Schedule-DeleteTreeOnReboot: $entries = @(Get-ChildItem -LiteralPath $Path -Recurse -Forc... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try { Schedule-DeleteOnReboot $Path } catch { Write-Warning ('SEDG:Schedule-DeleteTreeOnReboot: Schedule-DeleteOnReboot $Path (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Test-PendingRebootDelete([string]$Path) {
    # F4: a previous Uninstall may have scheduled the install tree for
    # reboot deletion via MoveFileEx. Installing now would be wiped by
    # that reboot, so detect it and abort instead.
    try {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        foreach ($op in @($key.PendingFileRenameOperations)) {
            if (([string]$op).IndexOf([string]$Path, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    } catch { Write-Verbose $_ }
    return $false
}

function Start-AllServices {
    param([switch]$DnsOnly)
    # Low: rotate runaway dnsproxy --output log (no built-in rotation).
    try {
        $dnsLog = Join-Path $script:DnsProxyPath 'dnsproxy.log'
        if ((Test-Path -LiteralPath $dnsLog) -and ((Get-Item -LiteralPath $dnsLog).Length -gt 20MB)) {
            Remove-Item -LiteralPath ($dnsLog + '.old') -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $dnsLog -NewName 'dnsproxy.log.old' -ErrorAction SilentlyContinue
        }
    } catch { Write-Warning ('SEDG:Start-AllServices: $dnsLog = Join-Path $script:DnsProxyPath ''dnsproxy.log'' if (... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    if ($DnsOnly) {
        Write-Host '  DnsOnly mode: skipping winws-service.' -ForegroundColor Yellow
        try { Stop-Service -Name $script:WinwsService -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Start-AllServices: Stop-Service -Name $script:WinwsService -Force -ErrorAction ... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    } else {
    Write-Step 'Starting Zapret...'
    Write-Host (('  ' + (T 'LbService') + ': ' + $script:WinwsService)) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'LbExecutable') + ': ' + (Join-Path $script:ZapretPath 'winws.exe'))) -ForegroundColor DarkGray
    try {
        Start-Service -Name $script:WinwsService -ErrorAction Stop
    } catch {
        $nssmStatus = ''
        try { $nssmStatus = (& $script:NssmPath status $script:WinwsService 2>&1 | Out-String).Trim() } catch { Write-Warning ('SEDG:Start-AllServices: $nssmStatus = (& $script:NssmPath status $script:WinwsServic... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $log = Join-Path $script:ZapretPath 'winws.log'
        $logText = if (Test-Path $log) { (Get-Content -LiteralPath $log -Tail 40 -ErrorAction SilentlyContinue) -join [Environment]::NewLine } else { '' }
        throw ("Failed to start {0}. NSSM: {1}{2}winws.log:{3}" -f $script:WinwsService, $nssmStatus, [Environment]::NewLine, $logText)
    }

    Start-Sleep -Seconds 2

    $winws = Get-Service -Name $script:WinwsService -ErrorAction Stop
    if ($winws.Status -ne 'Running') {
        $nssmStatus = ''
        try { $nssmStatus = (& $script:NssmPath status $script:WinwsService 2>&1 | Out-String).Trim() } catch { Write-Warning ('SEDG:Start-AllServices: $nssmStatus = (& $script:NssmPath status $script:WinwsServic... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $log = Join-Path $script:ZapretPath 'winws.log'
        $logText = if (Test-Path $log) { (Get-Content -LiteralPath $log -Tail 40 -ErrorAction SilentlyContinue) -join [Environment]::NewLine } else { '' }
        throw ("Service did not remain running: {0} ({1}). NSSM: {2}{3}winws.log:{4}" -f $script:WinwsService, $winws.Status, $nssmStatus, [Environment]::NewLine, $logText)
    }

    Write-Done 'Zapret is running.'
    Write-Step 'Starting DNSProxy...'
    Write-Host (('  ' + (T 'LbService') + ': ' + $script:DnsProxyService)) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'LbExecutable') + ': ' + (Join-Path $script:DnsProxyPath 'dnsproxy.exe'))) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'LbConfig') + ': ' + $script:ConfigFile)) -ForegroundColor DarkGray
    try {
        Start-Service -Name $script:DnsProxyService -ErrorAction Stop
    } catch {
        $nssmStatus = ''
        try { $nssmStatus = (& $script:NssmPath status $script:DnsProxyService 2>&1 | Out-String).Trim() } catch { Write-Warning ('SEDG:Start-AllServices: $nssmStatus = (& $script:NssmPath status $script:DnsProxySer... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $log = Join-Path $script:DnsProxyPath 'dnsproxy.log'
        $logText = if (Test-Path $log) { (Get-Content -LiteralPath $log -Tail 40 -ErrorAction SilentlyContinue) -join [Environment]::NewLine } else { '' }
        throw ("Failed to start {0}: {1}{2}NSSM: {3}{4}dnsproxy.log:{5}" -f $script:DnsProxyService, $_.Exception.Message, [Environment]::NewLine, $nssmStatus, [Environment]::NewLine, $logText)
    }

    Start-Sleep -Seconds 1
    $dns = Get-Service -Name $script:DnsProxyService -ErrorAction Stop
    if ($dns.Status -ne 'Running') {
        $nssmStatus = ''
        try { $nssmStatus = (& $script:NssmPath status $script:DnsProxyService 2>&1 | Out-String).Trim() } catch { Write-Warning ('SEDG:Start-AllServices: $nssmStatus = (& $script:NssmPath status $script:DnsProxySer... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        throw ("Service did not remain running: {0} ({1}). NSSM: {2}" -f $script:DnsProxyService, $dns.Status, $nssmStatus)
    }
    Write-Done 'DNSProxy is running.'
    }
}

function Set-AdapterDnsFamily([string]$AdapterName, [ValidateSet('IPv4','IPv6')][string]$AddressFamily, [string[]]$ServerAddresses, [switch]$Dhcp) {
    # Set-DnsClientServerAddress has no AddressFamily switch: pass only the
    # requested family's addresses for static DNS; use per-protocol netsh
    # contexts for DHCP so families stay independently restorable.
    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
    $interfaceIndex = [int]$adapter.ifIndex
    $family = $AddressFamily.ToLowerInvariant()

    if ($Dhcp) {
        $netshOut = (& netsh.exe interface $family set dnsservers "name=$AdapterName" source=dhcp validate=no 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "netsh failed to reset $AddressFamily DNS on $AdapterName (exit code $LASTEXITCODE): $netshOut"
        }
        return
    }

    $addresses = @($ServerAddresses |
        ForEach-Object { [string]$_ } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -ne 'DHCP' })

    if ($addresses.Count -eq 0) {
        throw "No DNS servers were supplied for $AddressFamily on $AdapterName."
    }

    foreach ($address in $addresses) {
        try {
            $parsed = [System.Net.IPAddress]::Parse($address)
            if (($AddressFamily -eq 'IPv4' -and $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) -or
                ($AddressFamily -eq 'IPv6' -and $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6)) {
                throw "Address belongs to the wrong IP family."
            }
        } catch {
            throw "Invalid $AddressFamily DNS address '$address' on $AdapterName."
        }
    }

    try {
        Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $addresses -ErrorAction Stop
    } catch {
        # Some adapters (freshly reset, driver-level oddities, runner images)
        # have no MSFT_DNSClientServerAddress objects at all, so the CIM
        # setter fails. netsh reaches the same state without them.
        $cimError = $_.Exception.Message
        $list = ($addresses -join ' ')
        $netshOut = (& netsh.exe interface $family set dnsservers "name=$AdapterName" static $list primary validate=no 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set $AddressFamily DNS on $AdapterName (interface index $interfaceIndex): $cimError ; netsh fallback failed (exit $LASTEXITCODE): $($netshOut.Trim())"
        }
        Write-Warning ("Set-DnsClientServerAddress failed on '{0}'; applied {1} static DNS via netsh instead. ({2})" -f $AdapterName, $AddressFamily, $cimError)
    }
}

function Set-AdapterDnsStatic([string]$AdapterName, [string[]]$V4, [string[]]$V6) {
    # Set both families in one call so the second never wipes the first. Only
    # for when static addresses for both are required.
    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
    $interfaceIndex = [int]$adapter.ifIndex
    $combined = @()
    foreach ($a in @($V4)) { if (-not [string]::IsNullOrWhiteSpace($a)) { $combined += $a.Trim() } }
    foreach ($a in @($V6)) { if (-not [string]::IsNullOrWhiteSpace($a)) { $combined += $a.Trim() } }
    if ($combined.Count -eq 0) { throw "No DNS servers were supplied for $AdapterName." }
    try {
        Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $combined -ErrorAction Stop
    } catch {
        # CIM objects can be absent on some adapters (see Set-AdapterDnsFamily);
        # fall back to per-family netsh static sets.
        $cimError = $_.Exception.Message
        $v4Ok = $true
        $v6Ok = $true
        if (@($V4).Count -gt 0) {
            $out4 = (& netsh.exe interface ipv4 set dnsservers "name=$AdapterName" static (@($V4) -join ' ') primary validate=no 2>&1 | Out-String)
            $v4Ok = ($LASTEXITCODE -eq 0)
        }
        if (@($V6).Count -gt 0) {
            $out6 = (& netsh.exe interface ipv6 set dnsservers "name=$AdapterName" static (@($V6) -join ' ') primary validate=no 2>&1 | Out-String)
            $v6Ok = ($LASTEXITCODE -eq 0)
        }
        if (-not ($v4Ok -and $v6Ok)) {
            throw "Failed to set combined DNS on $AdapterName (interface index $interfaceIndex): $cimError ; netsh fallback failed (ipv4 ok: $v4Ok, ipv6 ok: $v6Ok)"
        }
        Write-Warning ("Set-DnsClientServerAddress failed on '{0}'; applied static DNS via netsh instead. ({1})" -f $AdapterName, $cimError)
    }
}

function Set-AdapterDnsBoth([string]$AdapterName, [string[]]$V4, [string[]]$V6) {
    # Combined setter: empty family means DHCP, non-empty means static. Avoids
    # the second-call-wipes-first pitfall of Set-DnsClientServerAddress.
    $v4list = @($V4 | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $v6list = @($V6 | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if (($v4list.Count -eq 0) -and ($v6list.Count -eq 0)) {
        Set-AdapterDnsFamily $AdapterName IPv4 -Dhcp
        Set-AdapterDnsFamily $AdapterName IPv6 -Dhcp
        return
    }
    if (($v4list.Count -gt 0) -and ($v6list.Count -gt 0)) {
        Set-AdapterDnsStatic $AdapterName $v4list $v6list
        return
    }
    if ($v4list.Count -gt 0) {
        # Preserve real IPv6 RA/static state by querying current v6 first.
        $curV6 = @()
        try {
            $a = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
            $curV6 = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction Stop |
                Select-Object -ExpandProperty ServerAddresses | ForEach-Object { [string]$_ } |
                Where-Object { $_ -and $_ -ne '127.0.0.1' -and $_ -ne '::1' -and ($_ -match ':') })
        } catch { Write-Warning ('SEDG:Set-AdapterDnsBoth: $a = Get-NetAdapter -Name $AdapterName -ErrorAction Stop $cu... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        if ($curV6.Count -gt 0) { Set-AdapterDnsStatic $AdapterName $v4list $curV6; return }
        Set-AdapterDnsFamily $AdapterName IPv4 -ServerAddresses $v4list
        try { Set-AdapterDnsFamily $AdapterName IPv6 -Dhcp } catch { Write-Warning ('SEDG:Set-AdapterDnsBoth: Set-AdapterDnsFamily $AdapterName IPv6 -Dhcp (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        return
    }
    $curV4 = @()
    try {
        $a = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
        $curV4 = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction Stop |
            Select-Object -ExpandProperty ServerAddresses | ForEach-Object { [string]$_ } |
            Where-Object { $_ -and $_ -ne '127.0.0.1' -and $_ -ne '::1' -and ($_ -notmatch ':') })
    } catch { Write-Warning ('SEDG:Set-AdapterDnsBoth: $a = Get-NetAdapter -Name $AdapterName -ErrorAction Stop $cu... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    if ($curV4.Count -gt 0) { Set-AdapterDnsStatic $AdapterName $curV4 $v6list; return }
    Set-AdapterDnsFamily $AdapterName IPv6 -ServerAddresses $v6list
    try { Set-AdapterDnsFamily $AdapterName IPv4 -Dhcp } catch { Write-Warning ('SEDG:Set-AdapterDnsBoth: Set-AdapterDnsFamily $AdapterName IPv4 -Dhcp (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Set-SecureAcl([string]$Path, [switch]$AdminOnly) {
    # Admin/SYSTEM-only dir: strip inherited ACLs (well-known SIDs, language-independent).
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    if (-not $AdminOnly) { $grants += '*S-1-5-32-545:(OI)(CI)RX' }
    & icacls.exe $Path /inheritance:r /grant:r @grants | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to secure directory ACL: $Path" }
}

function Exit-Installer([int]$Code = 0) {
    # M5: never kill an interactive irm|iex host with exit; only exit when we
    # own a real script file invocation.
    if ($PSCommandPath) { exit $Code }
    return
}

function Get-OurProcesses {
    # M1: only processes running from our install directory.
    Get-Process -Name winws, dnsproxy, goodbyedpi -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Path -like ($script:InstallPath + '*') } catch { $false } }
}

function Get-StaticDnsServers([string]$InterfaceGuid, [ValidateSet('Tcpip','Tcpip6')]$Stack) {
    # H4: registry NameServer is the only reliable static-DNS signal.
    # Empty/missing value = automatic (DHCP/RA) -> empty array. An unreadable
    # key returns $null so callers can tell "unknown" apart from "DHCP".
    # Every return is a single object (,@()) so pipeline unrolling cannot
    # turn an empty array into $null.
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Stack\Parameters\Interfaces\$InterfaceGuid"
    try {
        $v = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('NameServer')
    } catch { return $null }
    $servers = @([string]$v -split '[,\s]+' | Where-Object { $_ })
    return ,$servers
}

function Log-Port53Owner {
    # Low: show which process holds UDP/TCP 53 before we stop services.
    try {
        $udp = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction Stop)
        foreach ($u in $udp) {
            try {
                $p = Get-Process -Id $u.OwningProcess -ErrorAction Stop
                Write-Host (('  Port 53 UDP {0} held by PID {1} ({2} {3})' -f $u.LocalAddress, $u.OwningProcess, $p.ProcessName, $p.Path)) -ForegroundColor DarkGray
            } catch {
                Write-Host (('  Port 53 UDP {0} held by PID {1}' -f $u.LocalAddress, $u.OwningProcess)) -ForegroundColor DarkGray
            }
        }
    } catch { Write-Warning ('SEDG:Log-Port53Owner: $udp = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction Stop)... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try {
        $tcp = @(Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction Stop)
        foreach ($t in $tcp) {
            try {
                $p = Get-Process -Id $t.OwningProcess -ErrorAction Stop
                Write-Host (('  Port 53 TCP {0} held by PID {1} ({2} {3})' -f $t.LocalAddress, $t.OwningProcess, $p.ProcessName, $p.Path)) -ForegroundColor DarkGray
            } catch {
                Write-Host (('  Port 53 TCP {0} held by PID {1}' -f $t.LocalAddress, $t.OwningProcess)) -ForegroundColor DarkGray
            }
        }
    } catch { Write-Warning ('SEDG:Log-Port53Owner: $tcp = @(Get-NetTCPConnection -LocalPort 53 -State Listen -E... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Backup-DnsSettings {
    # Best-effort pre-install DNS snapshot; never throws. Lives outside the
    # install dir and is never overwritten with tainted (local/bootstrap) data.
    # Static DNS comes from registry NameServer by InterfaceGuid, not the IP DHCP flag.
    try {
        $snapshot = @()
        foreach ($adapter in @(Get-NetworkAdapters -IncludeVirtual)) {
            try {
                $guid = $null
                try { $guid = [string]$adapter.InterfaceGuid } catch { Write-Warning ('SEDG:Backup-DnsSettings: $guid = [string]$adapter.InterfaceGuid (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                if ([string]::IsNullOrWhiteSpace($guid)) { continue }
                $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop)
                $v4 = @()
                $v6 = @()
                foreach ($a in @($dns | Select-Object -ExpandProperty ServerAddresses)) {
                    try {
                        $parsed = [System.Net.IPAddress]::Parse([string]$a)
                        if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $v4 += [string]$a }
                        else { $v6 += [string]$a }
                    } catch { Write-Warning ('SEDG:Backup-DnsSettings: $parsed = [System.Net.IPAddress]::Parse([string]$a) if ($par... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                }
                $regV4 = Get-StaticDnsServers $guid 'Tcpip'
                $regV6 = Get-StaticDnsServers $guid 'Tcpip6'
                if (($null -eq $regV4) -or ($null -eq $regV6)) {
                    # An unreadable registry key must not read as "DHCP": record
                    # the live servers so a later restore re-applies them
                    # instead of wiping the adapter to DHCP.
                    Write-Warning ("Could not read static DNS from the registry for adapter '$($adapter.Name)'; recording its current servers as the restore baseline.")
                    if ($null -eq $regV4) { $regV4 = @($v4) }
                    if ($null -eq $regV6) { $regV6 = @($v6) }
                }
                $snapshot += [pscustomobject]@{
                    Name = $adapter.Name
                    InterfaceGuid = $guid
                    ifIndex = $adapter.ifIndex
                    V4Addresses = $v4
                    V6Addresses = $v6
                    V4Static = $regV4
                    V6Static = $regV6
                }
            } catch { Write-Warning ('SEDG:Backup-DnsSettings: $guid = $null try { $guid = [string]$adapter.InterfaceGuid }... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        }
        $payload = [pscustomobject]@{
            BackedUp = (Get-Date).ToUniversalTime().ToString('o')
            Adapters = $snapshot
        }
        $json = $payload | ConvertTo-Json -Depth 5
        $localAddrs = @($snapshot | ForEach-Object { @($_.V4Addresses) + @($_.V6Addresses) })
        $tainted = [bool]@($localAddrs | Where-Object { $script:BootstrapTainted -contains $_ }).Count
        try {
            Set-SecureAcl $script:DnsBackupDir
            if (-not $tainted) {
                $json | Set-Content -LiteralPath $script:DnsBackupSafe -Encoding UTF8
            } elseif (-not (Test-Path -LiteralPath $script:DnsBackupSafe -PathType Leaf)) {
                Write-Warning 'Backup-DnsSettings: no safe baseline, skipping safe-backup write (live DNS is tainted).'
            }
        } catch { Write-Warning ('SEDG:Backup-DnsSettings: Set-SecureAcl $script:DnsBackupDir if ((-not (Test-Path -Lit... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    } catch { Write-Warning ('SEDG:Backup-DnsSettings: $snapshot = @() foreach ($adapter in @(Get-NetworkAdapters -... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Restore-DnsSettings {
    # Restore pre-install DNS (Uninstall/failure paths). Prefers the ProgramData
    # backup, then the legacy in-dir copy; matches by InterfaceGuid, then name.
    # Never throws; worst case resets to DHCP. Sets $script:DnsRestoreIncomplete
    # when the backup could not be fully replayed, so callers (Uninstall) know
    # to keep the backup file for another attempt.
    $restoredAny = $false
    $unmatchedEntries = $false
    $backupPath = $null
    $script:DnsRestoreIncomplete = $false
    try {
        $backupPath = $null
        foreach ($candidate in @($script:DnsBackupSafe, $script:DnsBackupFile)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $backupPath = $candidate; break }
        }
        if ($backupPath) {
            $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
            foreach ($entry in @($backup.Adapters)) {
                $guid = [string]$entry.InterfaceGuid
                $name = [string]$entry.Name
                if ([string]::IsNullOrWhiteSpace($guid) -and [string]::IsNullOrWhiteSpace($name)) { continue }
                try {
                    $adapter = $null
                    if (-not [string]::IsNullOrWhiteSpace($guid)) {
                        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $guid } | Select-Object -First 1
                    }
                    if (-not $adapter -and (-not [string]::IsNullOrWhiteSpace($name))) {
                        $adapter = Get-NetAdapter -Name $name -ErrorAction Stop
                    }
                    if (-not $adapter) { $unmatchedEntries = $true; continue }
                    $targetName = $adapter.Name
                    $clean = { param($list) @($list | ForEach-Object { [string]$_ } | Where-Object { $_ -and ($script:BootstrapTainted -notcontains $_) }) }
                    $v4live = & $clean @($entry.V4Addresses)
                    $v6live = & $clean @($entry.V6Addresses)
                    $v4reg = & $clean @($entry.V4Static)
                    $v6reg = & $clean @($entry.V6Static)
                    # Legacy backups without V4Static/V6Static: fall back to live lists.
                    if ($null -eq $entry.V4Static) { $v4reg = $v4live }
                    if ($null -eq $entry.V6Static) { $v6reg = $v6live }
                    $v4static = ($v4reg.Count -gt 0)
                    $v6static = ($v6reg.Count -gt 0)
                    if ($v4static -and $v6static) {
                        Set-AdapterDnsStatic $targetName $v4reg $v6reg
                        $restoredAny = $true
                    } elseif ($v4static) {
                        Set-AdapterDnsBoth $targetName $v4reg @()
                        $restoredAny = $true
                    } elseif ($v6static) {
                        Set-AdapterDnsBoth $targetName @() $v6reg
                        $restoredAny = $true
                    } else {
                        Set-AdapterDnsFamily $targetName IPv4 -Dhcp
                        Set-AdapterDnsFamily $targetName IPv6 -Dhcp
                        $restoredAny = $true
                    }
                } catch {
                    $script:DnsRestoreIncomplete = $true
                    try {
                        if ($adapter) {
                            Set-AdapterDnsFamily $adapter.Name IPv4 -Dhcp
                            Set-AdapterDnsFamily $adapter.Name IPv6 -Dhcp
                        }
                    } catch { Write-Warning ('SEDG:Restore-DnsSettings: if ($adapter) { Set-AdapterDnsFamily $adapter.Name IPv4 -Dhc... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                }
            }
        }
    } catch {
        $script:DnsRestoreIncomplete = $true
        Write-Warning ('SEDG:Restore-DnsSettings: $backupPath = $null foreach ($candidate in @($script:DnsBack... (' + $_.Exception.Message + ')'); Write-Verbose $_
    }
    if ($unmatchedEntries) { $script:DnsRestoreIncomplete = $true }
    if (-not $restoredAny) {
        if ($backupPath) {
            try { Reset-DnsToDhcp } catch { Write-Warning ('SEDG:Restore-DnsSettings: Reset-DnsToDhcp (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        } else {
            Write-Warning 'Restore-DnsSettings: no backup file found; skipping global DHCP reset.'
        }
        return
    }
    try { Clear-DnsClientCache; ipconfig /flushdns | Out-Null } catch { Write-Warning ('SEDG:Restore-DnsSettings: Clear-DnsClientCache; ipconfig /flushdns | Out-Null (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Reset-DnsToDhcp {
    # M4: physical adapters only by default so VPN/virtual adapters keep
    # their DNS. Falls back to all adapters only when no physical one is up.
    param([switch]$IncludeVirtual)
    Write-Step 'Resetting DNS settings to DHCP...'
    $failed = $false
    $adapters = @(Get-NetworkAdapters)
    if (($adapters.Count -eq 0) -or $IncludeVirtual) { $adapters = @(Get-NetworkAdapters -IncludeVirtual) }

    if ($adapters.Count -eq 0) {
        throw (T 'NoAdapters')
    }

    foreach ($adapter in $adapters) {
        try {
            Set-AdapterDnsFamily $adapter.Name IPv4 -Dhcp
            Set-AdapterDnsFamily $adapter.Name IPv6 -Dhcp
        } catch {
            $failed = $true
            Write-Host ((('  ' + ((T 'WarnDnsResetFailed') -f $adapter.Name)) + ': ' + $_.Exception.Message)) -ForegroundColor Yellow
        }
    }

    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null

    if ($failed) {
        throw 'One or more DNS adapters could not be reset to DHCP.'
    }

    Write-Done 'DNS settings reset to DHCP.'
}

function Get-AdapterDnsSnapshot([int]$IfIndex) {
    # Rollback input for the adapter mutation loops: per-family current DNS.
    $v4 = @()
    $v6 = @()
    try {
        $rows = @(Get-DnsClientServerAddress -InterfaceIndex $IfIndex -ErrorAction Stop)
    } catch {
        # An adapter with no DNS client entries (DHCP/reset state, runner
        # images) has no MSFT_DNSClientServerAddress objects at all: that is
        # an empty snapshot (restore to DHCP), not an unknown state.
        return @{ V4 = $v4; V6 = $v6 }
    }
    foreach ($a in @($rows | Select-Object -ExpandProperty ServerAddresses)) {
        try {
            $parsed = [System.Net.IPAddress]::Parse([string]$a)
            if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $v4 += [string]$a } else { $v6 += [string]$a }
        } catch { Write-Warning ('Could not classify DNS server address for rollback: ' + [string]$a) }
    }
    return @{ V4 = $v4; V6 = $v6 }
}

function Restore-AdapterDnsSnapshot([string]$AdapterName, $Snapshot) {
    # Best-effort undo for one adapter; empty families mean it was on DHCP.
    if ($null -eq $Snapshot) {
        Set-AdapterDnsFamily $AdapterName IPv4 -Dhcp
        Set-AdapterDnsFamily $AdapterName IPv6 -Dhcp
        return
    }
    Set-AdapterDnsBoth $AdapterName @($Snapshot.V4) @($Snapshot.V6)
}

function Set-LocalDns {
    Write-Step 'Switching to local DNS...'
    Write-Host (('  ' + (T 'InfoDnsTarget'))) -ForegroundColor DarkGray
    $adapters = @(Get-NetworkAdapters)
    if ($adapters.Count -eq 0) { $adapters = @(Get-NetworkAdapters -IncludeVirtual) }
    if ($adapters.Count -eq 0) { throw (T 'NoAdapters') }
    $applied = @()
    foreach ($adapter in $adapters) {
        Write-Host (('  ' + (T 'LbAdapter') + ': ' + $adapter.Name)) -ForegroundColor DarkGray
        $snapshot = $null
        try { $snapshot = Get-AdapterDnsSnapshot $adapter.ifIndex } catch { Write-Warning ('Could not snapshot DNS on adapter ''' + $adapter.Name + ''': ' + $_.Exception.Message) }
        try {
            Set-AdapterDnsBoth $adapter.Name @('127.0.0.1') @('::1')
        } catch {
            # A mid-loop failure must not leave earlier adapters on a
            # resolver that is not running yet.
            foreach ($done in $applied) {
                try { Restore-AdapterDnsSnapshot $done.Name $done.Snapshot } catch { Write-Warning ('Could not restore DNS on adapter ''' + $done.Name + ''': ' + $_.Exception.Message) }
            }
            throw
        }
        $applied += @{ Name = $adapter.Name; Snapshot = $snapshot }
    }
    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null
    try {
        $guids = @($adapters | ForEach-Object { try { [string]$_.InterfaceGuid } catch { '' } } | Where-Object { $_ })
        $st = @{ TouchedGuids = $guids; TouchedAt = (Get-Date).ToUniversalTime().ToString('o') }
        ($st | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath (Join-Path $script:DnsBackupDir 'touched-adapters.json') -Encoding UTF8
    } catch { Write-Warning ('SEDG:Set-LocalDns: $guids = @($adapters | ForEach-Object { try { [string]$_.Int... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    Write-Done 'Local DNS 127.0.0.1 enabled.'
}
function Set-InstallerBootstrapDns {
    Write-Step 'Checking download connection...'
    # Every host the installer downloads from: manifest origin, release
    # downloads and the NSSM mirror. No api.github.com calls.
    $checkHosts = @('github.com', 'nssm.cc')
    try {
        $manifestHost = ([uri]$script:Sources.Manifest).Host
        if (-not [string]::IsNullOrWhiteSpace($manifestHost)) { $checkHosts += $manifestHost }
    } catch { Write-Warning ('SEDG:Set-InstallerBootstrapDns: $manifestHost = ([uri]$script:Sources.Manifest).Host if (-no... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    $checkHosts = @($checkHosts | Select-Object -Unique)
    Write-Host (('  ' + (T 'LbTarget') + ': ' + ($checkHosts -join ', '))) -ForegroundColor DarkGray

    $failedHost = $null
    foreach ($h in $checkHosts) {
        try {
            if (@([System.Net.Dns]::GetHostAddresses($h)).Count -eq 0) { $failedHost = $h; break }
        } catch { $failedHost = $h; break }
    }

    if (-not $failedHost) {
        Write-Done 'Download connection OK.'
        return
    }

    Write-Step 'Applying temporary DNS for downloads...'
    Write-Host (('  ' + (T 'InfoTmpV4'))) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'InfoTmpV6'))) -ForegroundColor DarkGray
    # M4: bootstrap touches physical adapters only; VPN/virtual keep theirs.
    $adapters = @(Get-NetworkAdapters)
    if ($adapters.Count -eq 0) {
        throw 'No active network adapters were found for installer DNS bootstrap.'
    }

    $dnsV4 = @('1.1.1.1', '8.8.8.8')
    $dnsV6 = @('2606:4700:4700::1111', '2001:4860:4860::8888')

    $applied = @()
    foreach ($adapter in $adapters) {
        $snapshot = $null
        try { $snapshot = Get-AdapterDnsSnapshot $adapter.ifIndex } catch { Write-Warning ('Could not snapshot DNS on adapter ''' + $adapter.Name + ''': ' + $_.Exception.Message) }
        try {
            Set-AdapterDnsBoth $adapter.Name $dnsV4 $dnsV6
        } catch {
            foreach ($done in $applied) {
                try { Restore-AdapterDnsSnapshot $done.Name $done.Snapshot } catch { Write-Warning ('Could not restore DNS on adapter ''' + $done.Name + ''': ' + $_.Exception.Message) }
            }
            throw
        }
        $applied += @{ Name = $adapter.Name; Snapshot = $snapshot }
    }

    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null

    $failedHost = $null
    foreach ($h in $checkHosts) {
        try {
            if (@([System.Net.Dns]::GetHostAddresses($h)).Count -eq 0) { $failedHost = $h; break }
        } catch { $failedHost = $h; break }
    }

    if ($failedHost) {
        throw "DNS resolution is still unavailable for $failedHost after applying temporary bootstrap DNS."
    }

    Write-Done 'Temporary DNS is ready.'
}

function Get-PinnedNssmSource($ManifestNssm) {
    # F1: NSSM runs with installer/admin rights, so its origin and digest are
    # trusted only from this script. The manifest (primary or fallback) may
    # confirm the embedded pin, never choose it: a mismatch fails closed before
    # any download, extraction, copy or execution.
    $sha = ([string]$script:NssmSha256).Trim().ToLowerInvariant()
    $url = [string]$script:Sources.NssmZip
    $version = [string]$script:NssmVersion
    if ($sha.Length -ne 64 -or $sha -notmatch '^[0-9a-f]{64}$') {
        throw 'Embedded NSSM SHA-256 pin is missing or malformed; refusing to install NSSM.'
    }
    if (-not (Test-DownloadUrl $url)) {
        throw 'Embedded NSSM URL is missing or not https; refusing to install NSSM.'
    }
    if ($null -eq $ManifestNssm) {
        throw 'Approved manifest is missing the nssm component; refusing to install NSSM.'
    }
    $expected = [ordered]@{
        version = $version
        asset   = ('nssm-{0}.zip' -f $version)
        url     = $url
        sha256  = $sha
    }
    foreach ($field in $expected.Keys) {
        $actual = (Get-ManifestString $ManifestNssm $field).Trim()
        if ($field -eq 'sha256') { $actual = $actual.ToLowerInvariant() }
        if ($actual -ne [string]$expected[$field]) {
            throw ("Approved manifest nssm.{0} does not match the embedded NSSM pin; refusing to download, extract or run NSSM." -f $field)
        }
    }
    return [pscustomobject]@{
        Version = $version
        Asset   = $expected.asset
        Url     = $url
        Sha256  = $sha
        Mirror  = (Get-ManifestString $ManifestNssm 'mirror')
    }
}

function Install-StageNssm([string]$StageRoot, $ManifestNssm) {
    $pin = Get-PinnedNssmSource $ManifestNssm
    $nssmUrls = @([string]$pin.Url)
    $mirror = [string]$pin.Mirror
    if ((-not [string]::IsNullOrWhiteSpace($mirror)) -and ($mirror -ne $pin.Url) -and (Test-DownloadUrl $mirror)) {
        $nssmUrls += $mirror
    }

    Write-Step (((T 'StPrepNssm') -f $pin.Version))
    Write-Host (('  ' + (T 'LbSource') + ': ' + ($nssmUrls -join ' | '))) -ForegroundColor DarkGray
    $nssmZip = Join-Path $script:TempPath 'nssm.zip'
    Write-Host (('  ' + (T 'LbDest') + ': ' + $nssmZip)) -ForegroundColor DarkGray
    $nssmDownloaded = $false
    $nssmDlErrors = @()
    foreach ($candidateUrl in $nssmUrls) {
        try {
            Download-File $candidateUrl $nssmZip
            $nssmDownloaded = $true
            break
        } catch { $nssmDlErrors += ('{0}: {1}' -f $candidateUrl, $_.Exception.Message) }
    }
    if (-not $nssmDownloaded) { throw ("NSSM download failed: {0}" -f ($nssmDlErrors -join ' | ')) }
    Write-Host (('  ' + (T 'LbSize') + ': ' + ("{0:N0}" -f (Get-Item $nssmZip).Length) + ' ' + (T 'LbBytes'))) -ForegroundColor DarkGray
    $null = Verify-Sha256 $nssmZip ([string]$pin.Sha256) (T 'LblNssmArchive')
    $nssmExtract = Join-Path $script:TempPath 'nssm'
    Expand-Zip $nssmZip $nssmExtract
    $nssmExe = Get-ChildItem $nssmExtract -Recurse -File -Filter nssm.exe |
        Where-Object { $_.FullName -match '\\win64\\nssm\.exe$' } |
        Select-Object -First 1
    if (-not $nssmExe) { throw '64-bit NSSM executable not found in the pinned archive.' }
    $stageNssm = Join-Path $StageRoot 'nssm.exe'
    Copy-Item -LiteralPath $nssmExe.FullName -Destination $stageNssm -Force
    Write-Done (((T 'DoneNssmStaged') -f $pin.Version))
    return $stageNssm
}

function Get-PinnedManagerSource($ManifestManager) {
    # F1 pattern for the desktop app: its origin and digest are trusted only
    # from this script. The manifest may confirm the embedded pin, never choose
    # it: a mismatch fails closed before any download, extract, copy or run.
    $sha = ([string]$script:ManagerSha256).Trim().ToLowerInvariant()
    $repository = [string]$script:ManagerRepository
    $tag = [string]$script:ManagerTag
    $asset = [string]$script:ManagerAsset
    if ($sha.Length -ne 64 -or $sha -notmatch '^[0-9a-f]{64}$') {
        throw 'Embedded manager SHA-256 pin is missing or malformed; refusing to install the manager.'
    }
    if ($tag -notmatch '^(v)?\d+(\.\d+)*$') {
        throw 'Embedded manager tag pin is missing or malformed; refusing to install the manager.'
    }
    $version = $tag -replace '^v', ''
    if ($asset -ne ('sedg-manager-win-x64-{0}.zip' -f $version)) {
        throw 'Embedded manager asset pin does not match the embedded tag; refusing to install the manager.'
    }
    if ($script:AllowedReleaseRepos -notcontains $repository) {
        throw 'Embedded manager repository pin is not allow-listed; refusing to install the manager.'
    }
    if ($null -eq $ManifestManager) {
        throw 'Approved manifest is missing the manager component; refusing to install the manager.'
    }
    $expected = [ordered]@{
        repository = $repository
        tag        = $tag
        asset      = $asset
        sha256     = $sha
    }
    foreach ($field in $expected.Keys) {
        $actual = (Get-ManifestString $ManifestManager $field).Trim()
        if ($field -eq 'sha256') { $actual = $actual.ToLowerInvariant() }
        if ($actual -ne [string]$expected[$field]) {
            throw ("Approved manifest manager.{0} does not match the embedded manager pin; refusing to download, extract or install the manager." -f $field)
        }
    }
    return [pscustomobject]@{
        Repository = $repository
        Tag        = $tag
        Version    = $version
        Asset      = $asset
        Sha256     = $sha
    }
}

function Install-StageManager([string]$StageRoot, $ManifestManager, [switch]$AllowSeam) {
    $pin = Get-PinnedManagerSource $ManifestManager
    $managerUrl = Get-ReleaseAssetUrl $pin.Repository $pin.Tag $pin.Asset -AllowSeam:$AllowSeam
    Write-Step (('Preparing SEDG Manager {0}...' -f $pin.Tag))
    Write-Host (('  ' + (T 'LbSource') + ': ' + $managerUrl)) -ForegroundColor DarkGray
    $managerZip = Join-Path $script:TempPath 'manager.zip'
    Write-Host (('  ' + (T 'LbDest') + ': ' + $managerZip)) -ForegroundColor DarkGray
    Download-File $managerUrl $managerZip
    Write-Host (('  ' + (T 'LbSize') + ': ' + ("{0:N0}" -f (Get-Item $managerZip).Length) + ' ' + (T 'LbBytes'))) -ForegroundColor DarkGray
    $null = Verify-Sha256 $managerZip $pin.Sha256 'SEDG Manager archive'
    $managerExtract = Join-Path $script:TempPath 'manager'
    Expand-Zip $managerZip $managerExtract
    # The manager archive is one flat app: its exe plus a version file. Anything
    # else (the retired Sedg.Desktop.exe layout, a stray helper exe) is refused
    # before a single byte reaches the install directory.
    $payloadExes = @(Get-ChildItem $managerExtract -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue)
    if (($payloadExes.Count -ne 1) -or ($payloadExes[0].Name -ne $script:ManagerExe)) {
        $found = if ($payloadExes.Count -eq 0) { 'none' } else { ($payloadExes | ForEach-Object { $_.Name }) -join ', ' }
        throw ("Expected exactly one {0} in the manager archive; found: {1}." -f $script:ManagerExe, $found)
    }
    $appRoot = $payloadExes[0].DirectoryName
    if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'manager-version.txt') -PathType Leaf)) {
        throw 'Manager payload is missing required file: manager-version.txt.'
    }
    $bundledVersion = ''
    try {
        $bundledVersion = ([string](Get-Content -LiteralPath (Join-Path $appRoot 'manager-version.txt') -Raw -ErrorAction Stop)).Trim()
    } catch { Write-Verbose $_ }
    if ($bundledVersion -ne $pin.Version) {
        throw ("Manager payload version '{0}' does not match the pinned version '{1}'." -f $bundledVersion, $pin.Version)
    }
    foreach ($name in @($script:ManagerExe, 'manager-version.txt')) {
        Copy-Item -LiteralPath (Join-Path $appRoot $name) -Destination (Join-Path $StageRoot $name) -Force
    }
    Write-Done (('SEDG Manager {0} staged.' -f $pin.Tag))
    return $StageRoot
}

function Install-StageComponents {
    param([switch]$AllowSeam)
    Write-Step 'Preparing component installation...'
    Write-Host (('  ' + (T 'LbStaging') + ': ' + $script:TempPath)) -ForegroundColor DarkGray
    if (Test-Path $script:TempPath) {
        Remove-Item $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null
    Set-SecureAcl $script:TempPath -AdminOnly

    $stageRoot = Join-Path $script:TempPath 'stage'
    $stageDns = Join-Path $stageRoot 'dnsproxy'
    $stageZap = Join-Path $stageRoot 'zapret'
    New-Item -ItemType Directory -Path $stageDns -Force | Out-Null
    New-Item -ItemType Directory -Path $stageZap -Force | Out-Null

    Write-Step 'Checking approved component versions...'
    $manifest = Get-ApprovedManifest
    Assert-ManifestComponents $manifest
    # F1: reject a manifest whose NSSM values differ from the embedded trust
    # anchor before downloading anything, whichever origin produced it.
    $null = Get-PinnedNssmSource $manifest.components.nssm
    # Same fail-closed check for the manager pin before any download runs.
    $man = Get-ManifestProperty $manifest.components 'manager'
    $null = Get-PinnedManagerSource $man
    Write-Host (('  ' + ((T 'LbApproved') -f 'installer') + ': ' + $manifest.installer.version)) -ForegroundColor DarkGray
    Write-Host (('  ' + ((T 'LbApproved') -f 'DNSProxy') + ': ' + $manifest.components.dnsproxy.tag)) -ForegroundColor DarkGray
    Write-Host (('  ' + ((T 'LbApproved') -f 'Zapret') + ': ' + $manifest.components.zapret.tag)) -ForegroundColor DarkGray
    Write-Host (('  ' + ((T 'LbApproved') -f 'NSSM') + ': ' + $manifest.components.nssm.version)) -ForegroundColor DarkGray
    Write-Host (('  ' + ((T 'LbApproved') -f 'Manager') + ': ' + (Get-ManifestString $man 'tag'))) -ForegroundColor DarkGray
    $dnsTag = [string]$manifest.components.dnsproxy.tag
    $zapTag = [string]$manifest.components.zapret.tag
    $dnsAssetName = [string]$manifest.components.dnsproxy.asset
    $zapAssetName = [string]$manifest.components.zapret.asset
    $dnsDownloadUrl = Get-ReleaseAssetUrl ([string]$manifest.components.dnsproxy.repository) $dnsTag $dnsAssetName -AllowSeam:$AllowSeam
    $zapDownloadUrl = Get-ReleaseAssetUrl ([string]$manifest.components.zapret.repository) $zapTag $zapAssetName -AllowSeam:$AllowSeam
    Write-Host (('  ' + (T 'LbVersions') + ': DNSProxy ' + $dnsTag + ' | Zapret ' + $zapTag)) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'LbAssetDns') + ': ' + $dnsAssetName)) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'LbAssetZap') + ': ' + $zapAssetName)) -ForegroundColor DarkGray

    $dnsZip = Join-Path $script:TempPath $dnsAssetName
    Write-Step (((T 'StDlDnsproxy') -f $dnsTag))
    Write-Host (('  ' + (T 'LbSource') + ': ' + $dnsDownloadUrl)) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'LbDest') + ': ' + $dnsZip)) -ForegroundColor DarkGray
    Download-File $dnsDownloadUrl $dnsZip
    Write-Host (('  ' + (T 'LbSize') + ': ' + ("{0:N0}" -f (Get-Item $dnsZip).Length) + ' ' + (T 'LbBytes'))) -ForegroundColor DarkGray
    $null = Verify-Sha256 $dnsZip $manifest.components.dnsproxy.sha256 (T 'LblDnsArchive')
    Write-Step 'Preparing DNSProxy...'
    Write-Host (('  ' + (T 'InfoExtracting'))) -ForegroundColor DarkGray
    $dnsExtract = Join-Path $script:TempPath 'dnsproxy'
    Expand-Zip $dnsZip $dnsExtract
    $dnsExe = Find-File $dnsExtract 'dnsproxy.exe'
    if (-not $dnsExe) { throw 'dnsproxy.exe not found in upstream archive.' }
    Copy-Item $dnsExe.FullName (Join-Path $stageDns 'dnsproxy.exe') -Force
    Write-Done (((T 'DoneDnsStaged') -f $dnsExe.FullName))

    $zapZip = Join-Path $script:TempPath $zapAssetName
    Write-Step (((T 'StDlZapret') -f $zapTag))
    Write-Host (('  ' + (T 'LbSource') + ': ' + $zapDownloadUrl)) -ForegroundColor DarkGray
    Write-Host (('  ' + (T 'LbDest') + ': ' + $zapZip)) -ForegroundColor DarkGray
    Download-File $zapDownloadUrl $zapZip
    Write-Host (('  ' + (T 'LbSize') + ': ' + ("{0:N0}" -f (Get-Item $zapZip).Length) + ' ' + (T 'LbBytes'))) -ForegroundColor DarkGray
    $null = Verify-Sha256 $zapZip $manifest.components.zapret.sha256 (T 'LblZapArchive')
    Write-Step 'Preparing Zapret...'
    Write-Host (('  ' + (T 'InfoExtractingZapret'))) -ForegroundColor DarkGray
    $zapExtract = Join-Path $script:TempPath 'zapret'
    Expand-Zip $zapZip $zapExtract
    # Select the official Windows x64 bundle explicitly. Do not use a generic
    # recursive search because the release also contains the x86 build.
    $runtimeDirs = Get-ChildItem -LiteralPath $zapExtract -Recurse -Directory -Filter 'windows-x86_64' -ErrorAction SilentlyContinue
    if (@($runtimeDirs).Count -ne 1) {
        throw "Expected exactly one windows-x86_64 directory in the zapret archive; found $(@($runtimeDirs).Count)."
    }
    $runtimeRoot = $runtimeDirs[0].FullName
    Write-Host (('  ' + (T 'LbRuntime') + ': ' + $runtimeRoot)) -ForegroundColor DarkGray
    $winwsExe = Join-Path $runtimeRoot 'winws.exe'
    if (-not (Test-Path $winwsExe)) { throw 'x64 winws.exe not found in upstream zapret archive.' }

    Get-ChildItem -LiteralPath $runtimeRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $stageZap -Recurse -Force
    }
    if (-not (Test-Path (Join-Path $stageZap 'winws.exe'))) {
        throw 'Failed to stage winws.exe from the official zapret archive.'
    }

    if (-not (Test-Path (Join-Path $stageZap 'WinDivert64.sys'))) {
        throw 'Official x64 zapret bundle is missing WinDivert64.sys.'
    }

    Write-Done 'Zapret prepared.'

    $stageNssm = Install-StageNssm $stageRoot $manifest.components.nssm
    Write-Done 'Services prepared.'

    $stageManager = Join-Path $stageRoot 'manager'
    New-Item -ItemType Directory -Path $stageManager -Force | Out-Null
    $stageManager = Install-StageManager $stageManager $man -AllowSeam:$AllowSeam
    Write-Done 'Manager prepared.'

    Write-Step 'Validating staged components...'
    Write-Host '  DNSProxy: dnsproxy.exe' -ForegroundColor DarkGray
    Write-Host '  Zapret: winws.exe, cygwin1.dll, WinDivert.dll, WinDivert64.sys' -ForegroundColor DarkGray
    Write-Host ("  NSSM: {0}" -f $stageNssm) -ForegroundColor DarkGray
    Write-Host ("  Manager: {0}" -f $stageManager) -ForegroundColor DarkGray
    if (-not (Test-Path (Join-Path $stageDns 'dnsproxy.exe'))) { throw 'Staged dnsproxy.exe is missing.' }
    if (-not (Test-Path (Join-Path $stageZap 'winws.exe'))) { throw 'Staged winws.exe is missing.' }
    if (-not (Test-Path (Join-Path $stageZap 'cygwin1.dll'))) { throw 'Staged cygwin1.dll is missing.' }
    if (-not (Test-Path (Join-Path $stageZap 'WinDivert.dll'))) { throw 'Staged WinDivert.dll is missing.' }
    if (-not (Test-Path (Join-Path $stageZap 'WinDivert64.sys'))) { throw 'Staged WinDivert64.sys is missing.' }
    if (-not (Test-Path $stageNssm)) { throw 'Staged nssm.exe is missing.' }
    if (-not (Test-Path (Join-Path $stageManager $script:ManagerExe))) { throw ('Staged {0} is missing.' -f $script:ManagerExe) }
    if (-not (Test-Path (Join-Path $stageManager 'manager-version.txt'))) { throw 'Staged manager-version.txt is missing.' }

    Write-Done 'Components validated.'

    return @{
        DnsRelease = $dnsTag
        ZapRelease = $zapTag
        StageDns = $stageDns
        StageZap = $stageZap
        StageNssm = $stageNssm
        StageManager = $stageManager
    }
}

function Install-CommitComponents([hashtable]$Staged) {
    $stageDns = [string]$Staged.StageDns
    $stageZap = [string]$Staged.StageZap
    $stageNssm = [string]$Staged.StageNssm
    if ([string]::IsNullOrWhiteSpace($stageDns) -or [string]::IsNullOrWhiteSpace($stageZap) -or [string]::IsNullOrWhiteSpace($stageNssm)) {
        throw 'Staged component paths are missing.'
    }

    # Commit only after all downloads, extraction and validation have succeeded.
    Write-Step 'Installing verified components...'
    Write-Host (('  ' + (T 'LbTarget') + ': ' + $script:InstallPath)) -ForegroundColor DarkGray
    $rollbackRoot = Join-Path $script:TempPath 'rollback'
    if (Test-Path $rollbackRoot) {
        Remove-Item $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null

    $dnsRollback = Join-Path $rollbackRoot 'dnsproxy'
    $zapRollback = Join-Path $rollbackRoot 'zapret'
    $nssmRollback = Join-Path $rollbackRoot 'nssm.exe'

    try {
        if (Test-Path $script:DnsProxyPath) {
            Copy-Item -LiteralPath $script:DnsProxyPath -Destination $dnsRollback -Recurse -Force
        }
        if (Test-Path $script:ZapretPath) {
            Copy-Item -LiteralPath $script:ZapretPath -Destination $zapRollback -Recurse -Force
        }
        if (Test-Path $script:NssmPath) {
            Copy-Item -LiteralPath $script:NssmPath -Destination $nssmRollback -Force
        }

        New-Item -ItemType Directory -Path $script:DnsProxyPath -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $stageDns 'dnsproxy.exe') -Destination (Join-Path $script:DnsProxyPath 'dnsproxy.exe') -Force

        New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null

        # A kernel driver can stay locked briefly after its service stops. Keep
        # the locked file when staged and installed drivers are identical; fail
        # safely on change instead of deleting a loaded driver.
        $liveDriver = Join-Path $script:ZapretPath 'WinDivert64.sys'
        $stageDriver = Join-Path $stageZap 'WinDivert64.sys'
        if (Test-Path $liveDriver) {
            $liveDriverHash = (Get-FileHash -Path $liveDriver -Algorithm SHA256).Hash
            $stageDriverHash = (Get-FileHash -Path $stageDriver -Algorithm SHA256).Hash
            if ($liveDriverHash -ne $stageDriverHash) {
                throw 'Existing WinDivert64.sys differs from the staged driver and is still present. Reboot Windows, then run Install/Update again so the kernel driver can be replaced safely.'
            }
        }

        # Remove the previous user-mode runtime but preserve user files
        # (blacklist, winws args) and an identical locked WinDivert64.sys.
        Get-ChildItem -LiteralPath $script:ZapretPath -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('blacklist.txt', 'winws-args.txt', 'WinDivert64.sys') } |
            Remove-Item -Recurse -Force

        # Copy the staged runtime. Skip WinDivert64.sys when an identical live
        # driver is already locked by Windows; all other files are replaced.
        Get-ChildItem -LiteralPath $stageZap -Force |
            Where-Object { $_.Name -ne 'WinDivert64.sys' } |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $script:ZapretPath -Recurse -Force
            }

        if (-not (Test-Path $liveDriver)) {
            Copy-Item -LiteralPath $stageDriver -Destination $script:ZapretPath -Force
        }
        Copy-Item -LiteralPath $stageNssm -Destination $script:NssmPath -Force
        if (-not (Test-Path (Join-Path $script:DnsProxyPath 'dnsproxy.exe'))) { throw 'Live dnsproxy.exe commit failed.' }
        if (-not (Test-Path (Join-Path $script:ZapretPath 'winws.exe'))) { throw 'Live winws.exe commit failed.' }
        if (-not (Test-Path $script:NssmPath)) { throw 'Live nssm.exe commit failed.' }
        Write-Done 'Components installed.'
    } catch {
        Write-Host (('  ' + (T 'WarnRollingBack'))) -ForegroundColor Yellow
        try {
            if (Test-Path $dnsRollback) {
                Remove-Item $script:DnsProxyPath -Recurse -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $dnsRollback -Destination $script:DnsProxyPath -Recurse -Force
            }
            if (Test-Path $zapRollback) {
                $rollbackDriver = Join-Path $zapRollback 'WinDivert64.sys'
                $liveDriver = Join-Path $script:ZapretPath 'WinDivert64.sys'
                $preserveDriver = $false

                if ((Test-Path $liveDriver) -and (Test-Path $rollbackDriver)) {
                    try {
                        $preserveDriver = ((Get-FileHash -Path $liveDriver -Algorithm SHA256).Hash -eq
                            (Get-FileHash -Path $rollbackDriver -Algorithm SHA256).Hash)
                    } catch { Write-Warning ('SEDG:Install-CommitComponents: $preserveDriver = ((Get-FileHash -Path $liveDriver -Algorith... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                }

                if ($preserveDriver) {
                    Get-ChildItem -LiteralPath $script:ZapretPath -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notin @('WinDivert64.sys') } |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    Get-ChildItem -LiteralPath $zapRollback -Force |
                        Where-Object { $_.Name -ne 'WinDivert64.sys' } |
                        ForEach-Object {
                            Copy-Item -LiteralPath $_.FullName -Destination $script:ZapretPath -Recurse -Force
                        }
                } else {
                    # Never leave a mixed user-mode/driver pair silently: attempt a
                    # full restore, then fail loudly (reboot and retry). No
                    # reboot-deletion on the Install/Update path.
                    try {
                        Remove-Item -LiteralPath $script:ZapretPath -Recurse -Force -ErrorAction Stop
                        Copy-Item -LiteralPath $zapRollback -Destination $script:ZapretPath -Recurse -Force -ErrorAction Stop
                    } catch {
                        throw "Rollback incomplete: live WinDivert64.sys is locked and differs from backup. Reboot Windows, then retry. ($($_.Exception.Message))"
                    }
                }
            }
            if (Test-Path $nssmRollback) {
                Remove-Item $script:NssmPath -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $nssmRollback -Destination $script:NssmPath -Force
            }
        } catch {
            Write-Host (((T 'WarnRollback') -f $_.Exception.Message)) -ForegroundColor Yellow
        }
        throw
    }
}

function Test-ManagerHealthy {
    # The manager is healthy when the installed payload matches the embedded
    # pin: version file equal to the pinned version and a non-empty
    # sedg-manager.exe beside it in the engine root.
    try {
        if (-not (Test-Path -LiteralPath $script:ManagerPath -PathType Leaf)) { return $false }
        $versionPath = Join-Path (Split-Path -Parent $script:ManagerPath) 'manager-version.txt'
        if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { return $false }
        $installedVersion = ([string](Get-Content -LiteralPath $versionPath -Raw -ErrorAction Stop)).Trim()
        if ($installedVersion -ne ([string]$script:ManagerTag -replace '^v', '')) { return $false }
        return ((Get-Item -LiteralPath $script:ManagerPath -ErrorAction Stop).Length -gt 0)
    } catch { Write-Verbose $_ }
    return $false
}

function Install-CommitManager([string]$StageManager) {
    if ([string]::IsNullOrWhiteSpace($StageManager) -or (-not (Test-Path -LiteralPath $StageManager -PathType Container))) {
        throw 'Staged manager directory is missing.'
    }
    $stagedExe = Join-Path $StageManager $script:ManagerExe
    $stagedVersion = Join-Path $StageManager 'manager-version.txt'
    if ((-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) -or (-not (Test-Path -LiteralPath $stagedVersion -PathType Leaf))) {
        throw 'Staged manager payload is incomplete.'
    }
    if (Test-ManagerHealthy) {
        Write-Step 'SEDG Manager is already up to date.'
        return
    }
    $managerDir = Split-Path -Parent $script:ManagerPath
    New-Item -ItemType Directory -Path $managerDir -Force | Out-Null
    $versionPath = Join-Path $managerDir 'manager-version.txt'
    Write-Step 'Installing SEDG Manager...'
    Write-Host (('  ' + (T 'LbTarget') + ': ' + $script:ManagerPath)) -ForegroundColor DarkGray

    # File swap, not a directory swap: the manager is one exe + one version file
    # in the engine root. A running manager keeps its image open, so its files
    # are renamed aside (renaming a running exe is allowed; overwriting it is
    # not) and the new pair takes the canonical names.
    $stamp = [guid]::NewGuid().ToString('N')
    $asideExe = $script:ManagerPath + '.old-' + $stamp
    $asideVersion = $versionPath + '.old-' + $stamp
    $hadExe = Test-Path -LiteralPath $script:ManagerPath -PathType Leaf
    $hadVersion = Test-Path -LiteralPath $versionPath -PathType Leaf
    $movedExe = $false
    $movedVersion = $false
    $copiedExe = $false
    $copiedVersion = $false
    try {
        if ($hadExe) {
            try {
                Move-Item -LiteralPath $script:ManagerPath -Destination $asideExe -ErrorAction Stop
                $movedExe = $true
            } catch {
                throw ('SEDG Manager cannot be replaced while its file is locked ({0}). Close SEDG Manager, then run this action again.' -f $_.Exception.Message)
            }
        }
        if ($hadVersion) {
            try {
                Move-Item -LiteralPath $versionPath -Destination $asideVersion -ErrorAction Stop
                $movedVersion = $true
            } catch {
                throw ('The installed manager version file is locked ({0}). Close SEDG Manager, then run this action again.' -f $_.Exception.Message)
            }
        }
        Copy-Item -LiteralPath $stagedExe -Destination $script:ManagerPath -Force
        $copiedExe = $true
        Copy-Item -LiteralPath $stagedVersion -Destination $versionPath -Force
        $copiedVersion = $true
        if (-not (Test-ManagerHealthy)) { throw 'Live SEDG Manager commit failed verification.' }
        Write-Done ('SEDG Manager {0} installed.' -f ([string]$script:ManagerTag -replace '^v', ''))
    } catch {
        Write-Host (('  ' + (T 'WarnRollingBack'))) -ForegroundColor Yellow
        try {
            # Move the old files back over whatever landed; never delete a file
            # that was not proven to be this attempt's copy.
            if ($movedExe) {
                Move-Item -LiteralPath $asideExe -Destination $script:ManagerPath -Force -ErrorAction Stop
            } elseif ($copiedExe) {
                Remove-Item -LiteralPath $script:ManagerPath -Force -ErrorAction SilentlyContinue
            }
            if ($movedVersion) {
                Move-Item -LiteralPath $asideVersion -Destination $versionPath -Force -ErrorAction Stop
            } elseif ($copiedVersion) {
                Remove-Item -LiteralPath $versionPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host (((T 'WarnRollback') -f $_.Exception.Message)) -ForegroundColor Yellow
        }
        throw
    }

    # The aside copy of a running manager stays locked until that process exits,
    # so a locked leftover is scheduled for reboot deletion instead of failing.
    foreach ($leftover in @($asideExe, $asideVersion)) {
        if (-not (Test-Path -LiteralPath $leftover)) { continue }
        try { Remove-Item -LiteralPath $leftover -Force -ErrorAction Stop }
        catch { try { Schedule-DeleteOnReboot $leftover } catch { Write-Verbose $_ } }
    }
    # Leftovers from earlier updates, once nothing holds them.
    try {
        Get-ChildItem -LiteralPath $managerDir -Filter ($script:ManagerExe + '.old-*') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $asideExe } |
            ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { Write-Verbose $_ } }
    } catch { Write-Verbose $_ }

    # 1.2.5 and earlier kept the WPF app in %ProgramFiles%\SEDG Manager. It is
    # this product's own retired copy (proven by its exe name), never user data.
    if (Test-Path -LiteralPath (Join-Path $script:LegacyManagerPath 'Sedg.Desktop.exe') -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $script:LegacyManagerPath -Recurse -Force -ErrorAction Stop
            Write-Host '  Retired manager files removed from Program Files.' -ForegroundColor DarkGray
        } catch {
            Write-Host (('  Retired manager files kept: ' + $_.Exception.Message)) -ForegroundColor Yellow
        }
    }
}

function Get-UpstreamBlock {
    # Single parser for the dnsproxy `upstream:` block. Returns a span plus
    # validated entries so list/validate/replace share one code path.
    # Handles indented comments, trailing comments, and #-in-URL (a # cut
    # only applies outside quotes, mirroring the historical quote-parity rule).
    $block = [pscustomobject]@{ Style = 'none'; Start = -1; End = -1; Entries = @() }
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { return $block }
    try {
        $lines = @(Get-Content -LiteralPath $script:ConfigFile -ErrorAction Stop)
    } catch { Write-Warning ('SEDG:Get-UpstreamBlock: $lines = @(Get-Content -LiteralPath $script:ConfigFile -ErrorA... (' + $_.Exception.Message + ')'); Write-Verbose $_; return $block }
    $entries = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($line -match '^upstream:\s*\[(.*)\]\s*$') {
            foreach ($part in ($Matches[1] -split ',')) {
                $u = $part.Trim().Trim('"', "'")
                if (Test-DnsUpstream $u) { $entries += $u }
            }
            $block.Style = 'flow'; $block.Start = $i; $block.End = $i
            break
        }
        if ($line -match '^upstream:\s*$') {
            $block.Style = 'block'; $block.Start = $i; $block.End = $i
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $inner = [string]$lines[$j]
                if ($inner -match '^\s*#') { $block.End = $j; continue }
                if ($inner -match '^\S') { break }
                $block.End = $j
                $code = $inner
                foreach ($cut in [regex]::Matches($code, '\s+#')) {
                    if ((($code.Substring(0, $cut.Index) -replace "[^'""]", '').Length % 2) -eq 0) { $code = $code.Substring(0, $cut.Index); break }
                }
                if ($code -match '^\s*-\s*["'']?([^''"\s]+)["'']?\s*$') {
                    $u = $Matches[1].Trim()
                    if (Test-DnsUpstream $u) { $entries += $u }
                }
            }
            break
        }
    }
    $block.Entries = $entries
    return $block
}

function Get-UpstreamList {
    # Ordered valid upstream entries, primary first. Empty when none usable.
    return @((Get-UpstreamBlock).Entries)
}

function Get-ConfiguredUpstream {
    foreach ($u in @(Get-UpstreamList)) { return $u }
    if (Test-Path -LiteralPath $script:StateFile -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            $configured = [string]$state.Upstream
            if (Test-DnsUpstream $configured) { return $configured }
        } catch { Write-Warning ('SEDG:Get-ConfiguredUpstream: $state = Get-Content -LiteralPath $script:StateFile -Raw | C... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
    return $script:OptionalUpstreams['SDEG (Default)']
}

function Get-RedactedUrl([string]$Url) {
    # F10: strip the query string (?token=...) before any console/transcript
    # log or state file. The full URL lives only in config.yaml, never in
    # output. Scheme + host + path stay so the value remains parseable.
    $redacted = '[redacted]'
    try { $u = [uri]$Url; $redacted = ($u.Scheme + '://' + $u.Host + $u.AbsolutePath) } catch { Write-Verbose $_ }
    return $redacted
}

function Test-DnsUpstream([string]$Upstream) {
    if ([string]::IsNullOrWhiteSpace($Upstream)) { return $false }
    if ($Upstream -match '[\r\n]') { return $false }
    try {
        $uri = [Uri]$Upstream
        return $uri.IsAbsoluteUri -and $uri.Scheme -in @('https','tls','h3','quic') -and -not [string]::IsNullOrWhiteSpace($uri.Host)
    } catch { return $false }
}

function Write-OriginalConfigTemplate {
    New-Item -ItemType Directory -Path $script:DnsProxyPath -Force | Out-Null
    # M7: six upstreams under native load_balance plus a neutral fallback so
    # one provider outage does not take DNS down. timeout bounds slow-loris
    # drag at 5s. Set-UpstreamInConfig preserves fallback/bootstrap/cache.
    $tpl = @(
        'listen-addrs:',
        '  - 127.0.0.1',
        '  - ::1',
        'listen-ports:',
        '  - 53',
        'upstream:',
        '  - https://ultralow2.dns2.nextdns.io/735d22',
        '  - https://sdns.taiyuanwangjie.dpdns.org/dns-query',
        '  - https://ultralow2.dns2.nextdns.io/9fcbfc',
        '  - https://dns.google/dns-query',
        '  - https://cloudflare-dns.com/dns-query',
        '  - https://dns.quad9.net/dns-query',
        'timeout: 5s',
        'fallback:',
        '  - https://cloudflare-dns.com/dns-query',
        'bootstrap:',
        '  - 1.1.1.1',
        '  - 8.8.8.8',
        '  - 9.9.9.9',
        '  - 208.67.222.222',
        'cache: true',
        'cache-size: 4194304',
        'cache-max-ttl: 3600',
        'cache-optimistic: true'
    )
    [IO.File]::WriteAllLines($script:ConfigFile, $tpl, [Text.UTF8Encoding]::new($false))
}

function Test-ConfigValid {
    # A config without usable listen/upstream blocks would crash dnsproxy at
    # startup. Keep the check narrow to avoid false positives on user tweaks.
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { return $false }
        $raw = Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop
        if (-not [regex]::IsMatch($raw, '(?m)^upstream:\s*$')) {
            if (-not [regex]::IsMatch($raw, '(?m)^upstream:\s*\[.*\]')) { return $false }
        }
        if (-not [regex]::IsMatch($raw, '(?m)^listen-ports:\s*$')) { return $false }
        return (@((Get-UpstreamBlock).Entries).Count -gt 0)
    } catch { return $false }
}
function Ensure-Config {
    New-Item -ItemType Directory -Path $script:DnsProxyPath -Force | Out-Null
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) {
        Write-Step 'Installing DNSProxy configuration...'
        Write-Host (('  ' + (T 'LbConfig') + ': ' + $script:ConfigFile)) -ForegroundColor DarkGray
        Write-OriginalConfigTemplate
        Write-Done 'DNSProxy configuration installed.'
        return
    }
    if (-not (Test-ConfigValid)) {
        try { Copy-Item -LiteralPath $script:ConfigFile -Destination ($script:ConfigFile + '.bak') -Force -ErrorAction Stop } catch { Write-Warning ('SEDG:Ensure-Config: Copy-Item -LiteralPath $script:ConfigFile -Destination ($scr... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        Write-Host (('  ' + (T 'CfgInvalid'))) -ForegroundColor Yellow
        Write-OriginalConfigTemplate
        Write-Done 'DNSProxy configuration installed.'
        return
    }
    Repair-CacheKey
    Write-Host (('  ' + (T 'LbConfig') + ': ' + $script:ConfigFile)) -ForegroundColor DarkGray
    Write-Done 'Existing DNSProxy configuration preserved.'
}
function Repair-CacheKey {
    # H7: older templates wrote cache_max_ttl (underscore), which dnsproxy
    # ignores - the real key is cache-max-ttl. Migrate narrowly, keep the value.
    try {
        $raw = Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop
        if ($raw -notmatch '(?m)^cache_max_ttl:') { return }
        Write-Step 'Migrating DNSProxy cache setting...'
        if ($raw -match '(?m)^cache-max-ttl:') {
            $fixed = $raw -replace '(?m)^cache_max_ttl:.*(?:\r?\n|$)', ''
        } else {
            $fixed = $raw -replace '(?m)^cache_max_ttl:\s*(\S+)\s*$', 'cache-max-ttl: $1'
        }
        Set-Content -LiteralPath $script:ConfigFile -Value $fixed -Encoding UTF8 -NoNewline
        Write-Done 'DNSProxy cache setting migrated.'
    } catch { Write-Warning ('SEDG:Repair-CacheKey: $raw = Get-Content -LiteralPath $script:ConfigFile -Raw -Err... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}
function Set-UpstreamInConfig([string]$Upstream) {
    if (-not (Test-DnsUpstream $Upstream)) { throw 'Unsupported DNS Upstream.' }
    Ensure-Config
    $content = Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalized = $content -replace "`r`n", "`n"
    $block = Get-UpstreamBlock
    if ([string]$block.Style -eq 'none') { throw "Could not locate a valid upstream block in $($script:ConfigFile)." }
    # Multi-upstream: promote-or-prepend the selected entry; the rest stays in
    # order as standby. Defaults are never evicted; cap 8 drops the oldest
    # custom first (position = recency, index 0 is newest).
    $defaults = @($script:OptionalUpstreams.Values)
    $rest = @(@(Get-UpstreamList) | Where-Object { $_ -ne $Upstream })
    $list = @($Upstream) + $rest
    while ($list.Count -gt 8) {
        $evict = @($list | Where-Object { $defaults -notcontains $_ }) | Select-Object -Last 1
        if (-not $evict) { break }
        $list = @($list | Where-Object { $_ -ne $evict })
        $__evictShown = '[redacted]'
        try { $__eu = [uri]$evict; $__evictShown = ($__eu.Scheme + '://' + $__eu.Host + $__eu.AbsolutePath) } catch { }
        Write-Warning (('Upstream list exceeds 8 entries; removed oldest custom entry: {0}' -f $__evictShown))
    }
    $replacement = ("upstream:`n" + (($list | ForEach-Object { "  - $_" }) -join "`n") + "`n")
    if ([string]$block.Style -eq 'flow') {
        # Flow-style single line: replace the whole line, still emit block-style.
        $flowPattern = '(?m)^upstream:\s*\[.*\]'
        $updated = ([regex]$flowPattern).Replace($normalized, $replacement.Replace('$', '$$'), 1)
    } else {
        $pattern = '(?ms)^upstream:\s*\n(?:^[ \t]*-[^\r\n]*\n?)+'
        $updated = ([regex]$pattern).Replace($normalized, $replacement.Replace('$', '$$'), 1)
        if ($updated -eq $normalized) {
            # Comment-first layouts (a `#` line right after `upstream:`) do
            # not match the dash-run pattern: splice by the parsed span.
            $rawLines = @($normalized -split "`n")
            $before = @()
            if ([int]$block.Start -gt 0) { $before = $rawLines[0..([int]$block.Start - 1)] }
            $after = @()
            if (([int]$block.End + 1) -lt $rawLines.Count) { $after = $rawLines[([int]$block.End + 1)..($rawLines.Count - 1)] }
            $updated = (($before + @($replacement.TrimEnd("`n"))) + $after) -join "`n"
            if (-not $updated.EndsWith("`n")) { $updated += "`n" }
        }
    }
    if ($newline -eq "`r`n") { $updated = $updated -replace "`n", "`r`n" }
    Set-Content -LiteralPath $script:ConfigFile -Value $updated -Encoding UTF8 -NoNewline
    $__upShown = '[redacted]'
    try { $__uu = [uri]$Upstream; $__upShown = ($__uu.Scheme + '://' + $__uu.Host + $__uu.AbsolutePath) } catch { }
    Write-Done (((T 'DoneUpstreamChanged') -f $__upShown))
}
function Set-SystemDns {
    param([string[]]$Servers = $null)
    Ensure-Administrator
    Test-Platform
    Write-Title (T 'DnsTitle')
    Write-Host ('  ' + (T 'DnsIntro1'))
    Write-Host ('  ' + (T 'DnsIntro2'))
    Write-Host ''

    $v4 = @()
    $v6 = @()
    if ($null -eq $Servers) {
        $primary = Read-Host (T 'DnsPrimary')
        if ([string]::IsNullOrWhiteSpace($primary)) {
            throw (T 'DnsPrimaryReq')
        }

        try {
            $parsedPrimary = [System.Net.IPAddress]::Parse($primary.Trim())
            if ($parsedPrimary.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                throw 'IPv4 address required.'
            }
        } catch {
            throw ((T 'DnsBadV4') + $primary)
        }

        $secondary = Read-Host (T 'DnsSecondary')
        $v4 = @($primary.Trim())

        if (-not [string]::IsNullOrWhiteSpace($secondary)) {
            try {
                $parsedSecondary = [System.Net.IPAddress]::Parse($secondary.Trim())
                if ($parsedSecondary.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    throw 'IPv4 address required.'
                }
            } catch {
                throw ((T 'DnsBadV4') + $secondary)
            }
            $v4 += $secondary.Trim()
        }

        $ipv6 = Read-Host (T 'DnsV6')
        if (-not [string]::IsNullOrWhiteSpace($ipv6)) {
            try {
                $parsedIPv6 = [System.Net.IPAddress]::Parse($ipv6.Trim())
                if ($parsedIPv6.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                    throw 'IPv6 address required.'
                }
            } catch {
                throw ((T 'DnsBadV6') + $ipv6)
            }
            $v6 += $ipv6.Trim()

            $ipv6Secondary = Read-Host (T 'DnsV6Sec')
            if (-not [string]::IsNullOrWhiteSpace($ipv6Secondary)) {
                try {
                    $parsedIPv6Secondary = [System.Net.IPAddress]::Parse($ipv6Secondary.Trim())
                    if ($parsedIPv6Secondary.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                        throw 'IPv6 address required.'
                    }
                } catch {
                    throw ((T 'DnsBadV6') + $ipv6Secondary)
                }
                $v6 += $ipv6Secondary.Trim()
            }
        }
    } else {
        if ($Servers.Count -lt 1 -or $Servers.Count -gt 4) {
            throw 'setDns requires 1 to 4 addresses.'
        }
        foreach ($server in $Servers) {
            $text = [string]$server
            if ([string]::IsNullOrWhiteSpace($text)) {
                throw 'setDns requires non-empty addresses.'
            }
            try {
                $parsed = [System.Net.IPAddress]::Parse($text.Trim())
            } catch {
                throw ((T 'DnsBadV4') + $text)
            }
            if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $v4 += $text.Trim()
            } elseif ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                $v6 += $text.Trim()
            } else {
                throw ((T 'DnsBadV4') + $text)
            }
        }
    }

    Enter-InstallerMutex
    try {
    $adapters = @(Get-NetworkAdapters -IncludeVirtual)
    if ($adapters.Count -eq 0) {
        throw (T 'NoAdapters')
    }

    Write-Step (T 'DnsApplying')
    $applied = @()
    foreach ($adapter in $adapters) {
        Write-Host (('  ' + (T 'LbAdapter') + ': ' + $adapter.Name)) -ForegroundColor DarkGray
        $snapshot = $null
        try { $snapshot = Get-AdapterDnsSnapshot $adapter.ifIndex } catch { Write-Warning ('Could not snapshot DNS on adapter ''' + $adapter.Name + ''': ' + $_.Exception.Message) }
        try {
            Set-AdapterDnsBoth $adapter.Name $v4 $v6
        } catch {
            foreach ($done in $applied) {
                try { Restore-AdapterDnsSnapshot $done.Name $done.Snapshot } catch { Write-Warning ('Could not restore DNS on adapter ''' + $done.Name + ''': ' + $_.Exception.Message) }
            }
            throw
        }
        $applied += @{ Name = $adapter.Name; Snapshot = $snapshot }
    }

    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null

    Write-Done ((T 'DnsDoneV4') + ($v4 -join ', '))
    if ($v6.Count -gt 0) {
        Write-Done ((T 'DnsDoneV6') + ($v6 -join ', '))
    } else {
        Write-Done (T 'DnsDoneDhcp')
    }
    } finally {
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Set-SystemDns: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Get-StateReleases {
    $dns = 'Unknown'
    $zap = 'Unknown'
    if (Test-Path $script:StateFile) {
        try {
            $s = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            if ($s.DnsProxyRelease) { $dns = [string]$s.DnsProxyRelease }
            if ($s.ZapretRelease) { $zap = [string]$s.ZapretRelease }
        } catch { Write-Warning ('SEDG:Get-StateReleases: $s = Get-Content -LiteralPath $script:StateFile -Raw | Conve... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
    return @($dns, $zap)
}

function Restart-DnsProxyService([string]$FailMessage) {
    Start-Service -Name $script:DnsProxyService -ErrorAction Stop
    Start-Sleep -Seconds 2
    $service = Get-Service -Name $script:DnsProxyService -ErrorAction Stop
    if ($service.Status -ne 'Running') { throw $FailMessage }
    Test-DnsProxyListeners
}

function Set-Upstream([string]$SelectedUpstream = $null, [switch]$ResetDefaults) {
    Ensure-Administrator
    Test-Platform
    if (-not (Test-Path $script:InstallPath)) { throw (T 'NotFound') }
    $resetDefaults = [bool]$ResetDefaults

    if ((-not $resetDefaults) -and [string]::IsNullOrWhiteSpace($SelectedUpstream)) {
        Write-Title (T 'UpTitle')
        $presetNames = @($script:OptionalUpstreams.Keys)
        for ($i = 0; $i -lt $presetNames.Count; $i++) {
            $upLog = '[redacted]'
            try { $upUri = [uri]$script:OptionalUpstreams[$presetNames[$i]]; $upLog = ($upUri.Host + $upUri.AbsolutePath) } catch { Write-Verbose $_ }
            Write-Host ('  [{0}] {1} - {2}' -f ($i + 1), $presetNames[$i], $upLog)
        }
        $customIndex = $presetNames.Count + 1
        Write-Host ('  [{0}] {1}' -f $customIndex, (T 'UpOpt2'))
        $resetIndex = $presetNames.Count + 2
        Write-Host ('  [{0}] {1}' -f $resetIndex, (T 'UpOptReset'))
        Write-Host ''
        $choice = Read-Host (T 'UpSelect')
        $choiceNum = 0
        if ([int]::TryParse([string]$choice, [ref]$choiceNum) -and $choiceNum -ge 1 -and $choiceNum -le $presetNames.Count) {
            $SelectedUpstream = $script:OptionalUpstreams[$presetNames[$choiceNum - 1]]
        } elseif ([string]$choice.Trim() -eq [string]$customIndex) {
            $SelectedUpstream = Read-Host (T 'UpEnter')
        } elseif ([string]$choice.Trim() -eq [string]$resetIndex) {
            $resetDefaults = $true
        } else {
            throw (T 'UpInvalid')
        }
    }

    if ((-not $resetDefaults) -and (-not (Test-DnsUpstream $SelectedUpstream))) {
        throw (T 'UpBad')
    }

    Enter-InstallerMutex
    try {
    Write-Step (T 'UpChanging')
    Stop-Service -Name $script:DnsProxyService -Force -ErrorAction SilentlyContinue
    try {
        if ($resetDefaults) { Write-OriginalConfigTemplate; $SelectedUpstream = Get-ConfiguredUpstream }
        else { Set-UpstreamInConfig $SelectedUpstream }
        $rel = Get-StateReleases
        Write-State $rel[0] $rel[1] $SelectedUpstream
    } catch {
        $origErr = $_.Exception.Message
        try { Restart-DnsProxyService 'DNSProxy did not remain running after upstream change.' } catch { Write-Warning ('SEDG:Set-Upstream: Restart-DnsProxyService ''DNSProxy did not remain running aft... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        throw $origErr
    }
    Restart-DnsProxyService 'DNSProxy did not remain running after upstream change.'
    $upLog = '[redacted]'
    try { $upUri = [uri]$SelectedUpstream; $upLog = ($upUri.Host + $upUri.AbsolutePath) } catch { Write-Verbose $_ }
    Write-Host ((T 'UpChanged') + $upLog) -ForegroundColor Green
    } finally {
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Set-Upstream: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Set-Language([string]$SelectedLang = $null) {
    if ([string]::IsNullOrWhiteSpace($SelectedLang)) {
        Write-Title (T 'LangTitle')
        Write-Host '  [1] English'
        Write-Host ('  [2] ' + (T 'LangOptV'))
        Write-Host ''
        $current = if ($script:Lang -eq 'VI') { T 'LangOptV' } else { T 'LangOptE' }
        Write-Host ('  ' + (T 'EdCurrent') + $current) -ForegroundColor DarkGray
        Write-Host ''
        $choice = Read-Host (T 'LangSelect')
        switch ($choice) {
            '1' { $SelectedLang = 'EN' }
            '2' { $SelectedLang = 'VI' }
            default { throw (T 'LangInvalid') }
        }
    }
    $SelectedLang = $SelectedLang.Trim().ToUpperInvariant()
    if ($SelectedLang -notin @('EN','VI')) { throw (T 'LangInvalid') }
    $script:Lang = $SelectedLang
    Save-Lang $script:Lang
    Write-Host (T 'LangDone') -ForegroundColor Green
}

function Write-Blacklist {
    Write-Step 'Checking Zapret blacklist...'
    Write-Host (('  ' + (T 'LbFile') + ': ' + $script:BlacklistFile)) -ForegroundColor DarkGray
    New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
    if (-not (Test-Path $script:BlacklistFile)) {
        # UTF-8 without BOM (winws chokes on a BOM).
        $lines = @(
            '# One hostname per line.',
            '# Preserved across component updates.',
            '# Default list.',
            'pornhub.com',
            'www.pornhub.com',
            'vn.linkedin.com',
            'medium.com',
            'bilibili.tv',
            'www.bilibili.tv',
            'www.bbc.com',
            'bbc.com',
            'www.bbc.co.uk',
            'bbc.co.uk',
            'steamcommunity.com',
            'www.steamcommunity.com',
            'steampowered.com',
            'www.steampowered.com',
            'store.steampowered.com',
            'help.steampowered.com',
            'steamusercontent.com',
            'community.fastly.steamstatic.com',
            'images.steamusercontent.com',
            'api.steampowered.com',
            'steamstatic.com',
            'rsload.net',
            'www.xvideos.com',
            'xvideos.com',
            'nyaa.si',
            'lrepacks.net',
            'voa.gov',
            'rfa.org',
            'amnesty.org',
            'pastebin.com',
            'paste.ee',
            'xnxx.com',
            'xhamster.com',
            'javhd.today',
            'javhd.com',
            'spankbang.com',
            'xvideos2.com',
            'xvideos3.com',
            'javmost.com',
            'beeg.com',
            'sextop1.net',
            'sextop1.sale',
            'youporn.com',
            'www.wattpad.com',
            'mangadex.org',
            'fitgirl-repacks.site',
            'voatiengviet.com',
            'voz.vn'
        )
        [IO.File]::WriteAllLines($script:BlacklistFile, $lines, [Text.UTF8Encoding]::new($false))
    }
    Write-Done 'zapret blacklist ready.'
}

function Get-DefaultWinwsArgs {
    $tpl = [string]$script:DefaultWinwsArgsTemplate
    if ([string]::IsNullOrWhiteSpace($tpl)) {
        $tpl = '--wf-tcp=80,443 --wf-udp=443 --hostlist="{0}" --dpi-desync=fake,disorder2 --dpi-desync-fooling=badseq --dpi-desync-repeats=6'
    }
    $listPath = 'blacklist.txt'
    try { $listPath = Join-Path $script:ZapretPath 'blacklist.txt' } catch { Write-Warning ('SEDG:Get-DefaultWinwsArgs: $listPath = Join-Path $script:ZapretPath ''blacklist.txt'' (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    if ([string]::IsNullOrWhiteSpace([string]$listPath)) { $listPath = 'blacklist.txt' }
    return ($tpl -f $listPath)
}

function Get-WinwsParameters {
    # The file wins; the built-in default below only applies when it is
    # missing or has no effective line.
    try {
        if (Test-Path -LiteralPath $script:WinwsArgsFile -PathType Leaf) {
            $line = @(Get-Content -LiteralPath $script:WinwsArgsFile -ErrorAction Stop |
                ForEach-Object { [string]$_ } |
                Where-Object { $_.Trim() -and ($_.TrimStart() -notlike '#*') } |
                Select-Object -First 1)
            if ($line.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($line[0])) {
                return $line[0].Trim()
            }
        }
    } catch { Write-Warning ('SEDG:Get-WinwsParameters: if (Test-Path -LiteralPath $script:WinwsArgsFile -PathType L... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    return (Get-DefaultWinwsArgs)
}

function Write-WinwsArgs {
    Write-Step 'Checking Zapret arguments...'
    Write-Host (('  ' + (T 'LbFile') + ': ' + $script:WinwsArgsFile)) -ForegroundColor DarkGray
    New-Item -ItemType Directory -Path $script:ZapretPath -Force | Out-Null
    if (-not (Test-Path $script:WinwsArgsFile)) {
        $list = Join-Path $script:ZapretPath 'blacklist.txt'
        $lines = @(
            '# winws arguments: exactly one effective (non-comment) line.',
            '# This file is preserved across component updates.',
            (Get-DefaultWinwsArgs),
            '# Alternatives (replace the line above, keep a single line):',
            ('# TLS-focused: --wf-tcp=443 --hostlist="' + $list + '" --dpi-desync=fake --dpi-desync-fooling=badseq'),
            ('# QUIC/UDP-focused: --wf-udp=443 --hostlist="' + $list + '" --dpi-desync=fake --dpi-desync-repeats=6'),
            '# See https://github.com/bol-van/zapret for strategy details.'
        )
        [IO.File]::WriteAllLines($script:WinwsArgsFile, $lines, [Text.UTF8Encoding]::new($false))
    }
    Write-Done 'zapret arguments ready.'
}

function Write-WatchdogFile {
    # Standalone watchdog: must not dot-source the installer (it executes on
    # load). Covers the gateway-enabled flag, new adapters, 1-minute cadence.
    # Boot fix: restarts stopped gateway services before the DNS health
    # check, otherwise a Stopped dnsproxy + static 127.0.0.1 DNS looks like
    # no network until a manual Resume.
    $template = @'
#requires -Version 5.1
# SEDG DNS watchdog - generated by the installer. Do not edit by hand.
$ErrorActionPreference = 'Stop'
$InstallPath = '%%INSTALLPATH%%'
$StateFile = Join-Path $InstallPath 'state.json'
$FlagFile = Join-Path $InstallPath 'watchdog-fallback.flag'
$CountFile = Join-Path $InstallPath 'watchdog-count.txt'
$EnabledFile = Join-Path $InstallPath 'gateway-enabled'
$FailClosedFile = Join-Path $InstallPath 'fail-closed'
$WinwsService = '%%WINWSSERVICE%%'
$DnsProxyService = '%%DNSPROXYSERVICE%%'

# Single-instance guard: reuse the installer mutex so two watchdog ticks (or
# a tick racing Install/Update) never double-count failures. The handle dies
# with this process; an abandoned hold is treated as acquired.
$WatchdogMutex = $null
$WatchdogAcquired = $true
try {
    $WatchdogMutex = New-Object System.Threading.Mutex($false, 'Global\SEDG-Installer')
    try { $WatchdogAcquired = $WatchdogMutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $WatchdogAcquired = $true }
} catch { $WatchdogAcquired = $true }
if (-not $WatchdogAcquired) { exit 0 }

function Get-UpAdapters {
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' }
}

function Get-GatewayAdapters {
    foreach ($a in @(Get-UpAdapters)) {
        try {
            $all = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction Stop |
                Select-Object -ExpandProperty ServerAddresses)
            if (($all -contains '127.0.0.1') -or ($all -contains '::1')) { $a }
        } catch { Write-Warning ('SEDG:Get-GatewayAdapters: $all = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifInd... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Set-DnsDhcp($AdapterName) {
    & netsh.exe interface ipv4 set dnsservers "name=$AdapterName" source=dhcp validate=no 2>$null | Out-Null
    & netsh.exe interface ipv6 set dnsservers "name=$AdapterName" source=dhcp validate=no 2>$null | Out-Null
}

function Set-DnsLocal($AdapterName, [int]$IfIndex) {
    try {
        Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses @('127.0.0.1', '::1') -ErrorAction Stop
    } catch {
        try { Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses @('127.0.0.1') -ErrorAction Stop } catch { Write-Warning ('SEDG:Set-DnsLocal: Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerA... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { & netsh.exe interface ipv6 set dnsservers "name=$AdapterName" source=dhcp validate=no 2>$null | Out-Null } catch { Write-Warning ('SEDG:Set-DnsLocal: & netsh.exe interface ipv6 set dnsservers "name=$AdapterName... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Reset-ResolverCache {
    try { Clear-DnsClientCache } catch { Write-Warning ('SEDG:Reset-ResolverCache: Clear-DnsClientCache (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try { ipconfig /flushdns 2>$null | Out-Null } catch { Write-Warning ('SEDG:Reset-ResolverCache: ipconfig /flushdns 2>$null | Out-Null (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

if (-not (Test-Path -LiteralPath $EnabledFile -PathType Leaf)) { exit 0 }
$inUse = @(Get-GatewayAdapters).Count -gt 0
$failedOver = Test-Path -LiteralPath $FlagFile -PathType Leaf
if ((-not $inUse) -and (-not $failedOver)) { exit 0 }

# Self-heal stopped services first (common after reboot). Best-effort,
# never throw here. Respects -DnsOnly installs: winws is Manual there,
# so only auto-start services whose StartType is Automatic.
$restarted = $false
foreach ($svcName in @($WinwsService, $DnsProxyService)) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -ne 'Running')) {
            $auto = $true
            try { $auto = ($svc.StartType -eq 'Automatic') } catch { Write-Warning ('SEDG:Watchdog: $auto = ($svc.StartType -eq ''Automatic'') (' + $_.Exception.Message + ')'); Write-Verbose $_ }
            if ($auto) {
                try { Start-Service -Name $svcName -ErrorAction Stop } catch { Write-Warning ('SEDG:Watchdog: Start-Service -Name $svcName -ErrorAction Stop (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                $restarted = $true
            }
        }
    } catch { Write-Warning ('SEDG:Watchdog: $svc = Get-Service -Name $svcName -ErrorAction SilentlyConti... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}
if ($restarted) { try { Start-Sleep -Seconds 10 } catch { Write-Warning ('SEDG:Watchdog: Start-Sleep -Seconds 10 (' + $_.Exception.Message + ')'); Write-Verbose $_ } }

$upstreamHost = $null
try {
    if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
        $u = [string](Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json).Upstream
        $upstreamHost = ([uri]$u).Host
    }
} catch { Write-Warning ('SEDG:Watchdog: if (Test-Path -LiteralPath $StateFile -PathType Leaf) { $u =... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
$targets = @()
if (-not [string]::IsNullOrWhiteSpace($upstreamHost)) { $targets += $upstreamHost }
$targets += @('dns.google', 'one.one.one.one')
$targets = @($targets | Select-Object -Unique)

$healthy = $false
foreach ($t in $targets) {
    try {
        $r = Resolve-DnsName -Name $t -Server 127.0.0.1 -DnsOnly -QuickTimeout -ErrorAction Stop
        if ($r) { $healthy = $true; break }
    } catch { Write-Warning ('SEDG:Watchdog: $r = Resolve-DnsName -Name $t -Server 127.0.0.1 -DnsOnly -Qu... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

if ($healthy) {
    try { Remove-Item -LiteralPath $CountFile -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Watchdog: Remove-Item -LiteralPath $CountFile -Force -ErrorAction Sile... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    if ($failedOver) {
        foreach ($a in @(Get-UpAdapters)) {
            Set-DnsLocal $a.Name $a.ifIndex
        }
        Reset-ResolverCache
        try { Remove-Item -LiteralPath $FlagFile -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Watchdog: Remove-Item -LiteralPath $FlagFile -Force -ErrorAction Silen... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    } else {
        foreach ($a in @(Get-UpAdapters)) {
            try {
                $all = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction Stop | Select-Object -ExpandProperty ServerAddresses)
                if (($all -contains '127.0.0.1') -or ($all -contains '::1')) { continue }
                if ($all.Count -eq 0) { Set-DnsLocal $a.Name $a.ifIndex }
            } catch { Write-Warning ('SEDG:Watchdog: $all = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifInd... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        }
    }
    exit 0
}

$n = 0
try { $n = [int](Get-Content -LiteralPath $CountFile -Raw -ErrorAction Stop) } catch { Write-Warning ('SEDG:Watchdog: $n = [int](Get-Content -LiteralPath $CountFile -Raw -ErrorAc... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
$n++
# Atomic counter: temp+rename so a killed tick never leaves a half-written count.
$CountTmp = "$CountFile.tmp"
try { $n | Set-Content -LiteralPath $CountTmp -Encoding ASCII -NoNewline -Force; Move-Item -LiteralPath $CountTmp -Destination $CountFile -Force } catch { Write-Warning ('SEDG:Watchdog: $n | Set-Content -LiteralPath $CountFile -Encoding ASCII -No... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
if ($n -ge 3) {
    # M6 fail-closed: with the marker present the gateway stays on local DNS
    # (no traffic leaks to the ISP) instead of falling back to DHCP.
    if (-not (Test-Path -LiteralPath $FailClosedFile -PathType Leaf)) {
        foreach ($a in @(Get-GatewayAdapters)) {
            Set-DnsDhcp $a.Name
        }
        Reset-ResolverCache
        try { 'fallback' | Set-Content -LiteralPath $FlagFile -Encoding ASCII -NoNewline -Force } catch { Write-Warning ('SEDG:Watchdog: ''fallback'' | Set-Content -LiteralPath $FlagFile -Encoding AS... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}
exit 0
'@
    $content = $template.Replace('%%INSTALLPATH%%', $script:InstallPath).Replace('%%WINWSSERVICE%%', $script:WinwsService).Replace('%%DNSPROXYSERVICE%%', $script:DnsProxyService)
    [IO.File]::WriteAllText($script:WatchdogScript, $content, [Text.UTF8Encoding]::new($false))
}

function Clear-WatchdogState {
    foreach ($f in @($script:WatchdogFlag, $script:WatchdogCount)) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Clear-WatchdogState: Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyCont... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Set-GatewayEnabled([bool]$Enabled) {
    try {
        if ($Enabled) { 'enabled' | Set-Content -LiteralPath $script:GatewayFlag -Encoding ASCII -NoNewline -Force }
        else { Remove-Item -LiteralPath $script:GatewayFlag -Force -ErrorAction SilentlyContinue }
    } catch { Write-Warning ('SEDG:Set-GatewayEnabled: if ($Enabled) { ''enabled'' | Set-Content -LiteralPath $script... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

function Install-Watchdog {
    param([switch]$FailClosed)
    Write-Step 'Installing DNS watchdog...'
    Write-WatchdogFile
    Clear-WatchdogState
    # -FailClosed is sticky across Install/Update (never auto-downgraded).
    # Delete the marker file (or Uninstall) to return to DHCP fallback.
    if ($FailClosed) {
        try { 'fail-closed' | Set-Content -LiteralPath $script:FailClosedFile -Encoding ASCII -NoNewline -Force } catch { Write-Warning ('SEDG:Install-Watchdog: ''fail-closed'' | Set-Content -LiteralPath $script:FailClosedF... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $script:WatchdogScript + '"')
    # Boot fix: AtStartup heals the first minutes after reboot (when a
    # Stopped dnsproxy + static 127.0.0.1 looks like no network), plus a
    # 1-minute repetition so fallback happens after ~3 min, not ~9 min.
    $taskTriggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $script:WatchdogTask -Action $taskAction -Trigger $taskTriggers -Principal $taskPrincipal -Settings $taskSettings -Description 'SEDG DNS gateway watchdog: restarts gateway services and falls back to DHCP when 127.0.0.1 stops answering.' -Force -ErrorAction Stop | Out-Null
    $wdTask = Get-ScheduledTask -TaskName $script:WatchdogTask -ErrorAction Stop
    if ($wdTask.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $script:WatchdogTask -ErrorAction Stop | Out-Null
    }
    Write-Done 'DNS watchdog installed.'
}

function Invoke-Nssm([string[]]$Arguments) {
    $out = & $script:NssmPath @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("NSSM command failed (exit code {0}): {1}{2}{3}" -f $LASTEXITCODE, ($Arguments -join ' '), [Environment]::NewLine, $out.Trim())
    }
}

function Remove-Services {
    Write-Step 'Removing existing Windows services...'
    $errors = @()

    # F2: the watchdog task is independent of the services. Unregister it
    # first so a slow or failing service delete can never leave a SYSTEM task
    # behind. A missing task is already clean (idempotent).
    try {
        if (Get-ScheduledTask -TaskName $script:WatchdogTask -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $script:WatchdogTask -Confirm:$false -ErrorAction Stop
        }
    } catch {
        $errors += ("Failed to unregister scheduled task '{0}': {1}" -f $script:WatchdogTask, $_.Exception.Message)
    }

    foreach ($name in @($script:WinwsService, $script:DnsProxyService)) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) { continue }

        try {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        } catch { Write-Warning ('SEDG:Remove-Services: Stop-Service -Name $name -Force -ErrorAction SilentlyContinu... (' + $_.Exception.Message + ')'); Write-Verbose $_ }

        # NSSM owns these services. Use NSSM removal when the pinned binary
        # is available; fall back to sc.exe for recovery/partial installs.
        $removed = $false
        if (Test-Path -LiteralPath $script:NssmPath) {
            try {
                & $script:NssmPath remove $name confirm 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $removed = $true }
            } catch { Write-Warning ('SEDG:Remove-Services: & $script:NssmPath remove $name confirm 2>$null | Out-Null i... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        }

        if (-not $removed) {
            try { & sc.exe delete $name 2>$null | Out-Null } catch { $errors += ("Failed to delete service '{0}': {1}" -f $name, $_.Exception.Message) }
        }
    }

    $deadline = (Get-Date).AddSeconds(10)
    do {
        $remaining = @(
            $script:WinwsService,
            $script:DnsProxyService
        ) | ForEach-Object {
            Get-Service -Name $_ -ErrorAction SilentlyContinue
        }

        if (@($remaining).Count -eq 0) { break }

        # A service can remain in "DeletePending" briefly after sc.exe/NSSM
        # removes it. Wait rather than immediately attempting to recreate it.
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if (@($remaining).Count -gt 0) {
        $names = @($remaining | ForEach-Object { $_.Name }) -join ', '
        $errors += "Timed out waiting for services to be removed: $names"
    }

    if ($errors.Count -gt 0) { throw ($errors -join ' ') }

    Write-Done 'Existing Windows services removed.'
}

function Create-Services {
    param([switch]$DnsOnly)
    Write-Step 'Creating and configuring Windows services...'
    Remove-Services

    $winwsExe = Join-Path $script:ZapretPath 'winws.exe'
    $dnsExe = Join-Path $script:DnsProxyPath 'dnsproxy.exe'

    if (-not (Test-Path $winwsExe)) { throw 'winws.exe is missing.' }
    if (-not (Test-Path $dnsExe)) { throw 'dnsproxy.exe is missing.' }
    if (-not (Test-Path $script:NssmPath)) { throw 'nssm.exe is missing.' }

    Invoke-Nssm @('install', $script:WinwsService, $winwsExe)
    Invoke-Nssm @('set', $script:WinwsService, 'AppDirectory', $script:ZapretPath)
    Invoke-Nssm @('set', $script:WinwsService, 'AppParameters', (Get-WinwsParameters))
    Invoke-Nssm @('set', $script:WinwsService, 'DisplayName', 'Zapret WinWS DPI Bypass')
    Invoke-Nssm @('set', $script:WinwsService, 'AppStdout', (Join-Path $script:ZapretPath 'winws.log'))
    Invoke-Nssm @('set', $script:WinwsService, 'AppStderr', (Join-Path $script:ZapretPath 'winws.log'))
    Invoke-Nssm @('set', $script:WinwsService, 'AppRotateFiles', '1')
    Invoke-Nssm @('set', $script:WinwsService, 'AppRotateOnline', '1')
    Invoke-Nssm @('set', $script:WinwsService, 'AppRotateBytes', '1048576')
    if (-not $DnsOnly) {
        Invoke-Nssm @('set', $script:WinwsService, 'Start', 'SERVICE_AUTO_START')
    } else {
        Invoke-Nssm @('set', $script:WinwsService, 'Start', 'SERVICE_DEMAND_START')
    }
    sc.exe config $script:WinwsService depend= Tcpip 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to configure dependency for $($script:WinwsService)." }

    Invoke-Nssm @('install', $script:DnsProxyService, $dnsExe)
    Invoke-Nssm @('set', $script:DnsProxyService, 'AppDirectory', $script:DnsProxyPath)
    Invoke-Nssm @('set', $script:DnsProxyService, 'AppParameters', '--config-path=config.yaml --output=dnsproxy.log')
    Invoke-Nssm @('set', $script:DnsProxyService, 'DisplayName', 'DNSProxy DoH Service')
    Invoke-Nssm @('set', $script:DnsProxyService, 'AppStdout', (Join-Path $script:DnsProxyPath 'dnsproxy-nssm.log'))
    Invoke-Nssm @('set', $script:DnsProxyService, 'AppStderr', (Join-Path $script:DnsProxyPath 'dnsproxy-nssm.log'))
    Invoke-Nssm @('set', $script:DnsProxyService, 'AppRotateFiles', '1')
    Invoke-Nssm @('set', $script:DnsProxyService, 'AppRotateOnline', '1')
    Invoke-Nssm @('set', $script:DnsProxyService, 'AppRotateBytes', '1048576')
    Invoke-Nssm @('set', $script:DnsProxyService, 'Start', 'SERVICE_AUTO_START')
    # dnsproxy must survive a winws driver failure (HVCI/AV): no hard
    # dependency. Immediate auto-start (not delayed-auto): with static
    # 127.0.0.1 DNS, every delayed minute looks like no network after
    # boot. Early crashes self-heal via NSSM AppExit/SCM recovery below.
    sc.exe config $script:DnsProxyService depend= Tcpip 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to configure dependency for $($script:DnsProxyService)." }
    try {
        sc.exe config $script:DnsProxyService start= auto 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning ("sc.exe could not set the start type for $($script:DnsProxyService) (exit code $LASTEXITCODE); NSSM already configured SERVICE_AUTO_START.") }
    } catch { Write-Warning ('SEDG:Create-Services: sc.exe config $script:DnsProxyService start= auto 2>$null | ... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    # M10: least privilege. dnsproxy only binds 127.0.0.1:53, so prefer
    # LocalService; fall back to SYSTEM when the host refuses.
    # Boot fix: the install dir is admin-only (SYSTEM+Admin), so grant
    # LocalService traverse on the parent first, otherwise the service
    # binary/config is unreadable at boot and dnsproxy stays Stopped
    # while adapters still point at 127.0.0.1 (looks like no network).
    try {
        & icacls.exe $script:InstallPath /grant '*S-1-5-19:(OI)(CI)RX' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls could not grant LocalService read access on $($script:InstallPath) (exit code $LASTEXITCODE)." }
        $dnsLogFile = Join-Path $script:DnsProxyPath 'dnsproxy.log'
        try { if (-not (Test-Path -LiteralPath $dnsLogFile -PathType Leaf)) { New-Item -ItemType File -Path $dnsLogFile -Force | Out-Null } } catch { Write-Warning ('SEDG:Create-Services: if (-not (Test-Path -LiteralPath $dnsLogFile -PathType Leaf)) { New... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        & icacls.exe $dnsLogFile /grant '*S-1-5-19:M' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls could not grant LocalService modify access on $($dnsLogFile) (exit code $LASTEXITCODE)." }
        Invoke-Nssm @('set', $script:DnsProxyService, 'ObjectName', 'NT AUTHORITY\LocalService', '')
    } catch { Write-Warning ('SEDG:Create-Services: & icacls.exe $script:InstallPath /grant ''*S-1-5-19:(OI)(CI)R... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    # Boot resilience: restart the wrapper when the app exits early
    # (port race, network not ready). Without this SCM leaves the
    # service Stopped after reboot and DNS 127.0.0.1 goes dark.
    foreach ($svcName in @($script:WinwsService, $script:DnsProxyService)) {
        try { Invoke-Nssm @('set', $svcName, 'AppExit', 'Default', 'Restart') } catch { Write-Warning ('SEDG:Create-Services: Invoke-Nssm @(''set'', $svcName, ''AppExit'', ''Default'', ''Restar... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Invoke-Nssm @('set', $svcName, 'AppRestartDelay', '5000') } catch { Write-Warning ('SEDG:Create-Services: Invoke-Nssm @(''set'', $svcName, ''AppRestartDelay'', ''5000'') (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Invoke-Nssm @('set', $svcName, 'AppThrottle', '5000') } catch { Write-Warning ('SEDG:Create-Services: Invoke-Nssm @(''set'', $svcName, ''AppThrottle'', ''5000'') (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { & sc.exe failure $svcName reset= 86400 actions= restart/5000/restart/10000/restart/30000 2>$null | Out-Null } catch { Write-Warning ('SEDG:Create-Services: & sc.exe failure $svcName reset= 86400 actions= restart/5000... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { & sc.exe failureflag $svcName 1 2>$null | Out-Null } catch { Write-Warning ('SEDG:Create-Services: & sc.exe failureflag $svcName 1 2>$null | Out-Null (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }

    foreach ($name in @($script:WinwsService, $script:DnsProxyService)) {
        if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) {
            throw "Failed to create service: $name"
        }
    }
    Write-Done 'Windows services configured.'
}

function Get-ManagerSourceContent {
    # Authoritative manager source (iex-safe): in-memory copy first, then the
    # on-disk script, then a hash-pinned re-download (network works here).
    if (-not [string]::IsNullOrWhiteSpace($script:SelfContent) -and ($script:SelfContent -match 'InstallerVersion')) {
        return $script:SelfContent
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:SelfPath) -and (Test-Path -LiteralPath $script:SelfPath -PathType Leaf)) {
            $fileContent = Get-Content -LiteralPath $script:SelfPath -Raw -ErrorAction Stop
            if ($fileContent -match 'InstallerVersion') { return $fileContent }
        }
    } catch { Write-Warning ('SEDG:Get-ManagerSourceContent: if (-not [string]::IsNullOrWhiteSpace($script:SelfPath) -and... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    $distBase = $script:Sources.Manifest -replace '/approved-releases\.json$', ''
    if ([string]::IsNullOrWhiteSpace($distBase)) { throw 'Cannot determine distribution base URL.' }
    $ver = Invoke-RestMethod -Uri ($distBase + '/version.json') -Headers @{ 'User-Agent' = 'Serverless-Edge-DNS-Gateway-Installer' } -TimeoutSec 30 -ErrorAction Stop
    $expectedHash = ([string]$ver.sha256).Trim().ToLowerInvariant()
    if ($expectedHash.Length -ne 64 -or $expectedHash -notmatch '^[0-9a-f]{64}$') { throw 'Distribution version.json has an invalid SHA-256.' }
    $tmpBase = $script:TempPath
    try { New-Item -ItemType Directory -Path $tmpBase -Force | Out-Null } catch { $tmpBase = $env:TEMP }
    $tmpSource = Join-Path $tmpBase ('serverless-edge-dns-gateway-source-{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
    try {
        Download-File ($distBase + '/installer.ps1') $tmpSource
        $actualHash = (Get-FileHash -LiteralPath $tmpSource -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw 'Downloaded installer SHA-256 does not match version.json.' }
        return (Get-Content -LiteralPath $tmpSource -Raw -ErrorAction Stop)
    } finally {
        Remove-Item -LiteralPath $tmpSource -Force -ErrorAction SilentlyContinue
    }
}

function Write-Manager {
    Write-Step 'Installing local manager scripts...'
    $managerPath = Join-Path $script:InstallPath 'manager.ps1'
    $sourcePath = ''
    $targetPath = ''
    try { $sourcePath = [System.IO.Path]::GetFullPath($script:SelfPath) } catch { $sourcePath = [string]$script:SelfPath }
    try { $targetPath = [System.IO.Path]::GetFullPath($managerPath) } catch { $targetPath = [string]$managerPath }
    $sameFile = (-not [string]::IsNullOrWhiteSpace($sourcePath)) -and [string]::Equals($sourcePath, $targetPath, [System.StringComparison]::OrdinalIgnoreCase)

    # Reinstall wipes a running manager.ps1 too; restore from memory or a
    # hash-verified download (self-copy throws on PS 5.1).
    if ((-not $sameFile) -or (-not (Test-Path -LiteralPath $managerPath -PathType Leaf))) {
        $sourceContent = Get-ManagerSourceContent
        New-Item -ItemType Directory -Path $script:InstallPath -Force | Out-Null
        [IO.File]::WriteAllText($managerPath, $sourceContent, [Text.UTF8Encoding]::new($false))
    }

    @'
@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~dp0Gateway-Manager.bat' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manager.ps1"
'@ | Set-Content -Path (Join-Path $script:InstallPath 'Gateway-Manager.bat') -Encoding ASCII

    # Legacy launchers from earlier versions: a single entry point is enough now.
    foreach ($legacy in @('manager.bat', 'restart.bat', 'uninstall.bat')) {
        $legacyPath = Join-Path $script:InstallPath $legacy
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-DnsProxyListeners {
    Write-Step 'Verifying DNSProxy IPv4 listeners...'
    $deadline = (Get-Date).AddSeconds(10)
    while ($true) {
        $udp = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue)
        $tcp = @(Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue)
        $udpOk = ($udp | Where-Object { [string]$_.LocalAddress -eq '127.0.0.1' })
        $tcpOk = ($tcp | Where-Object { [string]$_.LocalAddress -eq '127.0.0.1' })
        if ($udpOk -and $tcpOk) { break }
        if ((Get-Date) -ge $deadline) {
            Log-Port53Owner
            if (-not $udpOk) { throw 'DNSProxy is not listening on UDP 127.0.0.1:53.' }
            throw 'DNSProxy is not listening on TCP 127.0.0.1:53.'
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Done 'DNSProxy is listening on UDP/TCP 127.0.0.1:53.'
    try {
        $udp6 = @($udp | Where-Object { [string]$_.LocalAddress -eq '::1' })
        $tcp6 = @($tcp | Where-Object { [string]$_.LocalAddress -eq '::1' })
        if (-not ($udp6 -and $tcp6)) {
            $requiresV6 = $false
            try {
                if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
                    $requiresV6 = [bool]((Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop) -match '(?m)^\s*-\s*::1\s*$')
                }
            } catch { Write-Verbose $_ }
            if ($requiresV6) { throw 'DNSProxy is not listening on ::1:53 but the config requires it.' }
            Write-Host (('  ' + (Get-ViInfo 'Local DNS IPv6 ::1: not listening.'))) -ForegroundColor Yellow
        }
    } catch {
        if ($_.Exception.Message -match 'not listening on ::1:53 but the config requires it') { throw }
        Write-Warning ('SEDG:Test-DnsProxyListeners: $udp6 = @($udp | Where-Object { [string]$_.LocalAddress -eq ... (' + $_.Exception.Message + ')'); Write-Verbose $_
    }
}
function Write-State([string]$DnsProxyRelease, [string]$ZapretRelease, [string]$Upstream = $null, [string[]]$UpstreamList = $null) {
    if ([string]::IsNullOrWhiteSpace($Upstream)) { $Upstream = Get-ConfiguredUpstream }
    if ($null -eq $UpstreamList) { $UpstreamList = @(Get-UpstreamList) }
    $__redact = { param([string]$u) $r = '[redacted]'; try { $x = [uri]$u; $r = ($x.Scheme + '://' + $x.Host + $x.AbsolutePath) } catch { }; return $r }
    $state = [ordered]@{
        InstallerVersion  = $script:InstallerVersion
        DnsProxyRelease   = if ($DnsProxyRelease) { $DnsProxyRelease } else { 'Unknown' }
        ZapretRelease     = if ($ZapretRelease) { $ZapretRelease } else { 'Unknown' }
        Upstream          = (& $__redact $Upstream)
        Updated           = (Get-Date).ToUniversalTime().ToString('o')
    }
    # Additive: old readers ignore unknown fields; omit when empty.
    # F10: state keeps the redacted upstream only; the full URL (with any
    # ?token=) lives in config.yaml alone.
    if (@($UpstreamList).Count -gt 0) { $state['upstream_list'] = @(@($UpstreamList) | ForEach-Object { & $__redact ([string]$_) }) }

    $json = $state | ConvertTo-Json -Depth 3
    $json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Remove-InstallDirectoryCleanly([string]$Path, [switch]$AllowSchedule) {
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    } catch { Write-Warning ('SEDG:Remove-InstallDirectoryCleanly: Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction ... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    # H3: schedule-on-reboot is only allowed for Uninstall. Install/Update must
    # fail loudly so a new driver is never deleted by a pending reboot entry.
    if (-not $AllowSchedule) {
        throw 'Install directory is locked (likely WinDivert64.sys in use). Reboot Windows, then retry. No reboot-deletion was scheduled.'
    }
    # Full removal blocked, almost always by a locked WinDivert64.sys.
    # Schedule locked drivers for reboot removal and clear everything else
    # so a fresh install can proceed without aborting mid-delete.
    Write-Host (('  ' + (T 'WarnDirBlocked'))) -ForegroundColor Yellow
    try { Schedule-DeleteOnReboot (Join-Path $script:ZapretPath 'WinDivert64.sys') } catch { Write-Warning ('SEDG:Remove-InstallDirectoryCleanly: Schedule-DeleteOnReboot (Join-Path $script:ZapretPath ''WinDi... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $item = $_
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            if ($item.FullName -like '*WinDivert*.sys') {
                try { Schedule-DeleteOnReboot $item.FullName } catch { Write-Warning ('SEDG:Remove-InstallDirectoryCleanly: Schedule-DeleteOnReboot $item.FullName (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                Write-Host (('  ' + ((T 'WarnDriverKept') -f $item.FullName))) -ForegroundColor Yellow
                Write-Host (('  ' + (T 'WarnRebootRequired'))) -ForegroundColor Yellow
            } else {
                throw
            }
        }
    }
}

function Test-OwnsProcessInvocation {
    # True for real script-file invocations (Gateway-Manager.bat, -File runs)
    # whose process the installer may end; false for irm|iex hosts it must
    # never kill (M5). OwnsProcessOverride exists for tests.
    if ($script:OwnsProcessOverride) { return $script:OwnsProcessOverride }
    return (-not [string]::IsNullOrEmpty($PSCommandPath))
}

function Wait-HandoffClosePrompt {
    # After a manager self-update: give the user a moment to read the closing
    # message before the console returns to the launcher. Skipped when input
    # is redirected (CI, pipes).
    if ([Console]::IsInputRedirected) { return }
    try { Read-Host '  Press Enter to close this window' | Out-Null } catch { Write-Verbose $_ }
}

function Update-ManagerFromDist([string]$ForAction) {
    # The protocol caller owns the process and expects exactly one result; the
    # manager self-update would print a handoff prompt and exit without one.
    if ($script:ProtocolMode) { return $false }
    # Self-update the local manager before Install/Update so an old manager
    # never fails the version check and destroys a working setup. After a
    # successful update the new manager is NOT re-execed in this console:
    # re-execing nests its menu inside the still-running Show-Menu loop,
    # whose prompts keep stealing stdin, so the menu never comes back
    # cleanly. Instead the message tells the user to start
    # Gateway-Manager.bat again, and script-file invocations end the process
    # here (irm|iex hosts cannot be killed, so those adopt the new version
    # in memory and get $true to stop their pending flow). $false = no
    # update happened, the caller continues.
    try {
        $distBase = $script:Sources.Manifest -replace '/approved-releases\.json$', ''
        if ([string]::IsNullOrWhiteSpace($distBase)) { return $false }
        $ver = Invoke-RestMethod -Uri ($distBase + '/version.json') -Headers @{ 'User-Agent' = 'Serverless-Edge-DNS-Gateway-Installer' } -TimeoutSec 15 -ErrorAction Stop
        $distVersion = [string]$ver.version
        $expectedHash = ([string]$ver.sha256).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($distVersion) -or ($distVersion -eq $script:InstallerVersion)) { return $false }
        if ($expectedHash.Length -ne 64 -or $expectedHash -notmatch '^[0-9a-f]{64}$') { return $false }

        Write-Step 'Updating local manager...'
        $tmpBase = $script:TempPath
        try { New-Item -ItemType Directory -Path $tmpBase -Force | Out-Null; Set-SecureAcl $tmpBase -AdminOnly } catch { $tmpBase = $env:TEMP }
        $tmpManager = Join-Path $tmpBase ('serverless-edge-dns-gateway-manager-{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
        Download-File ($distBase + '/installer.ps1') $tmpManager
        $actualHash = (Get-FileHash -LiteralPath $tmpManager -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw 'Downloaded manager SHA-256 does not match version.json.' }

        $managerPath = Join-Path $script:InstallPath 'manager.ps1'
        Copy-Item -LiteralPath $tmpManager -Destination $managerPath -Force -ErrorAction Stop
        $verifyHash = (Get-FileHash -LiteralPath $managerPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($verifyHash -ne $expectedHash) { throw 'Local manager copy failed SHA-256 re-verification.' }
        Remove-Item -LiteralPath $tmpManager -Force -ErrorAction SilentlyContinue
        Write-Done 'Local manager updated.'

        # Self-update done. Hand control back to the user: release our mutex
        # and transcript, adopt the dist version in-memory (so a later action
        # in this session stops self-updating and passes the manifest version
        # check), tell the user to reopen the launcher, and end a script-file
        # process here so the old Show-Menu loop cannot resume.
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Update-ManagerFromDist: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Stop-OpTranscript } catch { Write-Warning ('SEDG:Update-ManagerFromDist: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $script:InstallerMutex = $null; $script:MutexDepth = 0; $script:OpTranscript = $null
        $script:InstallerVersion = $distVersion
        Write-Host ''
        Write-Host (('  Manager updated to version {0}. Start Gateway-Manager.bat again, then run {1} again to continue.' -f $distVersion, $ForAction)) -ForegroundColor Yellow
        if (Test-OwnsProcessInvocation) {
            Wait-HandoffClosePrompt
            Exit-Installer 0
        }
        return $true
    } catch {
        Write-Host (('  Manager self-update skipped: ' + $_.Exception.Message)) -ForegroundColor Yellow
        return $false
    }
}

function Install-All {
    param([switch]$Clean, [switch]$DnsOnly, [switch]$FailClosed, [switch]$AllowSeam)
    Ensure-Administrator
    Test-Platform
    # The manager is replaced by a file swap that renames the running exe aside,
    # so an in-app update needs no "close it first" gate; a genuinely locked
    # file fails inside Install-CommitManager with a close-and-retry message.
    # F4: refuse to install over a tree that a pending reboot will delete
    # (scheduled by a previous Uninstall via MoveFileEx).
    if (Test-PendingRebootDelete $script:InstallPath) {
        throw 'A previous Uninstall scheduled the install directory for deletion at reboot. Reboot Windows first, then retry Install.'
    }
    Enter-InstallerMutex
    Start-OpTranscript 'Install'
    try {
    Write-CreditBanner
    Clear-StaleTempInstallers
    # H4: snapshot before any bootstrap DNS touches adapters.
    Backup-DnsSettings
    # H2: reinstall routes through the safer Update path unless -Clean.
    if ((Test-Path -LiteralPath $script:InstallPath) -and (-not $Clean)) {
        Write-Host '  Existing installation found; routing to Update path.' -ForegroundColor Yellow
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Install-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Stop-OpTranscript } catch { Write-Warning ('SEDG:Install-All: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $script:InstallerMutex = $null; $script:MutexDepth = 0; $script:OpTranscript = $null
        Update-All -Clean:$Clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam
        return
    }
    if (Update-ManagerFromDist 'Install') { return }
    Write-Title ('Serverless Edge DNS Gateway with Zapret DPI Bypass - Auto Installer - ' + (T 'MiInstall'))

    # Preflight: stage everything before touching the live system.
    # A staging failure aborts here while any existing setup keeps running.
    Write-Step 'Preparing fresh installation...'
    try {
        Set-InstallerBootstrapDns
        $staged = Install-StageComponents -AllowSeam:$AllowSeam
        if (-not $staged) { throw 'Component staging failed.' }
        # Downloads are done: restore the pre-bootstrap DNS snapshot now, so
        # the commit phase below runs on clean DNS even if it throws later.
        try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Install-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    } catch {
        try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Install-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        throw
    }

    $preserveDir = Join-Path $script:TempPath 'preserve'
    if (Test-Path -LiteralPath $preserveDir) {
        Remove-Item -LiteralPath $preserveDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $preserveDir -Force | Out-Null
    if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
        Copy-Item -LiteralPath $script:ConfigFile -Destination (Join-Path $preserveDir 'config.yaml') -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:BlacklistFile -PathType Leaf) {
        Copy-Item -LiteralPath $script:BlacklistFile -Destination (Join-Path $preserveDir 'blacklist.txt') -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:WinwsArgsFile -PathType Leaf) {
        Copy-Item -LiteralPath $script:WinwsArgsFile -Destination (Join-Path $preserveDir 'winws-args.txt') -Force -ErrorAction SilentlyContinue
    }

    # H2+H3: everything after Stop is guarded; locked drivers abort before
    # any delete, with old services restarted and DNS restored.
    try {
        Stop-AllServices

        if (Test-Path $script:InstallPath) {
            Write-Host (('  ' + ((T 'InfoRemovingExisting') -f $script:InstallPath))) -ForegroundColor Yellow
            # H3: no schedule-on-reboot here; locked driver aborts the install.
            if (Test-Path $script:ZapretPath) { Remove-OwnWinDivertDriver }
            $oldDir = $script:InstallPath + '-old'
            try { Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Install-All: Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorActio... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
            try {
                Rename-Item -LiteralPath $script:InstallPath -NewName (Split-Path -Leaf $oldDir) -ErrorAction Stop
            } catch {
                try { Start-AllServices -DnsOnly:$DnsOnly } catch { Write-Warning ('SEDG:Install-All: Start-AllServices (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Install-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }
                throw 'Install directory is locked. Reboot Windows, then retry with -Clean.'
            }
            try {
                Remove-InstallDirectoryCleanly $oldDir
            } catch {
                Write-Host (('  Old install kept at ' + $oldDir + ': ' + $_.Exception.Message)) -ForegroundColor Yellow
            }
            Write-Done 'Existing installation removed.'
        }

        foreach ($obsoletePath in $script:ObsoleteInstallPaths) {
            if (Test-Path $obsoletePath) {
                Write-Host (('  ' + ((T 'InfoRemovingObsolete') -f $obsoletePath))) -ForegroundColor Yellow
                try {
                    Remove-Item -LiteralPath $obsoletePath -Recurse -Force -ErrorAction Stop
                    Write-Done (((T 'DoneRemoved') -f $obsoletePath))
                } catch {
                    Write-Host (('  ' + (T 'WarnObsoleteKept'))) -ForegroundColor Yellow
                }
            }
        }

        Write-Step 'Creating installation directory...'
        Write-Host (('  ' + (T 'LbPath') + ': ' + $script:InstallPath)) -ForegroundColor DarkGray
        New-Item -ItemType Directory -Path $script:InstallPath -Force | Out-Null
        Write-Step 'Securing installation directory...'
        Set-SecureAcl $script:InstallPath
        Write-Done 'Installation directory secured.'

        Reset-DnsToDhcp
        Install-CommitComponents $staged
        Install-CommitManager $staged.StageManager
        $preservedBack = Join-Path $preserveDir 'config.yaml'
        if (Test-Path -LiteralPath $preservedBack -PathType Leaf) {
            Copy-Item -LiteralPath $preservedBack -Destination $script:ConfigFile -Force
        }
        $preservedList = Join-Path $preserveDir 'blacklist.txt'
        if (Test-Path -LiteralPath $preservedList -PathType Leaf) {
            Copy-Item -LiteralPath $preservedList -Destination $script:BlacklistFile -Force
        }
        $preservedArgs = Join-Path $preserveDir 'winws-args.txt'
        if (Test-Path -LiteralPath $preservedArgs -PathType Leaf) {
            Copy-Item -LiteralPath $preservedArgs -Destination $script:WinwsArgsFile -Force
        }
        if ((Test-Path -LiteralPath $preservedBack -PathType Leaf) -or (Test-Path -LiteralPath $preservedList -PathType Leaf) -or (Test-Path -LiteralPath $preservedArgs -PathType Leaf)) {
            Write-Host (('  ' + (T 'InfoPreserveConfig'))) -ForegroundColor DarkGray
        }
        Write-Step 'Checking DNSProxy configuration...'
        Ensure-Config
        Write-Blacklist
        Write-WinwsArgs
        $dnsLog = Join-Path $script:DnsProxyPath 'dnsproxy.log'
        try {
            if ((Test-Path -LiteralPath $dnsLog) -and ((Get-Item -LiteralPath $dnsLog).Length -gt 10MB)) {
                Remove-Item -LiteralPath $dnsLog -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType File -Path $dnsLog -Force | Out-Null
        } catch { Write-Warning ('SEDG:Install-All: if ((Test-Path -LiteralPath $dnsLog) -and ((Get-Item -Litera... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        Create-Services -DnsOnly:$DnsOnly
        Write-Manager
        Install-Watchdog -FailClosed:$FailClosed
        Set-GatewayEnabled $true
        Write-Step 'Starting configured services...'
        Start-AllServices -DnsOnly:$DnsOnly
        Test-DnsProxyListeners
        Set-LocalDns
        Write-State $staged.DnsRelease $staged.ZapRelease
        try { $oldLeft = $script:InstallPath + '-old'; Remove-Item -LiteralPath $oldLeft -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Install-All: $oldLeft = $script:InstallPath + ''-old''; Remove-Item -Litera... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Remove-Item -LiteralPath $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Install-All: Remove-Item -LiteralPath $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    } catch {
        # A failed install must not leave a half-created service behind.
        try { Stop-AllServices } catch { Write-Warning ('SEDG:Install-All: Stop-AllServices (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Remove-Services } catch { Write-Warning ('SEDG:Install-All: Remove-Services (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Install-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        throw
    }

    Write-Host ''
    Show-InstallSummary
    } finally {
        try { Stop-OpTranscript } catch { Write-Warning ('SEDG:Install-All: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Install-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Test-LiveBinariesHealthy {
    # Early-skip gate: all 6 live binaries must exist, be non-empty and
    # hash-readable. Existence alone can mask a truncated/corrupt install.
    foreach ($p in @((Join-Path $script:DnsProxyPath 'dnsproxy.exe'),
            (Join-Path $script:ZapretPath 'winws.exe'),
            (Join-Path $script:ZapretPath 'cygwin1.dll'),
            (Join-Path $script:ZapretPath 'WinDivert.dll'),
            (Join-Path $script:ZapretPath 'WinDivert64.sys'),
            $script:NssmPath)) {
        try {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
            if ((Get-Item -LiteralPath $p -ErrorAction Stop).Length -le 0) { return $false }
            $null = Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop
        } catch { return $false }
    }
    return $true
}

function Update-All {
    param([switch]$Clean, [switch]$DnsOnly, [switch]$FailClosed, [switch]$AllowSeam)
    Ensure-Administrator
    Test-Platform
    # No "close the manager first" gate: the file swap renames the running exe
    # aside, and a genuinely locked file fails inside Install-CommitManager.
    Enter-InstallerMutex
    Start-OpTranscript 'Update'
    try {
    Write-CreditBanner
    Clear-StaleTempInstallers
    if (-not (Test-Path $script:InstallPath)) {
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Update-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Stop-OpTranscript } catch { Write-Warning ('SEDG:Update-All: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $script:InstallerMutex = $null; $script:MutexDepth = 0; $script:OpTranscript = $null
        Install-All -Clean:$Clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam
        return
    }

    if (Update-ManagerFromDist 'Update') { return }

    Write-Title ('Serverless Edge DNS Gateway with Zapret DPI Bypass - Auto Installer - ' + (T 'MiUpdate'))
    Write-Step 'Preparing update...'
    Write-Host (('  ' + (T 'LbTarget') + ': ' + $script:InstallPath)) -ForegroundColor DarkGray

    # H4: snapshot clean DNS before bootstrap can taint adapters.
    Backup-DnsSettings
    # M8: skip staging entirely when manifest matches state and files exist.
    $earlySkip = $false
    if (-not $ForceUpdate) {
        try {
            $m0 = Get-ApprovedManifest
            $cur0 = Get-StateReleases
            if (($cur0[0] -eq [string]$m0.components.dnsproxy.tag) -and
                ($cur0[1] -eq [string]$m0.components.zapret.tag) -and
                (Test-LiveBinariesHealthy) -and
                (Test-ManagerHealthy)) {
                $earlySkip = $true
            }
        } catch { $earlySkip = $false }
    }
    $staged = $null
    if (-not $earlySkip) {
        try {
            Set-InstallerBootstrapDns
            $staged = Install-StageComponents -AllowSeam:$AllowSeam
            if (-not $staged) { throw 'Component staging failed.' }
            # Downloads are done: restore the pre-bootstrap DNS snapshot now,
            # so the commit phase below runs on clean DNS even if it throws.
            try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Update-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        } catch {
            try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Update-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }
            throw
        }
    }

    $skipCommit = $earlySkip
    if ((-not $earlySkip) -and (-not $ForceUpdate)) {
        $curRel = Get-StateReleases
        if (($curRel[0] -eq $staged.DnsRelease) -and
            ($curRel[1] -eq $staged.ZapRelease) -and
            (Test-LiveBinariesHealthy) -and
            (Test-ManagerHealthy)) {
            $skipCommit = $true
        }
    }

    Write-Step 'Stopping services before update...'

    try {
        Stop-AllServices
        Set-SecureAcl $script:InstallPath
        Reset-DnsToDhcp
        if ($skipCommit) {
            Write-Step (T 'UpdSkipped')
        } else {
            # H3: no reboot-scheduling on Update; locked driver aborts loudly.
            Remove-OwnWinDivertDriver
            Install-CommitComponents $staged
            Install-CommitManager $staged.StageManager
        }
        Write-Host (('  ' + (T 'InfoPreserveConfig'))) -ForegroundColor DarkGray
        Ensure-Config
        Write-Blacklist
        Write-WinwsArgs
        Create-Services -DnsOnly:$DnsOnly
        Write-Manager
        Install-Watchdog -FailClosed:$FailClosed
        Set-GatewayEnabled $true
        Clear-WatchdogState
        Start-AllServices -DnsOnly:$DnsOnly
        Set-LocalDns
        # Always refresh state (even when binaries were already current):
        # a skipped commit must still record the running InstallerVersion,
        # otherwise state.json goes stale and looks like Update never ran.
        $finalRel = Get-StateReleases
        if ($staged) { $finalRel = @($staged.DnsRelease, $staged.ZapRelease) }
        Write-State $finalRel[0] $finalRel[1]
        Remove-Item -LiteralPath $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ''
        Write-Host (T 'UpdDone') -ForegroundColor Green
        Show-InstallSummary
        Write-Host ('  ' + (T 'UpdKept')) -ForegroundColor DarkGray
    } catch {
        # Never destroy a working setup: restart the previous binaries and
        # restore DNS instead of removing services. Recovery errors are
        # appended so the real failure is never masked by a silent one.
        $origErr = $_.Exception.Message
        $extra = @()
        try { Stop-AllServices } catch { $extra += ('stop: ' + $_.Exception.Message) }
        try { Start-AllServices -DnsOnly:$DnsOnly } catch { $extra += ('start: ' + $_.Exception.Message) }
        try { Restore-DnsSettings } catch { $extra += ('dns: ' + $_.Exception.Message) }
        if ($extra.Count -gt 0) { throw ($origErr + ' [recovery: ' + ($extra -join '; ') + ']') }
        throw
    }
    } finally {
        try { Stop-OpTranscript } catch { Write-Warning ('SEDG:Update-All: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Update-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Pause-All {
    Ensure-Administrator
    Enter-InstallerMutex
    try {
    Write-CreditBanner
    Write-Title ('Serverless Edge DNS Gateway with Zapret DPI Bypass - Auto Installer - ' + (T 'MiPause'))
    if (-not (Test-Path $script:InstallPath)) { throw (T 'NotFound') }
    Stop-AllServices
    try { Reset-DnsToDhcp } catch { try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Pause-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }; throw }
    Set-GatewayEnabled $false
    Clear-WatchdogState
    Write-Host (T 'PauseDone') -ForegroundColor Green
    Write-Host (('  ' + (T 'StLocation') + ': {0}') -f $script:InstallPath) -ForegroundColor DarkGray
    Write-Host ('  ' + (T 'PauseKept')) -ForegroundColor DarkGray
    } finally {
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Pause-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Resume-All {
    Ensure-Administrator
    Test-Platform
    Enter-InstallerMutex
    try {
    Write-CreditBanner
    Write-Title ('Serverless Edge DNS Gateway with Zapret DPI Bypass - Auto Installer - ' + (T 'MiResume'))
    if (-not (Test-Path $script:InstallPath)) { throw (T 'NotFound') }
    Clear-WatchdogState
    Start-AllServices -DnsOnly:$DnsOnly
    try {
        Set-LocalDns
    } catch {
        $origErr = $_.Exception.Message
        try { Stop-AllServices } catch { Write-Warning ('SEDG:Resume-All: Stop-AllServices (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Reset-DnsToDhcp } catch { Write-Warning ('SEDG:Resume-All: Reset-DnsToDhcp (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        throw $origErr
    }
    Set-GatewayEnabled $true
    Write-Host (T 'ResumeDone') -ForegroundColor Green
    Write-Host '  DNS: 127.0.0.1:53' -ForegroundColor DarkGray
    Show-ServiceTests
    } finally {
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Resume-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Restart-All {
    Ensure-Administrator
    Test-Platform
    Enter-InstallerMutex
    try {
    Write-CreditBanner
    Write-Title ('Serverless Edge DNS Gateway with Zapret DPI Bypass - Auto Installer - ' + (T 'MiRestart'))
    if (-not (Test-Path $script:InstallPath)) { throw (T 'NotFound') }

    Stop-AllServices
    try {
        Start-AllServices -DnsOnly:$DnsOnly
        Set-LocalDns
    } catch {
        $origErr = $_.Exception.Message
        try { Stop-AllServices } catch { Write-Warning ('SEDG:Restart-All: Stop-AllServices (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Reset-DnsToDhcp } catch { Write-Warning ('SEDG:Restart-All: Reset-DnsToDhcp (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        throw $origErr
    }
    Write-Host (T 'RestartDone') -ForegroundColor Green
    Show-ServiceTests
    } finally {
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Restart-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}
function Uninstall-All {
    Ensure-Administrator
    Test-Platform
    Enter-InstallerMutex
    Start-OpTranscript 'Uninstall'
    try {
    Write-CreditBanner
    $installed = Test-Path $script:InstallPath
    if (-not $installed) {
        Write-Host (T 'NotInstalled') -ForegroundColor Yellow
    } else {
        Write-Title ('Serverless Edge DNS Gateway with Zapret DPI Bypass - Auto Installer - ' + (T 'MiUninstall'))
    }
    # F2: service/task/DNS cleanup is independent of the install directory.
    # A missing directory means the files are already gone, not that leftovers
    # (services, SYSTEM task, DNS) may be skipped. Every independent step runs
    # and real failures are rethrown at the end.
    $cleanupErrors = @()
    Write-Step 'Stopping services and restoring DNS...'
    try { Stop-AllServices } catch { Write-Warning ('SEDG:Uninstall-All: Stop-AllServices (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try { Restore-DnsSettings } catch { Write-Warning ('SEDG:Uninstall-All: Restore-DnsSettings (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    if ($script:DnsRestoreIncomplete) {
        # The backup is the only record of the user's original DNS; destroying
        # it after a failed restore would leave nothing to recover from.
        Write-Host (('  Original DNS could not be fully restored; keeping the backup for another attempt: ' + $script:DnsBackupSafe)) -ForegroundColor Yellow
    } else {
        try {
            if (Test-Path -LiteralPath $script:DnsBackupSafe -PathType Leaf) {
                Remove-Item -LiteralPath $script:DnsBackupSafe -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Warning ('SEDG:Uninstall-All: if (Test-Path -LiteralPath $script:DnsBackupSafe -PathType L... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
    Set-GatewayEnabled $false
    Clear-WatchdogState
    try { Remove-Services } catch { $cleanupErrors += $_.Exception.Message }

    if (Test-Path $script:ZapretPath) {
        try { Remove-OwnWinDivertDriver -ScheduleIfLocked } catch { $cleanupErrors += ('Failed to remove WinDivert: ' + $_.Exception.Message) }
    }

    if ($installed) {
        # O-9 used to keep the manager in %ProgramFiles% with an independent
        # lifecycle. It now lives inside this tree (sedg-manager.exe), so
        # uninstalling removes it too; a manager that is still running keeps its
        # image locked and the removal is scheduled for reboot instead of
        # reporting success.
        # Prefer a synchronous removal so success is verified. Fall back to a
        # scheduled async removal only when files are still locked (e.g. the
        # manager itself is running from the install directory).
        try {
            Remove-Item -LiteralPath $script:InstallPath -Recurse -Force -ErrorAction Stop
            Write-Host (T 'UninstDone') -ForegroundColor Green
            Write-Host ((T 'UninstRemoved') + $script:InstallPath + '.') -ForegroundColor DarkGray
        } catch {

        # Locked files remain (usually WinDivert64.sys or the running manager
        # itself). Schedule the whole tree for reboot deletion.
        Schedule-DeleteTreeOnReboot $script:InstallPath
        if (Test-Path -LiteralPath $script:InstallPath) {
            Write-Host (T 'UninstStarted') -ForegroundColor Yellow
            Write-Host ((T 'UninstSched') + $script:InstallPath + (T 'UninstSched2')) -ForegroundColor Yellow
            Write-Host (('  ' + (T 'InfoVerifyReboot'))) -ForegroundColor Yellow
        } else {
            Write-Host (T 'UninstDone') -ForegroundColor Green
            Write-Host ((T 'UninstRemoved') + $script:InstallPath + '.') -ForegroundColor DarkGray
        }
        }
    }
    if ($Purge) {
        try { Remove-Item -LiteralPath (Join-Path $script:DnsBackupDir 'logs') -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Uninstall-All: Remove-Item -LiteralPath (Join-Path $script:DnsBackupDir ''lo... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Remove-Item -LiteralPath $script:LangFile -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Uninstall-All: Remove-Item -LiteralPath $script:LangFile -Force -ErrorActio... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Remove-Item -LiteralPath (Join-Path $script:DnsBackupDir 'touched-adapters.json') -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Uninstall-All: Remove-Item -LiteralPath (Join-Path $script:DnsBackupDir ''to... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Remove-Item -LiteralPath $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning ('SEDG:Uninstall-All: Remove-Item -LiteralPath $script:TempPath -Recurse -Force -E... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try {
            if ((Test-Path -LiteralPath $script:DnsBackupDir -PathType Container) -and
                (-not (Get-ChildItem -LiteralPath $script:DnsBackupDir -Force -ErrorAction Stop | Select-Object -First 1))) {
                Remove-Item -LiteralPath $script:DnsBackupDir -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Warning ('SEDG:Uninstall-All: if ((Test-Path -LiteralPath $script:DnsBackupDir -PathType C... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
    if ($cleanupErrors.Count -gt 0) {
        throw ('Uninstall incomplete: ' + ($cleanupErrors -join ' '))
    }
    } finally {
        try { Stop-OpTranscript } catch { Write-Warning ('SEDG:Uninstall-All: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Uninstall-All: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }
}

function Get-LocalDnsV4AdapterNames {
    $names = @()
    try {
        foreach ($adapter in (Get-NetworkAdapters -IncludeVirtual)) {
            $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue)
            $v4 = @($dns | Where-Object { $_.AddressFamily -eq 2 } | Select-Object -ExpandProperty ServerAddresses)
            if ($v4 -contains '127.0.0.1') { $names += $adapter.Name }
        }
    } catch { Write-Warning ('SEDG:Get-LocalDnsV4AdapterNames: foreach ($adapter in (Get-NetworkAdapters -IncludeVirtual)) ... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    return $names
}

function Get-LocalDnsV6AdapterNames {
    $names = @()
    try {
        foreach ($adapter in (Get-NetworkAdapters -IncludeVirtual)) {
            $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue)
            $all = @($dns | Select-Object -ExpandProperty ServerAddresses)
            if ($all -contains '::1') { $names += $adapter.Name }
        }
    } catch { Write-Warning ('SEDG:Get-LocalDnsV6AdapterNames: foreach ($adapter in (Get-NetworkAdapters -IncludeVirtual)) ... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    return $names
}

function Show-Status {
    Write-CreditBanner
    Write-Title (T 'StTitle')

    $installed = Test-Path $script:InstallPath
    $winwsService = Get-Service -Name $script:WinwsService -ErrorAction SilentlyContinue
    $dnsService = Get-Service -Name $script:DnsProxyService -ErrorAction SilentlyContinue

    $localDnsV4 = @(Get-LocalDnsV4AdapterNames).Count -gt 0
    $localDnsV6 = @(Get-LocalDnsV6AdapterNames).Count -gt 0
    # The stock template listens on ::1 too: when the config requires it,
    # readiness must include a v6 adapter, not just 127.0.0.1.
    $needsV6 = $false
    try {
        if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
            $needsV6 = [bool]((Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop) -match '(?m)^\s*-\s*::1\s*$')
        }
    } catch { Write-Verbose $_ }

    $dnsRelease = 'Unknown'
    $zapretRelease = 'Unknown'
    $updated = $null
    if (Test-Path $script:StateFile) {
        try {
            $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            if ($state.DnsProxyRelease) { $dnsRelease = [string]$state.DnsProxyRelease }
            if ($state.ZapretRelease) { $zapretRelease = [string]$state.ZapretRelease }
            if ($state.Updated) {
                try { $updated = [DateTimeOffset]::Parse([string]$state.Updated) } catch { Write-Warning ('SEDG:Show-Status: $updated = [DateTimeOffset]::Parse([string]$state.Updated) (' + $_.Exception.Message + ')'); Write-Verbose $_ }
            }
        } catch { Write-Warning ('SEDG:Show-Status: $state = Get-Content -LiteralPath $script:StateFile -Raw | C... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    }

    $winwsRunning = $winwsService -and $winwsService.Status -eq 'Running'
    $dnsRunning = $dnsService -and $dnsService.Status -eq 'Running'
    $ready = $installed -and $winwsRunning -and $dnsRunning -and $localDnsV4 -and ((-not $needsV6) -or $localDnsV6)

    $upstreamShown = T 'VNA'
    $upstreamOk = $false
    try {
        $u = Get-ConfiguredUpstream
        if (Test-DnsUpstream $u) {
            $upstreamShown = '[redacted]'
            try { $upUri = [uri]$u; $upstreamShown = ($upUri.Host + $upUri.AbsolutePath) } catch { Write-Verbose $_ }
            $upstreamOk = $true
        }
    } catch { Write-Warning ('SEDG:Show-Status: $u = Get-ConfiguredUpstream if (Test-DnsUpstream $u) { $upst... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    $configExists = Test-Path -LiteralPath $script:ConfigFile

    Write-Section (T 'StInstall')
    Write-StatusLine $installed (T 'StStatus') $(if ($installed) { T 'VInstalled' } else { T 'VNotInstalled' })
    Write-StatusLine $installed (T 'StLocation') $(if ($installed) { $script:InstallPath } else { T 'VNA' })
    Write-StatusLine $configExists (T 'StConfig') $(if ($configExists) { $script:ConfigFile } else { T 'VNA' })

    Write-Section (T 'StServices')
    Write-StatusLine $winwsRunning 'Zapret WinWS' $(if ($winwsService) { [string]$winwsService.Status } else { T 'VNotInstalled' })
    Write-StatusLine $dnsRunning 'DNSProxy DoH' $(if ($dnsService) { [string]$dnsService.Status } else { T 'VNotInstalled' })
    $wdTask = Get-ScheduledTask -TaskName $script:WatchdogTask -ErrorAction SilentlyContinue
    $wdOk = $wdTask -and ($wdTask.State -ne 'Disabled')
    Write-StatusLine $wdOk 'Watchdog' $(if ($wdTask) { [string]$wdTask.State } else { T 'VNotInstalled' })

    Write-Section (T 'StNetwork')
    Write-StatusLine $localDnsV4 (T 'StLocalV4') $(if ($localDnsV4) { '127.0.0.1' } else { T 'VNotActive' })
    if ($needsV6) { Write-StatusLine $localDnsV6 'Local DNS IPv6' $(if ($localDnsV6) { '::1' } else { T 'VNotActive' }) }
    Write-StatusLine ($installed -and $upstreamOk) (T 'MnUpstream') $(if ($installed) { $upstreamShown } else { T 'VNA' })
    Write-StatusLine $ready (T 'StGw') $(if ($ready) { T 'VActive' } else { T 'VAttention' })

    Write-Section (T 'StVersions')
    $dnsVersionKnown = $dnsRelease -ne 'Unknown'
    $zapVersionKnown = $zapretRelease -ne 'Unknown'
    Write-StatusLine $zapVersionKnown 'Zapret' $zapretRelease
    Write-StatusLine $dnsVersionKnown 'DNSProxy' $dnsRelease

    if ($updated) {
        Write-Section (T 'StLastUpdate')
        Write-Host ("  {0}" -f $updated.ToString('yyyy-MM-dd HH:mm:ss zzz')) -ForegroundColor DarkGray
    }

    Write-Host ''
    $line = '+' + ('=' * 70) + '+'
    Write-Host $line -ForegroundColor $(if ($ready) { 'Green' } else { 'Yellow' })
    $statusText = if ($ready) { T 'VReady' } else { T 'VAttReq' }
    Write-Host ("|  {0,-66}  |" -f ("STATUS: " + $statusText)) -ForegroundColor $(if ($ready) { 'Green' } else { 'Yellow' })
    Write-Host $line -ForegroundColor $(if ($ready) { 'Green' } else { 'Yellow' })
    Write-Host ''
}
function Show-ServiceTests {
    Write-Step (T 'TChecking')

    foreach ($name in @($script:WinwsService, $script:DnsProxyService)) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Host (("  [FAIL] {0}: " -f $name) + (T 'SvcNotFound')) -ForegroundColor Red
            continue
        }

        if ($service.Status -eq 'Running') {
            Write-Host (("  [OK]   {0}: " -f $name) + (T 'SvcRunning')) -ForegroundColor Green
        } else {
            Write-Host ("  [FAIL] {0}: {1}" -f $name, $service.Status) -ForegroundColor Red
        }
    }

    $dnsV4Adapters = @(Get-LocalDnsV4AdapterNames)

    if ($dnsV4Adapters.Count -gt 0) {
        Write-Host ('  [OK]   ' + (T 'LocalDnsOk')) -ForegroundColor Green
    } else {
        Write-Host ('  [FAIL] ' + (T 'LocalDnsFail')) -ForegroundColor Red
    }
    foreach ($adapter in @(Get-NetworkAdapters)) {
        if ($dnsV4Adapters -notcontains $adapter.Name) {
            Write-Host (('  [WARN] ' + ((T 'WarnAdapterUncovered') -f $adapter.Name))) -ForegroundColor Yellow
        }
    }
}

function Get-IPLocation([string]$IP, [hashtable]$Headers) {
    try {
        $response = Invoke-RestMethod -Uri ("https://ipinfo.io/{0}/json" -f $IP) -Headers $Headers -TimeoutSec 5 -ErrorAction Stop
        return @{
            City    = $response.city
            Country = $response.country
            Org     = $response.org
        }
    } catch {
        return $null
    }
}
function Resolve-CdnIPv4([string]$Domain) {
    $addresses = [System.Net.Dns]::GetHostAddresses($Domain)
    $ip = @($addresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }) |
        Select-Object -First 1 -ExpandProperty IPAddressToString
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "No IPv4 address returned."
    }
    return $ip
}
function Test-CDNOptimization {
    $structured = $false
    try { $structured = [bool]$script:CdnStructured } catch { }
    Write-Step 'Verifying CDN Vietnam Optimization...'

    # Flush stale negative DNS entries so one transient stall cannot fail the whole loop.
    try { Clear-DnsClientCache -ErrorAction Stop; Write-Verbose 'SEDG:Test-CDNOptimization: DNS client cache cleared.' } catch { Write-Verbose $_ }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }

    $location = 'Unavailable'
    $isp = 'Unavailable'
    try {
        $geo = Invoke-RestMethod -Uri 'https://api.ip.sb/geoip' -Headers $headers -TimeoutSec 5 -ErrorAction Stop
        $locationParts = @($geo.city, $geo.country) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($locationParts.Count -gt 0) {
            $location = $locationParts -join ', '
        }
        if (-not [string]::IsNullOrWhiteSpace($geo.asn_organization)) {
            $isp = $geo.asn_organization
        }
    } catch { Write-Warning ('SEDG:Test-CDNOptimization: $geo = Invoke-RestMethod -Uri ''https://api.ip.sb/geoip'' -Hea... (' + $_.Exception.Message + ')'); Write-Verbose $_ }

    Write-Host ''
    Write-Host (((T 'CdnLoc') -f $location)) -ForegroundColor Cyan
    Write-Host (((T 'CdnIsp') -f $isp)) -ForegroundColor Cyan
    Write-Host ''

    # Match the original BIBICADOTNET benchmark: resolve a CDN hostname,
    # ping it, then query the IP for location/ASN.
    $targets = @(
        @{ Name = 'Tiktok.com';    Domain = 'v16-webapp-prime.tiktok.com' }
        @{ Name = 'Bilibili.com';  Domain = 'upos-hz-mirrorakam.akamaized.net' }
        @{ Name = 'Apple.com';     Domain = 'www.apple.com' }
        @{ Name = 'Amazon.com';    Domain = 'www.amazon.com' }
        @{ Name = 'Ebay.com';      Domain = 'www.ebay.com' }
        @{ Name = 'Douyin.com';    Domain = 'v3-dy-o.zjcdn.com' }
        @{ Name = 'Bilibili.tv';   Domain = 'www.bilibili.tv' }
        @{ Name = 'Shopee.vn';     Domain = 'cf.shopee.vn' }
        @{ Name = 'Lazada.vn';     Domain = 'img.lazcdn.com' }
    )

    $ipCache = @{}
    foreach ($target in $targets) {
        $name = $target.Name.PadRight(15)

        # Small delay to reduce the chance of rate limiting by the geo APIs.
        Start-Sleep -Milliseconds 200

        try {
            try {
                $resolvedIP = Resolve-CdnIPv4 $target.Domain
            } catch {
                # DNS can flap in bursts like ICMP: wait ~1s and retry exactly once.
                Write-Verbose ('SEDG:Test-CDNOptimization: DNS retry for ' + $target.Domain + ' (' + $_.Exception.Message + ')')
                Start-Sleep -Seconds 1
                $resolvedIP = Resolve-CdnIPv4 $target.Domain
            }

            $cdnLoc = $null
            if ($ipCache.ContainsKey($resolvedIP)) { $cdnLoc = $ipCache[$resolvedIP] }
            else {
                $cdnLoc = Get-IPLocation -IP $resolvedIP -Headers $headers
                $ipCache[$resolvedIP] = $cdnLoc
            }
            $locationInfo = ''
            if ($cdnLoc) {
                $cdnParts = @($cdnLoc.City, $cdnLoc.Org) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                if ($cdnParts.Count -gt 0) {
                    $locationInfo = ' (' + ($cdnParts -join ', ') + ')'
                }
            }

            try {
                $ping = Test-Connection -ComputerName $target.Domain -Count 1 -ErrorAction Stop
            } catch {
                # ICMP via WinDivert is flaky: wait ~1s and retry exactly once.
                Write-Verbose ('SEDG:Test-CDNOptimization: ping retry for ' + $target.Domain + ' (' + $_.Exception.Message + ')')
                Start-Sleep -Seconds 1
                try {
                    $ping = Test-Connection -ComputerName $target.Domain -Count 1 -ErrorAction Stop
                } catch {
                    Write-Verbose ('SEDG:Test-CDNOptimization: ping blocked for ' + $target.Domain + ' (' + $_.Exception.Message + ')')
                    Write-Host (('  ' + ((T 'CdnPingBlocked') -f $name, $resolvedIP, $locationInfo))) -ForegroundColor Yellow
                    continue
                }
            }
            # Strict-safe latency read (PS7 dropped ResponseTime for Latency;
            # touching a missing property throws under StrictMode Latest).
            $ms = $null
            if ($ping.PSObject.Properties['Latency']) { $ms = $ping.Latency }
            elseif ($ping.PSObject.Properties['ResponseTime']) { $ms = $ping.ResponseTime }
            if ($null -eq $ms) {
                Write-Verbose ('SEDG:Test-CDNOptimization: no latency property for ' + $target.Domain)
                Write-Host (('  ' + ((T 'CdnPingBlocked') -f $name, $resolvedIP, $locationInfo))) -ForegroundColor Yellow
                continue
            }

            $color = if ($ms -lt 10) {
                'Green'
            } elseif ($ms -lt 20) {
                'Yellow'
            } else {
                'Red'
            }

            Write-Host ("  {0} ({1}ms){2}" -f $name, $ms, $locationInfo) -ForegroundColor $color
        } catch {
            Write-Verbose ('SEDG:Test-CDNOptimization: target failed: ' + $target.Domain + ' (' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message + ')')
            Write-Host (('  ' + ((T 'CdnErr') -f $name))) -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Done 'CDN connectivity verification completed.'
    if ($structured) {
        return [ordered]@{
            checkedAt = (Get-Date).ToString('o')
            location  = $location
            isp       = $isp
            targets   = @($targets | ForEach-Object { [ordered]@{ name = $_.Name; domain = $_.Domain } })
        }
    }
}
function Show-InstallSummary {
    Write-Host ""
    Write-Host (T 'SumDone') -ForegroundColor Green
    Write-Host "  DNS: 127.0.0.1"
    Write-Host ('  ' + (T 'SumZap'))
    Write-Host ('  ' + (T 'SumProxy'))
    Write-Host (('  ' + (T 'LbPath') + ': ' + $script:InstallPath)) -ForegroundColor DarkGray
    try {
        $sumRel = Get-StateReleases
        $sumUp = Get-ConfiguredUpstream
        $upLog = '[redacted]'
        try { $upUri = [uri]$sumUp; $upLog = ($upUri.Host + $upUri.AbsolutePath) } catch { Write-Verbose $_ }
        Write-Host ("  DNSProxy {0} | Zapret {1}" -f $sumRel[0], $sumRel[1]) -ForegroundColor DarkGray
        Write-Host ('  ' + (T 'MnUpstream') + ': ' + $upLog) -ForegroundColor DarkGray
    } catch { Write-Warning ('SEDG:Show-InstallSummary: $sumRel = Get-StateReleases $sumUp = Get-ConfiguredUpstream ... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    Write-Host ('  ' + (T 'SumHint')) -ForegroundColor DarkGray
    Write-Host ""
    Show-ServiceTests
    # CDN test is opt-in: it adds delay and queries third-party geo APIs.
    $runCdn = [bool]$IncludeCdnTest
    if (-not $runCdn -and $Action -eq 'Menu' -and -not $script:ProtocolMode) {
        $answer = Read-Host (T 'CdnAsk')
        if ($answer -match '^[YyCc1]') { $runCdn = $true }
    }
    if ($runCdn) {
        Test-CDNOptimization
    } else {
        Write-Host ('  ' + (T 'CdnSkip')) -ForegroundColor DarkGray
    }
}
function Get-MenuStatusPanel {
    # Best-effort status rows for the menu box: services, DNS mode, upstream.
    # Never throws; a failed probe simply drops its row.
    $rows = @()
    try {
        $bits = @()
        $allOk = $true
        foreach ($pair in @(@('dnsproxy', $script:DnsProxyService), @('winws', $script:WinwsService))) {
            $svc = Get-Service -Name $pair[1] -ErrorAction SilentlyContinue
            $ok = [bool]($svc -and $svc.Status -eq 'Running')
            if (-not $ok) { $allOk = $false }
            $bits += ('[{0}] {1}' -f $(if ($ok) { 'OK' } else { '!!' }), $pair[0])
        }
        $rows += @{ Label = (T 'StServices'); Value = ($bits -join '   '); Color = $(if ($allOk) { 'Green' } else { 'Red' }) }
    } catch { }
    try {
        $local = $false
        try {
            $local = @(Get-DnsClientServerAddress -ErrorAction Stop |
                Where-Object { @($_.ServerAddresses) -contains '127.0.0.1' }).Count -gt 0
        } catch { }
        $rows += @{ Label = (T 'StNetwork'); Value = (T $(if ($local) { 'MnLocalDns' } else { 'MnOtherDns' })); Color = $(if ($local) { 'Green' } else { 'Yellow' }) }
    } catch { }
    try {
        $u = Get-ConfiguredUpstream
        try { $uh = ([uri]$u).Host } catch { $uh = $u }
        if (-not [string]::IsNullOrWhiteSpace($uh)) {
            $rows += @{ Label = (T 'MnUpstream'); Value = $uh; Color = 'Cyan' }
        }
    } catch { }
    return $rows
}
function Show-MainMenu {
    Write-CreditBanner
    $w = 70
    Write-BoxTop $w
    Write-BoxLine ('  ' + (T 'MenuTitle')) $w
    Write-BoxSeparator $w
    $colW = @(20, 20, 26)
    $row = {
        param([string]$N1, [string]$K1, [string]$N2, [string]$K2, [string]$N3, [string]$K3)
        $cells = ''
        $i = 0
        foreach ($cell in @(@($N1, $K1), @($N2, $K2), @($N3, $K3))) {
            $text = ''
            if ($cell[1]) {
                $text = (' [{0,2}] {1}' -f $cell[0], (T $cell[1]))
                if ($text.Length -gt $colW[$i] - 1) { $text = $text.Substring(0, $colW[$i] - 4) + '...' }
            }
            $cells += $text.PadRight($colW[$i])
            $i++
        }
        Write-BoxLine $cells $w
    }
    & $row '1' 'MiInstall'   '2' 'MiUpdate'   '3' 'MiStatus'
    & $row '4' 'MiRestart'   '5' 'MiPause'    '6' 'MiResume'
    & $row '7' 'MiUpstream'  '8' 'MiSysDns'   '9' 'MiCdn'
    Write-BoxLine '' $w
    & $row '10' 'MiUninstall' '' '' '11' 'MiLang'
    # Exit lives in its own fixed band, set off by double rules. The single
    # leading space keeps its bracket column aligned with the action grid.
    Write-BoxSeparator $w
    Write-BoxLine (' [ 0] ' + (T 'MiExit')) $w
    Write-BoxSeparator $w
    foreach ($statusRow in @(Get-MenuStatusPanel)) {
        Write-BoxLine ('  ' + ([string]$statusRow.Label).PadRight(12) + $statusRow.Value) $w $statusRow.Color
    }
    Write-BoxBottom $w
    Write-Host ''
    Write-Host (('  ' + ((T 'StVerPath') -f $script:InstallerVersion, $script:InstallPath))) -ForegroundColor DarkGray
    Write-Host ''
}

function Select-EntryLanguage {
    # M3: skip when a language is already saved or passed via -Language.
    if ((Test-Path -LiteralPath $script:LangFile -PathType Leaf) -or ($Language.ToUpperInvariant() -in @('EN','VI'))) { return }
    while ($true) {
        Write-CreditBanner
        Write-Title (T 'LangTitle')
        Write-Host '  [1] English'
        Write-Host ('  [2] ' + (T 'LangOptV'))
        Write-Host ''
        $current = if ($script:Lang -eq 'VI') { T 'LangOptV' } else { T 'LangOptE' }
        Write-Host ('  ' + (T 'EdCurrent') + $current) -ForegroundColor DarkGray
        Write-Host ''
        $choice = Read-Host ((T 'LangSelect') + ' (Enter)')
        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        switch ($choice.Trim()) {
            '1' { $script:Lang = 'EN'; Save-Lang $script:Lang; return }
            '2' { $script:Lang = 'VI'; Save-Lang $script:Lang; return }
            default { Write-Host (T 'LangInvalid') -ForegroundColor Yellow }
        }
    }
}

function Write-ProtocolLine($Object) {
    if (-not $script:ProtocolOut) { throw 'Protocol stdout is unavailable.' }
    $json = $Object | ConvertTo-Json -Compress -Depth 10
    $script:ProtocolOut.WriteLine($json)
    $script:ProtocolOut.Flush()
}

function New-ProtocolProbe([string]$State, $Value = $null, [string]$Reason = '') {
    if ($State -eq 'known') {
        return [ordered]@{ state = 'known'; value = $Value }
    }
    if ($State -eq 'notApplicable') {
        return [ordered]@{ state = 'notApplicable' }
    }
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = 'Probe could not be evaluated.' }
    return [ordered]@{ state = 'unknown'; reason = $Reason }
}

function New-ProtocolResult([bool]$Ok, [string]$Code, [string]$Message, $Data = $null, [string]$CurrentState = 'unchanged', [string]$RestoredState = 'notRequired', [string]$NextStep = 'none') {
    $result = [ordered]@{
        type          = 'result'
        ok            = $Ok
        code          = $Code
        message       = $Message
        currentState  = $CurrentState
        restoredState = $RestoredState
        nextStep      = $NextStep
    }
    if ($null -ne $Data) { $result['data'] = $Data }
    if ($script:OpTranscript) { $result['transcriptPath'] = [string]$script:OpTranscript }
    return $result
}

function Get-StatusSnapshot {
    $snapshot = [ordered]@{}
    $installed = $false
    $installProbeError = $null
    try {
        $installed = Test-Path -LiteralPath $script:InstallPath -ErrorAction Stop
    } catch { $installProbeError = $_.Exception.Message }
    if ($installProbeError) {
        $snapshot['installPresence'] = New-ProtocolProbe 'unknown' $null ('Install presence probe failed: ' + $installProbeError)
        foreach ($name in @('services', 'watchdog', 'dnsPerAdapter', 'upstream', 'versions', 'lastUpdate')) {
            $snapshot[$name] = New-ProtocolProbe 'unknown' $null 'Install presence is unknown.'
        }
        $snapshot['readiness'] = New-ProtocolProbe 'unknown' $null 'Install presence is unknown.'
        $snapshot['phases'] = @()
        $snapshot['observedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
        return $snapshot
    }
    $snapshot['installPresence'] = New-ProtocolProbe 'known' ([ordered]@{ installed = $installed; installPath = $script:InstallPath })

    if (-not $installed) {
        foreach ($name in @('services', 'watchdog', 'dnsPerAdapter', 'upstream', 'versions', 'lastUpdate')) {
            $snapshot[$name] = New-ProtocolProbe 'notApplicable'
        }
        $snapshot['readiness'] = New-ProtocolProbe 'known' ([ordered]@{ state = 'attention'; reasons = @('notInstalled') })
        $snapshot['phases'] = @()
        $snapshot['observedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
        return $snapshot
    }

    $serviceStatus = @{}
    $serviceRows = @()
    try {
        foreach ($name in @($script:DnsProxyService, $script:WinwsService)) {
            $service = Get-Service -Name $name -ErrorAction Stop
            $startType = 'unknown'
            try {
                $wmi = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $name + "'") -ErrorAction Stop
                if ($wmi -and $wmi.PSObject.Properties['StartMode']) { $startType = [string]$wmi.StartMode }
            } catch { }
            $serviceStatus[$name] = [string]$service.Status
            $serviceRows += [ordered]@{ name = $name; status = [string]$service.Status; startType = $startType }
        }
        $snapshot['services'] = New-ProtocolProbe 'known' $serviceRows
    } catch {
        $snapshot['services'] = New-ProtocolProbe 'unknown' $null ('Service probe failed: ' + $_.Exception.Message)
    }

    try {
        $task = Get-ScheduledTask -TaskName $script:WatchdogTask -ErrorAction Stop
        $lastRun = $null
        $lastOutcome = $null
        try {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $script:WatchdogTask -ErrorAction Stop
            if ($taskInfo -and $taskInfo.PSObject.Properties['LastRunTime'] -and $taskInfo.LastRunTime) {
                $lastRun = ([DateTimeOffset]$taskInfo.LastRunTime).ToString('o')
            }
            if ($taskInfo -and $taskInfo.PSObject.Properties['LastTaskResult']) {
                $lastOutcome = [string]$taskInfo.LastTaskResult
            }
        } catch { }
        $snapshot['watchdog'] = New-ProtocolProbe 'known' ([ordered]@{
            taskName            = $script:WatchdogTask
            enabled             = ([string]$task.State -ne 'Disabled')
            lastRunUtc          = $lastRun
            lastOutcome         = $lastOutcome
            lastFallbackUtc     = $null
            lastFallbackReason  = $null
            failClosed          = (Test-Path -LiteralPath $script:FailClosedFile)
        })
    } catch {
        $snapshot['watchdog'] = New-ProtocolProbe 'unknown' $null ('Watchdog probe failed: ' + $_.Exception.Message)
    }

    $dnsRows = @()
    try {
        $adapters = @(Get-NetworkAdapters -IncludeVirtual)
        foreach ($adapter in $adapters) {
            $v4 = @()
            $v6 = @()
            foreach ($row in @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop)) {
                foreach ($address in @($row.ServerAddresses)) {
                    if ([string]::IsNullOrWhiteSpace([string]$address)) { continue }
                    try {
                        $parsed = [System.Net.IPAddress]::Parse([string]$address)
                        if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $v4 += [string]$address }
                        else { $v6 += [string]$address }
                    } catch { }
                }
            }
            $servers = @($v4 + $v6)
            # H4 parity: the registry NameServer value, not the presence of
            # resolved/autoconfigured addresses, is the static-DNS signal.
            $static4 = Get-StaticDnsServers ([string]$adapter.InterfaceGuid) 'Tcpip'
            $static6 = Get-StaticDnsServers ([string]$adapter.InterfaceGuid) 'Tcpip6'
            if ($null -eq $static4 -or $null -eq $static6) {
                throw ('Static-DNS registry probe failed for adapter ' + $adapter.Name + '.')
            }
            $mode = if (@($static4).Count -gt 0 -or @($static6).Count -gt 0) { 'static' } else { 'dhcp' }
            $dnsRows += [ordered]@{
                adapterName     = [string]$adapter.Name
                mode            = $mode
                servers         = $servers
                gatewayBypassed = (-not ($servers -contains '127.0.0.1'))
            }
        }
        $snapshot['dnsPerAdapter'] = New-ProtocolProbe 'known' $dnsRows
    } catch {
        $snapshot['dnsPerAdapter'] = New-ProtocolProbe 'unknown' $null ('Adapter DNS probe failed: ' + $_.Exception.Message)
    }

    $upstreamOk = $false
    try {
        $configured = Get-ConfiguredUpstream
        if (Test-DnsUpstream $configured) {
            $upstreamOk = $true
            $upstreamUri = [uri]$configured
            $source = if ($configured -eq [string]$script:OptionalUpstreams['SDEG (Default)']) { 'default' } else { 'custom' }
            $snapshot['upstream'] = New-ProtocolProbe 'known' ([ordered]@{
                host                = $upstreamUri.Host
                scheme              = $upstreamUri.Scheme
                source              = $source
                credentialsRedacted = $true
            })
        } else {
            $snapshot['upstream'] = New-ProtocolProbe 'unknown' $null 'No valid configured upstream was found.'
        }
    } catch {
        $snapshot['upstream'] = New-ProtocolProbe 'unknown' $null ('Upstream probe failed: ' + $_.Exception.Message)
    }

    $state = $null
    try {
        if (Test-Path -LiteralPath $script:StateFile -PathType Leaf) {
            $state = Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
    } catch { }

    try {
        $dnsRelease = $null
        $zapretRelease = $null
        if ($state) {
            if ($state.PSObject.Properties['DnsProxyRelease']) { $dnsRelease = [string]$state.DnsProxyRelease }
            if ($state.PSObject.Properties['ZapretRelease']) { $zapretRelease = [string]$state.ZapretRelease }
        }
        if ([string]::IsNullOrWhiteSpace($dnsRelease) -or [string]::IsNullOrWhiteSpace($zapretRelease)) {
            $snapshot['versions'] = New-ProtocolProbe 'unknown' $null 'The installed state does not record both component versions.'
        } else {
            $snapshot['versions'] = New-ProtocolProbe 'known' @(
                [ordered]@{ component = 'installer'; installed = $script:InstallerVersion; approved = $null; match = 'unknown' },
                [ordered]@{ component = 'dnsproxy'; installed = $dnsRelease; approved = $null; match = 'unknown' },
                [ordered]@{ component = 'zapret'; installed = $zapretRelease; approved = $null; match = 'unknown' },
                [ordered]@{ component = 'nssm'; installed = $script:NssmVersion; approved = $null; match = 'unknown' },
                [ordered]@{ component = 'manager'; installed = $null; approved = $null; match = 'unknown' }
            )
        }
    } catch {
        $snapshot['versions'] = New-ProtocolProbe 'unknown' $null ('Version probe failed: ' + $_.Exception.Message)
    }

    try {
        if ($state -and $state.PSObject.Properties['Updated'] -and -not [string]::IsNullOrWhiteSpace([string]$state.Updated)) {
            $updated = [DateTimeOffset]::Parse([string]$state.Updated).ToString('o')
            $snapshot['lastUpdate'] = New-ProtocolProbe 'known' ([ordered]@{
                utc         = $updated
                fromVersion = $null
                toVersion   = $null
                outcome     = 'unknown'
                reportedBy  = 'engine'
            })
        } else {
            $snapshot['lastUpdate'] = New-ProtocolProbe 'unknown' $null 'The installed state does not record a last update.'
        }
    } catch {
        $snapshot['lastUpdate'] = New-ProtocolProbe 'unknown' $null ('Last-update probe failed: ' + $_.Exception.Message)
    }

    $unknownReasons = @()
    foreach ($name in @('installPresence', 'services', 'watchdog', 'dnsPerAdapter', 'upstream', 'versions', 'lastUpdate')) {
        if ($snapshot[$name]['state'] -eq 'unknown') {
            $unknownReasons += ($name + ': ' + [string]$snapshot[$name]['reason'])
        }
    }
    if ($unknownReasons.Count -gt 0) {
        $snapshot['readiness'] = New-ProtocolProbe 'unknown' $null (($unknownReasons -join '; '))
    } else {
        $reasons = @()
        if ($serviceStatus[$script:DnsProxyService] -ne 'Running') { $reasons += 'dnsproxyServiceNotRunning' }
        if ($serviceStatus[$script:WinwsService] -ne 'Running') { $reasons += 'winwsServiceNotRunning' }
        $localDns = @($dnsRows | Where-Object { @($_.servers) -contains '127.0.0.1' })
        if ($localDns.Count -eq 0) { $reasons += 'localDnsNotActive' }
        if (-not $upstreamOk) { $reasons += 'upstreamNotValid' }
        if ($reasons.Count -eq 0) {
            $snapshot['readiness'] = New-ProtocolProbe 'known' ([ordered]@{ state = 'ready'; reasons = @() })
        } else {
            $snapshot['readiness'] = New-ProtocolProbe 'known' ([ordered]@{ state = 'attention'; reasons = $reasons })
        }
    }
    $snapshot['phases'] = @()
    $snapshot['observedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    return $snapshot
}

function Test-ProtocolServers($Servers) {
    $list = @($Servers)
    if ($list.Count -lt 1 -or $list.Count -gt 4) { return $false }
    foreach ($server in $list) {
        $text = [string]$server
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }
        try { [void][System.Net.IPAddress]::Parse($text.Trim()) } catch { return $false }
    }
    return $true
}

function Invoke-ProtocolAction($request) {
    $actionProperty = $request.PSObject.Properties['action']
    if (-not $actionProperty) {
        return New-ProtocolResult $false 'Protocol' 'The request has no action.' $null 'unknown' 'unchanged' 'Send one valid request line.'
    }
    $action = [string]$actionProperty.Value
    $versionProperty = $request.PSObject.Properties['protocolVersion']
    if ($versionProperty -and ([string]$versionProperty.Value -ne '1')) {
        return New-ProtocolResult $false 'Protocol' 'Unsupported protocolVersion.' $null 'unknown' 'unchanged' 'Use protocolVersion 1.'
    }
    $argsProperty = $request.PSObject.Properties['args']
    $args = $null
    if ($argsProperty) { $args = $argsProperty.Value }

    $known = @('Status', 'Install', 'Update', 'Pause', 'Resume', 'Restart', 'Uninstall', 'Purge', 'SetUpstream', 'SetDns', 'RestoreEngine', 'SetLanguage', 'TestCdnOptimization')
    if ($action -notin $known) {
        return New-ProtocolResult $false 'Protocol' ('Unknown protocol action: ' + $action) $null 'unknown' 'unchanged' 'Use a declared action.'
    }

    if ($action -eq 'RestoreEngine') {
        return New-ProtocolResult $false 'EngineGeneric' 'RestoreEngine is reserved and is not implemented by this engine build.' $null 'unknown' 'notRequired' 'Use the app update or engine installer instead.'
    }

    $mutating = $action -in @('Install', 'Update', 'Pause', 'Resume', 'Restart', 'Uninstall', 'Purge', 'SetUpstream', 'SetDns')
    if ($mutating) {
        if ($action -eq 'SetDns') {
            $serversProperty = if ($args) { $args.PSObject.Properties['servers'] } else { $null }
            $servers = if ($serversProperty) { @($serversProperty.Value) } else { @() }
            if (-not (Test-ProtocolServers $servers)) {
                return New-ProtocolResult $false 'Validation' 'SetDns requires one to four parseable IPv4 or IPv6 addresses.' $null 'unchanged' 'notRequired' 'Correct the servers array.'
            }
        }
        if ($action -eq 'SetUpstream') {
            $modeProperty = if ($args) { $args.PSObject.Properties['mode'] } else { $null }
            $urlProperty = if ($args) { $args.PSObject.Properties['upstreamUrl'] } else { $null }
            $mode = if ($modeProperty) { [string]$modeProperty.Value } else { '' }
            $upstreamUrl = if ($urlProperty) { [string]$urlProperty.Value } else { '' }
            if ($mode -notin @('resetDefaults', 'custom')) {
                return New-ProtocolResult $false 'Validation' 'SetUpstream mode must be resetDefaults or custom.' $null 'unchanged' 'notRequired' 'Correct the mode.'
            }
            if ($mode -eq 'custom') {
                # Mirror the engine's existing upstream policy; plaintext HTTP is
                # deliberately not a valid DNS-over-HTTPS transport here.
                if (-not (Test-DnsUpstream $upstreamUrl)) {
                    return New-ProtocolResult $false 'Validation' 'SetUpstream custom requires an absolute https/tls/h3/quic URL with a host.' $null 'unchanged' 'notRequired' 'Correct the upstreamUrl.'
                }
            }
        }

        # The engine mutex is the exclusivity authority: a concurrent run is
        # refused here, before the elevation check, so the machine channel can
        # report the busy state instead of a generic failure.
        try { Enter-InstallerMutex } catch {
            if ($_.Exception.Message -eq (T 'MutexBusy')) {
                return New-ProtocolResult $false 'MutexBusy' 'Another installer operation is running.' $null 'unchanged' 'notRequired' 'Retry after the current operation finishes.'
            }
            # A standard user may not be able to open a mutex created by an
            # elevated process; that is not a busy mutex, so the elevation
            # refusal below still decides the outcome.
            if (Test-Administrator) { throw }
        }
        try {
            # A standard user cannot mutate; refuse before touching the host.
            if (-not (Test-Administrator)) {
                return New-ProtocolResult $false 'UacDenied' 'This action requires the elevated broker.' $null 'unchanged' 'notRequired' 'Run it through the elevated broker.'
            }
            switch ($action) {
                'Install' {
                    $clean = $false
                    if ($args -and $args.PSObject.Properties['mode']) { $clean = ([string]$args.mode -eq 'clean') }
                    Install-All -Clean:$clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam | Out-Null
                }
                'Update' { Update-All -Clean:$Clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam | Out-Null }
                'Pause' { Pause-All | Out-Null }
                'Resume' { Resume-All | Out-Null }
                'Restart' { Restart-All | Out-Null }
                'Uninstall' { Uninstall-All | Out-Null }
                'Purge' { $script:Purge = $true; Uninstall-All | Out-Null }
                'SetUpstream' {
                    if ([string]$args.mode -eq 'resetDefaults') { Set-Upstream -ResetDefaults | Out-Null }
                    else { Set-Upstream -SelectedUpstream ([string]$args.upstreamUrl) | Out-Null }
                }
                'SetDns' { Set-SystemDns -Servers @($args.servers) | Out-Null }
            }
        } finally {
            try { Exit-InstallerMutex } catch { }
        }
    } else {
        switch ($action) {
            'Status' { return New-ProtocolResult $true 'None' 'Status snapshot.' (Get-StatusSnapshot) }
            'SetLanguage' {
                $language = ''
                if ($args -and $args.PSObject.Properties['language']) { $language = [string]$args.language }
                if ($language -notin @('en', 'vi')) {
                    return New-ProtocolResult $false 'Validation' 'SetLanguage requires en or vi.' $null 'unchanged' 'notRequired' 'Correct the language.'
                }
                Set-Language -SelectedLang $language.ToUpperInvariant() | Out-Null
            }
            'TestCdnOptimization' {
                $script:CdnStructured = $true
                try { $data = Test-CDNOptimization } finally { $script:CdnStructured = $false }
                return New-ProtocolResult $true 'None' 'CDN test completed.' $data
            }
        }
    }
    return New-ProtocolResult $true 'None' ('Protocol action completed: ' + $action)
}

function Invoke-ProtocolLoop {
    $script:ProtocolMode = $true
    try { Write-ProtocolLine ([ordered]@{ type = 'hello'; protocolVersion = 1; engineVersion = $script:InstallerVersion; pid = $PID }) }
    catch { $script:ExitCode = 2; return }

    $line = $null
    try { $line = [Console]::In.ReadLine() } catch { }
    if ([string]::IsNullOrWhiteSpace($line)) {
        $result = New-ProtocolResult $false 'Protocol' 'No protocol request line was received.' $null 'unknown' 'unchanged' 'Send one valid request line.'
        try { Write-ProtocolLine $result; $script:ProtocolResultSent = $true; $script:ExitCode = 1 } catch { $script:ExitCode = 2 }
        return
    }

    # A UTF-8 BOM is not JSON: Windows PowerShell pipe writers emit one on a
    # UTF-8 ANSI code page. Absorb it the same way the app absorbs ours.
    $line = $line.TrimStart([char]0xFEFF)
    $request = $null
    try { $request = $line | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $result = New-ProtocolResult $false 'Protocol' ('Malformed request: ' + $_.Exception.Message) $null 'unknown' 'unchanged' 'Send one valid JSON request line.'
        try { Write-ProtocolLine $result; $script:ProtocolResultSent = $true; $script:ExitCode = 1 } catch { $script:ExitCode = 2 }
        return
    }

    try { $result = Invoke-ProtocolAction $request }
    catch {
        $result = New-ProtocolResult $false 'EngineGeneric' $_.Exception.Message $null 'unknown' 'notRequired' 'Inspect stderr and the engine transcript.'
    }
    try {
        Write-ProtocolLine $result
        $script:ProtocolResultSent = $true
        if ($result['ok']) { $script:ExitCode = 0 } else { $script:ExitCode = 1 }
    } catch { $script:ExitCode = 2 }
}

function Show-Menu {
    # M3: elevate once for the whole menu session.
    Ensure-Administrator
    Select-EntryLanguage
    while ($true) {
        Show-MainMenu
        $choice = Read-Host (T 'PmtSelect')
        try {
            switch ($choice) {
                '1' { Install-All -Clean:$Clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam }
                '2' { Update-All -Clean:$Clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam }
                '3' { Show-Status }
                '4' { Restart-All }
                '5' { Pause-All }
                '6' { Resume-All }
                '7' { Set-Upstream }
                '8' { Set-SystemDns }
                '9' { Test-CDNOptimization }
                '10' { Uninstall-All }
                '11' { Set-Language }
                '0' { return }
                default { Write-Host (T 'MsgInvalid') -ForegroundColor Yellow }
            }
        } catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
        # M2: release mutex/transcript between menu actions.
        try { Stop-OpTranscript } catch { Write-Warning ('SEDG:Show-Menu: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:Show-Menu: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
        $script:OpTranscript = $null

        if ($choice -ne '0') {
            Read-Host (T 'PmtContinue') | Out-Null
        }
    }
}

$script:ExitCode = 0
try {
    Clear-StaleTempInstallers
    if ($Protocol -eq 'jsonl') {
        Invoke-ProtocolLoop
    } else {
        switch ($Action) {
            'Install' { Install-All -Clean:$Clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam }
            'Update' { Update-All -Clean:$Clean -DnsOnly:$DnsOnly -FailClosed:$FailClosed -AllowSeam:$AllowSeam }
            'Pause' { Pause-All }
            'Resume' { Resume-All }
            'Restart' { Restart-All }
            'Uninstall' { Uninstall-All }
            'Status' { Show-Status }
            'SetUpstream' { Set-Upstream $Upstream }
            'SetDns' { Set-SystemDns }
            'Menu' { Show-Menu }
            default { throw "Unknown action: $Action" }
        }
    }
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    if ($Protocol -eq 'jsonl' -and (-not $script:ProtocolResultSent)) { $script:ExitCode = 2 } else { $script:ExitCode = 1 }
} finally {
    try { Stop-OpTranscript } catch { Write-Warning ('SEDG:script: Stop-OpTranscript (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try { Exit-InstallerMutex } catch { Write-Warning ('SEDG:script: Exit-InstallerMutex (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    # M5: restore host preferences polluted by irm|iex.
    try { $ErrorActionPreference = $script:SavedErrorAction } catch { Write-Warning ('SEDG:script: $ErrorActionPreference = $script:SavedErrorAction (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try { $ProgressPreference = $script:SavedProgress } catch { Write-Warning ('SEDG:script: $ProgressPreference = $script:SavedProgress (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try { if ($null -ne $script:SavedSecurityProtocol) { [Net.ServicePointManager]::SecurityProtocol = $script:SavedSecurityProtocol } } catch { Write-Warning ('SEDG:script: if ($null -ne $script:SavedSecurityProtocol) { [Net.ServiceP... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    try { if ($null -ne $script:SavedOutputEncoding) { [Console]::OutputEncoding = $script:SavedOutputEncoding } } catch { Write-Warning ('SEDG:script: if ($null -ne $script:SavedOutputEncoding) { [Console]::Outp... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
}

# Keep a one-shot elevated window open for reading. Menu pauses itself;
# redirected/piped runs skip this.
if (($Action -ne 'Menu') -and ($Protocol -ne 'jsonl') -and (-not [Console]::IsInputRedirected)) {
    Read-Host (T 'PmtContinue') | Out-Null
}

# Delete our own irm|iex temp copy (fully loaded in memory, safe). Installed
# manager.ps1 runs never match this pattern.
try {
    if ($script:SelfPath -like (Join-Path $env:TEMP 'serverless-edge-dns-gateway-installer-*.ps1')) {
        Remove-Item -LiteralPath $script:SelfPath -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Warning ('SEDG:script: if ($script:SelfPath -like (Join-Path $env:TEMP ''serverless-... (' + $_.Exception.Message + ')'); Write-Verbose $_ }

if ($script:ExitCode -ne 0) { Exit-Installer $script:ExitCode }
