# Changelog

## 0.10.0

- **Spend limits for API-billed executors**: `orch spend` caps how much DeepSeek (always) and Codex/Claude on a key
  profile may spend — default $10, per scope (a profile label), with a global counter and a separate counter per
  project that sets its own limit. `stop` refuses a new run at the limit and kills a running one that crosses it;
  `evaluate` (the executor default) refuses at the start but lets a running one finish until the limit plus an
  overrun (default 20%); `continue` (the lead default) only warns. `--force` does not bypass it, like profile
  `max_open`. A refused or killed run exits 75 (`SPEND_LIMIT`); a killed run logs the partial usage it spent.
- **Two kinds of limit**: a profile with an API key (prepaid — DeepSeek, Codex/Claude/Gemini on a key) has a
  **manual** counter that never rolls over; it stays blocked until the operator tops up and `orch spend reset
  <scope> [--limit N]` (the reset can also raise the limit). Everything else API-billed has a **monthly** counter
  that clears on the 1st. `--reset month|manual` overrides the default per scope; `--project [PATH]` sets a
  project's own counter; `orch spend limit default 20` sets the fallback.
- **Lead spend**: the orchestrator itself on a key is governed by a separate lead mode — `orch launch` refuses at the
  limit under `stop`/`evaluate`, and `orch key` (the apiKeyHelper) refuses past the threshold, which fails a Claude
  session's requests. A DeepSeek lead has no per-request hook, so only `orch launch` refuses at the start.
- **Live cost during a run**: headless adapters (DeepSeek, Claude) write `usage_live.json` per message; Codex's
  mid-run usage is read from its rollout `token_count` (best-effort). `orch run` polls every ~15 s and stops the
  whole process tree at the limit.
- **Counting**: spend is estimated from the usage ledger (tokens × `registry/prices.json`, overridden by a personal
  `~/.orchestra/prices.json`). The cost is frozen into each run's ledger entry as `cost_usd` (with the price
  `as_of`), so later price changes don't rewrite history; entries without it are priced when read. Counters are
  cached incrementally in `~/.orchestra/spend_cache.json` and restart on a shrunken ledger; a reset takes effect
  at once. Ledger entries and baselines carry microseconds, so a run that ended just before a reset stays out of the
  new count. `prices.json` now holds dated entries (promotions that end) and DeepSeek peak windows — the peak rate
  applies 01:00–04:00 and 06:00–10:00 UTC Mon–Fri and is halved otherwise. `orch spend` warns when a provider's
  prices are older than 30 days.
- **Surfaces**: `orch status` shows a line at ≥ 80%, the status line's `session in/out:` gains `deepseek $8.10/$10`,
  and a `💡` event fires once per counter period (per month or per baseline) at 80% and 100%. New guide section
  `orch guide spend`.

## 0.9.0

- **Codex on an API key**: `orch profile set codex <name> --key VAR` now works like DeepSeek — the profile's key is
  supplied to `codex exec` as `CODEX_API_KEY`. Only an explicit profile `key` turns the key on: a stray
  `CODEX_API_KEY=` line in `secrets.env` never switches a login profile to API billing (`# orch-secrets-explicit`).
  A key profile is API-billed: `orch status` shows no `Codex subscription:` line, no TIGHT, no `💡` event, and the
  status line shows no Codex limits, whatever the session logs hold. A rejected key (401) names the profile and
  exits 1 (no quota block); an exhausted balance still exits 75 via the existing limit detection.
- **Claude executor on an API key**: `orch run claude` on a key profile (and its `--key`) now treats the key as
  explicit-only, shows it as API-billed, and a 401 names the profile's key. Claude worker runs on a key project no
  longer count as subscription consumers.
