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
}

/** The only two legal values, captured from three real clicks in
 *  docs/superpowers/specs/2026-09-04-permission-response-capture.md
 *  (`response.result.behavior`). "Allow Always" is not a third value — it is
 *  `allow` plus a derived `updatedPermissions` rule — and is out of scope. */
export type PermissionDecision = "allow" | "deny";

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
