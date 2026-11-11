# Changelog

## 0.37.0

- **Account balances stay fresh while you work.** A long session used to show a figure fetched hours ago unless you
  reran `orch status`. Now SessionStart and every user prompt start a detached `orch balance --quiet` when any stored
  figure is older than 10 minutes, so the balance keeps up with the work even in a session that runs no `orch status`.
  This covers **every key** the provider has a balance API for, including the ones the current project does not use.
  Hooks start at most one fetch every two minutes (a marker in `~/.lanewise/.balance-refresh`), so several sessions and
  prompts do not multiply requests; a failed fetch counts as asked, so a down provider is retried only after the same
  10 minutes. `orch spend` now refreshes every stale key (its table shows every key) and `orch status` keeps refreshing
  the project's active ones. `ORCH_BALANCE=off` still stops every request, and nothing runs inside an executor.

## 0.36.0

- **Partitura is now Lanewise.** An AI-agent orchestration product named Partitura already exists, so the plugin
  takes a name of its own. **Where:** the repository is now [orwrkr/lanewise](https://github.com/orwrkr/lanewise);
  [orwrkr/partitura](https://github.com/orwrkr/partitura) stays for a while with a notice pointing here.
- **What changes, what stays.** Commands are `/lanewise:*`, subagent types `lanewise:orch-*`, the skill
  `lanewise:orchestrate`, and the folders `~/.lanewise` and `<project>/.lanewise`. The `orch` CLI and the `ORCH_*`
  variables keep their names, so scripts and settings that name them still work.
- **Upgrading from a clone** (in every environment where you installed it — Git Bash and WSL):
  `git remote set-url origin https://github.com/orwrkr/lanewise.git`, then `git pull`, `bash install.sh`,
  `orch migrate --all --home` (a dry run) and `orch migrate --all --home --yes`, then `/reload-plugins` in open
  sessions.
- **Upgrading without a clone:** `claude plugin uninstall partitura@partitura && claude plugin marketplace remove
  partitura`, then `claude plugin install lanewise --marketplace orwrkr/lanewise`.
- **Old names that keep working.** A personal registry made before 0.36.0 still names subagents `partitura:orch-…`
  (or `orchestra:orch-…` from before 0.34.0), and `orch registry show` reads them as `lanewise:orch-…` in every
  view. The Antigravity rule `.agents/rules/partitura-task.md` (or `orchestra-task.md` before 0.34.0) becomes
  `lanewise-task.md` at a project's next manual task, and `orch footprint` lists the old file until then. Folders
  keep working where they are: `orch` reads `~/.partitura` and `~/.orchestra` (and `<project>/.partitura`,
  `<project>/.orchestra`) until `orch migrate` moves them, and a place that has more than one of them is reported
  instead of merged.

## 0.35.0

- **The plugin's folders follow its name.** The personal folder is `~/.partitura` and a project's state folder is
  `<project>/.partitura` (the `orch` CLI, the `ORCH_*` variables and `ORCH_HOME` keep their names). Both old names
  keep working: `orch` reads `~/.orchestra` and `<project>/.orchestra` where they exist, so an upgrade changes
  nothing in place and a project that keeps the old folder is not touched.
- **`orch migrate` moves them** — `orch migrate [PATH] [--all] [--home] [--yes]`, a dry run by default: it prints
  what would move and changes nothing until run with `--yes`. For a project it renames the folder, rewrites the
  stored paths in `handoffs/*/meta.json` (workdir, TASK.md and RESULT.md paths, the paste line), repairs the git
  worktrees under `wt/`, replaces the `.orchestra/` line in `.git/info/exclude`, rewrites the Antigravity rule and
  regenerates `MANUAL.md`. `--home` moves `~/.orchestra` and the absolute paths into it in the home's top-level JSON
  files (a Codex profile's `home`, say), and open sessions pick the new home up after `/reload-plugins`. `--all`
  covers every known project — the usage log, the profile bindings and the current one. It skips, and says why: a
  task that is handed out and unfinished (its agent writes RESULT.md to the old folder), a run whose process is
  still alive, a personal folder another `orch` process is using, and a project that already has both folders
  (nothing is merged). A rename that fails changes nothing, so it can be retried.
- **`orch doctor` points at the old name**: one line when the current project or the personal folder still uses it;
  hooks and the status line stay silent about it.

## 0.34.1

- **The rename reaches the last two texts.** The six subagents' descriptions said "per the orchestra registry", and
  the plugin README said to disable it through `/plugin` → orchestra; both now use the new name. The self-test
  checks the plugin and its documents for the old name, except where a line explains the rename.

## 0.34.0

- **Orchestra is now Partitura.** Anthropic's plugin directory reserves "Orchestra" for an existing publisher, so
  the plugin, its marketplace, its documentation and the repository (now
  [orwrkr/partitura](https://github.com/orwrkr/partitura); GitHub redirects the old address) take the new name.
  Commands are `/partitura:*`, subagent types `partitura:orch-*`, the skill `partitura:orchestrate`, and the plugin
  folder `plugins/partitura`. The `orch` CLI, `~/.orchestra`, the `ORCH_*` variables and `<project>/.orchestra/`
  keep their names, so limits, profiles, keys, the usage log and manual tasks carry over as they are.
- **Upgrading.** From a clone: `git pull`, then `bash install.sh` in every environment where you installed it (Git
  Bash and WSL). It removes `orchestra@orchestra` and its marketplace and installs `partitura@partitura`. Without a
  clone:
  `claude plugin uninstall orchestra@orchestra && claude plugin marketplace remove orchestra && claude plugin install partitura --marketplace orwrkr/partitura`.
- **Old names keep working where they were stored.**
  - A personal registry made before 0.34.0 still names subagents `orchestra:orch-…`. `orch registry show` reads
    them as `partitura:orch-…` in every view. `orch registry diff --accept` brings the copy up to date.
  - The Antigravity rule `.agents/rules/orchestra-task.md` becomes `partitura-task.md` at a project's next manual
    task, and `orch footprint` lists the old file until then.
- **The self-test moved** from `plugins/orchestra/tests` to `tests/` at the repository root, so installs no longer
  carry it.

## 0.33.3

The first release since the repository went public. Behaviour is unchanged.

- **The plugin has an icon** (`.claude-plugin/icon.png`, source `assets/icon.svg`), so `claude plugin validate
  --strict` passes without warnings.
- **The plugin README says what it runs, sends and fetches.** There is no telemetry. `orch` makes one network
  request of its own, DeepSeek's balance, and the section lists what triggers it; `ORCH_BALANCE=off` turns it off. It
  also says what each executor sends to which provider and where keys go.
- **CodeQL and Dependabot** run on the repository. CodeQL checks the Python code and the workflows. Dependabot keeps
  the workflows' actions current. Two names CodeQL took for secrets were renamed: `ENV_FILE_DENY`, the deny rules
  that keep workers away from `.env` files, and `key_origin()`, which says where a key variable is set.

## 0.33.2

- **Forked sessions no longer count copied history again.** Claude Code's `--fork-session` copies the earlier
  transcript into a new session, so its usage and lead spend included those messages twice. Usage reports,
  session snapshots and status line tokens now count the fork's own messages only. Plain `--resume` already
  used the same session and was counted correctly.

## 0.33.1

- **A lead session's spend is split at counter resets and month starts.** A session run on an API key (`orch launch
  deepseek`, or Claude through an apiKeyHelper profile) was recorded once, at SessionEnd, with the whole session priced
  at that moment. So a counter reset in the middle of a session counted the whole session in the new counter, including
  what was spent before the reset (even when an earlier snapshot of the session had already counted that part in the
  old one); a session across a month boundary landed wholly in the new month; and every token was priced at the hour
  the session ended, although DeepSeek's off-peak hours cost half. Now each message is priced at its own time, and the
  session record carries `spend_parts`: the spend per interval between the cuts, which are each 1st of a month and every
  manual baseline stored for the lead's scope. `spend_usd` is their sum. The spend counters give one record per part, at
  the part's last message time, so a reset or a month start leaves the earlier parts out; of a session's snapshots,
  all the parts of the last one count. Records without parts (written by older versions) count as one, as before, and
  `orch run` records are unchanged. The spend cache is rebuilt from the ledger once (format 4). A monthly counter
  starts at local midnight on the 1st with that day's own UTC offset; after a daylight-saving change in the month it
  started an hour off.

## 0.33.0

- **`orch registry show` is brief by default.** It used to print the whole registry file, comments, per-model notes
  and folded `notes:` paragraphs included, and every orchestrating session carried that text (about 4.4k tokens for
  the built-in file). The default view now holds what picking a slot needs: the file in effect (built-in, personal or
  project copy, with the stale-copy warning when there is one), the `policy` settings and `never_auto`, the
  `operator` numbers, the difficulty scale, each provider's header (`lane`, `billing`, `quota_key`, `efforts`, the
  call) with one aligned line per slot (id, model, effort, cost, `max_difficulty`, the full `good_for`, `agent`), and
  the routes with their comments (`# cross-review`); unknown fields are shown as `key=value` and other top-level
  sections by name. About 1.6k tokens for the built-in registry. `orch registry show <provider>` prints one provider
  in full (its `notes` as one wrapped paragraph, its slots, the routes that name them; an unknown provider exits 2 and
  names the known ones), `--full` the file byte for byte and `--json` the parsed registry (the route comments under
  `routing_comments`). A small parser for the YAML subset the registry uses (nested maps, lists of maps, flow lists
  over several lines, folded scalars, comments) reads personal and project copies made from older versions: unknown
  keys are kept, missing optional fields are fine; a copy that cannot be parsed is shown as is after one line saying
  why. `registry_providers()`, which the status line uses, is unchanged. The skill's step 2 tells the orchestrator to
  read a provider's notes before first using it.
- **A size budget for what the plugin puts into a session.** `tests/check_sizes.py` (the self-test runs it, so CI
  does) estimates tokens as characters / 4 and holds to a budget: the frontmatter descriptions of every agent, skill
  and command together, `skills/orchestrate/SKILL.md`, each `agents/orch-*.md`, `AGENTS.md` plus `CLAUDE.md`, and the
  output of `orch registry show` and of `orch hook session-start` in the self-test's used home. A budget at 85% prints a warning; one over exits 1
  and says to move rarely needed text to `skills/orchestrate/reference/` or to raise the budget with the reason in
  the commit message. `CLAUDE.md` points to it instead of quoting figures that nothing checked.

## 0.32.0

- **`orch prices`: a way to refresh the prices behind the spend estimate.** `orch spend` warned that a provider's
  prices were more than 30 days old but nothing helped to renew them. `orch prices check [--provider P]…` now writes a
  self-contained `TASK.md` (under `~/.orchestra/prices/check-<stamp>/`) for a cheap agent with web access: each
  provider's official page and the model keys of the table that belong to it (the new `price_provider`: Claude
  families, `gpt-*`, `deepseek-*`), the rules (official site only, never guess, a promotion goes to `notes`) and the
  JSON schema of the answer. `orch prices diff FILE` reads the proposal from a JSON file or from the fenced `json`
  block of a report, validates it (known provider, the provider's own model keys, rates that are numbers >= 0, no
  future date; exit 2 otherwise) and prints `field: current → proposed (±N%)`, with a mark from 25%, the unchanged
  models, the models the proposal leaves out, new keys (reported, never applied) and the notes. `orch prices apply
  FILE [--provider P]… [--model M]… --yes` writes the personal `prices.json` under the home lock: each changed model
  becomes a dated list (open-ended elements are closed at the check date, DeepSeek's peak fields are kept), and
  each checked provider's source gets `as_of`, `source` and `models`, a check with no changes included (a provider
  whose change `--model` left out keeps its date); without `--yes` nothing is written. `orch prices show [--json]` prints the table in effect with source, date, age and
  origin, and flags a provider older than 30 days. Nothing happens by itself and `orch` makes no web request.
- **A newer plugin wins over an old check.** A personal source written by `apply` (it has a `models` list) that is
  older than the built-in source of the same provider is ignored together with its model entries, so the built-in
  prices of a newer plugin replace it; entries written by hand always override, as before. The staleness warning of
  `orch spend` now says "run `orch prices check`".
- **A Claude or DeepSeek executor can read a web page when granted.** An allowed `WebFetch(...)` rule given with `orch
  run … --allow` also adds the `WebFetch` tool to the worker's tool list, in analysis and write mode; without such a
  rule the tool stays out.
- **`orch.cmd` without warnings under the Python install manager.** Since 0.31.1 `bin/orch` starts with `#!/bin/sh`,
  and the install manager's `py` and `python` (python.org's default Windows installer) read a script's first line:
  `py -3 bin\orch` printed three warnings on every call before falling back to the default Python. `orch.cmd` now
  starts Python with `-c` and runs `bin\orch` through `runpy`, so there is no script argument to read. The self-test
  likewise prefers a real interpreter to a `WindowsApps` alias, as the hooks do.

## 0.31.2

- **A stale status line reading no longer lowers the shared Claude usage.** Usage never goes down within one limit
  window, but a session that comes back after a quiet spell refreshes its status line before its first new response
  and writes its own old, lower figure with a fresh time, and the last writer won: on one machine with several
  sessions the weekly history had 21 drops (one 40 → 28) and the five-hour history 17, so the pace projections were
  computed from wrong numbers. `save_usage` now drops a status line reading of a window that has already reset, and
  one lower than the stored status line reading of the same window (the same reset within 10 minutes, not yet
  passed): the stored `used`, `resets_at` and `updated` stay and no history sample is added; when every window of an
  update is dropped nothing is written. A new window and an equal or higher reading are saved as before. `orch budget
  set` always wins, as a correction, and the next status line reading replaces the operator's estimate.
- **The Claude and DeepSeek executors find `claude` where its native installer puts it.** They looked only at
  `ORCH_CLAUDE_BIN` and PATH, so `orch run claude` from a session whose shell lacks the user's own PATH entries (seen
  in Git Bash, with a hand-started DeepSeek lead) failed with "claude CLI not found"; `~/.local/bin/claude`
  (`claude.exe` on Windows) is now the last place they look.

## 0.31.1

- **`orch` from the plugin's own `bin/` finds its Python.** Claude Code puts the plugin's `bin/` on the Bash tool's
  PATH, and `bin/orch` began with `#!/usr/bin/env python3`: in a shell without `python3` (on Windows often only
  `python`, or a disabled Store alias) every `orch` call of the session failed with `/usr/bin/env: 'python3': No such
  file or directory`, while hooks and the status line, which find Python their own way, kept working. `bin/orch` now
  starts as a shell script that searches like `hooks/run.sh` (a real `python3`, `python` or `py` before a Store alias,
  version 3.8+) and shares its per-platform cache (`~/.orchestra/.hook-python-<platform>`), so a call starts a single
  interpreter; to Python the shell part is a string, so `python bin/orch` and the installed launchers run as before.
  No Python at all → exit 127 with a message. The skill's fallback is now `sh ${CLAUDE_PLUGIN_ROOT}/bin/orch`.

## 0.31.0

- **A session started by hand on another provider's endpoint is a lead, like `orch launch`.** A Claude Code session
  whose own `ANTHROPIC_BASE_URL` points at an endpoint an adapter declares (`# orch-endpoint:` — DeepSeek's
  Anthropic-compatible API) and whose `ORCH_LEAD` is unset is now detected on the first `orch` process of every
  command, hooks and the status line included: the endpoint is compared normalised, the token
  (`ANTHROPIC_AUTH_TOKEN`, else `ANTHROPIC_API_KEY`) against the profiles' key variables, and `ORCH_LEAD`,
  `ORCH_LEAD_MODEL`, `ORCH_LEAD_ENV` and `ORCH_LEAD_VIA=detected` are set, so routing, the Claude lane (`orch key`
  refuses), the worker environment and the status line behave as under `orch launch`. Anthropic's own API and other
  proxies are not a lead, and with no `ANTHROPIC_BASE_URL` nothing is read. The Lead line says
  `(detected: ANTHROPIC_BASE_URL)`; when the token is none of the profile keys it names the bare provider and notes
  that the session's spend is not under a profile's limit. A detected lead has already started, so SessionStart
  prints the spend warning instead of refusing.
- **A lead's own thread is billed to its account.** Session token counters now attribute the transcript of a lead
  session (its main thread and its `orch-*` subagents) to the lead's profile label, `DeepSeek@work`, not the bare
  provider — for a detected lead and for `orch launch` alike, closing the gap where the lead's thread was counted
  as a plain account.
- **`orch run claude` refuses when the user settings it reloads would take it off Claude.** The Claude executor
  loads the user settings of its config dir (`--setting-sources user`); if their `env` points `ANTHROPIC_BASE_URL` at
  another provider's lead endpoint (an adapter's `# orch-endpoint:`; a gateway to Claude is fine) or sets
  `ANTHROPIC_MODEL` to a non-Claude model, the worker would never reach Claude, so it fails before starting
  with exit 1 and a `STATUS: BLOCKED` report naming the setting and the file, instead of silently running on
  another provider.
- `reference/lead.md` and the README's DeepSeek-lead section describe detection, how the account is chosen, and the
  user-settings caveat.

## 0.30.0

- **A read-only command leaves an unused folder untouched.** In a folder where the plugin had never been used,
  `orch status` (its project lock and event check) and `orch handoff list` (the handoff scan) created `.orchestra/` —
  and with it the `.orchestra/` line in `.git/info/exclude` — though the README promises such projects "get
  nothing"; `profile show`, `guide` and `doctor` already created nothing. State is now created only by a command
  that writes it (`handoff new`, `offer`, `take`, `worktree add`, `run`, `launch`): a read in a folder with no
  `.orchestra/` skips the project lock and returns its default, and `orch status` skips the event check there. The
  status line and the hooks keep checking for state and still create none. `orch footprint` also names a project's
  paths relative to it instead of printing the folder twice.
- **`orch usage` outside a session is a report, not an error.** With no `CLAUDE_CODE_SESSION_ID` (a plain terminal)
  and no data it now exits 0 and says usage is collected per Claude Code session, naming `orch usage --list` and
  `orch usage --session <id>`. Records made with no session at all — a manual task closed from a terminal, an
  `orch run` outside a session — used to be unreachable: `--list` now ends with one `(outside a session)` row, and
  `--session none` shows them in the usual format (a pseudo-session in `--json`). Both READMEs and
  `reference/usage.md` say so.
- **The manual-lane cards match the commands they name.** The pool card's slash form is now
  `/orchestra:manual <id> to Antigravity`, the form `commands/manual.md` documents in its `argument-hint` (the
  board's take line too), and the card also gives the terminal form `orch handoff take <id>`; the take card adds
  that from a terminal `orch handoff check` picks completion up (in a session the hooks do). The README's clipboard
  claim now says it holds with `--clip`, which `/orchestra:manual` passes. The board no longer loses its history: a
  closed task is archived, so filtering archived tasks emptied "Recently finished" right after `close`; it is now
  built from all tasks, up to the last ten; `reference/manual.md` says what `close` still does.
- **The portability guard tells a generic key from a private name, and says where a name came from.** A key variable
  built as a standard key name plus one of the guard's generic labels (`CODEX_API_KEY_WORK`: `work`, like `client`
  or `personal`) is no longer flagged; a bound folder's name still is. Every finding now names its source (`a private name: proj (a folder
  bound in profiles.json)`), and `CONTRIBUTING.md` explains `~/.orchestra/private_terms.txt`.
- **`install.sh` and `uninstall.sh` print Windows paths on Windows** (`cygpath -w`), as `orch doctor` does;
  `uninstall.sh` closes by saying that the clone folder and any PATH line the user added (`~/.bashrc`, the user PATH
  on Windows) are theirs to remove.
- **The README quick start reads as a quick start.** The internal detail — the 20-minute projection window, atomic
  writes and locks, `--force` and manual capacity, `wait --any`, `STATUS: BLOCKED`/`PARTIAL`, exit 75 for capacity,
  the Windows sandbox note — moved to the plugin README; the root README keeps the plugin, routing, budget mode,
  a DeepSeek-led session and the requirements. The commented API-key profiles line is now a labelled example where
  profiles are introduced: `work` is a free label, the key lives in `~/.orchestra/secrets.env` as
  `CODEX_API_KEY_WORK=…` and never in the command, `profile use` binds it to the current project, and none of it is
  needed with the usual ChatGPT login. The command table links to the full eight commands, and the no-clone install
  line uses the documented `claude plugin install orchestra --marketplace orwrkr/orchestra`.
- **`CONTRIBUTING.md` warns about the native Windows suite:** it takes half an hour or more in Git Bash — use WSL or CI
  and keep a local Windows run for a Windows-specific failure.

## 0.29.1

- **A fallback move no longer leaves state behind for a dead session.** A per-session fallback entry was removed only
  when that same session saw its provider return, so a session that ended while its provider was on a fallback left
  its entry in `spend_events.json` forever, and every hook call read it. A per-session entry now records its session
  and time, is dropped when that session ends (`session-end`), and expires after seven days like a session budget
  baseline, which now shares the same constant; the move-once comparison still looks only at the profile names, and a
  project-wide entry is unchanged.

## 0.29.0

- **The session line gives each account its own line.** Since 0.27.0 every account's counter carried its cache reads,
  so a session with a subscription login and several API accounts produced one long line
  (`Session in/out: Claude 1.2M/180k +40M cache · DeepSeek@personal 805k/242k +28M cache (est. $3.81/$12.16,
  account $6.84) · Codex 224k/19k +4.8M cache`) that the terminal wrapped at arbitrary places. The first account now
  stands on the `Session in/out:` heading line and each further one follows on its own line, indented by two spaces; a
  scope with money but no tokens in this session gets such a line too, and a session with no tokens at all has no
  heading and starts with its first item. The order of the accounts, the filtering and each account's text are
  unchanged, the spend estimate still in parentheses on its account's line.

## 0.28.0

- **`orch` compiles once and reuses the bytecode.** Python never caches the bytecode of the script it is started
  with, so every hook and every status line update compiled all of `bin/orch` (7700 lines): 0.14 s of a hook's
  ~0.4 s on a calm Windows machine. The code now lives in `lib/orch_core.py`, and `bin/orch` is a short launcher
  that keeps the compiled code under `~/.orchestra/.pycache/orch_core.<cache tag>.bin`, keyed by a hash of the
  source and `sys.version`. An edited source or another interpreter compiles again; a missing, corrupt or unwritable
  cache only means compiling as before, and `python -B` writes nothing. The code still runs in the launcher's own
  namespace, so loading `bin/orch` as a module yields the real functions and the tests' patches reach them unchanged.

## 0.27.0

- **The session line shows cache reads too.** After the input/output pair comes the account's cache reads:
  `Session in/out: Claude 370k/111k · DeepSeek@personal 805k/242k +28M cache (est. $3.81/$12.16, account $6.84) ·
  Codex 224k/19k`, left out for an account whose cache reads are zero, with the spend text in parentheses where it
  was. The transcript side takes `cache_read_input_tokens` through `claude_tokens`, like `orch usage`, and the run
  records their `cached_input_tokens`, so the figures agree with that report's `cache` column. A project that
  budgets tasks in tokens of all kinds warned at 34.1 million while the line showed hundreds of thousands: the same
  five runs had 1.03M input, 261k output and 32.8M cache reads. The saved entry format is 3, so an older entry is
  rebuilt from the start: its ledger part and also its transcript files, whose totals have no cache; a long
  transcript catches up over a few updates, and until then the counters may show less.
- **`orch usage` survives a ledger line that isn't an object.** A stray JSON value in `usage.jsonl`, such as a list,
  made the report fail with `AttributeError`; such a line is now skipped, as a malformed one already was.
- **A timing check no longer races slower runs.** The test of a capacity block's ten minutes now reads the block
  right after the run that set it, not after four more runs, which on a loaded machine took over a minute.

## 0.26.0

- **Hooks and the status line stop paying for the Microsoft Store `python3` alias.** In Git Bash `command -v python3`
  often finds the Store's app execution alias, which redirects to the real interpreter at about 0.2 s a start, and
  `hooks/run.sh` started it twice per hook (a version check, then `exec`). The interpreter that passed the check is
  now cached in `~/.orchestra/.hook-python-<platform>` (one line, `sys.executable`; per platform, since WSL and Git
  Bash may share the folder) and the usual hook run is one start of that
  path; a fresh check skips a `…/WindowsApps/` alias while a real candidate passes and takes one only as the last
  resort. `install.sh` writes the same absolute path into the Git Bash launcher (`~/.local/bin/orch`) instead of the
  bare command name, so every `orch` call, the status line included, saves the redirect; re-running `bash install.sh`
  refreshes it, also after installing or upgrading Python. `orch doctor` warns about an old launcher that still runs
  the alias, or one naming an interpreter that is gone.
- **`orch hook <event>` no longer builds the command-line parser.** `main()` recognises the hook command and its event
  (and `--throttle`) directly, as it already does for the status line, so the 46 subparsers (about 0.07 s) are not
  built on every user message and tool call; unknown input, errors and `--help` still take the full parser.

## 0.25.0

- **The weekly pace is measured over three days, not one.** The projection of the week's limit takes its recent pace
  from the earliest sample of the last 72 hours with the same reset and at least 6 hours before the measurement (the
  history now keeps 80 hours, capped at 400 samples), so a single heavy or light day no longer swings it; a burst
  still shows in the five-hour window. Longer bases read `the last 2d 12h`.
- **A personal or project registry copy that went stale is named.** `orch registry init` writes the plugin version
  and the built-in registry's hash into the copy. When the built-in one changes afterwards, SessionStart and
  `orch doctor` warn that the copy is stale; `orch registry diff` shows what it changes against the built-in one, and
  `orch registry diff --accept` records the built-in one as current once what is needed has been taken over.

## 0.24.0

- **Flash is DeepSeek's default model, and Pro is taken only when it is known to be needed.** Flash is newer, ahead
  on coding and agentic work and several times cheaper, so the adapter's default, the lead and every DeepSeek route
  are Flash. Pro keeps a slot each for a second opinion when Flash failed or its answer is in doubt, and for the
  hardest knowledge-heavy reasoning. `deepseek/flash-high` now reaches difficulty 4, and a new `deepseek/flash-max`
  covers hard debugging, cross-module changes and an architecture critic.

## 0.23.0

- **A model at capacity is not a used-up limit.** The run ends `[CAPACITY]`, still exit 75, and the entry on that model
  alone is the new status `busy` for about ten minutes; it never moves a profile to its fallback. The report says that
  whatever the run already changed stays in its folder.
- **Only Codex's real messages decide what a failure was.** Its own tracing lines (a timestamp, then `ERROR`) were read
  as errors: a skill folder or a file named like `quota` turned any failed run into a recorded limit, and the limit
  message showed startup noise instead of the reason. They now count only when nothing else explains the failure.
- **A git-ignored `CLAUDE.md` or `AGENTS.md` reaches a worker in a worktree.** It comes from the project folder, also
  for Codex, which can't read it there itself; its `@` imports resolve on the branch first. A tracked file missing on
  the branch stays missing.
- **`orch handoff hold <id>`** keeps a pooled task out of the pool checks while the operator means to take it later
  (`--until WHEN`, `--off`). A take or a reclaim ends the hold.

## 0.22.0

- **Session budgets for accounts with a balance API.** Profile fields `session_soft`, `session_hard` and
  `balance_floor` move a project to its fallback as the account falls from its session baseline. Claude TIGHT
  suspends only the soft threshold; top-ups reset the baseline, and hooks announce moves both ways with figures.
  Budgeted runs require a fresh balance and refuse with exit 75 `SESSION_BUDGET` on a failed read or a hard stop,
  including with `--force` or explicit `--profile`. Status and profile show expose the account changes; the status
  line remains read-only for this budget. The existing spend limit continues independently.
- **An `@` import reaches a worker in a worktree.** A worktree holds no git-ignored files, so an import of one, such
  as notes on the machine's environment, stayed a dead line. It now comes from the project folder.
- **What a read ban covers, in the settings guide.** Only what its rules name, and only for DeepSeek and Claude
  executors. A secret committed to the repository is the project's to replace and remove, not something a ban fixes;
  until then, a reminder in the project rules warns every session.

## 0.21.0

- **Project rules survive a key change.** `orch profile rules --set "TEXT"` records private directory requirements
  for the orchestrator, shown with profiles in status and SessionStart. Parent and project rules all apply; `--path`
  selects a directory and `--clear` removes its entry. A fallback also reports when the configured key's rules lapse.

## 0.20.2

Fixes from an independent review of 0.19.1 to 0.20.1.

- **Something at a worktree's path must really be that worktree.** `make_worktree` accepted any existing path. Inside a
  plain folder under the project git answers for the project around it, so with `.orchestra/wt/<id>` a leftover folder
  would have let a writing task's review and commit land on the project's own branch. Now a path is reused only if it is
  the root of a worktree of this repository, on the expected branch; otherwise `handoff take`, `handoff new` and
  `orch worktree add` refuse and say why. `orch worktree add` on an existing worktree reports its real branch.
- **A failure after the worktree was made leaves it on record.** A task whose preparation failed later (the Antigravity
  rule can't be written, for one) had no `workdir` or `branch`, so nothing could find its worktree. Now a task back in the
  pool reuses it at the next take, and a failed `handoff new` says how to remove it: `orch handoff close <id>
  --remove-worktree`.
- **The status line joins money to its account by label, not by display name.** Two accounts that display alike could get
  each other's figures. The match is on the lowercase label, the key the run ledger uses.

## 0.20.1

- **`orch` on PATH, said where a new user looks.** `install.sh` now prints the PATH advice last, after the doctor
  table and the pointers (only when `~/.local/bin` is really off PATH), with `source ~/.bashrc` or a new terminal and,
  on Windows, the PowerShell line. The root README's Quick start has the same under "If `orch` isn't found", worded
  as conditional, and the plugin README points to it. The doctor row `orch on PATH` no longer tells you to re-run
  `install.sh` when the launcher already exists: it says the folder is off PATH.
- **No false alarms about Codex.** `install.sh` grepped for `Codex CLI` in the wrong case and warned that Codex was
  missing on every machine; fixed, and the DeepSeek profile pattern had the same mismatch. The `Codex CLI` row of
  `orch doctor` is optional (`·`, no exit 1), as the README says. The self-test checks that the patterns `install.sh`
  greps for occur in doctor's output.
- **What to do after installing.** The Quick start names Claude Code among the requirements, says what to run next
  (`claude`, `/orchestra:status`, `claude plugin list`) and how to read `✔`, `·` and `✘` in `orch doctor`.
- **The Antigravity rule no longer contradicts a writing task**: outside the task's RESULT.md it allows the task's
  own worktree under `.orchestra/`.

## 0.20.0

- **The agent's window stays on the project folder.** The operator keeps one folder open in the agent and never
  switches it, the way they work with Claude Code. A read-only task works right there; a task that changes files works
  in a git worktree that `orch` makes **inside** the project folder, so nothing needs opening.
- **Read-only by default, `--write` for a task that changes files.** `offer` and `new` take `--write`, stored as
  `write` in the meta; an old meta without the field counts as writing, since it made no promise. A read-only task
  may write only its RESULT.md and is told to run no shell commands (each can stop and wait for the operator's
  confirmation).
- **`--write` means a worktree of its own**: `<project>/.orchestra/wt/<id>` on branch `ag/<id>`, made at the take (or
  at `new`) and git-ignored with `.orchestra/`. `--base <ref>` picks its start and goes only with `--write`; without
  it, a clear error. `--worktree` is gone and fails with a line naming `--write`. Several writing tasks may be open at
  once and the project folder may be dirty. `--write` needs a git repository and is refused at `offer` and `new`
  outside one (an old offer that counts as writing is not taken there); read-only tasks work anywhere, nothing
  needs git. `make_worktree` takes a root; `orch worktree` for automated executors keeps `<project>.wt/`.
- **TASK.md and RESULT.md stay in the project's `.orchestra/handoffs/<id>/`** for both kinds, so the agent finds them
  the same way; `task_path` and `result_path` point there, `workdir` is the worktree. The writing protocol says to work
  only inside the worktree (never its same-named original at the project root), to install dependencies without
  copying secrets, and not to commit or switch branches: the orchestrator reviews the changes in the worktree and
  commits them (this keeps the agent's shell commands, and so its confirmation prompts, to a minimum).
- **The paste line is one line**, for the clipboard too. A read-only task's says to run no shell commands unless the
  task lists them; a writing task's names its worktree. Both say that if the agent's file tools cannot open
  `.orchestra/` because git ignores it, it should say so in the chat and stop instead of reaching it through the
  terminal.
- **One general Antigravity rule** instead of one per task: `.agents/rules/orchestra-task.md` in the project folder,
  written at each Antigravity assignment when absent or different and excluded through `.git/info/exclude`. It applies
  only when a message names a task id, so several open tasks do not mislead each other, and it tells a writing task to
  stay in its worktree. It stays after a task closes; `orch footprint`, `uninstall.sh` and the README name it among
  what the plugin leaves behind, with `git worktree prune` for the case of `.orchestra/` deleted by hand.
- **A start is detected from RESULT.md only** for a read-only task: it works in the shared project folder, where a
  changed file says nothing about the agent, so it stays `WAITING` until RESULT.md appears and never shows `STARTED?`
  from someone else's edit. A task with a worktree of its own keeps the folder scan and `STARTED?`.
- Tasks taken by an older version, with their worktree next to the project in `<project>.wt/`, keep working (card,
  `check`, `done`); `close --remove-worktree` is now the normal end of a writing task. The card says
  `In Antigravity, in the project folder: <path>` and, for a writing task, `It works in: .orchestra/wt/<id> (its own
  worktree, branch ag/<id>); no need to open it`; the pool card says `(changes files, in its own worktree)`;
  `.orchestra/MANUAL.md` follows.

## 0.19.1

- **The status line says each name once**: the money of an API-billed scope joins the token counter of the same
  displayed name, in parentheses, instead of repeating the name after a `·` and sitting under the "Session" heading
  (the money is not the session's): `Session in/out: Claude 6.7M/1.2M · DeepSeek@personal 1.5M/988k (est. $0.99/$12,
  account $9.73)`. A scope with money but no tokens in this session follows the counters
  (`DeepSeek@client (est. $1.47/$10, account $15.09)`), and with no session tokens at all the line is only that, with
  no `Session in/out:` heading. The age of the account figure goes inside the same parentheses
  (`, 3h ago`), the limit off leaves `(est. $1.47, account $15.09)`, no balance yet leaves `(est. $0.99/$12)`, and a
  fallback is the first item inside them: `(fallback: DeepSeek@client at its limit; est. $0.99/$12, account $9.73)`.
  `orch status` and `orch spend` keep their formats.

## 0.19.0

- **The provider's balance of the account**: `orch balance` asks the provider how much the account behind a key has
  left, with that key, for every profile that has a `key` and for DeepSeek's built-in `DEEPSEEK_API_KEY`
  (`GET /user/balance`; `--json`; `--quiet`). Only what an ordinary key can read counts, so only DeepSeek has it.
  OpenAI, Anthropic and Google offer a key no balance (OpenAI and Anthropic keep billing and cost reports behind admin
  keys; the Gemini API and Vertex AI have none), and `orch balance` says so for those: "no balance API: see `orch
  spend`". Another provider is one fetch function and one table entry (`BALANCE_PROVIDERS`).
- **It is the account's figure, not the key's**: all keys of a DeepSeek account share one balance, and the account can
  be spent from outside `orch` (other tools, other people). So it is worded as the account's balance everywhere
  (`account`), two keys of one account show the same figure, and it is never presented as comparable with one key's
  estimate: a drop in the account balance says nothing about one key's spend. Spend limits stay hand-set budgets for
  `orch`'s own runs; what actually stops an empty account is the provider's refusal (402), which moves a project with a
  `fallback` to that profile.
- **The status always shows both kinds of data**, not only from 80%: for every API-billed scope active in the
  directory (a fallback included), the status line has our estimate and limit and, where a balance was fetched, the
  provider's figure: `DeepSeek@client est. $1.47/$10 · account $15.09`, with `(3h ago)` once the figure is older than
  30 minutes; `est. $1.47` alone when the limit is `off`; only our part before a balance was ever fetched or for a
  provider with no balance API; a limit that is not whole shows as it is (`$12.16`). The built-in DeepSeek profile
  stays silent until it has a key, some spend or a balance. `orch status` has a line for each such scope, balance or
  not, under a heading saying where each number comes from (spend and limit: our estimate of `orch`'s own runs;
  account: the provider's figure, for all keys of that account), with the age of the figure, `no balance API`, or the
  last failed fetch. `orch spend` has an `account` column and a header that says `spent` is our estimate of `orch`'s
  runs and `account` can include spending outside `orch`. The warning at 80% (`API spend:` in `orch status`) and the 💡
  events are unchanged. The currency is the one the provider reports (`$`, `¥` for CNY), never converted.
- **When it is fetched**: `orch balance` always; `orch status` and `orch spend show` when the figure is older than 10
  minutes; the end of every `orch run` for its scope; and SessionStart, which starts a detached `orch balance --quiet`
  instead of waiting. Every request has a 5-second timeout. A failure never fails a run, a status or a hook: the last
  amount stays in `~/.orchestra/balances.json` with the error beside it and shows as age. The status line only reads
  that file: no request, no process. `ORCH_BALANCE=off` turns every request off; `ORCH_DEEPSEEK_BALANCE_URL` points
  the DeepSeek request elsewhere (tests).
- The key is read the way a run reads it (environment, then `secrets.env`), sent only as the bearer token, and appears
  in no message, no `--json`, no cache. A rejected key (401) names its variable. Spend limits work as before.

## 0.18.4

- **No five-hour TIGHT from a few minutes of data**: a projection of the five-hour window now needs at least 60
  minutes of the window behind it, for Claude and for Codex. Seen for real: Claude "TIGHT" at 5% used, 30 minutes in,
  from one heavy step projected over hours (gone minutes later), and Codex "TIGHT" at 15% used a few minutes after its
  reset, because the average of a young window was scaled up to the whole five hours. Before the hour, a used share
  that has reached the reserve is still TIGHT at once; anything else shows no mode. SURPLUS reads the same pace, so it
  cannot appear in that first hour either.
- **The recent pace needs a longer baseline**: the Claude pace of all sessions is measured from a sample 30–60 minutes
  old (it was 15–60), so it covers at least 30 minutes.
- **A young week no longer blocks SURPLUS**: at week 5%, nine hours after a reset, "98% projected" held back SURPLUS
  while TIGHT already ignored that projection for its first 24 hours. Now neither uses it. A used share over the
  reserve still counts at once.

## 0.18.3

Fixes from the first CI run. No change in how the plugin behaves.

- The portability guard took CI's own placeholder e-mail for a local identity and flagged the workflow that sets it.
- The self-test compared paths under a Windows short name (`RUNNER~1`) with the long form `orch` reports.
- For contributors: the portability guard also stops private names, read at run time from `~/.orchestra`, and a new
  `pre-push` hook checks every commit a push would send, messages and annotated tags included.

## 0.18.2

- **SURPLUS and a project's own key**: with `prefer for` on the key profile active in the directory (say
  `deepseek@client`) and budget on that key, that provider goes first for those task types, ahead of Claude, also in a
  SURPLUS. The status line used to say `surplus: Claude first` there, and `orch status`, the `💡` event and the skill
  "give subtasks to Claude subagents rather than to API-billed executors". Now the status line says `surplus`, and the
  line and the event add ", except the task types preferred for DeepSeek@client (tests, docs)". When the key is
  exhausted, the profile's `fallback` takes over and the text is as before unless the fallback has a `prefer for`
  of its own. With no such profile nothing changes. `SKILL.md` section 1 and `reference/budget.md` say the same.
- **A fallback shows on the status line**: while a provider's active profile is a fallback, the spend part of the
  status line says `DeepSeek@personal (fallback: DeepSeek@client at its limit)` (or `exhausted`, `disabled`), whatever
  the fallback's own spend is; its `$spent/$limit` follows from 80%. With no session tokens yet the note stands on a
  line of its own. Before, the exhausted key's `$10.50/$10` just vanished from the line.
- **Codex's model**: the status line named `codex-auto-review`, the model of Codex's internal auto-review step, which
  also writes `turn_context` events. It is ignored: the last real model of the tail is shown, else just `Codex`. An
  entry that older versions saved with that model counts as no model, and a re-scan drops it.

## 0.18.1

- **A fast status line**: it went blank in busy sessions although the command works, because Claude Code runs it on
  every update and a slow run gets replaced by the next one. A run now starts no process, rewrites no large file and
  loads only what it needs.
- **No `git`**: the project root comes from looking upward for `.git` (a folder, or a file in a linked worktree or a
  submodule), for every command, so the status line and `orch run` always agree on a project's profiles. Only
  `--then`, the operator's own command, still starts a process.
- **One small file per session**: `~/.orchestra/session_tokens/<session>.json` replaces the shared
  `session_tokens.json`, so a refresh leaves other sessions' data alone. It is saved at most once per 30 seconds; in
  between a refresh parses from the saved offset and shows the result without saving it. A backlog over 8 MB (a long
  transcript seen for the first time) is parsed in steps, each saved at once, so runs that get killed still get
  through it. A running session continues from its entry in the old file, which goes once it is a day old.
- **Bounded ids**: a file keeps the ids of its newest 100 messages, none once it has not grown for 10 minutes. In this
  project's transcripts every one of 1956 re-sent lines was adjacent to its first copy, at most 87 seconds later. A
  copy that comes after its id was dropped is recognized by its timestamp, older than the newest id dropped (or that
  very message) and is skipped. A copy with a new timestamp would count again; none was seen.
- **Imports**: `argparse`, `shutil`, `subprocess`, `tempfile`, `platform`, `random`, `shlex`, `signal` and others are
  imported where they are used, and a plain `orch statusline` does not build the argument parser. `write_json` no
  longer needs `tempfile`.
- **A busy lock costs nothing**: the status line does not wait for a lock, and prints what is cached. Readers of
  `~/.orchestra` state take no lock unless a file is corrupt. A part that fails costs only that part, not the whole
  line. Each file is opened once per run until it is written or a lock is taken.
- **The Codex scan keeps to its throttle**: a scan that found nothing, or a run killed mid-scan, made the next update
  scan the rollouts again. Now the start of a scan is recorded, which also limits all sessions together to one scan a
  minute per account, and the scan runs outside the lock.
- `*.tmp` files left by killed writes and the files of quiet sessions go after a day.

## 0.18.0

- **A fallback profile**: `orch profile set <provider> <name> --fallback <profile>` (`--fallback none` clears it). While
  the profile is exhausted, every place that resolves a provider's profile for a directory gets the fallback instead:
  its key, models, limits, `use_for`, `prefer_for` and `rules`. So a project's priorities, which exist only to spend
  that project's key, disappear with the key and return with it, with no command and no reading of `rules` by the
  session. Runs, `orch status`, `orch profile show`, SessionStart, the spend scopes and the ledger's `label` all follow,
  because they all resolve the profile. Before, this was a paragraph in `rules` plus `--profile` on each run, and a
  run on an empty key just got exit 75.
  - *Exhausted* means the profile's spend scope is at its limit under mode `stop` or `evaluate` (`continue` never
    is), or an availability entry on the profile's own key (`deepseek@work`) is `exhausted` or `disabled`, such as the
    one `orch run` records when a provider reports an empty balance (402). `low`, an entry on the whole provider or on
    one model, a rate limit (the timed entry `orch run` records on a 429), and an unreadable `spend_limits.json` or
    `profiles.json` are not exhaustion: the project stays on its profile and the run refuses as before.
  - A Claude session's own thread keeps billing to the key in its `apiKeyHelper`, which names the bound profile, so
    its status and token counter stay on that account while `orch run claude` moves to the fallback.
  - The target must be another profile of the same provider (or the built-in `default`); one level only, a target's
    own `fallback` is not followed; a target deleted later means no fallback, and `orch profile show` says so.
  - `--profile <name>` on a run is the operator's direct request and bypasses it: an exhausted profile still refuses
    (exit 75), and the refusal says which fallback takes over without the flag. A session-wide choice
    (`ORCH_PROFILES`, `orch launch --use`) follows the fallback like a binding.
  - `orch profile show` and `orch status` print `personal (fallback: client is at its limit)` while it applies, and the
    configured profile shows `fallback: personal` when it does not. A 💡 event fires once when a project moves to its
    fallback and once when it returns.


## 0.17.0

- **The status line counts tokens per account**: `Session in/out:` keyed each run by its provider, so `DeepSeek@client`
  and `DeepSeek@personal` came out as one `DeepSeek` figure. It now has one counter per profile label (`Codex`,
  `Codex@work`, `DeepSeek@client`, a subscription login next to API keys), for every provider, never a sum over a
  provider's accounts. A run record without a label falls back to its provider. The session's own Claude thread counts
  under its key profile's label when it bills to a key, else as `Claude`, together with `orch run claude` on the same
  default login. Within a provider the plain account comes first, then the labels alphabetically. The cache
  `session_tokens.json` marks the new format: an entry without the mark restarts its ledger part from the start, so
  old sessions get correct labels, and malformed cache entries or ledger lines no longer blank the line. `orch usage`
  and the ledger format are unchanged.
- **Executors are told not to wrap commands**: the executor role says to run an allowed command on its own, without
  `cd`, `&&`, `;` or pipes around it. A permission rule such as `Bash(node scripts/test.mjs:*)` does not match
  `cd <dir> && node scripts/test.mjs; echo $?`, so an executor that wrapped its test run was denied and ended PARTIAL.
  The line is general; Codex runs under its own sandbox and has no such rules, so for it the line is only harmless.

## 0.16.0

- **Subscriptions before API keys**: among the slots that suit a task, the orchestrator now takes subscription slots
  before API-billed ones (DeepSeek, any profile with a key), since what stays unused at a reset is lost and a balance
  is money. A subscription that is TIGHT or low goes after them. Before, the cheapest slot won whatever its billing, so
  DeepSeek could take work while a subscription had plenty left. Suitability still comes first, and `prefer for` and
  required cross-review outrank this order. In a SURPLUS, Claude also goes ahead of Codex on a tie.

## 0.15.1

- **A flat day no longer trips the weekly TIGHT alarm**: once the last-changed sample ages out of the 24-hour recent
  window, the weekly projection fell back to the week's average — so after an idle day a 70%-used week with the reset
  two days away projected ~98% and went TIGHT again, the exact false alarm 0.14.0 removed. When no sample qualifies,
  `week_base_sample` now takes the newest older sample with the same reset: if its `used` equals the current one, the
  recent pace is zero and the basis reads `the last 24 h` instead of the week's average.
- **`worker_env` no longer drops declared keys while leaking others**: a declared secret that isn't
  `# orch-secrets-explicit` again takes its value from the real environment ("real environment wins"), so an adapter
  declaring `# orch-secrets: OPENAI_API_KEY` with the key only in the shell keeps it. Every variable named as some
  profile's `key` and every `ANTHROPIC_*` ending in `_API_KEY` or `_AUTH_TOKEN` is now dropped from every worker
  unless this run's profile or adapter supplies that name. A Claude worker on a login profile therefore no longer sees
  `ANTHROPIC_AUTH_TOKEN` — someone authenticating through a gateway needs a profile key.
