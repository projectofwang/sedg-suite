# Audit rủi ro `installer.ps1` — Install / Update / Uninstall

- **Phạm vi:** `installer.ps1` bản `1.2.1` (3.989 dòng, 117 hàm), manifest `approved-releases.json`.
- **Cách làm:** chỉ đọc mã nguồn (`grep`, `nl -ba`), đối chiếu `README.md`, `codemap.md`, `docs/SECURITY_AUDIT.md`, `docs/FUNCTION_CONTRACTS.md`.
- **Không chạy:** không thực thi Install/Update/Uninstall/Restart, không tải binary, không đụng service/registry/scheduled task. Mọi kết luận về hành vi runtime được tách sang mục **Chưa xác minh**.
- **Kết quả:** 0 Critical, 2 High, 5 Medium, 5 Low.

| # | Mức | Vấn đề |
|---|-----|--------|
| F1 | High | Fallback manifest (`main`) không được cross-check; `nssm.url` tự do → chạy binary tuỳ ý bằng Administrator |
| F2 | High | `Uninstall-All` return sớm khi thiếu thư mục → bỏ sót service và scheduled task SYSTEM |
| F3 | Medium | Update lỗi sau `Create-Services` → mất service, catch không tạo lại và không rollback binary |
| F4 | Medium | Install/-Clean lỗi để lại cây cài đặt dở dang; không khôi phục bản cũ dù README cam kết |
| F5 | Medium | `Get-ManagerSourceContent` verify-rồi-đọc-lại (TOCTOU) + fallback `%TEMP%` |
| F6 | Medium | Watchdog ghi cờ "fallback" dù `netsh` thất bại (không kiểm exit code) |
| F7 | Medium | Kiểm tra ZipSlip sau khi đã giải nén |
| F8 | Low | ACL cấp `BUILTIN\Users` quyền đọc thư mục cài đặt (trái với thiết kế admin-only) |
| F9 | Low | Early-skip chỉ kiểm tồn tại/kích thước, không so hash |
| F10 | Low | Elevation chạy lại `SelfPath` mà không kiểm nội dung lần hai |
| F11 | Low | Seam `SEDG_INSTALL_PATH` không validate → phá/inject watchdog, `Remove-Item -Recurse` tuỳ ý |
| F12 | Low | Tài liệu lệch mã (codemap, FUNCTION_CONTRACTS, README) |

---

## F1 — High: Fallback manifest là trust root yếu, và `nssm` là đường chạy binary tuỳ ý

**Bằng chứng**
- `installer.ps1:121` — `ManifestFallback` trỏ tới nhánh `main` có thể sửa: `.../sedg-suite/main/approved-releases.json`.
- `installer.ps1:762-769` — thử `Sources.Manifest`, nếu lỗi thì dùng fallback; không phân biệt nguồn nào đã trả lời ngoài `$remoteUri`.
- `installer.ps1:778` — cross-check **chỉ chạy khi** `$remoteUri -eq $script:Sources.Manifest`. Khi primary chết và fallback trả lời, không có đối chiếu nào.
- `installer.ps1:676-682` — với `nssm`, chỉ kiểm `url`/`mirror` là HTTPS; không giới hạn host.
- `installer.ps1:1805-1830` — `sha256` lấy từ manifest được ưu tiên hơn hằng số nhúng `$script:NssmSha256` (`installer.ps1:124-125`); `Assert-ManifestComponents` bắt buộc phải có `nssm.sha256` (`installer.ps1:663`), nên hash nhúng gần như không bao giờ được dùng.
- `installer.ps1:2704-2708` — `Invoke-Nssm` chạy `$script:NssmPath`; `installer.ps1:2772-2775` dùng chính binary đó để tạo service (mặc định LocalSystem).

**Tác động:** ai kiểm soát được fallback (tài khoản GitHub/tổ chức, hoặc kênh phân phối khi primary down) đặt được `nssm.url` + `nssm.sha256` tuỳ ý → thực thi binary tuỳ ý bằng Administrator trong lúc cài, rồi service chạy LocalSystem. `dnsproxy`/`zapret` không bị đòn này vì URL bị khoá vào repo allow-list (`installer.ps1:644`, `installer.ps1:713-719`); `nssm` là ngoại lệ duy nhất.

