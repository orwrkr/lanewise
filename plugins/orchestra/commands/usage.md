---
description: Session usage — which model (Claude, subagents, Codex, DeepSeek, manual agents) did what and how many tokens it spent
argument-hint: "[list | <session id>]"
---
The operator wants to see usage: "$ARGUMENTS"

- Empty → `orch usage` (current session). "list" → `orch usage --list`. ID or prefix → `orch usage --session <id>`.
- Show the table from the output as is (who · model · effort · for what · input · cache · output) and the
  per-model totals.
- Add 1–2 takeaways: what cost the most and what could go to a cheaper slot next time.
  Manual agents don't report tokens — for them only agent, model and time. Details — `orch guide usage`.
