# F1 + F2 fix report

Fixes for the two High findings in `docs/analysis/installer-risk-audit.md`.

- Scope: `installer.ps1`, `tests/*.ps1`, this report. `approved-releases.json` and
  `tools/Update-Manifest.ps1` were not changed.
- No real install, update, uninstall, download, service, scheduled task or DNS
  operation was executed.

## 1. Root cause

### F1 — NSSM ran bytes chosen by the manifest

`Install-StageComponents` built the NSSM download from
`manifest.components.nssm.url`, `sha256`, and `version`, using the embedded
constants only when a field was empty. `Assert-ManifestComponents` requires those
fields, so the embedded pin was effectively dead. Because `Get-ApprovedManifest`
may fall back to the `main`-branch manifest, whoever controls that branch could
pair an arbitrary URL with a matching SHA-256 and get an Administrator/SYSTEM
binary executed. Unlike `dnsproxy`/`zapret`, NSSM had no repository allow-list.

### F2 — Uninstall skipped cleanup when the install directory was gone

`Uninstall-All` returned immediately when `Test-Path $script:InstallPath` was
false, before `Remove-Services` and `Unregister-ScheduledTask`. A half-removed
install therefore kept the `SYSTEM` watchdog task (firing every minute against a
deleted `watchdog.ps1`) and any surviving services. Additionally,
`Remove-Services` threw on the 10-second service-wait timeout before reaching
`Unregister-ScheduledTask`, so one stuck service also preserved the task.

## 2. Files changed

| File | Change |
| --- | --- |
| `installer.ps1` | Added `Get-PinnedNssmSource` and `Install-StageNssm`; rewired `Install-StageComponents`; rewrote `Remove-Services`; rewrote cleanup flow in `Uninstall-All`. |
| `tests/Installer.HighRiskFixes.Tests.ps1` | New F1/F2 regression suite (14 tests). |
| `tests/Installer.Maintain.Tests.ps1` | Added a `Get-ScheduledTask` stub and updated two call-order assertions to the new unregister-first order. Assertions were reordered, not weakened. |
| `docs/analysis/f1-f2-fix-report.md` | This report. |

`approved-releases.json` is unchanged and still matches the embedded pin
(`2.24`, `nssm-2.24.zip`, `https://nssm.cc/release/nssm-2.24.zip`,
`727d1e42...6743`).

## 3. F1 trust model

The trust anchor is the script itself:

- `$script:Sources.NssmZip`, `$script:NssmSha256`, `$script:NssmVersion`.
- `Get-PinnedNssmSource` validates the embedded anchor (64 hex chars, https URL),
  then requires the manifest's `version`, `asset`, `url`, and `sha256` to equal
  it exactly (case-insensitive on the digest). Any mismatch, missing component,
  or malformed pin throws before a download starts.
- `Install-StageComponents` calls `Get-PinnedNssmSource` immediately after
  `Assert-ManifestComponents`, so a bad manifest is rejected before any component
  (DNSProxy, Zapret, NSSM) is fetched.
- `Install-StageNssm` calls the same gate internally and uses only the returned
  pin. The archive is downloaded, SHA-256 verified, and only then extracted and
  copied. There is no fallback to manifest-supplied URL/hash on failure.
- The optional manifest `mirror` remains a download fallback only. Its bytes are
  still verified against the embedded digest, so it cannot change what is
  installed.

`tools/Update-Manifest.ps1` already rewrites the three constants when NSSM
changes, so the embedded pin stays in sync with releases without a schema change.

## 4. F2 cleanup flow

`Remove-Services`:

1. Looks up the watchdog task and unregisters it first when present; a missing
   task is treated as already clean. An unregister failure is recorded.
2. Stops and deletes each app-scoped service (`$script:WinwsService`,
   `$script:DnsProxyService`) using NSSM when available, else `sc.exe`.
3. Waits up to 10 seconds for both services to disappear.
4. Throws once at the end with all accumulated errors (unregister, delete,
   timeout), so no single step suppresses the rest.

`Uninstall-All`:

1. Always runs stop/DNS/gateway/watchdog/service/task/WinDivert cleanup,
   whether or not the install directory exists. A missing directory still prints
   `NotInstalled`, but no longer returns early.
2. `Stop-AllServices` is best-effort (warning); `Remove-Services` remains
   authoritative for service/task residue.
