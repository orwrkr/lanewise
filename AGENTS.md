# Partitura — plugin development

The repository is a Claude Code marketplace (`partitura`) with a single plugin `plugins/partitura/`: an orchestrator
that hands out subtasks to Claude subagents, Codex CLI, DeepSeek and manual agents (Antigravity and similar), and
can run with DeepSeek instead of Claude as the lead. These are the shared rules for any agent working on the
repository: Codex and Antigravity read this file themselves, Claude Code — via `CLAUDE.md` (`@AGENTS.md`), the
DeepSeek and Claude executors get it from `orch`.
Both environments are supported: WSL/Linux/macOS and native Windows (Bash there is Git Bash, Python is native
Windows); each has its own plugin installation (`bash install.sh`) and its own `~/.orchestra/`.

## Language

**English is the only language of all repository content**: code, comments, docstrings, CLI output, docs, prompts
and templates, test names and data, commit messages, PR and issue text. Conversations with the user in a session may
be in the user's language; whatever goes into the repository is English.

## Structure

- `plugins/partitura/bin/orch` — `orch` launcher: runs the parts below, with cached bytecode
- `plugins/partitura/lib/orch_core/NN-<area>.py` — CLI code by area (Python 3.8+, stdlib only). The parts run in
  name order in one namespace and must parse as one file when joined; code goes in its area's part
- `plugins/partitura/skills/orchestrate/SKILL.md` — core routing rules (loaded on every skill invocation — keep it
  compact); details — `skills/orchestrate/reference/*.md`, served by `orch guide <section>`
- `plugins/partitura/registry/providers.yaml` — built-in model registry; the personal one — `~/.orchestra/providers.yaml`
- `plugins/partitura/agents/orch-*.md` — executor subagents (model + effort)
- `plugins/partitura/commands/*.md` — `/partitura:*`
- `plugins/partitura/hooks/hooks.json` — SessionStart / UserPromptSubmit / PostToolUse / Stop / SessionEnd →
  `hooks/run.sh` → `orch hook <event>`
