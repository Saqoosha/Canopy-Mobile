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
      expect(b!.seq).toBeGreaterThan(a!.seq);
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

  it("reports what it evicted so the phone can read a gap from it", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-gap"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      for (let i = 0; i < MachineDO.maxEventsPerSession + 5; i++) {
        instance.appendEvent(ev("s1", `t${i}`));
      }
      // Asked from the very beginning, and five of this session's own events
      // are gone. `evictedThrough > since` is the whole verdict.
      const page = instance.eventsSince("s1", 0);
      expect(page.since).toBe(0);
      expect(page.evictedThrough).toBeGreaterThan(0);
    });
  });

  // **The bug the eviction mark exists to kill, and it shipped once.**
  // `seq` is one counter for the whole Mac, so a session's numbers are not
  // consecutive. Judging continuity by comparing `oldestSeq` against what
  // was asked for therefore reports a gap on a session that merely started
  // late — which is nearly every session, since only the first one on a Mac
  // begins at seq 1. Caught in review before it reached a phone.
  it("reports no eviction for a session that merely started late", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-late-start"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      for (let i = 0; i < 9; i++) instance.appendEvent(ev("busy", `x${i}`));
      instance.appendEvent(ev("late", "first"));
      const page = instance.eventsSince("late", 0);
      // The signal that used to be read as a gap, and is not one.
      expect(page.oldestSeq).toBeGreaterThan(1);
      // The signal that answers the question.
      expect(page.evictedThrough).toBe(0);
      expect(page.events.length).toBe(1);
    });
  });

  it("reports no eviction once the phone has caught up past what was dropped", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-caught-up"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      for (let i = 0; i < MachineDO.maxEventsPerSession + 5; i++) {
        instance.appendEvent(ev("s1", `t${i}`));
      }
      const dropped = instance.eventsSince("s1", 0).evictedThrough;
      // A phone holding everything up to the last dropped event has lost
      // nothing, however much the relay threw away before that point.
      expect(instance.eventsSince("s1", dropped).evictedThrough).toBe(dropped);
      expect(instance.eventsSince("s1", dropped).since).toBe(dropped);
    });
  });

  // The state `oldestSeq` could not express at all: a session with no rows
  // left reported 0, which is also what a session that never spoke reports.
  it("records a mark for a session evicted in full", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-whole-session"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const over = MachineDO.maxSessions + 1;
      for (let i = 0; i < over; i++) instance.appendEvent(ev(`s${i}`, "x"));
      const page = instance.eventsSince("s0", 0);
      expect(page.events.length).toBe(0);
      expect(page.oldestSeq).toBe(0);
      expect(page.evictedThrough).toBeGreaterThan(0);
    });
  });

  // A mark that could move backwards would retire a fact that is still true.
  //
  // **This pins the property, not the `MAX(...)` that expresses it — swapping
  // that for a plain assignment leaves this green, measured.** Every delete
  // takes a session's oldest rows, so a later mark is always the higher one
  // and no fixture can separate the two implementations. Said here rather
  // than left to read as coverage it does not provide.
  it("never lowers an eviction mark", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-monotonic"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      for (let i = 0; i < MachineDO.maxEventsPerSession + 5; i++) {
        instance.appendEvent(ev("s1", `t${i}`));
      }
      const first = instance.eventsSince("s1", 0).evictedThrough;
      for (let i = 0; i < 3; i++) instance.appendEvent(ev("s1", `more${i}`));
      expect(instance.eventsSince("s1", 0).evictedThrough).toBeGreaterThanOrEqual(first);
    });
  });

  // The mark table holds a row per session ever evicted, including ones with
  // no events left, so nothing else prunes it. Losing the oldest marks
  // degrades to reporting no gap, which is the safe direction.
  it("bounds the eviction mark table, dropping the oldest marks first", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-mark-cap"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const total = MachineDO.maxEvictionMarks + MachineDO.maxSessions + 10;
      for (let i = 0; i < total; i++) instance.appendEvent(ev(`s${i}`, "x"));
      // Evicted earliest, so its mark is the first to go.
      expect(instance.eventsSince("s0", 0).evictedThrough).toBe(0);
      // Evicted too, but recently enough that its mark is still held.
      const recent = total - MachineDO.maxSessions - 1;
      expect(instance.eventsSince(`s${recent}`, 0).evictedThrough).toBeGreaterThan(0);
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

  // `LIMIT -1` in `trimSessions` is there so a woken DO whose `maxSessions`
  // was lowered sheds every session past the new cap at once, rather than one
  // per append. Mutating it to `LIMIT 1` left the whole file green, and this
  // is the only fixture that can tell them apart: normal appends add one
  // session at a time, so the doomed set is never larger than one.
  it("sheds every session past the cap in one append", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-shed-many"));
    await runInDurableObject<MachineDO, void>(stub, async (instance, state) => {
      for (let i = 0; i < MachineDO.maxSessions; i++) instance.appendEvent(ev(`s${i}`, "x"));
      // Stand in for a deploy that lowered the cap: indexed sessions past the
      // cap that this append did not create. Seeded after the appends, or the
      // trim each append runs would sweep them straight back out. `last_seq`
      // 0 puts them at the bottom of the ranking, so they are the doomed set.
      const extra = 5;
      for (let i = 0; i < extra; i++) {
        state.storage.sql.exec(
          `INSERT INTO session (session_id, last_seq) VALUES (?, 0)`, `stale${i}`
        );
      }
      const count = () => state.storage.sql
        .exec<{ n: number }>(`SELECT COUNT(*) AS n FROM session`).toArray()[0].n;
      expect(count()).toBe(MachineDO.maxSessions + extra);
      // One append puts it one further over, so `LIMIT 1` would leave five.
      instance.appendEvent(ev("fresh", "x"));
      expect(count()).toBe(MachineDO.maxSessions);
    });
  });

  // **A gate needs a backstop somewhere off the hot path.** `noteEviction`
  // runs the mark trim only when it inserts a session id the table has never
  // held — right for the append path, but it means a table over cap for any
  // other reason never comes back down. Lowering `maxEvictionMarks` in a
  // deploy is exactly that, and before the gate the next append re-capped it.
  // The wake path is where that property went, so this is where it is pinned.
  it("re-caps an oversized mark table on wake", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-mark-wake"));
    await runInDurableObject<MachineDO, void>(stub, async (instance, state) => {
      // Stand in for a deploy that lowered the cap: marks already on disk
      // that no append will ever be the "first" for.
      const over = MachineDO.maxEvictionMarks + 50;
      for (let i = 0; i < over; i++) {
        state.storage.sql.exec(
          `INSERT INTO eviction (session_id, through) VALUES (?, ?)`, `old${i}`, i + 1
        );
      }
      instance.rebuildSessionIndex();
      const marks = state.storage.sql
        .exec<{ n: number }>(`SELECT COUNT(*) AS n FROM eviction`).toArray()[0].n;
      expect(marks).toBe(MachineDO.maxEvictionMarks);
      // The newest marks are the ones kept — losing a mark degrades to
      // reporting no gap, so what goes has to be the oldest history.
      expect(
        state.storage.sql
          .exec(`SELECT 1 FROM eviction WHERE session_id = ?`, `old${over - 1}`)
          .toArray().length
      ).toBe(1);
    });
  });

  // A Durable Object that was already running when the session index landed
  // holds events but no index rows, and the session cap is enforced entirely
  // from that index. Without the backfill the cap silently stops applying to
  // everything already on disk — no error, just a buffer that grows.
  it("backfills the session index for a DO that predates it", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-migrate"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const over = MachineDO.maxSessions + 1;
      for (let i = 0; i < over; i++) instance.appendEvent(ev(`s${i}`, "x"));
      // **`s1` gets a second event, and that is the whole point of it.** With
      // one event per session every aggregate over `seq` agrees, so a backfill
      // seeding `MIN(seq)` instead of `MAX(seq)` passes — verified: the suite
      // stayed green under that mutation. A second event separates them, and
      // ranking by the oldest seq would then evict the session that is in fact
      // the most recently written.
      instance.appendEvent(ev("s1", "later"));
      instance.rebuildSessionIndex();
      // The cap still bites on a session that only the backfill knows about.
      instance.appendEvent(ev("fresh", "x"));
      expect(instance.eventsSince("s2", 0).events.length).toBe(0);
      expect(instance.eventsSince("s1", 0).events.length).toBe(2);
      expect(instance.eventsSince("fresh", 0).events.length).toBe(1);
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

  // The same hole on the OTHER eviction path. `trimSessions` drops a session
  // whole and looks its mark up separately, and swapping that `MAX(seq)` for
  // `MIN(seq)` also left the whole file green — a session dropped with 200
  // buffered events would then report its FIRST seq as the mark, telling a
  // phone caught up past it that nothing was lost.
  it("marks a session evicted in full at its newest seq", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-mark-whole"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      let last = 0;
      for (let n = 0; n < 5; n++) {
        last = instance.appendEvent(ev("doomed", `d${n}`))!.seq;
      }
      for (let n = 0; n < MachineDO.maxSessions; n++) instance.appendEvent(ev(`s${n}`, "x"));
      const page = instance.eventsSince("doomed", 0);
      expect(page.events.length).toBe(0);
      expect(page.evictedThrough).toBe(last);
    });
  });

  // **Nothing pinned the mark's VALUE until this test.** The old code derived
  // it with `SELECT MAX(seq) ... WHERE seq NOT IN (survivors)` — computed from
  // what actually went. The new code asserts by construction that the deleted
  // set is exactly `seq <= cutoff`, so the mark IS the cutoff, and skips that
  // query. That argument stood on a comment: mutating the mark to `cutoff + 1`
  // left every other test in this file green.
  //
  // One too high is the failure the eviction table exists to prevent, in
  // reverse — a phone holding everything is told a gap it does not have. One
  // too low hides a real gap. Both directions are pinned by the equality.
  it("marks exactly the newest evicted seq", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-mark-value"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      for (let i = 0; i < MachineDO.maxEventsPerSession + 5; i++) {
        instance.appendEvent(ev("s1", `e${i}`));
      }
      const page = instance.eventsSince("s1", 0);
      expect(page.events.length).toBe(MachineDO.maxEventsPerSession);
      expect(page.evictedThrough).toBe(page.events[0].seq - 1);
    });
  });

  // **The regression that exhausted a day's free tier.** Enforcing the
  // session cap with a SELECT and a DELETE, each shaped `session_id NOT IN
  // (SELECT ... FROM event GROUP BY session_id ...)`, scans the whole `event`
  // table four times per appended event — twice per statement — whether or
  // not anything is over the cap. On a full buffer that measured 16,853 rows
  // read to store one event, and a normal day's traffic went through Durable
  // Objects' 5,000,000 rows_read daily free tier; every route that touches a
  // DO then returned errors until the counter reset.
  //
  // **The bound is what makes this a test.** Every assertion that existed
  // before this change passes with the full-scan version — it deleted the
  // right rows, it just read the whole table to decide that. `cursor.rowsRead`
  // is the billed quantity itself, so a bound on it is a bound on the bill.
  //
  // **There are THREE caps, and the fixture has to fill all of them.** The
  // first version of this test filled the two on `event` and measured 249 —
  // while a Durable Object that has run for any length of time also holds
  // `maxEvictionMarks` marks, and against that the same append read 651. The
  // mark trim was 405 of it — 3 rows in the fixture that omitted the cap, so
  // 402 of the difference — reading the whole table to delete nothing. So the
  // test that existed to pin the bill was blind to 62% of it, and its own
  // comment claimed a number measured under a fixture that omitted the
  // dominant cost. A ceiling measured against a fixture that omits a cap
  // asserts nothing about the case that omitted cap produces.
  //
  // The ceiling has some slack, but the cost it bounds is deterministic. An
  // append reads `201 + 2 × (rows in session) + ~7` — 248 at the session cap,
  // 210 with one live session. Every term is bounded by a cap, and none of
  // them is the size of `event` or of `eviction`, which is what the old form
  // could not say.
  //
  // **Do not shorten that to "flat".** An earlier draft of this comment did,
  // on the strength of this very fixture measuring 248 at 1, 5 and 20 live
  // sessions — but the churn phase leaves `session` at its cap whatever the
  // second phase does, so all three runs had the same 20 rows and the number
  // was an artifact of the fixture, not a property of the code. That is the
  // same mistake, twice, in the same test.
  it("appends an event without reading the whole buffer", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-cost"));
    await runInDurableObject<MachineDO, void>(stub, async (instance, state) => {
      // Distinct one-event sessions, each evicted whole, until the mark
      // table is at its own cap — the state every long-lived DO reaches.
      const churn = MachineDO.maxEvictionMarks + MachineDO.maxSessions + 10;
      for (let i = 0; i < churn; i++) instance.appendEvent(ev(`churn${i}`, "x"));
      // **One event PAST the cap, not up to it.** A session stopped exactly at
      // the cap has never evicted, so it has no mark yet, and the first append
      // after that pays the mark trim once — 651 rows, and then never again.
      // Measuring that append pins a per-session one-off instead of the number
      // that multiplies by traffic.
      for (let s = 0; s < MachineDO.maxSessions; s++)
        for (let n = 0; n <= MachineDO.maxEventsPerSession; n++)
          instance.appendEvent(ev(`s${s}`, `e${n}`));
      // **Check every cap, not the one that was on your mind.** An earlier
      // version of this block asserted the mark count alone — while its own
      // comment said the fixture is worth only what it actually built. A
      // later change that made `trimSessions` over-evict would collapse the
      // buffer, drop the measured append to ~210, and still pass the ceiling.
      const built = state.storage.sql
        .exec<{ marks: number; sessions: number; events: number }>(
          `SELECT (SELECT COUNT(*) FROM eviction) AS marks,
                  (SELECT COUNT(*) FROM session)  AS sessions,
                  (SELECT COUNT(*) FROM event)    AS events`
        ).toArray()[0];
      expect(built.marks).toBe(MachineDO.maxEvictionMarks);
      expect(built.sessions).toBe(MachineDO.maxSessions);
      expect(built.events).toBe(MachineDO.maxSessions * MachineDO.maxEventsPerSession);
      expect(
        state.storage.sql
          .exec(`SELECT 1 FROM eviction WHERE session_id = 's0'`).toArray().length
      ).toBe(1);

      const sql = state.storage.sql;
      const real = sql.exec.bind(sql);
      let read = 0;
      // The cursor reports its counts only once it has been drained, and the
      // caller drains its own copy — so read the rows here and hand back an
      // array-backed stand-in rather than the spent cursor.
      (sql as unknown as { exec: unknown }).exec = (...args: [string, ...unknown[]]) => {
        const cursor = real(...args);
        const rows = cursor.toArray();
        read += cursor.rowsRead;
        return { toArray: () => rows };
      };
      try {
        instance.appendEvent(ev("s0", "one-more"));
      } finally {
        (sql as unknown as { exec: unknown }).exec = real;
      }
      expect(read).toBeLessThan(300);
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

  // **The ASCII fixture above cannot fail for the safeSlice fix**: at 8192
  // ASCII characters `.slice` and `safeSlice` return the same string, so
  // reverting to `.slice` leaves it green. This one cuts inside a run of
  // astral-plane characters, where `.slice` counts UTF-16 units and leaves a
  // lone surrogate that the phone's JSON decode rejects — taking the whole
  // backfill page with it.
  it("does not split a surrogate pair when capping", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:ev-surrogate"));
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      instance.appendEvent({ ...ev("s1", "x"), text: "🍎".repeat(9000) });
      const stored = instance.eventsSince("s1", 0).events[0].text;
      // No unpaired surrogate anywhere in the stored text.
      expect(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(stored))
        .toBe(false);
      // And it is cut by code point, so every kept character is whole.
      expect(Array.from(stored).length).toBe(MachineDO.maxEventTextLength);
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
    // Driven through `webSocketMessage`, not by calling appendEvent and
    // broadcastEvent by hand: the first version did that and could not see
    // the defect it should have caught — live fan-out was sending the RAW
    // message while only the stored copy was normalised, so the same event
    // was two different things depending on the route. The fixtures below
    // carry an over-long text and no `at` for exactly that reason.
    await runInDurableObject<MachineDO, void>(stub, async (instance) => {
      const raw = { ...ev("s1", "x"), text: "a".repeat(50_000) } as Record<string, unknown>;
      delete raw.at;
      // The sending socket is irrelevant to this path — the event branch
      // reads only the message — so the stand-in is fine HERE. What must be
      // real is the RECEIVING watcher above, which fan-out finds through the
      // object's own socket list.
      instance.webSocketMessage(fakeWatcher().ws, JSON.stringify(raw));
    });
    const body = JSON.parse(await received);
    expect(body.type).toBe("event");
    expect(typeof body.seq).toBe("number");
    // Both of these were wrong before the fix: the live frame carried the
    // full 50 000 characters, and no `at` key at all — which fails the
    // phone's decode silently.
    expect(body.text.length).toBe(MachineDO.maxEventTextLength);
    expect(body.at).toBe(0);
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
      const first = instance.appendEvent(ev("s1", "one"))!.seq;
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
