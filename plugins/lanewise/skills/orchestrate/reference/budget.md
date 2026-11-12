# Claude subscription budget: use it or lose it

The 5-hour window of a Claude subscription expires at its reset: what is not used by then is lost. API-billed
executors — `billing: api` in the registry (DeepSeek) and any profile with an API `key` — cost money per token. So
when the window is going to expire with a lot unused, work that would go to them should go to Claude instead.

The numbers are account-wide: every session on the account — other orchestrators, other projects, the apps — is
already in them. `orch` projects the 5-hour window at the **current pace**: the higher of the window average and the
pace of the last 30–60 minutes, measured back from the same snapshot (the base sample is at least 30 minutes old, so a
short burst is not extrapolated). A five-hour projection needs at least 60 minutes of the window behind it, at the
measurement, for Claude and Codex alike: before that only a used share that has reached the reserve counts, and
neither TIGHT nor SURPLUS is projected. The week is projected from its **recent pace**: the earliest of the week's
own samples (`week_history`, at most one per 15 minutes, kept for 80 hours) from the last three days with the same
reset and at least 6 hours before the measurement; while there is no such sample (not enough history yet, or just
after a reset) the week falls back to its window average, as before. Three days, not one: a single heavy or light
day no longer swings the projection, while a burst still shows in the five-hour window. Each window has its own
measurement time; projections are anchored to it and do not improve merely as the numbers age. A
**reserve** is kept for sessions orch doesn't know about and as a safety margin: 10% of the 5-hour window, and for
the week a reserve that shrinks with the time left to the reset — `reserve × (time left / 7 days)`, floored at
1 point and never below a reserve of 0. So a 10% weekly reserve is 10 at the start of the week, 5 at mid-week,
about 1.85 with 31 hours left, and 1 (the floor) in the last hour. The mode is in `orch status` / SessionStart (the
line `Claude subscription: …`) and arrives as a `💡` event when it changes.

By default, among the slots that suit a task, subscriptions go before API-billed executors (DeepSeek, any profile with
a key): what stays unused at a reset is lost, and a balance is money. The modes adjust that order:

