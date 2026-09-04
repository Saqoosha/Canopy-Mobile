// Copied from Pager's worker/src/index.ts (sendPush and its helpers), not
// imported: the two Workers diverge by design — this one grows a DO, a
// roster and a WebSocket, that one stays a notification relay — and an
// APNs auth key is team-wide, so the credential is shared while the code
// is not. The accepted cost is that these two copies will drift; diff them
// against Pager before changing anything about JWT signing or the retry.

export interface ApnsEnv {
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  APNS_AUTH_KEY: string;
  APNS_USE_SANDBOX?: string;
  MACHINES: KVNamespace; // reused for the sandbox-environment cache
}

// --- APNs JWT ---

function base64url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlString(str: string): string {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importAPNsKey(pem: string): Promise<CryptoKey> {
  const lines = pem.split("\n").filter((l) => !l.startsWith("-----") && l.trim());
  const raw = Uint8Array.from(atob(lines.join("")), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

async function generateAPNsJWT(env: ApnsEnv): Promise<string> {
  const header = base64urlString(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const now = Math.floor(Date.now() / 1000);
  const claims = base64urlString(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const unsigned = `${header}.${claims}`;
  const key = await importAPNsKey(env.APNS_AUTH_KEY);
  // Web Crypto ECDSA returns raw r||s format directly (no DER-to-raw conversion needed)
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64url(signature)}`;
}

async function sendPushDirect(
  env: ApnsEnv,
  deviceToken: string,
  payload: object,
  sandbox: boolean,
): Promise<Response> {
  const jwt = await generateAPNsJWT(env);
  const apnsHost = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return fetch(`https://${apnsHost}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

// Token-to-environment cache lives in KV so the worker doesn't re-probe APNs
// every push. Both reads and writes are best-effort: a stale, missing, or
// unreachable cache only costs one extra round-trip via the BadDeviceToken
// retry path, so KV failures must never break the push itself.
//
// Shares the MACHINES namespace with the roster (`machine:<id>`) and the
// registered device token (`device_token`); this prefix keeps the cache
// entries distinct from both.
function apnsEnvCacheKey(deviceToken: string): string {
  return `apns_env:${deviceToken}`;
}

// Don't echo full device tokens into log lines — they're not PII in the strict
// sense, but logging the full token everywhere makes targeted-push abuse easier
// if Cloudflare logs ever leak.
function maskDeviceToken(deviceToken: string): string {
  return deviceToken.length <= 8 ? deviceToken : `${deviceToken.slice(0, 8)}…`;
}

// Devices typically only rotate their APNs token on reinstall, but a token
// that never receives another push would otherwise stay in KV forever. Expire
// the cache entry after 30 days so dormant tokens get garbage-collected.
const APNS_ENV_CACHE_TTL_SECONDS = 60 * 60 * 24 * 30;

// 400 reasons that mean "the token is for the other APNs environment". The
// canonical one is `BadDeviceToken`; `DeviceTokenNotForTopic` is also observed
// in env-mismatch cases on some APNs configurations, so include it too. Other
// 400 reasons (e.g. `MissingDeviceToken`, `BadCertificate`) are NOT environment
// problems and must not trigger the auto-detect flip.
const RETRYABLE_400_REASONS: ReadonlySet<string> = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
]);

async function readCachedApnsEnv(env: ApnsEnv, deviceToken: string): Promise<boolean | null> {
  try {
    const cached = await env.MACHINES.get(apnsEnvCacheKey(deviceToken));
    if (cached === "sandbox") return true;
    if (cached === "production") return false;
    return null;
  } catch (e) {
    // Treat the cache as a miss on read failure. Auto-detect will pick the
    // seed env and the BadDeviceToken retry path still produces the correct
    // result — just one extra round-trip for this push.
    const err = e instanceof Error ? e : new Error(String(e));
    console.error("APNs env cache read failed", {
      name: err.name,
      message: err.message,
      stack: err.stack,
      deviceToken: maskDeviceToken(deviceToken),
    });
    return null;
  }
}

async function writeCachedApnsEnv(env: ApnsEnv, deviceToken: string, sandbox: boolean): Promise<void> {
  try {
    await env.MACHINES.put(
      apnsEnvCacheKey(deviceToken),
      sandbox ? "sandbox" : "production",
      { expirationTtl: APNS_ENV_CACHE_TTL_SECONDS },
    );
  } catch (e) {
    const err = e instanceof Error ? e : new Error(String(e));
    console.error("APNs env cache write failed", {
      name: err.name,
      message: err.message,
      stack: err.stack,
      deviceToken: maskDeviceToken(deviceToken),
      sandbox,
    });
  }
}

/**
 * Send a push, auto-detecting APNs sandbox vs production when `useSandbox` is
 * not supplied. The first attempt uses the per-token cached environment (or
 * `APNS_USE_SANDBOX` as the seed when nothing is cached). On a 400 whose
 * `reason` is in `RETRYABLE_400_REASONS` — the APNs "wrong environment"
 * signals — we retry against the opposite host and update the cache.
 *
 * If the caller passes `useSandbox` explicitly, that value is honored as-is
 * with no retry (preserves legacy /notify and /request behaviour where the
 * hook already knows which environment to target).
 */
export async function sendPush(
  env: ApnsEnv,
  deviceToken: string,
  payload: object,
  useSandbox?: boolean,
): Promise<Response> {
  // typeof check (rather than `!== undefined`) so a JSON `null` from a
  // misconfigured client falls through to auto-detect instead of being treated
  // as "production".
  if (typeof useSandbox === "boolean") {
    return sendPushDirect(env, deviceToken, payload, useSandbox);
  }

  const cached = await readCachedApnsEnv(env, deviceToken);
  const firstTrySandbox = cached ?? (env.APNS_USE_SANDBOX === "true");

  const first = await sendPushDirect(env, deviceToken, payload, firstTrySandbox);
  if (first.ok) {
    if (cached !== firstTrySandbox) {
      await writeCachedApnsEnv(env, deviceToken, firstTrySandbox);
    }
    return first;
  }

  if (first.status === 400) {
    // Peek at the response body to see if APNs flagged the wrong environment.
    // Use `.clone()` so the original response body stays readable by the caller.
    let reason: string | undefined;
    let parseError: Error | undefined;
    try {
      const parsed = (await first.clone().json()) as { reason?: string };
      reason = parsed.reason;
    } catch (e) {
      parseError = e instanceof Error ? e : new Error(String(e));
    }
    if (reason && RETRYABLE_400_REASONS.has(reason)) {
      const retry = await sendPushDirect(env, deviceToken, payload, !firstTrySandbox);
      if (retry.ok) {
        await writeCachedApnsEnv(env, deviceToken, !firstTrySandbox);
        return retry;
      }
      // Both environments rejected this token. Log enough to distinguish
      // "really dead token" from "auto-detect bug" without leaking the
      // full token value into logs.
      let retryReason: string | undefined;
      try {
        retryReason = ((await retry.clone().json()) as { reason?: string }).reason;
      } catch {
        // Non-JSON retry body — leave retryReason undefined.
      }
      console.error("APNs auto-detect: both environments rejected token", {
        deviceToken: maskDeviceToken(deviceToken),
        firstTrySandbox,
        firstStatus: first.status,
        firstReason: reason,
        retryStatus: retry.status,
        retryReason,
      });
      return retry;
    }
    // 400 that we deliberately won't retry. Log so operators can spot APNs
    // returning malformed 400s or unexpected reasons (e.g. a new env-mismatch
    // code we don't yet recognise).
    console.warn("APNs 400 not retried", {
      deviceToken: maskDeviceToken(deviceToken),
      reason: reason ?? "<unparseable>",
      parseError: parseError ? `${parseError.name}: ${parseError.message}` : undefined,
    });
  }

  return first;
}
