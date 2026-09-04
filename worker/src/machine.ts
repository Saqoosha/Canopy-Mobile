import { DurableObject } from "cloudflare:workers";
import type { MachineSnapshot, ReplyEnvelope } from "./types";

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

  /** Writes a reply down the publisher socket, if one is connected.
   *
   *  Uses the sockets the Hibernation API hands back rather than any in-memory
   *  set: this DO may have hibernated since the publisher connected, and an
   *  in-memory list would be empty. The role comes from the attachment for the
   *  same reason. */
  deliverReply(envelope: ReplyEnvelope): boolean {
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
      const ok = this.deliverReply(envelope);
      return new Response(JSON.stringify({ ok }), {
        status: ok ? 200 : 503,
        headers: { "Content-Type": "application/json" },
      });
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

  webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): void {
    if (typeof message !== "string") return;
    const parsed = JSON.parse(message) as Partial<MachineSnapshot>;
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
