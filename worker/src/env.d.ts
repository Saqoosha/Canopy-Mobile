// Fills in the ambient `Cloudflare.Env` extension point that
// `@cloudflare/workers-types` declares empty (`interface Env {}`) and that
// `cloudflare:test`'s exported `env` is typed against (`export const env:
// Cloudflare.Env`). Without this, `env.MACHINE` in machine.test.ts has no
// declared shape at all. Kept separate from index.ts's own local `Env`
// interface, which types the Worker's own `fetch(request, env)` parameter
// and does not need this global.
import type { MachineDO } from "./machine";

declare global {
  namespace Cloudflare {
    interface Env {
      MACHINE: DurableObjectNamespace<MachineDO>;
      SHARED_SECRET: string;
    }
  }
}

export {};
