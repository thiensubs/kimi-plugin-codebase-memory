# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.8] - 2026-11-03

### Changed

- `secret_guard` default is now **reduced** mode: a detected credential path or
  secret-shaped value prints a friendly one-line notice, logs
  `NOTICE reduced <rule> tool=<tool>` (rule and tool name only — never the value),
  and lets the call run (exit 0). Safety is reduced; rotate the value or pipe text
  through `secret_guard redact` to inspect it without leaking.
- `SECRET_GUARD_MODE=strict` restores the old block behavior: exit 2 with a deny
  decision, `BLOCK <rule> tool=<tool>` in the log, and the deny reason written back
  into the conversation.
- README, SECURITY.md, SYSTEM.md and the `using-codebase-memory` skill updated for
  reduced mode and the `SECRET_GUARD_MODE` switch.
- Added "Transparency & contribution" to SECURITY.md: what the 40-bit fingerprint registry
  does and does not prevent, how to audit it, how to change the width, and how to contribute
  new provider prefixes or fingerprint edge cases.

## [0.2.7] - 2026-11-01

### Added

- README "Try it" carries the real session screenshot (`docs/try-it-proof.png`): one prompt, two
  graph calls (`list_projects`, then `index_status`), no grep. The image is committed to the repo
  and referenced by a relative path, so it renders on GitHub and survives a release zip.

### Added (tests)

- `tests/test-readme.sh` checks every relative image link resolves to a file in the repo — the
  failure mode that bit the earlier GitHub-hosted screenshots.

## [0.2.6] - 2026-11-01

### Added

- README section "Try it": three example prompts as one copyable `text` block, so a reader on a
  phone can paste a prompt into a new session instead of retyping it.

### Changed

- The phone-copy rules in `tests/test-readme.sh` now cover `text` blocks too (caption first line,
  no line over 96 characters, no continuation, no placeholder), not just `sh`.

## [0.2.5] - 2026-11-01

### Changed