- `plugins/partitura/adapters/` — adapters for automated executors (Python: `codex` — `codex exec --json`;
  `deepseek` — headless Claude Code on the DeepSeek API, also the `orch launch deepseek` lead; `claude` — headless
  Claude Code on the user's own login; `_claude_headless.py` — shared by the last two; contract template)
- `plugins/partitura/bin/orch.cmd` — `orch` launcher for PowerShell/cmd on Windows
- `tests/run_tests.sh` — self-test (fake codex and claude, temporary git repository): preamble
  `lib.sh`, then `sections/NN-<slug>.sh`; `--list` names them, `run_tests.sh <sel>…` runs some alone
- `install.sh` / `uninstall.sh` — plugin install and uninstall (the standard way, via `claude plugin`)
- `.github/workflows/tests.yml` — CI: the self-test on Ubuntu and Windows, Python 3.8 compatibility
- `ROADMAP.md` — open work, marked product or process; `CONTRIBUTING.md` — how a change ships

## Before committing

```bash
wsl.exe -- bash -lc 'bash tests/run_tests.sh'   # must report failed: 0; from the repo root, default WSL distro
claude plugin validate ./plugins/partitura && claude plugin validate .
```
While working, run just the sections you touched (`run_tests.sh <slug>`); the full suite before a commit.
Git Bash on Windows is left to CI (`.github/workflows/tests.yml`): five minutes there, half an hour or more locally,
slowing every session on the machine; run it locally only to debug a Windows-specific failure.
Changed `orch` behaviour — add a check to its section in `tests/sections/`. Changed the registry format — update SKILL.md and README.

## Rules

- `orch` and the adapters — Python standard library only, compatible with 3.8 (`vermin -t=3.8- bin/orch
  lib/orch_core/*.py adapters/codex adapters/deepseek adapters/claude adapters/_claude_headless.py`).
- No machine-specific content: no absolute paths, user names, distro names or personal settings in code, docs,
  tests or commit messages (examples use `/path/to/…`, `<you>`; test data, the user `me`); the repository works from any
  location. `tests/check_portable.py` enforces this in the self-test and in the git hooks (`.githooks`); don't bypass it.
- No names of private projects or clients, in code, tests, docs, sample data, commit messages or tags, in any commit:
  this repository is public. Use a neutral label (`client`, `work`), also in specifications given to
  executors, which copy what they read. The guard reads the names at run time from `~/.orchestra` (`private_terms.txt`,
  this machine's profile names, key variables and bound folders), and its `pre-push` hook checks every commit a push
  would send; CI has no such list, so this holds only on a machine that has it.
- Cross-platform: paths — via `pathlib`, output — UTF-8 (`utf8_stdio`), shell adapters on Windows run through
  Git Bash (`find_bash`, not `System32\bash.exe` — that is WSL), the executor's process tree — a Job Object on
  Windows, a process group on POSIX.
- Line endings — LF only (`.gitattributes`), except `*.cmd` (CRLF); don't switch them in Windows editors.
- Executors are isolated from the orchestrator session: `orch` strips `CLAUDECODE`/`CLAUDE_*` and the variables of a
  non-Claude lead (`ORCH_LEAD_ENV`: its endpoint, token, models) from their environment and sets `ORCH_WORKER`; with
  it set, `orch run`/`orch handoff`/`orch launch` refuse and hooks stay silent. API keys — only in
  `~/.orchestra/secrets.env` and only for adapters that declare `# orch-secrets: …`. A non-Claude lead never gets
  the user's `ANTHROPIC_*` credentials.
- Project rules reach every executor exactly once: `orch` assembles CLAUDE.md (with `@` imports expanded) and
  AGENTS.md into `ORCH_CONTEXT_FILE`, minus the files the agent reads on its own (`# orch-context-native:`).
- Executor profiles (`~/.orchestra/profiles.json`, `orch profile …`): `off`, models, effort ceiling, write ban and
  `max_open` are enforced by `orch` itself (exit 75 `PROFILE_OFF`/`PROFILE_DENIED`); `use_for`/`prefer_for`/`rules` —
  by the orchestrator per SKILL.md, as are a directory's `project_rules`, which don't depend on the profile. A profile
  holds only the key's variable name, never the key itself. An unreadable
  `profiles.json` means refusing to run, not "no profiles". Profile fields for an adapter — the directive
  `# orch-profile-env: field=VARIABLE`. Session-wide choices: `ORCH_PROFILES=provider=profile,…`.
- Usage log `~/.orchestra/usage.jsonl`: runs (`usage.json` from the adapter), manual tasks, session snapshots
  (SessionEnd). Writing to the log never breaks a run.
- Read-modify-write of shared state must hold its interprocess lock, re-read and validate under the lock, and
  release it before slow external work; hooks and the status line use a short wait and skip busy updates silently.
- Hooks (`orch hook …`) never crash and never make noise: any error → a silent `exit 0`; output — only on an event.
- The status line runs on every update and may be killed by the next one, so it starts no subprocess and rewrites no
  large file.
- Adapters follow the contract from `adapters/_template.example` (env `ORCH_*`, exit 75 = limit, `usage.json`).
- **No programmatic interaction with Antigravity** (or other manual agents): don't launch `agy`, don't use
  computer use, don't paste text, don't touch OAuth — this violates Google's ToS (account ban). The manual lane is
  files in the project folder only: TASK.md and RESULT.md in `.orchestra/handoffs/<id>/`, the general rule
  `.agents/rules/orchestra-task.md`, and, for a task that changes files, its git worktree `.orchestra/wt/<id>`.
- Personal data (limits, the personal registry, profiles and project bindings, keys, usage log) lives in
  `~/.orchestra/`, not in the repository.
- Bump the version in `plugins/partitura/.claude-plugin/plugin.json` when behaviour changes: plugin installs from
  GitHub are cached by version.
- A version that reaches `main` gets a signed tag `vX.Y.Z` on its last commit, at the merge, once CI is green on its
  pull request (`.github/workflows/tests.yml`: the self-test on Ubuntu and Windows, vermin). A tag never moves: a fix
  that CI on `main` still calls for is a new patch version with its own tag, because installs are cached by version.
- Product before process: at most one process item of `ROADMAP.md` is in progress, and a new one starts only with the
  maintainer's go, its expected benefit and a cost limit.
- Commit finished work as new commits on top; amend or rewrite existing ones only for a concrete reason (a secret, a
  wrong author). An agent asks the maintainer before a push, a merge or deleting a branch.
