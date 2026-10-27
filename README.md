# sedg-suite

Automatic Windows installer and manager for a local DNS + traffic-routing gateway built on Zapret and AdGuard DNSProxy.

[![CI](https://github.com/projectofwang/sedg-suite/actions/workflows/ci.yml/badge.svg)](https://github.com/projectofwang/sedg-suite/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/projectofwang/sedg-suite)](https://github.com/projectofwang/sedg-suite/releases)

## Overview

This repo sets up Windows the same way every time: it downloads pinned release
components, installs them in a fixed folder, registers them as Windows
services, and keeps DNS working with a scheduled watchdog task.

On Windows 11 x64, the **SEDG Desktop Manager** is the primary management
surface: status, DNS upstream, service control, logs, and update/uninstall. The
installer script (`installer.ps1`) remains the bootstrap and the `-Action` CLI
for automation and recovery. All component versions are pinned in
[`approved-releases.json`](approved-releases.json), including the manager asset.

The engine installs `sedg-manager.exe` inside the install folder
(`C:\serverless-edge-dns-gateway` by default); uninstalling the gateway removes
it too. `Gateway-Manager.bat` in the engine folder remains the
one-release-cycle rollback path to the console menu if the GUI cannot start.

## Features

- **SEDG Desktop Manager** (Rust + Tauri): status, upstream, service
  control, logs, update/uninstall; privileged actions go through the same
  executable's broker mode, and the GUI itself stays unprivileged.
- One-line install, update, pause, resume, restart, status, and uninstall actions.
- Console rollback path (`Gateway-Manager.bat`, created in the install folder)
  that self-elevates to administrator.
- DNS service (dnsproxy) with selectable upstream presets or a custom DoH/DoT/DoH3/DoQ endpoint.
- Traffic-routing service (winws) with an editable argument file and an optional domain blacklist.
- Watchdog scheduled task that runs every minute and restores DHCP-assigned DNS after
  3 consecutive failures (fail-open; can be made sticky with `-FailClosed`).
- Automatic coverage of newly connected network adapters.
- Staged, per-file SHA-256 verified downloads written to an administrator-only directory.
- Per-adapter DNS backups that are never overwritten with temporary bootstrap data.
- Fail-safe rollback: a failed install or update restores the previous state.
- Localized menu output (English and Vietnamese).

## Requirements

Requirements checked by the installer (`installer.ps1`):

- Engine: Windows 10 version 1803 (build 17134) or newer, 64-bit x64; ARM64 is rejected by the engine.
- Desktop Manager GUI: Windows 11 x64 only. Windows 10 and ARM64 are **not**
  supported GUI targets. This is an observed compatibility statement, not a
  claim of Microsoft support.
- The published manager is a single self-contained `win-x64` `sedg-manager.exe`;
  no .NET install is required, and Windows 11 provides the WebView2 runtime it
  uses.
- Windows PowerShell 5.1 or newer for the engine.
- Administrator privileges (the launcher and script elevate automatically; the
  GUI asks the broker for privileged actions).
- Outbound HTTPS access to the release endpoints listed in
  [`approved-releases.json`](approved-releases.json).

## Install

On Windows 11 x64, install once with the published one-line bootstrap. It
installs the engine and the Desktop Manager. Run in an elevated PowerShell:

```powershell
irm https://dl.taiyuanwangjie.dpdns.org/installer.ps1 | iex
```

Or download the repo and run the script yourself (the default action is
the interactive menu):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer.ps1 -Action Install
```

The default installation directory is `C:\serverless-edge-dns-gateway`. The
install registers two services (`winws-service`, `dnsproxy-service`) and one
scheduled task (`SEDG-DNS-Watchdog`). It also installs `sedg-manager.exe` in
the same folder. Run `sedg-manager.exe` after install; it is the primary
management surface. `Gateway-Manager.bat` in the engine folder remains the
one-release-cycle rollback path to the console menu.

The published manager is one self-contained `win-x64` executable;
`tools/Publish-Manager.ps1` builds and verifies the zip, and its only mode is
the release payload.

> **Manager release status:** the manager is pinned in
> `approved-releases.json` as `sedg-manager-win-x64-2.0.1.zip`, published on the
> bare `2.0.1` release tag because releases are immutable. Installer/engine
> real-machine acceptance passed on 2026-10-26 with installer `v2.0.1` (clean
> install + reboot, same-version update drill, pause/resume, restart, upstream,
> DNS, CDN, uninstall + reboot). Installer `v2.0.2` packages the per-step
> progress stream and the real manager match, but has not had a full
> real-machine rerun. The `2.0.0` manager GUI and broker path were exercised
> on 2026-10-27: setup installed (repair over an interrupted first attempt)
> from the published zip, the dashboard toggled EN/VI, and Pause/Resume/Restart
> ran through the elevated broker (UAC prompt observed for Restart; all three
> recorded `ok` in the operation log). A second GUI pass exercised CDN, Set
> upstream (custom + reset), Set DNS (`1.1.1.1` + restore), and Uninstall.
> Uninstall removed the services, watchdog task, and DNS settings, but left the
> install tree and did not schedule it for reboot; the folder needs an elevated
> removal. GUI Update is still untested. The unelevated dashboard reports the
> SYSTEM watchdog task as missing by ACL. Manager `2.0.1` adds per-step progress
> and reports `equal`, `mismatch`, or `unknown` from the embedded pin without a
> network call. The planned `1.2.6` rollback drill could not be run because that
> release was never published.

## Usage

The Desktop Manager exposes the same operations through its windows; the
command line below remains for automation, recovery, and the
`Gateway-Manager.bat` rollback path.

Command line:

```powershell
# Install
.\installer.ps1 -Action Install

# Show status (versions, upstream, local DNS)
.\installer.ps1 -Action Status

# Change the DNS upstream (an absolute encrypted-DNS URL)
.\installer.ps1 -Action SetUpstream -Upstream https://cloudflare-dns.com/dns-query

# Restart, pause, or resume the services
.\installer.ps1 -Action Restart
.\installer.ps1 -Action Pause
.\installer.ps1 -Action Resume

# Update to the latest approved release
.\installer.ps1 -Action Update

# Uninstall
.\installer.ps1 -Action Uninstall
```

Actions: `Install`, `Update`, `Pause`, `Resume`, `Restart`, `Uninstall`,
`Status`, `SetUpstream`, `SetDns`, `Menu`.

Available switches:

| Switch | Effect |
| --- | --- |
| `-Upstream <value>` | Absolute upstream URL using `https://`, `tls://`, `h3://`, or `quic://`. Preset names are chosen interactively from the menu. |
| `-Language <en\|vi>` | Menu language for this run. |
| `-IncludeCdnTest` | Run the CDN reachability test after install or update. |
| `-ForceUpdate` | Skip early-out version checks and force a fresh download. |
| `-Clean` | Perform a fresh install instead of the in-place update route. |
| `-DnsOnly` | Install DNS only; the winws service is registered with a manual (demand) start type and is not started. |
| `-Purge` | With `Uninstall`, also remove logs, the language file, touched-adapter records, and staging data. |
| `-FailClosed` | Disable the DHCP fallback (persisted for the watchdog). |
| `-Action Menu` | Open the interactive menu. |

Interactive menu (after `-Action Menu` or by running `Gateway-Manager.bat`):

1. Install
2. Update
3. Status
4. Restart
5. Pause
6. Resume
7. DNS upstream
8. System DNS
9. CDN test
10. Uninstall
11. Language
0. Exit

## Configuration

Files live under the install directory (`C:\serverless-edge-dns-gateway`):

| File | Purpose |
| --- | --- |
| `config.yaml` | dnsproxy configuration: local listeners `127.0.0.1:53` and `[::1]:53`, upstream server, fallback resolver, bootstrap servers, cache TTL. |
| `blacklist.txt` | Domain rules for winws. Empty by default, which matches nothing (no traffic is altered until entries are added). |
| `winws-args.txt` | winws command-line arguments, stored as UTF-8 without BOM. |

`config.yaml`, `blacklist.txt`, and `winws-args.txt` are preserved across
updates and reinstalls.

DNS upstream presets: SDEG (default), Cloudflare, Google, Quad9,
AdGuard, or a custom encrypted-DNS URL. The active upstream is shown by
`-Action Status` and stored in `config.yaml`.

Bootstrap resolvers (`1.1.1.1`, `8.8.8.8`, and their IPv6 equivalents) are
applied to physical adapters only when the release hosts do not resolve, so
downloads can still succeed. These temporary values are tracked and never
written over a user's per-adapter DNS backup. The `config.yaml` bootstrap list
used by dnsproxy also includes `9.9.9.9` and `208.67.222.222`.

## Updating

```powershell
.\installer.ps1 -Action Update
```

The update flow reads `approved-releases.json` and compares component versions.
It downloads only what changed into a staging folder, verifies each file with
SHA-256, then swaps it in. Use `-ForceUpdate` to skip those version checks. If
a driver file is locked by the running system, the installer stops and asks for
a reboot instead of deleting the locked file.

Release metadata is published as `version.json` alongside `SHA256SUMS`, so you
can check a downloaded installer before you run it.

## Uninstalling

```powershell
.\installer.ps1 -Action Uninstall
```

Uninstall stops and removes both services, removes the watchdog task, and
restores the per-adapter DNS backups taken at install time. Files that are
locked by Windows are normally scheduled for deletion at the next reboot; if
the install folder remains (for example because the manager was still running),
close the manager and remove the folder from an elevated shell. Add `-Purge`
to also delete logs, the language file, touched-adapter records, and staging
data.

## Troubleshooting

- **Check current state**: `.\installer.ps1 -Action Status` reports service
  state, local DNS, the active upstream, and installed component versions.
- **Service logs**: winws output is written to `zapret\winws.log` under the
  install directory; dnsproxy writes `dnsproxy.log` and `dnsproxy-nssm.log`
  under the `dnsproxy` directory. The winws log path is also shown by the
  status action.
- **"Reboot required" during update**: a staged driver differs from the loaded
  one. Reboot Windows and run the update again; the installer does not delete
  locked driver files outside of uninstall.
- **Adapter not covered**: the status output can warn that a specific adapter
  is not using the local resolver. Re-run `-Action Restart` or `-Action SetDns`
  so the watchdog re-applies DNS to the new adapter.
- **DNS falls back to DHCP**: after 3 consecutive watchdog failures the task
  switches the adapter back to DHCP-assigned DNS (fail-open). Check
  `winws.log`, then restart the services; with `-FailClosed` the fallback is
  disabled and the previous state is kept instead.
- **Downloads fail**: install requires HTTPS reachability to the release host.
  Bootstrap DNS is applied automatically only when release hosts do not
  resolve.

## Trust and privacy

- No telemetry: the installer and services make no analytics or reporting
  calls. Network traffic is limited to release downloads, the release manifest,
  configured DNS upstreams, and traffic-routing rules the user enables.
- HTTPS-only downloads with per-file SHA-256 verification. Staging happens in
  an administrator-only directory under `ProgramData`.
- No GitHub API usage: downloads go directly to release asset URLs, and the
  release manifest is fetched from the project endpoint with a raw GitHub
  fallback.
- Component versions are pinned in `approved-releases.json`; the manifest can
  fall back to an embedded copy, in which case the installer warns that it is
  using embedded versions.
- Releases are published from `vX.Y.Z` tags protected by an immutable-tag
  ruleset, and releases created by the workflow are marked immutable.
- The installer script and release binaries are not code-signed; verify the
  checksum files before running them.
- DNS backups are stored per adapter (by interface GUID) and are only restored
  with the values captured at install time.
- An empty `blacklist.txt` matches nothing, so a default install changes no
  application traffic.

## Development

Repository tasks:

```powershell
# Run the test suite (Pester 5.2 or newer)
Invoke-Pester ./tests

# Lint (PSScriptAnalyzer, errors only)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error -ExcludeRule PSAvoidUsingWriteHost

# Re-sync the embedded fallback manifest from approved-releases.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-Manifest.ps1 -SkipDownload

# Build and test the Rust manager
cargo build --release --locked --manifest-path src/rust/Cargo.toml
cargo test --locked --manifest-path src/rust/Cargo.toml

# Package the pinned manager zip (writes only under -OutDir)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-Manager.ps1
```

CI runs the baseline PowerShell, ASCII, PSScriptAnalyzer, Pester, manifest/EN-VI
parity, and Cloudflare gates, a legacy .NET job for the retired solution, and a
`windows-latest` Rust job that builds the manager, runs its tests, and lints with
Clippy. The manifest gate also checks the `manager`
repository/tag/asset/SHA and its embedded `$script:Manager*` pins.

### Integration smoke (CI)

The `integration` workflow (manual dispatch, weekly schedule) runs the real
installer end to end on a disposable Windows runner: `Install`, `Status`,
`Restart`, and `Uninstall -Purge` with real NSSM services, the real watchdog
scheduled task, and real DNS mutation and restore. Components are stub
executables built from source by `tests/integration/Build-Fixtures.ps1` and
served over loopback HTTP; NSSM itself is the real pinned archive. The
installer's `SEDG_INSTALL_PATH` / `SEDG_MANIFEST_URL` / `SEDG_ASSET_BASE_URL`
seams keep the run isolated, and per-file SHA-256 verification stays
enforced throughout.

The fixture builder currently creates dnsproxy/zapret/NSSM stubs and does not
include the manager component or a manager asset. The scheduled smoke will fail
at the engine's required-manager check until that fixture is extended; the
desktop manager remains integration-unverified.

`tools/Update-Manifest.ps1` accepts `-DnsproxyTag`, `-ZapretTag`,
`-NssmVersion`, `-NssmUrl`, `-ManagerTag`, `-ManagerAsset`,
`-ManagerSha256`, and `-SkipDownload`. Check
[`approved-releases.json`](approved-releases.json) for the current pinned
values instead of copying version numbers from this document.

Frontend / Worker assets:

```bash
npm run build:cloudflare   # build the Cloudflare assets
npm test                   # same Pester suite via npm
```

Static hosting and deployment details are described in
[`cloudflare/README.md`](cloudflare/README.md). Contribution guidelines are in
[`CONTRIBUTING.md`](CONTRIBUTING.md) and security reporting in
[`SECURITY.md`](SECURITY.md).

## Release process

- Releases are created from `vX.Y.Z` tags; the tag must match the installer
  version declared in `installer.ps1`, otherwise the workflow fails.
- The manager is published as one self-contained `win-x64`
  `sedg-manager-win-x64-X.Y.Z.zip`; `approved-releases.json` and the embedded
  `$script:Manager*` pins must use that exact tag/asset/SHA. A rebuild is not
  byte-reproducible, so upload the pinned artifact, not a fresh build.
- Gateway uninstall removes `sedg-manager.exe` with the rest of the install
  folder (the retired `%ProgramFiles%\SEDG Manager` copy is cleaned up too).
- The release workflow builds the assets, generates `version.json` and
  `SHA256SUMS`, and publishes the release.
- Releases are immutable: assets must be attached at creation. The installer
  release stays `vX.Y.Z`; the locally built, non-reproducible manager artifact
  is published on a bare `X.Y.Z` release, which `$script:ManagerTag` accepts.
- A scheduled workflow runs every Monday at 02:00 UTC, checks the pinned
  upstream component versions, and opens a pull request when a new version is
  available.
- Pushing to `main` runs the CI workflow (checks only). Deployment of the
  download and SDNS endpoints is handled by the Cloudflare Git integration;
  see [`cloudflare/README.md`](cloudflare/README.md).

## Project layout

```text
.
|-- .github/
|   `-- workflows/          CI, release, and component-watch workflows
|-- cloudflare/             Static assets-only channel (no Worker script), build script, deployment docs
|-- src/                    Retired .NET 10 solution, kept as rollback reference
|   |-- Sedg.Desktop/       WinForms management surface
|   |-- Sedg.Broker/        Elevated broker and pipe protocol host
|   `-- Sedg.Protocol/      Shared request/response schema
|-- src/rust/               Rust/Tauri manager (shipped)
|   |-- src-tauri/          Manager, broker, and setup modes
|   `-- ui/                 HTML/CSS/JS front end
|-- tests/                  Pester and .NET test suites
|   |-- Sedg.UnitTests/     Zero-dependency .NET unit harness
|   |-- Installer.Logic.Tests.ps1
|   |-- Installer.Maintain.Tests.ps1
|   `-- integration/        Elevated end-to-end smoke (Invoke-Smoke.ps1, Build-Fixtures.ps1)
|-- docs/                   Function contracts, security audit, upstream design
|-- tools/
|   |-- Update-Manifest.ps1 Regenerates approved-releases.json and embedded pins
|   `-- Publish-Manager.ps1 Publishes the win-x64 manager
|-- approved-releases.json  Pinned component versions and manifest URLs
|-- installer.ps1           Installer, menu, services, and watchdog logic
|-- package.json            Build, deploy, and test scripts
|-- codemap.md              Repository atlas (start here)
|-- README.vi.md            Vietnamese version of this README
|-- CHANGELOG.md
|-- CODEOWNERS
|-- CONTRIBUTING.md
|-- SECURITY.md
|-- THIRD-PARTY.md
`-- LICENSE
```

## Thanks

- [BIBICADOTNET](https://github.com/BIBICADOTNET) for the original automatic
  install script concept.
- [AdGuard DNSProxy](https://github.com/AdguardTeam/dnsproxy) for the local DNS
  resolver.
- [Zapret](https://github.com/bol-van/zapret) for the traffic-routing engine.
- [NSSM](https://nssm.cc/) for the Windows service wrapper.

This project was written with AI assistance.

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE) for
the full text. Third-party components keep their own licenses; see
[`THIRD-PARTY.md`](THIRD-PARTY.md).
