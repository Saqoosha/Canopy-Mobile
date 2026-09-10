// worker/src/index.test.ts
import { SELF, env } from "cloudflare:test";
import { describe, it, expect, vi, afterEach } from "vitest";
import { plainBanner, safeSlice } from "./llm";
import worker, { fitPushPayload } from "./index";

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

  // Through the worker route, not the DO directly: the thing under test is
  // index.ts FORWARDING the field, which a stub.fetch("https://do/reply")
  // would skip. The publisher acks so the route returns 200 instead of
  // waiting out the ack timeout; the assertion is on the envelope it saw.
  it("forwards replyId to the Mac unchanged", async () => {
    const machine = "REPLY-ID-1";
    const upgrade = await SELF.fetch(`https://relay/publish?machine=${machine}`, {
      headers: { ...auth, Upgrade: "websocket" },
    });
    const ws = upgrade.webSocket!;
    ws.accept();
    const envelope = new Promise<Record<string, unknown>>((resolve) => {
      ws.addEventListener("message", (e) => {
        const parsed = JSON.parse(e.data as string) as Record<string, unknown>;
        if (parsed.type !== "reply") return;
        ws.send(JSON.stringify({ type: "ack", deliveryId: parsed.deliveryId, ok: true }));
        resolve(parsed);
      });
    });
    const res = await SELF.fetch("https://relay/reply", {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ machine, sessionId: "s1", text: "hi", replyId: "r-42" }),
    });
    expect(res.status).toBe(200);
    expect((await envelope).replyId).toBe("r-42");
  });

  it("forwards no replyId when the phone sent none", async () => {
    const machine = "REPLY-ID-2";
    const upgrade = await SELF.fetch(`https://relay/publish?machine=${machine}`, {
      headers: { ...auth, Upgrade: "websocket" },
    });
    const ws = upgrade.webSocket!;
    ws.accept();
    const envelope = new Promise<Record<string, unknown>>((resolve) => {
      ws.addEventListener("message", (e) => {
        const parsed = JSON.parse(e.data as string) as Record<string, unknown>;
        if (parsed.type !== "reply") return;
        ws.send(JSON.stringify({ type: "ack", deliveryId: parsed.deliveryId, ok: true }));
        resolve(parsed);
      });
    });
    await SELF.fetch("https://relay/reply", {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ machine, sessionId: "s1", text: "hi" }),
    });
    expect("replyId" in (await envelope)).toBe(false);
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

  // `eventId` is the phone's only handle for "this push and that streamed
  // event are one turn". Losing it under pressure would draw the assistant's
  // message twice — which is exactly what happened when the relay accepted the
  // field and never put it in the payload at all (measured on device).
  //
  // **This pins only that the shrink cascade preserves it.** That the field is
  // put into the payload in the first place is not reachable from here — the
  // route needs a registered device token and an APNs call — and was verified
  // on device instead.
  it("keeps eventId while shrinking the body", () => {
    const fitted = fitPushPayload(
      { title: "t", body: "b", bodyFull: "x".repeat(4000), eventId: "abc" },
      500,
    );
    expect(fitted.eventId).toBe("abc");
  });

  it("keeps eventId even when the buttons are dropped", () => {
    const fitted = fitPushPayload(
      { title: "t", body: "b", bodyFull: "x".repeat(500), choices: form, eventId: "abc" },
      120,
    );
    expect(fitted.choices).toBeUndefined();
    expect(fitted.eventId).toBe("abc");
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

  // A limitation, recorded rather than fixed. The fields left after both
  // stages are the notification's identity, and truncating one would send a
  // push naming the wrong thing — worse than not sending it. What the code
  // does guarantee is that this stops being silent, which is asserted here by
  // the console.error rather than by the (deliberately unchanged) size.
  it("reports rather than hides a payload it cannot shrink far enough", () => {
    const errors: unknown[] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => { errors.push(args[0]); };
    try {
      const fitted = fitPushPayload({ title: "t".repeat(500), body: "b", bodyFull: "x" }, 100);
      expect(new TextEncoder().encode(JSON.stringify(fitted)).length).toBeGreaterThan(100);
      expect(errors.some((e) => String(e).includes("APNs will reject it"))).toBe(true);
    } finally {
      console.error = original;
    }
  });

  it("leaves a payload that already fits completely alone", () => {
    const payload = { title: "t", body: "b", bodyFull: "short", choices: form };
    expect(fitPushPayload(payload, 4096)).toEqual(payload);
  });
});

