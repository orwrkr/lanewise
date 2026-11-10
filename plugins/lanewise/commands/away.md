---
description: The operator is unavailable (manual lane closed) until a given time, or is back
argument-hint: "[until 19:00 | back]"
---
Operator: "$ARGUMENTS"

- If the operator is back → `orch quota clear operator`, then `orch handoff list` and briefly: are there
  tasks worth handing them now (as a batch).
- Otherwise get `date` and run `orch quota set operator away --until <time>` (no time given — without `--until`).
  Don't create new manual tasks; consider tasks already handed out but not started (`WAITING`) for
  reassignment to automated slots if they are on the critical path.
