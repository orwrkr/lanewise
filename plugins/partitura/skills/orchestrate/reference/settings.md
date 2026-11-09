# Settings — what is configurable, where it lives, what it reaches

This is the map for "how do I set this plugin up here?". Each topic names its command and points to the deeper
guide; check the exact flags with `--help`. Almost everything is configured in the session, in plain words.

## This project vs. every project

Every setting is either scoped to **this project** (a path binding, a project file) or **personal, for every
project** (files under `~/.partitura/`). Personal data never goes into a repository.

**This project only:**

| Setting | Command / file | Stored |
|---|---|---|
| Project registry | `orch registry init --project` → `<project>/.partitura/providers.yaml` | in the project, git-excluded |
| Profile for this project | `orch profile use <provider> <profile|off>` | `~/.partitura/profiles.json`, keyed by path |
| Profile for a directory above it | `orch profile use <provider> <profile> --path /path/to/dir` | same file |
| This project's own spend limit / mode | `orch spend limit <scope> N --project` | `~/.partitura/spend_limits.json`, keyed by path |
| Claude key profile's `apiKeyHelper` | written by `orch profile use claude <key-profile>` | `.claude/settings.local.json`, git-excluded |

**Every project (personal, under `~/.partitura/`):**

| Setting | Command / file |
|---|---|
| API key values | `~/.partitura/secrets.env` (edited by hand) |
| Personal registry | `orch registry init` → `~/.partitura/providers.yaml` |
| Profile definitions and provider defaults | `orch profile set …`, `orch profile use … --default` → `profiles.json` |
| Spend limits, modes, price table | `orch spend …` → `spend_limits.json`; `prices.json` |
| Account balances (the provider's figure, shared by all keys of an account) | `orch balance` → `balances.json` |
| Availability ("away", "out until …") | `orch quota set|clear` → `availability.json` |
| Status line | `"statusLine": { … "orch statusline" }` in Claude Code settings |

Bindings and spend limits sit in the shared files but are **path-keyed**, so a project keeps its own effective
values while the file is shared. `ORCH_HOME` relocates all of `~/.partitura/` (separate per OS unless shared).

## Executor profiles — `orch guide profiles`

A profile is one executor's settings: which key or account, which models and efforts, whether it may write, which
tasks to use it for, free-form rules.

- Change: `orch profile set <provider> <name> …` (create/edit) and `orch profile use <provider> <profile|off|inherit>`
  (bind), or `/partitura:profile`.
- Fields (`orch profile set --help`): `--key NAME`, `--home` / `--codex-profile` (a second Codex account),
  `--models`, `--max-effort`, `--write yes|no`, `--use-for`, `--prefer-for`, `--rules`, `--max-open` (manual lane),
  `--fallback <profile>` (another profile of the provider that takes over while this one is exhausted; `none` clears
  it), and adapter extras via `--opt FIELD=VALUE` (the Claude budget's `surplus`, `reserve`, `week_reserve`; Codex's
  `reserve`, `week_reserve`).
- Scope: no qualifier = this project; `--default` = every project; `--path /path/to/dir` = a directory above this
  project; `inherit` removes the binding; `off` disables the provider.
- Precedence: `--profile` on a run → session choice (`ORCH_PROFILES`, `orch launch --no-claude` / `--use`) →
  project / directory binding → provider default → the built-in `default`.
- `orch` enforces `off`, `models`, the effort ceiling, the write ban and `max_open`; you honour `use_for`,
  `prefer_for` and `rules` when routing. A broken `profiles.json` refuses runs rather than silently re-enabling.
- Session account budgets: `--session-soft PCT`, `--session-hard PCT`, `--balance-floor N` (DeepSeek only;
  empty values clear fields). Baselines live in `~/.partitura/session_budget.json`; see `orch guide spend`.
- `orch profile rules --set "TEXT"` records project-wide operator requirements; `--path /path/to/dir` covers a directory,
  and `--clear` removes the entry. `orch profile rules` shows all applicable entries.
- A `fallback` is resolved by `orch` itself: while the profile's key is exhausted (spend limit reached, or an
  availability entry `exhausted`/`disabled` on `<provider>@<profile>`), the project gets the fallback's key, models,
  limits and routing, and returns when the key has budget again. `orch profile show` shows the effective profile.

## API keys

A profile stores **only the variable name** (`--key DEEPSEEK_API_KEY_WORK`); the value is a line
`DEEPSEEK_API_KEY_WORK=sk-…` in `~/.partitura/secrets.env` — the one place keys live, and only adapters that declare
`# orch-secrets: …` ever receive a value. A session **never asks for a key's value, never prints it and never reads
that file**; it only ever says "add `NAME=sk-…` to `~/.partitura/secrets.env`". `orch doctor` reports whether each
declared key is set (`✔` / missing) without showing the value. A profile's `key` is explicit-only: a stray `NAME=…`
line alone never switches a login profile to API billing.

## Spend limits — `orch guide spend`

Caps what API-billed executors spend (DeepSeek always; Codex/Claude only on a `key` profile), enforced by `orch`
(`--force` does not bypass it). Two reset kinds: **manual** for a prepaid key, **month** for a periodic bill.

- Limit: `orch spend limit <scope> N` (or `off`); scope is `default`, a provider, or `<provider>@<profile>`;
  `--reset month|manual`; `--project` for this project's own counter.
