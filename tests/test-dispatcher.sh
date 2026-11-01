#!/usr/bin/env bash
# tests/test-dispatcher.sh — prove bin/run.sh dispatches, compiles and fails open.
#
# The checks run against a throwaway plugin root in .tmp/ (real bin/run.sh
# copied in, fake c/ and bin/prebuilt/) so nothing here touches the plugin's
# own c/ or bin/prebuilt/ tree. One final check drives the real dispatcher and
# the real cbm_nudge end to end.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
run_sh=$root/bin/run.sh
work=$root/.tmp/build-layer-dispatcher

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  if [ -n "${2-}" ]; then printf '     %s\n' "$2"; fi
}
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

[ -x "$run_sh" ] || { echo "test-dispatcher: $run_sh missing or not executable" >&2; exit 1; }

case "$(uname -sm)" in
  "Darwin x86_64")                plat=darwin-x86_64 ;;
  "Darwin arm64"|"Darwin arm64e") plat=darwin-arm64 ;;
  "Linux x86_64")                 plat=linux-x86_64 ;;
  "Linux aarch64"|"Linux arm64"|"Linux arm64e") plat=linux-arm64 ;;
  *) echo "test-dispatcher: unsupported host: $(uname -sm)" >&2; exit 1 ;;
esac

# -- fixture plugin root ----------------------------------------------
rm -rf "$work"
mkdir -p "$work/plugin/bin/prebuilt/$plat" "$work/plugin/c" \
         "$work/home" "$work/cache/prebuilt" "$work/cache/compile" \
         "$work/cache/noc" "$work/cache/real" "$work/bin-min" "$work/bin-empty"
cp "$run_sh" "$work/plugin/bin/run.sh"
chmod +x "$work/plugin/bin/run.sh"

cat > "$work/plugin/c/test_probe.c" <<'EOF'
#include <stdio.h>

int main(void) {
    fputs("compiled\n", stdout);
    return 0;
}
EOF

prebuilt=$work/plugin/bin/prebuilt/$plat/test_probe
cat > "$prebuilt" <<'EOF'
#!/bin/sh
printf 'prebuilt'
for arg in "$@"; do printf ':%s' "$arg"; done
printf '\n'
EOF
chmod +x "$prebuilt"

disp=$work/plugin/bin/run.sh

# -- 1. prebuilt wins over the compiler --------------------------------
out=$(XDG_CACHE_HOME=$work/cache/prebuilt KIMI_CODE_HOME=$work/home "$disp" test_probe 2>&1)
rc=$?
check_eq "prebuilt binary is used when present" "$out" "prebuilt"
check_eq "prebuilt run exits 0" "$rc" "0"
if [ -e "$work/cache/prebuilt/kimi-plugin-codebase-memory/$plat/test_probe" ]; then
  bad "prebuilt run does not compile" "a cache binary was created"
else
  ok "prebuilt run does not compile"
fi

out=$(XDG_CACHE_HOME=$work/cache/prebuilt KIMI_CODE_HOME=$work/home "$disp" test_probe alpha "b c")
check_eq "extra arguments reach the binary" "$out" "prebuilt:alpha:b c"

# -- 2. root resolution through a symlink ------------------------------
ln -sf "$disp" "$work/link-run.sh"
out=$(XDG_CACHE_HOME=$work/cache/prebuilt KIMI_CODE_HOME=$work/home "$work/link-run.sh" test_probe)
check_eq "symlinked dispatcher still finds the plugin root" "$out" "prebuilt"
rm -f "$work/link-run.sh"

# -- 3. no prebuilt: compile from c/<tool>.c ---------------------------
rm -f "$prebuilt"
out=$(XDG_CACHE_HOME=$work/cache/compile KIMI_CODE_HOME=$work/home "$disp" test_probe 2>&1)
rc=$?
check_eq "compiles c/test_probe.c when the prebuilt is gone" "$out" "compiled"
check_eq "compiled run exits 0" "$rc" "0"
cached=$work/cache/compile/kimi-plugin-codebase-memory/$plat/test_probe
if [ -x "$cached" ]; then
  ok "compiled binary is cached under XDG_CACHE_HOME"
