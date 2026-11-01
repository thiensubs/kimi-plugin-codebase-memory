#!/usr/bin/env bash
# tests/test-cbm-nudge.sh — cbm_nudge behaviour on real kimi-code hook payloads.
#
# Fixtures are generated under .tmp/build-layer-nudge/payloads/ and use the
# payload shape kimi-code sends: "prompt" is an array of content blocks, not a
# string. The binary under test is compiled fresh from c/cbm_nudge.c, so this
# catches a source regression independent of whatever is in bin/prebuilt/; any
# shipped binary is checked against the same fixtures too.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
src=$root/c/cbm_nudge.c
work=$root/.tmp/build-layer-nudge
bin=$work/bin/cbm_nudge

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  if [ -n "${2-}" ]; then printf '     %s\n' "$2"; fi
}
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

[ -f "$src" ] || { echo "test-cbm-nudge: missing $src" >&2; exit 1; }

case "$(uname -sm)" in
  "Darwin x86_64")                plat=darwin-x86_64 ;;
  "Darwin arm64"|"Darwin arm64e") plat=darwin-arm64 ;;
  "Linux x86_64")                 plat=linux-x86_64 ;;
  "Linux aarch64"|"Linux arm64"|"Linux arm64e") plat=linux-arm64 ;;
  *) echo "test-cbm-nudge: unsupported host: $(uname -sm)" >&2; exit 1 ;;
esac

# -- fixtures ----------------------------------------------------------
rm -rf "$work"
mkdir -p "$work/bin" "$work/payloads" "$work/home" "$work/out"

cat > "$work/payloads/structure.json" <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"test-session","cwd":"/Users/example/project","client_type":"kimi_code_cli","prompt":[{"type":"text","text":"Where is the 25 MiB body limit enforced?"}],"is_steer":false}
EOF

cat > "$work/payloads/chat.json" <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"test-session","cwd":"/Users/example/project","client_type":"kimi_code_cli","prompt":[{"type":"text","text":"Thanks, that looks good. Go ahead and publish it."}],"is_steer":false}
EOF

cat > "$work/payloads/structure-no-cwd.json" <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"test-session","client_type":"kimi_code_cli","prompt":[{"type":"text","text":"How is cmd_guard implemented?"}],"is_steer":false}
EOF

# -- build the binary under test ---------------------------------------
cc=
for candidate in "${CC:-}" cc clang /usr/bin/cc /usr/bin/clang; do
  [ -n "$candidate" ] || continue
  if command -v "$candidate" >/dev/null 2>&1; then cc=$candidate; break; fi
done
if [ -z "$cc" ]; then
  echo "test-cbm-nudge: no C compiler found" >&2
  exit 1
fi

if warnings=$("$cc" -O2 -std=c11 -Wall -Wextra "$src" -o "$bin" 2>&1); then
  if [ -z "$warnings" ]; then
    ok "cbm_nudge.c compiles with -Wall -Wextra and no warnings"
  else
    bad "cbm_nudge.c compiles with -Wall -Wextra and no warnings" "$warnings"
  fi
else
  bad "cbm_nudge.c compiles with -Wall -Wextra" "$warnings"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# -- helpers -----------------------------------------------------------
# run_as <binary> <payload> <stdout file> <stderr file>; returns the exit code
run_as() {
  KIMI_CODE_HOME="$work/home" "$1" < "$2" > "$3" 2> "$4"
}
lines_of() { wc -l < "$1" | tr -d ' '; }

# -- 1. structure question: the five-line nudge ------------------------
run_as "$bin" "$work/payloads/structure.json" "$work/out/structure" "$work/out/structure.err"
rc=$?
check_eq "structure question exits 0" "$rc" "0"
check_eq "structure question prints five lines" "$(lines_of "$work/out/structure")" "5"
check_eq "structure question writes nothing to stderr" "$(cat "$work/out/structure.err")" ""

head1=$(sed -n '1p' "$work/out/structure")
case $head1 in
  "[codebase graph] Structure question detected"*)
    ok "first line announces the graph reminder" ;;
  *)
    bad "first line announces the graph reminder" "got [$head1]" ;;
esac

if grep -q 'search_graph' "$work/out/structure" &&
   grep -q 'trace_path' "$work/out/structure" &&
   grep -q 'get_code_snippet' "$work/out/structure"; then
  ok "the reminder names search_graph, trace_path and get_code_snippet"
else
  bad "the reminder names search_graph, trace_path and get_code_snippet" "$(cat "$work/out/structure")"
fi

check_eq "last line carries the payload cwd" \
  "$(sed -n '5p' "$work/out/structure")" "  cwd: /Users/example/project"

# -- 2. plain chat: completely silent ----------------------------------
run_as "$bin" "$work/payloads/chat.json" "$work/out/chat" "$work/out/chat.err"
rc=$?
check_eq "plain chat exits 0" "$rc" "0"
check_eq "plain chat prints nothing" "$(cat "$work/out/chat")" ""
check_eq "plain chat has zero bytes of stdout" "$(wc -c < "$work/out/chat" | tr -d ' ')" "0"
check_eq "plain chat writes nothing to stderr" "$(cat "$work/out/chat.err")" ""

# -- 3. structure question without cwd: four lines ---------------------
run_as "$bin" "$work/payloads/structure-no-cwd.json" "$work/out/no-cwd" "$work/out/no-cwd.err"
rc=$?
check_eq "structure question without cwd exits 0" "$rc" "0"
check_eq "structure question without cwd prints four lines" "$(lines_of "$work/out/no-cwd")" "4"
if grep -q 'cwd:' "$work/out/no-cwd"; then
  bad "no cwd line when the payload has no cwd" "$(cat "$work/out/no-cwd")"
else
  ok "no cwd line when the payload has no cwd"
fi

# -- 4. well-formed payloads do not touch the log ----------------------
if [ -e "$work/home/logs/cbm-nudge.log" ]; then
  bad "valid payloads do not log" "$(cat "$work/home/logs/cbm-nudge.log")"
else
  ok "valid payloads do not log"
fi

# -- 5. shipped binaries behave the same -------------------------------
for candidate in "$root/bin/prebuilt/$plat/cbm_nudge" "$root/bin/cbm_nudge"; do
  if [ ! -e "$candidate" ]; then
    echo "# skip $candidate (not built; run ./build-c.sh)"
    continue
  fi
  run_as "$candidate" "$work/payloads/structure.json" "$work/out/shipped" "$work/out/shipped.err"
  rc=$?
  label=${candidate#"$root/"}
  check_eq "$label structure question prints five lines" \
    "$(lines_of "$work/out/shipped")" "5"
  check_eq "$label exits 0" "$rc" "0"

  run_as "$candidate" "$work/payloads/chat.json" "$work/out/shipped-chat" "$work/out/shipped-chat.err"
  check_eq "$label stays silent on plain chat" \
    "$(wc -c < "$work/out/shipped-chat" | tr -d ' ')" "0"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  rm -rf "$work"
fi
[ "$fail" -eq 0 ]
