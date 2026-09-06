// End-to-end check against the DEPLOYED relay: a publisher socket sends an
// event, a watcher socket must receive it with a seq, and a backfill request
// must come back with the same event and an oldestSeq.
//
// Uses a throwaway machine id so the real roster's PANES are untouched.
//
// **It does not leave nothing behind.** `/publish` writes `machine:<id>` into
// the MACHINES KV namespace, which is exactly what the phone lists, so every
// run adds a "PROBE-…" entry to the app's machine list — observed on device.
// Clean it up afterwards, or the list fills with them:
//
//   npx wrangler kv key delete --binding MACHINES --remote "machine:PROBE-<id>"
//
// The secret is read from the keychain inside this process and never printed.
import { execFileSync } from "node:child_process";

const SECRET = execFileSync("/usr/bin/security",
  ["find-generic-password", "-s", "sh.saqoo.Canopy.roster", "-w"],
  { encoding: "utf8" }).trim();

const HOST = "wss://canopy-mobile-relay.saqoosha.workers.dev";
const MACHINE = `PROBE-${Date.now()}`;
const headers = { Authorization: `Bearer ${SECRET}` };

function open(path) {
  const ws = new WebSocket(`${HOST}${path}?machine=${MACHINE}`, { headers });
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(ws));
    ws.addEventListener("error", (e) => reject(new Error(`open ${path}: ${e.message ?? e}`)));
  });
}

function nextMessage(ws, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timed out waiting for a frame")), timeoutMs);
    ws.addEventListener("message", (e) => { clearTimeout(timer); resolve(JSON.parse(e.data)); },
                        { once: true });
  });
}

const fail = [];
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : ` — ${detail}`}`);
  if (!ok) fail.push(name);
}

const watcher = await open("/watch");
const publisher = await open("/publish");

const event = {
  type: "event",
  eventId: "probe-e1",
  sessionId: "probe-session",
  resumeId: null,
  kind: "assistant",
  text: "hello from the probe",
  at: 778000000.5,
};

const live = nextMessage(watcher);
publisher.send(JSON.stringify(event));
const got = await live;

check("a watcher receives a published event", got.type === "event", JSON.stringify(got));
check("the relay stamped a seq", typeof got.seq === "number", JSON.stringify(got.seq));
check("the text survived the round trip", got.text === event.text, got.text);
check("the timestamp survived as sent", got.at === event.at, String(got.at));

const page = nextMessage(watcher);
watcher.send(JSON.stringify({ type: "events_since", sessionId: "probe-session", seq: 0 }));
const backfill = await page;

check("a backfill answers with an events page", backfill.type === "events", JSON.stringify(backfill));
check("the backfill holds the event", backfill.events?.length === 1, String(backfill.events?.length));
check("the backfill reports an oldestSeq", typeof backfill.oldestSeq === "number",
      String(backfill.oldestSeq));
check("asking from the newest seq returns nothing", true);

const empty = nextMessage(watcher);
watcher.send(JSON.stringify({ type: "events_since", sessionId: "probe-session", seq: got.seq }));
const after = await empty;
check("nothing follows the newest seq", after.events?.length === 0, String(after.events?.length));

// A malformed event must not be stored and must not reach the watcher.
publisher.send(JSON.stringify({ type: "event", eventId: "bad", kind: "assistant", text: "x", at: 0 }));
const stillEmpty = nextMessage(watcher);
watcher.send(JSON.stringify({ type: "events_since", sessionId: "probe-session", seq: got.seq }));
const afterBad = await stillEmpty;
check("a malformed event is not stored", afterBad.events?.length === 0,
      String(afterBad.events?.length));

watcher.close();
publisher.close();
console.log(`--- ${fail.length === 0 ? "all passed" : `${fail.length} failed`} ---`);
process.exit(fail.length === 0 ? 0 : 1);
