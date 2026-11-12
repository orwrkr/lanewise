# Lanewise — a multi-model orchestrator for Claude Code

Claude Code stays in charge: it breaks the task down and decides on its own who gets each subtask and at what effort:

- **Claude subagents** — Haiku, Sonnet, Opus, Fable at different effort levels;
- **Codex CLI** — on a ChatGPT subscription or an API key, automatically, in the background;
- **DeepSeek** — with an API key (paid from your balance), automatically, in the background, with the same tools Claude has;
- **the manual task pool** — you pick a task yourself and hand it to Antigravity (or Cursor, etc.) with a single pasted line.

It takes into account subscription limits and balance (which you report in plain words or which executors report themselves), your availability and the project's executor profiles, and it caps API-billed spend with a **spend limit** (`orch spend`, default $10 — a manual counter for prepaid keys, a monthly budget otherwise) so DeepSeek or a key profile cannot run up the bill. It keeps the manual channel off the critical path so you don't become the bottleneck, and for every session it keeps a log: which model did what and how many tokens it spent.

Claude doesn't have to be the lead: `orch launch deepseek` starts the same setup with DeepSeek as the orchestrator, and `--no-claude` keeps Claude models out of it entirely (see [DeepSeek as the lead](#deepseek-as-the-lead)).

```
                ┌──────────────── Claude Code (orchestrator, skill orchestrate) ────────────────┐
 registry ─────►│ decomposition → difficulty 1–5 → slot (model × effort) → fallback             │◄── orch status
 providers.yaml │                                                                               │    (limits, manual tasks)
                └──────┬──────────────────┬──────────────────────┬─────────────────────┬────────┘
                       │ Agent tool       │ orch run codex       │ orch run deepseek   │ orch handoff offer
                       ▼                  ▼  (background)        ▼  (background)       ▼
              orch-* subagents     Codex CLI (gpt-6.1-*)   headless Claude Code   pool → you take it → TASK.md
              (model + effort)     codex sandbox           + DeepSeek API         → Antigravity → RESULT.md
                                   exit 75 = limit         exit 75 = balance      hooks detect completion
                       └──────────────────┴──────────────────────┴─────────────────────┴─► tokens → orch usage
```

## Installation

Requirements: Claude Code, Python ≥ 3.8 and git; optionally Codex CLI and a DeepSeek API key.

```bash
git clone https://github.com/orwrkr/lanewise && cd lanewise && bash install.sh
```

Or, without a clone, from a terminal: `claude plugin install lanewise --marketplace orwrkr/lanewise`. The
plugin's `orch` is then available to the session's Bash tool, but not in your terminal: for `orch launch` and the
terminal commands below use the clone and `install.sh`.

Lanewise works in Claude Code only. Its `bin/` folder puts `orch` on the Bash tool's PATH, and claude.ai and
Cowork don't install a plugin that has one. It would not work there anyway: it needs hooks, local CLIs (`claude`,
`codex`), `~/.lanewise/` and git worktrees on your machine.

You can keep the clone anywhere: the plugin is installed straight from this folder, and edits in it are "live" — they take effect after `/reload-plugins` or in a new session. Both environments are supported: Claude Code in **WSL** and Claude Code running **natively on Windows** (where its Bash tool is Git Bash). Each environment has its own Claude Code installation, so run `install.sh` in every environment you work in:

```bash
# WSL (a repository on the Windows drive lives under /mnt/c/...)
cd /path/to/repo && bash install.sh

# Windows: in Git Bash (or from Claude Code on Windows — its Bash tool is Git Bash)
cd /c/path/to/repo && bash install.sh
```

