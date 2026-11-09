---
description: Run a task through the orchestrator — decompose it, assign models/effort, launch
argument-hint: "<task>"
---
Run the task through the `partitura:orchestrate` skill:

$ARGUMENTS

Order: `orch status` → registry (`orch registry show`, if not read yet in this session) →
decomposition → plan table for the operator (if ≥ 3 subtasks) → launch with a fallback for every subtask.
