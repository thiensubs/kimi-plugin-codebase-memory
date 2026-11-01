# Codebase discovery: graph first, text second

You have a codebase knowledge graph exposed as MCP tools (server `codebase-memory`, tools
`search_graph`, `trace_path`, `get_code_snippet`, `query_graph`, `search_code`,
`get_architecture`, `detect_changes`, `check_index_coverage`, `index_status`,
`list_projects`, …). The graph answers structural questions in a fraction of the tokens
that reading files costs; text search answers literal questions just as well.

## Lane 0 — secrets: never read, never print, never index

This lane outranks every other rule here. It applies to every file, indexed or not.

- Never read a credential file whole: `~/.kimi-code/config.toml`, `~/.ssh/*`, `.env*`, `*.pem`,
  `*.key`, `credentials.*`, `secrets.*`, `id_rsa*`, `.aws/*`. No `cat`, no whole-file `Read`,
  no `Grep -n` that prints the matching line.
- Ask whether a key exists with `grep -c '<KEY_NAME>' <file>` or `grep -l`, and report the count.
  Never print the line that holds the value — not as an example, not "just the prefix".
- Quote a secret only as `[REDACTED:<provider>]`: `[REDACTED:nvidia]`, `[REDACTED:github]`.
  No value, no prefix, no suffix, no length, no "starts with sk-".
- When a file that contains secrets has to be shown, run
  `./bin/run.sh secret_guard redact <path>` and read that output. Do not open the original instead.
- The plugin's `PreToolUse` hook runs `./bin/run.sh secret_guard` before every tool call and
  blocks it (exit 2) when a Bash command, path or argument would read or print a credential file,
  including silent leaks such as piping a config through a summariser. A block is a rule, not an
  obstacle: do not retry through another tool, another spelling of the path, or a `Task` prompt.
- The graph must never hold credential paths. Add them to `.cbmignore` before indexing; if
  `/codebase-memory:audit-secrets` finds one in the graph, exclude it and re-index.

## Lane 1 — graph: structure

| Question | First call |
| --- | --- |
| Who calls X, what does X call | `trace_path(function_name=..., direction="inbound"\|"outbound"\|"both")` |
| Where is X defined | `search_graph(name_pattern=...)`, then `get_code_snippet(qualified_name=...)` |
| What exists in this area | `search_graph(file_pattern=...)` or `search_code(path_filter=...)` |
| Architecture, layers, entry points, hotspots | `get_architecture` |
| What did my edit touch | `detect_changes` |
| Anything the fixed tools do not answer | `query_graph` with Cypher |

Scope every call: pass `project`, and narrow with `file_pattern` / `path_filter` /
`label` / `name_pattern` before widening.

## Lane 2 — text: literals

Use `Grep` / `Read` for string literals, error messages, config values, non-code files
(docs, YAML, JSON, scripts), and files the graph skipped or only partially parsed.

Lane 2 does not override Lane 0. A credential file stays closed: count matches instead of
printing them, and quote values only as `[REDACTED:<provider>]`.

## Session start (30 seconds)

1. `list_projects` — pick the project whose `root_path` contains the working directory.
   Pass its `name` (or the absolute directory) as `project`, never a repo or folder name.
2. `index_status` — check the generation and the `indexed_at` timestamp. A stale index
   answers confidently and wrongly; a fresh one does not.
3. Once candidate paths are known, call `check_index_coverage` once with every path you
   relied on. Clean coverage is not proof of completeness — it only means no gap was recorded.

## Traps

- "No callers" is not dead code. CLI entry points, `main`, tests and script bodies have none.
- The only negation the query parser accepts is `WHERE NOT EXISTS { (f)<-[:CALLS]-() }`.
- Degree and hotspot ranks lie on name collisions with stdlib and frameworks; confirm a
  symbol by its fully qualified name before drawing a conclusion.
- An empty result is not proof of absence. Check coverage, then fall back to Lane 2 and say
  which lane answered the question.
- `index_mode` metadata can disagree with the mode you requested; verify with `index_status`.
- Files under `scripts/` and `tools/` are often excluded from the index even with an empty
  `.gitignore`; those questions belong to Lane 2.

## Evidence discipline

Name the tier you used — Scout (quick positive lookup), Verify (task-directed graph
evidence plus exact snippets), or Auditor (bounded full verification) — and list the paths
you actually checked. A graph answer without its source path is an assertion, not evidence.
