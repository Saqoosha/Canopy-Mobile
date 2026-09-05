// worker/src/machine.test.ts
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import type { MachineSnapshot, SessionEventMessage } from "./types";
import { MachineDO } from "./machine";

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

function ev(sessionId: string, text: string): SessionEventMessage {
  return {
    type: "event",
    eventId: `${sessionId}-${text}`,
    sessionId,
    resumeId: null,
    kind: "assistant",
    text,
    at: 0,
  };
}

/** A stand-in for a watcher socket. Only `send` and the role attachment are
 *  read on the paths under test, and using a real pair would need a live
 *  upgrade this suite has no way to make from inside the object. */
function fakeWatcher(): { ws: WebSocket; sent: string[] } {
  const sent: string[] = [];
  const ws = {
    send: (text: string) => { sent.push(text); },
    deserializeAttachment: () => ({ role: "watcher" }),
  } as unknown as WebSocket;
  return { ws, sent };
}

describe("session event ring buffer", () => {
  it("assigns a strictly increasing seq", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-seq"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const a = instance.appendEvent(ev("s1", "one"));
      const b = instance.appendEvent(ev("s1", "two"));
      expect(a).not.toBeNull();
      expect(b).not.toBeNull();
      expect(b as number).toBeGreaterThan(a as number);
    });
  });

  it("keeps the newest events once the per-session cap is passed", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-trim"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const over = MachineDO.maxEventsPerSession + 5;
      for (let i = 0; i < over; i++) instance.appendEvent(ev("s1", `t${i}`));
      const page = instance.eventsSince("s1", 0);
      expect(page.events.length).toBe(MachineDO.maxEventsPerSession);
      expect(page.events.some((e) => e.text === `t${over - 1}`)).toBe(true);
      expect(page.events.some((e) => e.text === "t0")).toBe(false);
    });
  });

  it("reports an oldest seq the phone can read a gap from", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-gap"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      for (let i = 0; i < MachineDO.maxEventsPerSession + 5; i++) {
        instance.appendEvent(ev("s1", `t${i}`));
      }
      // Asked from the very beginning, but the oldest still held is later —
      // everything in between is gone and the phone must be able to see that.
      expect(instance.eventsSince("s1", 0).oldestSeq).toBeGreaterThan(1);
    });
  });

  it("refuses a malformed event instead of storing it", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-bad"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const bad = { type: "event", eventId: "x", kind: "assistant", text: "hi", at: 0 };
      expect(instance.appendEvent(bad as unknown as SessionEventMessage)).toBeNull();
      expect(instance.eventsSince("", 0).events.length).toBe(0);
    });
  });

  it("evicts the least recently written session past the session cap", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-sessions"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const over = MachineDO.maxSessions + 1;
      for (let i = 0; i < over; i++) instance.appendEvent(ev(`s${i}`, "x"));
      expect(instance.eventsSince("s0", 0).events.length).toBe(0);
      expect(instance.eventsSince(`s${over - 1}`, 0).events.length).toBe(1);
    });
  });

  it("caps one event's text", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-size"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.appendEvent({ ...ev("s1", "x"), text: "a".repeat(50_000) });
      const stored = instance.eventsSince("s1", 0).events[0];
      expect(stored.text.length).toBe(MachineDO.maxEventTextLength);
    });
  });

  it("keeps a Swift reference-date timestamp intact", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-time"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.appendEvent({ ...ev("s1", "x"), at: 778_000_000.5 });
      expect(instance.eventsSince("s1", 0).events[0].at).toBe(778_000_000.5);
    });
  });

  it("stores a missing timestamp as zero rather than inventing one", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-notime"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.appendEvent({ ...ev("s1", "x"), at: undefined as unknown as number });
      // Not Date.now(): epoch milliseconds decode on the phone as a date tens
      // of thousands of years out, which throws the merged order away.
      expect(instance.eventsSince("s1", 0).events[0].at).toBe(0);
    });
  });

  // A REAL watcher socket, not the stand-in below: fan-out walks
  // `ctx.getWebSockets()`, which only knows about sockets the object actually
  // accepted. The first version of this test used the stand-in and failed for
  // that reason — the fake can be written TO by a handler holding it, but it
  // is not in the object's own set.
  it("fans an incoming event out to watchers with its seq", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-fanout"));
    const upgrade = await stub.fetch("https://do/watch", { headers: { Upgrade: "websocket" } });
    const ws = upgrade.webSocket!;
    ws.accept();
    const received = new Promise<string>((resolve) => {
      ws.addEventListener("message", (e) => resolve(e.data as string));
    });
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const seq = instance.appendEvent(ev("s1", "live"));
      expect(seq).not.toBeNull();
      instance.broadcastEvent({ ...ev("s1", "live"), seq: seq as number });
    });
    const body = JSON.parse(await received);
    expect(body.type).toBe("event");
    expect(body.text).toBe("live");
    expect(typeof body.seq).toBe("number");
  });

  it("answers a watcher's events_since on its own socket", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-backfill"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.appendEvent(ev("s1", "one"));
      instance.appendEvent(ev("s1", "two"));
      const watcher = fakeWatcher();
      instance.webSocketMessage(
        watcher.ws,
        JSON.stringify({ type: "events_since", sessionId: "s1", seq: 0 })
      );
      expect(watcher.sent.length).toBe(1);
      const body = JSON.parse(watcher.sent[0]);
      expect(body.type).toBe("events");
      expect(body.events.length).toBe(2);
      expect(typeof body.oldestSeq).toBe("number");
    });
  });

  it("returns only what follows the seq a watcher asks from", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-after"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const first = instance.appendEvent(ev("s1", "one")) as number;
      instance.appendEvent(ev("s1", "two"));
      const page = instance.eventsSince("s1", first);
      expect(page.events.length).toBe(1);
      expect(page.events[0].text).toBe("two");
    });
  });

  it("ignores an events_since with no sessionId", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-nosession"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const watcher = fakeWatcher();
      instance.webSocketMessage(watcher.ws, JSON.stringify({ type: "events_since", seq: 0 }));
      expect(watcher.sent.length).toBe(0);
    });
  });

  it("keeps one session's events out of another's", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-split"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.appendEvent(ev("s1", "mine"));
      instance.appendEvent(ev("s2", "yours"));
      expect(instance.eventsSince("s1", 0).events.map((e) => e.text)).toEqual(["mine"]);
      expect(instance.eventsSince("s2", 0).events.map((e) => e.text)).toEqual(["yours"]);
    });
  });
});