describe("plainBanner", () => {
  // The reported bug: stripMarkdown empties a fenced block, so fallbackBanner
  // falls back to slicing the raw JSON.
  const askJson = '```json\n{\n  "questions" : [\n    { "question" : "Which database?" }\n  ]\n}\n```';

  it("banners an ask by its questions", () => {
    expect(plainBanner([{ question: "Which database?" }], askJson, 100)).toBe("Which database?");
  });

  it("joins several questions", () => {
    expect(
      plainBanner([{ question: "Which database?" }, { question: "Which region?" }], askJson, 100),
    ).toBe("Which database? · Which region?");
  });

  it("keeps the relay's own banner when there is no form", () => {
    expect(plainBanner(undefined, "Run the migration?", 100)).toBe("Run the migration?");
    expect(plainBanner([], "Run the migration?", 100)).toBe("Run the migration?");
  });

  it("keeps it when every question is blank", () => {
    expect(plainBanner([{ question: "  " }, { question: "" }], "Run it?", 100)).toBe("Run it?");
  });

  it("drops the blank questions and keeps the real ones", () => {
    expect(plainBanner([{ question: " " }, { question: "Which region?" }], askJson, 100)).toBe(
      "Which region?",
    );
  });

  it("refuses anything that is not a list of question-bearing objects", () => {
    expect(plainBanner("questions", "fallback", 100)).toBe("fallback");
    expect(plainBanner([null, 42, { header: "no question" }], "fallback", 100)).toBe("fallback");
  });

  // stripMarkdown would eat both of these. Questions are prose.
  it("leaves markdown-looking question text alone", () => {
    expect(plainBanner([{ question: "Delete *.log or *.tmp?" }], askJson, 100)).toBe(
      "Delete *.log or *.tmp?",
    );
    expect(plainBanner([{ question: "Which shell: bash | zsh?" }], askJson, 100)).toBe(
      "Which shell: bash | zsh?",
    );
  });

  it("does not pair fence markers that came from two different questions", () => {
    const banner = plainBanner(
      [{ question: "Use ```json" }, { question: "middle question" }, { question: "or ```yaml" }],
      askJson,
      200,
    );
    expect(banner).toBe("Use ```json · middle question · or ```yaml");
  });

  it("caps at the limit", () => {
    const many = Array.from({ length: 20 }, (_, i) => ({ question: `Question number ${i}` }));
    expect(Array.from(plainBanner(many, askJson, 100)).length).toBe(100);
  });

  it("cuts on code points, so a cap cannot split an emoji", () => {
    expect(plainBanner([{ question: "\u{1F680}".repeat(200) }], "fallback", 100)).toBe(
      "\u{1F680}".repeat(100),
    );
  });

  it("trims a question that has content and padding", () => {
    expect(plainBanner([{ question: "  Which region?  " }], "fallback", 100)).toBe("Which region?");
  });

  it("collapses newlines so a question cannot break the banner across lines", () => {
    expect(plainBanner([{ question: "Line one\nline two?" }], askJson, 100)).toBe(
      "Line one line two?",
    );
  });
});