- **SURPLUS** — at least N % of the window (N = the `claude` profile's `surplus`, default 30) would expire unused
  beyond the reserve, and the weekly limit has room beyond its reserve. The line names the active orchestrator
  sessions and each one's share of the surplus: plan for your share, not for the whole. Until the reset shown:
  - a subtask still headed for an API-billed executor goes to the cheapest Claude slot that handles its difficulty
    (a subagent; in a session led by another model — `orch run claude`) — except the task types the active profile of
    an API-billed provider has in `prefer for` (the line names them): while that key has budget, they go to it first.
    When the key runs out, the profile's `fallback` takes over and its own `prefer for` (if any) applies instead;
  - Codex and the manual pool keep their tasks; on a tie between Claude and Codex, take Claude;
  - cross-review of Claude's code stays with Codex (DeepSeek only if Codex is unavailable);
  - don't spend for the sake of spending: no extra subtasks, no effort above what the task needs.
- **TIGHT** — the five-hour window reaches its (flat) reserve before reset (projected only once 60 minutes of the
  window have passed; a used share already at the reserve is TIGHT at once), or the weekly used share has reached its
  effective reserve, or the weekly projection reaches it after at least 24 hours of the week have been measured.
  Weekly TIGHT works even without current five-hour numbers; without a weekly reset only the used share counts. The
  line names the weekly limit, the basis the projection used (`N% projected from the week's average` or `N% projected
  from the last 8 h`) and the effective reserve, shown with what it comes from when it has shrunk (`reserve 2% (10%
  at the start of the week)`). The status line's mode part says `tight: week N% projected` (or `tight: week over
  reserve` for the used share, `tight: 5h` for a five-hour-only squeeze). Treat Claude as `low`: it goes after the
  API-billed executors, so work moves to another subscription with room, then to them. A weekly projection from the first
  24 hours is too thin to count: it neither raises TIGHT nor blocks SURPLUS.
- **no mode in the line / no line** — the default order (too early in the window to tell — the first 60 minutes of a
  five-hour window — or no numbers).

`orch budget` shows the numbers, the active consumers orch knows of (Claude Code sessions with this plugin active in
the last 15 minutes, running `orch run claude` executors; sessions led by another model don't count) and the
thresholds.

## The orchestrator's own limits

The budget mode decides where work goes; this watcher decides whether the orchestrator is about to lose its own
capacity before a limit resets. It reads the same snapshot and the same pace and projection (`window_pace`,
`week_rate`, `projected_at_reset`) — no second model of usage. A session led by another model (`ORCH_LEAD`) watches
that model's spend limit and account balance at its spend pace instead of Claude's windows.

- **A five-hour window** (shorter than a day) is at risk when its projection at the reset reaches 100%. The
  projection minimum applies: less than 60 minutes into the window is no risk.
- **A window of a day or more** (the week, a monthly spend limit, a prepaid balance, a manual spend counter) is at
  risk when it runs out before the reset *and* either in under `watch_horizon_h` hours or with under `watch_low` %
  left. Claude needs a projection; only a non-Claude spend limit or balance uses the low test without a pace.
  A balance has no scheduled reset: its exhaustion must be within the horizon or its remaining share low.
  A manual counter with no baseline watches its balance.
- **Early** (a window of a day or more with a reset: the week and a monthly spend limit — not a balance or a manual
  counter): both pace estimates (the recent pace and the window average) run out before the reset, the lower one at
  least `watch_early_share` % of the window length before it, and each estimate rests on at least
  `watch_early_min_data_h` hours of samples. The question says it is early and names both projected exhaustion times
  and the reset.

Hooks ask per session. SessionStart and UserPromptSubmit print the question; PostToolUse adds it as context (at most
once per 2 minutes per session, a marker file); an unanswered question repeats after 15 minutes, not before. The operator
answers in that session with `orch watch answer …`:

- `pause` — record "paused until <reset>"; the session's UserPromptSubmit reminds to finish nothing new and answer
  briefly. The pause ends by itself at the reset, and the next hook says once "▶ … the pause is over"; other
  sessions are unaffected. A balance pause has no end time: it says "until the balance is topped up" and ends when
  the user answers `continue`, including when a spend limit is also at risk.
- `continue` — record the time and the used % of every limit at risk; ask again after `watch_ask_again_min` minutes
  or when one of those limits grew by `watch_ask_again_step` points, whichever first, while the risk persists. For
  the five-hour window, after `continue`, a risk counts only while the lower of its two pace estimates also projects
  100% before the reset; the window's reset ends the answer and that raised bar. Windows of a day or more keep their
  rule.
- `continue-session` — never ask again in that session.

`orch watch` shows every current limit with its used %, reset, projection at the reset, time to exhaustion and risk,
this session's standing answer and the settings in effect (`--json` for tools). The thresholds are the `claude`
profile's, next to the budget's: `orch profile set claude <name> --opt watch_horizon_h=2 --opt watch_low=5
--opt watch_early_share=15 --opt watch_early_min_data_h=24 --opt watch_ask_again_min=60 --opt watch_ask_again_step=10`,
then `orch profile use claude <name>` for a project or `--default`. `--opt watch=off` silences the watcher
(`watch_early=off` only the early rule). The answers live in `~/.lanewise/watch.json`, are removed at SessionEnd and
after 7 quiet days, and the status line only reads them: a paused session shows `⏸ paused until HH:MM`.

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

## Codex subscription limits

Codex writes its own rate limits into its session logs, `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`
(`CODEX_HOME` defaults to `~/.codex`; a profile with `--home` is another account with its own entry). The format
is undocumented, so `orch` parses it defensively and treats any surprise as "no data" — never an error or noise.
It reads only the newest files and just a tail of each, and refreshes at most once a minute from the status line
and once after every `orch run codex`.

The limits appear next to the Claude line in `orch status`:

```
Codex subscription: 5-hour window 81% used, resets 18:28, week 95%, resets Nov 4 21:08 (measured 14:46). TIGHT: treat Codex as low
```

The mode reuses the Claude thresholds (`reserve`, `week_reserve` from the `codex` profile, default 10): **TIGHT**
when a window's used share is at or above its cap, or its projection at reset is, with the same rule that a weekly
projection counts only after 24 h of the week and a five-hour projection only after 60 minutes of its window. Codex
keeps its own `week_history` in its cached entry, so its weekly projection and the shrinking effective reserve work
exactly as for Claude. Treat Codex as `low` then — offload to
other providers. There is no SURPLUS mode for Codex. The line and its `💡` event only appear with current data and
while the `codex` profile isn't `off`; `orch run codex` itself is not blocked by this (real exhaustion is still the
adapter's exit 75).

The status line shows the limits on a line of their own, and a further `Session in/out:` block with this session's
tokens per account: one account per line, the first on the heading line and each further one indented by two spaces.
Each counter is input and output, then the cache reads as `+N cache` (`Claude 370k/111k +28M cache`), left out
when an account had none. One counter per profile label (`Codex`, `Codex@work`, `DeepSeek@client`,
`DeepSeek@personal`), never a sum over a provider's accounts. The session's own Claude thread counts as `Claude`, or
under its key profile's label when it bills to a key. Each account's line carries the API-billed scope of the same
name active in the directory, always, in parentheses after the counter: `DeepSeek@client 1.5M/988k (est. $1.47/$10,
account $15.09)` (our estimate and limit, then the provider's figure for the account once one was fetched, with
`, 3h ago` once it is old; `orch guide spend`). A scope with money but no tokens in this session follows the counters
on a line of its own (`DeepSeek@client (est. $1.47/$10, account $15.09)`), and with no session tokens at all the block
is only those, with no `Session in/out:` heading. While a provider's active profile is a fallback it says so inside the
parentheses:
`DeepSeek@personal 1.5M/988k +28M cache (fallback: DeepSeek@client at its limit; est. $0.99/$12, account $9.73)`
(the cause: `at its limit`, `exhausted` or `disabled`). None of this costs tokens: the status line never reaches the
model.

## The status line format

Every provider's part of the status line is built the same way, as
`name · 5h N% → HH:MM · week N% · [N session(s)] · mode · stale: age`, with any part that has no data left out:

- the Claude part is `Claude <model> · 5h 40% → 18:00 · week 60% · 3 sessions · surplus: Claude first` (a session
  led by another model shows the model's display name with no `Claude ` prefix);
- the Codex part is the model of the last `turn_context` event in the same rollout file that gave the limits, except
  the internal `codex-auto-review` step, which is skipped (`Codex GPT-6.1 Terra · 5h 81% → 18:28 · week 95% · tight:
  week over reserve`; just `Codex` when no model is logged, an unknown model id as-is). It has no session count.
- the mode text is the same on both (`tight: 5h`, `tight: week N% projected`, `tight: week over reserve`; Claude
  also `surplus: Claude first`, or just `surplus` where a key profile's `prefer for` holds), and both append
  `stale: <age>` once the measurement is older than 20 minutes.
