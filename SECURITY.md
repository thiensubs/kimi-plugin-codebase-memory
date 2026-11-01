# Security policy

## Scope

This document covers the two local C hooks that ship with the plugin —
`bin/secret_guard` (`c/secret_guard.c`) and `bin/cbm_nudge` (`c/cbm_nudge.c`) — and the
dispatcher `bin/run.sh` that starts them. The MCP server itself is
[DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) and is out of
scope here; report bugs in it upstream.

## Threat model

Everything the agent reads or types is sent to the model provider: the prompt, the tool
arguments, every file the agent opens, the output of every command it runs, and the tool
results from the graph server. A secret reaches the provider through one of three doors:

1. The agent requests a file that holds it — `cat .env`, `Read ~/.ssh/id_rsa`,
   `grep api_key ~/.kimi-code/config.toml`.
2. The agent puts it into a tool argument itself — `curl -H "Authorization: Bearer …"`,
   `export SK=…`.
3. A tool result contains it even though the request looked harmless — a generated file, a
   log line, a config read through a path the guard does not recognise.

`bin/secret_guard` is a `PreToolUse` hook: it sees the pending tool call before it runs and
can refuse it (exit 2). It closes door 1 and most of door 2. It cannot close door 3, and it
cannot retract anything already in context.

The hook runs on the machine running Kimi Code, before the tool's permission check, with the
plugin root as its working directory. Kimi Code treats exit 0 as allow, exit 2 as block, any
other exit code or a timeout as allow.

## What the guard enforces

A call is blocked when any of the following matches. The rule name is what appears in the log
and in the deny reason.

| Rule | Trigger | Blocks | Allows |
| --- | --- | --- | --- |
| `credential-path` | A path-valued argument to a reading tool matches a credential pattern | `Read .env`, `cat ~/.ssh/id_rsa`, `grep -rn key ~/.kimi-code/config.toml`, `cp .env.example .env`, `curl -o out.pem …` | `Read src/main.c`, `.env.example`, `grep -c key ~/.kimi-code/config.toml`, `find . -name '*.pem'` |
| `openai-key`, `anthropic-key`, … | One of the 43 provider prefixes followed by a long enough body (table below) | `echo sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA` | `run task-12345678901234567890 now` (`sk-` needs the body immediately after the dash) |
| `private-key` | `-----BEGIN … PRIVATE KEY-----` through the matching `END` line | A pasted RSA/EC/OpenSSH key block | A prose mention of "private key" |
| `jwt` | Three dot-separated base64url runs starting `eyJ` | `eyJhbGciOi….eyJzdWIi….dozjgNry…` | A sentence starting with `eyJ` and no dots |
| `bearer-token` | `Bearer` + whitespace + 24 or more token characters | `send Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA now` | `Bearer short` |
| `url-credentials` | `scheme://user:password@host`, password not all digits | `postgres://admin:hunter2pass@db.example.test/app` | `postgres://user:1234@host/db` |
| `client_secret`, `password`, `api_key`, `token`, … | `name = value` or `name: value`, value at least 12 chars, at least 6 distinct characters, at least 2 character classes | `export CLIENT_SECRET=Abc123Xyz789Qrs`, `api_key = "Zx81kQp29LmN4vT"` | `API_KEY=your_api_key_here`, `TOKEN=$TOKEN_FROM_ENV`, `token=short`, `secret=abcdefghijkl`, `thisisthetoken` |

The context rule applies to these names (case-insensitive): `client_secret`,
`application_key`, `encryption_key`, `private_key`, `refresh_token`, `access_token`,
`signing_key`, `session_key`, `secret_key`, `access_key`, `auth_token`, `credential`,
`authorization`, `password`, `apikey`, `api_key`, `api-key`, `passwd`, `secret`, `token`,
`pwd`.

Path rules apply only to tools whose name contains `bash`, `shell`, `exec`, `read`, `cat`,
`grep`, `search_code`, `get_code_snippet`, `index`, `open`, `preview` or `notebook`. The
`Write` tool is deliberately not path-checked: writing a file is not reading one.

### Shell command inspection

For shell tools, the command string is tokenised and checked:

- **Readers** — `cat`, `head`, `tail`, `less`, `more`, `bat`, `source`, `strings`, `xxd`,
  `od`, `base64`, `cp`, `scp`, `rsync`, `tar`, `zip`, `curl`, `wget`: any non-flag argument
  that matches a credential path blocks.
