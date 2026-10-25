# Cloudflare distribution

Static hosting for the installer. Cloudflare Workers Builds deploys this
directory's build output; it plays no role at component runtime - the
installer fetches its manifest here, then downloads binaries from their
pinned upstream sources.

## Deploy

Push to `main` auto-builds via the dashboard Git integration:

- Build: `bash cloudflare/build.sh` (`npm run build:cloudflare`)
- Deploy: `npm run deploy:cf` (primary, `cf` CLI)
- Fallback: direct Wrangler path via `wrangler.toml` (currently no npm script for it)
- Root directory: `/`, branch: `main`

The build rejects installer/manifest version mismatch, then emits
`cloudflare/public/`. `version.json` carries the published `installer.ps1`
SHA-256; `_headers` applies `no-store` and security headers (assets-only
deploy, no Worker script). GitHub Actions runs checks only - no deploys, no
`CLOUDFLARE_API_TOKEN` secret.

Prerequisites: run `npm ci` at the repo root **and** in `cloudflare/` (both
`package-lock.json` files are committed; run `npm install` only when you change
dependencies). Real deploys also need `cf auth login` (dry runs need no
sign-in). The `cf` beta cannot spawn its Wrangler delegate on Windows
(`spawn EFTYPE`), so the build step calls the delegate directly through
`node`:

- Dry run: `npm run deploy:cf:dry`
- Deploy: `npm run deploy:cf`

When upstream `cf` fixes the Windows spawn, replace the delegate call
with plain `cf build`. Transitive pre-releases (e.g. miniflare alpha, unenv
rc) ride along with the pinned deps and are not bumped separately.

Smoke (after deploy, 3 lines — version.json commit must equal HEAD):

```sh
BASE=https://dl.taiyuanwangjie.dpdns.org
[ "$(curl -fsSL "$BASE/version.json" | node -p "JSON.parse(require('fs').readFileSync(0,'utf8')).commit")" = "$(git rev-parse HEAD)" ] && echo "smoke OK"
```

Wrangler fallback (direct path via `wrangler.toml`, currently no npm script) targets Wrangler 4.x
(pinned in `cloudflare/package.json`); the fallback path is kept for
emergencies and is not regularly tested — prefer `npm run deploy:cf`.

## Files

`/` (landing page with install command, from `landing.html`) -
`/installer.ps1` - `/approved-releases.json` - `/version.json` - `/SHA256SUMS`

## Endpoints

- `https://dl.taiyuanwangjie.dpdns.org/` (landing page)
- `https://dl.taiyuanwangjie.dpdns.org/installer.ps1`
- `https://dl.taiyuanwangjie.dpdns.org/approved-releases.json`
- `https://dl.taiyuanwangjie.dpdns.org/version.json`
- `https://dl.taiyuanwangjie.dpdns.org/SHA256SUMS`

Flow: GitHub `main` -> Workers Builds -> static assets -> `dl.` subdomain.
The default DoH upstream is `https://sdns.taiyuanwangjie.dpdns.org/dns-query`;
other presets (Cloudflare, Google, Quad9, AdGuard) or a custom URL can be
picked in the installer's menu.