**Fix tối thiểu:** bỏ `nssm.url`/`nssm.sha256` khỏi manifest; luôn dùng `$script:Sources.NssmZip` + `$script:NssmSha256` nhúng trong script. Nếu vẫn muốn fallback manifest, pin fallback vào commit SHA và cross-check cả hai chiều.

---

## F2 — High: Uninstall bỏ sót service và scheduled task SYSTEM

**Bằng chứng**
- `installer.ps1:3438-3441` — nếu `$script:InstallPath` không tồn tại thì in "NotInstalled" và `return`.
- `installer.ps1:3459` — `Remove-Services` chỉ được gọi **sau** chỗ return đó.
- `installer.ps1:2750-2755` — nếu chờ xoá service quá 10 giây, hàm `throw` **trước** `Unregister-ScheduledTask`.
- `installer.ps1:2686-2696` — task `SEDG-DNS-Watchdog` chạy `powershell.exe -File <InstallPath>\watchdog.ps1` với principal `SYSTEM`, trigger mỗi phút.

**Tác động:** một uninstall dở dang (thư mục bị xoá tay, xoá một phần, hoặc lần trước đã schedule xoá) sẽ:
1. báo "chưa cài" và bỏ qua toàn bộ dọn dẹp;
2. để lại task SYSTEM trỏ vào file không còn tồn tại (lỗi mỗi phút, rác vĩnh viễn) và/hoặc service còn sống;
3. làm lần cài lại gặp service cũ, dễ rơi vào nhánh Update thay vì Install.

**Fix tối thiểu:** gọi `Remove-Services` (idempotent) **trước** kiểm tra thư mục; chuyển `Unregister-ScheduledTask` vào `finally` hoặc lên trước vòng chờ service, để timeout không chặn việc xoá task.

---

## F3 — Medium: Update thất bại ở bước tạo service thì không tự phục hồi

**Bằng chứng**
- `installer.ps1:3324` — `Create-Services` được gọi sau khi binary đã commit.
- `installer.ps1:2760-2763` — `Create-Services` gọi `Remove-Services` ngay đầu, tức service cũ bị xoá trước khi service mới được tạo.
- `installer.ps1:3342-3352` — catch chỉ `Stop-AllServices`, `Start-AllServices`, `Restore-DnsSettings`; không gọi `Create-Services`, không dùng lại thư mục rollback.
- `installer.ps1:1937-1977` — rollback binary chỉ chạy bên trong `Install-CommitComponents`; sau khi hàm này thành công, bản backup nằm ở Temp nhưng catch không đụng tới.

**Tác động:** lỗi tại `Invoke-Nssm`/`sc.exe` (ví dụ `sc.exe config` trả mã khác 0, `nssm.exe` bị AV chặn) xảy ra **sau** `Remove-Services` → không còn service nào; catch cố `Start-AllServices` trên service đã bị xoá nên lỗi, rồi ném lỗi kèm `[recovery: start: ...]`. Gateway ngừng hoạt động (DNS đã về DHCP nên mạng vẫn lên), và thông điệp "restart the previous binaries" ở `installer.ps1:3343` không đúng vì binary đã là bản mới.

**Fix tối thiểu:** trong catch, nếu `Get-Service` không còn service thì gọi `Create-Services` (binary đã commit) trước khi `Start-AllServices`; giữ thư mục rollback tới khi service chạy và listener test xong mới xoá.

---

## F4 — Medium: Install/-Clean lỗi để lại trạng thái dở dang, không khôi phục bản cũ