- **Search tools** — `grep`, `rg`, `ag`, `ack`, `sed`, `awk`, `find`, `cut`, `jq`: an
  argument blocks when it contains `/`, starts with `~`, or exists relative to the working
  directory, and matches a credential path.
- **Presence checks pass** — `-c`, `--count`, `-l`, `--files-with-matches`, `-q`, `--quiet`,
  `--silent` anywhere in the command allow it. `grep -c api_key ~/.kimi-code/config.toml`
  tells you whether a key exists without printing it.
- **A pipe through the redactor passes** — any command containing `|` followed by `redact`.

## Redacting instead of blocking

`redact` mode reads plain text on stdin, replaces every detected secret with
`[REDACTED:<label>]`, and always exits 0. The label is the rule name from the tables above:
`[REDACTED:anthropic-key]`, `[REDACTED:private-key]`, `[REDACTED:password]`, and so on.
Only the value is replaced; the field name and the file structure survive, which is what you
need in order to reason about a config without leaking it.

```sh
cat ~/.kimi-code/config.toml | ~/.kimi-code/plugins/managed/codebase-memory/bin/run.sh secret_guard redact
```

The hook treats that pipeline as allowed, so it is the supported way to look at a credential
file. The redactor has the same rule set and therefore the same blind spots — a secret it
does not recognise passes through unchanged.

## Fail-open behaviour

The guard fails open on purpose; Kimi Code also fails open on any hook that crashes or times
out (the default timeout here is 3 s).

| Situation | Result |
| --- | --- |
| Empty, malformed or truncated payload | exit 0, allow |
| Payload larger than 32 MiB | exit 0, allow |
| No prebuilt for the platform and no compiler | `run.sh` logs one line, exits 0 |
| Compiler fails | `run.sh` logs one line, exits 0 |
| Hook times out or crashes | Kimi Code allows the call |

Because of this, the guard is an accident preventer for an agent that reads credentials
because nothing stopped it — not a security boundary. Keep permission prompts on. Anyone who
can run code as your user can also delete, replace or bypass the hook.

## Known limits

1. **Regex-shaped searches pass.** `grep -o 'sk-[A-Za-z0-9]*' config.toml` is allowed: the
   pattern is not a secret, and `config.toml` is not a credential name. The same command
   against `~/.kimi-code/config.toml` blocks on the path, but any other file that happens to
   contain keys does not.
2. **Secrets already in context stay there.** Anything read before the plugin was installed,
   or produced by a tool the guard does not gate, has already been sent.
3. **Tool results are not inspected.** There is no `PostToolUse` redaction. A tool that
   legitimately returns a secret (a generated certificate, a debug dump) delivers it.
4. **Encoded or split secrets pass.** `printf bnZhcGkt… | base64 -d`,
   `"nvapi-""AAAA…"`, and values built character by character are not detected.
5. **Matching is on the path string, not the inode.** A symlink or a renamed copy —
   `ln -s ~/.kimi-code/config.toml notes.txt; cat notes.txt` — is allowed.
6. **Unrecognised tool names are not path-checked.** Content rules still apply to the whole
   payload, but a custom tool whose name does not contain one of the reader needles can be
   handed a credential path.
7. **Placeholder matching is substring-based.** Any value containing `test`, `fake`, `sample`,
   `example`, `dummy`, `todo` … is treated as a placeholder, so `password = "test-AbC123xyz789"`
   passes.
8. **Credential file contents are never read by the hook.** It inspects the payload only, so
   a file with an unremarkable name and a credential inside passes.
9. **The prefix list is finite.** Providers not listed below — and new key formats — are not
   detected by prefix. The context rules catch some of them by field name.
10. **The guard is local to your machine.** Hooks run where Kimi Code runs; in a session bound
    to a remote environment the guard inspects the local project, not the target.
11. **The MCP server is not gated.** The guard sees `search_code`/`get_code_snippet` paths but
    not what the graph server returns; exclude credential paths from the index instead
    (`/codebase-memory:audit-secrets`, then `.cbmignore` and a re-index).

## Provider prefixes covered

A prefix only matches at a token boundary, with a body of the stated minimum length. The body
is letters, digits, `-` and `_` unless noted.

