#!/usr/bin/env bash
# tests/test-secret-guard.sh — exercise c/secret_guard.c in both modes.
#
# Every credential below is fake and generated in this file. The test never
# reads a real credential file: commands such as
# `cat ~/.kimi-code/config.toml | secret_guard redact` are only ever passed to
# the guard as *payload strings*, and the one real pipeline runs on a fake
# config written into .tmp/.
#
# Usage: tests/test-secret-guard.sh
# Exit:  0 when every case passes, 1 otherwise.
#
# Scratch goes to a per-run directory under .tmp/ so that two concurrent runs
# cannot delete each other's binary, payloads or log.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$ROOT/.tmp/secret-guard-test.$$"
BIN="$WORK/secret_guard"
export KIMI_CODE_HOME="$WORK/kimi-home"
LOG="$KIMI_CODE_HOME/logs/secret-guard.log"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

rm -rf "$WORK"
mkdir -p "$WORK"

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }

# ---------------------------------------------------------------- build ----
build_err="$WORK/build.log"
if ! clang -O2 -std=c11 -Wall -Wextra "$ROOT/c/secret_guard.c" -o "$BIN" 2>"$build_err"; then
    printf 'FAIL  build: clang failed\n'
    sed -n '1,40p' "$build_err"
    printf '\n0 passed, 1 failed\n'
    exit 1
fi
if [ -s "$build_err" ]; then
    bad "build: compiler emitted warnings (must be silent)"
    sed -n '1,20p' "$build_err"
else
    ok
fi

# -------------------------------------------------------------- helpers ----

RC=0

