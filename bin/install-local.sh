#!/bin/sh
# Reinstall this checkout into the running Kimi Code server.
# The bearer token is read here, inside the script, so it never appears in a
# tool call or a shell history line.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
home=${KIMI_CODE_HOME:-$HOME/.kimi-code}
token_file=$home/server.token
port=${KIMI_WEB_PORT:-58627}

if [ ! -r "$token_file" ]; then
  echo "install-local: no server token at $token_file (is 'kimi web' running?)" >&2
  exit 1
fi

token=$(cat "$token_file")
body=$(printf '{"source":"%s"}' "$root")

curl -sS -X POST "http://127.0.0.1:$port/api/v1/plugins" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d "$body" >/dev/null || {
  echo "install-local: request failed (is the server on port $port?)" >&2
  exit 1
}

curl -sS "http://127.0.0.1:$port/api/v1/plugins" \
  -H "Authorization: Bearer $token" |
  python3 -c '
import json, sys
want = sys.argv[1]
def walk(o):
    if isinstance(o, dict):
        if o.get("id") == want and "state" in o:
            print("installed %s  version %s  state %s  skills %s  mcp %s  hooks %s  commands %s  errors %s"
                  % (o["id"], o.get("version"), o.get("state"), o.get("skillCount"),
                     o.get("mcpServerCount"), o.get("hookCount"), o.get("commandCount"),
                     o.get("hasErrors")))
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(json.load(sys.stdin))
' codebase-memory