| Provider | Prefixes | `[REDACTED:…]` label | Minimum body |
| --- | --- | --- | --- |
| OpenAI | `sk-proj-`, `sk-svcacct-`, `sk-` | `openai-key`, `openai-style-key` | 20 |
| Anthropic | `sk-ant-` | `anthropic-key` | 20 |
| OpenRouter | `sk-or-v1-` | `openrouter-key` | 20 |
| Cerebras | `csk-` | `cerebras-key` | 20 |
| xAI | `xai-` | `xai-key` | 20 |
| Perplexity | `pplx-` | `perplexity-key` | 20 |
| NVIDIA | `nvapi-` | `nvidia-key` | 20 |
| Groq | `gsk_` | `groq-key` | 20 |
| GitHub | `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_` | `github-token` | 20 |
| GitLab | `glpat-`, `glptt-`, `gloas-` | `gitlab-token` | 20 |
| Docker Hub | `dckr_pat_` | `dockerhub-token` | 20 |
| Slack | `xoxb-`, `xoxp-`, `xoxa-`, `xoxs-`, `xoxr-`, `xapp-` | `slack-token` | 10 |
| Stripe | `sk_live_`, `sk_test_`, `rk_live_`, `rk_test_`, `pk_live_`, `pk_test_` | `stripe-key` | 10 |
| PyPI | `pypi-` | `pypi-token` | 20 |
| npm | `npm_` | `npm-token` | 20 |
| Supabase | `sbp_` | `supabase-token` | 20 |
| Hugging Face | `hf_` | `huggingface-token` | 20 |
| Replicate | `r8_` | `replicate-token` | 20 |
| Google | `ya29.` | `google-oauth-token` | 20 |
| Google API | `AIza` | `google-api-key` | 30 |
| AWS | `AKIA`, `ASIA` | `aws-access-key` | 16 hex digits |
| SendGrid | `SG.` | `sendgrid-key` | 20 (`.` allowed in body) |
| Twilio | `AC` | `twilio-key` | 32 hex digits |

## Reporting a vulnerability

Open a private security advisory at
https://github.com/thiensubs/kimi-plugin-codebase-memory/security/advisories/new.
Do not open a public issue with a working credential in it.

Rotate the exposed key first. Then include: the plugin version
(`kimi.plugin.json`), the platform (`uname -sm`), the smallest tool call or payload that
reproduces the problem, the log line from `$KIMI_CODE_HOME/logs/secret-guard.log`, and what
you expected to happen. Replace every real secret in the report with
`[REDACTED:<label>]` — the guard's own output makes a good template.

Bugs in the graph server itself belong at https://github.com/DeusData/codebase-memory-mcp.

## Supported versions

0.2.x receives security fixes. 0.1.0 predates the guard and has none.

## Known-secret fingerprints (0.2.1+)

Prefix rules only catch shapes. The fingerprint registry catches *one specific value*:

- `secret_guard fingerprint` → 10-hex SHA-256 prefix (40 bits) per token of 16+ chars.
- `secret_guard fingerprint --secrets` → same, but only for values the pattern rules flag, so a
  config file can be registered without matching URLs, model ids or paths.
- Registry: `$KIMI_CODE_HOME/secret-fingerprints.txt` (default `~/.kimi-code/`), one fingerprint
  per line, `#` comments and blank lines ignored, case-insensitive. Override the path with
  `SECRET_GUARD_FINGERPRINTS`.
- A hit denies the call as `known-secret` and `redact` masks the value as
  `[REDACTED:known-secret]`. The registry stores no plaintext, and neither the log nor the deny
  message ever echoes the secret.

Why 40 bits: collision expectation is `n² / (2 · 2^40)`. A 1,000-entry registry sits at ~4.5×10⁻⁷;
the first expected collision arrives at ~1.5M entries. 32 bits would collide at ~93k and would also
make the registry twice as guessable; 64 bits would double the file size for a problem this code
does not have.

Known limits of this class: only tokens of 16+ characters from `[A-Za-z0-9_-]` are fingerprinted,
so a key with `.` or `/` in it is missed; a fingerprint is a *presence* check, not a proof of
identity (a deliberate 2^40 search could collide, which no realistic attacker will spend on a
local file).
