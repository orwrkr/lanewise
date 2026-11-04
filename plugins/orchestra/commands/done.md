---
description: Mark a manual task (AG-…) done/blocked/cancelled if Antigravity didn't write RESULT.md
argument-hint: "<AG-0001> [done|blocked|failed|cancel] [note]"
---
The operator reports on a manual task: "$ARGUMENTS"

1. Determine the ID and the outcome. Default — done.
   - done/blocked/failed → `orch handoff done <ID> --status DONE|BLOCKED|FAILED --note "<note>"`
   - cancel → `orch handoff cancel <ID> --note "<note>"`
2. For DONE: verify the result and integrate it per `orch guide manual`
   (RESULT.md, `git diff` of a writing task, tests, cross-review, your own commit, `orch handoff close`).
3. For BLOCKED/FAILED/cancel: reassign the task to its fallback, or refine it and hand it out again.
