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
  /** Canopy's id for the streamed event carrying this same text.
   *
   *  **Must be forwarded into the push payload, not just accepted here.** The
   *  phone de-duplicates a completed notification against the event stream on
   *  this field alone, and a relay that takes it and drops it produces exactly
   *  the symptom it exists to prevent: the assistant's message drawn twice,
   *  once from each route. Measured on device. */
  eventId?: string;
  /** Whether the CLI proposed a rule for this ask, so the phone can offer
   *  "Always" only when there is something to write. */
  allowAlways?: boolean;
  /** False for an ask that Allow/Deny cannot resolve (an AskUserQuestion,
   *  whose answer is a chosen option). The phone then shows it without
   *  Allow/Deny — and, when `choices` is present, with those instead. */
  answerable?: boolean;
  /** An AskUserQuestion's form: what the phone draws buttons from. Present
   *  exactly when `answerable` is false. Rides in the push for the same
   *  reason `bodyFull` does — the Notification Service Extension stores the
   *  notification and has no credential to fetch anything. */
  choices?: AskChoice[];
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
/** One question of an AskUserQuestion, as the phone renders it. */
export interface AskOption {
  label: string;
  /** The model's own explanation of this option. Carried, not dropped: on a
   *  question with terse labels it is the entire difference between them, and
   *  the phone no longer prints the tool's raw input above the form, so this
   *  is the only copy that reaches the user. When the form makes the push too
   *  large, `fitPushPayload` drops `choices` wholesale and the body — which
   *  still has the descriptions — is shown instead. */
  description?: string;
}

export interface AskChoice {
  question: string;
  header?: string;
  options: AskOption[];
  multiSelect: boolean;
}

export interface DecisionBody {
  machine: string;
  sessionId: string;
  /** Ties this decision to the request it answers. Required and never
   *  defaulted: applying a decision with no id to "whatever is outstanding"
   *  could approve a tool the user never saw. */
  requestId: string;
  decision: PermissionDecision;
  /** An AskUserQuestion's answer: the question's own text mapped to the
   *  chosen option labels joined with ", ". Passed through untouched — the
   *  relay cannot tell an ask from an ordinary permission request, and only
   *  the Mac holds the form to validate against. */
  answers?: Record<string, string>;
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
  /** See `DecisionBody.answers`. */
  answers?: Record<string, string>;
  /** See `ReplyEnvelope.deliveryId`. */
  deliveryId?: string;
}

/** One thing that happened in a session, as Canopy writes it to the
 *  publisher socket.
 *
 *  **`type` is the only thing separating this from a `MachineSnapshot` on
 *  that socket** — a snapshot carries no `type` field at all, so
 *  `webSocketMessage` branches on its presence. */
export interface SessionEventMessage {
  type: "event";
  /** Minted by Canopy, and also carried on the `completed` push so the phone
   *  can tell a notification and an event are the same turn. Distinct from
   *  `seq`, which the relay assigns and Canopy cannot know. */
  eventId: string;
  sessionId: string;
  resumeId: string | null;
  kind: "assistant" | "user" | "tool" | "turnStart" | "turnEnd";
  text: string;
  /** Seconds on Swift's reference date (2001), as `JSONEncoder` writes a
   *  `Date` by default. **Never mix an epoch-milliseconds value in here** —
   *  the phone decodes it straight back into a `Date`. */
  at: number;
}

/** A stored event on its way to a watcher: the message plus the relay's own
 *  ordering number. */
export interface StoredSessionEvent extends SessionEventMessage {
  seq: number;
}

/** The answer to a watcher's backfill request.
 *
 *  **`oldestSeq` is the load-bearing field.** It is the oldest seq the relay
 *  still holds for that session; when it is greater than what the watcher
 *  asked for, everything between is gone for good. Returning the events
 *  without it would let the phone splice a partial range onto what it has as
 *  if the two were contiguous. */
export interface EventsResponse {
  type: "events";
  sessionId: string;
  oldestSeq: number;
  events: StoredSessionEvent[];
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
