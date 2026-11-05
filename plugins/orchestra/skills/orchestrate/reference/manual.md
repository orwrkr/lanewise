# Manual lane: Antigravity and other manual agents

You do NOT control Antigravity (or any manual agent) programmatically: no `agy`, computer use, text pasting,
proxies or OAuth. You prepare the task package as files; the operator opens the folder in the official app and
pastes one line. For Antigravity this is a Google ToS requirement — violating it gets the account banned.

The operator keeps **one folder open in the agent** — the project folder — and never switches it, the way they work
with Claude Code. A read-only task works right there; a task that changes files works in a worktree of its own that
`orch` makes **inside** the project folder (`.orchestra/wt/<id>`), so the window never moves.

## When to hand off manually

Only if ALL of these hold:
- the project profile doesn't disable the agent and allows the model (`orch status`);
- the subtask is **off the critical path** (nothing waits on it in the next steps) or has a parallel automated
  alternative;
- it is large (≥ `operator.min_task_minutes`) and self-contained — describable without our conversation;
- the agent has a real advantage (`good_for`: UI verification in a browser, broad survey, a second opinion from
  another family, long autonomous work) **or** Claude/Codex are running low;
- the operator is not `away`.

## Pool or immediately

- **Pool (default)** — `orch handoff offer`: the task waits until the operator picks it and takes it when
  convenient. TASK.md, the worktree of a task that changes files and the line to paste appear only when it is taken. Pool — at most `operator.max_offers`.
- **Immediately** — `orch handoff new`: only when the operator explicitly asked "give this to Antigravity now"
  or the task has already been discussed. Handed out at once — at most `operator.max_open_handoffs`.

Tasks in the pool don't count as handed out and don't hold the critical path: keep working, don't wait for them.
The profile's `max_open` is a hard cap on `new` and `take`, including with `--force`; the flag still bypasses
the operator's open-task limit and availability blocks. All `handoff` commands refuse inside a worker.

Manual state transitions and capacity checks share a project lock: only one concurrent `take` or `reclaim`
can win. A take reserves ownership before writing the task files and making the worktree outside the lock; failure returns it to the
pool unless it was cancelled meanwhile. IDs remain reserved even if the counter is lost or corrupt. CLI lock
waits are bounded; hooks and the status line skip busy state silently after a much shorter wait.

## Preparation

