# Security audit — sedg-suite (2026-10-11, read-only)

Threat model đã chốt: chống lỗi vô tình + MITM (HTTPS + SHA-256 + allow-list + embedded fallback + version check + remote-older warn). Host-compromise out-of-scope (documented), downgrade được phép.

## Findings (sev + vị trí + fix gợi ý)

| # | Sev | Vị trí | Vấn đề → khi khai thác | Fix |
|---|---|---|---|---|
| F1 | high | manager self-update + landing hero | Host bị chiếm → phục vụ version.json+installer.ps1 độc khớp hash = **full-script RCE** (mạnh hơn chữ "đổi binaries" trong SECURITY.md) | **QĐ: document-as-is** — patch câu chữ SECURITY.md, giữ hành vi |
| F2 | medium | SEDG_INSTALL_PATH/MANIFEST_URL/ASSET_BASE_URL | Seam test sống trong production; env bẩn + elevate kế thừa env → manifest giả qua hết check | **QĐ: khóa khi elevated** — ignore seam khi admin trừ flag显式, warn khi active |
| F3 | medium | icacls DnsProxyPath | LocalService có Modify cả dir → dnsproxy bị compromise tự thay binary, persist sau restart | **QĐ: thu hẹp** — RX dir, M chỉ file log; **cần smoke reboot tay** |
| F4 | medium | reboot-delete vs Install | Uninstall hẹn xóa cây → Install lại ngay → reboot xóa luôn bản mới | Install đầu check/xóa pending MoveFileEx trỏ InstallPath hoặc abort báo reboot |
| F5 | medium | landing hero irm\|iex | Chạy bytes chưa verify; bước verify optional | Hero ưu tiên bản 3-bước, irm\|iex nhãn "nhanh nhưng bỏ qua verify" |
| F6 | low | TEMP materialize elevation | $env:TEMP user-writable, GUID + cửa sổ ngắn, không re-verify | Materialize vào ProgramData staging (admin-only) |
| F7 | low | version.json TOFU | Hash-pin đặt trên niềm tin lần đầu | Ghi rõ "TOFU" trong SECURITY.md, không claim hơn |
| F8 | low | restore per-adapter fail → DHCP | Mất static gốc dù còn backup | Chỉ DHCP khi entry rỗng, còn không giữ nguyên + Incomplete |
| F9 | low | netsh "name=" không escape `"` | Adapter tên chứa `"` phá quoting (cần admin để rename → robustness) | CIM -InterfaceIndex chính, netsh fallback strip `"` |
| F10 | low | log/state/config | **QĐ: có secret** — DoH `?token=` vào console/transcript/state/config | Redact query-string khi log, giữ full chỉ trong config + document |
| F11 | low | Expand-Archive | Không ZipSlip guard tường minh (tin hash-pin cả zip) | Assert mọi file dưới $Destination sau expand |
| F12 | low | WinDivert64.sys | Tin theo manifest hash, không check Authenticode | Document + cân nhắc Get-AuthenticodeSignature warn-only |
| F13 | low | Update-Manifest.ps1 2-file write | "Atomic" trong comment nhưng crash giữa 2 file = drift (CI bắt, local không) | .tmp + Move-Item + parity check cuối |
| F14 | low | CI cài module không pin + SkipPublisherCheck | TOFU PSGallery mỗi run; Severity Error-only bỏ qua warning invoke | Pin version/hash, xét Severity Warning cho rule invoke/shell |
| F15 | low | release verify-after-publish cùng runner | Tự nhất quán, không bắt build-host compromise | Ghi rõ giới hạn; cross-check tay CF↔GitHub là lớp thật duy nhất |
| F16-18 | info | touched-adapters.json dead-write; heal chỉ -Physical; Find-File match đầu | — | Dọn/health mở rộng/assert count==1 khi tiện |

## Defenses đã ổn (không đụng)

Elevation (strip quotes, whitelist, ValidateSet, GUID temp), download integrity (stream SHA + 64-hex cả 2 đầu, https cả 2 nhánh, allow-list + regex, hard-throw + fallback + cache + timeout R10), self-update hash 2 lớp + re-verify, WinDivert ownership check, R4+R5 DNS safety, input validation (CRLF/scheme/absolute URI, TryParse, regex-escape, array-splat), supply chain (parity fail-closed, CRLF deterministic, tag immutable, human-review gate, CSP + textContent landing).

## Quyết định user (đã chốt → implement)

F1 document-as-is · F2 khóa khi elevated · F3 thu hẹp (+smoke tay) · F10 có secret (redact).