else
  bad "compiled binary is cached under XDG_CACHE_HOME" "missing $cached"
fi

# -- 4. the cache survives source removal ------------------------------
mv "$work/plugin/c/test_probe.c" "$work/test_probe.c.bak"
out=$(XDG_CACHE_HOME=$work/cache/compile KIMI_CODE_HOME=$work/home "$disp" test_probe)
check_eq "cached binary is reused when the source is gone" "$out" "compiled"
mv "$work/test_probe.c.bak" "$work/plugin/c/test_probe.c"

# -- 5. a newer source invalidates the cache ---------------------------
cat > "$work/plugin/c/test_probe.c" <<'EOF'
#include <stdio.h>

int main(void) {
    fputs("recompiled\n", stdout);
    return 0;
}
EOF
touch -t 203001010000 "$work/plugin/c/test_probe.c"
out=$(XDG_CACHE_HOME=$work/cache/compile KIMI_CODE_HOME=$work/home "$disp" test_probe 2>&1)
check_eq "a newer source rebuilds the cached binary" "$out" "recompiled"
rm -f "$cached"

# restore the plain probe, no source in the way for the failure tests
cat > "$work/plugin/c/test_probe.c" <<'EOF'
#include <stdio.h>

int main(void) {
    fputs("compiled\n", stdout);
    return 0;
}
EOF

# -- 6. exit 2 is passed through, not swallowed ------------------------
# 0 means allow and 2 means block; a wrapper that returned 0 for a blocking
# tool would silently disable the guard.
cat > "$work/plugin/c/exit2_probe.c" <<'EOF'
int main(void) {
    return 2;
}
EOF
out=$(XDG_CACHE_HOME=$work/cache/compile KIMI_CODE_HOME=$work/home "$disp" exit2_probe 2>&1)
rc=$?
check_eq "compiled tool keeps exit 2" "$rc" "2"
check_eq "compiled tool adds no output" "$out" ""

cat > "$work/plugin/bin/prebuilt/$plat/exit2_probe" <<'EOF'
#!/bin/sh
exit 2
EOF
chmod +x "$work/plugin/bin/prebuilt/$plat/exit2_probe"
out=$(XDG_CACHE_HOME=$work/cache/prebuilt KIMI_CODE_HOME=$work/home "$disp" exit2_probe 2>&1)
rc=$?
check_eq "prebuilt tool keeps exit 2" "$rc" "2"
check_eq "prebuilt tool adds no output" "$out" ""

# -- 7. no compiler: exit 0, silent, one log line ----------------------
for util in uname mkdir mv rm date tr; do
  ln -sf "$(command -v "$util")" "$work/bin-min/$util"
done
rm -f "$work/home/logs/test-probe.log"

out=$(env -u CC PATH="$work/bin-min" XDG_CACHE_HOME="$work/cache/noc" \
        KIMI_CODE_HOME="$work/home" "$disp" test_probe 2>"$work/noc.err")
rc=$?
check_eq "exits 0 with no compiler and no prebuilt" "$rc" "0"
check_eq "prints nothing when it cannot build" "$out" ""
check_eq "writes nothing to stderr when it cannot build" "$(cat "$work/noc.err")" ""

log=$work/home/logs/test-probe.log
if [ -s "$log" ]; then
  ok "logs one line to KIMI_CODE_HOME/logs/test-probe.log"
else
  bad "logs one line to KIMI_CODE_HOME/logs/test-probe.log" "missing or empty: $log"
fi
if [ -f "$log" ]; then
  check_eq "the log holds exactly one line" "$(wc -l < "$log" | tr -d ' ')" "1"
  if grep -q "test_probe" "$log" && grep -q "no C compiler" "$log"; then
    ok "the log line names the tool and the reason"
  else
    bad "the log line names the tool and the reason" "$(cat "$log")"
  fi
fi

# -- 7. nothing works at all: still exit 0, still silent ---------------
out=$(env -u CC PATH="$work/bin-empty" XDG_CACHE_HOME="$work/cache/noc" \
        KIMI_CODE_HOME="$work/home" "$disp" test_probe 2>&1)