1. Accumulate small suitable tasks and hand them out **as a batch** in one TASK.md (parts 1..N, one RESULT.md).
2. **Read-only is the default.** The agent reads and reports; it may write one file, its RESULT.md, and is told to
   run no shell commands (each can stop and wait for the operator's confirmation). A task that changes files takes
   `--write`: `orch` makes a git worktree for it at the take, `<project>/.orchestra/wt/<id>` on branch `ag/<id>`
   (`--base <ref>` picks the start, default `HEAD`, and goes only with `--write`). The agent works only inside that
   folder and does not commit; TASK.md and RESULT.md stay in the project's `.orchestra/handoffs/<id>/` for both
   kinds. Several writing tasks may be open at once and the project folder may be dirty: each has its own tree. A git
   repository is needed for `--write` (`offer` and `new` refuse otherwise); a read-only task works anywhere.
   `--worktree` is gone (it fails with a line naming `--write`). Tools that walk hidden folders (jest, for one) may
   see an open nested worktree: exclude `.orchestra/` in their config if that matters.
3. Task body (stdin or `--prompt-file`) per this template:
   ```
   ## Context              — what the project is, what's already done, key files
   ## Goal                 — one paragraph, what result is needed
   ## Scope                — what may be changed / what must NOT be touched
   ## Acceptance criteria  — a checkable list
   ## How to verify        — exact commands (build, tests, browser scenario)
   ## Hints                — known pitfalls, file references
   ```
   `orch` adds the rest itself: the Orchestra executor role, references to the project rules (CLAUDE.md,
   AGENTS.md), the `RESULT.md` protocol (`STATUS:` + `AGENT: product · model`; the read-only or the writing one, with
   its worktree and "do not commit"). For
   Antigravity the project folder also gets one general rule `.agents/rules/orchestra-task.md` (always_on, written
   at each assignment when absent or different): it applies only when a message names a task id, so several open
   tasks do not mislead each other (a writing task is told to stay in its worktree). It stays after a task closes
   and is excluded from git.
4. To the pool:
   ```
   orch handoff offer --title "<short>" --model "Gemini 4 Argon" --model-key gemini-4-argon \
     --effort High --fallback "codex gpt-6.1-sol high" --check-min 5 \
     --prompt-file .orchestra/prompts/ag.md
   ```
   To the operator — one line: what you put in the pool and why. List: `orch handoff list`; the operator's board is
   `.orchestra/MANUAL.md` (it can be kept open in an editor).
5. The operator picks: "AG-0004 to Antigravity" / "I'll take AG-0004" / "AG-0004 to Cursor" →
   `orch handoff take AG-0004 [--agent cursor] [--model …] --clip` and show the card from the output in full
   (project folder, model, thinking level, line to paste; with `--clip` it is already on the clipboard; a writing
   task's card also says where it works, and that there is no need to open it). The line is one line; a read-only
   task's says to run no shell commands, a writing task's names its worktree, and both say that if the agent's file
   tools cannot open `.orchestra/` because git ignores it, it should say so in the chat and stop.
6. Immediately, bypassing the pool (the operator asked):
   ```
   orch handoff new --title "<short>" --model "Gemini 4 Argon" --model-key gemini-4-argon \
     --effort High --fallback "codex gpt-6.1-sol high" \
     --pickup-min 30 --reassign-min 180 --max-open 2 --clip --prompt-file .orchestra/prompts/ag.md
   ```
   (numbers — from `operator` in the registry).

## How completion is detected (the operator doesn't need to report back)

- The agent itself writes `RESULT.md`: `STATUS: IN_PROGRESS` at the start, `DONE/BLOCKED/FAILED` at the end, and an
  `AGENT:` line — who did the work. The plugin's hooks check it on every operator message, while you work (after
  tool calls, at most once a minute) and at the end of each of your turns (the Stop hook won't let you finish if a
  result has arrived — handle it).
- Parallel work is over and there's nothing else to wait for — run `orch handoff wait --any --timeout 8h` in the
  background and end the turn, briefly saying what you're waiting for. It returns when a handed-out task finishes
  (exit 0, or 2 on BLOCKED/FAILED) or when a pool check is due (exit 3, the `⌛` text below) — handle it, then start
  it again while anything is still pending. An unarchived final result already present when `wait --any` starts
  is returned once if it has not been reported; CANCELLED and REASSIGNED are excluded.
- The operator says "AG-0003 done" / "cancel AG-0003" → `orch handoff done AG-0003` / `orch handoff cancel AG-0003`.

## "Orchestra" events

- `✅ … finished: STATUS DONE` → read RESULT.md. For a writing task: `git -C <worktree> status` and `diff`, check
  that the project folder got no stray edits from the agent, run the tests in the worktree, check the acceptance
  criteria and cross-review via Codex/Claude, commit on `ag/<id>` yourself, merge, then
  `orch handoff close <id> --remove-worktree`. A read-only task's findings are in RESULT.md. You need not keep your
  own edits out of the project folder: the agent works elsewhere.
- `STATUS BLOCKED/FAILED` → read RESULT.md; refine the task and hand it out again, or reassign.
- `⌛ Manual pool: no task taken for N min …` — a pool check (see below).
- `⏰ waiting for the operator for N min` (handed out but not started) → one short reminder, don't stop working.
- `⚠ … not started after N min` → `orch handoff cancel <id> --reassigned`, run it via the fallback, tell the
  operator.
- `⚠ … in progress for N min without a final status` → ask the operator once; don't reassign on your own.
  A read-only task works in the shared project folder, so a changed file there is never `STARTED?`: only its RESULT.md
  counts. A task with a worktree of its own (a writing task) shows `STARTED?` from changes in that worktree.

## Pool checks: taking tasks back

A full `orch handoff check` returns an assignment claim older than 10 minutes to the pool; an interrupted direct assignment is cancelled and archived.

The pool's clock runs from the operator's **last take** from the pool (or from when the pool opened, if nothing
was taken). Every `operator.pool_check_min` (5) minutes without a take, `orch` raises one `⌛` check: in a hook, or
`handoff wait --any` exits 3. A take restarts the clock; your reclaims do not — the checks go on every 5 minutes.
At each check:

1. **Reclaim every task no longer worth waiting for** — `orch handoff reclaim <id>` — and run them as you see fit:
   in parallel where they may run in parallel (independent, no shared files, separate worktrees from `orch worktree`),
   choosing slots by the profiles, quality, efficiency and cost as usual. Waiting is pointless when, for example: the operator is
   `away` (the check says so); the task has reached the critical path or blocks other work; the manual agent's
   advantage is small and an automated slot does it as well; the operator has ignored the pool for several checks
   in a row; the session is wrapping up; the task has gone stale.
2. **If there is none, reclaim only the next one** (the oldest, unless the order matters otherwise):
   `orch handoff reclaim <id> --next` — but only while no previous "next" task is still running; `orch` refuses a
   second one (`NEXT_BUSY`, exit 75). This drains the pool one task at a time while waiting still makes sense.
3. Run a reclaimed task with `orch run … --handoff <id>` — a successful run marks it finished and frees the
   "next" slot; if you did it another way (subagent, yourself) or gave up, `orch handoff done <id>` (or
   `--status FAILED`). Nothing worth doing at a check and nothing to reclaim → leave the pool as it is.
   A PARTIAL or BLOCKED report keeps the slot busy until `orch handoff done <id>`.
4. To the operator — one line per check: what you took back and why.

When the operator says they'll take a task later, keep it: `orch handoff hold <id>` (`--until WHEN` to come back
by itself, `--off` to undo). Checks leave a held task out; a take or a reclaim ends the hold. Hold a task only on the
operator's word, never to quiet the checks.

