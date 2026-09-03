// The pool is what gives the test a real DO; plain vitest cannot construct one.
//
// The brief called for `defineWorkersConfig` from
// `@cloudflare/vitest-pool-workers/config` (the API shape in 0.8.x). That
// subpath and helper no longer exist in the installed 0.22.0 — the package
// dropped the pool-config helper for a Vite-plugin API (`cloudflareTest`)
// exported from its root entry. Same package, same wrangler.toml wiring,
// newer shape.
import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
    }),
  ],
});
