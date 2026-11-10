---
description: Manual task pool (Antigravity and similar) — show it, take a task, mark one handed off, done or cancelled
argument-hint: "[show | AG-0004 to Antigravity | AG-0004 to Cursor | AG-0004 done | AG-0004 cancel | AG-0004 later]"
---
The operator about manual tasks: "$ARGUMENTS"

Workflow — per `orch guide manual`.

1. Empty or "show" → `orch handoff list`. Answer compactly: what's in the pool (ID, task, proposed agent
   and model, how long it has waited) and what's handed out (status, who is working). Mention the board
   `.lanewise/MANUAL.md`.
2. "AG-… to <agent>" / "I'll take AG-…" → `orch handoff take <ID> [--agent <agent>] [--model "<model>"] --clip`
   and show the card from the output in full: folder, model, line to paste (it is already on the clipboard).
   A task that changes files is made a worktree at the take; the card says where it works.
3. "AG-… done / blocked / didn't work out" → `orch handoff done <ID> --status DONE|BLOCKED|FAILED --note "…"`,
   then verify and integrate the result per `orch guide manual`.
4. "AG-… cancel" / "not doing it" → `orch handoff cancel <ID>`; if the task is still needed, run it automatically
   (the fallback from the card) and say whom you gave it to.
5. "AG-… later" / "I'll take it later" → `orch handoff hold <ID> [--until WHEN]`: pool checks leave it out. It
   isn't handed out: it stays in the pool until the operator says they took it, and you reclaim it if waiting for it
   starts to block other work. Undo → `orch handoff hold <ID> --off`.
