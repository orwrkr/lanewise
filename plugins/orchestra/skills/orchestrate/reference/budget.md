# Claude subscription budget: use it or lose it

The 5-hour window of a Claude subscription expires at its reset: what is not used by then is lost. API-billed
executors — `billing: api` in the registry (DeepSeek) and any profile with an API `key` — cost money per token. So
when the window is going to expire half-unused, work that would go to them should go to Claude instead.

`orch` projects the window from the pace so far and reports a mode in `orch status` / SessionStart (the line
`Claude subscription: …`) and as a `💡` event when the mode changes:

- **SURPLUS** — at least N % of the window would expire unused (N = the `claude` profile's `surplus`, default 30)
  and the weekly limit has headroom. Until the reset shown:
  - a subtask you would give to an API-billed executor goes to the cheapest Claude slot that handles its difficulty
    (a subagent; in a session led by another model — `orch run claude`);
  - Codex and the manual pool keep their tasks; on a tie between Claude and Codex, take Claude;
  - cross-review of Claude's code stays with Codex (DeepSeek only if Codex is unavailable);
  - don't spend for the sake of spending: no extra subtasks, no effort above what the task needs.
- **TIGHT** — at this pace the window runs out before the reset: treat Claude as `low` — the cheapest Claude slots
  only, offload the rest to Codex / DeepSeek.
- **no mode in the line / no line** — route as usual (too early in the window to tell, or no numbers).

## Where the numbers come from

Claude Code gives its status line command the subscription usage (`rate_limits`). Use `orch statusline` as the
status line once — in `~/.claude/settings.json`:

```json
"statusLine": {"type": "command", "command": "orch statusline"}
```

(or ask `/statusline` in Claude Code to set it). To keep your own status line: `orch statusline --then "<your
command>"`. Without it the operator can tell you the numbers: "Claude: 40% of the session used, resets at 18:00,
week 60%" → `orch budget set --used 40 --resets 18:00 --week 60`. `orch budget` shows the current state.

## Switching it

`orch profile set claude <name> --opt surplus=off` (or `surplus=50` for a stricter threshold), then
`orch profile use claude <name>` for a project or `--default`. With the `claude` profile `off` there is no surplus
mode (Claude is not used at all).
