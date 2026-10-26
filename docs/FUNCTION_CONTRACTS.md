# Function contracts — installer.ps1 (4.717 dòng, post Tasks 1–7)

Gộp từ 5 lanes (số dòng grep-verify 2026-10-11; cập nhật tổng dòng 2026-10-23). File này là source of truth cho function contracts (thay thế INSTALLER_MAP/FLOW_TRACES đã xóa). Quy ước: pre→post/throw | invariant | edge. Các range A–E là anchor lịch sử; function mới của delivery nằm ở §F.

## A. Bootstrap/i18n/UI/preflight/manifest (~1–802)

- Param block (5-17): `-Action` ValidateSet 10 giá trị default Menu + 8 switch (+`-AllowSeam`); unknown action chặn trước dispatcher.
- Host prefs/TLS/UTF-8 (19-43): save 4 prefs trước khi mutate, finally restore (irm|iex không pollute caller); TLS 1.3 fail → 1.2.
- SelfPath/SelfContent (50-64): SelfPath không bao giờ rỗng (TEMP-GUID fallback); snapshot trước mọi wipe; guard `InstallerVersion` chặn content rác.
- Env seams (74/108/684): hiệu lực iff (`$AllowSeam` ∨ non-admin); warn khi active; elevated không flag → default im lặng.
- i18n (410-508): `T` fallback VI→EN→key, never-null; `Get-SavedLang` lỗi → EN; `Save-Lang` ASCII no-newline; `Write-*` never-throw (Box truncate `...`, Title clamp 20-60).
- Ensure-Administrator (516): admin → return; else materialize + RunAs (forward full switches incl. -AllowSeam, strip `"` -Upstream) + exit; UAC từ chối → throw.
- Mutex (561/580): re-entrant qua depth; abandoned = acquired; exit depth=0 no-op; never-throw.
- Transcript (593/612): best-effort, rotate 10, never-throw; null ⟺ không log.
- Test-Platform (618): throw nếu x86/ARM64/build<17134; lỗi đọc version khác → nuốt (fail-open) trừ ARM64/x86 fail-closed.
- Manifest (636-802): null-safe helpers; Assert gate duy nhất trước mọi download; Test-DownloadUrl chỉ https + loopback-CI; Get-ReleaseAssetUrl allow-list + regex (không GitHub API); Get-ApprovedManifest cache-first, 2 URI (TimeoutSec 30) → embedded, cùng 1 validate, mismatch hard-throw; remote-cũ-hơn → warn-only (R1 Opt C).

## B. Integrity/download/services/driver/DNS primitives (~804–1490)

- Verify-Sha256 (804): validate 64-hex trước khi hash; fail = throw (không boolean); stream.
- Download-File (841): Test-DownloadUrl gate; curl `--proto =https` → IWR fallback; retry ×3 sleep 2s; xóa partial đầu attempt.
- Expand-Zip (886): xóa-recreate (không merge); Find-File (894): best-effort, `$null` nếu thiếu.
- Get-NetworkAdapters (899): Up, no-loopback, physical-only (opt-in virtual); rỗng → giữ nguyên list.
- Stop-AllServices (915): log port-53 trước; poll 15s; chỉ throw khi *service* treo (process force-kill im lặng).
- WinDivert (950-1058): registry→normalize (strip NT prefix)→ownership check (foreign → throw); locked: schedule reboot iff switch else throw Reboot; MoveFileEx Add-Type 1 lần; tree-delete files-trước/dirs-deepest-first, warn-only.
- Start-AllServices (1060): rotate log >20MB; winws→dnsproxy; verify Running sau sleep; fail kèm nssm status + log tail-40; -DnsOnly skip winws.
- DNS setters (1124-1247): CIM trước, netsh fallback (validate=no); Static combined-call chống wipe; Both không wipe family kia (query current, loại loopback).
- Set-SecureAcl (1249): SID well-known (language-independent); icacls≠0 → throw.
- Exit-Installer (1260): script-file → exit; iex → return (M5).
- Get-OurProcesses (1267): path-filter InstallPath* (chống kill nhầm); Get-StaticDnsServers (1273): phân biệt unknown($null)/DHCP(@()); Log-Port53Owner (1287): never-throw.
- Backup-DnsSettings (1313): chạy sớm nhất; safe-baseline chỉ khi untainted (R5); never-throw.
- Restore-DnsSettings (1377): GUID→name, filter tainted, 4 nhánh replay; never-throw; Incomplete flag giữ file; rỗng + có file → DHCP reset, không file → skip+warn (R4).
- Reset-DnsToDhcp (1459): physical-only; best-effort hết adapter rồi throw gộp.