## Other manual agents

Cursor, Windsurf, Jules, Kiro, etc. — the same lane: `orch handoff take <id> --agent cursor` (or
`--provider cursor` on `offer`/`new`). TASK.md is self-contained for any agent; profile and quota are kept under
the agent's name (`orch profile use cursor off`, `orch quota set cursor exhausted`).

## Older tasks, other folders

- A task handed out by an older version has its worktree next to the project (`<project>.wt/<id>`); it keeps
  working (card, `check`, `done`, `close --remove-worktree`). An offered task of an older version without the `write`
  field made no promise: it counts as writing and gets a nested worktree at the take.
- A folder that is not a git repository can hold read-only manual tasks: nothing needs git there. `--write` is
  refused at `offer` and `new` there (an old offer that counts as writing is not taken: run it automatically).
- If `.orchestra/` is deleted by hand, git keeps stale worktree entries: run `git worktree prune` in the project.
- A take refuses when something at `.orchestra/wt/<id>` isn't that task's worktree: a plain folder there would make git
  answer for the project around it. Look at it, remove it, take again. A task whose preparation failed after its
  worktree was made keeps it on record: a later take reuses it, and a failed `new` is cleaned up with
  `orch handoff close <id> --remove-worktree`.

## Moving the project or switching Windows/WSL

A task's `meta.json` stores its paths relative to the project root, not absolute, so the `.orchestra/` state
survives a moved project folder and the same folder opened from native Windows or from WSL. The board, the
handoff card and `orch handoff` output still print absolute paths for the environment they run in.

Out of scope: a git worktree's own links. Git stores absolute paths in `.git` and `worktrees/`, so moving the
project breaks a task's worktree until `git worktree repair`, and a worktree created on Windows does not work
from WSL. Recreate or repair the worktree yourself; the manual lane does not automate that.
