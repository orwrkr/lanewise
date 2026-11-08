# Spend limits (API-billed executors)

Orchestra caps how much money API-billed executors spend, so a long batch of DeepSeek runs or a Codex/Claude
profile on an API key cannot silently run up the bill. It is enforced by `orch` itself, like profile `max_open` —
`--force` does **not** bypass it.

## Two kinds of limit

There are two kinds because there are two kinds of payment:

- **Prepaid (an API key)** — the limit is what lies on the account. Time doesn't bring the money back, so a limit
  that has been reached stays reached until the operator tops up and resets it. This is a **manual** counter.
- **Postpaid, billed by period** (Vertex AI through GCP, when it arrives) — the limit is a monthly budget that
  resets by itself when the month rolls over. This is a **month** counter.

**Defaults:** a profile with an API key (`key` field: DeepSeek, Codex, Claude, and later Gemini on a key) has a
**manual** reset. Everything else API-billed has an automatic **monthly** reset. Both can be changed for any scope
with `--reset month|manual`.

For a prepaid key, set the limit to roughly what is on the account. A manual counter only grows: when it is
blocked, top up, then `orch spend reset <scope> [--limit N]` (the reset can also raise the limit in one step).

## What is counted

- **DeepSeek — always.** It has no subscription; every token is paid from the balance.
- **Codex and Claude — only when the active profile has a `key`** (an API-key profile, not a `codex login`
  account or your Claude subscription).
- A scope is a profile label: `deepseek`, `deepseek@work`, `codex@work`, `claude@work`, … (see `orch profile show`).
  Each scope has one counter: a global counter (projects without their own limit) or a per-project counter (a
  project with its own limit — spent independently).
- Spend comes from the usage ledger: `orch run` records that bill to the key, plus the lead session's own tokens
  when the orchestrator itself runs on that key (`orch launch`, or Claude via an apiKeyHelper profile). A lead
  session is recorded at SessionEnd, split at counter resets and month starts, each message priced at its own time:
  what was spent before a reset stays out of the new counter, and a session across the 1st counts per month.
- The cost is an **estimate**: tokens × the prices in `plugins/orchestra/registry/prices.json` (a personal copy at
  `~/.orchestra/prices.json` overrides it). Cache writes fold into the input price; DeepSeek uses its peak rates,
  halved off-peak (see below). The cost is frozen into the ledger entry as `cost_usd` at run time, with the price
  `as_of`; later price changes don't rewrite history. It will not match the provider's invoice to the cent.

## Limits and modes

Default limit **10 USD**; `orch spend limit <scope> N` or `off`. Two modes per scope, each `stop`, `evaluate`
(default for executors) or `continue` (default for the lead):

| Mode | New `orch run` at ≥ 100% | A running executor crosses 100% | Crosses 100% + overrun (default 20%) |
|---|---|---|---|
| `stop` | refused (exit 75) | killed | — |
| `evaluate` | refused (exit 75) | may finish | killed |
| `continue` | warn only | warn only | warn only |

- A refused or killed run exits **75** and the header/usage log say `SPEND_LIMIT`; a killed run still logs the
  partial usage it spent. At **80%** a warning appears in `orch status` (an `API spend:` line), and a 💡 event fires once
  per counter period (per month for `month`, per baseline for `manual`; again at 100%).
- **Lead mode** (default `continue`) governs the orchestrator itself: `orch launch` refuses at the limit under
  `stop`/`evaluate`, and `orch key` (the apiKeyHelper) refuses past the threshold — `stop` at 100%, `evaluate`
  past the overrun — which makes a Claude session's requests fail. A DeepSeek lead has no such per-request hook,
  so it cannot be stopped mid-session: only `orch launch` refuses at the start.

## Commands

```bash
orch spend                              # limits, spend, modes, counter (manual, since … / this month)
orch spend limit deepseek 25            # global limit; the counter keeps running, so raising it unblocks
orch spend limit gemini 10 --reset month  # also set the reset kind
orch spend limit gemini 50 --project    # this project's own limit; --project PATH for another
orch spend limit gemini off             # no limit
orch spend limit default 20             # the default for everything without its own limit
orch spend mode deepseek stop           # executor mode: stop at the limit
orch spend mode deepseek continue --lead  # lead mode: warn only
orch spend mode default evaluate --overrun 20
orch spend reset deepseek               # topped up: count from zero from now
orch spend reset deepseek --limit 40    # the same, with a new limit
orch spend reset deepseek --project     # a project's own counter (needs its own limit first)
```

`orch spend reset` on a `month` scope also moves its baseline for the rest of that month — the next month starts
clean anyway. It prints what was spent, the old and new limits, and the kind.

