// worker/src/index.test.ts
import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";

// Must match the SHARED_SECRET binding in vitest.config.ts. Spelled as a
// literal rather than read back out of `env` — an expectation derived from
// the same value the code under test compares against can't tell "correctly
// configured" apart from "both sides are undefined" (the bug this suite
// exists to catch: with no binding at all, both this line and
// `authorized()`'s comparison collapse to the literal string "Bearer
// undefined", and the auth tests pass with no secret configured).
const TEST_SHARED_SECRET = "test-secret";
const auth = { Authorization: `Bearer ${TEST_SHARED_SECRET}` };

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

  it("refuses a listing with the wrong secret", async () => {
    const res = await SELF.fetch("https://relay/machines", {
      headers: { Authorization: "Bearer wrong-secret" },
    });
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

describe("push notifications", () => {
  it("register rejects a non-hex token", async () => {
    const res = await SELF.fetch("https://x/register", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ token: "NOT-HEX" }),
    });
    expect(res.status).toBe(400);
  });

  it("notify is refused when no device has registered", async () => {
    const res = await SELF.fetch("https://x/notify", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "completed" }),
    });
    expect(res.status).toBe(503);
  });

  it("notify rejects an unknown kind", async () => {
    const res = await SELF.fetch("https://x/notify", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "gossip" }),
    });
    expect(res.status).toBe(400);
  });

  it("notify rejects a requestId on a completed push", async () => {
    const res = await SELF.fetch("https://x/notify", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "completed", requestId: "r1" }),
    });
    expect(res.status).toBe(400);
  });

  it("notify requires a requestId on an asking push", async () => {
    const res = await SELF.fetch("https://x/notify", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "asking" }),
    });
    expect(res.status).toBe(400);
  });
});

describe("reply", () => {
  it("reply is refused when no publisher is connected", async () => {
    const res = await SELF.fetch("https://x/reply", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "no-such-mac", sessionId: "s1", text: "hi" }),
    });
    expect(res.status).toBe(503);
  });

  it("reply rejects empty text", async () => {
    const res = await SELF.fetch("https://x/reply", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "m1", sessionId: "s1", text: "   " }),
    });
    expect(res.status).toBe(400);
  });
});