hook_run() { # payload
    printf '%s' "$1" | "$BIN" >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

line_count() { wc -l < "$1" | tr -d ' '; }

expect_allow() { # name, payload
    hook_run "$2"
    if [ "$RC" -ne 0 ]; then
        bad "$1: exit $RC, want 0"
        [ -s "$WORK/out" ] && note "stdout: $(head -c 200 "$WORK/out")"
        return
    fi
    if [ -s "$WORK/out" ]; then
        bad "$1: allow printed to stdout"
        note "stdout: $(head -c 200 "$WORK/out")"
        return
    fi
    ok
}

expect_block() { # name, rule, tool, payload
    hook_run "$4"
    if [ "$RC" -ne 2 ]; then
        bad "$1: exit $RC, want 2"
        return
    fi
    if ! grep -q '"permissionDecision":"deny"' "$WORK/out"; then
        bad "$1: stdout is not a deny decision"
        note "stdout: $(head -c 200 "$WORK/out")"
        return
    fi
    if [ "$(line_count "$WORK/out")" != "1" ]; then
        bad "$1: deny JSON must be a single line"
        return
    fi
    if [ ! -s "$WORK/err" ] || [ "$(line_count "$WORK/err")" != "1" ]; then
        bad "$1: stderr must be exactly one line"
        return
    fi
    if ! grep -Fq "BLOCK $2 tool=$3" "$LOG"; then
        bad "$1: log missing 'BLOCK $2 tool=$3'"
        return
    fi
    ok
}

redact_case() { # name, expected label, token
    local got
    got="$(printf 'value %s here\n' "$3" | "$BIN" redact)"
    if [ "$got" = "value [REDACTED:$2] here" ]; then
        ok
    else
        bad "$1: redact label mismatch"
        note "want: value [REDACTED:$2] here"
        note "got:  $got"
    fi
}

hook_json_bash() { # command -> payload
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"
}

redact_expect() { # name, input, expected output
    local got
    got="$(printf '%s\n' "$2" | "$BIN" redact)"
    if [ "$got" = "$3" ]; then
        ok
    else
        bad "$1"
        note "want: $3"
        note "got:  $got"
    fi
}

hook_json_read() { # path -> payload
    printf '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1"
}

# ------------------------------------------------------- provider keys ----
# prefix|label — every body is a fake run of A's (or hex for the last two).

PROVIDERS=(
    "sk-ant-""api03-AAAAAAAAAAAAAAAAAAAAAAAA|anthropic-key"
    "sk-""proj-AAAAAAAAAAAAAAAAAAAAAAAA|openai-key"
    "sk-""svcacct-AAAAAAAAAAAAAAAAAAAAAAAA|openai-key"
    "sk-""AAAAAAAAAAAAAAAAAAAAAAAA|openai-style-key"
    "sk-or-""v1-AAAAAAAAAAAAAAAAAAAAAAAA|openrouter-key"
    "csk-""AAAAAAAAAAAAAAAAAAAAAAAA|cerebras-key"
    "pplx-""AAAAAAAAAAAAAAAAAAAAAAAA|perplexity-key"
    "xai-""AAAAAAAAAAAAAAAAAAAAAAAA|xai-key"
    "nvapi-""AAAAAAAAAAAAAAAAAAAAAAAA|nvidia-key"
    "gsk_""AAAAAAAAAAAAAAAAAAAAAAAA|groq-key"
    "AIza""AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|google-api-key"
    "ya29.""AAAAAAAAAAAAAAAAAAAAAAAA|google-oauth-token"
    "hf_""AAAAAAAAAAAAAAAAAAAAAAAA|huggingface-token"
    "r8_""AAAAAAAAAAAAAAAAAAAAAAAA|replicate-token"
    "glpat-""AAAAAAAAAAAAAAAAAAAAAAAA|gitlab-token"
    "glptt-""AAAAAAAAAAAAAAAAAAAAAAAA|gitlab-token"
    "gloas-""AAAAAAAAAAAAAAAAAAAAAAAA|gitlab-token"
    "npm_""AAAAAAAAAAAAAAAAAAAAAAAA|npm-token"
    "pypi-""AAAAAAAAAAAAAAAAAAAAAAAA|pypi-token"
    "dckr_pat_""AAAAAAAAAAAAAAAAAAAAAAAA|dockerhub-token"
    "xoxb-""AAAAAAAAAAAAAAAAAAAAAAAA|slack-token"
    "xoxp-""AAAAAAAAAAAAAAAAAAAAAAAA|slack-token"
    "xoxa-""AAAAAAAAAAAAAAAAAAAAAAAA|slack-token"
    "xoxs-""AAAAAAAAAAAAAAAAAAAAAAAA|slack-token"
    "xoxr-""AAAAAAAAAAAAAAAAAAAAAAAA|slack-token"
    "xapp-""AAAAAAAAAAAAAAAAAAAAAAAA|slack-token"
    "sk_""live_AAAAAAAAAAAAAAAAAAAAAAAA|stripe-key"
    "sk_""test_AAAAAAAAAAAAAAAAAAAAAAAA|stripe-key"
    "rk_""live_AAAAAAAAAAAAAAAAAAAAAAAA|stripe-key"
    "rk_""test_AAAAAAAAAAAAAAAAAAAAAAAA|stripe-key"
    "pk_""live_AAAAAAAAAAAAAAAAAAAAAAAA|stripe-key"
    "pk_""test_AAAAAAAAAAAAAAAAAAAAAAAA|stripe-key"
    "SG.""AAAAAAAAAAAAAAAAAAAAAAAA|sendgrid-key"
    "sbp_""AAAAAAAAAAAAAAAAAAAAAAAA|supabase-token"
    "github_pat_""AAAAAAAAAAAAAAAAAAAAAAAA|github-token"
    "ghp_""AAAAAAAAAAAAAAAAAAAAAAAA|github-token"
    "gho_""AAAAAAAAAAAAAAAAAAAAAAAA|github-token"
    "ghu_""AAAAAAAAAAAAAAAAAAAAAAAA|github-token"
    "ghs_""AAAAAAAAAAAAAAAAAAAAAAAA|github-token"
    "ghr_""AAAAAAAAAAAAAAAAAAAAAAAA|github-token"
    "AKIA""0123456789ABCDEF|aws-access-key"
    "ASIA""0123456789ABCDEF|aws-access-key"
    "AC""0123456789abcdef0123456789abcdef|twilio-key"
)

for entry in "${PROVIDERS[@]}"; do
    key="${entry%%|*}"
    label="${entry##*|}"
    redact_case "provider $label redact ($key)" "$label" "$key"
    expect_block "provider $label hook ($key)" "$label" "Bash" "$(hook_json_bash "echo $key")"
    if grep -Fq "$key" "$WORK/out"; then
        bad "provider $label: deny output leaked the key"
    fi
done

# --------------------------------------------------- other content types ----

JWT='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U'
got="$(printf 'x %s y\n' "$JWT" | "$BIN" redact)"
if [ "$got" = "x [REDACTED:jwt] y" ]; then ok; else bad "jwt redact"; note "got: $got"; fi
expect_block "jwt hook" jwt "Bash" "$(hook_json_bash "echo $JWT")"

BEARER_TOKEN='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
got="$(printf 'send Bearer %s now\n' "$BEARER_TOKEN" | "$BIN" redact)"
if [ "$got" = "send Bearer [REDACTED:bearer-token] now" ]; then
    ok
else
    bad "bearer redact"
    note "got: $got"
fi
expect_block "bearer hook" bearer-token "Bash" "$(hook_json_bash "send Bearer $BEARER_TOKEN now")"

cat >"$WORK/pem.in" <<'PEM'
header line
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAfakefakefakefakefake
-----END RSA PRIVATE KEY-----
footer line
PEM
cat >"$WORK/pem.want" <<'PEM'
header line
[REDACTED:private-key]
footer line
PEM
if "$BIN" redact <"$WORK/pem.in" >"$WORK/pem.out" 2>"$WORK/pem.err"; then
    RC=0
else
    RC=$?
fi
if [ "$RC" -eq 0 ] && diff -q "$WORK/pem.want" "$WORK/pem.out" >/dev/null; then
    ok
else
    bad "private-key redact: block not fully masked"
    note "got: $(tr '\n' '|' <"$WORK/pem.out")"
fi
expect_block "private-key hook" private-key "Read" \
    '{"tool_name":"Read","tool_input":{"file_path":"notes.txt","content":"-----BEGIN RSA PRIVATE KEY-----\nMIIEfake\n-----END RSA PRIVATE KEY-----"}}'

# context rules
# context rules: only the value is masked, the name is left readable
redact_expect "context env style" "CLIENT_SECRET=Abc123Xyz789Qrs" \
    "CLIENT_SECRET=[REDACTED:client_secret]"
redact_expect "context toml style" 'password = "hunter2hunter2"' \
    'password = "[REDACTED:password]"'
redact_expect "context json style" '{"api_key": "Zx81kQp29LmN4vT"}' \
    '{"api_key": "[REDACTED:api_key]"}'
expect_block "context secret hook" client_secret "Bash" \
    "$(hook_json_bash 'export CLIENT_SECRET=Abc123Xyz789Qrs')"

got="$(printf 'dsn postgres://admin:hunter2pass@db.example.test/app\n' | "$BIN" redact)"
if [ "$got" = "dsn postgres://admin:[REDACTED:url-credentials]@db.example.test/app" ]; then
    ok
else
    bad "url credentials redact"
    note "got: $got"
fi

# ------------------------------------------------------- no false positives ----

expect_allow "placeholder your_" "$(hook_json_bash 'export API_KEY=your_api_key_here')"
expect_allow "env reference" "$(hook_json_bash 'export TOKEN=$TOKEN_FROM_ENV')"
expect_allow "short value" "$(hook_json_bash 'set token=short')"
expect_allow "single class value" "$(hook_json_bash 'set secret=abcdefghijkl')"
expect_allow "no separator" "$(hook_json_bash 'echo thisisthetoken')"
expect_allow "task- prefix is not sk-" "$(hook_json_bash 'run task-12345678901234567890 now')"

got="$(printf 'API_KEY=your_api_key_here\n' | "$BIN" redact)"
if [ "$got" = "API_KEY=your_api_key_here" ]; then ok; else bad "placeholder redact changed text"; fi

# ------------------------------------------------------------- path rules ----

expect_block "path .env" credential-path "Read" "$(hook_json_read '.env')"
expect_block "path .env.local" credential-path "Read" "$(hook_json_read '/repo/app/.env.local')"
expect_allow "path .env.example" "$(hook_json_read '.env.example')"
expect_allow "path .env.sample" "$(hook_json_read '.env.sample')"
expect_block "path .npmrc" credential-path "Read" "$(hook_json_read '~/.npmrc')"
expect_block "path .git-credentials" credential-path "Read" "$(hook_json_read '/repo/.git-credentials')"
expect_block "path id_rsa" credential-path "Read" "$(hook_json_read 'id_rsa')"
expect_block "path .ssh fragment" credential-path "Read" "$(hook_json_read '/Users/kai/.ssh/id_ed25519')"
expect_block "path home tilde ssh" credential-path "Read" "$(hook_json_read '~/.ssh/known_hosts')"
expect_block "path .aws fragment" credential-path "Read" "$(hook_json_read '/Users/kai/.aws/credentials')"
expect_block "path .ssh directory no slash" credential-path "Read" "$(hook_json_read '~/.ssh')"
expect_block "path .aws directory no slash" credential-path "Read" "$(hook_json_read '/Users/kai/.aws')"
expect_block "path .gnupg directory no slash" credential-path "Read" "$(hook_json_read '~/.gnupg')"
expect_allow "path name ending in .ssh is not the dir" "$(hook_json_read 'build/my.ssh')"
expect_block "path kimi config" credential-path "Read" "$(hook_json_read '~/.kimi-code/config.toml')"
expect_block "path kimi credentials" credential-path "Read" "$(hook_json_read '~/.kimi-code/credentials/nvidia.json')"
expect_block "path pem extension" credential-path "Read" "$(hook_json_read 'certs/server.pem')"
expect_block "path kdbx extension" credential-path "Read" "$(hook_json_read 'vault.kdbx')"
expect_block "path credential json" credential-path "Read" "$(hook_json_read 'config/credentials.json')"
expect_block "path secrets yaml" credential-path "Read" "$(hook_json_read 'deploy/secrets.yaml')"
expect_block "path service account" credential-path "Read" "$(hook_json_read 'service-account-prod.json')"
expect_block "path gh config" credential-path "Read" "$(hook_json_read '~/.config/gh/hosts.yml')"
expect_allow "path source file" "$(hook_json_read 'src/main.c')"
expect_allow "path doc" "$(hook_json_read 'docs/notes.md')"
expect_allow "path pem name in prose" "$(hook_json_read 'docs/pem-format.md')"

# path rules only apply to tools that can read
expect_allow "write tool is not path-checked" \
    '{"tool_name":"Write","tool_input":{"file_path":".env","content":"API_KEY=your_key_here"}}'

# alternate payload key spellings
expect_block "payload tool/input fallbacks" credential-path "Bash" \
    '{"tool":"Bash","input":{"cmd":"cat ~/.ssh/id_rsa"}}'
expect_block "payload name/parameters fallbacks" credential-path "bash" \
    '{"name":"bash","parameters":{"script":"base64 ~/.docker/config.json"}}'
expect_block "tool_input as encoded string" credential-path "Bash" \
    '{"tool_name":"Bash","tool_input":"{\"command\":\"cat .env\"}"}'

# ---------------------------------------------------- bash command rules ----

expect_allow "cat README.md" "$(hook_json_bash 'cat README.md')"
expect_allow "grep -c on the real config path" "$(hook_json_bash 'grep -c api_key ~/.kimi-code/config.toml')"
expect_allow "grep -l presence flag" "$(hook_json_bash 'grep -l token ~/.kimi-code/config.toml')"
expect_allow "pipe through redact" "$(hook_json_bash 'cat ~/.kimi-code/config.toml | secret_guard redact')"
expect_block "cat real config without redact" credential-path "Bash" \
    "$(hook_json_bash 'cat ~/.kimi-code/config.toml')"
expect_block "grep real config without presence flag" credential-path "Bash" \
    "$(hook_json_bash 'grep -rn api_key ~/.kimi-code/config.toml')"
expect_block "less .env" credential-path "Bash" "$(hook_json_bash 'less /repo/.env')"
expect_block "cp .env.example .env" credential-path "Bash" "$(hook_json_bash 'cp .env.example .env')"
expect_block "curl into pem" credential-path "Bash" "$(hook_json_bash 'curl -o out.pem https://example.test/x')"
expect_allow "find name glob is not a path" "$(hook_json_bash "find . -name '*.pem'")"
expect_allow "unrelated command" "$(hook_json_bash 'cargo build --release')"

# relative names that exist on disk are checked for search verbs
mkdir -p "$WORK/cwd"
: >"$WORK/cwd/id_rsa"
: >"$WORK/cwd/.env"
: >"$WORK/cwd/notes.txt"
(
    cd "$WORK/cwd" || exit 1
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"grep secret id_rsa"}}' |
        "$BIN" >"$WORK/out2" 2>"$WORK/err2"
    echo $? >"$WORK/rc2"
)
if [ "$(cat "$WORK/rc2")" = "2" ] && grep -Fq "BLOCK credential-path tool=Bash" "$LOG"; then
    ok
