# Security Policy

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0.0 | :x:                |

Older versions update themselves to the latest release when you run Update or
Install while online. Always update before reporting an issue.

## Trust model

- The installer is unsigned, so verify the download before you run it. The
  landing page has the 3 steps: download the file, compare its SHA-256 with
  `version.json`, then run it.
- Component binaries are pinned by SHA-256 in `approved-releases.json`.
  The WinDivert driver is trusted through that same manifest hash; it is
  not separately checked for an Authenticode signature.
- The manifest is trusted through HTTPS and a matching installer/manifest
  version. Anyone who can push to `main` or publish the Cloudflare deployment
  can change which binaries users install. `main` blocks force-pushes, `v*`
  tags are immutable, and the Cloudflare account needs 2FA.
- Manager self-update downloads `installer.ps1` from the same distribution
  origin, hash-pinned by `version.json`. That is unsigned script execution:
  a compromised origin means remote code execution, not just swapped
  binaries. `version.json` itself is trust-on-first-use — there is no
  out-of-band pin for it the way the landing page pins `installer.ps1`.
- A compromised manifest host can replay an older but otherwise valid
  manifest (downgrade): SHA pinning lives inside the manifest itself, so old
  pins still verify. The installer warns when the remote manifest is older
  than its embedded copy or the last-run state, but still honors it. Defense
  in depth stays: HTTPS + installer/manifest version check, GitHub allow-list
  for asset URLs, SHA-256 verification of every binary, and the embedded
  offline fallback.

## Reporting a vulnerability

Open a private security advisory on GitHub or contact the maintainer directly.
Do not open a public issue for unpatched privilege-escalation, installer
bypass, or supply-chain concerns. Please include steps to reproduce, Windows
build, and relevant logs from `%ProgramData%\serverless-edge-dns-gateway\logs`.

Contact: open a private advisory at
https://github.com/projectofwang/sedg-suite/security/advisories/new
(or the maintainer email listed on the GitHub profile). Allow up to 7 days
for triage before any public disclosure.
