---
description: Show the codebase-memory index state for this directory and whether it is fresh.
---

Report the codebase-memory index state for the current working directory.

1. Call `list_projects` and pick the project whose `root_path` contains the working directory.
2. Call `index_status` for that project and report: `indexed_at`, file count, node count,
   edge count, watch state, and any coverage gaps.
3. If the index is older than the working tree or missing files that exist on disk, say so
   plainly and give the exact re-index command for that repository — not for the workspace root.
4. If a project is missing entirely, say which directory has no index and give the
   `index_repository` call that creates one.

Answer in under 12 lines. No preamble.