- **A BOM no longer silently drops a project's deny rules**: `settings_deny` reads with `utf-8-sig` (PowerShell 5
  writes such files), and when a settings file exists but can't be parsed the worker names it instead of continuing as
  if there were no deny rules.
- **A transient read error on `spend_limits.json` no longer refuses a run**: `load_spend_limits` retries a
  `PermissionError` the way `_read_json` already did (they share the same helper), so a parallel `orch spend` or
  `ensure_baseline` no longer fails another run or a Claude key fetch on Windows.
- **`orch spend limit <provider>@default` is refused** unless a profile named `default` really exists; the built-in
  profile's label is just the provider, so the limit used to add a second row that silently did nothing.
- **A `.orchestra` symlink no longer breaks handoff paths**: `meta_base` uses path arithmetic instead of `.resolve()`,
  so it still maps `meta.json` to the project (not the symlink target), and `all_metas` computes the base once per
  load instead of resolving every file.
- **The surplus gate uses the effective weekly reserve**, so a 95% weekly projection close to the reset no longer
  blocks surplus mode that is about to expire.
- **A corrupt usage file no longer loses a run's ledger line**: the post-run usage read and cost are guarded — a
  corrupt `usage_live.json` or bad price data keeps whatever tokens were read, prices them at 0, and notes
  "cost not priced" on the run's output line instead of raising before `ledger_append`. A `Ctrl-C` during the mid-run
  spend poll now stops the run rather than escaping the handler.
