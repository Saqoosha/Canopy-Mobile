// worker/src/machine.test.ts
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import type { MachineSnapshot } from "./types";
import type { MachineDO } from "./machine";

const snapshot: MachineSnapshot = {
  machineId: "AAAA-1111",
  displayName: "Mac Studio",
  publishedAt: 1_700_000_000,
  sessionPct: 43,
  weeklyPct: 25,
  panes: [
    {
      sessionId: "s1", paneIndex: 0, title: "Canopy Mobile",
      project: "Canopy · main", state: "asking", stateSince: 1_699_999_000,
      contextPct: 17, model: "opus", messageCount: 42,
    },
  ],
};

describe("MachineDO", () => {
  it("stores a published snapshot and reads it back", async () => {
    const id = env.MACHINE.idFromName("mac:AAAA-1111");
    const stub = env.MACHINE.get(id);
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.applySnapshot(snapshot);
      expect(instance.currentSnapshot()?.displayName).toBe("Mac Studio");
      expect(instance.currentSnapshot()?.panes[0].state).toBe("asking");
    });
  });

  it("survives losing its in-memory state", async () => {
    const id = env.MACHINE.idFromName("mac:BBBB-2222");
    const stub = env.MACHINE.get(id);
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.applySnapshot({ ...snapshot, machineId: "BBBB-2222" });
    });
    // A fresh instance handle reads from SQLite, not from memory.
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.forgetInMemoryState();
      expect(instance.currentSnapshot()?.machineId).toBe("BBBB-2222");
    });
  });

  it("serves a stored snapshot over HTTP", async () => {
    const id = env.MACHINE.idFromName("mac:CCCC-3333");
    const stub = env.MACHINE.get(id);
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.applySnapshot({ ...snapshot, machineId: "CCCC-3333" });
    });
    const res = await stub.fetch("https://do/roster");
    expect(res.status).toBe(200);
    const body = (await res.json()) as MachineSnapshot;
    expect(body.machineId).toBe("CCCC-3333");
  });

  it("returns 404 for a Mac that has never published", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:NEVER"));
    const res = await stub.fetch("https://do/roster");
    expect(res.status).toBe(404);
  });

  it("forwards a publisher's snapshot to a watcher, but never echoes it back to the publisher", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:DDDD-4444"));

    const watcherUpgrade = await stub.fetch("https://do/watch", {
      headers: { Upgrade: "websocket" },
    });
    const watcherWs = watcherUpgrade.webSocket!;
    watcherWs.accept();
    const watcherReceived = new Promise<string>((resolve) => {
      watcherWs.addEventListener("message", (e) => resolve(e.data as string));
    });

    // A second socket on the same DO, opened via /publish so it carries the
    // "publisher" role tag `broadcast()` is supposed to skip. If the role
    // filter is ever dropped, this socket receives the echo the whole task
    // exists to prevent — recorded here rather than awaited, since a
    // publisher that (correctly) receives nothing would otherwise hang the
    // test on an unresolved promise.
    const publisherUpgrade = await stub.fetch("https://do/publish", {
      headers: { Upgrade: "websocket" },
    });
    const publisherWs = publisherUpgrade.webSocket!;
    publisherWs.accept();
    const publisherMessages: string[] = [];
    publisherWs.addEventListener("message", (e) => {
      publisherMessages.push(e.data as string);
    });

    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.applySnapshot({ ...snapshot, machineId: "DDDD-4444" });
      instance.broadcast();
    });

    const body = JSON.parse(await watcherReceived) as MachineSnapshot;
    expect(body.machineId).toBe("DDDD-4444");

    // Give a wrongly-sent publisher echo a chance to arrive before asserting
    // its absence — the watcher's message and any (incorrect) publisher
    // message are dispatched from the same synchronous broadcast() loop.
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(publisherMessages).toEqual([]);
  });
});
