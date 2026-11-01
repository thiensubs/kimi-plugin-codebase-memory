#!/usr/bin/env bash
# Sampled allocation self-check (c/selfcheck.h) in both hook binaries.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work="$root/.tmp/selfcheck-tests.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

sg="$work/secret_guard"
nudge="$work/cbm_nudge"
for t in secret_guard cbm_nudge; do
  if ! clang -O2 -std=c11 -Wall -Wextra "$root/c/$t.c" -o "$work/$t" 2>"$work/$t.build"; then
    echo "FAIL build $t"
    sed -n '1,10p' "$work/$t.build"
    exit 1
  fi
done
if [ -s "$work/secret_guard.build" ] && grep -q 'warning:' "$work/secret_guard.build"; then
  bad "secret_guard builds without warnings" "$(head -2 "$work/secret_guard.build")"
else
  ok
fi
if [ -s "$work/cbm_nudge.build" ] && grep -q 'warning:' "$work/cbm_nudge.build"; then
  bad "cbm_nudge builds without warnings" "$(head -2 "$work/cbm_nudge.build")"
else
  ok
fi

allow='{"tool_name":"Read","tool_input":{"path":"README.md"}}'
state() { echo "$work/counter"; }

# -- 1. runs 1-9 stay silent, run 10 writes the ok line ---------------------
rm -f "$work/counter" "$work/counter.log"
out=""
for _ in $(seq 1 9); do
  out="$out$(printf '%s' "$allow" | SG_SELFCHECK_STATE="$(state)" "$sg")"
done
[ -z "$out" ] && ok || bad "runs 1-9 print nothing" "$out"
[ -f "$work/counter.log" ] && bad "no log before the 10th run" || ok

tenth=$(printf '%s' "$allow" | SG_SELFCHECK_STATE="$(state)" "$sg")
if [ -z "$tenth" ] && grep -q 'selfcheck ok' "$work/counter.log" 2>/dev/null; then ok
else bad "10th run logs selfcheck ok" "$(cat "$work/counter.log" 2>/dev/null)"; fi

if grep -qE 'allocs=[0-9]+ frees=[0-9]+' "$work/counter.log" 2>/dev/null; then ok
else bad "log reports alloc and free counts"; fi

# -- 2. sampling repeats at 20, not at 11 ----------------------------------
n11=$(printf '%s' "$allow" | SG_SELFCHECK_STATE="$(state)" "$sg")
[ -z "$n11" ] && ok || bad "run 11 is silent"
for _ in $(seq 12 19); do printf '%s' "$allow" | SG_SELFCHECK_STATE="$(state)" "$sg" >/dev/null; done
lines_before=$(wc -l < "$work/counter.log")
printf '%s' "$allow" | SG_SELFCHECK_STATE="$(state)" "$sg" >/dev/null
lines_after=$(wc -l < "$work/counter.log")
[ "$lines_after" -gt "$lines_before" ] && ok || bad "run 20 samples again" "$lines_before -> $lines_after"

# -- 3. a planted leak produces a report the user can paste ----------------
printf '9\n' > "$work/leak-counter"
rm -f "$work/leak-counter.log"
report=$(printf '%s' "$allow" | SG_SELFCHECK_STATE="$work/leak-counter" SG_SELFTEST_LEAK=1 "$sg")
case "$report" in
  *'"message"'*'self-check found a leak'*'live='*) ok ;;
  *) bad "secret_guard prints a JSON message on a leak" "$report" ;;
esac
case "$report" in
  *'https://github.com/thiensubs/kimi-plugin-codebase-memory/issues'*) ok ;;
  *) bad "leak message names the issue tracker" ;;
esac
grep -q 'selfcheck LEAK' "$work/leak-counter.log" 2>/dev/null && ok || bad "leak also lands in the log"

printf '9\n' > "$work/nudge-counter"
nreport=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":[{"type":"text","text":"who calls main"}]}' \
  | SG_SELFCHECK_STATE="$work/nudge-counter" SG_SELFTEST_LEAK=1 "$nudge")
case "$nreport" in
  *'cbm_nudge self-check'*'leak detected'*) ok ;;
  *) bad "cbm_nudge prints a plain-text leak report" "$nreport" ;;
esac

# -- 4. versions match the manifest ---------------------------------------
manifest=$(python3 -c 'import json;print(json.load(open("'"$root"'/kimi.plugin.json"))["version"])')
for t in secret_guard cbm_nudge; do
  declared=$(grep -oE 'SG_VERSION "[0-9]+\.[0-9]+\.[0-9]+"' "$root/c/$t.c" | head -1 | cut -d'"' -f2)
  if [ "$declared" = "$manifest" ]; then ok; else bad "$t SG_VERSION matches manifest" "$declared != $manifest"; fi
done

# -- 5. a corrupt counter is not a crash ----------------------------------
printf 'not-a-number\n' > "$work/bad-counter"
printf '%s' "$allow" | SG_SELFCHECK_STATE="$work/bad-counter" "$sg" >/dev/null 2>&1
rc=$?
[ "$rc" = "0" ] && ok || bad "corrupt counter does not crash (rc=$rc)"

# -- 6. an unwritable state path still allows the call --------------------
printf '%s' "$allow" | SG_SELFCHECK_STATE="/nonexistent-dir/counter" "$sg" >/dev/null 2>&1
rc=$?
[ "$rc" = "0" ] && ok || bad "unwritable state path still exits 0 (rc=$rc)"

# -- 7. the check never changes a block decision --------------------------
printf '9\n' > "$work/block-counter"
printf '{"tool_name":"Bash","tool_input":{"command":"cat /Users/x/.kimi-code/config.toml"}}' \
  | SG_SELFCHECK_STATE="$work/block-counter" SG_SELFTEST_LEAK=1 "$sg" >/dev/null 2>&1
rc=$?
[ "$rc" = "2" ] && ok || bad "sampled run still blocks with exit 2 (rc=$rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
