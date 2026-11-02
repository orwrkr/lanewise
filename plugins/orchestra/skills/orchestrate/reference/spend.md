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
  when the orchestrator itself runs on that key (`orch launch`, or Claude via an apiKeyHelper profile).
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
  partial usage it spent. At **80%** a warning appears in `orch status`, the status line, and a 💡 event fires once
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

## Prices

`prices.json` holds dated entries (a price `from` a date, for promotions that end) and, for DeepSeek, peak windows:
the peak rate applies 01:00–04:00 and 06:00–10:00 UTC Monday–Friday, and is halved otherwise (weekends and other
hours). Chinese public holidays are off-peak on DeepSeek's page but are not modelled — on those days the estimate
errs high, which is accepted. `orch spend` warns when a provider's prices are older than 30 days and names the
source to check.

## The provider's own refusal is separate

A DeepSeek 402 blocks until `orch quota clear deepseek` — that is the provider's real balance. `orch spend` is our
estimate of the same spending and is a separate stop. Both are worth respecting: the provider's is exact, ours is
early (before the money runs out).

## The orchestrator's job

- Before `orch run` on a key, check `orch status` / `orch spend`; when a scope is near or past its limit, route
  that work to a lane that does not bill the same key — a subscription lane (Claude, `codex login`) or a different
  scope — or tell the operator the limit is reached rather than spending past it.
- Do not set a limit above what the operator asked for, and never under a `--force` (it does not help).
