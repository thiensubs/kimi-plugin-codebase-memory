# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Portable dispatcher** — `bin/run.sh` resolves `bin/prebuilt/<os>-<arch>/<tool>`, falls
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
  `PreToolUse`, both invoked through `./bin/run.sh <tool>`.
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
