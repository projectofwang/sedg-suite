# Repository Atlas: sedg-suite

## Project Responsibility
Auto-installer Windows cho DNS gateway (dnsproxy) + DPI-bypass routing (zapret/winws), quản lý bằng NSSM services + watchdog scheduled task. Engine là one-script PowerShell 5.1 (`installer.ps1`, 130 functions, 4.769 dòng, ~249 KiB), manifest pinning `approved-only`, phân phối tĩnh qua Cloudflare assets-only.

Manager đang được thay bằng Rust/Tauri v2: một exe `sedg-manager.exe` ba mode (setup/manager/broker) nằm trong engine root. `src/` vẫn giữ solution .NET 10 cũ (`Sedg.Desktop`/`Sedg.Broker`/`Sedg.Protocol`) làm rollback path. Engine vẫn là bootstrap/CLI và là đường cài đặt duy nhất; `Gateway-Manager.bat` là rollback console một chu kỳ phát hành.

## System Entry Points
- `sedg-manager.exe` (`%ProgramFiles%\serverless-edge-dns-gateway\sedg-manager.exe`): manager chính (setup, status, upstream, service control, logs, update/uninstall); một exe, broker mode tự elevate qua UAC.
- `Sedg.Desktop.exe` (`%ProgramFiles%\SEDG Manager\`): manager .NET cũ, chỉ còn trên máy chưa update; installer mới không stage layout này.
- `Sedg.Broker.exe`: elevated broker, action allow-list + pipe DACL; không tự nhận hash/manifest từ app.
- `Sedg.Protocol`: request/response schema dùng chung cho app và broker.
- `installer.ps1 -Action <X>` (mặc định `Menu`): `Install-All/Update-All/Status/Restart/Uninstall -Purge/Show-Menu`; chạy trực tiếp hoặc `irm https://dl.../installer.ps1 | iex`.
- `Gateway-Manager.bat` (trong engine folder): console menu cũ; one-release-cycle rollback path khi GUI không dùng được.
- `approved-releases.json`: source of truth pin version + sha256 (installer v1.2.5, dnsproxy v0.86.0, zapret v72.13, nssm 2.24, manager v1.2.5).
- `tools/Update-Manifest.ps1`: dev-time bump manifest + sync embedded fallback (gồm manager).
- `tools/Publish-Manager.ps1`: build Rust `sedg-manager.exe` → zip `sedg-manager-win-x64-<version>.zip` (exe + `manager-version.txt`), tự verify bằng `tools/Test-ManagerPayload.ps1`.
- `tools/Test-ManagerPayload.ps1`: cổng payload manager (layout, version, SHA-256); dùng chung cho publish và release.
- `Invoke-Pester ./tests` / `npm test`; `dotnet run --project tests/Sedg.UnitTests -c Release`.

## Root Assets
| File | Role |
|---|---|
| `installer.ps1` | Entry point engine, `-Action` dispatcher; staged download → verify → commit; manager stage/commit/rollback; watchdog; i18n `T()` |
| `approved-releases.json` | Pinned manifest `schema:1/policy:approved-only`; mỗi component có `tag/asset/url/sha256`, gồm `manager` |
| `src/` | .NET 10 solution legacy: `Sedg.Desktop`, `Sedg.Broker`, `Sedg.Protocol`; `src/rust` là manager Tauri v2. |
| `tests/Sedg.UnitTests/` | Zero-dependency .NET unit harness (104 cases) |
| `tools/Update-Manifest.ps1` | Regen manifest + patch installer, manager parity |
| `tools/Publish-Manager.ps1` | Manager publish driver cho `win-x64` |
| `cloudflare/` | Kênh phân phối tĩnh dl.* |
| `tests/` | Pester unit/mocked + integration fixtures |

## Directory Map (Aggregated)
| Directory | Responsibility Summary | Detailed Map |
|---|---|---|
| `src/` | Ba project .NET 10 (legacy) + `src/rust` (Tauri v2 manager); solution .NET `sedg-manager.sln`. | — |
| `tests/Sedg.UnitTests/` | Self-contained .NET harness: protocol, broker, validation, rendering, localization, nonce. | — |
| `tests/integration/` | Elevated end-to-end smoke + fixture builder; **chưa có manager component/asset** (integration gap). | — |
| `tools/` | Maintainer-only manifest + manager publish tooling. | [View Map](tools/codemap.md) |
| `cloudflare/` | Static distribution channel assets-only. | [View Map](cloudflare/codemap.md) |

## Flow (end-to-end)
1. User → landing `dl.taiyuanwangjie.dpdns.org` → `irm .../installer.ps1 | iex` (hoặc chạy script local).
2. `Get-ApprovedManifest` (~L761) fetch manifest → fallback raw GitHub → embedded copy (warn).
3. `Install-StageComponents` (~L1928) tải từng asset theo repo/tag → staging admin-only → `Verify-Sha256`; manager được stage qua `Install-StageManager` (~L1890) từ pin `Get-PinnedManagerSource` (~L1839).
4. `Install-CommitComponents` (~L1928) swap engine; `Install-CommitManager` (~L2191) swap hai file `<engine root>\sedg-manager.exe` + `manager-version.txt` (rename-aside cho exe đang chạy), verify rồi rollback nếu lỗi; không còn guard `Get-Process Sedg.Desktop` trước khi mutate.
5. Engine tạo 2 NSSM services + task `SEDG-DNS-Watchdog`; manager là surface chính; `Gateway-Manager.bat` rollback console.
6. Watchdog (`Write-WatchdogFile` ~L2795) mỗi phút set DNS adapter → local resolver; 3 fail → DHCP fail-open (hoặc `-FailClosed`).
7. Uninstall gateway xóa manager cùng engine tree (O-9 bị D-07 thay thế); tree bị khóa → `Schedule-DeleteTreeOnReboot` + "reboot required", không báo `UninstDone`.
8. Release: `Publish-Manager.ps1` → zip Rust; upload asset vào release bare tag `<manager-version>` **trước**; `Update-Manifest.ps1` pin; tag `vX.Y.Z` khớp `$script:InstallerVersion`; `release.yml` tải lại asset đã pin, verify SHA/layout trước khi tạo release.

## Integration / Parity Gates
- Baseline gates giữ nguyên: parse PowerShell, pure-ASCII `installer.ps1`, PSScriptAnalyzer errors, Pester, manifest schema/version/embedded parity, EN/VI parity, Cloudflare build.
- Gate mới: job `dotnet` (`windows-latest`, SDK `10.0.x`) build `src/sedg-manager.sln` Release + chạy `tests/Sedg.UnitTests`; job `rust` build/test/clippy (locale parity nằm trong `src-tauri/tests/locales.rs`); manifest step kiểm tra `manager` repository/tag/asset/SHA và embedded `$script:Manager*` parity; EN/VI step so sánh 143 key app resx; `release.yml` verify manager zip đã publish (SHA + layout) trước khi tạo release.
- Seams: `SEDG_INSTALL_PATH`, `SEDG_MANIFEST_URL`, `SEDG_ASSET_BASE_URL` (test/packaging).
- 3-way config parity: `wrangler.toml` ↔ `wrangler.config.ts` ↔ `cloudflare.config.ts`.
- Version parity: `$script:InstallerVersion` ↔ `approved-releases.json.installer.version`.
- Cross-origin check: CF `version.json`/`SHA256SUMS` vs GitHub Releases assets; installer không serve binary từ CF host.
- Integration smoke hiện chưa build manager fixture; scheduled smoke sẽ fail ở required-manager check cho đến khi `tests/integration/Build-Fixtures.ps1` được mở rộng (ngoài Task 7).

## Design
- Single-script dispatcher facade; staged 2-phase (download → verify → commit) + rollback; manifest pinning + embedded fallback; env-var seams; i18n key table; self-elevation.
- Desktop: protocol JSON có schema/version; broker allow-list + pipe DACL; GUI không giữ đặc quyền; update không kill app (rename-aside).
- **O-6 (superseded bởi Rust rewrite):** bản .NET cũ phát hành self-contained `win-x64` (kèm .NET runtime); Rust manager không cần runtime, chỉ một exe.
- **O-9 → D-07:** manager nằm trong engine root nên uninstall gateway xóa luôn; không có UI uninstall riêng, file bị khóa thì hẹn reboot thay vì báo thành công.
- **Plan/envelope discrepancy:** plan Task 8 criterion 6 nói không tài liệu nào được nêu publishing mode đã quyết; Gate 1 O-6 lại quyết định self-contained. Tài liệu này ghi nhận O-6 và discrepancy; envelope là authority.
- Platform: GUI chỉ Windows 11 x64; Windows 10 và ARM64 **không** phải GUI target (engine vẫn giữ contract Windows 10 1803+ x64 cũ). Không có claim Microsoft support cho 26H2; mọi đề cập chỉ là observed compatibility.
- Delivery status: `IMPLEMENTED_NOT_INTEGRATION_ACCEPTED`; manager asset chưa publish; elevated UAC/broker/DNS/service/driver end-to-end chưa verify.
