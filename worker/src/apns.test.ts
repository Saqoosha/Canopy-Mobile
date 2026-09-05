// worker/src/apns.test.ts
//
// `sendPush` takes its APNs credentials as a PARAMETER, which is what makes
// these tests safe and portable: the env below is synthetic and its signing
// key is generated here, so nothing reads `.dev.vars` (loaded into the test
// pool, and holding the REAL key) and nothing depends on a secret CI does not
// have. `fetch` is stubbed for the same reason — an un-intercepted call would
// reach Apple with a live key.
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { sendPush, type ApnsEnv } from "./apns";

const TOKEN = "a".repeat(64);

/// A fresh P-256 key in the PEM-less base64 PKCS8 shape `importAPNsKey`
/// accepts. Generated per run: this must sign, but it never authenticates
/// anything, since no request leaves the test.
async function syntheticEnv(): Promise<ApnsEnv> {
  // Both casts are the Workers typings being wider than this call: an ECDSA
  // `generateKey` is declared `CryptoKey | CryptoKeyPair`, and `exportKey`
  // `ArrayBuffer | JsonWebKey`, because each covers every algorithm and
  // format. Only the pkcs8/keypair arms are reachable here.
  const pair = (await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const pkcs8 = (await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer;
  const bytes = new Uint8Array(pkcs8);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return {
    APNS_KEY_ID: "TESTKEYID1",
    APNS_TEAM_ID: "TESTTEAMID",
    APNS_BUNDLE_ID: "sh.saqoo.canopy-app.test",
    APNS_AUTH_KEY: btoa(binary),
    // Unread on this path: every test pins the environment explicitly, so the
    // token-environment auto-detect (the only KV reader) never runs.
    MACHINES: undefined as unknown as KVNamespace,
  };
}

/// Answers each call with the next status in the list, and records how many
/// calls happened — the count is the assertion that matters here, since "did
/// it retry" is not visible in the returned response alone.
function stubApns(statuses: number[]): { calls: () => number } {
  let call = 0;
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      const status = statuses[call] ?? 599;
      call += 1;
      return new Response(JSON.stringify({ reason: "TooManyRequests" }), { status });
    }),
  );
  return { calls: () => call };
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

/// Runs `sendPush` while advancing the throttle delay, so a retrying test
/// does not wait a real second. `runAllTimersAsync` has to be raced against
/// the call rather than awaited after it: the promise cannot settle until the
/// timer fires, so awaiting it first would deadlock.
async function push(env: ApnsEnv): Promise<Response> {
  const inFlight = sendPush(env, TOKEN, { aps: { alert: "hi" } }, false);
  await vi.runAllTimersAsync();
  return inFlight;
}

describe("APNs throttling", () => {
  it("retries once when APNs answers 429, and returns the retry's success", async () => {
    const seen = stubApns([429, 200]);
    const res = await push(await syntheticEnv());
    expect(res.status).toBe(200);
    expect(seen.calls()).toBe(2);
  });

  it("returns the second rejection when the retry is throttled too", async () => {
    const seen = stubApns([429, 429]);
    const res = await push(await syntheticEnv());
    expect(res.status).toBe(429);
    // Exactly two: one retry, never a ladder. A persistent throttle must cost
    // one extra request, not a storm.
    expect(seen.calls()).toBe(2);
  });

  it("does not retry a rejection that is not a throttle", async () => {
    const seen = stubApns([410, 200]);
    const res = await push(await syntheticEnv());
    expect(res.status).toBe(410);
    expect(seen.calls()).toBe(1);
  });

  it("does not retry a success", async () => {
    const seen = stubApns([200, 200]);
    const res = await push(await syntheticEnv());
    expect(res.status).toBe(200);
    expect(seen.calls()).toBe(1);
  });
});