- The settings guide now gives the full pair for budget thresholds (`orch profile set …` **and**
  `orch profile use …`), and its "what is not a setting" line says a worker receives only the key its own profile
  names.

## 0.15.0

- **A settings guide, so any project's session can discuss the plugin's settings** (`orch guide settings`): one
  place that says what can be configured, where it is stored and what it reaches, starting with the split between
  what is scoped to this project and what is personal (`~/.orchestra/`). It maps each topic — executor profiles,
  API keys, spend limits, subscription budgets, availability, the registry, the status line — to its command and
  points to the deeper guides instead of repeating them, and ends with how a project's own process takes precedence.
- **The `orchestrate` skill now loads for configuration and spend-limit questions**: its `description` names "how to
  configure the plugin" and "spend limits", the guide list includes `settings`, and the profiles section points
  setup questions to `orch guide settings`. The two places that still called a spend limit "monthly" now say what it
  is — a manual counter for a prepaid key, not a monthly one.
- **`/orchestra:profile` points broader setup questions at the settings guide**.
- The self-test covers the new guide: it is served as a topic, names `secrets.env` and `orch registry show`, and the
  skill's description names configuration.

## 0.14.0

- **The weekly TIGHT alarm no longer fires on a stale burst**: the weekly projection used to be the whole week's
  linear average, so yesterday's heavy use counted as if it were still going on, and the reserve was a flat 10% of
  the week right up to the reset. `orch` now keeps a `week_history` series (one sample per 15 minutes, kept 72 h)
  for both Claude and Codex and projects the week from the recent pace — the earliest sample from the last 24 h with
  the same reset and at least 6 h before the measurement — falling back to the window average while there is no such
  sample. The weekly reserve also shrinks with the time left to the reset (`reserve × remaining / week`, floored at
  1 point), so a nearly-finished week does not keep unused quota behind a now-pointless margin. The TIGHT line shows
  which basis the projection used and the effective reserve in place of the flat one (`reserve 2% (10% at the start
  of the week)`); the compact status line texts are unchanged. The five-hour window keeps its existing pace and flat
  reserve.

