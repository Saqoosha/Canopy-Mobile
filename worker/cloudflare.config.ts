import { bindings, defineConfig, exports } from "cf/config";

export default defineConfig({
	accountId: "0f56ad2619afc619cc2975dd0728f8a9",
	worker: {
		name: "canopy-mobile-relay",
		compatibilityDate: "2026-08-22",
		entrypoint: "src/index.ts",
		observability: {
			enabled: true,
			headSamplingRate: 1,
		},
		env: {
			APNS_KEY_ID: bindings.text("SRH3669YH6"),
			APNS_TEAM_ID: bindings.text("VCFY2GFR89"),
			APNS_BUNDLE_ID: bindings.text("sh.saqoo.canopy-app"),
			APNS_USE_SANDBOX: bindings.text("false"),
			MACHINES: bindings.kv({
				id: "34a34a05b2194af6b9f2c89847a57ea1",
			}),
			IMAGES: bindings.r2({
				name: "canopy-mobile-images",
			}),
			MACHINE: bindings.durableObject({
				worker: "canopy-mobile-relay",
				exportName: "MachineDO",
			}),
		},
		// Replaces wrangler.toml's `[[migrations]] tag = "v1", new_sqlite_classes = ["MachineDO"]`:
		// the existing SQLite namespace stays as is (Cloudflare docs, "Migrate from the legacy
		// migrations flow").
		exports: {
			MachineDO: exports.durableObject({ storage: "sqlite" }),
		},
	},
});
