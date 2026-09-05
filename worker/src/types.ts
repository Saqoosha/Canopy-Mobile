/** One pane on one Mac. Mirrors RosterSnapshot.Pane in the Canopy repo. */
export interface PaneRow {
  /** OpenSession.ID as a UUID string. Stable for the life of the process. */
  sessionId: string;
  /** 0-based position in the pane strip. */
  paneIndex: number;
  title: string;
  /** "repo · branch", already composed by Canopy. */
  project: string;
  /** One of SessionActivity's seven cases, lowercased. */
  state: string;
  /** Unix seconds at which the pane entered `state`. */
  stateSince: number;
  contextPct: number;
  model: string;
  messageCount: number;
}

/** What Canopy posts to /notify. */
export interface NotifyBody {
  machine: string;
  /** OpenSession.ID as a UUID string — the same one the roster carries. */
  sessionId: string;
  title: string;
  body: string;
  /** Which activity raised this. Only these two push. */
  kind: "completed" | "asking";
  /** The full text, before any shortening. Rides in the push payload so the
   *  Notification Service Extension can store it — the extension has no
   *  credential to fetch anything with. */
  bodyFull?: string;
  /** Present only for `kind: "asking"`. The id the phone answers with. */
  requestId?: string;
  /** Whether the CLI proposed a rule for this ask, so the phone can offer
   *  "Always" only when there is something to write. */
  allowAlways?: boolean;
  /** False for an ask that Allow/Deny cannot resolve (an AskUserQuestion,
   *  whose answer is text). The phone then shows it without buttons. */
  answerable?: boolean;
  /** The CLI's own session id, stable across Canopy restarts. */
  resumeId?: string;
}

/** What the phone posts to /reply. */
export interface ReplyBody {
  machine: string;
  sessionId: string;
  text: string;
}

/** What the DO writes down the publisher socket. The `type` discriminator
 *  exists because that socket previously carried only snapshots in the other
 *  direction; Canopy must be able to tell a reply from anything added later. */
export interface ReplyEnvelope {
  type: "reply";
  sessionId: string;
  text: string;
  /** Correlates the Mac's acknowledgement with this delivery. Optional so a
   *  Canopy older than the ack protocol still parses the envelope; the relay
   *  then times out rather than hanging, and reports that honestly. */
  deliveryId?: string;
}

/** What Canopy sends back once it has tried to act on a delivery.
 *
 *  `ok: false` is the case this protocol exists for: the socket was alive, so
 *  the write "succeeded", but the Mac could not do anything with it — no such
 *  session, no live shim, or a shim that refused. Before this, all three were
 *  a 200 and a message the user believed they had sent. */
export interface DeliveryAck {
  type: "ack";
  deliveryId: string;
  ok: boolean;
  /** Why it failed, for the phone to show. Never conversation content. */
  reason?: string;
}

/** The only two legal values, captured from three real clicks in
 *  docs/superpowers/specs/2026-09-04-permission-response-capture.md
 *  (`response.result.behavior`). "Allow Always" is not a third value — it is
 *  `allow` plus a derived `updatedPermissions` rule — and is out of scope. */
/** "allowAlways" is not a third behavior on the wire — Canopy turns it into
 *  an `allow` carrying the rules the CLI itself proposed for this request
 *  (the extension's own button does exactly that). It stays a distinct value
 *  here so the relay refuses anything it has not seen, rather than
 *  normalizing an unknown decision into an approval. */
export type PermissionDecision = "allow" | "deny" | "allowAlways";

/** What the phone posts to /decide. */
export interface DecisionBody {
  machine: string;
  sessionId: string;
  /** Ties this decision to the request it answers. Required and never
   *  defaulted: applying a decision with no id to "whatever is outstanding"
   *  could approve a tool the user never saw. */
  requestId: string;
  decision: PermissionDecision;
}

/** What the DO writes down the publisher socket. A decision is not a reply
 *  — it answers a different Canopy affordance entirely — so it carries its
 *  own `type` rather than overloading ReplyEnvelope's, and a future third
 *  kind can't be confused with either. */
export interface DecisionEnvelope {
  type: "decision";
  sessionId: string;
  requestId: string;
  decision: PermissionDecision;
  /** See `ReplyEnvelope.deliveryId`. */
  deliveryId?: string;
}

export interface MachineSnapshot {
  /** IOPlatformUUID. Never the hostname. */
  machineId: string;
  displayName: string;
  /** Unix seconds when Canopy composed this snapshot. */
  publishedAt: number;
  sessionPct: number;
  weeklyPct: number;
  panes: PaneRow[];
}
