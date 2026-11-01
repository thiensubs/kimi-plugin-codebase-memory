---
description: Re-index the current repository after changes and show what the change touched.
---

Re-index the current repository after recent changes, then show the blast radius.

1. Call `detect_changes(scope="impact")` for the current project and summarise the changed
   symbols and their inbound callers. This is the cheap pass — do it before re-indexing.
2. Re-index the repository that owns those files with `index_repository`
   (`mode="moderate"`, `persistence=true`), not the workspace root.
3. Re-run `detect_changes` after the index and confirm the affected symbols now resolve.
4. Call `check_index_coverage` once with every path you relied on and report any partial
   or skipped range — a file the graph only partially parsed will not answer for those lines.

Report: what changed, who calls it, what the graph could not cover, and the new
`indexed_at` timestamp.
