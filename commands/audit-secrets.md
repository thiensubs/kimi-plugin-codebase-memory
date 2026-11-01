---
description: List credential-looking file paths in the codebase-memory index and exclude them with .cbmignore.
---

Audit the indexed graph for credential-looking file paths. Report **paths only** — never open,
read or print the contents of a file this command finds, and never quote a value from one.

1. Resolve the project: `codebase-memory-mcp cli list_projects --format json`, then pick the
   entry whose `root_path` contains the working directory. Use that `name` verbatim as
   `<project>`; never pass a repo folder name.

2. Broad sweep — everything that could be a credential file:

   ```sh
   codebase-memory-mcp cli query_graph --project <project> --format json --max-rows 500 \
     --query "MATCH (f:File) WHERE f.file_path =~ '(^|/)([.]env[^/]*|[.]aws|[.]ssh|credentials[^/]*|secrets?[^/]*|id_rsa[^/]*|[^/]*[.]pem|tokens?[^/]*)' RETURN DISTINCT f.file_path AS path ORDER BY path"
   ```

3. Strict sweep — basename anchored, so substring noise separates from real hits
   (`tokenCounting.ts` matches the broad pattern and is harmless):

   ```sh
   codebase-memory-mcp cli query_graph --project <project> --format json --max-rows 500 \
     --query "MATCH (f:File) WHERE f.file_path =~ '(^|/)([.]env([.][^/]*)?|credentials([.][^/]+)?|secrets?([.][^/]+)?|id_rsa[^/]*|[^/]+[.]pem|tokens?[.][^/]+)$' RETURN DISTINCT f.file_path AS path ORDER BY path"
   ```

   Both patterns are written without backslashes on purpose: a backslash has to survive the
   shell **and** Cypher's string literal, and over-escaping turns `\.env` into "backslash then
   any character". `[.]` is the same intent and survives both parsers.

4. Report, in this order: the two totals, the strict list one path per line, then the
   broad-only extras as a count plus at most five examples. A path is the whole finding — do
   not `Read` it, do not `Grep` it, do not `get_code_snippet` it, do not sample it.

5. If a real credential file is indexed (`.env`, `.pem`, `id_rsa*`, `credentials.*`, `.aws/`,
   `.ssh/`), say plainly that the index is serving a path that must never enter a prompt.

Then recommend the exclusion and how to apply it:

- Propose exact `.cbmignore` entries for the repository root, one per line: `.env`, `.env.*`,
  `*.pem`, `*.key`, `credentials.*`, `secrets.*`, `**/id_rsa*`, `.ssh/`, `.aws/`, and any
  vendored credential config the sweep actually found.
- The built-in skip list already covers many of these; add only the gaps this audit reported,
  because a rule for a path that is absent changes nothing.
- Re-index the repository — not the workspace root — after editing `.cbmignore`: `index_repository`
  with `mode="moderate"` and `persistence=true`, then `index_status` to confirm the new
  `indexed_at`. A path already in the graph keeps answering until a successful re-index replaces
  it; deleting the file from disk is not enough.
- If the re-index fails with `over_memory_budget`, do not repeat it: report the peak RSS and give
  the fix — `CBM_MEM_BUDGET_MB` in the MCP server's environment, then restart.

Keep the whole report under 20 lines. No preamble.
