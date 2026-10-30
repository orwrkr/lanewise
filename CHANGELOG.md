# Changelog

## 0.6.0

- **Budget reserve**: a share of the Claude window (default 10%) and of the week (10%) is kept for other sessions
  and as a safety margin — profile `claude`: `--opt reserve=N`, `week_reserve=N`. TIGHT now means "reaches the
  reserve before the reset", SURPLUS counts only what would be left beyond it.
- **All instances in the forecast**: the pace is the higher of the window average and the last 15–60 minutes of
  samples, which every session's `orch statusline` adds to a shared history — so the projection follows every
  instance consuming right now. Active orchestrator sessions and running Claude executors are tracked in
  `~/.orchestra/sessions.json`; a surplus is split between the active sessions; `orch budget` lists them.

## 0.5.0 — first public release

- **DeepSeek as the lead**: `orch launch deepseek` starts Claude Code with DeepSeek as the orchestrator; `--no-claude`
  keeps Claude models out of the session entirely; `--use PROVIDER=PROFILE` picks profiles for the session.
- **Claude budget mode**: `orch statusline` records the subscription usage Claude Code reports; when the 5-hour
  window would expire largely unused (a surplus), the orchestrator gives Claude what would go to API-billed
  executors, and when it would run out early (tight) it conserves Claude (`orch budget`, profile `surplus=N|off`).
- **Claude executor** (`orch run claude`): headless Claude Code on your own Claude login — the Claude lane of a
  non-Claude lead; `orch profile use claude off` turns Claude workers off.
- **Manual pool checks**: every 5 minutes without a take from the pool (`operator.pool_check_min`) the
  orchestrator reclaims every task no longer worth waiting for, or else just the next one — one at a time
  (`orch handoff reclaim --next`, `orch run --handoff`); `orch handoff wait --any` wakes it up for the checks.
  Replaces the 45-minute per-task timeout.
- Marketplace renamed `orchestra-local` → `orchestra`; `install.sh` migrates an existing installation.
- Everything in English; MIT license; CI on Ubuntu and Windows.

## 0.4.0

- Codex CLI and DeepSeek executors (isolated workers with a role brief), WSL and native Windows.
- Executor profiles: keys and accounts, models, effort ceiling, write ban, rules, project and directory bindings.
- The manual task pool for Antigravity and similar agents, the `.orchestra/MANUAL.md` board, the always-on
  Antigravity rule in the task's worktree.
- Per-session usage log (`orch usage`), project rules for every executor, `orch guide`, `orch footprint`,
  `uninstall.sh`.
