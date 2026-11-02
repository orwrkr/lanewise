# Claude subscription budget: use it or lose it

The 5-hour window of a Claude subscription expires at its reset: what is not used by then is lost. API-billed
executors — `billing: api` in the registry (DeepSeek) and any profile with an API `key` — cost money per token. So
when the window is going to expire with a lot unused, work that would go to them should go to Claude instead.

The numbers are account-wide: every session on the account — other orchestrators, other projects, the apps — is
already in them. `orch` projects the window at the **current pace**: the higher of the window average and the pace
of the last 15–60 minutes, measured back from the same snapshot. Each window has its own measurement time;
projections are anchored to it and do not improve merely as the numbers age. A **reserve** (default 10% of the
window, 10% of the week) is kept for sessions orch doesn't know about and as a safety margin. The mode is in
`orch status` / SessionStart (the line `Claude subscription: …`) and arrives as a `💡` event when it changes:

- **SURPLUS** — at least N % of the window (N = the `claude` profile's `surplus`, default 30) would expire unused
  beyond the reserve, and the weekly limit has room beyond its reserve. The line names the active orchestrator
  sessions and each one's share of the surplus: plan for your share, not for the whole. Until the reset shown:
  - a subtask you would give to an API-billed executor goes to the cheapest Claude slot that handles its difficulty
    (a subagent; in a session led by another model — `orch run claude`);
  - Codex and the manual pool keep their tasks; on a tie between Claude and Codex, take Claude;
  - cross-review of Claude's code stays with Codex (DeepSeek only if Codex is unavailable);
  - don't spend for the sake of spending: no extra subtasks, no effort above what the task needs.
- **TIGHT** — the five-hour window reaches its reserve before reset, or the weekly used share has reached its
  reserve, or the weekly projection reaches it after at least 24 hours of the week have been measured. Weekly
  TIGHT works even without current five-hour numbers; without a weekly reset only the used share counts. The
  line names the weekly limit and its projection; the status line says `tight: weekly limit (N% projected);
  conserve Claude` (or the used share when projection is unavailable). Treat Claude as `low`: use the cheapest Claude slots, offload the rest to Codex / DeepSeek.
  An earlier weekly projection still blocks SURPLUS but cannot by itself raise TIGHT.
- **no mode in the line / no line** — route as usual (too early in the window to tell, or no numbers).

`orch budget` shows the numbers, the active consumers orch knows of (orchestrator sessions with the plugin seen in
the last 15 minutes, running `orch run claude` executors; sessions led by another model don't count) and the
thresholds.

## Where the numbers come from

Claude Code gives its status line command the subscription usage (`rate_limits`). Use `orch statusline` as the
status line once — in `~/.claude/settings.json`:

```json
"statusLine": {"type": "command", "command": "orch statusline"}
```

(or ask `/statusline` in Claude Code to set it). Every session that shows it adds samples to the shared history —
that is what the current pace and the session count are made of. To keep your own status line: `orch statusline
--then "<your command>"`. Without it the operator can tell you the numbers: "Claude: 40% of the session used,
resets at 18:00, week 60%" → `orch budget set --used 40 --resets 18:00 --week 60`.
Omitting `--week` preserves the weekly measurement time. Older snapshots fall back to their top-level `updated`.
Five-hour numbers older than 20 minutes show their age and cannot enable SURPLUS; TIGHT remains possible.
A reserve time already in the past is replaced by a warning instead of an obsolete clock time.

## Settings (profile `claude`)

`orch profile set claude <name> --opt reserve=25 --opt week_reserve=15 --opt surplus=40` (or `surplus=off`), then
`orch profile use claude <name>` for a project or `--default`. "Keep more for my other sessions" → raise `reserve`.
With the `claude` profile `off` there is no surplus mode (Claude is not used at all).