else
    bad "search verb on existing relative credential file: exit $(cat "$WORK/rc2"), want 2"
fi
(
    cd "$WORK/cwd" || exit 1
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"grep secret notes.txt"}}' |
        "$BIN" >"$WORK/out3" 2>"$WORK/err3"
    echo $? >"$WORK/rc3"
)
if [ "$(cat "$WORK/rc3")" = "0" ]; then ok; else bad "search verb on a plain file: want allow"; fi

# ------------------------------------------------- redact pipeline on disk ----

cat >"$WORK/fake-config.toml" <<'CFG'
api_key = "Zx81kQp29LmN4vT"
nvidia = "nvapi-AAAAAAAAAAAAAAAAAAAAAAAA"
[server]
token = "Aa1Bb2Cc3Dd4Ee5Ff6Gg7"
CFG
if cat "$WORK/fake-config.toml" | "$BIN" redact >"$WORK/fake-masked.toml" 2>"$WORK/pipe.err"; then
    RC=0
else
    RC=$?
fi
if [ "$RC" -ne 0 ]; then
    bad "redact pipeline: exit $RC, want 0"
elif ! grep -q '\[REDACTED:api_key\]' "$WORK/fake-masked.toml"; then
    bad "redact pipeline: context secret not masked"
elif ! grep -q '\[REDACTED:nvidia-key\]' "$WORK/fake-masked.toml"; then
    bad "redact pipeline: provider key not masked"
