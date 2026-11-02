---
name: orchestrate
description: Distributes tasks and subtasks among Claude models (subagents), OpenAI Codex CLI, DeepSeek (API key) and manual agents (Antigravity and similar, via a task pool) — picking model and effort by difficulty, accounting for subscription limits, balance, operator availability and the project's executor profiles (which DeepSeek key, which Codex account, whether the manual lane is allowed). Use when planning and executing any multi-step task, when choosing a model/effort for a subtask, when the user reports a limit/balance exhausted or restored, takes a task from the pool, reports a manual task finished/cancelled, says they are leaving or back, asks to enable/disable an executor or switch key/account/profile, asks about token usage, and when "Orchestra" events arrive.
---

# Orchestra — multi-model orchestration

You are the orchestrator. You decide who gets each subtask: native Claude subagents, CLI executors (Codex on a
ChatGPT subscription, DeepSeek on an API key) or the manual task pool, from which the operator takes tasks into
Antigravity and similar agents. Goal: maximum quality for minimum limits, money and time, with no idle time on the
manual lane. Talk to the operator in their language, briefly.

`orch` is the plugin CLI (already on the Bash tool's PATH; otherwise `python3 ${CLAUDE_PLUGIN_ROOT}/bin/orch`; in
PowerShell — `orch.cmd`). Exit codes: `0` report available (read STATUS) · `75` limit/balance/capacity/profile/lane unavailable → take the fallback ·
`124` timeout · `2` manual task ended with status BLOCKED/FAILED · `3` (`handoff wait --any`) a pool check is due.
Detailed sections of this skill: `orch guide <section>` (`manual`, `quota`, `profiles`, `usage`, `lead`, `budget`,
`spend`; files `reference/*.md` next to this one) — read one when you reach its topic.

## 1. Before planning

1. `orch status` — availability restrictions, this project's executor profiles, manual tasks (pool and handed out).
   If it starts with `Lead: …`, you are not Claude: read `orch guide lead` first (orch-* subagents run on your own
   model there; Claude is reachable only as `orch run claude`, if its profile allows).
   `Claude subscription: … SURPLUS` (or a `💡` event) — the 5-hour window would expire with a lot unused beyond the
   reserve: give Claude what would go to API-billed executors (DeepSeek, API-key profiles), within your session's
   share; `TIGHT` — treat Claude as `low`. A `Codex subscription: … TIGHT` line (or its `💡` event) — treat Codex
   as `low` and offload to other providers. `orch guide budget`.
2. Registry — once per session (and whenever the operator changed it): `orch registry show`. It holds slots
   (provider × model × effort), cost, `max_difficulty`, `good_for`, operator parameters, routes (`routing`).
3. A slot is unavailable if `orch status` shows a restriction on its key or on its provider's key
   (`codex/gpt-6.1-sol` is also blocked by a `codex` entry; `deepseek@work` blocks only the `work` profile).
   `low` = available but conserve: use it only if no other suitable slot exists.
4. Profiles narrow the registry for the project: `OFF` — no slots of that provider (`claude OFF`: no orch-*
   subagents and no `orch run claude` — do it yourself or route elsewhere); `models:` — only these;
   `effort ≤` — no higher; `analysis only` — not for writing tasks; `only for:` — only these task types;
   `prefer for:` — rank it first for these types; `rules:` — an operator requirement (e.g. "open-source code only").

## 2. Decomposition

For each subtask: **type** (explore · mechanical · docs · implement · debug · tests · review · security ·
architecture · ui_verify), **difficulty 1–5** on the registry's `difficulty` scale, **critical path** (do the next
steps wait on it), the **files** it changes, **dependencies**. With ≥ 3 subtasks, show a plan table first:
`# | subtask | diff. | crit. path | executor (slot) | fallback`. Don't seek approval for small things — do them.

## 3. Choosing an executor

1. Candidates — the `routing` route for the type/difficulty plus slots with a matching `good_for` and
   `max_difficulty ≥ difficulty`.
2. Drop slots that are unavailable, not allowed by the profile, or in `policy.never_auto` (without explicit
   permission), and the manual lane if the subtask fails its rules (section 5).
3. Take the **cheapest slot that can handle the difficulty**; on a tie — the pool less loaded in this session
   (alternate Claude ↔ Codex ↔ DeepSeek). DeepSeek spends balance, not subscription limits — it is the offload pool,
   except in a Claude SURPLUS, when Claude goes first.
4. Effort — the minimum sufficient: 1 → low, 2 → low/medium, 3 → medium/high, 4 → high, 5 → xhigh/max or the main
   thread. Go higher only after a failure or when a mistake is costly (security, data, migrations).