**Bằng chứng**
- `installer.ps1:3135-3148` — nhánh `-Clean`/thư mục cũ: rename install dir thành `-old` rồi `Remove-InstallDirectoryCleanly $oldDir` **trước** khi commit.
- `installer.ps1:3172` — commit component xảy ra sau đó.
- `installer.ps1:3210-3215` — catch chỉ stop/remove service và restore DNS; không khôi phục `-old`, không xoá cây cài đặt dở.
- `installer.ps1:1937-1977` — rollback chỉ chạy khi `$dnsRollback`/`$zapRollback` tồn tại, tức khi đã có bản live; cài mới thì không có gì để rollback.
- `README.md:31` — "Fail-safe rollback: a failed install or update restores the previous state."

**Tác động:** sau một lần cài/-Clean thất bại giữa chừng, máy còn thư mục cài đặt một phần (dnsproxy/zapret/nssm tuỳ điểm lỗi) và **không còn bản cũ**. Lần chạy sau `Install` thấy thư mục tồn tại nên tự chuyển sang Update (`installer.ps1:3085-3091`), trong khi người dùng được hứa là đã rollback.

**Fix tối thiểu:** giữ `-old` tới khi commit + `Start-AllServices` + `Test-DnsProxyListeners` thành công rồi mới xoá; trong catch, nếu `-old` tồn tại thì đổi tên khôi phục và xoá cây mới. Nếu không muốn làm, sửa README cho đúng hành vi.

---

## F5 — Medium: Verify-rồi-đọc-lại khi self-update manager (TOCTOU)

**Bằng chứng**
- `installer.ps1:2855-2862` — tải installer vào `$script:TempPath`; nếu tạo thư mục lỗi thì fallback `$env:TEMP`; không gọi `Set-SecureAcl` ở nhánh này.
- `installer.ps1:2864-2867` — `Get-FileHash` trên file, so với `version.json`, rồi `Get-Content` **đọc lại chính file đó**.
- `installer.ps1:3032-3037` — nhánh self-update khác có `Set-SecureAcl -AdminOnly`, cho thấy đây là thiếu sót cục bộ chứ không phải chủ ý.
- Nội dung trả về được ghi thành `manager.ps1` (`installer.ps1:2873` trở đi) và chạy bởi launcher.

**Tác động:** người dùng local không phải admin thay file trong khoảng giữa hash và `Get-Content` → nội dung tuỳ ý được cài làm `manager.ps1`. Fallback `$env:TEMP` là thư mục người dùng ghi được, nên điều kiện tấn công càng dễ. Cần có local attacker + một lần chạy elevated.

**Fix tối thiểu:** đọc file một lần vào byte[], băm chính byte[] đó và trả về đúng byte[] đã băm; dùng `Set-SecureAcl -AdminOnly` và fail-closed thay vì fallback `%TEMP%`.

---

## F6 — Medium: Watchdog báo "fallback" dù reset DNS có thể đã thất bại

**Bằng chứng**
- `installer.ps1:2557-2560` — `Set-DnsDhcp` gọi `netsh ... | Out-Null`, không đọc `$LASTEXITCODE`, không kiểm lại `ServerAddresses`.
- `installer.ps1:2646-2655` — sau 3 lần lỗi, gọi `Set-DnsDhcp` cho từng adapter rồi **ghi `watchdog-fallback.flag` vô điều kiện**.
- `installer.ps1:2578` — sự tồn tại của flag được dùng như trạng thái "đã fallback".

**Tác động:** nếu `netsh` fail (adapter đang reset, tên adapter đổi, IPv6 bị disable), flag vẫn được ghi và log/trạng thái nói đã fallback trong khi adapter có thể vẫn trỏ `127.0.0.1` → người dùng mất mạng với thông báo sai hướng. Các tick sau có thử lại, nhưng trạng thái ghi nhận vẫn sai.

**Fix tối thiểu:** sau mỗi `netsh`, kiểm `$LASTEXITCODE`; chỉ ghi flag khi tất cả adapter đã thực sự rời `127.0.0.1`/`::1`; nếu không, ghi log lỗi và để nguyên counter để tick sau thử lại.

---

## F7 — Medium: ZipSlip guard chạy sau `Expand-Archive`

