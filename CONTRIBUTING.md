# Contributing

Keep changes small and easy to revert. Every change must pass the same checks
CI runs (`.github/workflows/ci.yml`).

## Requirements

- Windows PowerShell 5.1 (the installer targets 5.1; no PowerShell 7-only
  syntax).
- Pester 5.2+ (`tests/Installer.Logic.Tests.ps1` has `#Requires` Pester
  5.2.0). Windows ships Pester 3.4, so install 5.2 and force-import it:

```powershell
Install-Module Pester -RequiredVersion 5.2.0 -Scope CurrentUser -Force
Import-Module Pester -MinimumVersion 5.2.0 -Force
```

## Tests

```powershell
Invoke-Pester ./tests
```

Logic tests only: no admin, no network, no real services or registry writes.
Tests that touch destructive paths (DNS, services, downloads) must mock them.

## Lint / static checks (what CI runs)

1. Parse every `*.ps1` with the Windows PowerShell 5.1 PSParser: 0 errors.
2. `installer.ps1` must stay pure ASCII (0 chars outside `\x00-\x7F`). Markdown
   files are exempt, but keep them clean ASCII too.
3. PSScriptAnalyzer at errors only (only `PSAvoidUsingWriteHost` excluded):

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error -ExcludeRule PSAvoidUsingWriteHost
```

## Version and manifest parity

Single version source: `installer.ps1` (`$script:InstallerVersion = '1.2.5'`).
These must stay in lockstep:

- `approved-releases.json` -> `installer.version` (CI fails on mismatch).
- The `vX.Y.Z` git tag (the release workflow refuses a mismatched tag).
- The released heading in `CHANGELOG.md` (convention; not CI-checked).

Component tags and SHA-256 hashes live in `approved-releases.json` and must
also appear embedded in `installer.ps1` (offline fallback manifest; CI checks
both). Regenerate with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-Manifest.ps1 -DnsproxyTag v0.86.0 -ZapretTag v72.13
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-Manifest.ps1 -SkipDownload  # re-sync only
```

Then bump `$script:InstallerVersion` and `installer.version` together.

## Language parity (EN/VI)

The `EN = @{...}` and `VI = @{...}` tables in `installer.ps1` must have the
same key set (CI fails on drift). If you change the meaning of a `README.md`
section, mirror it in `README.vi.md` (unaccented VI, same structure).

## Release

1. Update `CHANGELOG.md`: move items from `## [Unreleased]` into a new
   `## [X.Y.Z] - YYYY-MM-DD` heading, date from `git log --format=%cs`, then
   recreate an empty `## [Unreleased]` on top.
2. Bump the version in `installer.ps1` and `approved-releases.json`, run the
   tests and parity gates above.
3. Merge to `main` (deploys the site via Cloudflare), then push tag `vX.Y.Z`
   matching the installer version; `.github/workflows/release.yml` publishes
   the GitHub Release assets. Tags and releases are immutable - never move or
   delete them.

## Scope

- Docs and test tasks must not change install, uninstall, service, or DNS
  behavior.
- Keep `installer.ps1` ASCII-only (no accents, no box-drawing chars).
- Prefer small commits you can undo later. Record user-visible changes in
  `CHANGELOG.md` under `## [Unreleased]`.
