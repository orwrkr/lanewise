# ───────────────────────── handoffs (manual lane) ─────────────────────────

MANUAL_ROLE = """> You are an executor in the Orchestra system. This task comes from the orchestrator — Claude Code,
> which runs the work together with the operator and checks the result itself (diff, tests) before accepting it.
> The operator only handed you the task: work autonomously and do not message them about it. Everything you need
> is in this file and in the project rules.
"""

PROTOCOL_START = """
---

## Execution protocol (follow it strictly)

1. **Right at the start** create the file `{rel}/RESULT.md` with your file editor, with two lines:
   `STATUS: IN_PROGRESS`
   `AGENT: <product and model, e.g. Antigravity · Gemini 3.8 Flash>`
"""
# A task that changes nothing (the default): the agent reads and reports. It runs in the project folder, where other
# work goes on, so it may write one file only, and it is told not to run commands that could wait for confirmation.
PROTOCOL_READ = PROTOCOL_START + """2. This task changes nothing: change no file except `{rel}/RESULT.md`, and do not commit. Other work goes on in this
   folder, so leave its files and branches alone.
3. Run no shell commands unless this task lists them: each one can stop and wait for the operator's confirmation. If
   you think you need one, write in your report what you wanted to know instead.
4. Do not start other agents or `orch`: assigning tasks is the orchestrator's job.
5. Check the result against the acceptance criteria.
6. **When finished**, overwrite `{rel}/RESULT.md`. The first line is exactly one of:
   `STATUS: DONE` · `STATUS: BLOCKED` · `STATUS: FAILED`
   The second is the same `AGENT: …` line. Then the sections: `## Summary` (your findings), `## Verification`,
   `## Open questions`.
7. Writing RESULT.md with a final status is the completion signal for the orchestrator. Change nothing after that.
"""
# A task that changes files (--write): it works in a worktree of its own inside the project folder, made by orch, and
# leaves the changes uncommitted for the orchestrator to review and commit.
PROTOCOL_WRITE = PROTOCOL_START + """2. Work only inside `{wt}`, a separate git worktree on branch `{branch}`. It is a full copy of the project, with the
   same paths as the project folder around it: every file you read or change for this task must be under that
   folder, never its same-named original at the project root. Local files (`.env`, `node_modules`, builds) may be
   missing: install dependencies as the project instructions say; do not copy secrets: if you need one,
   `STATUS: BLOCKED`. In `.orchestra/` outside that folder touch nothing except `{rel}/RESULT.md`.
3. Do not start other agents or `orch`: assigning tasks is the orchestrator's job.
4. Check the result against the acceptance criteria (run the listed commands/tests).
5. Do not commit and do not switch branches: the orchestrator reviews the changes in that worktree and commits them.
6. **When finished**, overwrite `{rel}/RESULT.md`. The first line is exactly one of:
   `STATUS: DONE` · `STATUS: BLOCKED` · `STATUS: FAILED`
   The second is the same `AGENT: …` line. Then the sections: `## Summary`, `## Changed files`,
   `## Verification` (commands and their outcome), `## Open questions`.
7. Writing RESULT.md with a final status is the completion signal for the orchestrator. Change nothing after that.
"""
# The paste line is one line, for the clipboard too. Both kinds stop where the agent's file tools cannot open
# .orchestra/ (git ignores it) instead of reaching it through the terminal; a read-only task also runs no commands.
PASTE_BASE = ("Execute the task described in {rel}/TASK.md, by the execution protocol at the end of that file "
              "(RESULT.md status markers).")
PASTE_STOP = (" If your file tools can't open .orchestra/ because git ignores it, don't use the terminal to get "
              "around that: say so in the chat and stop.")
PASTE_READ = PASTE_BASE + " Run no shell commands unless the task lists them." + PASTE_STOP
PASTE_WRITE = PASTE_BASE + " Work only inside {wt}, a separate git worktree." + PASTE_STOP
# Antigravity loads .agents/rules/*.md of the workspace (trigger always_on → every turn): the protocol survives
# long sessions and context compaction. One general rule in the project folder, because several tasks can be open
# in it and a rule naming one of them would mislead the others. It stays after a task closes; git excludes it.
AG_RULE_PATH = ".agents/rules/orchestra-task.md"
AG_RULE = """---
trigger: always_on
---
# Orchestra tasks

This applies only when a message names an Orchestra task (an id such as AG-0004); other conversations ignore it.
The task file is `.orchestra/handoffs/<id>/TASK.md`; carry it out strictly by the protocol at the end of that file.
- At the start — `.orchestra/handoffs/<id>/RESULT.md` with the lines `STATUS: IN_PROGRESS` and `AGENT: <product · model>`.
- At the end — the same file with `STATUS: DONE | BLOCKED | FAILED` and the report sections: without it the
  orchestrator will not know the task is finished.
- The project rules ({rules}) are mandatory; scope — that task only; in `.orchestra/` — only that task's RESULT.md and, for a task that changes files, its own worktree.
- A task that changes files names its own worktree: work only inside it.
"""
AGENT_RE = re.compile(r"^\s*AGENT:\s*(.+?)\s*$", re.M)
AGENT_NAMES = {"antigravity": "Antigravity", "cursor": "Cursor", "windsurf": "Windsurf", "jules": "Jules",
               "kiro": "Kiro", "copilot": "GitHub Copilot"}
OPEN_TAKEN = ("WAITING", "STARTED?", "IN_PROGRESS")


def agent_name(provider):
    return AGENT_NAMES.get((provider or "").lower(), provider or "manual agent")


