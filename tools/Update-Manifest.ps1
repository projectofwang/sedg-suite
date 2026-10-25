#requires -Version 5.1
<#
.SYNOPSIS
    Updates approved-releases.json and the embedded fallback copy in
    installer.ps1 atomically (no cryptography involved).
.DESCRIPTION
    Downloads the requested upstream assets, computes their SHA-256, verifies
    each archive opens and contains the expected runtime, then writes both the
    JSON manifest and the matching embedded copy in Get-ApprovedManifest.
    Run with -SkipDownload to only re-sync the embedded copy from the JSON.
    -ManagerTag/-ManagerAsset/-ManagerSha256 update the local manager pin
    without a download (all three together).
    After changing component versions, bump $script:InstallerVersion in
    installer.ps1 AND installer.version in approved-releases.json together.
#>
param(
    [string]$DnsproxyTag = '',
    [string]$ZapretTag = '',
    [string]$NssmVersion = '',
    [string]$NssmUrl = '',
    [string]$ManagerTag = '',
    [string]$ManagerAsset = '',
    [string]$ManagerSha256 = '',
    [switch]$SkipDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'approved-releases.json'
$installerPath = Join-Path $repoRoot 'installer.ps1'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sedg-manifest-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
try {
    function Get-UrlHash([string]$Url, [string]$Label) {
        $dest = Join-Path $workDir ([guid]::NewGuid().ToString('N') + '.zip')
        Write-Host "Downloading $Label from $Url ..."
        $curl = Join-Path (Join-Path $env:SystemRoot 'System32') 'curl.exe'
        if (Test-Path $curl) {
            & $curl --fail --location --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 600 --output $dest $Url
            if ($LASTEXITCODE -ne 0) { throw "curl.exe exited with code $LASTEXITCODE for $Url" }
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
        }
        $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        return @{ Path = $dest; Sha256 = $hash }
    }

    function Assert-ZipHas([string]$Zip, [string]$Pattern, [string]$Label) {
        $dir = Join-Path $workDir ([guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $Zip -DestinationPath $dir -Force -ErrorAction Stop
        $hit = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match $Pattern } |
            Select-Object -First 1
        if (-not $hit) { throw "$Label archive is missing expected content ($Pattern)." }
    }

    function Set-UniqueReplace([string]$Text, [string]$Old, [string]$New, [string]$What) {
        $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
        if ($count -ne 1) { throw "Expected exactly 1 occurrence of $What; found $count." }
        return $Text.Replace($Old, $New)
    }

    $manifestText = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
    $manifestNewline = if ($manifestText -match "`r`n") { "`r`n" } else { "`n" }
    $manifest = $manifestText | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.policy -ne 'approved-only') {
        throw 'Manifest schema/policy is not approved-only schema 1.'
    }

    if (-not $SkipDownload) {
        if (-not [string]::IsNullOrWhiteSpace($DnsproxyTag)) {
            if ($DnsproxyTag -notmatch '^(v)?\d+(\.\d+)*$') { throw "Invalid dnsproxy tag: $DnsproxyTag" }
            $asset = "dnsproxy-windows-amd64-$DnsproxyTag.zip"
            $dl = Get-UrlHash "https://github.com/AdguardTeam/dnsproxy/releases/download/$DnsproxyTag/$asset" 'DNSProxy'
            Assert-ZipHas $dl.Path 'dnsproxy\.exe$' 'DNSProxy'
            $manifest.components.dnsproxy.tag = $DnsproxyTag
            $manifest.components.dnsproxy.asset = $asset
            $manifest.components.dnsproxy.sha256 = $dl.Sha256
            Write-Host "dnsproxy $DnsproxyTag sha256=$($dl.Sha256)"
        }
        if (-not [string]::IsNullOrWhiteSpace($ZapretTag)) {
            if ($ZapretTag -notmatch '^(v)?\d+(\.\d+)*$') { throw "Invalid zapret tag: $ZapretTag" }
            $asset = "zapret-$ZapretTag.zip"
            $dl = Get-UrlHash "https://github.com/bol-van/zapret/releases/download/$ZapretTag/$asset" 'Zapret'
            Assert-ZipHas $dl.Path 'windows-x86_64[\\/]winws\.exe$' 'Zapret'
            $manifest.components.zapret.tag = $ZapretTag
            $manifest.components.zapret.asset = $asset
            $manifest.components.zapret.sha256 = $dl.Sha256
            Write-Host "zapret $ZapretTag sha256=$($dl.Sha256)"
        }
        if (-not [string]::IsNullOrWhiteSpace($NssmVersion)) {
            if ($NssmVersion -notmatch '^\d+(\.\d+)*$') { throw "Invalid nssm version: $NssmVersion" }
            $url = if ([string]::IsNullOrWhiteSpace($NssmUrl)) { "https://nssm.cc/release/nssm-$NssmVersion.zip" } else { $NssmUrl }
            if ($url -notmatch '^https://') { throw "NSSM URL must be https: $url" }
            $dl = Get-UrlHash $url 'NSSM'
            Assert-ZipHas $dl.Path 'win64[\\/]nssm\.exe$' 'NSSM'
            $manifest.components.nssm.version = $NssmVersion
            $manifest.components.nssm.asset = "nssm-$NssmVersion.zip"
            $manifest.components.nssm.url = $url
            $manifest.components.nssm.sha256 = $dl.Sha256
            Write-Host "nssm $NssmVersion sha256=$($dl.Sha256)"
        }
    }

    # The manager pin is local (no upstream download): these parameters update
    # it even with -SkipDownload. The repository is fixed to this project.
    $mgr = $manifest.components.manager
    if ($null -eq $mgr) { throw 'Manifest is missing the manager component.' }
    if ([string]$mgr.repository -ne 'projectofwang/sedg-suite') {
        throw 'Manifest manager.repository must be projectofwang/sedg-suite.'
    }
    $managerValues = @(@($ManagerTag, $ManagerAsset, $ManagerSha256) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($managerValues.Count -gt 0 -and $managerValues.Count -lt 3) {
        throw 'Provide -ManagerTag, -ManagerAsset and -ManagerSha256 together.'
    }
    if ($managerValues.Count -eq 3) {
        if ($ManagerTag -notmatch '^(v)?\d+(\.\d+)*$') { throw "Invalid manager tag: $ManagerTag" }
        $managerVersion = $ManagerTag -replace '^v', ''
        if ($ManagerAsset -ne ('sedg-manager-win-x64-{0}.zip' -f $managerVersion)) {
            throw "Manager asset must be sedg-manager-win-x64-$managerVersion.zip."
        }
        if ($ManagerSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid manager SHA-256: $ManagerSha256" }
        $mgr.tag = $ManagerTag
        $mgr.asset = $ManagerAsset
        $mgr.sha256 = $ManagerSha256.ToLowerInvariant()
        Write-Host "manager $ManagerTag sha256=$($mgr.sha256)"
    }

    # Canonical JSON layout. Preserve an existing optional nssm mirror so a
    # re-run never silently drops it.
    $d = $manifest.components.dnsproxy
    $z = $manifest.components.zapret
    $n = $manifest.components.nssm
    $mgrLine = ('    "manager": {{"repository":"{0}","tag":"{1}","asset":"{2}","sha256":"{3}"}},' -f $mgr.repository, $mgr.tag, $mgr.asset, $mgr.sha256)
    $existingMirror = ''
    try {
        $mirrorProp = $n.PSObject.Properties['mirror']
        if ($null -ne $mirrorProp) { $existingMirror = [string]$mirrorProp.Value }
    } catch { Write-Warning ('SEDG:Update-Manifest: $mirrorProp = $n.PSObject.Properties[''mirror''] if ($null -ne... (' + $_.Exception.Message + ')'); Write-Verbose $_ }
    $nssmLine = ('    "nssm": {{"version":"{0}","asset":"{1}","url":"{2}","sha256":"{3}"}}' -f $n.version, $n.asset, $n.url, $n.sha256)
    if (-not [string]::IsNullOrWhiteSpace($existingMirror)) {
        $nssmLine = ('    "nssm": {{"version":"{0}","asset":"{1}","url":"{2}","mirror":"{3}","sha256":"{4}"}}' -f $n.version, $n.asset, $n.url, $existingMirror, $n.sha256)
    }
    $json = @(
        '{',
        '  "schema": 1,',
        '  "policy": "approved-only",',
        ('  "installer": {{"version": "{0}"}},' -f $manifest.installer.version),
        '  "components": {',
        ('    "dnsproxy": {{"repository":"{0}","tag":"{1}","asset":"{2}","sha256":"{3}"}},' -f $d.repository, $d.tag, $d.asset, $d.sha256),
        ('    "zapret": {{"repository":"{0}","tag":"{1}","asset":"{2}","sha256":"{3}"}},' -f $z.repository, $z.tag, $z.asset, $z.sha256),
        $mgrLine,
        $nssmLine,
        '  }',
        '}'
    ) -join $manifestNewline
    $json = $json + $manifestNewline
    [IO.File]::WriteAllText($manifestPath, $json, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote: $manifestPath"

    # Rebuild the $embedded fallback block from the manifest (nssm lines stay
    # dynamic script refs).
    $installer = Get-Content -LiteralPath $installerPath -Raw -ErrorAction Stop
    $blockMatch = [regex]::Match($installer, '(?s)(\$embedded = \[pscustomobject\]@\{.*?\r?\n        \}\r?\n    \})')
    if (-not $blockMatch.Success) { throw 'Embedded manifest block not found in installer.ps1.' }
    $newBlock = @(
        '$embedded = [pscustomobject]@{',
        '        schema = 1',
        "        policy = 'approved-only'",
        '        installer = [pscustomobject]@{ version = $script:InstallerVersion }',
        '        components = [pscustomobject]@{',
        '            dnsproxy = [pscustomobject]@{',
        ("                repository = '{0}'" -f $d.repository),
        ("                tag = '{0}'" -f $d.tag),
        ("                asset = '{0}'" -f $d.asset),
        ("                sha256 = '{0}'" -f $d.sha256),
        '            }',
        '            zapret = [pscustomobject]@{',
        ("                repository = '{0}'" -f $z.repository),
        ("                tag = '{0}'" -f $z.tag),
        ("                asset = '{0}'" -f $z.asset),
        ("                sha256 = '{0}'" -f $z.sha256),
        '            }',
        '            manager = [pscustomobject]@{',
        ("                repository = '{0}'" -f $mgr.repository),
        ("                tag = '{0}'" -f $mgr.tag),
        ("                asset = '{0}'" -f $mgr.asset),
        ("                sha256 = '{0}'" -f $mgr.sha256),
        '            }',
        '            nssm = [pscustomobject]@{',
        '                version = $script:NssmVersion',
        "                asset = 'nssm-$($n.version).zip'",
        '                url = $script:Sources.NssmZip',
        '                sha256 = $script:NssmSha256',
        '            }',
        '        }',
        '    }'
    ) -join "`r`n"
    $installer = $installer.Substring(0, $blockMatch.Index) + $newBlock + $installer.Substring($blockMatch.Index + $blockMatch.Length)

    # The manager pin lives in script variables for Get-PinnedManagerSource;
    # the embedded block above carries the same values as literals.
    $oldMgrRepo = [regex]::Match($installer, '(?m)^\$script:ManagerRepository = ''([^'']+)''\r?$')
    $oldMgrTag = [regex]::Match($installer, '(?m)^\$script:ManagerTag = ''([^'']+)''\r?$')
    $oldMgrAsset = [regex]::Match($installer, '(?m)^\$script:ManagerAsset = ''([^'']+)''\r?$')
    $oldMgrSha = [regex]::Match($installer, '(?m)^\$script:ManagerSha256 = ''([^'']+)''\r?$')
    if (-not ($oldMgrRepo.Success -and $oldMgrTag.Success -and $oldMgrAsset.Success -and $oldMgrSha.Success)) {
        throw 'Manager script lines not found in installer.ps1.'
    }
    $installer = Set-UniqueReplace $installer $oldMgrRepo.Value ("`$script:ManagerRepository = '$($mgr.repository)'") '$script:ManagerRepository'
    $installer = Set-UniqueReplace $installer $oldMgrTag.Value ("`$script:ManagerTag = '$($mgr.tag)'") '$script:ManagerTag'
    $installer = Set-UniqueReplace $installer $oldMgrAsset.Value ("`$script:ManagerAsset = '$($mgr.asset)'") '$script:ManagerAsset'
    $installer = Set-UniqueReplace $installer $oldMgrSha.Value ("`$script:ManagerSha256 = '$($mgr.sha256)'") '$script:ManagerSha256'

    if (-not [string]::IsNullOrWhiteSpace($NssmVersion)) {
        # Embedded nssm resolves through script variables: update them too.
        $oldVer = [regex]::Match($installer, "(?m)^`$script:NssmVersion = '([^']+)'\r?$")
        $oldHash = [regex]::Match($installer, "(?m)^`$script:NssmSha256 = '([^']+)'\r?$")
        $oldUrl = [regex]::Match($installer, "(?m)^\s*NssmZip\s+= '([^']+)'\r?$")
        if (-not ($oldVer.Success -and $oldHash.Success -and $oldUrl.Success)) {
            throw 'NSSM script lines not found in installer.ps1.'
        }
        $installer = Set-UniqueReplace $installer $oldVer.Value ("`$script:NssmVersion = '$NssmVersion'") '$script:NssmVersion'
        $installer = Set-UniqueReplace $installer $oldHash.Value ("`$script:NssmSha256 = '$($n.sha256)'") '$script:NssmSha256'
        $installer = Set-UniqueReplace $installer $oldUrl.Value ("NssmZip     = '$($n.url)'") 'Sources.NssmZip'
    }

    [IO.File]::WriteAllText($installerPath, $installer, [Text.UTF8Encoding]::new($false))
    Write-Host "Synced: installer.ps1 embedded manifest"

    $instVer = [regex]::Match($installer, "(?m)^`$script:InstallerVersion = '([^']+)'\r?$")
    if ($instVer.Success -and ([string]$instVer.Groups[1].Value -ne [string]$manifest.installer.version)) {
        Write-Warning ("Version drift: installer.ps1={0} manifest={1}. Bump both together." -f $instVer.Groups[1].Value, $manifest.installer.version)
    } else {
        Write-Host ("Versions in sync: " + $manifest.installer.version)
    }
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
