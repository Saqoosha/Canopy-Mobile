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

// SHARED_SECRET is bound only here, for the test pool — it has no `[vars]`
// entry in wrangler.toml and no `.dev.vars`, on purpose (it's a real secret
// in production, set via `wrangler secret put`). Without this binding
// `env.SHARED_SECRET` is undefined in every test, and comparing against
// `Bearer ${undefined}` would pass with no secret configured at all — see
// index.test.ts's TEST_SHARED_SECRET constant, which must match this value.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: { SHARED_SECRET: "test-secret" },
      },
    }),
  ],
});
