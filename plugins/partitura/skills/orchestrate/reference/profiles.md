# Executor profiles

A profile is an executor's settings: which API key or account, which models and efforts are allowed, whether it may
write, which tasks to use it for, free-form rules. Each provider has a default profile; a project (or a directory
containing all its projects) can pin another profile or `off`. The built-in profile `default` is the plain
environment with no restrictions. Stored in `~/.partitura/profiles.json` (shared by all projects, not in the
repository). Effective ones — `orch status` / `orch profile show`; all of them — `orch profile list`; fields —
`orch profile set --help`.

| The operator says | Command |
|---|---|
| "move off this account above 30% per session, always stop at 90% or a balance of 1" | `orch profile set deepseek client --session-soft 30 --session-hard 90 --balance-floor 1` (balance API required; see `orch guide spend`) |
| "don't use DeepSeek in this project" | `orch profile use deepseek off` |
| "DeepSeek here — with the work key" | `orch profile use deepseek work` |
| "put it back to the default" | `orch profile use deepseek inherit` |
| "leave Codex alone by default" | `orch profile use codex off --default` |
| "for all projects in this folder — the work key" | `orch profile use deepseek work --path "/path/to/folder"` |
| "don't offer Antigravity in this project" | `orch profile use antigravity off` |
| "no Claude in this project" (no orch-* subagents, no `orch run claude`) | `orch profile use claude off` |
| "keep a quarter of the Claude window for my other sessions" | `orch profile set claude main --opt reserve=25` and `orch profile use claude main --default` |
| "Claude executor on the second account" | `orch profile set claude alt --home ~/.claude-alt`; the operator logs in there once (`CLAUDE_CONFIG_DIR=… claude`) |
| "add a DeepSeek profile work: key DEEPSEEK_API_KEY_WORK, flash only, no writing, tests and review only" | `orch profile set deepseek work --key DEEPSEEK_API_KEY_WORK --models deepseek-flash --write no --use-for tests,review` |
| "a second Codex account" | `orch profile set codex alt --home ~/.codex-alt`; the operator runs the login command from the output (`CODEX_HOME=… codex login`) themselves — login is interactive |
| "Codex here — on an API key" | `orch profile set codex work --key CODEX_API_KEY_WORK` and `orch profile use codex work` |
| "Claude here — on an API key" | `orch profile set claude work --key ANTHROPIC_API_KEY_WORK` and `orch profile use claude work` |
| "every session of mine — on that Claude key" | `orch profile use claude work --default` |
| "in Antigravity — Argon only and no more than one task" | `orch profile set antigravity argon --models gemini-4-argon --max-open 1` and `orch profile use antigravity argon` |
| "DeepSeek work — for open-source code only" | `orch profile set deepseek work --rules "open-source code only"` |
| "when the project's key runs out, use my own key and the usual routing" | `orch profile set deepseek work --fallback personal` (`--fallback none` clears it) |
| "all executors here must follow this requirement" | `orch profile rules --set "TEXT"` |

`orch profile rules` shows applicable project rules; `--clear` or `--set ""` removes an entry. Add
`--path /path/to/dir` to set or clear a directory's rules. All matching parent rules apply, outermost first.
These private operator requirements survive profile fallback; profile `rules` belong to the key and lapse with it.

- Never ask for or record the API key itself: the profile holds the variable name; the operator puts the value as a
  line `NAME=sk-…` into `~/.partitura/secrets.env`.
- A profile with an API `key` is **API-billed** (per token), not a subscription: no `Codex subscription:` /
  `Claude subscription:` budget line, no SURPLUS/TIGHT, and routing treats it as the offload lane. The key is
  *explicit-only* — only the profile's `key` supplies it; a `NAME=…` line in `secrets.env` alone never switches a
  login profile to API billing.
- `orch profile use claude <profile>` with a key profile also writes Claude Code's `apiKeyHelper` into the project's
  `.claude/settings.local.json` (git-excluded), so the session and its subagents bill to that key; `--default`
  writes it to the user settings. It takes effect after a restart (`/status` shows the active credential).
  Switching to a login profile (or `inherit` / `off`) removes the helper only when orch wrote it.
- `orch` strictly enforces `off`, models, `effort ≤` (lowers it with a note), the write ban and `max_open`;
  `only for`, `prefer for` and `rules` are yours to honour when choosing an executor. A manual profile's
  `max_open` is a hard cap for both `handoff new` and `take`: `--force` cannot bypass it (or `off`), but can
  bypass the operator's open-task limit and availability blocks.
- Precedence: `--profile` on the run (only at the operator's request) → session-wide choices (`ORCH_PROFILES`, set
  by `orch launch --no-claude` / `--use`) → the binding of the project or of the nearest directory above it → the
  provider's default → the built-in `default`.
- The DeepSeek and Claude headless executors deny reading `.env` and `.env.*`, including `.env.example` (a tracked
  one: `git show HEAD:.env.example`), deny Bash searches that would print ignored files (`grep`, `rg`, `git grep
  --no-index`; the Grep tool skips them), and forward the target project's `permissions.deny` Read and Bash rules.
  This stops accidents, not intent: checked against the real CLI, `cat .en*` still gets through. **Codex has no such
  rule:** its sandbox limits writes, not reads, so a Codex run can read `.env` in either mode. What an executor reads
  goes to its provider, so keep real secrets out of the working tree when that matters.
- **Fallback.** A profile with `fallback: <profile>` is replaced by that profile, for everything that resolves it
  (runs, `orch status`, `orch profile show`, the spend scope, the ledger label), while it is *exhausted*: its spend
  scope is at its limit under mode `stop`/`evaluate` (never under `continue`), or an availability entry on its own key
  (`deepseek@work`) is `exhausted`/`disabled` — what `orch run` records on an empty balance. `low`, an entry on the
  whole provider, a rate limit (the timed entry `orch run` records itself) and an unreadable
  `spend_limits.json`/`profiles.json` do not count: the project stays on its profile and the run refuses as before. So the exhausted profile's `prefer_for`, `use_for` and `rules` are gone at once and
  return by themselves when it has budget again (`orch spend reset` / a higher limit / `orch quota clear`); take the
  routing from `orch profile show`, never from the exhausted profile's rules. `orch profile show` prints
  `personal (fallback: work is at its limit)` while it applies and `fallback: personal` on the configured profile
  otherwise. The target is another profile of the same provider (or the built-in `default`), one level only (its own
  `fallback` is not followed); a deleted target means no fallback. `--profile` on a run bypasses it, and an
  exhausted profile then refuses (exit 75) — use it only at the operator's request. A Claude session's own thread
  stays on the key in its `apiKeyHelper` (`orch key` names the profile); only runs move. A session-wide choice
  (`ORCH_PROFILES`, `orch launch --use`) follows it like a binding. Two 💡 events: once on the move, once on the
  return.
- After a profile change, replan unstarted subtasks; tell the operator briefly what changed.
