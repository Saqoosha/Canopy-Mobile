#!/bin/bash
# Push the relay's Cloudflare secrets from the 1Password mount.
#
# Reads worker/.dev.vars — a symlink to the Canopy-Mobile Environment's FIFO
# (see .1password/environments.toml) — and pipes each value into
# `wrangler secret put`. Values move file→process only; nothing here echoes,
# and `set -x` must never be added.
#
# Why this exists: the relay's ANTHROPIC_API_KEY sat invalid for an unknown
# time (api.anthropic.com returned 401) and nothing noticed, because the
# secret lived only in Cloudflare. With the Environment as the source, a
# rotation is one edit in 1Password plus this script.
set -euo pipefail
cd "$(dirname "$0")/../worker"
MOUNT=.dev.vars
[ -p "$MOUNT" ] || [ -L "$MOUNT" ] || { echo "no mount at worker/$MOUNT — see .1password/environments.toml" >&2; exit 1; }

value() { grep -E "^$1=" "$MOUNT" | head -1 | cut -d= -f2-; }

put() {   # put NAME [transform]
  local name="$1" v
  v="$(value "$name")"
  if [ -z "$v" ]; then echo "SKIP  $name (empty in the Environment)"; return; fi
  if [ "${2:-}" = b64 ]; then v="$(printf '%s' "$v" | base64 -d)"; fi
  if printf '%s' "$v" | npx wrangler secret put "${3:-$name}" >/dev/null 2>&1; then
    echo "PASS  ${3:-$name}"
  else
    echo "FAIL  ${3:-$name}" >&2; return 1
  fi
}

put ANTHROPIC_API_KEY
put SHARED_SECRET
put APNS_AUTH_KEY_B64 b64 APNS_AUTH_KEY
