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
- The operator asks "how much did each provider spend on this project last week / this month", or wants a spend
  figure when the provider's console is out of reach → `orch usage --daily --days 7` (`--since YYYY-MM-DD` /
  `--until YYYY-MM-DD`, `--by day`, `--provider` / `--model` / `--key`, `--project PATH`, `--all-projects` for every
  project with its split, `--json` / `--csv`); the account is the profile label (the key's variable name also
  matches `--key`). Totals are kept for 60 days; an executor run counts on the day it ended, a session by each
  message's day. For a subscription (Claude login, Codex account) the report adds the project's estimated share of
  the weekly and 5-hour limits by tokens and cost, with separate coverage for each window (only days with tokens
  and limit samples); zeros and missing samples are explicit, also per day, in JSON and CSV. Say it is measured
  against this machine's sessions only; cache reads are excluded from the token share.
- Lead billing is API when the environment has an Anthropic key/token or Bedrock/Vertex/Foundry switch, the native
  account is a key profile, or the lead is not Claude; otherwise it is subscription, frozen on first observation.