The config lives in `~/.orchestra/spend_limits.json` (baselines for manual counters live there too); a corrupt file
refuses writes **and refuses runs** — `orch run` / `orch launch` / `orch key` cannot check the limit without it, so
they fail closed (like a broken `profiles.json`) rather than silently count $0. `orch spend` still shows the
defaults. Scopes are case-insensitive (`DEEPSEEK` → `deepseek`), must name a real provider or `<provider>@<profile>`,
and `orch spend reset … --project` refuses a project that has no limit of its own. The counters are cached
incrementally in `~/.orchestra/spend_cache.json`; a reset takes effect at once.

## When a key runs out: a fallback profile

A project's profile may name a `fallback` (`orch profile set deepseek work --fallback personal`). While the profile is
at its limit (mode `stop` or `evaluate`; `continue` never is) or marked `exhausted`/`disabled` in `orch quota`, the
project resolves to the fallback profile: its key, its spend scope (so its own counter and limit), its `prefer_for`,
`use_for` and `rules`. `orch spend` keeps listing both scopes. `orch spend reset <scope>`, a higher limit or
`orch quota clear <scope>` returns the project at once. An explicit `--profile <name>` on a run bypasses the fallback
and refuses at the limit as usual, naming the fallback that takes over without the flag. An unreadable
`spend_limits.json` is not exhaustion: nothing moves and runs refuse as above. Two 💡 events: when a project moves to
its fallback and when it returns.

## Per-session account budget

For a provider with a balance API (currently DeepSeek), set any of these independent profile fields:

```bash
orch profile set deepseek client --session-soft 30 --session-hard 90 --balance-floor 1 --fallback personal
```

Percentages must be above 0 and at most 100, with soft below hard when both are set; the floor is nonnegative
and uses the account's currency. An empty value removes a field. Other providers refuse these fields because
they have no balance API.

The first balance recorded by a hook or run preflight in a session becomes its baseline. It lives in
`~/.orchestra/session_budget.json`, keyed by scope and session id, so compaction keeps it. Entries older than
seven days are pruned on writes. A rise of at least 0.01 over the last recorded balance is a top-up and starts a
new baseline. With no session id (a plain terminal), only the floor applies.

After existing availability and spend-limit checks, the causes are checked in this order:

1. `floor`: the account balance is at or below `balance_floor`.
2. `session-hard`: the account has fallen by at least `session_hard` percent of the baseline.
3. `session-soft`: the account has fallen by more than `session_soft` percent, unless Claude is **TIGHT**.

A cause moves the project to its fallback, including that profile's key and routing rules. While Claude is TIGHT,
the soft cause clears and the project returns; when TIGHT ends it moves again if still over soft. Hard and floor
apply during TIGHT too. A top-up clears the old percentage baseline. Hooks announce each move in either direction
once, with figures and the reason for returning. A per-session entry is dropped when that session ends, and any
per-session entry expires after seven days, so a session that dies on a fallback leaves nothing behind. No quota
entry is needed for these causes.

`orch status` and `orch profile show` (including `--json`) show, for example,
`session: account down $0.42 of $15.50 (2.7%; soft 30%, hard 90%, floor $1)`.
These are **account changes**, including other tools and people, not the session's own spending. Parallel sessions
have separate baselines and count each other's account spending too; this errs on the safe side.

Every run on a budgeted profile fetches a fresh balance synchronously (five-second timeout). A failed fetch or a
broken baseline store refuses with exit **75**, header and usage status `SESSION_BUDGET`; take the fallback and
do not work around it. A hard cause without an available fallback, or with explicit `--profile`, refuses the same
way. Soft without a fallback only warns. `--force` never bypasses these checks. `ORCH_BALANCE=off` deliberately
disables the session budget: runs warn once and proceed. Before the first figure, profile resolution infers no
exhaustion. An old figure or a failed read keeps the last known amount, so nothing moves because of it: a balance
rises only with a top-up. A run always reads the configured key first, even while the project is on its fallback,
so a top-up brings the project back. The status line adds nothing and only reads the cache and baseline;
it never fetches a balance or writes a baseline.

The spend limit continues alongside this budget, unchanged: either can stop or reroute a run first, and
`continue`/`stop`/`evaluate` retain their existing meanings for the estimate of `orch`'s own runs.

## Prices

`prices.json` holds dated entries (a price `from` a date, for promotions that end) and, for DeepSeek, peak windows:
the peak rate applies 01:00–04:00 and 06:00–10:00 UTC Monday–Friday, and is halved otherwise (weekends and other
hours). Chinese public holidays are off-peak on DeepSeek's page but are not modelled — on those days the estimate
errs high, which is accepted. `orch spend` warns when a provider's prices are older than 30 days and names the
source to check.

**Refreshing the prices.** `orch` makes no web request; a cheap agent reads the official pages and the operator
confirms what it found. Nothing happens by itself.

