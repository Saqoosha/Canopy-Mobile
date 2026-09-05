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

  // Every test below drives the real POST /reply route rather than calling
  // `deliverAndAwaitAck` directly, because the thing worth pinning is the
  // status code the PHONE sees: 200 acted on it, 409 got there and could not
  // be used, 503 never got there or never answered. A test against the
  // internal return shape would pass while `respondToDelivery` mapped it to
  // the wrong one.
  //
  // `machineId` differs per test on purpose — the DO is addressed by name, so
  // two tests sharing one would share its sockets.
  describe("delivery acknowledgement", () => {
    /** Opens a publisher socket that answers every delivery it receives with
     *  the given verdict, and records the deliveries it saw.
     *
     *  `answer: null` makes it deliberately silent — a Canopy that received
     *  the delivery and never came back, which is a different outcome from
     *  one that rejected it. */
    async function publisher(
      stub: DurableObjectStub<MachineDO>,
      answer: { ok: boolean; reason?: string } | null,
      /** Milliseconds to wait before acking. **Load-bearing, not a hack.**
       *  Every publisher receives a delivery from the same synchronous send
       *  loop, so with all of them answering immediately the arrival order is
       *  whatever the runtime happens to do. A test for "a rejection must not
       *  beat a success" that does not FORCE the rejection to arrive first
       *  measures nothing: measured here, the first version passed against
       *  the first-ack-wins bug it was written for. */
      delayMs = 0,
    ): Promise<{ seen: string[] }> {
      const upgrade = await stub.fetch("https://do/publish", { headers: { Upgrade: "websocket" } });
      const ws = upgrade.webSocket!;
      ws.accept();
      const seen: string[] = [];
      ws.addEventListener("message", (e) => {
        const envelope = JSON.parse(e.data as string) as { deliveryId?: string };
        if (!envelope.deliveryId) return;
        seen.push(envelope.deliveryId);
        if (!answer) return;
        const send = () =>
          ws.send(JSON.stringify({ type: "ack", deliveryId: envelope.deliveryId, ...answer }));
        if (delayMs > 0) setTimeout(send, delayMs);
        else send();
      });
      return { seen };
    }

    function reply(stub: DurableObjectStub<MachineDO>): Promise<Response> {
      return stub.fetch("https://do/reply", {
        method: "POST",
        body: JSON.stringify({ type: "reply", sessionId: "s1", text: "hi" }),
      });
    }

    // **The bug this whole block exists for.** One Mac runs more than one
    // Canopy — a Debug build and the installed Release share a machine id, and
    // a reconnect overlaps two sockets — so a delivery reaches several
    // publishers and only one owns the session. The others answer "no open
    // session matches" immediately, and first-ack-wins reported that rejection
    // as the verdict for a reply that HAD been injected. Found by review, not
    // by any test here; this is the test that was missing.
    it("does not let one Canopy's rejection mask another's success", async () => {
      const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ACK-1"));
      // The rejecter answers immediately, the owner 50 ms later. Without the
      // delay this passed against the bug — see the note on `publisher`.
      await publisher(stub, { ok: false, reason: "no open session matches" });
      await publisher(stub, { ok: true }, 50);
      const response = await reply(stub);
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ ok: true });
    });

    // The order the rejection and the success arrive in must not matter. With
    // the fix, a success settles the wait wherever it lands; without it, this
    // case passed by luck while the one above failed.
    it("accepts a success that arrives after every other Canopy has rejected", async () => {
      const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ACK-2"));
      await publisher(stub, { ok: false, reason: "no open session matches" });
      await publisher(stub, { ok: false, reason: "no open session matches" });
      await publisher(stub, { ok: true }, 50);
      const response = await reply(stub);
      expect(response.status).toBe(200);
    });

    it("reports a rejection once every Canopy has rejected, in its own words", async () => {
      const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ACK-3"));
      await publisher(stub, { ok: false, reason: "no open session matches" });
      await publisher(stub, { ok: false, reason: "no open session matches" });
      const response = await reply(stub);
      expect(response.status).toBe(409);
      expect(await response.json()).toMatchObject({ ok: false, reason: "no open session matches" });
    });

    it("reports 503 when no Mac is connected at all", async () => {
      const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ACK-4"));
      const response = await reply(stub);
      expect(response.status).toBe(503);
    });

    it("delivers to every connected publisher, not just the first", async () => {
      const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ACK-5"));
      const a = await publisher(stub, { ok: true });
      const b = await publisher(stub, { ok: false });
      await reply(stub);
      // Both saw it. A delivery that reached only one socket would make the
      // aggregation above vacuous — it would have nothing to aggregate.
      expect(a.seen.length).toBe(1);
      expect(b.seen.length).toBe(1);
      expect(a.seen[0]).toBe(b.seen[0]);
    });

    // **A socket that was never a recipient must not be able to answer.**
    // The delivery is written only to publisher sockets, so a WATCHER — the
    // phone's own roster socket, which holds the same shared Bearer secret —
    // receives nothing and knows nothing. Handed an in-flight deliveryId
    // anyway (strictly more than an attacker has), its `ok: true` must settle
    // nothing.
    //
    // This is the test the first version of this block did not have. It used
    // an id that was never in flight, so it stopped at the map lookup and
    // never reached the recipient check — measured: deleting that check left
    // the whole suite green.
    it("refuses an ack from a socket the delivery was never written to", async () => {
      const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ACK-6"));
      // The only real recipient, and deliberately silent.
      const owner = await publisher(stub, null);

      const watcherUpgrade = await stub.fetch("https://do/watch", { headers: { Upgrade: "websocket" } });
      const watcher = watcherUpgrade.webSocket!;
      watcher.accept();

      const pending = reply(stub);
      // Wait for the real delivery to reach the owner so its id is known,
      // then forge a success from the watcher.
      await new Promise((resolve) => setTimeout(resolve, 100));
      expect(owner.seen.length).toBe(1);
      watcher.send(JSON.stringify({ type: "ack", deliveryId: owner.seen[0], ok: true }));

      // 503, not 200: the only socket that could answer never did.
      const response = await pending;
      expect(response.status).toBe(503);
    }, 10_000);

    // The subtlest decision in the fix: with one recipient still silent we do
    // not know whether it acted, so a rejection from the others is NOT the
    // answer. Borrowing it would assert `delivered: true` — 409, "it got
    // there and could not be used" — about a delivery that may well have
    // succeeded on the silent Mac.
    it("stays unconfirmed rather than borrowing a rejection while a Canopy is silent", async () => {
      const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ACK-7"));
      await publisher(stub, { ok: false, reason: "no open session matches" });
      await publisher(stub, null);
      const response = await reply(stub);
      expect(response.status).toBe(503);
      expect(await response.json()).toMatchObject({ ok: false, reason: "the Mac did not answer" });
    }, 10_000);
  });
});