rc=$?
check_eq "exits 0 with an empty PATH" "$rc" "0"
check_eq "stays silent with an empty PATH" "$out" ""

# -- 7b. unwritable cache: exit 0 and one log line ---------------------
: > "$work/cache-file"
out=$(XDG_CACHE_HOME="$work/cache-file" KIMI_CODE_HOME="$work/home2" \
        "$disp" test_probe 2>&1)
rc=$?
check_eq "exits 0 when the cache path is not a directory" "$rc" "0"
check_eq "stays silent when the cache path is not a directory" "$out" ""
if grep -q "not writable" "$work/home2/logs/test-probe.log" 2>/dev/null; then
  ok "logs the unwritable cache"
else
  bad "logs the unwritable cache" "$(cat "$work/home2/logs/test-probe.log" 2>/dev/null)"
fi

# -- 7c. no HOME and no cache: exit 0, silent -------------------------
out=$(env -u HOME -u XDG_CACHE_HOME -u KIMI_CODE_HOME PATH="$work/bin-min" \
        "$disp" test_probe 2>&1)
rc=$?
check_eq "exits 0 with no HOME and no cache" "$rc" "0"
check_eq "stays silent with no HOME and no cache" "$out" ""

# -- 8. hostile tool names are rejected --------------------------------
for name in '../evil' 'a/b' 'a;echo pwned' '.*' ''; do
  out=$("$disp" "$name" 2>&1)
  rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then
    ok "rejects tool name [$name]"
  else
    bad "rejects tool name [$name]" "rc=$rc output=[$out]"
  fi
done

# -- 9. POSIX syntax ---------------------------------------------------
for shell in /bin/sh /bin/dash; do
  [ -x "$shell" ] || continue
  if "$shell" -n "$run_sh" 2>"$work/syntax.err"; then
    ok "parses with $shell"
  else
    bad "parses with $shell" "$(cat "$work/syntax.err")"
  fi
done

if command -v dash >/dev/null 2>&1; then
  out=$(cd "$work/plugin" && XDG_CACHE_HOME=$work/cache/prebuilt \
          KIMI_CODE_HOME=$work/home dash bin/run.sh test_probe 2>&1)
  check_eq "runs under dash" "$out" "compiled"
else
  echo "# skip dash run (dash not installed)"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if out=$(shellcheck -s sh -S warning "$run_sh" 2>&1); then
    ok "shellcheck -s sh -S warning is clean"
  else
    bad "shellcheck -s sh -S warning is clean" "$out"
  fi
else
  echo "# skip shellcheck (not installed)"
fi

# -- 10. a plugin root with spaces -------------------------------------
spaced="$work/with space"
mkdir -p "$spaced"
cp -R "$work/plugin" "$spaced/plugin"
out=$(XDG_CACHE_HOME="$work/cache with space" KIMI_CODE_HOME="$work/home" \
        "$spaced/plugin/bin/run.sh" test_probe 2>&1)
rc=$?
check_eq "plugin root and cache path with spaces work" "$out" "compiled"
check_eq "plugin root with spaces exits 0" "$rc" "0"

# -- 11. real dispatcher, real tool ------------------------------------
payload=$work/payload.json
cat > "$payload" <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"test","cwd":"/Users/example/project","client_type":"kimi_code_cli","prompt":[{"type":"text","text":"Who calls cmd_guard and what does it call?"}],"is_steer":false}
EOF

out=$(XDG_CACHE_HOME=$work/cache/real KIMI_CODE_HOME=$work/home "$run_sh" cbm_nudge < "$payload")
rc=$?
case $out in
  *"[codebase graph]"*) ok "real dispatcher runs cbm_nudge end to end" ;;
  *) bad "real dispatcher runs cbm_nudge end to end" "output: [$out]" ;;
esac
check_eq "real dispatcher exits 0" "$rc" "0"
check_eq "real dispatcher adds no output of its own" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "5"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  rm -rf "$work"
fi
[ "$fail" -eq 0 ]