## C. DNS advanced/stage/commit/config (~1459–2181)

- Snapshot helpers (1492-1521): empty = DHCP hợp lệ (≠ unknown); null → DHCP; mid-loop-fail rollback đã apply.
- Set-InstallerBootstrapDns (1555): resolve OK → không đụng adapter; fail → DNS tạm + snapshot/rollback → vẫn fail → throw.
- Install-StageComponents (1623): chỉ TEMP; 6 file validated; ≠1 windows-x86_64 → reject; NSSM mirror fallback; fail → caller chỉ restore DNS.
- Install-CommitComponents (1767): locked+identical → giữ driver; locked+differs → throw Reboot; preserve whitelist; rollback partial/full, incomplete → throw reboot.
- Config (1890-2026): reader ladder YAML→state→default, skip comment + strip trailing (R7); Test-DnsUpstream gate chung (absolute + 4 scheme + anti-CRLF); template block-style no-BOM; Test-ConfigValid hẹp; Ensure 3 nhánh (.bak chỉ khi invalid); Repair-CacheKey warn-only; Set-UpstreamInConfig đúng 1 occurrence + flow-style→block-style (R7) — **còn hở: nuốt comment indent trong block**.
- Set-SystemDns (2027): primary bắt buộc, validate family từng ô; áp IncludeVirtual; không rollback adapter đã ghi.
- Get-StateReleases (2114): luôn 2 slots ('Unknown' fallback); Restart-DnsProxyService (2127): start + verify listener; Set-Upstream (2135): stop→ghi→restart LUÔN (lỗi vẫn restart rồi rethrow orig); log redact Host+Path (F10).

## D. Watchdog/services/manager/Install-All (~2183–2993)

- Set-Language (2183): normalize Trim/Upper; blacklist/winws-args (2206-2316): only-if-missing, no-BOM, đúng 1 dòng hiệu lực.
- Write-WatchdogFile (2318): template 3 placeholder → Replace $script: vars (R8 byte-identical); generated standalone: guard enabled → in-use/failedOver → self-heal Automatic-only → health-check 127.0.0.1 → healthy reset counter / ≥3 strikes DHCP trừ fail-closed → luôn exit 0.
- Clear-WatchdogState/Set-GatewayEnabled (2456-2467): best-effort; flag = gate 1 watchdog.
- Install-Watchdog (2469): task SYSTEM AtStartup + 1'/3650d Highest timeout 5'; -FailClosed sticky, không tự xóa.
- Invoke-Nssm (2497): điểm throw duy nhất config nssm. Remove-Services (2504): nssm→sc fallback, poll 10s DeletePending, unregister task warn-only. Create-Services (2553): remove trước; winws DEMAND khi -DnsOnly; LocalService + recovery; **F3: log pre-create, dir RX, M chỉ file log**; fail → giữ SYSTEM + warn.
- Manager (2636-2700): memory→file→download hash-pinned; anti-self-copy PS5.1; bat ASCII + dọn legacy.
- Test-DnsProxyListeners (2702): poll 10s :53 127.0.0.1, IPv6 chỉ warn. Write-State (2727): JSON depth 3, Updated UTC-ISO. Remove-InstallDirectoryCleanly (2741): chỉ Uninstall được schedule reboot.
- Test-OwnsProcessInvocation (2772): seam override > PSCommandPath; iex → false (không kill host).
- Update-ManagerFromDist (2788): version≠ + sha hợp lệ → download/verify/copy/re-verify → nhả mutex+transcript + bump in-memory → exit (script-file) / return $true (iex); mọi lỗi → $false. Handoff double-release an toàn (idempotent guards).
- Install-All (2845): preflight → backup DNS → route Update nếu đã cài → self-update → bootstrap+stage → preserve → stop → swap (locked → start cũ + restore + throw) → ACL/DHCP/commit → restore preserved → config → services/manager/watchdog/flag → start/verify/DNS/state → dọn → summary; teardown B (không service nửa vời); R6 cleanup non-rethrow; F2 -AllowSeam forward đầy đủ.

