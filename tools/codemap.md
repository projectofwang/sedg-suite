# tools/

## Responsibility

Maintainer-only manifest tooling. Single script `Update-Manifest.ps1` giữ `approved-releases.json` (source of truth cho pinned component versions + SHA-256) và bản embedded fallback trong `installer.ps1:Get-ApprovedManifest` luôn đồng bộ. Không chạy lúc install runtime, chỉ chạy khi bump component version.

## Design

- Procedural script, `#requires 5.1`, `StrictMode Latest`, `$ErrorActionPreference='Stop'`; không module/class.
- Helpers nội bộ: `Get-UrlHash($Url,$Label)` (curl.exe → fallback `Invoke-WebRequest`, trả `@{Path;Sha256}`), `Assert-ZipHas($Zip,$Pattern,$Label)` (Expand-Archive + regex match runtime), `Set-UniqueReplace($Text,$Old,$New,$What)` (replace đúng 1 occurrence, throw nếu ≠1).
- Canonical JSON: không `ConvertTo-Json`, tự ráp string theo layout cố định (`schema/policy/installer/components.{dnsproxy,zapret,nssm}`), UTF-8 no-BOM, CRLF; giữ optional `nssm.mirror` nếu đã tồn tại.
- Embedded block trong installer resolve gián tiếp qua `$script:NssmVersion/$script:NssmSha256/$script:Sources.NssmZip` (chỉ dnsproxy/zapret embed giá trị literal).
- Quy ước version: bump `$script:InstallerVersion` (installer.ps1:71) và `installer.version` (JSON) cùng lúc; lệch nhau chỉ warning drift, không fail.

## Flow

Input: params `-DnsproxyTag/-ZapretTag/-NssmVersion/-NssmUrl/-SkipDownload`. Output: `approved-releases.json` + `installer.ps1` (edited in place), stdout hash + sync status.

1. Resolve paths (`$repoRoot/$manifestPath/$installerPath`), tạo `$workDir` temp GUID; `finally` xóa.
2. Load JSON, guard `schema -eq 1` và `policy -eq 'approved-only'`, else throw.
3. Nếu không `-SkipDownload`, với mỗi tag/version được truyền: validate regex tag (`^(v)?\d+(\.\d+)*$`, nssm `^\d+(\.\d+)*$`, URL phải `https://`) → dựng asset URL (dnsproxy `AdguardTeam/dnsproxy`, zapret `bol-van/zapret`, nssm `nssm.cc/release` hoặc `-NssmUrl` custom) → `Get-UrlHash` download + SHA-256 → `Assert-ZipHas` kiểm tra `dnsproxy\.exe$` / `windows-x86_64[\\/]winws\.exe$` / `win64[\\/]nssm\.exe$` → ghi đè `tag/asset/url/sha256` vào `$manifest.components`.
4. Serialize canonical JSON (bảo toàn `nssm.mirror`), `WriteAllText` UTF-8 no-BOM.
5. Regex tìm block `$embedded = [pscustomobject]@{...}` trong installer.ps1 (throw nếu không thấy), rebuild block mới từ manifest (nssm dùng script-var refs), thay bằng substring splice.
6. Nếu `-NssmVersion` được truyền: regex 3 dòng `$script:NssmVersion`/`$script:NssmSha256`/`NssmZip`, `Set-UniqueReplace` từng dòng (đúng 1 occurrence).
7. `WriteAllText` installer.ps1, so sánh `$script:InstallerVersion` vs `manifest.installer.version`: mismatch → `Write-Warning` drift, match → `Write-Host` in sync.

## Integration

- Consumed by: maintainer/CI manual run (`README.md` Development: `Update-Manifest.ps1 -SkipDownload` để re-sync; truyền full tag khi bump version).
- Depends on: `approved-releases.json` (đọc + ghi, fields `schema/policy/installer.version/components.*`), `installer.ps1` (đọc + ghi: regex block `$embedded` trong `Get-ApprovedManifest` ~line 706, vars `$script:InstallerVersion`/:71, `$script:NssmVersion/$script:NssmSha256/$script:Sources.NssmZip`).
- Runtime consumer gián tiếp: `installer.ps1:Get-ApprovedManifest` (fetch remote manifest, fallback `$embedded`, throw khi `installer.version` mismatch) và `Update` flow (~line 1596, 2959) — tool này đảm bảo fallback đó không stale.
