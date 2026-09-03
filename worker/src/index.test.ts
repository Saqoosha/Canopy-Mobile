// worker/src/index.test.ts
import { env, SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";

const auth = { Authorization: `Bearer ${(env as any).SHARED_SECRET}` };

describe("machine directory", () => {
  it("lists a machine after it publishes", async () => {
    await SELF.fetch("https://relay/publish?machine=EEEE-5555", {
      headers: { ...auth, Upgrade: "websocket" },
    });
    const res = await SELF.fetch("https://relay/machines", { headers: auth });
    const body = (await res.json()) as string[];
    expect(body).toContain("EEEE-5555");
  });

  it("refuses an unauthenticated listing", async () => {
    const res = await SELF.fetch("https://relay/machines");
    expect(res.status).toBe(401);
  });

  // /roster is the phone's actual read path (RosterClient + RosterSocket's
  // /watch upgrade both sit behind it); nothing else in the suite exercised
  // its auth ordering before this.
  it("refuses an unauthenticated roster read", async () => {
    const res = await SELF.fetch("https://relay/roster?machine=EEEE-5555");
    expect(res.status).toBe(401);
  });
});
