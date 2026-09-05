// worker/src/index.test.ts
import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { safeSlice } from "./llm";
import { fitPushPayload } from "./index";

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

describe("decide", () => {
  it("decide is refused when no publisher is connected", async () => {
    const res = await SELF.fetch("https://x/decide", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "no-such-mac", sessionId: "s1", requestId: "r1", decision: "allow" }),
    });
    expect(res.status).toBe(503);
  });

  // "allow_always" stands in for Allow Always, which the capture document
  // pins as `allow` plus a derived `updatedPermissions` rule — not a third
  // `behavior` value — so it is not a legal `decision` here either.
  it("decide rejects a decision value outside the captured set", async () => {
    const res = await SELF.fetch("https://x/decide", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "m1", sessionId: "s1", requestId: "r1", decision: "allow_always" }),
    });
    expect(res.status).toBe(400);
  });

  it("decide requires a requestId", async () => {
    const res = await SELF.fetch("https://x/decide", {
      method: "POST",
      headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
      body: JSON.stringify({ machine: "m1", sessionId: "s1", decision: "allow" }),
    });
    expect(res.status).toBe(400);
  });
});

describe("safeSlice", () => {
  const loneSurrogate = (s: string) =>
    [...s].some((c) => {
      const p = c.codePointAt(0)!;
      return p >= 0xd800 && p <= 0xdfff;
    });

  it("never leaves half of a surrogate pair", () => {
    // The exact shape that failed: one ASCII char, so every even cut lands
    // between an emoji's two UTF-16 code units.
    const body = "x" + "🍎".repeat(2000);
    expect(loneSurrogate(body.slice(0, 3000))).toBe(true); // what .slice does
    expect(loneSurrogate(safeSlice(body, 3000))).toBe(false); // what we do
  });

  it("counts code points, not code units", () => {
    // Both differ from a plain `.slice`; what differs is HOW it is wrong.
    // Measured: `"🍎🍎🍎".slice(0,2)` is "🍎" — valid text, but one emoji
    // short, because two UTF-16 units are one pair. `"あ🍎b".slice(0,2)` is
    // "あ" plus a lone surrogate — broken text. The first is the counting
    // contract, the second the corruption; a helper that only fixed the
    // second would still return the wrong number of characters.
    expect(safeSlice("🍎🍎🍎", 2)).toBe("🍎🍎");
    expect(safeSlice("あ🍎b", 2)).toBe("あ🍎");
  });

  it("keeps a pair whole at the exact boundary", () => {
    // n = 1 over a pure-emoji string is the smallest cut that can split one.
    expect(safeSlice("🍎🍎", 1)).toBe("🍎");
    expect("🍎🍎".slice(0, 1)).not.toBe("🍎"); // what we protect against
  });
});

describe("delivery acknowledgement", () => {
  const auth = {
    Authorization: `Bearer ${TEST_SHARED_SECRET}`,
    "Content-Type": "application/json",
  };

  it("does not report success when no Mac is connected", async () => {
    // The shape this protocol exists to end: before the ack, the relay
    // answered 200 as soon as it had written to a socket — and on a
    // half-open connection that write succeeds. The user was told their
    // message had been sent while nothing had happened.
    const res = await SELF.fetch("https://x/reply", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ machine: "no-such-mac", sessionId: "s1", text: "hi" }),
    });
    expect(res.status).toBe(503);
    expect(res.status).not.toBe(200);
    const body = (await res.json()) as { ok: boolean; reason?: string };
    expect(body.ok).toBe(false);
    expect(typeof body.reason).toBe("string");
  });

  it("does not report success for a decision no Mac can take", async () => {
    const res = await SELF.fetch("https://x/decide", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        machine: "no-such-mac",
        sessionId: "s1",
        requestId: "abc",
        decision: "allow",
      }),
    });
    expect(res.status).toBe(503);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(false);
  });
});

describe("AskUserQuestion form", () => {
  const form = [
    { question: "Which database?", header: "DB", multiSelect: false, options: ["Postgres", "SQLite"] },
  ];

  it("passes a well-formed answers map through to the Mac", async () => {
    // 503, not 400: no publisher is connected in this test, so getting as far
    // as delivery is the proof it cleared validation. A 400 would mean the
    // relay rejected the shape it is supposed to forward untouched.
    const res = await SELF.fetch("https://x/decide", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        machine: "AAAA-1111", sessionId: "s1", requestId: "r1",
        decision: "allow", answers: { "Which database?": "Postgres" },
      }),
    });
    expect(res.status).toBe(503);
  });

  it("rejects an answers map that is not an object of strings", async () => {
    for (const answers of [["Postgres"], "Postgres", { q: 1 }, { q: ["a"] }]) {
      const res = await SELF.fetch("https://x/decide", {
        method: "POST",
        headers: auth,
        body: JSON.stringify({
          machine: "AAAA-1111", sessionId: "s1", requestId: "r1",
          decision: "allow", answers,
        }),
      });
      expect(res.status, JSON.stringify(answers)).toBe(400);
    }
  });

  it("leaves a decision with no answers alone", async () => {
    const res = await SELF.fetch("https://x/decide", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        machine: "AAAA-1111", sessionId: "s1", requestId: "r1", decision: "allow",
      }),
    });
    expect(res.status).toBe(503);
  });

  // The push budget. `bodyFull` is context and goes first; `choices` are the
  // buttons and go last, because an ask the phone cannot answer is the state
  // this whole field was added to end.
  it("keeps the buttons and shrinks the body when the payload is too large", () => {
    const fitted = fitPushPayload(
      { title: "t", body: "b", bodyFull: "x".repeat(4000), choices: form },
      1000,
    );
    expect(fitted.choices).toEqual(form);
    expect(fitted.bodyFull.length).toBeLessThan(4000);
    expect(new TextEncoder().encode(JSON.stringify(fitted)).length).toBeLessThanOrEqual(1000);
  });

  it("drops the buttons only once the body is exhausted", () => {
    // A limit no payload carrying this form can meet, so the body reaches
    // zero and the second stage has to fire. Without it the function returns
    // something over the limit and APNs drops the push silently.
    const fitted = fitPushPayload(
      { title: "t", body: "b", bodyFull: "x".repeat(500), choices: form },
      120,
    );
    expect(fitted.choices).toBeUndefined();
    expect(fitted.bodyFull).toBe("");
  });

  it("leaves a payload that already fits completely alone", () => {
    const payload = { title: "t", body: "b", bodyFull: "short", choices: form };
    expect(fitPushPayload(payload, 4096)).toEqual(payload);
  });
});
