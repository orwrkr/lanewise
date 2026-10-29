# Executor profiles

A profile is an executor's settings: which API key or account, which models and efforts are allowed, whether it may
write, which tasks to use it for, free-form rules. Each provider has a default profile; a project (or a directory
containing all its projects) can pin another profile or `off`. The built-in profile `default` is the plain
environment with no restrictions. Stored in `~/.orchestra/profiles.json` (shared by all projects, not in the
repository). Effective ones — `orch status` / `orch profile show`; all of them — `orch profile list`; fields —
`orch profile set --help`.

| The operator says | Command |
|---|---|
| "don't use DeepSeek in this project" | `orch profile use deepseek off` |
| "DeepSeek here — with the work key" | `orch profile use deepseek work` |
| "put it back to the default" | `orch profile use deepseek inherit` |
| "leave Codex alone by default" | `orch profile use codex off --default` |
| "for all projects in /path/to/work — the work key" | `orch profile use deepseek work --path "/path/to/work"` |
| "don't offer Antigravity in this project" | `orch profile use antigravity off` |
| "no Claude in this project" (no orch-* subagents, no `orch run claude`) | `orch profile use claude off` |
| "Claude executor on the second account" | `orch profile set claude alt --home ~/.claude-alt`; the operator logs in there once (`CLAUDE_CONFIG_DIR=… claude`) |
| "add a DeepSeek profile work: key DEEPSEEK_API_KEY_WORK, flash only, no writing, tests and review only" | `orch profile set deepseek work --key DEEPSEEK_API_KEY_WORK --models deepseek-flash --write no --use-for tests,review` |
| "a second Codex account" | `orch profile set codex alt --home ~/.codex-alt`; the operator runs the login command from the output (`CODEX_HOME=… codex login`) themselves — login is interactive |
| "in Antigravity — Argon only and no more than one task" | `orch profile set antigravity argon --models gemini-4-argon --max-open 1` and `orch profile use antigravity argon` |
| "DeepSeek work — for open-source code only" | `orch profile set deepseek work --rules "open-source code only"` |

- Never ask for or record the API key itself: the profile holds the variable name; the operator puts the value as a
  line `NAME=sk-…` into `~/.orchestra/secrets.env`.
- `orch` strictly enforces `off`, models, `effort ≤` (lowers it with a note), the write ban and `max_open`;
  `only for`, `prefer for` and `rules` are yours to honour when choosing an executor.
- Precedence: `--profile` on the run (only at the operator's request) → session-wide choices (`ORCH_PROFILES`, set
  by `orch launch --no-claude` / `--use`) → the binding of the project or of the nearest directory above it → the
  provider's default → the built-in `default`.
- After a profile change, replan unstarted subtasks; tell the operator briefly what changed.