- Mode: `orch spend mode <scope> stop|evaluate|continue [--lead] [--overrun PCT]`.
- After a top-up: `orch spend reset <scope> [--limit N]` (counts from zero from now).
- Personal price table: `~/.partitura/prices.json` overrides the built-in `registry/prices.json`.
- Stored in `~/.partitura/spend_limits.json`; a broken file refuses runs and writes.
- The provider's balance of the account behind a key (DeepSeek): `orch balance [--json]`, kept in
  `~/.partitura/balances.json` and shown as `account $15.09` in the status line (after our `est. $1.47/$10`, in the same parentheses),
  `orch status` and the `account` column of `orch spend`; `ORCH_BALANCE=off` turns every request off. Other providers
  have no balance API for an ordinary key and show only the estimate. The account is shared by all its keys and can be
  spent from outside `orch`, so a drop in it says nothing about one key's spend: limits stay hand-set budgets for
  `orch`'s own runs, and the provider's refusal (402) is what stops an empty account (and moves a project to its
  profile's `fallback`).

## Subscription budgets — `orch guide budget`

The Claude (and Codex) subscription's 5-hour window and weekly limit, projected to warn of a surplus or a squeeze.
Among slots that suit a task, subscriptions go before API-billed executors unless they are TIGHT: a global routing
rule in `SKILL.md`, with `prefer for` as the per-profile way to rank a provider first for a task type.

- Thresholds live in the profile: `orch profile set claude <name> --opt reserve=25 --opt week_reserve=15
  --opt surplus=40` (Codex: `reserve`, `week_reserve` only, no surplus), then
  `orch profile use claude <name>` for a project or `--default` (the budget reads only the bound profile).
- `orch budget` shows the numbers, the active consumers and the thresholds; without the status line, report them with
  `orch budget set --used 40 --resets 18:00`.
- The numbers come from the status line (below) and are account-wide.

## Availability — `orch guide quota`

"Codex is out until 18:00", "topped up DeepSeek", "I'm away" → `orch quota set|clear`.

- Keys: a provider (`codex`), provider/model (`codex/gpt-6.1-sol`), a profile (`deepseek@work` — its own key), or
  `operator` (the whole manual lane). Statuses: `low`, `exhausted`, `disabled`, `away`; `busy` is set by `orch`
  for a model at capacity and lifts by itself.
- "I'm away" → `orch quota set operator away --until 19:00`; "I'm back" → `orch quota clear operator`.
- Stored in `~/.partitura/availability.json`, shared by all projects; `--until` lifts on its own.

## The registry — `orch registry show`

The built-in `providers.yaml` plus your personal copy. What is in effect for this project, `orch registry show`:
the brief view (settings, slots with `good_for`, routes; no notes), `orch registry show <provider>` (that provider in
full: its notes, slots and the routes that name them), `orch registry show --full` (the file itself; `--json` — the
parsed registry). `orch registry path` prints the file's path. A copy that cannot be parsed is shown as is, after a
line saying so. Precedence: `<project>/.partitura/providers.yaml`, then
`~/.partitura/providers.yaml`, then the built-in one. Make a copy to edit: `orch registry init` (personal) or
`--project` (this project). A copy overrides the whole built-in registry, so when the built-in one has changed since
the copy was made, SessionStart and `orch doctor` say so; `orch registry diff` shows what the copy changes and
`orch registry diff --accept` records the built-in registry as current once you have taken over what you need.

It holds the **slots** (provider × model × effort, with cost, `max_difficulty`, `good_for`), the **routes**
(`routing`), `policy.never_auto` (slots that need explicit permission), and the **`operator`** manual-lane parameters
(`min_task_minutes`, `max_open_handoffs`, `max_offers`, `pool_check_min`, `pickup_reminder_min`, `reassign_after_min`,
`batch_small_tasks`). `orch doctor` checks the whole setup (keys, logins, profiles, registry, PATH).

## The status line

One line in Claude Code's settings, set once (or ask `/statusline`):

```json
"statusLine": {"type": "command", "command": "orch statusline"}
```

It feeds the budget mode and the session count from every session that shows it, and prints the limits, the mode and
`Session in/out` tokens with their cache reads as `+N cache` (`Claude 370k/111k +28M cache`); it never reaches the
model, so it costs nothing. Keep your own: `orch statusline --then "<your command>"`.

## What is not a setting

Some rules hold everywhere and are not configurable: manual agents are never automated (no `agy`, computer use, text
pasting or OAuth — a ToS ban); keys never go into the repository; executors don't delegate; a worker never sees the
operator's Anthropic credentials — it receives only the key its own profile names, never `ANTHROPIC_AUTH_TOKEN` or
any other credential. These are fixed for safety, not knobs.

## Projects with their own process

A project's own workflow and commit rules come **first** — the plugin is a tool inside that process, not above it.
When the operator records a decision, do it where the project asks; `.partitura/` is local and outside git, so it is
the place for plugin state, not for the project's own notes. There are three places for a constraint:

- The project's `CLAUDE.md` and `AGENTS.md` live in its repository and reach every executor on their own, exactly
  once, so a constraint everyone working there should see belongs in them.
- Project rules (`orch profile rules`) are private to this machine and survive a key change. `orch` shows them only
  to you, the orchestrator: follow them when routing, and carry what an executor needs into its task.
- A profile's `rules` belong to that key and lapse with its fallback. `orch` shows them to you the same way.

A project's read ban (`permissions.deny` in `.claude/settings*.json`) covers only what its rules name; other
git-ignored files, such as notes on the machine's environment, stay readable. A worktree holds only tracked files.
The project's git-ignored `CLAUDE.md` or `AGENTS.md` and what its instructions import with `@` still reach a worker
there, from the project folder; carry anything else it needs into its task. The bans bind DeepSeek and Claude executors, not Codex or manual agents, so keep tasks near
banned files away from those two; in a worktree only the tracked `settings.json` applies. A secret committed to the
repository is already compromised: the project replaces and removes it, and no ban fixes that. Until it is gone, keep a
reminder in the project rules, so every session warns about it.