- **The session itself on an API key**: `orch profile use claude <profile>` with a key profile writes Claude Code's
  `apiKeyHelper` into the project's `.claude/settings.local.json` (`--default` → user `settings.json` under
  `CLAUDE_CONFIG_DIR`), so the session and its subagents bill to that key. The helper runs the hidden
  `orch key claude@<profile>` (prints only the key; refuses inside a worker or a non-Claude lead). Switching to a
  login profile / `inherit` / `off` removes the helper only when orch wrote it; a broken settings file is refused;
  writes are atomic and locked. `--path` binds the profile for `orch run claude` only and says so.
- **Budget on a key**: a project whose Claude profile has a key bills to it, not the subscription — no SURPLUS/TIGHT,
  `orch status` says it bills to the key, the status line shows no subscription percentages from the shared snapshot,
  and the session does not write its numbers into that snapshot.

## 0.8.0

- **Codex limits in routing**: `orch status` reads the Codex account's rate limits from its session logs
  (`$CODEX_HOME/sessions/…/rollout-*.jsonl`, parsed defensively — the format is undocumented) and shows a
  `Codex subscription: 5-hour window … week …` line next to the Claude one, with `TIGHT: treat Codex as low`
  when a window or its projection reaches the reserve. The mode is announced as a `💡` event on change, like the
  Claude budget. No line when there is no current snapshot or the `codex` profile is `off`.
- **Status line**: two more lines, each left out when it has no data. The Codex limits, and `session in/out:` with
  the current session's cumulative tokens per provider (claude from the transcript, codex/deepseek from the usage
  ledger), in compact `k`/`M` form and without cache reads, agreeing with `orch usage`. Reads are incremental and
  cached per session. With `--then`, your own line stays first and these lines still follow.
- **Rounding**: percentages in the status line and `Claude subscription:` line are rounded to the nearest
  integer instead of truncated.
- **Worker write scope**: the write permission of DeepSeek and Claude executors no longer shrinks after they
  `cd` to another directory.

## 0.7.0

- **Recovery**: corrupt rebuildable state is preserved before reset; damaged task records are skipped in reports,
  and unreadable availability is ignored for reads but protected from writes. Stale assignment claims return
  offered tasks to the pool; failed or stale direct assignments are cancelled and archived.
- **Reclaimed tasks**: the first status line determines the outcome even after a preamble; PARTIAL and BLOCKED
  keep the slot busy until explicitly marked done.
- **Shared state**: unique atomic-write temp files with Windows sharing-violation retries; reentrant OS locks,
  bounded CLI waits and quiet short hook/status-line waits. Manual IDs, capacity, transitions, notifications,
  pool checks, sessions, budget snapshots, quota and profile updates are serialized. Take claims ownership
  before worktree creation outside the lock and rolls back on failure; lost/corrupt counters cannot reuse IDs.
- **Lead and worker rules**: launch session choices govern the lead and Claude lane; explicit profiles still
  win. Every handoff subcommand refuses inside a worker. Non-Claude leads drop the OAuth token too; the lead
  documentation clarifies that credential hygiene does not sandbox the operator's tools or config directory.
- **Claude budget**: independent measurement times anchor average/recent pace and projections. Five-hour numbers
  older than 20 minutes cannot enable SURPLUS and show their age. Weekly usage or a projection after day one
  raises TIGHT, including without five-hour numbers; obsolete reserve clock times are suppressed.
- **Manual lane**: profile capacity cannot be bypassed with force; wait-any reports an existing unreported final
  result once. Inferred STARTED? activity gets the overdue warning; fast checks still avoid workdir scans.
- **Run outcomes**: BLOCKED/PARTIAL reports retain their status in headers and usage (exit 0); Codex model
  capacity produces exit 75 and a model-only ten-minute block. Registry notes explain native Windows sandbox
  temp-directory access and the scratch-directory remedy.
- **Self-test**: fail-safe setup aborts before running checks in the wrong directory; optional ORCH_TEST_TIMING
  reports per-check time; literal patterns match without grep. Added real process races and regression checks
  for state failure/rollback, profile precedence, worker guards, budget freshness, weekly limits and run outcomes.

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
