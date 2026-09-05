import { MachineDO } from "./machine";
import { sendPush, type ApnsEnv } from "./apns";
import { shortenWithLLM, fallbackBanner, safeSlice, type LlmEnv } from "./llm";
import type { DecisionBody, NotifyBody, ReplyBody } from "./types";
export { MachineDO };

interface Env extends ApnsEnv, LlmEnv {
  MACHINE: DurableObjectNamespace;
  MACHINES: KVNamespace;
  SHARED_SECRET: string;
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function authorized(request: Request, env: Env): boolean {
  return request.headers.get("Authorization") === `Bearer ${env.SHARED_SECRET}`;
}

/** APNs rejects a payload over 4 KB outright, and the push is the only place
 *  the whole notification exists — Canopy caps its own text in bytes, but it
 *  cannot see the title, the ids, the category or the form that ride with it.
 *
 *  Two stages, and the ORDER is the decision. `bodyFull` shrinks first,
 *  because it is context. `choices` is dropped only when the body is already
 *  exhausted and the payload is still over, because those are the buttons —
 *  an ask the phone cannot answer is exactly the state this field was added
 *  to end, so it is the last thing to go, not the first.
 *
 *  Without the second stage the loop simply exits with an oversized payload
 *  and APNs drops it: no notification, and silence on both ends. */
export function fitPushPayload<T extends { bodyFull: string; choices?: unknown }>(
  payload: T,
  limit = 4096,
): T {
  const encodedLength = (value: unknown) =>
    new TextEncoder().encode(JSON.stringify(value)).length;
  let shrunk = payload;
  while (encodedLength(shrunk) > limit && shrunk.bodyFull.length > 0) {
    const over = encodedLength(shrunk) - limit;
    // Cut at least one character, and roughly the overshoot, so a body of
    // multibyte text converges in a few passes instead of one per byte.
    const drop = Math.max(1, Math.ceil(over / 3));
    // Code points, so the shrink cannot end mid-pair either.
    const points = Array.from(shrunk.bodyFull);
    shrunk = {
      ...shrunk,
      bodyFull: safeSlice(shrunk.bodyFull, Math.max(0, points.length - drop)),
    };
  }
  if (shrunk.choices !== undefined && encodedLength(shrunk) > limit) {
    console.warn("notify: dropping choices to fit the APNs limit");
    const { choices: _dropped, ...withoutChoices } = shrunk;
    shrunk = withoutChoices as T;
  }
  return shrunk;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    // A missing/empty SHARED_SECRET makes `Bearer ${env.SHARED_SECRET}`
    // compare against the literal "Bearer undefined" (or "Bearer "), which a
    // deployed-but-unconfigured worker would then accept from anyone. Fail
    // closed instead of silently serving every request as authorized.
    if (!env.SHARED_SECRET) {
      console.error("relay misconfigured: SHARED_SECRET binding is missing or empty");
      return new Response(JSON.stringify({ error: "relay misconfigured: SHARED_SECRET not set" }), {
        status: 503,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (!authorized(request, env)) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.pathname === "/publish") {
      const machine = url.searchParams.get("machine");
      if (!machine) return new Response("machine required", { status: 400 });
      await env.MACHINES.put(`machine:${machine}`, "1");
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${machine}`));
      return stub.fetch(request);
    }
    if (url.pathname === "/roster") {
      const machine = url.searchParams.get("machine");
      if (!machine) return new Response("machine required", { status: 400 });
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${machine}`));
      return stub.fetch(new Request("https://do/roster"));
    }
    if (url.pathname === "/watch") {
      const machine = url.searchParams.get("machine");
      if (!machine) return new Response("machine required", { status: 400 });
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${machine}`));
      return stub.fetch(request);
    }
    if (url.pathname === "/machines") {
      const listed = await env.MACHINES.list({ prefix: "machine:" });
      const ids = listed.keys.map((k) => k.name.slice("machine:".length));
      return new Response(JSON.stringify(ids), {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.pathname === "/register" && request.method === "POST") {
      const body = await request.json<{ token?: string }>().catch(() => null);
      if (!body?.token) return json({ error: "token required" }, 400);
      // APNs tokens are lowercase hex; length varies by device and OS, so the
      // shape is checked and the length deliberately is not.
      if (!/^[0-9a-f]+$/.test(body.token)) return json({ error: "invalid token format" }, 400);
      await env.MACHINES.put("device_token", body.token);
      return json({ ok: true });
    }
    if (url.pathname === "/notify" && request.method === "POST") {
      const body = await request.json<NotifyBody>().catch(() => null);
      if (!body?.machine || !body.sessionId) return json({ error: "machine and sessionId required" }, 400);
      if (body.kind !== "completed" && body.kind !== "asking") {
        return json({ error: "kind must be completed or asking" }, 400);
      }
      // A decision needs something to answer, and a completion has nothing to
      // answer — the phone's Allow/Deny actions are meaningless without an id
      // to send them back with, and attaching one to a completed push would
      // let a stale action fire against a session that already moved on.
      if (body.kind === "asking" && !body.requestId) return json({ error: "asking requires requestId" }, 400);
      if (body.kind === "completed" && body.requestId) return json({ error: "completed takes no requestId" }, 400);
      // Validated because the two reads below are `.length` — without this a
      // caller omitting both fields got an opaque 500 from a TypeError rather
      // than being told what was missing.
      if (typeof body.body !== "string" && typeof body.bodyFull !== "string") {
        return json({ error: "body or bodyFull required" }, 400);
      }
      const deviceToken = await env.MACHINES.get("device_token");
      if (!deviceToken) return json({ error: "no device registered" }, 503);
      // `bodyFull` is the new, optional carrier for the untouched text; `body`
      // stays required so older callers keep working during rollout.
      const fullText = body.bodyFull ?? body.body;
      // A coarse pre-cap, measured in CODE POINTS. It does not by itself keep
      // the payload under APNs's 4 KB — 3000 emoji are 12 KB — and it never
      // did; what guarantees the limit is the byte-accurate shrink below,
      // which measures the encoded payload whole. This exists so the common
      // case never reaches that loop, and so `bodyFull` cannot be unbounded.
      const MAX = 3000;
      // `safeSlice`, never `.slice`: cutting between a surrogate pair's
      // halves leaves a replacement glyph at the end of the body.
      const bodyFullCapped =
        Array.from(fullText).length > MAX ? safeSlice(fullText, MAX) + "…" : fullText;
      // The banner is a display shortcut, not the payload's source of truth —
      // `bodyFull` above carries the real text. A slow LLM call must never
      // delay the push, which is why shortenWithLLM has its own timeout.
      const BANNER_MAX = 100;
      // Summarise a COMPLETED push only. An asking push's body is the tool's
      // raw input — a command line, a file path, whatever was pasted into an
      // edit — and sending that to api.anthropic.com is a data flow the design
      // doc argues nowhere; it was inherited by the banner path rather than
      // chosen. Truncation loses nothing here either, since the full text is
      // in `bodyFull` and a JSON blob summarises badly.
      const banner =
        body.kind === "completed" && fullText.length > BANNER_MAX
          ? await shortenWithLLM(env, fullText, BANNER_MAX)
          : fallbackBanner(fullText, BANNER_MAX);
      const payload = {
        aps: {
          alert: { title: body.title, body: banner },
          sound: "default",
          "mutable-content": 1,
          // Only an asking push gets Allow/Deny actions; a completed push has
          // nothing for them to act on.
          // iOS resolves a notification's actions from its category alone, so
          // "offer Always only when the CLI proposed a rule" has to be a
          // second category rather than a flag the app reads at render time.
          // An unanswerable ask gets the plain category: two lock-screen
          // buttons that cannot resolve it are worse than none.
          category:
            body.kind === "asking" && body.answerable !== false
              ? body.allowAlways
                ? "CANOPY_PERMISSION_ALWAYS"
                : "CANOPY_PERMISSION"
              : "CANOPY_SESSION",
        },
        machine: body.machine,
        sessionId: body.sessionId,
        kind: body.kind,
        bodyFull: bodyFullCapped,
        // Groups this notification with the session's others across a Canopy
        // restart, which mints a new sessionId and would otherwise orphan
        // everything stored so far.
        ...(body.resumeId ? { resumeId: body.resumeId } : {}),
        ...(body.requestId ? { requestId: body.requestId } : {}),
        // Only true when the CLI proposed a rule for this ask. The phone
        // offers "Always" on this alone: a button that quietly degraded to a
        // plain Allow would tell the user they had made a standing decision
        // they had not.
        ...(body.allowAlways ? { allowAlways: true } : {}),
        ...(body.answerable === false ? { answerable: false } : {}),
        // Only for an ask that Allow/Deny cannot resolve. The phone draws its
        // buttons from these; without them it rendered the tool input as raw
        // JSON with a plain text field under it — legible and unanswerable.
        ...(body.choices?.length ? { choices: body.choices } : {}),
      };
      // APNs rejects a payload over 4 KB outright, and this is the only
      // place the whole thing exists — Canopy caps its own text in bytes, but
      // it cannot see the title, the ids or the category that ride with it.
      // Shrink `bodyFull` until the encoded payload fits rather than trusting
      // an upstream guess; a dropped notification is silent on both ends.
      return sendPush(env, deviceToken, fitPushPayload(payload));
    }
    if (url.pathname === "/reply" && request.method === "POST") {
      const body = await request.json<ReplyBody>().catch(() => null);
      if (!body?.machine || !body.sessionId) return json({ error: "machine and sessionId required" }, 400);
      const text = (body.text ?? "").trim();
      // An empty reply would inject a blank user turn into a real conversation
      // and permanently into its transcript. Refuse rather than normalize.
      if (!text) return json({ error: "text required" }, 400);
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${body.machine}`));
      return stub.fetch(
        new Request("https://do/reply", {
          method: "POST",
          body: JSON.stringify({ type: "reply", sessionId: body.sessionId, text }),
        })
      );
    }
    if (url.pathname === "/decide" && request.method === "POST") {
      const body = await request.json<DecisionBody>().catch(() => null);
      // requestId is the only thing tying this decision to the request it
      // answers, minted per process — never defaulted to whatever is
      // outstanding, which could approve a tool the user never saw.
      if (!body?.machine || !body.sessionId || !body.requestId) {
        return json({ error: "machine, sessionId, and requestId required" }, 400);
      }
      // Legal values captured from three real clicks (see
      // docs/superpowers/specs/2026-09-04-permission-response-capture.md).
      // An unrecognized value is refused, not normalized — approving a tool
      // because a value failed to parse is the worst outcome this route can
      // produce.
      if (
        body.decision !== "allow" &&
        body.decision !== "deny" &&
        body.decision !== "allowAlways"
      ) {
        return json({ error: "decision must be allow, deny, or allowAlways" }, 400);
      }
      // Shape only — the relay cannot know which questions were asked. A
      // malformed map would be refused by the Mac anyway; refusing it here
      // costs nothing and keeps a garbage payload off the publisher socket.
      if (
        body.answers !== undefined &&
        (typeof body.answers !== "object" ||
          body.answers === null ||
          Array.isArray(body.answers) ||
          Object.values(body.answers).some((v) => typeof v !== "string"))
      ) {
        return json({ error: "answers must be an object of strings" }, 400);
      }
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${body.machine}`));
      return stub.fetch(
        new Request("https://do/decide", {
          method: "POST",
          body: JSON.stringify({
            type: "decision",
            sessionId: body.sessionId,
            requestId: body.requestId,
            decision: body.decision,
            // Passed through untouched; only the Mac holds the form to
            // validate the labels against, and it refuses anything that does
            // not resolve the question it actually asked.
            ...(body.answers ? { answers: body.answers } : {}),
          }),
        })
      );
    }
    return new Response("not found", { status: 404 });
  },
};