3. `Remove-Services` and WinDivert removal failures are collected; file-tree
   removal only runs when the directory existed; then the function throws
   `Uninstall incomplete: ...` if any real error was collected.
4. App-scoped names are unchanged, and cleanup stays idempotent (already-absent
   services/tasks are not errors).

## 5. Pester run and results

Pester 5.7.1 was used (CurrentUser install for pwsh 7.6.7 and Windows PowerShell
5.1). Tests were run over the `\\wsl.localhost\...` share with
`-ExecutionPolicy Bypass` so unsigned test scripts can be discovered.

Command (per file or the whole `tests` directory):

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path '<windows path to tests>' -Output Detailed
```

Results:

| Run | Result |
| --- | --- |
| `Installer.HighRiskFixes.Tests.ps1` (pwsh 7.6.7) | 14 passed, 0 failed |
| Whole `tests` directory (pwsh 7.6.7) | 130 passed, 0 failed |
| Whole `tests` directory at HEAD (baseline) | 116 passed, 0 failed |
| Whole `tests` directory (Windows PowerShell 5.1) | 128 passed, 2 failed |
| Whole `tests` directory at HEAD (Windows PowerShell 5.1 baseline) | 114 passed, 2 failed |

The two PS 5.1 failures are pre-existing and unrelated: `Installer mutex.balances
recursive acquire/release` and `H4 DNS backup signals.Get-StaticDnsServers reads
registry NameServer`. They reproduce identically on HEAD.

`Installer.Maintain.Tests.ps1` alone still has the same 6 pre-existing failures
before and after the change (missing `Get-AssetDownloadBase`, `Test-DownloadUrl`,
`Test-DnsUpstream` imports, one `Test-ConfigValid`, and one upstream-block pin).
When the whole directory runs, the other test files supply those helpers, so the
combined run is green.

Parse check: `Parser::ParseFile` reports 0 errors for `installer.ps1` on
PowerShell 7.6.7 and 5.1.26100.9711.

## 6. Safety confirmation

- No real Install/Update/Uninstall was run; no component was downloaded; no
  service, scheduled task, DNS setting, ACL or registry key was touched.
- The new tests stub every system-touching command (`Download-File`,
  `Expand-Zip`, `Invoke-Nssm`, `Get/Unregister-ScheduledTask`,
  `Get/Stop-Service`, `sc.exe`, `Remove-Item` targets are `TestDrive` paths).
- Tests extract production functions from `installer.ps1` via the AST (the
  repo's existing test pattern) rather than reimplementing them, so assertions
  run against the shipped code.
- F1 tests include a positive case (pinned bytes verify and stage), a full
  manifest-substitution case, single-field tampering, fail-closed cases, a
  digest-mismatch case that asserts no extraction/copy/execution, and a mirror
  case that verifies the same digest. The verifier is not mocked.
- F2 tests assert the task is unregistered before service deletion, idempotency
  when everything is gone, a real unregister failure being reported, cleanup
  with no install directory, and cleanup continuing after a service timeout.

## 7. Diff scope and residual risks

Diff scope: `installer.ps1` (134 insertions, 65 deletions), the new 14-test
file, two ordered assertions plus one stub in `Installer.Maintain.Tests.ps1`, and
this report. Pre-existing working-tree changes (`.gitignore`, `AGENTS.md`, and
untracked tooling directories) were not modified.

Residual risks:

- Any manifest that intentionally diverges from the embedded NSSM pin now fails
  closed. This is the intended behavior, but a release that updates NSSM must go
  through `tools/Update-Manifest.ps1` (or edit both the script constants and the
  manifest together).
- The embedded URL is still `https://nssm.cc`; integrity rests on the embedded
  SHA-256, not on host allow-listing. That matches the audit's recommendation to
  keep the pinned digest as the trust root.
- `Uninstall-All` can print `NotInstalled` and then still throw
  `Uninstall incomplete: ...` if a leftover service/task cannot be removed. That
  is deliberate: absence of files must not be reported as a clean uninstall.
- If `Get-ScheduledTask` itself fails (for example the ScheduledTasks module is
  unavailable), the failure is recorded and surfaces as an incomplete uninstall
  instead of being silently ignored.
- The service-wait timeout message text is unchanged; it is now aggregated with
  other errors instead of aborting the function immediately.
