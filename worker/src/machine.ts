import { DurableObject } from "cloudflare:workers";
import type { DecisionEnvelope, DeliveryAck, MachineSnapshot, ReplyEnvelope } from "./types";

/** One in-flight delivery's outstanding recipients and its verdict so far. */
interface AckWaiter {
  /** Sockets the delivery was written to that have not yet answered. */
  outstanding: Set<WebSocket>;
  /** The first rejection seen, reported only if every recipient rejects. */
  rejection?: DeliveryAck;
  /** Ends the wait, cancelling the timeout and clearing the map entry. */
  settle: (ack: DeliveryAck | null) => void;
}

export class MachineDO extends DurableObject {
  private cached: MachineSnapshot | null = null;

  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(
        `CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)`
      );
    });
  }

  /**
   * Replace the whole roster for this Mac. Canopy always sends a full snapshot.
   *
   * The spec requires anything undelivered to be queued in SQLite, because
   * hibernation clears memory. A roster has nothing to queue: the newest
   * snapshot is the whole truth and supersedes every earlier one, so storing
   * the latest IS the queue. Do not add a message log here — a replayed older
   * snapshot would resurrect a pane that has since closed.
   */
  applySnapshot(snapshot: MachineSnapshot): void {
    this.cached = snapshot;
    this.ctx.storage.sql.exec(
      `INSERT INTO snapshot (id, json) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json`,
      JSON.stringify(snapshot)
    );
  }

  currentSnapshot(): MachineSnapshot | null {
    if (this.cached) return this.cached;
    const rows = this.ctx.storage.sql
      .exec<{ json: string }>(`SELECT json FROM snapshot WHERE id = 1`)
      .toArray();
    if (rows.length === 0) return null;
    this.cached = JSON.parse(rows[0].json) as MachineSnapshot;
    return this.cached;
  }

  /** Test seam: simulate what hibernation does to the in-memory copy. */
  forgetInMemoryState(): void {
    this.cached = null;
  }

  /** Deliveries waiting for the Mac to say what it did with them.
   *
   *  In memory on purpose, and safe to be: the only thing that resolves one is
   *  a `webSocketMessage` arriving while the `fetch` that created it is still
   *  awaiting. A DO cannot hibernate with a request in flight, so an entry
   *  cannot outlive the promise that reads it — and if the DO is evicted
   *  anyway, the request is gone too and there is nobody left to answer. */
  /** In-flight deliveries, keyed by `deliveryId`.
   *
   *  **A delivery has more than one recipient**, which the first version of
   *  this map did not model: it held one callback and the first ack to arrive
   *  settled the request. One Mac runs more than one Canopy more often than it
   *  sounds — `MachineIdentity.stableId()` is per-machine, so a Debug build
   *  and the installed Release connect as the SAME machine, and a reconnect
   *  overlaps the old socket with the new one. `deliverReply` writes to all of
   *  them, only one owns the session, and the others answer "no open session
   *  matches" at once. First-ack-wins therefore reported 409 for a reply that
   *  had in fact been injected — this PR's own lie, in the other direction. */
  private readonly pendingAcks = new Map<string, AckWaiter>();

  /** How long to wait for the Mac before reporting the delivery unconfirmed.
   *
   *  A reply is injected the moment Canopy routes it, so the round trip is
   *  local-network fast; this is long enough to absorb a slow wake, short
   *  enough that the phone is not left spinning. A timeout is NOT a failure
   *  claim — it is the honest "we do not know", and the phone says exactly
   *  that. */
  private static readonly ackTimeoutMs = 5000;

  /** Sends a delivery and waits for the Mac to acknowledge it.
   *
   *  **Why this exists.** `ws.send()` on a half-open socket does not throw:
   *  the write is buffered into a connection whose other end is gone, and
   *  `deliverReply` reports success. Measured 2026-09-05 — a Mac Studio whose
   *  socket had been dead for 47 minutes still took a `POST /reply` with a
   *  200, and the phone told the user their message had been sent. An
   *  acknowledgement is the only thing that can tell "written" from
   *  "received". */
  async deliverAndAwaitAck(
    envelope: (ReplyEnvelope | DecisionEnvelope) & { deliveryId: string },
  ): Promise<{ delivered: boolean; ok: boolean; reason?: string }> {
    const recipients = this.deliverReply(envelope);
    if (recipients.length === 0) {
      return { delivered: false, ok: false, reason: "no Mac connected" };
    }
    const ack = await new Promise<DeliveryAck | null>((resolve) => {
      const waiter: AckWaiter = {
        outstanding: new Set(recipients),
        settle: (result) => {
          clearTimeout(timer);
          this.pendingAcks.delete(envelope.deliveryId);
          resolve(result);
        },
      };
      const timer = setTimeout(() => {
        // **A rejection is only reported once every recipient has rejected.**
        // With one still silent we genuinely do not know whether it acted, so
        // the answer stays the honest "unconfirmed" rather than borrowing the
        // one publisher that said no — which would assert `delivered: true`
        // about a delivery that may well have succeeded elsewhere.
        waiter.settle(null);
      }, MachineDO.ackTimeoutMs);
      this.pendingAcks.set(envelope.deliveryId, waiter);
    });
    if (!ack) return { delivered: false, ok: false, reason: "the Mac did not answer" };
    return { delivered: true, ok: ack.ok, reason: ack.reason };
  }

  /** Writes a reply or a decision down the publisher socket, if one is
   *  connected. One finder for both envelope kinds, since the only thing
   *  either needs is "reach the publisher" — the shape of what gets sent is
   *  the caller's concern.
   *
   *  Uses the sockets the Hibernation API hands back rather than any in-memory
   *  set: this DO may have hibernated since the publisher connected, and an
   *  in-memory list would be empty. The role comes from the attachment for the
   *  same reason. */
  deliverReply(envelope: ReplyEnvelope | DecisionEnvelope): WebSocket[] {
    const publishers = this.ctx.getWebSockets().filter((ws) => {
      const attachment = ws.deserializeAttachment() as { role?: string } | null;
      return attachment?.role === "publisher";
    });
    const text = JSON.stringify(envelope);
    // The sockets actually written to, not every publisher: a socket whose
    // `send` threw never received this delivery, so an ack claiming to be
    // from it is not one, and it must not be counted as a recipient still
    // owed an answer.
    const written: WebSocket[] = [];
    for (const ws of publishers) {
      try {
        ws.send(text);
        written.push(ws);
      } catch {
        // A socket the runtime has not yet reaped. Try the next one rather
        // than reporting failure while another publisher may still be live.
      }
    }
    return written;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/roster") {
      const snapshot = this.currentSnapshot();
      if (!snapshot) return new Response("not found", { status: 404 });
      return new Response(JSON.stringify(snapshot), {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.pathname === "/reply" && request.method === "POST") {
      const envelope = (await request.json()) as ReplyEnvelope;
      return this.respondToDelivery({ ...envelope, deliveryId: crypto.randomUUID() });
    }
    if (url.pathname === "/decide" && request.method === "POST") {
      const envelope = (await request.json()) as DecisionEnvelope;
      return this.respondToDelivery({ ...envelope, deliveryId: crypto.randomUUID() });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const role = url.pathname === "/watch" ? "watcher" : "publisher";
    const pair = new WebSocketPair();
    // Hibernation API. `pair[1].accept()` would bill an idle connection.
    this.ctx.acceptWebSocket(pair[1]);
    // Attachments survive hibernation; an in-memory Set would not.
    pair[1].serializeAttachment({ role });
    if (role === "watcher") {
      // Without this, a watcher sees nothing until some Mac's state next
      // changes — an hour-old snapshot reads as current, and a machine
      // first appearing while the app is open sits blank indefinitely.
      // Only this one new socket needs it; broadcast() is for an actual
      // state change reaching every existing watcher.
      const snapshot = this.currentSnapshot();
      if (snapshot) {
        try {
          pair[1].send(JSON.stringify(snapshot));
        } catch {
          // The socket can't plausibly be gone already; matches broadcast()'s guard.
        }
      }
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** One response shape for both delivery routes.
   *
   *  **200 now means the Mac acted on it**, which is the whole point of the
   *  ack. The two failure shapes are kept apart because the phone shows them
   *  differently: 503 is "it never got there" (no Mac, or no answer within the
   *  timeout), and 409 is "it got there and could not be used" — a session
   *  that has closed, a shim that is busy. Conflating them would tell the user
   *  to retry when retrying cannot help. */
  private respondToDelivery(
    envelope: (ReplyEnvelope | DecisionEnvelope) & { deliveryId: string },
  ): Promise<Response> {
    return this.deliverAndAwaitAck(envelope).then(({ delivered, ok, reason }) => {
      const status = ok ? 200 : delivered ? 409 : 503;
      return new Response(JSON.stringify({ ok, reason }), {
        status,
        headers: { "Content-Type": "application/json" },
      });
    });
  }

  webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
    if (typeof message !== "string") return;
    const parsed = JSON.parse(message) as Partial<MachineSnapshot> & Partial<DeliveryAck>;
    // An acknowledgement, not a snapshot. Checked first because a snapshot
    // has no `type` and would otherwise fall through the same shape guard.
    if (parsed.type === "ack" && typeof parsed.deliveryId === "string") {
      const waiter = this.pendingAcks.get(parsed.deliveryId);
      // A late ack — one whose request already timed out — finds nothing and
      // is dropped. Deliberately silent: the phone has already been told the
      // truth for that delivery, and revising it afterwards is not something
      // an HTTP response can do.
      if (!waiter) return;
      // **Only a socket this delivery was written to may answer for it, and
      // only once.** `Set.delete` returns false for a socket that was never a
      // recipient and for one that has already answered, so both are dropped
      // by the same line. This is not authentication — every publisher shares
      // one Bearer secret, so a holder of it can still be among the genuine
      // recipients — but it does stop an ack for a delivery a socket never
      // received, and stops one socket answering enough times to stand in for
      // the others. Per-Mac credentials are the real fix and belong with the
      // secret model, not here.
      if (!waiter.outstanding.delete(ws)) return;
      const ack = parsed as DeliveryAck;
      // A success ends the wait at once: one Mac acting on it is the answer,
      // whatever the others say. Only when every recipient has rejected is a
      // rejection the whole truth.
      if (ack.ok) {
        waiter.settle(ack);
      } else {
        waiter.rejection ??= ack;
        if (waiter.outstanding.size === 0) waiter.settle(waiter.rejection);
      }
      return;
    }
    // Narrow shape check, not a schema validator: a malformed publish must
    // not be persisted and served back to the phone, where — until the
    // RosterSocket fix — an undecodable frame permanently ended that
    // machine's watch socket.
    if (typeof parsed.machineId !== "string" || parsed.machineId.length === 0 || !Array.isArray(parsed.panes)) {
      console.error("rejected publish: malformed snapshot shape");
      return;
    }
    this.applySnapshot(parsed as MachineSnapshot);
    this.broadcast();
  }

  /** Send the current snapshot to every watcher. Publishers are skipped. */
  broadcast(): void {
    const snapshot = this.currentSnapshot();
    if (!snapshot) return;
    const text = JSON.stringify(snapshot);
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as { role?: string } | null;
      if (attachment?.role !== "watcher") continue;
      try {
        ws.send(text);
      } catch {
        // A watcher that has gone away is routine; the next publish retries.
      }
    }
  }
}
