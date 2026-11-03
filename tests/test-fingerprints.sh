#!/usr/bin/env bash
# 40-bit known-secret fingerprint denylist: unit tests for c/secret_guard.c.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work="$root/.tmp/fp-tests.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

bin="$work/secret_guard"
if ! clang -O2 -std=c11 -Wall -Wextra "$root/c/secret_guard.c" -o "$bin" 2>"$work/build.log"; then
  echo "FAIL build"
  sed -n '1,20p' "$work/build.log"
  exit 1
fi

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

body=$(printf 'Aa0-%.0s' 1 2 3 4 5 6 7 8 9 10)
fake="Kq7z-${body}"
short="abc"
reg="$work/registry.txt"
export SECRET_GUARD_FINGERPRINTS="$reg"
export KIMI_CODE_HOME="$work/home"

fp() { printf '%s' "$1" | "$bin" fingerprint; }

# -- 1. fingerprint format --------------------------------------------------
out=$(fp "$fake")
case "$out" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok ;;
  *) bad "fingerprint is 10 lowercase hex chars" "got: $out" ;;
esac

# -- 2. interop with sha256(token)[:10] ------------------------------------
if command -v python3 >/dev/null 2>&1; then
  want=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:10])' "$fake")
  if [ "$out" = "$want" ]; then ok; else bad "matches python sha256 prefix" "want $want got $out"; fi
else
  echo "# skip python interop (no python3)"
fi

# -- 3. short tokens are not fingerprinted ---------------------------------
if [ -z "$(fp "$short")" ]; then ok; else bad "tokens under 16 chars ignored"; fi

# -- 4. dedupe --------------------------------------------------------------
lines=$(printf '%s %s %s\n' "$fake" "$fake" "$fake" | "$bin" fingerprint | wc -l | tr -d ' ')
if [ "$lines" = "1" ]; then ok; else bad "duplicate tokens collapse to one fingerprint" "got $lines lines"; fi

# -- 5. no registry: allow --------------------------------------------------
rm -f "$reg"
payload=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo %s"}}' "$fake")
if printf '%s' "$payload" | "$bin" >/dev/null 2>&1; then ok; else bad "allow when no registry exists"; fi

# -- 6. registered fingerprint blocks (strict mode) --------------------------
printf '%s\n' "$out" > "$reg"
SECRET_GUARD_MODE=strict "$bin" < <(printf '%s' "$payload") >"$work/out6" 2>"$work/err6"
rc=$?
if [ "$rc" = "2" ]; then ok; else bad "registered fingerprint blocks (exit 2)" "rc=$rc"; fi
if grep -q 'known-secret' "$work/out6" "$work/err6" 2>/dev/null; then
  ok
else
  bad "deny reason names the rule" "$(head -c 200 "$work/out6")"
fi
if grep -q "$fake" "$work/out6" "$work/err6" 2>/dev/null; then
  bad "deny output must not echo the secret"
else
  ok
fi

# -- 7. unregistered value still allowed -----------------------------------
other=$(printf 'Zz9-%.0s' 1 2 3 4 5 6 7 8 9 10)
p2=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo %s"}}' "$other")
if printf '%s' "$p2" | "$bin" >/dev/null 2>&1; then ok; else bad "unregistered token is allowed"; fi

# -- 8. redact masks a registered fingerprint ------------------------------
masked=$(printf 'auth %s\n' "$fake" | "$bin" redact)
if [ "$masked" = "auth [REDACTED:known-secret]" ]; then ok; else bad "redact masks registered token" "got: $masked"; fi

# -- 9. registry parsing: comments, blanks, junk, uppercase (strict blocks) --
{
  echo "# provider keys that leaked on 2026-11-01"
  echo ""
  echo "not-a-fingerprint"
  echo "zzzzzzzzzz"
  printf '%s\n' "$(printf '%s' "$out" | tr 'a-f' 'A-F')"
} > "$reg"
SECRET_GUARD_MODE=strict "$bin" < <(printf '%s' "$payload") >/dev/null 2>&1
rc=$?
if [ "$rc" = "2" ]; then ok; else bad "uppercase fingerprint + junk lines still block" "rc=$rc"; fi

# -- 10. credential path is allowed only through the fingerprint pipe ------
cred='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat /Users/x/.kimi-code/config.toml"}}'
SECRET_GUARD_MODE=strict "$bin" < <(printf '%s' "$cred") >/dev/null 2>&1
rc=$?
if [ "$rc" = "2" ]; then ok; else bad "bare credential read stays blocked (strict)" "rc=$rc"; fi

pipe='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat /Users/x/.kimi-code/config.toml | ./bin/run secret_guard fingerprint"}}'
printf '%s' "$pipe" | "$bin" >/dev/null 2>&1
rc=$?
if [ "$rc" = "0" ]; then ok; else bad "credential read piped through fingerprint is allowed" "rc=$rc"; fi

# -- 11. fingerprint mode on a config-shaped file --------------------------
cat > "$work/config.toml" <<EOF
[provider]
api_key = "$fake"
model = "fast"
EOF
got=$("$bin" fingerprint < "$work/config.toml")
if [ "$got" = "$out" ]; then ok; else bad "config file yields the key fingerprint only" "got: $got"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
