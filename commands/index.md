---
description: Index the current repository into the codebase-memory knowledge graph and verify it.
---

Index the current working directory into the codebase-memory knowledge graph, then verify it.

1. If this directory is a sub-repository of a larger workspace, index the sub-repository.
   A workspace-wide index can exceed the per-process memory budget; a failed run publishes
   nothing and the previous index keeps serving.
2. Call `index_repository` with `repo_path` set to the repository root, `mode="moderate"`
   and `persistence=true`. For a large repository use `async=true` and poll `index_status`
   until the job succeeds.
3. If the job fails with `over_memory_budget`, do not repeat the same call. Report the peak
   RSS and the suggested budget, and give the fix: set `CBM_MEM_BUDGET_MB` in the MCP
   server's environment and restart it.
4. Verify: call `index_status`, then one `query_graph` proving a symbol from this repository
   is present with its call edges.

Report the counts, the `indexed_at` timestamp and the verification result.