The script registers the marketplace, installs the plugin, puts `orch` into `~/.local/bin` (if `orch` isn't found afterwards, that folder is not on your PATH: see the root README, "Quick start"), creates your personal registry and then runs `orch doctor`. On Windows, instead of a symlink it installs the launchers `orch` (for Git Bash) and `orch.cmd` (for PowerShell and cmd); the Git Bash launcher records the interpreter's absolute path, so `orch` doesn't go through the Microsoft Store `python3` alias, and re-running `bash install.sh` refreshes it (also after installing or upgrading Python). Inside Claude Code sessions the Bash tool also finds the plugin's own `bin/orch`; it looks for Python itself, the same way the hooks do, so it works without a `python3` on PATH.

`install.sh` is safe to re-run, including after moving the folder: it re-registers the marketplace at the current location. Personal data lives in `~/.lanewise/`, not in the repository: limits, your model registry, API keys. WSL and Windows use separate folders. If you want limits, registry and keys to be shared, set `export ORCH_HOME=/mnt/c/Users/<you>/.lanewise` in WSL (in `~/.bashrc`).

If you already have a personal registry `~/.lanewise/providers.yaml`, it overrides the built-in one. Copy new entries into it from `registry/providers.yaml`, or recreate it: `orch registry init --force`. When the built-in registry changes later, SessionStart and `orch doctor` warn that the copy is stale: `orch registry diff` shows the difference and `orch registry diff --accept` records the built-in one as current. Up to version 0.4 the marketplace was called `orchestra-local`; `install.sh` removes that installation before adding the current one.

### What the plugin changes and how to remove it

It is installed and removed **the standard way**: `install.sh` calls `claude plugin marketplace add` and `claude plugin install` and never edits `settings.json` or other Claude Code files by hand. Hooks, commands, subagents and the skill live inside the plugin and go away with it. To disable it without removing: `/plugin` → lanewise → Disable, or `claude plugin disable lanewise@lanewise` (re-enable with `enable`).

Outside Claude Code the plugin creates only:
- the launchers `~/.local/bin/orch` (plus `orch.cmd` on Windows);
- personal data in `~/.lanewise/` (limits, profiles, keys, usage log, the limit-watch answers, the isolated config of
  the DeepSeek executor);
- in projects where you have used it: a `<project>/.lanewise/` folder (with the worktrees of manual tasks that change files in `.lanewise/wt/`: if you delete it by hand, run `git worktree prune`), `<project>.wt/` worktrees (`orch worktree`), for Antigravity the rule `<project>/.agents/rules/lanewise-task.md` (it stays after a task closes), and their lines in `.git/info/exclude`. `.gitignore` is left alone; projects where the plugin was never used get nothing;
- Codex account directories, if you created such profiles (`--home`).

`orch footprint` shows the full list for the current environment. `bash uninstall.sh` removes the plugin and the launchers and lists what is left in projects; `--purge` also deletes `~/.lanewise/`.

Line endings are pinned to LF (`.gitattributes`), except for `*.cmd`, which use CRLF. If files still end up with CRLF (which breaks the bash scripts and `orch`), `install.sh` detects it and tells you how to fix it.

### What it runs, sends and fetches

Lanewise has no telemetry: it reports nothing to its author or to anyone else.

- **Hooks** (SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd) run `orch hook <event>` on your machine. They read and write `~/.lanewise/` and the project's `.lanewise/`, and print short events into the session. The status line (`orch statusline`, if you set it) only reads local files.
  - Each hook is one line in `hooks/hooks.json`, `sh "${CLAUDE_PLUGIN_ROOT}/hooks/run.sh" <event>`. `run.sh` only finds a Python 3.8+ interpreter and runs the plugin's own `bin/orch hook <event>`; it remembers the interpreter in `~/.lanewise/.hook-python-<platform>`.
  - A hook is written as one line, not as a program plus a list of arguments, because of native Windows: Claude Code runs a one-line hook in Git Bash, while a hook with arguments starts only where Windows itself finds `sh`.
- **The `orch` launcher** (`bin/orch`; Claude Code puts the plugin's `bin/` on the Bash tool's PATH) runs the plugin's own Python source, `lib/orch_core/*.py`, as one program.
  - The status line and every hook start it, so it keeps the compiled bytecode in `~/.lanewise/.pycache/` and runs it from there, as Python's own `__pycache__` does.
  - The cache is keyed by a SHA-256 of those sources and the Python version, so a changed file or another Python compiles anew. `PYTHONDONTWRITEBYTECODE=1` keeps it from writing the cache.
  - Nothing is downloaded, and nothing but these files is decoded or run.
- **Nothing is installed for you.** Commands in this README that install software, such as `npm i -g @openai/codex` for the optional Codex executor, are for you to run if you want that tool; the plugin downloads and installs nothing.
- **`orch`'s only network request** is DeepSeek's balance, `GET https://api.deepseek.com/user/balance`, sent with each DeepSeek key your profiles use. It happens on `orch balance`, `orch status` and `orch spend`, before a DeepSeek run that a per-session budget checks and after every DeepSeek run, and on SessionStart and on each user prompt through a detached `orch balance --quiet` when any stored figure is older than 10 minutes. That covers every key, including the ones the current project does not use; hooks start at most one fetch every two minutes. `ORCH_BALANCE=off` turns it off everywhere. `orch prices check` makes no web request: it writes a task for an agent.
- **Executors** start only through `orch run …` or `orch launch`. Each sends its provider the task prompt, the project rules (CLAUDE.md, AGENTS.md) and whatever files it reads or commands it runs in its working folder:
  - Codex: `codex exec` → OpenAI, on your Codex login or API key;
  - DeepSeek: headless Claude Code (`claude -p`) → `https://api.deepseek.com/anthropic` with your DeepSeek key (`ORCH_DEEPSEEK_BASE_URL` changes the address);
  - Claude: headless Claude Code on your own Claude login or API key → Anthropic;
  - `orch launch deepseek`: an interactive Claude Code session whose every model request goes to DeepSeek.
- **Claude subagents** (`orch-*`) run inside your session, like any Claude Code subagent.
- **Manual agents** (Antigravity and similar) are never started or driven: Lanewise writes task files and reads the results.
- **Keys** live in `~/.lanewise/secrets.env` or the environment. Each reaches only the adapter that declares it (`# orch-secrets: …`), and `orch key` hands a Claude API-key profile's key to Claude Code as its `apiKeyHelper`. They are not plugin options (`userConfig`), which Claude Code keeps in secure storage. Claude Code passes those values to hooks and MCP servers but not to commands run through the Bash tool, and that is how `orch run` starts. Exporting a key into the session instead would hand it to every command the session runs.

### Codex
Requires Codex CLI signed in with ChatGPT: `npm i -g @openai/codex && codex login`. The login is stored in `~/.codex` and is separate for Windows and WSL. The adapter is written in Python and drives `codex exec --json`: from the event stream it builds a compact log and a token count. On Windows it runs the native `codex.exe` from the npm package, bypassing the `codex.cmd` wrapper, and needs no Git Bash. If only the Codex app is installed, the adapter finds the `codex.exe` bundled with it. You can also point it at a binary explicitly: `ORCH_CODEX_BIN=<path>`. `codex debug models` lists the models available to your account.

### DeepSeek
1. Get a key at platform.deepseek.com and put it in `~/.lanewise/secrets.env` (or in the `DEEPSEEK_API_KEY` environment variable):
   ```
   DEEPSEEK_API_KEY=sk-…
   ```
   Only the `deepseek` adapter receives the key, because it declares `# orch-secrets: DEEPSEEK_API_KEY` in its header. Keys from this file are not passed to other executors.
2. The `claude` CLI must be available in the same environment: the DeepSeek executor is headless Claude Code, see below.
3. `orch doctor` should show `✔ DEEPSEEK_API_KEY`.

Multiple keys (personal, work) and per-project key selection are handled by [profiles](#executor-profiles-keys-accounts-rules-projects). A second Codex account is a profile too.

`orch balance` reads the balance of the DeepSeek account behind a key from DeepSeek itself (`GET /user/balance`) and keeps it in `~/.lanewise/balances.json`. The status line then shows, for every API-billed scope of the directory, our own estimate and limit next to it, in parentheses after the session counter of the same name: `DeepSeek@client 1.5M/988k (est. $1.47/$10, account $15.09)`. The account figure is the provider's, shared by all keys of that account (which can also be spent from outside `orch`), so it is never a key's balance and a drop in it says nothing about one key's spend; limits stay hand-set budgets for `orch`'s own runs, and the provider's refusal (402) is what stops an empty account. Other providers give an ordinary key no balance to read, so they show only the estimate. See `orch guide spend`.

`orch spend` prices tokens from a table (`registry/prices.json`, overridden by `~/.lanewise/prices.json`) and warns when a provider's prices are older than 30 days. `orch prices show` prints the table in effect with each provider's source and date. To refresh it, `orch prices check` writes a task for a cheap agent with web access (`orch` itself makes no web request); `orch prices diff <its report>` shows what the report would change, and `orch prices apply <its report> --yes`, after your confirmation, writes dated entries to your personal file. A newer plugin version's built-in prices replace an older check. See `orch guide spend`.

Codex model capacity failures return exit 75 and block only the selected model for about ten minutes.
On native Windows, write workers may need a scratch directory with readable parents and explicit `--add-dir`
permission for tests using temp repositories; see the Codex [registry notes](registry/providers.yaml).

## How CLI executors work

A Claude subagent (Agent tool) is an agent loop inside the same Claude Code session: the session itself executes its tool calls. You can't plug a foreign model in there, since subagents call the same API as the session. Claude Code doesn't drive an external process; to Claude Code it is just a command: start it in the background, get notified when it finishes, read the output. So the executor needs an agent loop of **its own**:

- **Codex** has one (`codex exec`), with a `read-only` / `workspace-write` sandbox;
- **DeepSeek** has none — over the API it only answers with text. The loop comes from headless Claude Code (`claude -p`) pointed at DeepSeek's Anthropic-compatible API (`https://api.deepseek.com/anthropic`). The DeepSeek model gets Read/Grep/Glob/Edit/Write/Bash and works like a Sonnet subagent. You pay from your DeepSeek balance; subscription limits are not consumed.

To the orchestrator both look the same: `orch run <provider> … ` in the background → a `STATUS: DONE | PARTIAL | BLOCKED` report with the sections "Done / Changed files / Verification / Blockers", plus the paths to `output.md` and `log.txt`. `orch` adds the executor role to the task itself: who the executor is, that another Claude Code instance is directing it, the rules and the report format. For DeepSeek the role goes into the system prompt, for Codex at the top of the prompt. The role also tells the executor to run an allowed command on its own, without `cd`, `&&`, `;` or pipes around it, because a permission rule matches the command as written.

Reports beginning `STATUS: BLOCKED` or `PARTIAL` keep that outcome in the run header and usage ledger even
when the adapter exits 0; the orchestrator reads and handles the report.

### Why the nested Claude Code doesn't conflict with yours

| Risk | Mitigation |
|---|---|
| The executor latches onto your session (message-channel socket and token, session id, effort) | `orch` strips every `CLAUDECODE` / `CLAUDE_*` variable from the executor's environment (except the Git Bash path) |
| It uses your Claude subscription, your settings or your `ANTHROPIC_*` variables | a config directory of its own, `~/.lanewise/workers/deepseek-<platform>` (no OAuth, plugins or sessions); all `ANTHROPIC_*` are replaced with DeepSeek values; the variables are set only for the child process, your terminal is unchanged |
| Hooks fire — yours, the plugin's or the project's | no plugins are installed in its config; `--setting-sources user` doesn't load the project's `.claude/settings*.json`; `ORCH_WORKER` silences Lanewise's hooks if the plugin loads anyway |
| MCP servers, auto-memory | `--strict-mcp-config`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` |
| The executor starts delegating on its own | with `ORCH_WORKER` set, `orch run` / `orch handoff` refuse to run; it is not given the Agent tool |
| It goes beyond the task | `--permission-mode dontAsk`: only what is explicitly allowed runs. Reading and search only inside `--cd`; writing via `Edit(./**)`, `Write(./**)`; Bash: read-only git plus whatever the orchestrator granted with `--allow 'Bash(npm test:*)'`. Everything else is denied without prompting, and the list of denials comes at the end of the report |
| A hung or orphaned process burns money | on timeout `orch` kills the whole tree: the process group on Linux, a Job Object on Windows (where the tree also dies together with `orch`) |
| It doesn't see the project rules | `--setting-sources user` also skips the project's CLAUDE.md, so `orch` passes CLAUDE.md (with `@` imports expanded) and AGENTS.md into the system prompt itself — see "Project rules for every executor" |

Out of balance (HTTP 402) → exit 75, and DeepSeek is blocked until `orch quota clear deepseek`. Rate limit (429) → blocked for 15 minutes. Invalid key (401) is an ordinary error. The words "quota" and "429" in the DeepSeek executor's own output do not trigger a block (`# orch-limit-detect: exit-code`).

### Claude as an external executor

`adapters/claude` runs headless Claude Code on **your own** Claude login (`orch run claude --model sonnet --effort high …`). In a Claude-led session you don't need it — Claude workers are the plugin's subagents. It is the Claude lane of a [non-Claude lead](#deepseek-as-the-lead), where every in-session request goes to the lead's API. Same isolation as the DeepSeek executor, but on your Claude config, because that is where the login lives: `--setting-sources user` plus `disableAllHooks`, no MCP servers, no auto-memory or session files, and the lead's endpoint and token are stripped from its environment. A profile can point it at another config directory (`--home`, a second account) or at an API key (`--key`). A usage limit → exit 75 with the reset time.

## Usage

Usually there is nothing special to do: give it a task and the skill kicks in on its own. To invoke it explicitly:

Configuring the plugin is done in the session, in plain words; "how do I set this up here?" is answered by the
[`settings` guide](skills/orchestrate/reference/settings.md) (`orch guide settings`), which maps every setting to its
command, storage and scope.

| Command | What it does |
|---|---|
| `/lanewise:run <task>` | split → assign models and effort → execute |
| `/lanewise:status` | who is unavailable, what is pending on the manual channel, what comes next |
| `/lanewise:quota codex is out until 18:00` | report a limit (or "Codex works again", "topped up DeepSeek") |
| `/lanewise:profile deepseek work` | executor profiles: which key/account, models and rules, per project or by default (see below) |
| `/lanewise:manual` · `AG-0004 to Antigravity` | the manual task pool: show it, take a task, mark it done or cancel it |
| `/lanewise:done AG-0003` | a manual task is done (if the agent did not write RESULT.md) |
| `/lanewise:away until 19:00` / `back` | close or reopen the manual channel |
| `/lanewise:usage` · `list` | session usage: which model did what and how many tokens it spent |

You can also report limits without commands, in plain words: "Sol is out until 9 am tomorrow", "Argon's weekly quota ran out, it resets on Wednesday", "Opus is running low — go easy on it". Restrictions with a stated time lift on their own. If Codex hits a limit or DeepSeek runs out of balance, exit code 75 signals it: the block is set automatically and the task goes to a fallback.

## Claude subscription budget: use it or lose it

A Claude subscription's 5-hour window expires at its reset, and whatever was not used is gone, while DeepSeek and
other API-key executors cost money per token. Lanewise projects the window to its reset at the current pace. The
usage numbers are account-wide, so every session on the account is included. The pace is the higher of the window
average and the last 30–60 minutes, which tracks every instance that is consuming right now (neither is projected
during the first hour of the window; a used share already at the reserve counts at once). A reserve (10% of the
window and 10% of the week by default) is kept for your other sessions and as a safety margin:

- **surplus** — at least 30% of the window would expire unused beyond the reserve, and the weekly limit has room.
  Until the reset, the orchestrator gives Claude subagents the subtasks it would otherwise give to API-billed
  executors. Codex and the manual pool keep their tasks. When several sessions are active, each one
  gets its share of the surplus, so they don't all pile onto Claude at once.
- **tight** — the five-hour window reaches its reserve, or weekly usage reaches its reserve, or the weekly
  projection reaches it after the first 24 hours. Weekly TIGHT works without current five-hour numbers. The
  orchestrator treats Claude as low and offloads to Codex and DeepSeek.

Each figure is used with its own measurement time: a five-hour sample older than 20 minutes shows its age and cannot
enable SURPLUS, while a weekly overrun raises TIGHT without current five-hour numbers.

The mode appears in `orch status` and at session start, and the orchestrator gets an event when it changes. The
numbers come from Claude Code itself, which passes them to the status line command (`rate_limits`). Set Lanewise's
command as your status line once, in `~/.claude/settings.json`:

```json
"statusLine": {"type": "command", "command": "orch statusline"}
```

To keep your own status line, use `orch statusline --then "<your command>"`. Without the status line you can give the
numbers in plain words ("Claude: 40% of the session used, resets at 18:00") → `orch budget set --used 40 --resets 18:00`.
`orch budget` shows the current state and the active consumers Lanewise knows of. Those are the Claude Code
sessions with this plugin active in the last 15 minutes and running `orch run claude` executors; a session led by
DeepSeek doesn't count. The thresholds live in the `claude` profile: `--opt reserve=25` (keep more for other
sessions), `week_reserve=15`, `surplus=50`, or `surplus=off` to switch the mode off.
Lanewise also watches the orchestrator's own limits: before a five-hour window would run out at its reset, or a
week, spend limit or balance would run out within two hours or with under 5% left, the hooks ask one question in
each session — pause this session until the reset, continue and ask again later (after an hour or ten points of
growth), or continue without questions in this session (`orch watch answer …`). It uses the budget's own pace and
projection; for the week and a monthly spend limit it also warns early, when both pace estimates exhaust the limit
well before the reset. `orch watch` shows every limit projected, and the status line marks a paused session.
Thresholds are `--opt` settings of the `claude` profile (`watch_horizon_h=2`, `watch_low=5`, `watch_early_share=15`,
`watch_early_min_data_h=24`, `watch_ask_again_min=60`, `watch_ask_again_step=10`), `watch_early=off` turns off only
the early warning, and `watch=off` silences the watcher — `orch guide budget`.
A project whose Claude or Codex profile has an API `key` is API-billed instead: no subscription line, no mode, and the
session doesn't write its numbers into the shared snapshot.

Codex's limits are read the same way from its own session logs (`$CODEX_HOME/sessions/…`, an undocumented format
parsed defensively) and shown as a `Codex subscription: …` line next to the Claude one, with `TIGHT: treat Codex
as low` when a window or its projection reaches the reserve — see the `codex` profile's `reserve`/`week_reserve`.
The status line gets up to three more blocks: `⏸ paused until 16:50` while the session is paused, the Codex limits,
and the current session's tokens per account, one account per
line — the first on the heading line, each further one indented by two spaces — with cache reads as a third figure and
left out when an account had none, which agrees with `orch usage`:

```
Session in/out: Claude 370k/111k +28M cache
  Codex 450k/84k
```

An account is a profile label, so a provider whose usage goes to different accounts shows one counter each, never a
sum: with a subscription login and two DeepSeek keys,

```
Session in/out: Claude 1.5k/150 +6.0k cache
  Codex 400/40
  DeepSeek@client 500/60
  DeepSeek@personal 100/10
```

The plain account (the built-in profile) comes first within a provider, then the labels alphabetically. This session's
own Claude thread counts under its key profile's label when it bills to a key, else as `Claude`, together with
`orch run claude` on the same default login. A non-Claude lead's own thread and its `orch-*` subagents count under
the lead's label — `DeepSeek@work`, not plain `DeepSeek` — whether the lead was launched or detected.

## DeepSeek as the lead

When Claude limits run out, to save Claude quota, or for a setup without Claude at all, start the session with
DeepSeek as the orchestrator — from a terminal, in the project:

```bash
orch launch deepseek                       # DeepSeek leads; Claude is still available as an executor
orch launch deepseek --no-claude           # no Claude models at all in this session
orch launch deepseek --profile work --model deepseek-v4-pro --use codex=alt -- --resume   # Pro on purpose
orch launch deepseek --dry-run             # show the command and the environment (key masked)
```

This is the same Claude Code with your settings and plugins, but every model request goes to DeepSeek's
Anthropic-compatible API: the main thread and all subagents run on the lead model (default `deepseek-flash`), and
background calls run on the profile's fast model. The key comes from the `deepseek` profile or `secrets.env`. Your
`ANTHROPIC_*` variables are dropped for the session, so no Anthropic credential is sent to DeepSeek. The skill, the
registry, profiles and the manual pool work as usual; `orch status` starts with `Lead: …`, and the orchestrator
follows [`reference/lead.md`](skills/orchestrate/reference/lead.md):

- Claude is reached only through the Claude executor (`orch run claude`, on your Claude login and its limits);
- `--no-claude` (or `orch profile use claude off`) turns that off too: `orch run claude` answers `PROFILE_OFF`, and
  cross-review goes Codex ↔ DeepSeek;
- `--use PROVIDER=PROFILE` picks profiles for the whole session, including the lead itself; only an explicit
  `--profile` overrides it. Disabled or unknown lead profiles refuse to launch.

A session started by hand on DeepSeek's endpoint (`ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic` plus
`ANTHROPIC_AUTH_TOKEN`, no `ORCH_LEAD`) is detected as a lead by every `orch` process, hooks and the status line
included: the endpoint is one an adapter declares (`# orch-endpoint:`), and the token picks the profile whose key it
is (`DeepSeek@work`), else the bare provider. `orch status` then says
`Lead: DeepSeek@work · … (detected: ANTHROPIC_BASE_URL)`, routing, `orch key` and the worker environment follow as
under `orch launch`, and the session's own thread counts under the lead's label in `orch usage` and the status
line. Anthropic's own API and other proxies are not a lead. A detected lead has already started, so SessionStart
only warns when its spend scope is at the limit.

Limits of the mode: Claude Code features that rely on Anthropic-only API capabilities (web search, image input) may
not work on the DeepSeek endpoint, and Claude Code's cost estimate in `orch usage` assumes Claude prices.
The launch environment drops `ANTHROPIC_*` and `CLAUDE_CODE_OAUTH_TOKEN`; the lead still uses the operator's config
directory and tools, so this is credential hygiene, not a sandbox. The Claude executor (`orch run claude`) reloads
the user settings of its config dir: if their `env` points `ANTHROPIC_BASE_URL` at another provider's lead endpoint
(or sets a non-Claude `ANTHROPIC_MODEL`), the run fails before starting with `STATUS: BLOCKED` and names the setting, rather than running off Claude.

Parallel sessions serialize shared state through bounded OS locks and atomic JSON writes, so tasks and usage survive
them; busy hooks and the status line skip their update silently. Manual `new` and `take` obey the profile's hard
`max_open` even with `--force`. `handoff wait --any` returns an existing unreported final result once.

## Executor profiles: keys, accounts, rules, projects

A profile describes **how** the orchestrator uses an executor: with which API key or account, which models and effort levels are allowed, whether it may change files, which tasks to use it for. Each provider (`claude`, `deepseek`, `codex`, `antigravity`) has a default profile, and a project can pin a different profile or switch the executor off entirely (`off`). With no configuration the built-in `default` profile applies: the normal environment (`~/.codex`, `DEEPSEEK_API_KEY`) with no restrictions, so everything works out of the box.

An executor on an API key instead of a login is a profile too — Codex here, and the same shape for Claude:

```bash
# `work` is a free label, not a fixed word; the key itself goes into ~/.lanewise/secrets.env as
#   CODEX_API_KEY_WORK=sk-…  (never into the command, the repository or your shell history)
orch profile set codex work --key CODEX_API_KEY_WORK
orch profile use codex work       # binds the profile to the project in the current directory
```

None of this is needed with the usual ChatGPT login (`codex login`): the built-in `default` profile uses it.

You can manage profiles right in the session, in plain words or with `/lanewise:profile`: "don't use DeepSeek in this project", "use DeepSeek with the work key here", "don't offer Antigravity in this project", "leave Codex alone by default". The orchestrator turns this into commands:

```bash
# several DeepSeek keys: the keys themselves go in ~/.lanewise/secrets.env, the profile holds only the variable name
#   DEEPSEEK_API_KEY=sk-…        (personal)
#   DEEPSEEK_API_KEY_WORK=sk-…   (work)
orch profile set deepseek personal --key DEEPSEEK_API_KEY --default
orch profile set deepseek work --key DEEPSEEK_API_KEY_WORK --models deepseek-flash,deepseek-v4-pro \
  --max-effort high --write no --use-for tests,review --rules "open-source code only"

# a second Codex account: its own CODEX_HOME (login) and, optionally, a codex --profile settings layer
orch profile set codex alt --home ~/.codex-alt --codex-profile fast
CODEX_HOME=~/.codex-alt codex login          # PowerShell: $env:CODEX_HOME="$HOME\.codex-alt"; codex login

# manual channel: Argon only, and no more than one task in hand
orch profile set antigravity argon --models gemini-4-argon --max-open 1

orch profile use deepseek work               # for the current project (the whole git project, including its worktrees)
orch profile use antigravity off             # no manual tasks in this project
orch profile use codex off --default         # Codex is off by default
orch profile use claude off                  # no Claude workers in this project (no orch-* subagents, no orch run claude)
orch profile use deepseek work --path ~/work # every project under ~/work
orch profile use deepseek inherit            # remove the project binding
orch profile rules --set "Do not touch credentials" # requirements for every executor here
orch profile rules                           # show applicable project rules
orch profile rules --clear                   # remove the project's entry
orch profile show                            # what applies here and where it comes from
orch profile list                            # all profiles, defaults and bindings
```

Resolution order: `--profile` on a specific run (only when you ask for it) → session-wide choices (`ORCH_PROFILES=claude=off,codex=alt`, set by `orch launch --no-claude` / `--use`) → the binding of the project or of the nearest directory above it → the default profile → the built-in `default`.

Project rules are private requirements for the orchestrator, independent of profiles and their fallbacks. Use
`--path /path/to/dir` to set or clear a directory's rules; all matching parent rules apply.

| Field | Meaning | Enforced by |
|---|---|---|
| `session_soft`, `session_hard`, `balance_floor` | optional session account decrease percentages (above 0 to 100; soft below hard) and nonnegative floor in the account currency; DeepSeek balance API only. Soft yields to Claude TIGHT; hard/floor always apply. Fresh balance required before a run; exit 75 `SESSION_BUDGET`, fallback takes over. Each session has its own baseline and counts all account spending; spend limits still apply. Empty CLI values clear fields. See `orch guide spend`. | `orch` |
| `key` | name of the variable holding the API key (from the environment or `secrets.env`); the adapter receives its value as `DEEPSEEK_API_KEY` (`ANTHROPIC_API_KEY` for `claude`, `CODEX_API_KEY` for `codex`) | `orch` |
| `home`, `codex_profile` | Codex account (`CODEX_HOME`) and the `codex --profile` settings layer; for `claude`, its config directory (`CLAUDE_CONFIG_DIR`) | `orch` |
| `fast_model`, `base_url` | DeepSeek: model for light background calls, endpoint | `orch` |
| `off` (instead of a profile) | the executor is not started: `orch run` / `orch handoff new` → `PROFILE_OFF`, exit 75 (`--force` doesn't help) | `orch` |
| `models` | allowed models, the first one is the default; for Antigravity, model keys (`gemini-4-argon`) | `orch` |
| `max_effort` | effort ceiling: anything higher is lowered, with a note in the report | `orch` |
| `write: false` | `analysis` only, writing tasks are rejected | `orch` |
| `max_open` | Antigravity: how many manual tasks at once | `orch` |
| `use_for`, `prefer_for` | task types (`tests`, `docs`, `review`, `implement`…): only for these / these first | orchestrator |
| `rules` | free-form rules ("open-source code only", "don't touch migrations") | orchestrator |

What a project binding gives you:
- **Its own balance and its own limit.** If the `work` key runs out of money, only `deepseek@work` is blocked. Projects on other keys keep working. "Topped up DeepSeek" lifts the blocks on all keys.
- **Keys stay out of the repository.** Everything is stored in `~/.lanewise/profiles.json`, with the project path recorded in a normalized form (`c:/users/…`). If `ORCH_HOME` is shared, the bindings match between Windows and WSL.
- **A corrupted file doesn't re-enable what you turned off.** If `profiles.json` can't be read, CLI executors and manual tasks are not started, and `orch status` warns about it.

A profile with an API `key` is **API-billed** (per token), not a subscription: `orch status` shows it bills to the key,
there is no `Claude subscription:` / `Codex subscription:` line and no SURPLUS/TIGHT, and routing treats it as the
offload lane. The key is *explicit-only* — only the profile's `key` supplies it, so a stray `CODEX_API_KEY=` line in
`secrets.env` never switches a login profile to API billing. A rejected key (401) names the profile and is an ordinary
error; an exhausted balance still reports the limit as usual.

For Claude, `orch profile use claude <profile>` with a key profile also writes Claude Code's `apiKeyHelper` into the
project's `.claude/settings.local.json` (git-excluded), so **the session itself and its subagents** bill to that key;
`--default` writes it to your user settings instead. It takes effect after a restart, and `/status` shows the active
credential. Switching back to a login profile (or `inherit` / `off`) removes the helper when orch wrote it. `--path`
binds a profile for `orch run claude` only and says so.

## Manual channel: a task pool for Antigravity and other agents

Tasks that are worth doing by hand in Antigravity (UI checks in a browser, a broad review, a second opinion from another model family, long autonomous work) go **into a pool** instead of being dumped on you right away. You choose what to take and when.

1. **Browse the pool:** `/lanewise:manual` (or "what's in the pool?"). The same list is in `<project>/.lanewise/MANUAL.md`, which you can keep open in your editor. It shows each task, the suggested agent and model, and how long it has been waiting.
2. **Take a task:** "AG-0004 to Antigravity" (or "AG-0004 to Cursor"). The orchestrator runs `orch handoff take`: it completes TASK.md in the project folder and shows a card with the folder, the model and thinking level, and the line to paste — on your clipboard only with `--clip`, which `/lanewise:manual` passes.
3. You keep the project folder open in the agent, pick the model and paste the line. **That's it.** You don't need to report back when it's done: the agent writes `RESULT.md` itself.

The pool has a clock that runs from your last take (or from when the pool opened). Each time 5 minutes pass without a take, the orchestrator checks the pool. It takes back every task that is no longer worth waiting for — you are away, the task now blocks other work, or an automated executor would do it just as well — and runs them, in parallel where that is allowed. If there is no such task, it takes back only the next one, and only once the previous one it took this way has finished. So while you are picking tasks nothing is taken away, and an ignored pool drains one task at a time. A take restarts the clock. It hands a task straight to you, bypassing the pool, only when you ask (`orch handoff new`).

**How the agent learns it is part of the system.** `orch` adds to TASK.md:
- the role: you are a Lanewise executor, the task was set by the orchestrator (Claude Code), which will also review the result;
- links to the project rules (`CLAUDE.md`, `AGENTS.md` — whichever exist);
- the protocol: on start, `RESULT.md` with the lines `STATUS: IN_PROGRESS` and `AGENT: product · model`, at the end `DONE`, `BLOCKED` or `FAILED` and a report; the scope; a ban on launching other agents. A task is **read-only** by default: the agent may write only its `RESULT.md` and is told to run no shell commands, since each one can stop and wait for your confirmation. A task that changes files (`--write`) works in a git worktree of its own that `orch` makes inside the project folder (`.lanewise/wt/<id>`, branch `ag/<id>`) when the task is taken; it leaves the changes uncommitted and the orchestrator reviews and commits them. Either way the agent keeps the project folder open and is never switched: you do not open the worktree. Several such tasks can be open at once, and the project folder may be dirty. A folder that is not a git repository takes read-only tasks only. Tools that walk hidden folders (jest, for one) may see an open nested worktree.

For Antigravity, the project folder also gets one general rule, `.agents/rules/lanewise-task.md`, with `trigger: always_on`. Antigravity injects it into every turn, so the protocol isn't lost in a long session; it applies only when a message names a task id, so several open tasks do not mislead each other. The rule is excluded from git and stays after a task closes. Antigravity needs no extra setup. If you like, add a line to your global rules (`~/.gemini/GEMINI.md`): "follow tasks from `.lanewise/handoffs/*/TASK.md` strictly according to their protocol".

The `AGENT:` line goes into the usage log, so you can see who completed a manual task and with which model.

How the orchestrator learns that a task is finished:
- **while it is working** — a hook after tool calls, at most once a minute;
- **at the end of each of its turns** — the Stop hook won't let it finish if a result has arrived and makes it process the result: verification, cross-review, merge;
- **on any message from you** — the prompt-submit hook;
- **when there is nothing else to wait for** — it starts `orch handoff wait --any` in the background. If your version of Claude Code wakes the session when a background command finishes, it carries on by itself. If not, the event is picked up with your next message, even just "so?". For desktop notifications, set `ORCH_NOTIFY_CMD` to any command that takes the text as `$1`.

If an assigned task hasn't been started within 30 minutes, you get a single reminder. If it hasn't been started within 180 minutes, the orchestrator reassigns it to a fallback. You have at most two tasks in hand at once, and the pool holds at most five. Small tasks are batched and handed out together. All these numbers are configurable in the registry, in the `operator` section. An `antigravity` profile (or `cursor`, etc.) lets you turn off the manual channel for a project and limit the models and the number of tasks.

**Important (Google ToS):** the plugin does not control Antigravity programmatically. It doesn't run `agy`, doesn't use computer use, doesn't paste text and doesn't touch OAuth. It only writes and reads files in the project folder (TASK.md, RESULT.md, the general rule and the task's own worktree). Do not add such automation: Google bans accounts for it.

## Usage log: who did what and how much it spent

`orch usage` (or `/lanewise:usage`) shows, for the current session:

```
Session 3f9a1c2e · “Config parser” · 29.10 12:01–16:40
  who                          model                    effort  what for                          input   cache  output
  orchestrator                 claude-opus-5-5          xhigh   main thread                        1.2M     45M    310k
  subagent orch-sonnet-high    claude-sonnet-5-5        high    Find parse() calls                  80k    1.1M     12k
  codex                        gpt-6.1-terra            high    Implement the parser · OK · 6m     210k    1.8M     25k
  deepseek@work                deepseek-flash           high    Parser tests · OK · 3m              95k    600k    9.0k
  antigravity (manual)         Antigravity · Gemini 4…  High    Form UI check · DONE · 42m            —       —       —
  Totals by model: …
```

- **Claude: main thread and subagents** — taken straight from the Claude Code session transcript: the model, effort and tokens of every response. For a subagent, its type and the task `description` are shown.
- **Codex, DeepSeek and the Claude executor** — every `orch run` writes to `~/.lanewise/usage.jsonl` the model, the task (`--task` or the first line of the prompt), the status, the time and the tokens reported by the adapter.
- **A DeepSeek-led session** shows `lead: deepseek…` in its header and DeepSeek model ids for the main thread and subagents.
- **Manual agents** don't report tokens. For them you see who did the work (the `AGENT:` line from RESULT.md), with which model and how long it took.

There are other modes too: `orch usage --list` shows the project's recent sessions, `--session <id>` a specific one, `--json` gives output for your own reports. Usage is collected per Claude Code session, so from a terminal pick one with `--list` and `--session <id>`; `--session none` shows the records made outside a session (a manual task closed from a terminal, an `orch run` outside one). Claude Code deletes old transcripts over time, so the SessionEnd hook saves the session's numbers to the log when the session ends. To disable the log, set `ORCH_USAGE_LOG=0`.

## Project rules for every executor

Different agents read project rules from different files:
- Claude Code — `CLAUDE.md` with `@` imports;
- Codex and Antigravity — `AGENTS.md`;
- the DeepSeek executor (headless Claude Code without project settings) — nothing.

`orch` evens this out: each CLI executor gets exactly the files it doesn't read on its own. Codex gets CLAUDE.md, DeepSeek gets CLAUDE.md and AGENTS.md. `@` imports are expanded, and no rule arrives twice. For a manual agent, TASK.md points to these files.

A convenient layout for a project that uses this workflow is the one this repository uses itself:
- shared rules go in `AGENTS.md`: every agent reads them;
- `CLAUDE.md` holds the line `@AGENTS.md` plus whatever only Claude Code needs.

This way the rules don't drift apart, and each agent sees them exactly once.

## Model registry

`orch registry path` shows which file is currently in effect. Precedence: `<project>/.lanewise/providers.yaml`, then `~/.lanewise/providers.yaml`, then the built-in one. A copy records the version it was made from; when the built-in registry changes later, SessionStart and `orch doctor` warn that the copy is stale, and `orch registry diff` / `orch registry diff --accept` show the difference and record the built-in one as current.

What it contains:
- **slots** — provider × model × effort, each with a cost (`cost`: the load on the subscription limit; for DeepSeek, the relative token price), a difficulty ceiling (`max_difficulty`) and strengths (`good_for`);
- **default routes** (`routing`) for each task type, including cross-review between the Claude · OpenAI · DeepSeek families;
- **`policy.never_auto`** — slots that are used only with your permission (Codex ultra, Fable);
- **manual channel parameters** (`operator`).

Model names and effort levels change. Check against `/model` in Claude Code, `/model` in Codex, the Antigravity model picker and api-docs.deepseek.com (currently `deepseek-flash` — V4.1 Flash — and `deepseek-v4-pro`; for a 1M context you can pass `--model deepseek-flash[1m]`).

## New executors (CLI / API / MCP)

- **CLI or API:** copy `adapters/_template.example` to `~/.lanewise/adapters/<name>` and add the provider with its slots to the registry. An adapter can be bash or Python: `orch` runs a Python adapter with its own interpreter, which is simpler on Windows. Invocation: `orch run <name> --model … --effort … --mode analysis|write [--allow …]`. The adapter contract is described in the template: environment variables, exit codes, `usage.json` with tokens, and the `orch-secrets`, `orch-limit-detect`, `orch-context-native` and `orch-profile-env` directives. Examples: `adapters/codex` is a CLI with its own agent loop, `adapters/deepseek` is an API without one (any Anthropic-compatible endpoint will do), `adapters/claude` is headless Claude Code on your own login; the last two share `adapters/_claude_headless.py`. An adapter that declares `# orch-launch: env` can also lead a session (`orch launch <name>`).
- **A manual agent** (Cursor, Windsurf, Jules…) needs no adapter: the same pool, `orch handoff take <id> --agent cursor`. Its profile and quota are tracked under its own name.
- **MCP:** add the server to Claude Code and describe the provider in the registry with `lane: mcp`. You keep track of such a provider's quota with `orch quota`.

## Where things are stored

| Path | Contents |
|---|---|
| `~/.lanewise/availability.json` | limits and availability, shared by all projects |
| `~/.lanewise/providers.yaml` | your registry |
| `~/.lanewise/secrets.env` | API keys (`DEEPSEEK_API_KEY=…`, `DEEPSEEK_API_KEY_WORK=…`), only for the adapters that declare them |
| `~/.lanewise/profiles.json` | executor profiles, defaults and project bindings (`orch profile …`) |
| `~/.lanewise/usage.jsonl` | usage log: runs, manual tasks, session snapshots (`orch usage`) |
| `~/.lanewise/claude_usage.json` | the Claude subscription's last known window usage and its recent history, for the budget mode (`orch budget`) |
| `~/.lanewise/codex_usage.json` | the Codex account's last known limits, per `CODEX_HOME` (the `Codex subscription:` line) |
| `~/.lanewise/session_tokens/<session>.json` | one session's byte offsets and running token totals per account, for the status line's session part; removed a day after its last save |
| `~/.lanewise/sessions.json` | active Claude Code sessions and Claude executor runs: the budget's consumer count |
| `~/.lanewise/watch.json` | each session's limit-watch answer (pause until the reset, continue, continue-session) and the limits it answered for; removed at SessionEnd or once the session has been quiet for 7 days |
| `~/.lanewise/workers/deepseek-<platform>/` | isolated Claude Code config for the DeepSeek executor |
| `<project>/.lanewise/runs/` | executor runs: prompt, role, project rules, response, log, tokens |
| `<project>/.lanewise/handoffs/AG-…/` | manual tasks: meta, BODY.md, TASK.md, RESULT.md |
| `<project>/.lanewise/MANUAL.md` | the manual task board: pool, assigned, completed |
| `<project>/.lanewise/wt/<id>/` | the worktree of a manual task that changes files (inside the project folder, git-ignored) |
| `<project>.wt/<name>/` | worktrees for isolated tasks of automated executors (`orch worktree`, next to the repository) |
| `<project>/.agents/rules/lanewise-task.md` | the general Antigravity rule (always on, applies only to a named task); stays after a task closes |

`.lanewise/` and the Antigravity rule are added to `.git/info/exclude` automatically (nothing is added outside a git repository), and `.gitignore` is left alone. `orch footprint` lists everything outside Claude Code.

Before 0.36.0 both folders were named `.partitura` (`~/.partitura/` and `<project>/.partitura/`); before 0.35.0,
`.orchestra` (`~/.orchestra/` and `<project>/.orchestra/`). `orch` reads either where it is; `orch migrate` moves it
to the new name — it prints what would move and changes nothing until run with `--yes` (`orch migrate --all --home`
covers every known project and the personal folder). A place that has more than one of them is reported, never
merged.

## Alongside maestro-flow

You can install both: maestro commands also run inside Claude Code, and this skill will suggest the model and effort. In maestro's `cli-tools.json`, keep `agy` disabled (`"enabled": false`) for the same ToS reason. For Codex and DeepSeek, prefer `orch run …` over `maestro delegate`: only `orch` automatically catches limits and balance and isolates the executor.

## Testing

The self-test lives at the repository root (`tests/`), not in the installed plugin. From the root, `bash tests/run_tests.sh` runs regression checks against a temporary repository with fake `codex` and `claude`: limits, detection of exhausted quotas and balance, timeouts and process-tree termination, DeepSeek and Claude executor isolation (environment, permissions, role, CLAUDE.md), the DeepSeek lead (`orch launch`: endpoint, token, models, no Anthropic credentials, `--no-claude`), profiles (keys and accounts, project and directory bindings, `off`, models, effort, write ban, separate per-key balance blocks), project rules for each executor (CLAUDE.md with imports, AGENTS.md), the usage log (transcript parsing, Codex/DeepSeek tokens, SessionEnd snapshot), the manual task pool (offer → take → result, the Antigravity rule, the pool clock and its checks, one-at-a-time reclaims), the Claude budget mode (status line snapshot, surplus / tight projection, reserves, the recent pace of all sessions, active consumers and the shared surplus, profile thresholds), the ban on nested delegation, worktrees, reminders, hooks, guide and footprint. The tests run both in WSL/Linux and in Git Bash on Windows — run them in both.

The suite is a preamble (`tests/lib.sh`) and sections (`tests/sections/NN-<slug>.sh`). `bash tests/run_tests.sh
--list` names them, and `bash tests/run_tests.sh <section>` runs one alone, together with what it needs.

The suite aborts on setup failures and supports `ORCH_TEST_TIMING=1` for per-check timings. Regression checks
include real parallel offers, take/reclaim races and status-line updates; shared-state I/O failures and rollback;
launch profile precedence; every worker handoff guard; measurement freshness and weekly TIGHT without five-hour
numbers; hard manual capacity; existing wait results; inferred activity warnings; OAuth hygiene; and run outcomes.
Claude budget projections use independent window measurement times: five-hour samples older than 20 minutes
show their age and cannot enable SURPLUS, while weekly pressure can still raise TIGHT.
