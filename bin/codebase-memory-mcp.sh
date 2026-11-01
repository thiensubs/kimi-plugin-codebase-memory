#!/bin/sh
# Resolve the codebase-memory-mcp binary and exec it.
# Kimi Code may be launched from a GUI app with a minimal PATH, so a bare
# `codebase-memory-mcp` lookup is not reliable on macOS.
set -eu

for candidate in \
  "${CBM_BIN:-}" \
  "$(command -v codebase-memory-mcp 2>/dev/null || true)" \
  "$HOME/.local/bin/codebase-memory-mcp" \
  "$HOME/.cargo/bin/codebase-memory-mcp" \
  "/opt/homebrew/bin/codebase-memory-mcp" \
  "/usr/local/bin/codebase-memory-mcp"
do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    exec "$candidate" "$@"
  fi
done

echo "codebase-memory-mcp not found. Install it from https://github.com/DeusData/codebase-memory-mcp" >&2
echo "or set CBM_BIN=/absolute/path/to/codebase-memory-mcp" >&2
exit 127
