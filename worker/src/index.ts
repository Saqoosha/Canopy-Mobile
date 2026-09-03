import { MachineDO } from "./machine";
export { MachineDO };

interface Env {
  MACHINE: DurableObjectNamespace;
  MACHINES: KVNamespace;
  SHARED_SECRET: string;
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
    return new Response("not found", { status: 404 });
  },
};