1. `orch prices check [--provider P]…` writes `~/.orchestra/prices/check-<stamp>/TASK.md`: each provider's price page
   and the model keys of our table that belong to it.
2. The orchestrator gives it to a cheap executor with web access: in a Claude-led session a native subagent such as
   `orchestra:orch-haiku-low`; otherwise `orch run claude|deepseek --mode analysis --allow
   'WebFetch(domain:<site>)' --prompt-file <TASK.md>` (an allowed `WebFetch(...)` rule gives the worker that tool);
   or the manual pool, since reading price pages is read-only research.
3. `orch prices diff <output>` validates its report (a JSON file, or any text with the proposal in a fenced
   json block) and prints `field: current → proposed (±N%)`, large changes marked, models left out, new keys.
   Exit 2 when it is invalid.
4. After the operator's yes: `orch prices apply <output> --yes` (`--provider`, `--model` narrow it; without `--yes`
   it only shows the diff). It writes dated entries to the personal `prices.json` and confirms the provider's
   `as_of`, even for a check with no changes. The built-in file is never written, and a newer plugin version's prices
   replace an older check.

`orch prices show [--json]` prints the table in effect: source, date and age per provider, personal or built-in.

## The provider's balance of the account — `orch balance`

`orch spend` is an **estimate of `orch`'s own runs** (tokens × prices). For a provider that reports a balance,
`orch balance` also reads the provider's own figure with the key (`GET /user/balance` for DeepSeek) and keeps it in
`~/.orchestra/balances.json`: per scope `{amount, currency, at}`, plus the last error and its time. A failed fetch keeps
the last amount; its age says how old it is. The currency is the provider's own (`$`, `¥` for CNY): nothing is
converted, and the USD limits above stay as set by hand.

**The figure belongs to the account, not to the key.** All keys of one DeepSeek account share one balance, and the
account can be spent from outside `orch` (other tools, other people). So it is the account's balance everywhere it is
shown, two keys of one account show the same figure, and it is never comparable with one key's estimate: **a drop in
the account balance says nothing about one key's spend.** Spend limits stay what they were, hand-set budgets for
`orch`'s own runs. What actually stops an empty account is the provider's refusal (402), and it moves a project whose
profile has a `fallback` to that profile.

- **Where**: for every API-billed scope active in the directory, the status line always shows our part and, once a
  balance was fetched, the provider's:
  `DeepSeek@client 1.5M/988k (est. $1.47/$10, account $15.09)`, joined to the session counter of the same name
  (`, 3h ago` after 30 minutes; `(est. $1.47, account $15.09)` when the limit is `off`; no account part before the
  first fetch or for a provider with no balance API; a limit that is not whole shows as it is, `$12.16`; a scope
  with no tokens in this session follows the counters on a line of its own, and with no tokens at all it stands alone). `orch status` has a line per such scope under an `API keys (...)` heading that says where
  each number comes from: `est. $1.47 of $10 (manual, since Nov 03) · account $15.09 (checked 3m ago)`, or `no balance
  API`, or `last fetch failed: ...`. `orch spend` has an `account` column. The warning at 80% (`API spend:` in `orch
  status`) and the 💡 events are unchanged.
- **When fetched**: `orch balance [SCOPE …] [--json]` always; `orch status` and `orch spend` when the figure is older
  than 10 minutes; the end of each `orch run` for its scope; SessionStart starts a detached `orch balance --quiet`
  when it is stale. A budgeted run also fetches before starting. 5-second timeout everywhere; outside session-budget
  preflight a failure never fails the command. The status line only reads the
  file. `ORCH_BALANCE=off` stops every request.
- **Which providers**: only what an ordinary key can read: DeepSeek. OpenAI (Codex key), Anthropic (Claude key) and
  Google (Gemini API, Vertex AI) offer none, so those scopes show "no balance API: see `orch spend`" and keep the
  estimate. A new provider is a fetch function plus an entry in `BALANCE_PROVIDERS` in
  `lib/orch_core/15-provider-account-balances.py`.
- A rejected key (401/403) is reported with its variable name (`check DEEPSEEK_API_KEY_WORK`); a key value is never
  printed, logged or cached.

## The provider's own refusal is separate

A DeepSeek 402 blocks until `orch quota clear deepseek` — the account is really empty, whoever spent it. `orch spend`
is our estimate of `orch`'s own runs and is a separate stop. Both are worth respecting: the provider's is exact, ours
is early (before the money runs out) and covers only what `orch` ran.

## The orchestrator's job

- Before `orch run` on a key, check `orch status` / `orch spend`; when a scope is near or past its limit, route
  that work to a lane that does not bill the same key — a subscription lane (Claude, `codex login`) or a different
  scope — or tell the operator the limit is reached rather than spending past it.
- Do not set a limit above what the operator asked for, and never under a `--force` (it does not help).
