# Upstream failover — locked design (đã implement một phần, commit 00a31c2)

Trạng thái: decisions đã chốt với user (2026-10-11) và implement một phần trong `installer.ps1`: `Get-UpstreamList` (:1892), template 6 upstreams + `timeout: 5s` (:1949-1965), `upstream_list` trong `state.json` (:2778), mode `load_balance` native (M7, :1949).

## Quyết định đã chốt

1. **NextDNS IDs của user, free 300k req/tháng** — dùng được. Rủi ro quota: `load_balance` dồn traffic về entry nhanh nhất (ultralow anycast nhiều khả năng thắng weight) → 2 entries NextDNS có thể hút phần lớn query toàn fleet. Chấp nhận có giám sát: hết quota NextDNS trả lỗi → native weight-penalty tự dồn traffic sang 4 entry còn lại (graceful, không rớt mạng). Theo dõi dashboard NextDNS sau 1 tuần canary; per-upstream disable để v2.
2. **Đo trước** — protocol §4. Thứ tự provisional bên dưới, finalize sau số liệu.
3. **Mode = `load_balance` native** (default dnsproxy, không set gì thêm). Không strict top-down (dnsproxy v0.86.0 không có), không parallel/fastest_addr.
4. **"Rớt" + gián đoạn (orchestrator quyết)**: rớt = per-query error/timeout; set `timeout: 5s` (thay vì default 10s) để bound slow-loris drag; KHÔNG đánh dấu chết dài hạn, KHÔNG hysteresis custom — query sau thử lại entry đầu ngay (RTT-weight tự phạt entry hay fail). **Gián đoạn = 0**: failover trong-process dnsproxy, không rewrite config, không restart service.
5. **Custom (orchestrator quyết)**: custom/prefer preset → move-or-prepend lên đầu list; defaults không bao giờ bị xóa; cap tổng **8 entries** (6 default + tối đa 2 custom, thêm quá → evict custom cũ nhất + warn); thêm menu "Reset về defaults".

## Config mục tiêu (provisional, chờ số đo)

```yaml
upstream:
  - "https://ultralow2.dns2.nextdns.io/735d22"
  - "https://sdns.taiyuanwangjie.dpdns.org/dns-query"
  - "https://ultralow2.dns2.nextdns.io/9fcbfc"
  - "https://dns.google/dns-query"
  - "https://cloudflare-dns.com/dns-query"
  - "https://dns.quad9.net/dns-query"
timeout: "5s"
fallback:
  - "https://cloudflare-dns.com/dns-query"
bootstrap: [1.1.1.1, 8.8.8.8, 9.9.9.9, 208.67.222.222]  # giữ nguyên (IP thuần)
```

Lưu ý: 2 NextDNS tách rời (diversity failure-domain); SDEG #2 cho cold-start VN. Dưới `load_balance` thứ tự gần như không ảnh hưởng steady-state (weight theo RTT) — finalize sau đo.

## Thay đổi code (khi implement, hướng A)

- `Write-OriginalConfigTemplate`: sinh 6 entries + `timeout: 5s`; giữ fallback/bootstrap/cache.
- `Set-UpstreamInConfig`: promote/prepend thay vì overwrite 1 dòng; giữ rest + newline style; enforce cap 8 + reset-defaults.
- `Get-ConfiguredUpstream`: primary = entry hợp lệ đầu tiên (giữ contract cũ) + thêm `Get-UpstreamList` trả full list.
- `Ensure-Config`/`Test-ConfigValid`: chấp nhận multi-entry (không rewrite mất); `state.json`: thêm field optional `upstream_list` (watchdog không đổi).
- `Set-Upstream` menu: preset 5→6+NextDNS, custom prepend, reset-defaults. Tests Logic/Maintain mở rộng tương ứng.
- KHÔNG đụng: watchdog (giữ DHCP-fallback safety net), `parallel`/`fastest_addr`, per-upstream health monitor riêng.

## §4 Measurement protocol (chạy trên mạng VN trước implement)

Mỗi upstream: 50 DoH queries (cùng bộ domain gồm CDN VN + quốc tế), 3 khung giờ khác nhau; ghi p50/p95/fail%. Kèm đếm query/ngày trên install live hiện tại để ước quota NextDNS (300k/tháng ≈ 10k/ngày cho cả fleet nếu dồn). Quyết sau đo: thứ tự cuối + giữ cả 2 NextDNS hay rút 1.
