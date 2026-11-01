#!/usr/bin/env bash
# Proves the README's claims: referenced paths exist, shell examples are
# cwd-independent, the documented pipelines run, and the install-line counts
# match the manifest.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
readme="$root/README.md"
work="$root/.tmp/readme-tests.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

# -- 1. every repo path the README names exists -----------------------------
missing=$(python3 - "$readme" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
pat = re.compile(r"`((?:bin|commands|skills|tests|c|\.github)/[A-Za-z0-9_./-]+)`")
seen, out = set(), []
for m in pat.finditer(text):
    p = m.group(1).rstrip("/")
    if any(ch in p for ch in "<>*$"):
        continue
    if p.startswith("bin/prebuilt/"):
        continue
    if p in seen:
        continue
    seen.add(p)
    out.append(p)
print("\n".join(out))
PY
)
checked=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  checked=$((checked + 1))
  if [ ! -e "$root/$rel" ]; then
    bad "README names a path that does not exist: $rel"
  fi
done <<< "$missing"
[ "$checked" -ge 5 ] && ok || bad "README path check found too few paths to be meaningful" "$checked"

# Prebuilt directories are release output, not tracked files, except the host
# one, which this checkout must still be able to build and ship.
host_os=$(uname -s | tr 'A-Z' 'a-z')
case "$(uname -m)" in
  arm64|aarch64) host_arch=arm64 ;;
  *) host_arch=x86_64 ;;
esac
host_dir="$root/bin/prebuilt/$host_os-$host_arch"
if [ -x "$host_dir/cbm_nudge" ] && [ -x "$host_dir/secret_guard" ]; then ok
else bad "host prebuilt directory is complete" "$host_dir"; fi

# -- 2. no shell example calls a relative ./bin/run -------------------------
badrel=$(python3 - "$readme" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
blocks = re.findall(r"```(?:sh|bash)\n(.*?)```", text, re.S)
hits = [ln.strip() for b in blocks for ln in b.splitlines() if "./bin/run" in ln]
print("\n".join(hits))
PY
)
[ -z "$badrel" ] && ok || bad "shell example depends on the current directory" "$badrel"

# -- 3. the documented pipelines actually run ------------------------------
key="nvapi-""$(printf 'Aa0-%.0s' 1 2 3 4 5 6 7 8 9 10)"
printf '[provider]\napi_key = "%s"\nmodel = "fast"\n' "$key" > "$work/config.toml"

# Pull whole fenced blocks out of the README, drop comment lines, point them at
# the temp config and this checkout, then run them exactly as documented.
block_for() {
  python3 - "$readme" "$1" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
needle = sys.argv[2]
for block in re.findall(r"```(?:sh|bash)\n(.*?)```", text, re.S):
    if needle not in block:
        continue
    print("\n".join(ln for ln in block.splitlines() if not ln.strip().startswith("#")))
    raise SystemExit
PY
}

run_block() {
  local body
  body=$(block_for "$1")
  [ -z "$body" ] && return 1
  body=${body//\~\/\.kimi-code\/config.toml/$work/config.toml}
  body=${body//\~\/\.kimi-code\/plugins\/managed\/codebase-memory/$root}
  body=${body//\~\/\.kimi-code\/secret-fingerprints.txt/$2}
  eval "$body"
}

if run_block "secret_guard fingerprint --secrets" "$work/fp.txt" >/dev/null 2>"$work/fp.err"; then
  if [ ! -s "$work/fp.txt" ]; then
    bad "documented fingerprint pipeline produced at least one line"
  elif grep -qvE '^[0-9a-f]{10}$' "$work/fp.txt"; then
    bad "fingerprint file holds only 10-hex lines" "$(head -2 "$work/fp.txt")"
  else
    ok
  fi
else
  bad "documented fingerprint pipeline exits 0" "$(head -c 120 "$work/fp.err")"
fi

redacted=$(run_block "secret_guard redact" /dev/null 2>&1)
case "$redacted" in
  *'[REDACTED:'*) ok ;;
  *) bad "documented redact pipeline masks the value" "${redacted:0:120}" ;;
esac
case "$redacted" in
  *"$key"*) bad "redact output must not contain the raw key" ;;
  *) ok ;;
esac

# -- 6. shell blocks stay copy-pasteable on a phone -----------------------
problems=$(python3 - "$readme" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
out = []
for i, block in enumerate(re.findall(r"```(?:sh|text)\n(.*?)```", text, re.S), 1):
    lines = block.splitlines()
    if not lines or not lines[0].strip().startswith("#"):
        out.append("block %d: first line is not a # caption" % i)
    for ln in lines:
        if len(ln) > 96:
            out.append("block %d: %d chars > 96" % (i, len(ln)))
        if ln.rstrip().endswith("\\"):
            out.append("block %d: line continuation breaks mobile copy" % i)
        if "<" in ln and ">" in ln:
            out.append("block %d: placeholder in a copy-paste block" % i)
print("\n".join(out))
PY
)
[ -z "$problems" ] && ok || bad "shell blocks are phone-copyable" "$problems"


# -- 4. the install-line counts match the manifest -------------------------
counts=$(python3 - "$root" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
m = json.loads((root / "kimi.plugin.json").read_text())
skills = len([p for p in (root / "skills").glob("*/SKILL.md")]) if (root / "skills").is_dir() else 0
print(m["hooks"].__len__(), len(m["mcpServers"]), skills, len(list((root / "commands").glob("*.md"))))
PY
)
read -r hooks mcp skills commands <<< "$counts"
line="codebase-memory · Local · ${skills} skill · ${mcp} MCP server · ${hooks} hooks · ${commands} commands"
if grep -qF "$line" "$readme"; then ok; else bad "README install line matches the manifest" "expected: $line"; fi

# -- 5. no stale command names survive in the docs ------------------------
if grep -qF 'bin/run.sh' "$readme"; then bad "README still mentions bin/run.sh"; else ok; fi
if grep -qF 'only resolves when the' "$readme"; then ok
else bad "README explains why ./bin/run needs the plugin root"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
