# sedg-suite

Trinh cai dat va quan ly tu dong cua cong gateway DNS + dieu khien luu trinh tren Windows, dua tren Zapret va AdGuard DNSProxy.

[![CI](https://github.com/projectofwang/sedg-suite/actions/workflows/ci.yml/badge.svg)](https://github.com/projectofwang/sedg-suite/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/projectofwang/sedg-suite)](https://github.com/projectofwang/sedg-suite/releases)

## Tong quan

Kho luu tru nay cai dat Windows theo mot cach moi lan: tai cac thanh phan
da ghim phien ban, cai dat vao thu muc co dinh, dang ky chung thanh dich vu
Windows, va giu DNS hoat dong qua mot task watchdog theo lich.

Tren Windows 11 x64, **SEDG Desktop Manager** la management surface chinh:
trang thai, DNS upstream, dich vu, log, cap nhat/go cai dat. Trinh cai dat
(`installer.ps1`) van la bootstrap va CLI `-Action` cho automation va recovery.
Tat ca phien ban thanh phan duoc ghim trong
[`approved-releases.json`](approved-releases.json), gom ca manager.

Engine cai `sedg-manager.exe` trong thu muc cai dat
(`C:\serverless-edge-dns-gateway` mac dinh); go gateway cung xoa manager.
`Gateway-Manager.bat` trong thu
muc engine van la rollback path mot chu ky phat hanh ve menu console neu GUI
khong khoi dong duoc.

## Tinh nang

- **SEDG Desktop Manager** (Rust + Tauri): trang thai, upstream, dich vu,
  log, cap nhat/go cai dat; thao tac can quyen di qua broker cua chinh exe,
  GUI van khong giu dac quyen.
- Cai dat, cap nhat, tam dung, tiep tuc, khoi dong lai, xem trang thai, va gho
  bo mot dong lenh.
- Console rollback (`Gateway-Manager.bat`, duoc tao trong thu muc cai dat) tu
  dong nang quyen len administrator.
- Dich vu DNS (dnsproxy) voi cac upstream san hoac URL DoH/DoT/DoH3/DoQ tuy chinh.
- Dich vu dieu khien luu trinh (winws) voi file tham so va danh sach domain tuy chinh.
- Task watchdog chay moi phut va khoi phuc DNS theo DHCP sau 3 loi lien tiep
  (mac dinh fail-open; dung `-FailClosed` de giu trang thai).
- Tu dong ap DNS cho cac adapter mang moi ket noi.
- Tai ve theo tung tep voi xac minh SHA-256 vao thu muc chi admin moi truy cap duoc.
- Sao luu DNS theo tung adapter, khong bao gio bi ghi de boi du lieu tam.
- Hoan tac khi that bai: cai dat hoac cap nhat loi se khoi phuc trang thai truoc do.
- Menu da ngon ngu (Anh va Viet).

## Yeu cau

Cac yeu cau duoc trinh cai dat kiem tra (`installer.ps1`):

- Engine: Windows 10 phien ban 1803 (build 17134) tro len, 64-bit x64; ARM64
  bi engine tu choi.
- Desktop Manager GUI: chi Windows 11 x64. Windows 10 va ARM64 **khong** phai
  GUI target. Day la observed compatibility, khong phai claim Microsoft support.
- Manager da publish la mot exe self-contained `win-x64` (`sedg-manager.exe`);
  khong can cai .NET, Windows 11 co san WebView2 runtime ma no dung.
- Windows PowerShell 5.1 tro len cho engine.
- Quyen administrator (launcher va script tu nang quyen; GUI hoi broker cho
  thao tac can quyen).
- Ket noi HTTPS toi cac endpoint phat hanh ghi trong
  [`approved-releases.json`](approved-releases.json).

## Cai dat

Tren Windows 11 x64, cai mot lan bang one-line bootstrap. Lenh nay cai engine
va Desktop Manager. Chay trong PowerShell voi quyen administrator:

```powershell
irm https://dl.taiyuanwangjie.dpdns.org/installer.ps1 | iex
```

Hoac tai kho luu tru va chay script truc tiep (thao tac mac dinh la menu tuong
tac):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer.ps1 -Action Install
```

Thu muc cai dat mac dinh la `C:\serverless-edge-dns-gateway`. Qua trinh cai dat
dang ky hai dich vu (`winws-service`, `dnsproxy-service`) va mot scheduled task
(`SEDG-DNS-Watchdog`). `sedg-manager.exe` duoc cai trong cung thu muc. Chay
`sedg-manager.exe` sau khi cai; day la management surface
chinh. `Gateway-Manager.bat` trong thu muc engine van la rollback path mot chu
ky phat hanh ve menu console.

Manager da publish la mot exe self-contained `win-x64`;
`tools/Publish-Manager.ps1` build va verify zip, va chi co mode payload phat
hanh.

> **Trang thai manager release:** manager duoc ghim trong
> `approved-releases.json` la `sedg-manager-win-x64-2.0.0.zip`, phat hanh tren
> tag release tran `2.0.0` vi release la immutable. Kiem thu tren may that cho
> installer/engine da pass ngay 2026-10-26 voi installer `v2.0.1` (cai sach +
> reboot, update drill cung phien ban, pause/resume, restart, upstream, DNS, CDN,
> uninstall + reboot). GUI manager, prompt UAC va duong broker chua duoc chay
> end-to-end; screenshot GUI va toggle ngon ngu trong app van phai lam thu cong,
> va rollback drill `1.2.6` theo ke hoach khong chay duoc vi release do chua
> bao gio duoc publish.

## Su dung

Desktop Manager cung cap cac thao tac tuong tu qua cua so; dong lenh ben duoi
van danh cho automation, recovery, va rollback path `Gateway-Manager.bat`.

Dong lenh:

```powershell
# Cai dat
.\installer.ps1 -Action Install

# Xem trang thai (phien ban, upstream, DNS cuc bo)
.\installer.ps1 -Action Status

# Doi upstream DNS (URL ma hoa tuyet doi)
.\installer.ps1 -Action SetUpstream -Upstream https://cloudflare-dns.com/dns-query

# Khoi dong lai, tam dung, hoac tiep tuc dich vu
.\installer.ps1 -Action Restart
.\installer.ps1 -Action Pause
.\installer.ps1 -Action Resume

# Cap nhat len phien ban duoc phe duyet moi nhat
.\installer.ps1 -Action Update

# Gho bo cai dat
.\installer.ps1 -Action Uninstall
```

Cac thao tac: `Install`, `Update`, `Pause`, `Resume`, `Restart`, `Uninstall`,
`Status`, `SetUpstream`, `SetDns`, `Menu`.

Cac co duoc ho tro:

| Co | Tac dung |
| --- | --- |
| `-Upstream <value>` | URL upstream tuyet doi dung `https://`, `tls://`, `h3://`, hoac `quic://`. Ten upstream san duoc chon tuong tac tu menu. |
| `-Language <en\|vi>` | Ngon ngu menu cho lan chay nay. |
| `-IncludeCdnTest` | Chay kiem tra ket noi CDN sau khi cai dat hoac cap nhat. |
| `-ForceUpdate` | Bo qua kiem tra phien ban som va tai ve lai day du. |
| `-Clean` | Cai dat moi thay cho qua trinh cap nhat tai cho. |
| `-DnsOnly` | Chi cai dat DNS; dich vu winws duoc dang ky voi kieu khoi dong thu cong (demand) va khong duoc chay. |
| `-Purge` | Kiem hop voi `Uninstall`, xu ly them log, tep ngon ngu, ghi nhan adapter, va du lieu staging. |
| `-FailClosed` | Tat ho tro DHCP (duoc luu lai cho watchdog). |
| `-Action Menu` | Mo menu tuong tac. |

Menu tuong tac (sau `-Action Menu` hoac khi chay `Gateway-Manager.bat`):

1. Cai dat
2. Cap nhat
3. Trang thai
4. Khoi dong lai
5. Tam dung
6. Tiep tuc
7. Upstream DNS
8. DNS he thong
9. Kiem tra CDN
10. Gho bo
11. Ngon ngu
0. Thoat

## Cau hinh

Cac tep nam trong thu muc cai dat (`C:\serverless-edge-dns-gateway`):

| Tep | Cong dung |
| --- | --- |
| `config.yaml` | Cau hinh dnsproxy: cong nghe `127.0.0.1:53` va `[::1]:53`, server upstream, resolver phu, server bootstrap, TTL cache. |
| `blacklist.txt` | Quy tac domain cho winws. Mac dinh rong, nghia la khong khop gi (khong luu trinh nao bi thay doi cho den khi ban them phan tu). |
| `winws-args.txt` | Tham so lenh cua winws, luu dang UTF-8 khong BOM. |

`config.yaml`, `blacklist.txt`, va `winws-args.txt` duoc giu lai qua cac lan
cap nhat va cai dat lai.

Cac upstream DNS san: SDEG (mac dinh), Cloudflare, Google, Quad9,
AdGuard, hoac URL DNS ma hoa tuy chinh. Upstream hien tai duoc hien thi boi
`-Action Status` va luu trong `config.yaml`.

Cac resolver bootstrap (`1.1.1.1`, `8.8.8.8`, va cac gia tri IPv6 tuong ung)
chi duoc ap len cac adapter vat ly khi host phat hanh khong phan giai duoc,
de viec tai ve van thanh cong. Cac gia tri tam nay bi theo doi va khong bao gio
ghi de len ban sao luu DNS theo adapter cua nguoi dung. Danh sach bootstrap trong
`config.yaml` cho dnsproxy con gom `9.9.9.9` va `208.67.222.222`.

## Cap nhat

```powershell
.\installer.ps1 -Action Update
```

Qua trinh cap nhat doc `approved-releases.json` va so sanh phien ban thanh phan.
Noi chi tai phan thay doi vao thu muc staging, xac minh SHA-256 tung tep, sau do
doi tep vao. Dung `-ForceUpdate` de bo qua cac kiem tra phien ban. Neu tep
driver bi he thong dang giu, trinh cai dat dung lai va yeu cau khoi dong lai
thay vi xoa tep bi khoa.

Metadata phat hanh duoc dang tai `version.json` kem `SHA256SUMS`, de ban co the
kiem tra trinh cai dat da tai truoc khi chay.

## Gho bo cai dat

```powershell
.\installer.ps1 -Action Uninstall
```

Lenh gho bo dung va xoa hai dich vu, xoa task watchdog, va khoi phuc cac ban
sao luu DNS theo adapter da chup luc cai dat. Cac tep bi Windows giu se duoc
lich xoa tai lan khoi dong lai tiep theo. Them `-Purge` de xu ly them log, tep
ngon ngu, ghi nhan adapter, va du lieu staging.

## Xu ly su co

- **Xem trang thai hien tai**: `.\installer.ps1 -Action Status` bao cao trang
  thai dich vu, DNS cuc bo, upstream hien tai, va phien ban thanh phan da cai.
- **Log dich vu**: ket qua winws duoc ghi vao `zapret\winws.log` trong thu muc
  cai dat; dnsproxy ghi `dnsproxy.log` va `dnsproxy-nssm.log` trong thu muc
  `dnsproxy`. Duong dan log winws cung duoc hien thi boi thao tac trang thai.
- **"Reboot required" khi cap nhat**: tep driver da staging khac voi tep dang
  tai. Khoi dong lai Windows roi chay cap nhat lai; trinh cai dat khong xoa cac
  tep driver bi khoa ngoai tru luc gho bo.
- **Adapter chua duoc phu hop**: ket qua trang thai co the canh bao adapter do
  khong dung resolver cuc bo. Chay lai `-Action Restart` hoac `-Action SetDns`
  de watchdog ap DNS lai cho adapter moi.
- **DNS rot ve DHCP**: sau 3 loi lien tiep, task watchdog chuyen adapter ve
  DNS gan boi DHCP (fail-open). Kiem tra `winws.log`, roi khoi dong lai dich vu;
  voi `-FailClosed`, viec rot ve bi tat va trang thai truoc do duoc giu lai.
- **Tai ve that bai**: viec cai dat can ket noi HTTPS den host phat hanh. DNS
  bootstrap chi duoc tu dong ap khi host phat hanh khong phan giai duoc.

## Tin cay va rieng tu

- Khong telemetri: trinh cai dat va cac dich vu khong co cuoc goi bao cao hay
  phan tich nao. Luu trinh mang chi gioi han o tai ve phat hanh, manifest phat
  hanh, upstream DNS da cau hinh, va cac quy tac dieu khien luu trinh ma nguoi
  dung bat.
- Tai ve chi qua HTTPS voi xac minh SHA-256 tung tep. Staging nam trong thu muc
  chi admin moi truy cap duoc duoi `ProgramData`.
- Khong dung GitHub API: viec tai ve truc tiep den cac asset phat hanh, va
  manifest phat hanh duoc lay tu endpoint du cua du an voi phan hoi du GitHub.
- Phien ban thanh phan duoc ghim trong `approved-releases.json`; manifest co
  the chay ban sao luu ghep, luc do trinh cai dat canh bao dang dung phien ban
  ghep.
- Phat hanh duoc tao tu tag `vX.Y.Z` duoc bao ve boi ruleset immutable-tag, va
  cac release do workflow tao duoc danh dau immutable.
- Trinh cai dat va cac binary phat hanh khong co chu ky so; hay xac minh tep
  checksum truoc khi chay.
- Ban sao luu DNS duoc luu theo tung adapter (theo interface GUID) va chi duoc
  khoi phuc voi gia tri da chup luc cai dat.
- `blacklist.txt` rong thi khop khong gi, nen viec cai dat mac dinh khong thay
  doi luu trinh ung dung nao.

## Phat trien

Cac tac vu trong kho luu tru:

```powershell
# Chay bo test (Pester 5.2 tro len)
Invoke-Pester ./tests

# Kiem tra ma (PSScriptAnalyzer, chi muc do loi)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error -ExcludeRule PSAvoidUsingWriteHost

# Dong lai manifest ghep tu approved-releases.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-Manifest.ps1 -SkipDownload

# Build va test Rust manager
cargo build --release --locked --manifest-path src/rust/Cargo.toml
cargo test --locked --manifest-path src/rust/Cargo.toml

# Dong goi zip manager da ghim (chi ghi duoi -OutDir)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-Manager.ps1
```

CI chay cac gate PowerShell, ASCII, PSScriptAnalyzer, Pester, manifest/EN-VI
parity, Cloudflare, mot job .NET cho solution cu da nghi huu, va job Rust tren
`windows-latest` build manager, chay test, va lint bang Clippy. Gate manifest
cung kiem tra `manager`
repository/tag/asset/SHA va embedded `$script:Manager*`.

`tools/Update-Manifest.ps1` nhan `-DnsproxyTag`, `-ZapretTag`, `-NssmVersion`,
`-NssmUrl`, `-ManagerTag`, `-ManagerAsset`, `-ManagerSha256`, va
`-SkipDownload`. Hay xem [`approved-releases.json`](approved-releases.json) cho
cac phien ban hien tai thay vi sao chep so phien ban tu tai lieu nay.

Integration smoke tao fixture dnsproxy/zapret/NSSM nhung chua co manager
component/asset. Smoke theo lich se fail tai required-manager check cho den khi
fixture duoc mo rong; desktop manager chua duoc integration-accepted.

Tai san Worker / frontend:

```bash
npm run build:cloudflare   # build cac tai san Cloudflare
npm test                   # cung bo test Pester qua npm
```

Chi tiet trien khai va hosting static duoc mo ta trong
[`cloudflare/README.md`](cloudflare/README.md). Huong dan dong gop trong
[`CONTRIBUTING.md`](CONTRIBUTING.md) va bao cao lo hong trong
[`SECURITY.md`](SECURITY.md).

## Qua trinh phat hanh

- Phat hanh duoc tao tu tag `vX.Y.Z`; tag phai khop voi phien ban trinh cai dat
  khai bao trong `installer.ps1`, nguoc lai workflow that bai.
- Manager duoc publish thanh mot exe self-contained `win-x64`
  `sedg-manager-win-x64-X.Y.Z.zip`; `approved-releases.json` va embedded
  `$script:Manager*` phai dung tag/asset/SHA do. Rebuild khong byte-reproducible,
  nen upload dung artifact da pin, khong phai build moi.
- Go gateway xoa `sedg-manager.exe` cung thu muc cai dat (ban cu trong
  `%ProgramFiles%\SEDG Manager` cung duoc don).
- Workflow phat hanh build tai asset, tao `version.json` va `SHA256SUMS`, roi
  cong bo release.
- Workflow theo lich chay moi Thu Hai luc 02:00 UTC, kiem tra phien ban cac
  thanh phan da ghim, va mo pull request khi co phien ban moi.
- Push len `main` se chay workflow CI (chi cac kiem tra). Viec trien khai endpoint
  tai ve va SDNS duoc xu ly boi tich hop Git cua Cloudflare; xem
  [`cloudflare/README.md`](cloudflare/README.md).

## Cau truc du an

```text
.
|-- .github/
|   `-- workflows/          Workflow CI, phat hanh, va component-watch
|-- cloudflare/             Static assets-only channel (khong Worker script), script build, tai lieu trien khai
|-- src/                    Solution .NET 10 da nghi huu, giu lam rollback reference
|   |-- Sedg.Desktop/       WinForms management surface
|   |-- Sedg.Broker/        Broker nang quyen va pipe protocol host
|   `-- Sedg.Protocol/      Schema request/response dung chung
|-- src/rust/               Rust/Tauri manager (ban phat hanh)
|   |-- src-tauri/          Manager, broker, va setup mode
|   `-- ui/                 Front end HTML/CSS/JS
|-- tests/                  Pester va .NET test suites
|   |-- Sedg.UnitTests/     .NET unit harness khong dependency
|   |-- Installer.Logic.Tests.ps1
|   |-- Installer.Maintain.Tests.ps1
|   `-- integration/        Elevated smoke (Invoke-Smoke.ps1, Build-Fixtures.ps1)
|-- tools/
|   |-- Update-Manifest.ps1 Tao lai approved-releases.json va embedded pins
|   `-- Publish-Manager.ps1 Publish manager win-x64
|-- approved-releases.json  Phien ban thanh phan da ghim va URL manifest
|-- installer.ps1           Logic cai dat, menu, dich vu, va watchdog
|-- package.json            Script build, trien khai, va test
|-- CHANGELOG.md
|-- CODEOWNERS
|-- CONTRIBUTING.md
|-- SECURITY.md
|-- THIRD-PARTY.md
`-- LICENSE
```

## Cam on

- [BIBICADOTNET](https://github.com/BIBICADOTNET) voi y tuong script cai dat
  tu dong goc.
- [AdGuard DNSProxy](https://github.com/AdguardTeam/dnsproxy) cho resolver DNS
  cuc bo.
- [Zapret](https://github.com/bol-van/zapret) cho bo dieu khien luu trinh.
- [NSSM](https://nssm.cc/) cho bo boc goi dich vu Windows.

Du an nay co AI ho tro viet code.

## Giay phep

Du an nay duoc cap giay phep MIT. Xem [`LICENSE`](LICENSE) cho noi dung day du.
Cac thanh phan thu ba giu giay phep rieng; xem [`THIRD-PARTY.md`](THIRD-PARTY.md).