**Bằng chứng**
- `installer.ps1:964` — `Expand-Archive` giải nén trước.
- `installer.ps1:965-977` — sau đó mới duyệt entry và kiểm prefix; entry thoát ra ngoài đã được ghi trước khi bị phát hiện.

**Tác động:** archive độc hại ghi được file ra ngoài thư mục staging trước khi guard kịp chặn. Trên thực tế bị giảm mạnh bởi hai lớp khác: hash pinning (`installer.ps1:1757`, `1773`, `1830`) là cổng chính, và staging là admin-only (`installer.ps1:1726`). Đây là lỗi thứ tự phòng thủ, không phải đường vượt qua hiện hữu.

**Fix tối thiểu:** kiểm `ZipArchive.Entries[i].FullName` trước khi extract (reject rooted path và `..`), hoặc chấp nhận rủi ro đã được hash pinning che và ghi rõ trong comment.

---

## F8 — Low: Thư mục cài đặt cấp quyền đọc cho mọi user local

**Bằng chứng**
- `installer.ps1:1353-1355` — mặc định cấp `*S-1-5-18:F`, `*S-1-5-32-544:F`, và **`*S-1-5-32-545:(OI)(CI)RX`** khi không có `-AdminOnly`.
- `installer.ps1:3168` và `installer.ps1:3311` — gọi `Set-SecureAcl $script:InstallPath` **không** truyền `-AdminOnly`.
- `installer.ps1:2811` — comment khẳng định "the install dir is admin-only (SYSTEM+Admin)".
- `installer.ps1:2816-2822` — sau đó chỉ thêm quyền cho `LocalService`, không thu hồi `Users`.

**Tác động:** bất kỳ user local nào cũng đọc được `config.yaml` (có thể chứa DoH URL kèm token), `state.json`, log và cấu trúc cài đặt. Không ghi/execute được, nên mức Low.

**Fix tối thiểu:** truyền `-AdminOnly` tại `3168`/`3311`; `Create-Services` đã tự cấp `RX` cho `LocalService` nên không mất quyền cần thiết.

---

## F9 — Low: Early-skip không kiểm hash binary

**Bằng chứng**
- `installer.ps1:3226-3242` — chỉ kiểm file tồn tại, `Length > 0`, và `Get-FileHash` chạy được; không so với hash manifest/staged.

**Tác động:** binary bị thay/thối một phần nhưng vẫn đọc được sẽ qua cổng early-skip khi tag trong `state.json` khớp manifest (`installer.ps1:3273-3279`, `3298-3305`) → không cài lại, lỗi tồn tại âm thầm.

**Fix tối thiểu:** lưu hash của 6 binary vào `state.json` lúc commit và so lại trong `Test-LiveBinariesHealthy`; hoặc chỉ early-skip khi có `-ForceUpdate` đảo nghĩa (không khuyến nghị).

---

## F10 — Low: Elevation chạy lại file mà không xác minh nội dung

**Bằng chứng**
- `installer.ps1:51-56` — `SelfPath` lấy từ `$PSCommandPath`; nếu rỗng (irm|iex) thì tạo tên GUID mới trong `%TEMP%`.
- `installer.ps1:61-65` — đọc `SelfContent` một lần, không dùng để đối chiếu lại.
- `installer.ps1:528-538`, `553` — ghi `SelfContent` ra `SelfPath` nếu chưa có, rồi `Start-Process -Verb RunAs -File $SelfPath`.

**Tác động:** với irm|iex, đường dẫn là GUID mới nên không đoán trước được — an toàn. Với chạy bằng file, nếu script nằm trong thư mục mà user không phải admin ghi được, nội dung có thể bị đổi giữa lần chạy đầu và lần re-exec elevated → chạy code tuỳ ý bằng admin. Điều kiện khá hẹp nên xếp Low.

**Fix tối thiểu:** băm `SelfContent`, ngay trước `Start-Process` đọc lại `SelfPath` và so hash; lệch thì dừng.

---

## F11 — Low: Seam `SEDG_INSTALL_PATH` không được validate