// The one test that reads the production banner expression rather than a copy
// of it. Deleting `plainBanner(...)` from the /notify route leaves every other
// test in this file green — measured — so without this the fix is unguarded.
describe("/notify puts the banner it builds into the push", () => {
  afterEach(async () => {
    vi.restoreAllMocks();
    // Storage is not rolled back per test under vitest-pool-workers 0.22, so
    // these outlive the block. Measured: a probe appended below read both back.
    await env.MACHINES.delete("device_token");
    await env.MACHINES.delete("apns_env:abcdef01");
  });

  async function bannerSentFor(body: unknown): Promise<string> {
    // A throwaway P-256 key: `sendPush` signs a JWT before it calls APNs, and
    // that has to succeed for the request we want to inspect to be made.
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
    ])) as CryptoKeyPair;
    const pkcs8 = new Uint8Array(
      (await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer,
    );
    const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
    await env.MACHINES.put("device_token", "abcdef01");

    let sent = "";
    fetched = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (url, init) => {
      const target = url instanceof Request ? url.url : String(url);
      fetched.push(target);
      // Answer the shortener in its own shape. The blanket 200 below reaches
      // it as a JSON parse failure, which `shortenWithLLM` catches and turns
      // into the fallback banner — so without this branch a test cannot tell
      // the two sides of the LLM gate apart.
      if (target.startsWith("https://api.anthropic.com/")) {
        return Response.json({ type: "message", content: [{ type: "text", text: "LLM said this" }] });
      }
      sent = String((init as RequestInit).body);
      return new Response("", { status: 200 });
    });

    const res = await worker.fetch(
      new Request("https://x/notify", {
        method: "POST",
        headers: { ...auth, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      }),
      { ...env, APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_BUNDLE_ID: "B", APNS_AUTH_KEY: pem } as never,
    );
    expect(res.ok, `/notify returned ${res.status}`).toBe(true);
    lastPayload = JSON.parse(sent);
    return lastPayload.aps.alert.body;
  }

  let lastPayload: {
    aps: { alert: { body: string }; category?: string };
    choices?: unknown;
    answerable?: boolean;
  };
  // Every URL the route fetched, in order. The banner branch is the only
  // thing that can put api.anthropic.com in here.
  let fetched: string[] = [];
  const reachedTheLLM = () => fetched.some((u) => u.startsWith("https://api.anthropic.com/"));

  const askJson = '```json\n{\n  "questions" : [\n    { "question" : "Which database?" }\n  ]\n}\n```';

  it("sends the questions for an ask that carries a form", async () => {
    expect(
      await bannerSentFor({
        machine: "m1", sessionId: "s1", title: "Canopy — AskUserQuestion",
        body: askJson, kind: "asking", requestId: "r1", answerable: false,
        choices: [{ question: "Which database?", options: [{ label: "pg" }], multiSelect: false }],
      }),
    ).toBe("Which database?");
  });

  // The whole argument for computing the banner here: `fitPushPayload` drops
  // `choices` when the payload will not fit, so a phone could not rebuild the
  // questions for the largest asks. Breaks if the banner ever moves after the
  // shrink in `index.ts`.
  it("keeps the questions even when the form is dropped to fit APNs", async () => {
    const choices = Array.from({ length: 40 }, (_, i) => ({
      question: `Question ${i}`,
      options: Array.from({ length: 6 }, (_, j) => ({
        label: `Option ${j}`,
        description: "padding".repeat(12),
      })),
      multiSelect: false,
    }));
    const banner = await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy — AskUserQuestion",
      body: askJson, kind: "asking", requestId: "r1", answerable: false, choices,
    });
    expect(banner).toContain("Question 0");
    expect(banner).not.toContain("{");
    expect(lastPayload.choices).toBeUndefined();
  });

  it("ignores choices on a completed push, whatever its length", async () => {
    const choices = [{ question: "Which database?", options: [{ label: "pg" }], multiSelect: false }];
    expect(
      await bannerSentFor({
        machine: "m1", sessionId: "s1", title: "Canopy", body: "All tests passed.",
        kind: "completed", choices,
      }),
    ).toBe("All tests passed.");
    // And the form does not ride along either. The phone's History row
    // previews questions whenever they are present, whatever the kind, so
    // leaving them in the payload puts the same substitution one surface down.
    expect(lastPayload.choices).toBeUndefined();
  });

  // The one line that decides what reaches an LLM at all, and nothing pinned
  // either side of it: flipping `completed` to `asking` there sends an ask's
  // tool input to api.anthropic.com and leaves every other test green.
  it("shortens a long completed push with the LLM", async () => {
    const banner = await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy",
      body: "a detailed completion report. ".repeat(30), kind: "completed",
    });
    expect(reachedTheLLM()).toBe(true);
    expect(banner).toBe("LLM said this");
  });

  // An ask's body is the tool's raw input — a command line, a file path,
  // whatever was pasted into an edit. Length must not change that.
  it("never sends an ask to the LLM, however long its body", async () => {
    await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy — Bash",
      body: "rm -rf /very/long/path ".repeat(30), kind: "asking", requestId: "r1",
    });
    expect(reachedTheLLM()).toBe(false);
  });

  it("leaves a completed push under the cap alone", async () => {
    const banner = await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy", body: "All tests passed.",
      kind: "completed",
    });
    expect(reachedTheLLM()).toBe(false);
    expect(banner).toBe("All tests passed.");
  });

  // `choices` present IS "Allow/Deny cannot resolve this", so the relay
  // derives the pair rather than trusting a client to send both halves. Sent
  // apart, the lock screen offered two buttons that answer an AskUserQuestion
  // by echoing its question back as the tool's input.
  it("treats an ask carrying a form as unanswerable without being told", async () => {
    await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy — AskUserQuestion",
      body: askJson, kind: "asking", requestId: "r1",
      choices: [{ question: "Which database?", options: [{ label: "pg" }], multiSelect: false }],
    });
    expect(lastPayload.aps.category).toBe("CANOPY_SESSION");
    expect(lastPayload.answerable).toBe(false);
  });

  // `allowAlways` is the other door into the permission categories.
  it("keeps a form unanswerable even when the ask proposed a rule", async () => {
    await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy — AskUserQuestion",
      body: askJson, kind: "asking", requestId: "r1", allowAlways: true,
      choices: [{ question: "Which database?", options: [{ label: "pg" }], multiSelect: false }],
    });
    expect(lastPayload.aps.category).toBe("CANOPY_SESSION");
  });

  // The derivation must not swallow the ordinary ask, which is the only thing
  // Allow and Deny exist for.
  it("still offers Allow/Deny for an ask with no form", async () => {
    await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy — Bash",
      body: "rm -rf /tmp/x", kind: "asking", requestId: "r1",
    });
    expect(lastPayload.aps.category).toBe("CANOPY_PERMISSION");
    expect(lastPayload.answerable).toBeUndefined();
  });

  // An AskUserQuestion whose form did not fit the 4 KB budget, or that came
  // from a build predating `choices`. The flag is all there is, and it still
  // has to work on its own.
  it("honours an explicit answerable:false with no form", async () => {
    await bannerSentFor({
      machine: "m1", sessionId: "s1", title: "Canopy — AskUserQuestion",
      body: askJson, kind: "asking", requestId: "r1", answerable: false,
    });
    expect(lastPayload.aps.category).toBe("CANOPY_SESSION");
    expect(lastPayload.answerable).toBe(false);
  });

  it("sends the relay's own banner for an ask with no form", async () => {
    expect(
      await bannerSentFor({
        machine: "m1", sessionId: "s1", title: "Canopy — Bash",
        body: "rm -rf build", kind: "asking", requestId: "r1",
      }),
    ).toBe("rm -rf build");
  });
});