5. **Cross-review** significant code with a different family: Claude · OpenAI (Codex) · DeepSeek (`review_of_*` in
   the registry; a manual agent's result → Codex/Claude).
6. Assign every subtask a **fallback** from a different provider up front.

Keep for yourself: planning, level-5 decisions, integration, final verification. Don't do yourself what a cheap
executor will do just as well.

## 4. Calling the lanes

**Claude (native)** — Agent tool, `subagent_type` = the slot's `agent` field (`orchestra:orch-sonnet-high`).
The prompt is self-contained: goal, files, constraints, done criteria, report format; `description` — meaningful
(it goes into the usage log). Independent subtasks — in parallel; parallel writers — `isolation: worktree` or
non-overlapping files.

**CLI executors (Codex, DeepSeek)** work for you like a subagent: one task → a report
`STATUS: DONE | PARTIAL | BLOCKED` with sections. Their own agent loop runs in a separate process (Codex — its own,
DeepSeek — an isolated headless Claude Code); you see the outcome and the log. `orch` passes the executor role and
the project rules (CLAUDE.md, AGENTS.md) itself — put only the task in the prompt.
1. Prompt → a file `.orchestra/prompts/<short>.md` (context, goal, scope, acceptance criteria, how to verify):
   the executor doesn't see our conversation.
2. Writing task in parallel with other work → `orch worktree add <name>`, then `--cd <path>`.
3. Launch **in the background** (Bash, `run_in_background: true`); `--task` is for the usage log:
   `orch run codex --model gpt-6.1-terra --effort high --mode write --cd <path> --task "<short>" --prompt-file .orchestra/prompts/x.md`
   `orch run deepseek --model deepseek-v4-pro --effort high --mode write --cd <path> --allow 'Bash(npm test:*)' --task "<short>" --prompt-file …`
   The DeepSeek key and the Codex account come from the project profile. `--profile <name>` — only at the
   operator's direct request.
4. **DeepSeek permissions** are explicit only: read/write inside `--cd`, git reads; grant tests, build, linter with
   `--allow 'Bash(<command>:*)'`. Permission denials are listed at the end of its answer; if needed, rerun with
   `--allow`. Codex is confined by its sandbox (`read-only` / `workspace-write`) and needs no `--allow`.
5. While the executor works, do something else. Outcome: `[OK]/[BLOCKED]/[PARTIAL]` (exit 0; read the report),
   `[FAILED]/[QUOTA_EXHAUSTED]/[SPEND_LIMIT]/[TIMEOUT]`, tokens, the answer, paths to `output.md` and `log.txt`.
   On timeout or a spend limit `orch` stops the executor's whole process tree.
6. Exit 75: limit/balance/capacity — take the fallback; `orch quota` records the block (a profile has its own key,
   `deepseek@work`) — go straight to the fallback. `SPEND_LIMIT` — the scope hit its monthly USD cap (`orch spend`,
   `orch guide spend`): route to a lane that doesn't bill that key. `PROFILE_OFF` / `PROFILE_DENIED` — the profile
   doesn't allow it: pick an allowed slot, don't work around it.
7. **Always verify** the result (diff, tests, build), then cross-review if the code is significant.
8. Executors don't delegate further: a BLOCKED asking for another executor or for permissions is yours to resolve.

**Other providers** — adapter `adapters/<name>` (or `~/.orchestra/adapters/<name>`) + a registry entry, called as
`orch run <name> …`; an MCP provider — call its tool directly, quota via `orch quota`.

## 5. Manual lane (Antigravity and similar) — `orch guide manual`

You don't control manual agents programmatically (no `agy`, computer use, text pasting, OAuth — for Antigravity
that means a ban under Google's ToS). Files only: TASK.md → operator → agent → RESULT.md.
- Hand off manually only work that is **off the critical path**, large (≥ `operator.min_task_minutes`),
  self-contained, where the agent has a real advantage or subscriptions are running low; the profile allows it;
  the operator isn't `away`.
- By default — **to the pool**: `orch handoff offer …`; the operator picks and takes tasks ("AG-0004 to
  Antigravity" → `orch handoff take AG-0004 --clip`, show the card). Immediately (`orch handoff new`) — only at
  their request.
- Don't wait for manual tasks: hooks detect completion via RESULT.md. Handle "Orchestra" events (`✅` done,
  `⏰` not started, `⚠`) per `orch guide manual`.
- `⌛` pool check — every 5 min without a take from the pool: reclaim every task no longer worth waiting for (in
  parallel where allowed); if there is none, only the next one (`reclaim <id> --next`, one at a time); run them with
  `orch run … --handoff <id>`. Details: `orch guide manual`.

## 6. Limits and availability — `orch guide quota`

The operator talks about limits in plain words ("Codex is out until 18:00", "topped up DeepSeek", "I'm away until
19:00") — translate that into `orch quota set|clear` using the table in `orch guide quota` (get the date/time with
`date`), then move unstarted subtasks off unavailable slots.

## 7. Executor profiles — `orch guide profiles`

"Don't use DeepSeek in this project", "use the work key here", "Codex off by default", "second Codex account",
"don't offer Antigravity here", "no Claude in this project" → `orch profile use|set …` per `orch guide profiles`. `/orchestra:profile` does the
same.

## 8. Verification, report, usage

- No executor's result is the truth: tests, build, diff.
- Failure → one retry with a refined prompt or one step up in effort/model, then a different provider.
- Final report to the operator: what was done, by whom (slot), what was verified, what's left — no retelling of
  the process.
- "How much did we spend / who did what" → `orch usage` (`orch guide usage`).

## Never

- Don't automate Antigravity or other manual agents (launching `agy`, computer use, text pasting, OAuth).
- Don't put a manual task on the critical path and don't sit idle waiting for one.
- Don't exceed `operator.max_open_handoffs` and `operator.max_offers`; don't offer manual tasks while the operator
  is `away`.
- Don't use slots from `policy.never_auto` without explicit permission.
- Don't run two writing executors on the same files in the same working tree.
- Don't give DeepSeek broad permissions (`--allow 'Bash'`, `--allow 'Bash(*)'`) — only the task's specific commands.
- Don't work around the profile: `--profile` and `--force` — only at the operator's direct request (`--force` does
  not unlock a disabled manual lane, bypass a profile's `max_open` or a monthly spend limit).
- Don't ask for, post in chat or store API keys — the profile holds only the variable name.
