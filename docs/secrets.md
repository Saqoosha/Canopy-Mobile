# Relay secrets

The relay needs three secrets in Cloudflare: `ANTHROPIC_API_KEY` (the History
banner shortener), `SHARED_SECRET` (every authenticated route), and
`APNS_AUTH_KEY` (push signing).

They live in the 1Password Environment **Canopy-Mobile**, and Cloudflare is fed
from it — never the other way round.

## The mount

The Environment is mounted on the developer's machine at
`~/.claude/1p-mounts/canopy-mobile.env`, and `worker/.dev.vars` is a symlink to
it. That path is gitignored, and the mount is a FIFO, so no plaintext ever
lands in the repo. `wrangler dev` reads `.dev.vars` on its own, so a local run
needs no extra step.

`.1password/environments.toml` declares that mount so 1Password's own agent
hook can validate it.

`APNS_AUTH_KEY_B64` is stored base64-encoded because the `.p8` is multi-line
and a `.env` value is not.

## Pushing to Cloudflare

```bash
./scripts/worker-secrets.sh
```

It reads the mount and pipes each value into `wrangler secret put`. Values move
file→process only; the script prints `PASS` / `SKIP` / `FAIL` per name and
never a value. Do not add `set -x`.

## Rotating a key

Edit the value in 1Password, then run the script. Nothing else holds a copy.

## Why the source of truth moved

The relay's `ANTHROPIC_API_KEY` was invalid for an unknown length of time and
nothing noticed: `api.anthropic.com` answered 401, the shortener fell back to
truncating the notification body, and the fallback looks like a design choice
rather than a failure. The key existed only inside Cloudflare, where it could
not be read back or checked. With the Environment as the source, the key can be
verified from the machine and re-pushed in one command.

The failure is still silent in production — a 401 logs
`LLM shortener: Anthropic API error` and the banner degrades. To confirm the
path end to end, tail the worker and send a long `completed` notification;
a healthy run logs `LLM shortener: success`.