**Bằng chứng**
- `installer.ps1:75-77` — gán thẳng `$script:InstallPath = $env:SEDG_INSTALL_PATH` khi seam active.
- `installer.ps1:2659` — giá trị được `Replace('%%INSTALLPATH%%', ...)` vào template watchdog, nằm trong chuỗi **single-quoted** (`$InstallPath = '%%INSTALLPATH%%'`).
- `installer.ps1:3469` — `Remove-Item -LiteralPath $script:InstallPath -Recurse -Force`.

**Tác động:** chỉ khi người dùng chủ động truyền `-AllowSeam` (hoặc chạy non-admin, nhưng khi đó seam không được forward sang tiến trình elevated — `installer.ps1:551`). Một dấu `'` trong đường dẫn làm hỏng script watchdog; đường dẫn sai/không kiểm soát khiến lệnh xoá đệ quy nhắm sai chỗ.

**Fix tối thiểu:** yêu cầu đường dẫn tuyệt đối, từ chối `'`, `"`, `..`, và kiểm `$script:InstallPath` nằm dưới một root cho phép trước mọi `Remove-Item -Recurse`.

---

## F12 — Low: Tài liệu lệch mã nguồn

**Bằng chứng**
- `codemap.md:4` — ghi "112 functions, ~202KB"; thực tế 117 hàm, ~211.8KB, 3.989 dòng.
- `codemap.md:7` — ghi `-Action Install-All/Update-All`; `ValidateSet` thực tế là `Install|Update|Pause|Resume|Restart|Uninstall|Status|SetUpstream|SetDns|Menu` (`installer.ps1:6`), dispatcher ở `installer.ps1:3946-3960`.
- `codemap.md:16`, `codemap.md:33` — số dòng dispatcher/staging cũ (`~L3713`, `~L1625`), nay là `3946`, `1718`.
- `docs/FUNCTION_CONTRACTS.md:39` — ghi staging "chỉ TEMP"; thực tế `$script:TempPath` nằm dưới `%ProgramData%` (`installer.ps1:92-93`).
- `docs/FUNCTION_CONTRACTS.md:66` — dispatcher "3667-3710"; thực tế `3946-3960`.
- `README.md:29`, `README.md:200` — "administrator-only directory", trái với F8.
- `README.md:31` — cam kết rollback, trái với F4.

**Tác động:** người vận hành/agent tiếp theo tin vào hành vi và vị trí không còn đúng, dễ sửa nhầm hoặc bỏ qua đúng chỗ.

**Fix tối thiểu:** cập nhật 4 con trỏ trên; thêm ghi chú "line numbers có thể lệch" nếu không muốn bảo trì thường xuyên.

---

## Đã xác minh

Các điểm sau được xác nhận trực tiếp từ mã, không cần runtime:

1. **Không có Critical.** Không tìm thấy đường leo thang từ non-admin lên admin/SYSTEM chỉ bằng đầu vào công khai khi chạy đúng luồng; các đường nguy hiểm đều cần hoặc manifest compromise (F1), hoặc local attacker + elevated run (F5, F10), hoặc seam tường minh (F11).
2. **Verify → commit của component không phải TOCTOU khai thác được bởi non-admin.** Zip được băm tại `installer.ps1:1757/1773/1830`, staging `Set-SecureAcl -AdminOnly` (`1726`), và nếu ACL fail thì abort (`Set-SecureAcl` throw tại `1356`). Kẻ tấn công không ghi được vào staging giữa verify và extract.
3. **`nssm` là component duy nhất có URL do manifest quyết định**, không bị allow-list theo repo như dnsproxy/zapret (`644`, `713-719`).
4. **Fallback manifest không có cross-check** khi primary thất bại (`762-769` vs `778`).
5. **`Create-Services` xoá service cũ trước khi tạo service mới** (`2763`), và `Update-All` gọi nó sau khi đã commit binary (`3318`, `3324`).
6. **Catch của `Update-All` không tạo lại service** (`3348-3352`).
7. **Uninstall return trước `Remove-Services`** khi thư mục không tồn tại (`3438-3441` vs `3459`); `Remove-Services` throw trước khi unregister task (`2750-2755`).
8. **Install root được cấp `Users:(OI)(CI)RX`** qua `Set-SecureAcl` không `-AdminOnly` (`1354`, `3168`, `3311`).
9. **Watchdog bỏ qua exit code của `netsh` và ghi flag vô điều kiện** (`2557-2560`, `2646-2655`).
10. **ZipSlip check nằm sau `Expand-Archive`** (`964-977`).
11. **Rủi ro đã được audit trước chấp nhận, không tính lại:** host/repo compromise (F1 cũ), `version.json` TOFU (F7 cũ), binary không ký (F12 cũ). Xem `docs/SECURITY_AUDIT.md`.
12. **Các fix trước vẫn còn hiệu lực:** seam lock khi elevated (`75-81`), pending-reboot guard (`3074-3076`), redact log (được tham chiếu trong `docs/SECURITY_AUDIT.md`), ZipSlip guard có tồn tại (dù sai thứ tự).

