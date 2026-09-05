import { DurableObject } from "cloudflare:workers";
import type { DecisionEnvelope, DeliveryAck, MachineSnapshot, ReplyEnvelope } from "./types";

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
  private readonly pendingAcks = new Map<string, (ack: DeliveryAck) => void>();

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
    if (!this.deliverReply(envelope)) {
      return { delivered: false, ok: false, reason: "no Mac connected" };
    }
    const ack = await new Promise<DeliveryAck | null>((resolve) => {
      const timer = setTimeout(() => {
        this.pendingAcks.delete(envelope.deliveryId);
        resolve(null);
      }, MachineDO.ackTimeoutMs);
      this.pendingAcks.set(envelope.deliveryId, (received) => {
        clearTimeout(timer);
        this.pendingAcks.delete(envelope.deliveryId);
        resolve(received);
      });
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
  deliverReply(envelope: ReplyEnvelope | DecisionEnvelope): boolean {
    const publishers = this.ctx.getWebSockets().filter((ws) => {
      const attachment = ws.deserializeAttachment() as { role?: string } | null;
      return attachment?.role === "publisher";
    });
    if (publishers.length === 0) return false;
    const text = JSON.stringify(envelope);
    let delivered = false;
    for (const ws of publishers) {
      try {
        ws.send(text);
        delivered = true;
      } catch {
        // A socket the runtime has not yet reaped. Try the next one rather
        // than reporting failure while another publisher may still be live.
      }
    }
    return delivered;
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

  webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): void {
    if (typeof message !== "string") return;
    const parsed = JSON.parse(message) as Partial<MachineSnapshot> & Partial<DeliveryAck>;
    // An acknowledgement, not a snapshot. Checked first because a snapshot
    // has no `type` and would otherwise fall through the same shape guard.
    if (parsed.type === "ack" && typeof parsed.deliveryId === "string") {
      const waiting = this.pendingAcks.get(parsed.deliveryId);
      // A late ack — one whose request already timed out — finds nothing and
      // is dropped. Deliberately silent: the phone has already been told the
      // truth for that delivery, and revising it afterwards is not something
      // an HTTP response can do.
      if (waiting) waiting(parsed as DeliveryAck);
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
