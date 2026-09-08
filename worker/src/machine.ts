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
    ctx.blockConcurrencyWhile(async () => this.ensureSchema());
  }

  /** Create every table this DO needs and bring an older one's data up to it.
   *  Split out of the constructor so a test can re-run it. */
  private ensureSchema(): void {
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
    // What the ring buffer has thrown away, per session. Without it a
    // watcher cannot tell a dropped event from a seq that belonged to a
    // different session, because `seq` above is global to this Mac and a
    // single session's numbers are therefore not consecutive. See
    // `EventsResponse.evictedThrough`.
    //
    // Deliberately its own table rather than a column on `event`: the
    // case it has to survive is a session whose rows are ALL gone.
    this.ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS eviction (
         session_id TEXT PRIMARY KEY,
         through    INTEGER NOT NULL
       )`
    );
    // One row per session that still has events, holding its newest seq.
    //
    // **This table exists for the bill, not for the feature.** The session
    // cap used to be enforced by a pair of `session_id NOT IN (SELECT
    // session_id FROM event GROUP BY session_id ...)` statements — a SELECT
    // to record the evictions and a DELETE to make them — and each one scans
    // every row of `event` twice, once for the subquery and once for itself.
    // Four full scans per appended event, whether or not anything is over
    // the cap. Measured with `cursor.rowsRead` on a full buffer (20 sessions
    // × 200 events): 16,040 of the 16,853 rows read per event, 95% of the
    // cost, to delete nothing. That put a day's normal traffic past Durable
    // Objects' 5,000,000 rows_read free tier and the relay began returning
    // errors on every route that touches a DO.
    //
    // Ordering ~20 rows here instead of ~4,000 there is most of the fix, not
    // all of it: with this table in place but the per-session trim left in
    // its old form, a full-buffer append still measures ~850. See
    // `trimSessionEvents` for the other half.
    this.ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS session (
         session_id TEXT PRIMARY KEY,
         last_seq   INTEGER NOT NULL
       )`
    );
    // Durable Objects created before this table existed already hold
    // events, and their session rows have to come from somewhere. One
    // grouped scan, guarded so it does real work only once — an empty index
    // beside a non-empty `event` is exactly the pre-migration state. The
    // guard is evaluated on every wake, and for a DO that has never stored
    // an event it never stops being true; that costs one row, because an
    // empty `event` makes the scan free.
    //
    // **This guard is not an optimisation — without it the DO cannot wake.**
    // It reads like one, and the sentence above only talks about cost, but
    // the statement it guards is a bare `INSERT`: run it against storage that
    // already has index rows and it raises `UNIQUE constraint failed`, inside
    // `blockConcurrencyWhile`, which fails construction and takes every route
    // for that Mac down on every wake. `ON CONFLICT DO NOTHING` below means
    // that is no longer true, so the guard is back to being about cost — but
    // both are kept, because one of them being load-bearing was invisible.
    //
    // **The guard asks "is the index empty", not "is the index complete".**
    // A binary that writes `event` without maintaining `session` — the one
    // this replaces — running against storage that already has an index
    // leaves sessions the cap can never see, and this will not repair them.
    // Reaching that state needs a rollback or a split-version deployment. A
    // session that appends again heals itself; one that has gone quiet keeps
    // its rows for good, and while it does, `maxSessions` is not a bound.
    // `LIMIT 1`, not `COUNT(*)`: the question is whether any row exists, and
    // a count reads the whole table to answer it — the pattern this whole
    // change is about, one row where twenty were being read.
    const seeded = this.ctx.storage.sql
      .exec(`SELECT 1 FROM session LIMIT 1`)
      .toArray().length;
    if (seeded === 0) {
      this.ctx.storage.sql.exec(
        `INSERT INTO session (session_id, last_seq)
           SELECT session_id, MAX(seq) FROM event GROUP BY session_id
         ON CONFLICT(session_id) DO NOTHING`
      );
    }
    // **The mark cap needs one enforcement point that does not depend on a
    // new session appearing.** `noteEviction` runs the trim only when it
    // inserts a session id the table has never held, which is the right
    // trade on the append path — but it means a table that is over cap for
    // any OTHER reason stays over cap indefinitely. Lowering
    // `maxEvictionMarks` in a deploy is exactly that: before the gate the
    // next append re-capped the table, and the gate silently took that away.
    // Here it costs one statement per wake instead of one per append: ~405
    // rows with the mark table full, against ~248 for an append. A DO would
    // have to wake more than ten thousand times a day for that to matter, and
    // a DO waking that often is already handling enough appends to dominate
    // it.
    this.trimEvictionMarks();
  }

  /** Test seam: re-enter the wake path exactly as a second construction
   *  would, over whatever this DO already holds.
   *
   *  Separate from `rebuildSessionIndex` because that one empties the index
   *  first, so every test that used it took the migration's TRUE branch and
   *  the false branch — the one an ordinary wake takes, and the one that used
   *  to throw — had no coverage at all. */
  rerunWakePath(): void {
    this.ensureSchema();
  }

  /** Test seam: put this DO back in the state a deployment from before the
   *  `session` index left behind — events on disk, no index — and re-run the
   *  whole wake path over it, migration and cap enforcement both.
   *
   *  This and `rerunWakePath` are public because a `DurableObject` subclass
   *  has no other way to expose one, matching `forgetInMemoryState` below.
   *  Nothing routes to them: every entry point in `index.ts` reaches this
   *  class through `stub.fetch`. */
  rebuildSessionIndex(): void {
    this.ctx.storage.sql.exec(`DELETE FROM session`);
    this.ensureSchema();
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
  /** How many sessions keep an eviction mark. Ten times `maxSessions`, so a
   *  session that has fallen out of the buffer keeps its mark for a long
   *  while after — a row is a session id and an integer, and the whole table
   *  at this size is a few kilobytes. */
  static readonly maxEvictionMarks = 200;
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
    this.trim(msg.sessionId, seq);
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

  /** Record `seq` as this session's newest, then drop whatever is over the
   *  caps. Runs on every write, so the buffer can never be more than one
   *  event past either limit.
   *
   *  The index write comes first because `trimSessions` ranks sessions by it:
   *  raising this session's `last_seq` before the ranking is what keeps the
   *  session currently being appended to from evicting itself.
   *
   *  **Every delete is recorded before it happens.** A watcher's only way to
   *  know it has lost something is `evictedThrough`, so a deletion that does
   *  not raise the mark is a hole nothing will ever admit to. The two callees
   *  record separately because they lose different things: the first drops a
   *  session's oldest events, the second drops whole sessions.
   */
  private trim(sessionId: string, seq: number): void {
    this.ctx.storage.sql.exec(
      `INSERT INTO session (session_id, last_seq) VALUES (?, ?)
       ON CONFLICT(session_id) DO UPDATE SET last_seq = MAX(last_seq, excluded.last_seq)`,
      sessionId, seq
    );
    this.trimSessionEvents(sessionId);
    this.trimSessions();
  }

  /** Drop this session's events past `maxEventsPerSession`.
   *
   *  **The cutoff is looked up, not described in the DELETE.** `OFFSET` on
   *  the session's own index walks at most `maxEventsPerSession + 1` rows —
   *  fewer while the session is still filling — and returns the newest seq
   *  that has to go, or nothing at all, which ends the work here. The old
   *  `seq NOT IN (SELECT ... LIMIT 200)` form asked the same question by
   *  materialising the 200 survivors and testing every row against them,
   *  twice over, on every append: ~800 rows where this reads ~201.
   *
   *  That 201 is the largest line left in an append, and it is the one term
   *  that still scales with a cap — raising `maxEventsPerSession` raises it.
   *
   *  The deleted set is exactly `seq <= cutoff` for this session, so the
   *  eviction mark IS the cutoff — no second query to find the max of what
   *  went. */
  private trimSessionEvents(sessionId: string): void {
    const cutoff = this.ctx.storage.sql
      .exec<{ seq: number }>(
        `SELECT seq FROM event WHERE session_id = ? ORDER BY seq DESC LIMIT 1 OFFSET ?`,
        sessionId, MachineDO.maxEventsPerSession
      )
      .toArray()[0]?.seq;
    if (typeof cutoff !== "number") return;
    this.noteEviction(sessionId, cutoff);
    this.ctx.storage.sql.exec(
      `DELETE FROM event WHERE session_id = ? AND seq <= ?`, sessionId, cutoff
    );
  }

  /** Drop whole sessions past `maxSessions`, least recently written first.
   *
   *  Ordering happens over `session`, which holds one row per live session,
   *  rather than over `event`, which holds up to `maxSessions ×
   *  maxEventsPerSession` of them. Same verdict, ~400× fewer rows read
   *  (16,040 → 40, measured — 2 per row, the scan plus the sort).
   *
   *  It runs on every append, including the overwhelming majority that add no
   *  session. Gating it on "was this session id new" the way `noteEviction`
   *  is gated would take those 40 rows to 1; it is left ungated here because
   *  40 is bounded by `maxSessions` and the gate would need the same
   *  wake-time backstop the mark cap now carries.
   *
   *  `LIMIT -1` is SQLite's "no limit", so the OFFSET names every session
   *  past the cap — all of them, which matters on the first append after
   *  `maxSessions` is lowered. Nothing sheds sessions at wake time; that
   *  asymmetry with the mark cap is deliberate, because only the mark cap
   *  lost its per-append enforcement to a gate. The ordering is total and the choice deterministic because
   *  `event.seq` is a single global AUTOINCREMENT, so no two sessions can
   *  share a `last_seq`. */
  private trimSessions(): void {
    const doomed = this.ctx.storage.sql
      .exec<{ session_id: string }>(
        `SELECT session_id FROM session ORDER BY last_seq DESC LIMIT -1 OFFSET ?`,
        MachineDO.maxSessions
      )
      .toArray();
    for (const row of doomed) {
      // What this session actually still has, not what it once reached: a
      // mark has to cover the rows being deleted here and nothing beyond.
      const through = this.ctx.storage.sql
        .exec<{ seq: number | null }>(
          `SELECT MAX(seq) AS seq FROM event WHERE session_id = ?`, row.session_id
        )
        .toArray()[0]?.seq;
      if (typeof through === "number") this.noteEviction(row.session_id, through);
      this.ctx.storage.sql.exec(`DELETE FROM event WHERE session_id = ?`, row.session_id);
      this.ctx.storage.sql.exec(`DELETE FROM session WHERE session_id = ?`, row.session_id);
    }
  }

  /** Raise one session's eviction mark to `through`.
   *
   *  `MAX(through, excluded.through)` rather than a plain assignment: marks
   *  only ever move forward. A later trim of a session that has since been
   *  re-seeded selects lower seqs, and letting it overwrite would retire a
   *  mark that is still true. */
  private noteEviction(sessionId: string, through: number): void {
    // **The check, not the trim, is what runs on the hot path.** A session
    // sitting at `maxEventsPerSession` writes a mark on EVERY append — that
    // is the steady state this whole file is about — and the mark it writes
    // is almost always an update to a row that already exists. Only an
    // INSERT of a new session id can push the table over its cap, so this
    // one-row primary-key lookup decides whether `trimEvictionMarks` needs
    // to run at all, and the answer is normally no.
    //
    // Measured, with all three caps full: the trim reads ~405 rows to delete
    // nothing — 62% of the append that inserts a session's FIRST mark, and
    // the whole reason the ungated version cost 651 rather than 248. Running it unconditionally
    // here — which is what the first version of this fix did — left the last
    // full-table scan sitting on the append path, in a PR whose entire
    // subject is full-table scans on the append path.
    //
    // **The gate is only as good as the mark surviving.** `trimEvictionMarks`
    // ranks by `through`, which is a seq, so a long-lived session at the cap
    // — whose `through` trails 200 of its own events behind — can be outranked
    // by 200 short sessions evicted since, and lose the mark it just wrote.
    // Then `known` is false again on the next append and the ~400 rows come
    // back. That ordering predates this change and behaves identically on
    // `main` (measured), where it costs the mark itself: the session reports
    // `evictedThrough: 0` for events it really dropped. Fixing the ordering is
    // a separate job; this comment exists so the next person measuring 651
    // knows where to look.
    const known = this.ctx.storage.sql
      .exec(`SELECT 1 FROM eviction WHERE session_id = ?`, sessionId)
      .toArray().length > 0;
    this.ctx.storage.sql.exec(
      `INSERT INTO eviction (session_id, through) VALUES (?, ?)
       ON CONFLICT(session_id) DO UPDATE SET through = MAX(through, excluded.through)`,
      sessionId, through
    );
    if (!known) this.trimEvictionMarks();
  }

  /** Keep the mark table bounded.
   *
   *  It holds a row per session ever evicted, including sessions with no
   *  events left, so nothing else prunes it. Dropping the lowest marks first
   *  means what is lost is the oldest history, and losing a mark degrades to
   *  reporting NO gap — the same silence as before this existed, and only
   *  for a session that fell out of the buffer `maxEvictionMarks` sessions
   *  ago. Under-reporting is the safe direction; the alternative is claiming
   *  a hole in a conversation that never had one. */
  private trimEvictionMarks(): void {
    this.ctx.storage.sql.exec(
      `DELETE FROM eviction WHERE session_id IN (
         SELECT session_id FROM eviction ORDER BY through DESC LIMIT -1 OFFSET ?
       )`,
      MachineDO.maxEvictionMarks
    );
  }

  /** Everything after `after` for one session, plus what it takes to know
   *  whether anything in that range was dropped.
   *
   *  See `EventsResponse` for why the verdict rides on `evictedThrough` and
   *  `since` rather than on `oldestSeq`, which cannot answer it. */
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
    const evicted = this.ctx.storage.sql
      .exec<{ through: number | null }>(
        `SELECT through FROM eviction WHERE session_id = ?`, sessionId
      )
      .toArray();
    return {
      type: "events",
      sessionId,
      oldestSeq: oldest[0]?.seq ?? 0,
      since: after,
      evictedThrough: evicted[0]?.through ?? 0,
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