## 0.13.0

- **A broken `spend_limits.json` now refuses runs instead of letting them through**: a corrupt limits file made a
  manual scope look like it had spent nothing (its baseline was lost, so `current_spend` returned $0 and the run
  proceeded). `orch run`, `orch launch` and `orch key` now name the broken file and refuse when they cannot check
  the limit — fail-closed, like a broken `profiles.json`. Reads (`orch spend`) still show the defaults.
- **Interrupted and failed runs are logged, not dropped**: a run killed by a signal or `Ctrl-C` no longer exits
  without a ledger line — its partial usage is recorded (and its cost counted against the limit). The token usage of
  every run now prefers the adapter's `usage.json` and falls back to `usage_live.json`, so a failed run keeps the
  tokens it reported before failing instead of logging $0.
- **One spend count per lead session**: a `SessionEnd` snapshot is cumulative, and the same session could be logged
  more than once, so a lead's tokens were summed twice. The spend cache now keys session records by session id and
  keeps only the last snapshot (cache format 3, which also clears any previously double-counted totals).
- **A mid-run spend poll can no longer crash the run**: a half-written `usage_live.json` or an unreadable Codex
  rollout used to raise out of the poll loop, killing `orch run` without a ledger line. The poll now skips one round
  on a read error, the adapter writes `usage_live.json` atomically, and the process tree is reaped in a `finally`.
