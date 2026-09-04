import { MachineDO } from "./machine";
import { sendPush, type ApnsEnv } from "./apns";
import type { NotifyBody, ReplyBody } from "./types";
export { MachineDO };

interface Env extends ApnsEnv {
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
      const deviceToken = await env.MACHINES.get("device_token");
      if (!deviceToken) return json({ error: "no device registered" }, 503);
      // 3000 chars keeps the whole APNs payload under the 4 KB limit, matching
      // Pager's own cap. The routing fields ride in the payload rather than in
      // KV because they are two short ids, not a conversation.
      const MAX = 3000;
      const text = body.body.length > MAX ? body.body.slice(0, MAX) + "…" : body.body;
      const payload = {
        aps: {
          alert: { title: body.title, body: text },
          sound: "default",
          "mutable-content": 1,
          category: "CANOPY_SESSION",
        },
        machine: body.machine,
        sessionId: body.sessionId,
        kind: body.kind,
      };
      return sendPush(env, deviceToken, payload);
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
    return new Response("not found", { status: 404 });
  },
};
