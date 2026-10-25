# Changelog

## [Unreleased]

## [1.2.5] - 2026-10-24

- Publish the pinned SEDG Manager artifact on a bare `1.2.5` release tag:
  GitHub releases are immutable, so the `vX.Y.Z` workflow release cannot accept
  the locally built, non-reproducible archive after publication.
- Bump InstallerVersion 1.2.4 -> 1.2.5. Contains the 1.2.4 protocol fix below.

## [1.2.4] - 2026-10-24

- Tagged, not released: the release could not carry the manager asset and
  immutable releases refuse later uploads. Superseded by 1.2.5.
- Decode protocol stdin as UTF-8 in `-Protocol jsonl`, so the engine no longer
  rejects every request when the host console uses an OEM code page (the CI
  runner decodes the pipe as IBM437). The existing BOM strip stays.
- Write protocol stdin as UTF-8 without BOM from the Desktop Manager and broker.
- Bump InstallerVersion 1.2.3 -> 1.2.4 and pin SEDG Manager
  `sedg-manager-win-x64-1.2.4.zip` (self-contained `win-x64`).
  (This entry also covers v1.2.3, which was tagged but never released:
  stripping the BOM alone did not cover an OEM-code-page decoder.)

## [1.2.3] - 2026-10-24

- Tagged, not released; superseded by 1.2.4.

## [1.2.2] - 2026-10-24

- Bump InstallerVersion 1.2.1 -> 1.2.2 and pin SEDG Manager
  `sedg-manager-win-x64-1.2.2.zip` (self-contained `win-x64`).
- Fix Desktop Manager shell visibility bindings so only one view renders
  at a time (`50c1e31`).
- No engine behavior change.

## [1.2.1] - 2026-10-11

- Bump InstallerVersion 1.2.0 -> 1.2.1 (`installer.ps1` +
  `approved-releases.json`, không đổi behavior).

## [1.2.0] - 2026-10-09

- Fix test CDN báo đỏ oan dưới StrictMode: đọc ms kiểu strict-safe
  (ưu tiên Latency của PS7, fallback ResponseTime) + Pester chạy
  cùng strict với production.

## [1.1.9] - 2026-10-09

- Log lỗi thật (loại exception + message) khi target CDN rớt để
  chẩn đoán thay vì chỉ báo đỏ câm.

## [1.1.8] - 2026-10-09

- Xóa DNS client cache đầu test CDN chống cache âm làm rớt oan
  cả hàng sau stall thoáng qua + dọn file temp chẩn đoán.

## [1.1.7] - 2026-10-09

- Retry resolve DNS đúng 1 lần sau ~1 giây trước khi báo fail
  trong test CDN: DNS chết thoáng qua theo đợt giờ vẫn chạy tiếp
  flow ping bình thường thay vì đỏ cả hàng oan.

## [1.1.6] - 2026-10-09

- Retry ping đúng 1 lần sau ~1 giây trước khi báo blocked trong
  test CDN: ICMP chập chờn thoáng qua giờ vẫn cho kết quả ms
  bình thường thay vì vàng degraded oan.

## [1.1.5] - 2026-10-09

- Tách lỗi ping-blocked khỏi fail trong test CDN: resolve OK nhưng
  ping bị chặn (ICMP chập chờn) giờ báo degraded màu vàng kèm IP,
  chỉ resolve rớt mới báo lỗi đỏ.

## [1.1.4] - 2026-10-09

- Landing page: boopable mascot row (fox, cat, hedgehog, otter, sloth)
  with eye-tracking sprites, flanking verse rails, and a tighter
  desktop vertical rhythm.
- Landing security: stricter Content-Security-Policy (frame-ancestors,
  base-uri, form-action locked down), no-store on HTML entry points,
  local favicon.svg, workers.dev route disabled, and the pre-run
  hash check now cross-checks GitHub Releases SHA256SUMS.

## [1.1.3] - 2026-10-06

- Code cleanup after the menu redesign: removed the orphaned language
  keys (MnCurrent, MnSvc, MnStopped, WarnIpv6Reset) and the unused
  self-update leftovers; the manager self-update message now names the
  cancelled action so users know to re-run it after reopening.

## [1.1.2] - 2026-10-06

- The [0] Exit row now sits in the same bracket column as the action
  grid instead of one space to the right.

## [1.1.1] - 2026-10-06

- Menu numbering now reads row-major: 1-9 fill the three-column grid
  in visual order, 10-11 sit on their own row, and [0] Exit lives in
  its own fixed band set off by double rules.

## [1.1.0] - 2026-10-06

- Manager menu redesign: three-column action grid with aligned
  two-digit entries, a live status panel inside the box (per-service
  [OK]/[!!] indicators, DNS mode, upstream host) colored by state, and
  the version/path footer. The credit banner is unchanged.

## [1.0.9] - 2026-10-06

- Fixed the manager self-update console trap: after updating, the
  installer no longer re-execs the new menu inside the old one (the two
  loops kept stealing stdin, so the menu never came back). It now prints
  a closing message, ends the process, and the user starts
  Gateway-Manager.bat again to use the new menu.

## [1.0.8] - 2026-10-06

