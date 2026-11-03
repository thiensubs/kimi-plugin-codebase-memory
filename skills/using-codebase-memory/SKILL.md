---
name: using-codebase-memory
description: "Use the codebase knowledge graph for structural code queries. Triggers on: explore the codebase, understand the architecture, what functions exist, who calls this function, what does X call, trace the call chain, find callers of, show dependencies, impact analysis, dead code, unused functions, high fan-out, refactor candidates, code quality audit, graph query syntax, Cypher query examples, edge types, how to use search_graph."
type: prompt
whenToUse: When the task is about code structure rather than a literal string - finding symbols, callers, dependencies, architecture, or the blast radius of a change.
---

# Codebase Memory — knowledge graph for Kimi Code

The graph answers structural questions in roughly 500 tokens where file-by-file reading
costs tens of thousands. Text search still wins for literals.

## Secrets — never read, never print, never index

- Never read a credential file whole (`~/.kimi-code/config.toml`, `~/.ssh/*`, `.env*`, `*.pem`,
  `credentials.*`, `id_rsa*`, `.aws/*`); prove a key exists with `grep -c`, never by printing the
  line, and quote a value only as `[REDACTED:<provider>]`.
- The graph must never index credential paths: list them in `.cbmignore` before indexing, and
  treat a credential-looking `File` node as a defect to re-index away
  (`/codebase-memory:audit-secrets` lists them, paths only).
- `search_code` / `get_code_snippet` results that contain a secret are reported as
  `[REDACTED:<provider>]`, never quoted — even when the exact value was requested.
- The PreToolUse `secret_guard` hook enforces this. Default is **reduced** mode: a match prints a
  friendly notice, logs it (rule and tool only, never the value), and lets the call run — safety
  is reduced. Set `SECRET_GUARD_MODE=strict` to restore the old block (exit 2 + deny decision).
  A block is final.

## Which tool answers which question

| Question | Call |
| --- | --- |
| Who calls X? | `trace_path(function_name="X", direction="inbound")` |
| What does X call? | `trace_path(function_name="X", direction="outbound")` |
| Full call context | `trace_path(direction="both")` |
| Find by name pattern | `search_graph(name_pattern=".*Pattern.*")` |
| Scope to a directory | `search_graph(file_pattern="pkg/**")`, `search_code(path_filter="pkg/")` |
| Read a symbol | `get_code_snippet(qualified_name="pkg.mod.Func")` |
| Architecture, layers, entry points | `get_architecture(aspects=[...])` |
| Custom question | `query_graph(query="MATCH ... RETURN ...")` |
| What my edit touched | `detect_changes(scope="impact")` |
| Literal / config / doc text | `Grep`, `Read` |

## Workflow

1. `list_projects` — pick the project whose `root_path` contains the working directory.
   Pass its `name` (or the absolute directory) as `project`. Never pass a repo or folder name.
2. `index_status` — confirm the generation and `indexed_at` timestamp before trusting it.
   A stale index is worse than no index: it answers confidently and wrongly.
3. `search_graph` / `search_code` — find candidates, always scoped.
4. `get_code_snippet` — read the exact source of the candidate.
5. `trace_path` — callers and callees, inbound and outbound.
6. `check_index_coverage` — once, with every path the answer depends on.

## Evidence tiers

- **Scout** — quick positive lookup, few calls. Provisional; no negative claims.
- **Verify** (default) — task-directed graph evidence, relevant trace directions, exact
  snippets for material claims, coverage checked for the paths used.
- **Auditor** — bounded scope, complete pagination, both call directions, limitations stated.

State the tier in the answer. An answer without its source path is an assertion, not evidence.

## Index maintenance

- Index the repository you are working in, not the whole workspace. A workspace-wide index
  can exceed the per-process memory budget (`over_memory_budget`, 512 MB default); a failed
  run publishes nothing, so the previous index keeps serving.
- Override the budget with `CBM_MEM_BUDGET_MB` in the MCP server's environment, then
  restart the server.
- Nothing is indexed automatically. After a repo changes materially, re-index it.
- `mode="moderate"` (filtered + semantics) is the right default; `mode="fast"` skips semantics.

## Traps

- "No callers" is not dead code: entry points, `main`, tests and script bodies have none.
- The only negation the parser accepts is `WHERE NOT EXISTS { (f)<-[:CALLS]-() }`.
- Degree/hotspot ranks lie on name collisions with stdlib; confirm by qualified name.
- Empty result ≠ absence. Check coverage, then fall back to text search and say so.
- `index_mode` metadata can disagree with the requested mode; verify with `index_status`.
- `scripts/` and `tools/` are often skipped by the index; use text search there.

## CLI fallback

When the MCP tools are unavailable, the same tools run locally:

```sh
codebase-memory-mcp cli --json list_projects
codebase-memory-mcp cli --json search_graph --project <name> --name_pattern ".*Foo.*"
codebase-memory-mcp cli <tool> --help
```

Look the exact flags up with `--help` rather than guessing them.