- Every shell example in the README is now one phone-copyable block: a `#` caption first, no line
  over 96 characters, no `\` continuations, no placeholders. Long paths collapsed into `PLUGIN`
  and `R` variables so each real command fits one line.

### Added

- `tests/test-readme.sh` executes the documented blocks verbatim and fails on any line a phone copy
  would break (length, continuation, placeholder, missing caption).

## [0.2.4] - 2026-11-01

### Fixed

- The README's fingerprint recipe said `./bin/run`, which only resolves when the shell's working
  directory is the plugin root — true for a hook, false for a reader. It now uses the installed
  absolute path, states why, and explains the checkout variant.

### Added

- `tests/test-readme.sh`, so the docs cannot drift: every repo path the README names must exist, no
  shell example may depend on the current directory, the documented `redact` and `fingerprint`
  pipelines are executed for real, and the install-line counts must equal the manifest.

## [0.2.3] - 2026-11-01

### Added

- Sampled self-check in both hooks: every 10th run counts its own allocations and frees, writes
  `selfcheck ok …` to `$KIMI_CODE_HOME/logs/<tool>.runs.log`, and, if anything is still live,
  prints a one-line report naming live/allocs/frees, version and platform so it can be pasted into
  an issue. `SG_SELFCHECK_STATE` overrides the counter path (tests), `SG_SELFTEST_LEAK` plants a
  leak (self-test only).

### Verified

- Leak audit with macOS `leaks --atExit` over seven paths — allow, credential block, registry
  hit, redact, fingerprint, malformed payload, 1 MB input — all report 0 leaks. ASan was rejected
  for this purpose: Apple clang answers `detect_leaks is not supported on this platform`.

## [0.2.2] - 2026-11-01

### Added

- Windows x86_64: a `windows-latest` build job produces `bin/prebuilt/windows-x86_64/*.exe`, the
  release archive ships them, and `bin/run.cmd` is the cmd.exe twin of the dispatcher.

### Changed

- `bin/run.sh` is now `bin/run`, so one manifest command resolves on every platform: by shebang on
  macOS and Linux, by `PATHEXT` (`.CMD`) under cmd.exe on Windows.
- The MCP server command is `codebase-memory-mcp`, resolved from `PATH`, instead of the bundled
  `bin/codebase-memory-mcp.sh`. MCP servers are spawned without a shell and a `.sh` shim can never
  start on Windows. `bin/codebase-memory-mcp.sh` stays for launches with a minimal `PATH`; point
  `mcp.json` at it if you need that fallback.

### Fixed

- Directory creation uses a `_WIN32` shim (`_mkdir`), because MinGW declares a one-argument
  `mkdir` that rejects the POSIX two-argument call.

## [0.2.1] - 2026-11-01

### Added

- `secret_guard fingerprint` prints one **40-bit SHA-256 fingerprint** (10 hex chars) per token;
  `fingerprint --secrets` fingerprints only values the pattern rules flag, so a config file can be
  registered without matching ordinary URLs or model ids.
- A known-secret denylist: any tool call carrying a token whose fingerprint is listed in
  `$KIMI_CODE_HOME/secret-fingerprints.txt` is denied as `known-secret`, and `redact` masks it.
  A key that already leaked stays blocked even when its shape matches no provider prefix.
- `bin/install-local.sh` reinstalls this checkout into a running server without putting the bearer
  token in a shell history or a tool call.

### Changed

- A credential file may also be piped through `fingerprint`, not only `redact`, without a block.

## [0.2.0] - 2026-11-01

### Added

- **Secret guard** — `c/secret_guard.c` and `bin/secret_guard`, a `PreToolUse` hook that
  blocks calls reading credential files (`.env`, `~/.ssh/`, `~/.kimi-code/config.toml`,
  `*.pem`, `credentials.*`, …) and calls whose payload carries a provider key, PEM block,
  JWT, Bearer token, URL password or secret-shaped `name = value`. Blocks exit 2 with a
  single-line deny decision and append `BLOCK <rule> tool=<tool>` to
  `$KIMI_CODE_HOME/logs/secret-guard.log` without the value.
- **`redact` mode** — `secret_guard redact` replaces each detected secret on stdin with
  `[REDACTED:<label>]` and always exits 0; the hook allows a command piped through it.
- **`/codebase-memory:audit-secrets`** — lists credential-looking paths in the graph index
  and turns them into `.cbmignore` entries without opening them.
- **Portable dispatcher** — `bin/run` resolves `bin/prebuilt/<os>-<arch>/<tool>`, falls
  back to a cached compile under `${XDG_CACHE_HOME:-~/.cache}`, and on any failure writes one
  log line and exits 0 so a hook can never block a prompt. POSIX `sh`, follows symlinked
  installs, validates the tool name so it cannot escape the plugin root.
- **Prebuilt binaries** for macOS arm64 and x86_64 (`bin/prebuilt/darwin-*/cbm_nudge`,
  `secret_guard`), committed so installation needs no compiler.
- **CI and release workflows** — `.github/workflows/ci.yml` builds `-Werror` and runs the
  suite on Linux x86_64/arm64 and macOS x86_64/arm64; `release.yml` builds per-platform
  binaries on a `v*` tag, verifies each with `file(1)`, and publishes one all-platform
  archive, per-platform tarballs and `SHA256SUMS`.
- **Test suite** — `tests/test-cbm-nudge.sh`, `tests/test-dispatcher.sh`,
  `tests/test-secret-guard.sh`.
- `SECURITY.md`, `marketplace.json`, `CHANGELOG.md` and `.gitignore`.

### Changed

- `kimi.plugin.json` is now 0.2.0 and declares two hooks, `UserPromptSubmit` and
  `PreToolUse`, both invoked through `./bin/run <tool>`.
- `build-c.sh` builds every `c/*.c` into `bin/prebuilt/<os>-<arch>/` and refreshes `bin/`,
  with `-O2 -std=c11 -Wall -Wextra`.

## [0.1.0] - 2026-11-01

### Added

- Initial plugin: the `codebase-memory-mcp` knowledge graph as the `graph` MCP server,
  `SYSTEM.md` graph-first discovery rules, a session-start skill and the
  `/codebase-memory:status`, `:index` and `:reindex` commands.
- `c/cbm_nudge.c` — a `UserPromptSubmit` hook that prints a graph-first reminder on
  structure questions and stays silent otherwise. It replaces
  `codebase-memory-mcp hook-augment --dialect kimi`, which cost 2.08–2.13 s per prompt and
  printed nothing because the kimi-code payload carries `prompt` as an array of content
  blocks. Measured at ~58 ms over 200 runs against a `/usr/bin/true` baseline.
- `bin/codebase-memory-mcp.sh` — PATH-independent launcher for the upstream server, honouring
  `CBM_BIN`.
- `build-c.sh` and the MIT `LICENSE`.

[0.2.0]: https://github.com/thiensubs/kimi-plugin-codebase-memory/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/thiensubs/kimi-plugin-codebase-memory/releases/tag/v0.1.0
