# cloudflare/

## Responsibility

Static distribution channel for the installer. Publishes `installer.ps1`, `approved-releases.json`, and generated integrity files (`version.json`, `SHA256SUMS`) plus a landing page (`index.html`) on the `dl.*` custom domain. Plays no role at component runtime — the installer fetches its manifest here, then downloads binaries from pinned upstream sources.

## Design

- **Assets-only deploy, no Worker script:** no `main` entrypoint. `wrangler.toml` is the source of truth for worker name / route / `compatibility_date`; `wrangler.config.ts` (Wrangler behavior: `assetsDirectory: ./public`, no types) and `cloudflare.config.ts` (`cf` CLI worker block, fetch trigger) mirror it.
- **Build-generated `public/`:** `build.sh` is the sole generator — copies `installer.ps1`, `approved-releases.json`, `landing.html`→`index.html`, favicon + mascot sprites; normalizes staged copies to CRLF (deterministic hashes across Windows/Unix checkouts); writes `_headers`, `version.json` (version/commit/SHA-256/built), `SHA256SUMS`.
- **Version gate:** build parses `$script:InstallerVersion` from `installer.ps1` (sed) and `.installer.version` from `approved-releases.json` (node, avoids false NSSM-version match); mismatch or unparseable → hard fail.
- **Headers instead of Worker logic:** `_headers` sets `no-store` on `/`, `/index.html`, `/installer.ps1`, `/version.json`, `/approved-releases.json`, `/SHA256SUMS`, plus `nosniff` / `DENY` / HSTS / strict CSP; explicit `text/plain` for `.ps1` and `SHA256SUMS`. `workers_dev = false` — custom domain only.
- **Landing page (`landing.html`):** single static file, inline CSS + vanilla JS (no build step): VI/EN toggle via `data-en`/`data-vi` + localStorage, copy buttons (clipboard + textarea fallback), version badge + `sha256:` line fetched from `/version.json` (`no-store`), starfield/meteor canvas and cursor-tracking mascots, all `prefers-reduced-motion`-aware, `noindex`. Static assets: `mascots/*.webp` (10 sprite sheets) + `favicon.svg`.
- **Dual deploy CLIs:** primary `cf` beta (`npm run deploy:cf`, node-invoked Wrangler delegate as Windows `spawn EFTYPE` workaround), fallback Wrangler (direct path via `wrangler.toml`, currently no npm script). GitHub Actions runs checks only — never deploys.

## Flow

Build/deploy (push to `main`):

1. Workers Builds (root `/`, branch `main`) runs `bash cloudflare/build.sh` (`npm run build:cloudflare`): wipe/recreate `cloudflare/public/`, copy sources + landing page + assets.
2. Normalize line endings (CRLF) → write `_headers` → version gate (installer vs manifest) → stamp `version.json` (git HEAD, sha256 of staged `installer.ps1`) and `SHA256SUMS`.
3. Deploy `public/` as static assets to route `dl.taiyuanwangjie.dpdns.org/*` (zone `taiyuanwangjie.dpdns.org`); dry run via `npm run deploy:cf:dry` needs no login, real deploy needs `cf auth login`.

Request lifecycle (user install):

1. `GET /` → landing page; badge fetches `/version.json`, shows `version · short-commit`.
2. User copies `irm https://dl…/installer.ps1 | iex` (or 3-step verify: download → cross-check SHA-256 against GitHub Releases `SHA256SUMS`, different origin → run with `Bypass`).
3. Installer reads `approved-releases.json` from this origin, then pulls dnsproxy/zapret/NSSM binaries from their pinned upstreams — this host never serves binaries.

## Integration

- **Consumed by:** Windows users via `irm … | iex`; `installer.ps1` at runtime (manifest + integrity check against `version.json`/`SHA256SUMS`).
- **Depends on:** repo-root `installer.ps1` + `approved-releases.json` (only inputs); `cf` beta / Wrangler 4.x devDeps; Cloudflare Workers Builds + DNS (custom-domain route); GitHub Releases `SHA256SUMS` as independent cross-check origin.
- **Links out to (docs only):** upstream `dnsproxy`, `zapret`, `nssm` project pages and the GitHub repo; default DoH upstream `https://sdns.taiyuanwangjie.dpdns.org/dns-query` is referenced by the installer, not served here.
