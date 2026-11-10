# Usage log: who, with which model, for what, how many tokens

`orch usage` — a report for a Claude Code session (the current one by default):

| Row | Data source |
|---|---|
| orchestrator (main thread) | the Claude Code session transcript: model, effort, tokens of every response |
| subagent `orch-…` | the session's subagent files: agent type, task description (the `description` field of the Agent call), model |
| `codex`, `deepseek@work`, … | the log `~/.lanewise/usage.jsonl`: `orch run` runs (model, `--task` or the prompt's first line, status, time, tokens from the adapter) |
| `antigravity (manual)` | manual tasks: agent and model from the `AGENT:` line in RESULT.md, status, time; manual agents don't report tokens |

- `orch usage --list` — the project's recent sessions (and one row for the records made outside any session);
  `orch usage --session <id>` — a specific one (an id prefix works); `--json` — for parsing.
- Usage is collected per Claude Code session. From a terminal nothing is current: pick a session from `--list` and
  pass it as `--session <id>`; `--session none` shows the runs and manual tasks logged with no session (a manual
  task closed from a terminal, an `orch run` outside a session). No data is not an error.
- Tokens: "input" — uncached (for Claude including cache writes), "cache" — cache reads, "output". Totals — per
  model. For Claude Code, also its own cost estimate at API prices (nominal on a subscription).
  A forked session's copied history is not counted again.
- Claude Code transcripts are deleted over time; when a session ends, the SessionEnd hook saves its figures to the
  log, and a report on an old session is built from there.
- To make "for what" readable in the report: give Agent calls a meaningful `description`, and `orch run` a
  `--task "<short>"` (otherwise the prompt's first line is used).
- The operator asks "how much did we spend / who did what" → `orch usage`; answer with a compact table and 1–2
  takeaways (what cost the most, what could have gone to a cheaper slot).