elif ! grep -q '\[REDACTED:token\]' "$WORK/fake-masked.toml"; then
    bad "redact pipeline: token not masked"
elif grep -q 'Zx81kQp29LmN4vT\|nvapi-AAA\|Aa1Bb2Cc3Dd4Ee5Ff6Gg7' "$WORK/fake-masked.toml"; then
    bad "redact pipeline: a fake secret survived"
else
    ok
fi

# --------------------------------------------------- exit codes and edges ----

printf '' | "$BIN" >"$WORK/out" 2>"$WORK/err"
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$WORK/out" ]; then ok; else bad "empty stdin must allow"; fi

printf 'not json at all' | "$BIN" >"$WORK/out" 2>"$WORK/err"
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$WORK/out" ]; then ok; else bad "malformed payload must allow"; fi

printf '{"tool_name":' | "$BIN" >"$WORK/out" 2>"$WORK/err"
RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad "truncated payload must allow"; fi

printf 'plain text with nothing to hide\n' | "$BIN" redact >"$WORK/out" 2>"$WORK/err"
RC=$?
if [ "$RC" -eq 0 ] && grep -qx 'plain text with nothing to hide' "$WORK/out"; then
    ok
else
    bad "redact on clean input: exit $RC or output changed"
fi

# the log must never contain a secret value
if grep -Fq 'sk-ant-api03-' "$LOG" || grep -Fq 'nvapi-' "$LOG" || grep -Fq "$JWT" "$LOG"; then
    bad "log leaked a secret value"
else
    ok
fi
if [ -f "$LOG" ] && grep -q '^BLOCK ' "$LOG"; then ok; else bad "log file was not written"; fi

# ------------------------------------------------------------- summary ----
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
