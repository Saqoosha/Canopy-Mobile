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
});