## Chưa xác minh

Chỉ là giả thuyết từ mã hoặc phụ thuộc runtime Windows; **không** khẳng định là bug:

1. **`LocalService` có thể không ghi được NSSM stdout log.** `AppStdout`/`AppStderr` trỏ `dnsproxy-nssm.log` (`installer.ps1:2793-2797`), nhưng quyền `M` chỉ cấp cho `dnsproxy.log` (`2818-2821`). Nếu NSSM mở log với token của service account, service có thể fail khi start. Cần chạy trên Windows để xác nhận; có thể NSSM tạo/mở file trước khi hạ quyền.
2. **Trạng thái thực sau timeout của `Remove-Services`.** Mã cho thấy task còn nguyên, nhưng chưa xác minh service có thực sự biến mất sau `sc.exe delete` trong trạng thái `DeletePending` hoặc hành vi của watchdog khi file script mất.
3. **Hành vi của `Expand-Archive` trên PowerShell 5.1 với entry `..`.** Một số bản `Microsoft.PowerShell.Archive` tự chặn; nếu vậy F7 chỉ còn là vấn đề thứ tự, không phải đường ghi file.
4. **Hành vi watchdog khi resolver bị chặn.** `dns.google`/`one.one.one.one` (`installer.ps1:2609`) là target phụ, chỉ dùng khi upstream host không resolve được; chưa đo được trong mạng thực tế của người dùng mục tiêu.
5. **Tần suất thực của early-skip sai hash (F9).** Cần log/thực nghiệm để biết binary có bị thay cục bộ trong thực tế hay không.
6. **Khả năng khai thác F10.** Phụ thuộc quyền ghi của user khác trên thư mục chứa script gốc và việc admin chạy lại đúng file đó; chưa dựng kịch bản.

## Top 3 nên xử lý trước

1. **F1 — trust root của manifest + `nssm`.** Đây là đường duy nhất từ một nguồn cấu hình (manifest) tới thực thi binary tuỳ ý bằng Administrator/SYSTEM, và fallback đang yếu hơn primary một cách không cần thiết. Fix nhỏ (bỏ URL/hash nssm khỏi manifest, dùng hằng số nhúng) nhưng xoá bỏ hẳn một lớp rủi ro cao nhất.
2. **F2 — Uninstall bỏ sót service/task SYSTEM.** Hậu quả kéo dài vô hạn (task chạy mỗi phút, không tự biến mất), ảnh hưởng trực tiếp người dùng cuối và các lần cài lại; fix chỉ là đổi thứ tự vài dòng.
3. **F3 — Update lỗi làm mất service.** Update là luồng chạy thường xuyên nhất; lỗi ở bước tạo service đang biến một lần update hỏng thành gateway ngừng hoạt động, trong khi thông điệp lại nói đã phục hồi. Sửa catch để tạo lại service (hoặc không xoá service cho tới khi mọi validation xong) là thay đổi nhỏ, tác động lớn.
