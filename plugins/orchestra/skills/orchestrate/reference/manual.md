# Manual lane: Antigravity and other manual agents

You do NOT control Antigravity (or any manual agent) programmatically: no `agy`, computer use, text pasting,
proxies or OAuth. You prepare the task package as files; the operator opens the folder in the official app and
pastes one line. For Antigravity this is a Google ToS requirement — violating it gets the account banned.

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
  convenient. The worktree and the line to paste appear only when it is taken. Pool — at most `operator.max_offers`.
- **Immediately** — `orch handoff new`: only when the operator explicitly asked "give this to Antigravity now"
  or the task has already been discussed. Handed out at once — at most `operator.max_open_handoffs`.

Tasks in the pool don't count as handed out and don't hold the critical path: keep working, don't wait for them.

## Preparation

1. Accumulate small suitable tasks and hand them out **as a batch** in one TASK.md (parts 1..N, one RESULT.md).
2. Writing task → always `--worktree` (its own branch `ag/<id>`, no conflicts with you or Codex).
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
   AGENTS.md), the `RESULT.md` protocol (`STATUS:` + `AGENT: product · model`), a note about the worktree. For
   Antigravity the task's worktree also gets the rule `.agents/rules/orchestra-task.md` (always_on), so the
   protocol isn't lost in a long session; it is excluded from git.
4. To the pool:
   ```
   orch handoff offer --title "<short>" --model "Gemini 4 Argon" --model-key gemini-4-argon \
     --effort High --worktree --fallback "codex gpt-6.1-sol high" --check-min 5 \
     --prompt-file .orchestra/prompts/ag.md
   ```
   To the operator — one line: what you put in the pool and why. List: `orch handoff list`; the operator's board is
   `.orchestra/MANUAL.md` (it can be kept open in an editor).
5. The operator picks: "AG-0004 to Antigravity" / "I'll take AG-0004" / "AG-0004 to Cursor" →
   `orch handoff take AG-0004 [--agent cursor] [--model …] --clip` and show the card from the output in full
   (folder, model, thinking level, line to paste; with `--clip` it is already on the clipboard).
6. Immediately, bypassing the pool (the operator asked):
   ```
   orch handoff new --title "<short>" --model "Gemini 4 Argon" --model-key gemini-4-argon \
     --effort High --worktree --fallback "codex gpt-6.1-sol high" \
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
  it again while anything is still pending.
- The operator says "AG-0003 done" / "cancel AG-0003" → `orch handoff done AG-0003` / `orch handoff cancel AG-0003`.

## "Orchestra" events

- `✅ … finished: STATUS DONE` → verify: the diff of branch `ag/<id>` (`git -C <worktree> log/diff`), tests,
  acceptance criteria; cross-review via Codex/Claude; merge; `orch handoff close <id> --remove-worktree`
  (remove the worktree only once the branch is merged).
- `STATUS BLOCKED/FAILED` → read RESULT.md; refine the task and hand it out again, or reassign.
- `⌛ Manual pool: no task taken for N min …` — a pool check (see below).
- `⏰ waiting for the operator for N min` (handed out but not started) → one short reminder, don't stop working.
- `⚠ … not started after N min` → `orch handoff cancel <id> --reassigned`, run it via the fallback, tell the
  operator.
- `⚠ … in progress for N min without a final status` → ask the operator once; don't reassign on your own.

## Pool checks: taking tasks back

The pool's clock runs from the operator's **last take** from the pool (or from when the pool opened, if nothing
was taken). Every `operator.pool_check_min` (5) minutes without a take, `orch` raises one `⌛` check: in a hook, or
`handoff wait --any` exits 3. A take restarts the clock; your reclaims do not — the checks go on every 5 minutes.
At each check:

1. **Reclaim every task no longer worth waiting for** — `orch handoff reclaim <id>` — and run them as you see fit:
   in parallel where they may run in parallel (independent, no shared files, separate worktrees), choosing slots by
   the profiles, quality, efficiency and cost as usual. Waiting is pointless when, for example: the operator is
   `away` (the check says so); the task has reached the critical path or blocks other work; the manual agent's
   advantage is small and an automated slot does it as well; the operator has ignored the pool for several checks
   in a row; the session is wrapping up; the task has gone stale.
2. **If there is none, reclaim only the next one** (the oldest, unless the order matters otherwise):
   `orch handoff reclaim <id> --next` — but only while no previous "next" task is still running; `orch` refuses a
   second one (`NEXT_BUSY`, exit 75). This drains the pool one task at a time while waiting still makes sense.
3. Run a reclaimed task with `orch run … --handoff <id>` — a successful run marks it finished and frees the
   "next" slot; if you did it another way (subagent, yourself) or gave up, `orch handoff done <id>` (or
   `--status FAILED`). Nothing worth doing at a check and nothing to reclaim → leave the pool as it is.
4. To the operator — one line per check: what you took back and why.

## Other manual agents

Cursor, Windsurf, Jules, Kiro, etc. — the same lane: `orch handoff take <id> --agent cursor` (or
`--provider cursor` on `offer`/`new`). TASK.md is self-contained for any agent; profile and quota are kept under
the agent's name (`orch profile use cursor off`, `orch quota set cursor exhausted`).
