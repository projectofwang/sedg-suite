# UA Onboarding — sedg-suite

Curated guide generated from `.ua/knowledge-graph.json` (commit `df681a1`).

## Project Overview

Automatic Windows installer and manager for a local DNS + traffic-routing
gateway built on **dnsproxy** (AdGuard) and **zapret/winws**, wrapped as
Windows services via **NSSM** plus a watchdog scheduled task.

- Entry point: `installer.ps1 -Action <X>` (default `Menu`); also
  `irm https://dl.taiyuanwangjie.dpdns.org/installer.ps1 | iex`.
- Trust root: `approved-releases.json` pins every component by tag + SHA-256
  (`schema:1`, `policy:approved-only`).
- Distribution: static assets-only deploy on `dl.*` (no Worker script);
  binaries always come from pinned upstreams, never the CF host.
- Install path: `C:\serverless-edge-dns-gateway` (2 services +
  `SEDG-DNS-Watchdog` task).

## Architecture Layers

| Layer | Contents |
|---|---|
| **installer-core** | `installer.ps1` + 5 key functions + `manifest-pinning`, `staged-commit` concepts |
| **manifest-tooling** | `approved-releases.json`, `tools/Update-Manifest.ps1`, `package.json` scripts |
| **distribution** | `cloudflare/build.sh`, `wrangler.toml`, `landing.html` + `assets-only-deploy` concept |
| **tests-docs** | Pester suites (`Installer.Logic`, `Installer.Maintain`) + `README.md` |

## Key Concepts

- **manifest-pinning** — approved-only policy: remote manifest → GitHub
  fallback → embedded copy (with warning). `Update-Manifest.ps1` keeps the
  embedded fallback in sync; version mismatch is a hard error.
- **staged-commit** — two-phase install: download → SHA-256 verify → stage in
  an admin-only dir, then commit with a rollback snapshot. A locked
  `WinDivert64.sys` differing from staged means reboot-and-retry, never a
  forced delete of a loaded driver.
- **assets-only-deploy** — `build.sh` is the sole generator of
  `cloudflare/public/` (CRLF-normalized copies, `_headers`, `version.json`,
  `SHA256SUMS`, version-parity gate). Served statically on the custom domain;
  `workers_dev = false`.

## Guided Tour

1. **Single entry point** — one `-Action` dispatcher (`switch ($Action)`
   ~L3600): Install/Update/Pause/Resume/Restart/Uninstall/Status/SetUpstream/
   SetDns/Menu.
2. **Trust starts at the manifest** — `Get-ApprovedManifest` (~L704) loads
   pinned versions; refuses on schema/policy/version mismatch.
3. **Stage and verify** — `Install-StageComponents` (~L1580) downloads per
   manifest and `Verify-Sha256` (~L770) checks each archive pre-extraction.
4. **Commit with rollback** — `Install-CommitComponents` (~L1723) snapshots,
   swaps, preserves user files (`blacklist.txt`, `winws-args.txt`), rolls back
   on failure.
5. **Watchdog keeps DNS alive** — `Write-WatchdogFile` (~L2259) emits a
   standalone per-minute script: service restart, new-adapter coverage,
   3-strikes DHCP fail-open (`-FailClosed` to disable).
6. **Ship it and maintain it** — `build.sh` → static deploy; bump pins with
   `Update-Manifest.ps1 -SkipDownload` (re-sync) or full tags; `npm test` /
   `Invoke-Pester ./tests` to verify.

## File Map

| File | Role |
|---|---|
| `installer.ps1` | The monolith: dispatcher, staging, services, watchdog, i18n |
| `approved-releases.json` | Pinned manifest (installer 1.2.0, dnsproxy v0.86.0, zapret v72.13, nssm 2.24) |
| `tools/Update-Manifest.ps1` | Regen manifest + patch embedded fallback in installer |
| `cloudflare/build.sh` | Build + integrity + parity gate for static deploy |
| `cloudflare/wrangler.toml` | Source of truth: name/route/compat date, assets `./public` |
| `cloudflare/landing.html` | Static landing page → `public/index.html` |
| `package.json` | npm scripts (Pester, build/deploy), wrangler 4.147.0 |
| `tests/Installer.Logic.Tests.ps1` | Unit/mocked Pester suite |
| `tests/Installer.Maintain.Tests.ps1` | Parity/maintenance Pester suite |
| `README.md` | User docs: actions, switches, config, troubleshooting |

## Complexity Hotspots

- **`installer.ps1` is the main hotspot** — 113 functions, ~199KB single
  script; the staged-commit pair (`Install-StageComponents` /
  `Install-CommitComponents`) carries the most branching (driver-lock,
  rollback paths). Change it with Pester green and the manifest in sync.
- `tools/Update-Manifest.ps1` — regex surgery on the installer; its
  single-occurrence replace guard is load-bearing.
- `cloudflare/build.sh` — small but strict: version-parity gate fails the
  build on any installer/manifest drift.