## E. Update/Uninstall/Status/Menu/dispatcher (~2995–3710)

- Update-All (2995): chưa cài → route Install; Backup → early-skip (state==manifest + 6 file, không stage) → skipCommit (state==staged) → stop/DHCP → commit có điều kiện → rebuild (cả khi skip) → start/DNS → **Write-State luôn** → summary; catch append-recovery không mask; Write-State bị bỏ qua khi catch.
- Pause (3118): stop + DHCP (không backup) + flag off. Resume (3132): clear → start → DNS (fail → stop+DHCP+rethrow) → flag on + tests. Restart (3154): bounce, không đụng flag/task/backup.
- Uninstall-All (3174): chưa cài → return; stop → restore warn-only (incomplete giữ backup) → flag/state off → Remove-Services → driver schedule-iff → xóa dir (fail → tree-reboot-delete) → -Purge (sót transcript đang mở + backup-incomplete giữ dir — deliberate).
- Status (3247-3364): pure-read, never-throw; upstream redact; ready = installed ∧ services ∧ localDns.
- CDN (3366-3504): never-throw ra ngoài; retry 1/lớp; cache IP + sleep 200ms; opt-in 2 luồng (flag / Menu prompt).
- Summary/Menu (3505-3665): elevate 1 lần/session; loop try/catch từng action + release mutex/transcript giữa actions; panel best-effort drop-row.
- Dispatcher (3667-3710): Clear-StaleTempInstallers trong try (R9); default throw; finally restore prefs; pause nếu ≠Menu; self-delete chỉ match TEMP pattern; Exit-Installer nếu ExitCode≠0.

## F. Desktop-manager delivery functions (Tasks 1–6; grep-verify 2026-10-23)

Các hàm mới so với base `a834a44`; số dòng hiện tại của `installer.ps1` là **4.769**. Manager pin: repository `projectofwang/sedg-suite`, tag `2.0.0`, asset `sedg-manager-win-x64-2.0.0.zip`, SHA-256 `0dfef8...ee8d`, app path `<engine root>\sedg-manager.exe` (D-07).

- `Get-PinnedManagerSource` (1839): đọc manager pin từ manifest/embedded theo cùng validate path; trả source cho staging; không nhận hash từ app.
- `Install-StageManager` (1890): tải pinned zip vào staging admin-only → `Verify-Sha256` trước khi extract/write; fail → không chạm app path; `-AllowSeam` chỉ theo seam hiện có. Chỉ nhận đúng một `sedg-manager.exe` + `manager-version.txt`, version trong zip phải khớp pin; layout `Sedg.Desktop.exe`/`Sedg.Broker.exe` bị từ chối trước khi copy.
- `Test-ManagerHealthy` (2176): live `sedg-manager.exe` non-empty + `manager-version.txt` == pin; dọn `*.old-*`; legacy `%ProgramFiles%\SEDG Manager` chỉ xóa khi có `Sedg.Desktop.exe` chứng minh đúng sản phẩm.
- `Install-CommitManager` (2191): hai-file swap; rename exe đang chạy sang `*.old-<guid>` (Windows cho rename, không cho overwrite) → copy → verify → rollback cặp cũ khi fail; file khóa thật → lỗi "đóng app rồi thử lại"; không còn guard `Get-Process` trước mutate. Uninstall xóa manager cùng engine tree (O-9 → D-07), tree khóa → reboot-delete.
- `Write-ProtocolLine` (4247): ghi một JSON line ra stdout/pipe; dùng cho protocol mode.
- `New-ProtocolProbe` (4254): tạo probe object (`state/value/reason`) theo schema.
- `New-ProtocolResult` (4265): tạo result envelope (`ok/code/message/data/currentState/restoredState/nextStep`).
- `Get-StatusSnapshot` (4280): snapshot status read-only cho protocol; không mutate.
- `Test-ProtocolServers` (4482): validate danh sách server cho protocol action; reject ngoài shape.
- `Invoke-ProtocolAction` (4493): dispatch allow-list action; không tự elevate; lỗi → result envelope, không throw ra loop.
- `Invoke-ProtocolLoop` (4601): đọc request JSON theo dòng từ stdin → dispatch → ghi result; exit semantics cho broker/host.

Các function manager nằm trong vùng stage/commit (C/D); protocol nằm cuối file (F) và không thay đổi dispatcher `-Action` hiện có.
