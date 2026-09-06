import { DurableObject } from "cloudflare:workers";
import { safeSlice } from "./llm";
import type {
  DecisionEnvelope, DeliveryAck, EventsResponse, MachineSnapshot,
  ReplyEnvelope, SessionEventMessage, StoredSessionEvent,
} from "./types";

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
      // The session-event ring buffer. A table rather than a JSON blob
      // because both things this feature needs are one statement here:
      // "everything after seq N" and "drop all but the newest 200".
      this.ctx.storage.sql.exec(
        `CREATE TABLE IF NOT EXISTS event (
           seq        INTEGER PRIMARY KEY AUTOINCREMENT,
           session_id TEXT NOT NULL,
           event_id   TEXT NOT NULL,
           resume_id  TEXT,
           kind       TEXT NOT NULL,
           text       TEXT NOT NULL,
           created_at REAL NOT NULL
         )`
      );
      this.ctx.storage.sql.exec(
        `CREATE INDEX IF NOT EXISTS event_by_session ON event (session_id, seq)`
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

  /** How many events one session keeps. The design's "recent enough to catch
   *  up on" made concrete. */
  static readonly maxEventsPerSession = 200;
  /** How many sessions keep a buffer at all. The least recently written one
   *  is dropped whole. */
  static readonly maxSessions = 20;
  /** Ceiling on one event's text, in CODE POINTS. Canopy caps its own in
   *  UTF-8 bytes; this is the relay refusing to take Canopy's word for it,
   *  and the two units differ on purpose — this one only has to be a bound,
   *  not the same bound. */
  static readonly maxEventTextLength = 8 * 1024;

  /** Store one event and return the seq assigned to it, or null if it was
   *  refused.
   *
   *  **The shape check runs before the insert, not after.** A malformed value
   *  that reaches storage is handed straight back to the phone on the next
   *  backfill — the same mistake on the snapshot path once ended a machine's
   *  watch socket permanently. */
  appendEvent(msg: SessionEventMessage): StoredSessionEvent | null {
    if (
      typeof msg?.sessionId !== "string" || msg.sessionId.length === 0 ||
      typeof msg.eventId !== "string" || msg.eventId.length === 0 ||
      typeof msg.kind !== "string" || msg.kind.length === 0 ||
      typeof msg.text !== "string"
    ) {
      console.error("rejected event: malformed shape");
      return null;
    }
    // `safeSlice`, never `.slice`: this file's sibling uses it on the notify
    // path for the reason that applies here too — `.slice` counts UTF-16
    // units and can cut a surrogate pair, leaving a lone surrogate that the
    // phone's JSON decode rejects. One such event would fail the record, and
    // inside a backfill page it takes all 200 with it.
    const text = safeSlice(msg.text, MachineDO.maxEventTextLength);
    // **Never substitute `Date.now()` here.** Canopy sends seconds on Swift's
    // 2001 reference date; an epoch-milliseconds value mixed in decodes on the
    // phone as a date tens of thousands of years out and throws the merged
    // conversation's order away. A missing timestamp sorts to the front, which
    // is wrong but bounded.
    const at = typeof msg.at === "number" && Number.isFinite(msg.at) ? msg.at : 0;
    const rows = this.ctx.storage.sql
      .exec<{ seq: number }>(
        `INSERT INTO event (session_id, event_id, resume_id, kind, text, created_at)
         VALUES (?, ?, ?, ?, ?, ?) RETURNING seq`,
        msg.sessionId, msg.eventId, msg.resumeId ?? null, msg.kind, text, at
      )
      .toArray();
    const seq = rows[0]?.seq;
    if (typeof seq !== "number") return null;
    this.trim(msg.sessionId);
    // **The STORED row, not the message that arrived.** Fanning out the raw
    // `parsed` was the first version, and it made the same event two
    // different things depending on the route: live it carried untruncated
    // text and, with `at` missing, no `at` key at all — which fails the
    // phone's decode silently — while a backfill of the same event carried
    // 8 KiB of text and `at: 0`. Everything the phone sees now comes from
    // one normalisation.
    return {
      type: "event",
      seq,
      eventId: msg.eventId,
      sessionId: msg.sessionId,
      resumeId: msg.resumeId ?? null,
      kind: msg.kind,
      text,
      at,
    };
  }

  /** Drop whatever is over the caps. Runs on every write, so the buffer can
   *  never be more than one event past either limit. */
  private trim(sessionId: string): void {
    this.ctx.storage.sql.exec(
      `DELETE FROM event WHERE session_id = ? AND seq NOT IN (
         SELECT seq FROM event WHERE session_id = ? ORDER BY seq DESC LIMIT ?
       )`,
      sessionId, sessionId, MachineDO.maxEventsPerSession
    );
    this.ctx.storage.sql.exec(
      `DELETE FROM event WHERE session_id NOT IN (
         SELECT session_id FROM event GROUP BY session_id ORDER BY MAX(seq) DESC LIMIT ?
       )`,
      MachineDO.maxSessions
    );
  }

  /** Everything after `after` for one session, plus the oldest seq still held.
   *
   *  See `EventsResponse.oldestSeq` for why that number ships with every
   *  answer rather than only when something is missing. */
  eventsSince(sessionId: string, after: number): EventsResponse {
    const rows = this.ctx.storage.sql
      .exec<{
        seq: number; session_id: string; event_id: string;
        resume_id: string | null; kind: string; text: string; created_at: number;
      }>(
        `SELECT seq, session_id, event_id, resume_id, kind, text, created_at
           FROM event WHERE session_id = ? AND seq > ? ORDER BY seq ASC`,
        sessionId, after
      )
      .toArray();
    const oldest = this.ctx.storage.sql
      .exec<{ seq: number | null }>(
        `SELECT MIN(seq) AS seq FROM event WHERE session_id = ?`, sessionId
      )
      .toArray();
    return {
      type: "events",
      sessionId,
      oldestSeq: oldest[0]?.seq ?? 0,
      events: rows.map((r) => ({
        type: "event" as const,
        seq: r.seq,
        eventId: r.event_id,
        sessionId: r.session_id,
        resumeId: r.resume_id,
        kind: r.kind as SessionEventMessage["kind"],
        text: r.text,
        at: r.created_at,
      })),
    };
  }

  /** Send one event to every watcher. Publishers are skipped, exactly as in
   *  `broadcast()`. */
  broadcastEvent(event: StoredSessionEvent): void {
    const text = JSON.stringify(event);
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as { role?: string } | null;
      if (attachment?.role !== "watcher") continue;
      try {
        ws.send(text);
      } catch {
        // A watcher that has gone away is routine; the next event retries.
      }
    }
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
    // `type` is widened to a plain string because four different messages
    // arrive on these sockets and only three of them carry one. Narrowing it
    // to any single message's literal makes the comparisons below a compile
    // error, which is what the type says rather than what the wire does.
    const parsed = JSON.parse(message) as Partial<MachineSnapshot> &
      Omit<Partial<DeliveryAck>, "type"> & { type?: string };
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
    // A session event from the publisher. Checked before the snapshot shape
    // guard below, which would otherwise reject it as "no panes" and log a
    // rejection for a perfectly good message.
    if (parsed.type === "event") {
      const stored = this.appendEvent(parsed as unknown as SessionEventMessage);
      if (stored === null) return;
      this.broadcastEvent(stored);
      return;
    }
    // A watcher asking for what it missed. Answered on its own socket rather
    // than broadcast — nobody else asked.
    if (parsed.type === "events_since") {
      const sessionId = (parsed as { sessionId?: unknown }).sessionId;
      if (typeof sessionId !== "string" || sessionId.length === 0) {
        console.error("rejected events_since: no sessionId");
        return;
      }
      const raw = (parsed as { seq?: unknown }).seq;
      const after = typeof raw === "number" && Number.isFinite(raw) ? raw : 0;
      try {
        ws.send(JSON.stringify(this.eventsSince(sessionId, after)));
      } catch {
        // The watcher went away between asking and being answered. It will
        // ask again on its next connection.
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
