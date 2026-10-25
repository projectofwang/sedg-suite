// Source of truth for worker name / route / compatibilityDate: wrangler.toml,
// keep in sync. worker block is the static-assets route only (no `main`,
// assets-only deploy, no Worker script).
import { defineConfig, triggers } from "cf/config";

export default defineConfig({
	worker: {
		name: "sedg-with-zapret-dpi-bypass-auto-installer",
		compatibilityDate: "2026-09-27",
		// Parity with wrangler.toml `workers_dev = false`: custom domain only,
		// no default *.workers.dev route.
		workersDev: false,
		triggers: [
			triggers.fetch({
				pattern: "dl.taiyuanwangjie.dpdns.org/*",
				zone: "taiyuanwangjie.dpdns.org",
			}),
		],
	},
});