- **The operator's API key no longer leaks into workers**: `worker_env` now strips `ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN`, `CODEX_API_KEY` and `OPENAI_API_KEY`, so a login-profile worker can't silently switch to
  API billing on the operator's key. A profile's own key still reaches the worker through its declared secret.
- **`orch spend` scope handling**: scopes are lowercased (`orch spend limit DEEPSEEK 5` now means `deepseek`);
  `orch spend limit <provider>@<profile>` refuses a profile that doesn't exist; and `orch spend reset … --project`
  refuses a project that has no limit of its own instead of writing a baseline that would never be read.
- **`--profile` is honoured by every part of a run**: `orch run codex --profile work` now reads mid-run spend and
  refreshes the account limits from `work`'s `--home`, and the Claude consumer / API-billing checks use the resolved
  profile instead of re-resolving the default.
- **Limits reject `nan`/`inf`** instead of accepting a non-finite dollar amount.
- **The spend cache persists its byte offset** even when new ledger bytes contain no API-billed records, so it no
  longer re-reads them on every check.
- **Model names display correctly**: `deepseek-v4-pro[1m]` now shows as *DeepSeek V4 Pro*, and an unknown model
  version such as `claude-opus-6-0` stays as-is instead of collapsing to *Claude*.
- **Headless workers don't read secret files by accident**: the DeepSeek and Claude adapters deny `.env` and `.env.*`
  (`.env.example` too, since a deny outranks an allow; a tracked one reads with `git show HEAD:.env.example`) and
  Bash searches that print ignored files (`grep`, `rg`, `git grep --no-index`), and forward the target project's
  `permissions.deny` Read and Bash rules, which `--setting-sources user` would otherwise skip. Checked against the
  real CLI. It stops accidents, not intent: `cat .en*` still gets through, and Codex has no such rule.