describe("session images", () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const put = (query: string, body: BodyInit = png, headers: HeadersInit = auth) =>
    SELF.fetch(`https://relay/image?${query}`, { method: "PUT", body, headers });

  it("round-trips a variant and keeps its content type", async () => {
    const res = await put("machine=M1&session=s1&event=e1&variant=full", png, {
      ...auth,
      "Content-Type": "image/png",
    });
    expect(res.status).toBe(200);
    const got = await SELF.fetch(
      "https://relay/image?machine=M1&session=s1&event=e1&variant=full",
      { headers: auth },
    );
    expect(got.status).toBe(200);
    expect(got.headers.get("Content-Type")).toBe("image/png");
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(png);
  });

  // full と thumb は別のオブジェクト。同じ event の下で衝突しない。
  it("keeps full and thumb apart", async () => {
    const thumb = new Uint8Array([0xff, 0xd8, 0xff]);
    await put("machine=M2&session=s1&event=e1&variant=full", png);
    await put("machine=M2&session=s1&event=e1&variant=thumb", thumb);
    const got = await SELF.fetch(
      "https://relay/image?machine=M2&session=s1&event=e1&variant=thumb",
      { headers: auth },
    );
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(thumb);
  });

  // 別の Mac が同じ session/event 名を使っても混ざらない。seq と違い
  // eventId は UUID なので実際には衝突しないが、キーの機械スコープが
  // 消えたことに気づく手段がこれしかない。
  it("scopes the key by machine", async () => {
    await put("machine=A&session=s1&event=e1&variant=full", png);
    const other = await SELF.fetch(
      "https://relay/image?machine=B&session=s1&event=e1&variant=full",
      { headers: auth },
    );
    expect(other.status).toBe(404);
  });

  it("404s a variant that was never uploaded", async () => {
    const res = await SELF.fetch(
      "https://relay/image?machine=M3&session=s1&event=nope&variant=full",
      { headers: auth },
    );
    expect(res.status).toBe(404);
  });

  it("refuses an unknown variant", async () => {
    const res = await put("machine=M4&session=s1&event=e1&variant=original");
    expect(res.status).toBe(400);
  });

  it("refuses a request missing an id", async () => {
    const res = await put("machine=M5&session=s1&variant=full");
    expect(res.status).toBe(400);
  });

  // 認証は両方向に効く。GET だけ素通しだと、画像は URL を知る誰でも
  // 読めることになる。
  it("refuses an unauthenticated upload", async () => {
    const res = await put("machine=M6&session=s1&event=e1&variant=full", png, {});
    expect(res.status).toBe(401);
  });

  it("refuses an unauthenticated read", async () => {
    const res = await SELF.fetch(
      "https://relay/image?machine=M6&session=s1&event=e1&variant=full",
    );
    expect(res.status).toBe(401);
  });

  it("refuses an upload over the size cap", async () => {
    const big = new Uint8Array(13 * 1024 * 1024);
    const res = await put("machine=M7&session=s1&event=e1&variant=full", big);
    expect(res.status).toBe(413);
  });
});