- Release verification step now skips the SHA256SUMS header comment
  (v1.0.7's run failed on it after the release itself had already been
  published correctly; assets were verified manually).

## [1.0.7] - 2026-10-06

- Fixed manager self-update handoff: the new manager's menu now replaces
  the old flow instead of both competing for the same console.
- Fixed Uninstall keeping the DNS backup file when the restore could not
  be fully replayed (it was deleted either way before).
- Fixed LocalService ACL and start-type exit codes in Create-Services: a
  refused grant now falls back to LocalSystem as documented.
- Fixed DNS backup recording an unreadable static-DNS registry key as
  "DHCP", which could wipe real static DNS on restore.
- Fixed partial DNS switches (local/bootstrap) rolling back adapters
  already changed when a later adapter fails mid-loop.
- Fixed quoted upstream entries in `config.yaml` not being parsed.
- Manifest download failures now log the host and reason before falling
  back to the embedded manifest.
- CI hardening: release dispatch now builds the tagged commit and
  re-verifies uploaded assets against SHA256SUMS; embedded-manifest check
  covers the NSSM pins; concurrency groups and job timeouts on all
  workflows; Dependabot covers `cloudflare/`; `npm run deploy:cf:dry`
  builds first instead of failing on a fresh clone.
- Fixed DNS adapters whose CIM DNS client objects are absent (freshly
  reset interfaces, some runner images): static DNS now falls back to
  netsh instead of aborting the install or update.
- New `integration` workflow: elevated end-to-end smoke on a disposable
  Windows runner (Install, Status, Restart, Uninstall) against local stub
  components, exercising real NSSM services, the watchdog task, and DNS
  mutation and restore. The installer gains opt-in test seams
  (`SEDG_ASSET_BASE_URL`, loopback http downloads) that are inert for
  normal users; SHA-256 pinning stays enforced.
- Landing page: WCAG AA contrast for small text, `aria-pressed` on the
  language toggle, favicon, no-JS notice, dead code removed.
- Tests: the generated watchdog script is now executed against stubs
  (service restart, fail-open after 3 failures, fail-closed, recovery
  from fallback, disabled no-op); Cloudflare config files are checked
  for drift.

## [1.0.6] - 2026-10-05

- Manager self-update now relaunches the new manager menu in the same
  admin console (`-Action Menu` instead of `-Action Update` then exit),
  so the window returns to the menu instead of closing.

## [1.0.5] - 2026-10-05

- Component updates: dnsproxy `v0.85.0` -> `v0.86.0`, zapret kept at
  `v72.13`; embedded manifest and `approved-releases.json` bumped to
  installer `1.0.5` with refreshed SHA-256 pins.

## [1.0.4] - 2026-10-01

- Update now always refreshes `state.json`, even when binaries are
  already current (previously a skipped commit left a stale
  `InstallerVersion`, making a successful Update look like it never ran).

## [1.0.3] - 2026-10-01

- Kill the remaining 1-2 minute outage after boot: dnsproxy now starts
  immediately (automatic) instead of delayed-auto, since static
  127.0.0.1 DNS turns every delayed minute into no network. Early
  crashes still self-heal via NSSM AppExit and SCM failure actions.

## [1.0.2] - 2026-09-30

- Fix no-network after reboot: DNS adapters keep pointing at `127.0.0.1`
  while `dnsproxy-service` stayed `Stopped`.
- Harden boot: grant LocalService traverse on the install dir, set NSSM
  `AppExit Default Restart` plus SCM failure actions (`restart/5000/...`),
  watchdog self-heals stopped auto-start services (respects `-DnsOnly`),
  task runs AtStartup plus every 1 minute.
- Existing installs pick the fix up via Update (recreates services/task).

## [1.0.1] - 2026-09-30

- Docs cleanup, no behavior change: rewrote `README.md` and
  `cloudflare/README.md` (shorter, no duplicated sections), compressed
  installer comments, removed internal review tags, and dropped an obsolete
  workflow example version.

## [1.0.0] - 2026-09-30

- Initial release: Windows auto-installer for a local DoH gateway
  (`127.0.0.1`) with Zapret DPI bypass.
- Safe by design: stage-then-verify with per-asset SHA-256 pins, admin-only
  staging under ProgramData, reinstalls routed through the Update path
  (rename-old, abort on locked drivers), registry-based DNS backup/restore
  keyed by InterfaceGuid, manager self-restore, no reboot-deletion outside
  Uninstall.
- Local DNS on physical adapters, 3-minute watchdog with DHCP fallback and
  optional `-FailClosed`, DoH upstream presets plus custom URL,
  `-DnsOnly`/`-Clean`/`-Purge` modes.
- Supply chain: pinned manifest with embedded fallback, GitHub Releases as
  a second origin for hash cross-checks, CI (syntax, Pester, parity,
  Cloudflare build), upstream component watcher.

[Unreleased]: https://github.com/projectofwang/sedg-suite/compare/v1.0.6...HEAD
[1.0.6]: https://github.com/projectofwang/sedg-suite/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/projectofwang/sedg-suite/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/projectofwang/sedg-suite/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/projectofwang/sedg-suite/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/projectofwang/sedg-suite/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/projectofwang/sedg-suite/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/projectofwang/sedg-suite/releases/tag/v1.0.0