- **Codex 401 wording matches the profile**: a 401 on a `codex login` account now says "log in again" instead of
  blaming an API key, and the auth detector no longer matches a bare `401` in unrelated output.

## 0.12.0

- **Manual tasks survive a moved project folder and a Windows↔WSL switch**: `meta.json` no longer stores
  absolute paths. `workdir`, `task_path` and `result_path` are written relative to the project root (forward
  slashes), and a worktree task keeps its `../Project.wt/<id>` sibling path; only a path with no relative form
  (a different drive on Windows, or one written by the other OS) stays absolute. In memory the same fields are
  still absolute native paths — one conversion on load and one on save — so the board, the handoff card and
  `orch handoff` output keep printing a full path for the current environment. The base is taken from where
  `meta.json` lives, so the same commands work from a subdirectory. Old metas with absolute paths still load;
  one under the current root becomes relative on the next save, one that isn't is left alone. `workdir_win` is
  no longer stored — it is derived from the resolved workdir for display.

## 0.11.0

- **One status line format for every provider**: Claude and Codex build their status-line part with the same
  `provider_line` helper — `name · 5h N% → HH:MM · week N% · [N session(s)] · mode · stale: age`. The compact mode
  text is identical on both (`tight: 5h`, `tight: week N% projected`, `tight: week over reserve`; Claude also
  `surplus: Claude first`), and both mark a measurement older than 20 minutes as `stale:`. The third line now reads
  `Session in/out:`.
- **Official names in all output**: ids are mapped to their display names (claude → Claude, codex → Codex,
  deepseek → DeepSeek, gemini → Gemini, antigravity → Antigravity, gpt-6.1-terra → GPT-6.1 Terra, deepseek-v4-pro →
  DeepSeek V4 Pro, …; unknown ids stay as-is) in the status line, `orch status` (including the profile table),
  the `orch run` header, `orch usage` tables and totals, `orch doctor`, spend surfaces and event/prose text. Raw
  ids are kept in suggested commands, `--json`, the ledger and profile/cache files. The Codex status line now names
  the model of the last `turn_context` event in the same rollout file that gave the limits (kept when it scrolls out
  of the tail).
- **Session count on the Claude line**: the Claude status line always shows `N session(s)` (including `1 session`),
  describing Claude Code sessions with this plugin active in the last 15 minutes. A headless `sdk-*` entrypoint
  no longer registers as a consumer.
- **`orch spend limit … --project PATH`** can set another project's own limit from a different directory; that
  project shows the limit while the current one keeps its default.

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
