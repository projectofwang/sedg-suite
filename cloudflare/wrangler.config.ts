// Source of truth for worker name / route / compatibilityDate: wrangler.toml,
// this file only configures Wrangler behavior (assets directory, types);
// no worker block here (assets-only deploy, no Worker script / no `main`).
import { defineWranglerConfig } from "wrangler/experimental-config";

export default defineWranglerConfig({
	types: {
		generate: false,
	},
	assetsDirectory: "./public",
});
