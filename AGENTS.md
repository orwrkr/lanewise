# Orchestra — plugin development

The repository is a Claude Code marketplace (`orchestra`) with a single plugin `plugins/orchestra/`: an orchestrator
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

- `plugins/orchestra/bin/orch` — CLI (Python 3.8+, stdlib only): limits, executor profiles, `run`, `launch` (a
  non-Claude lead), the pool and manual tasks, usage log (`usage`), guides (`guide`), hooks
- `plugins/orchestra/skills/orchestrate/SKILL.md` — core routing rules (loaded on every skill invocation — keep it
  compact); details — `skills/orchestrate/reference/*.md`, served by `orch guide <section>`
- `plugins/orchestra/registry/providers.yaml` — built-in model registry; the personal one — `~/.orchestra/providers.yaml`
- `plugins/orchestra/agents/orch-*.md` — executor subagents (model + effort)
- `plugins/orchestra/commands/*.md` — `/orchestra:*`
- `plugins/orchestra/hooks/hooks.json` — SessionStart / UserPromptSubmit / PostToolUse / Stop / SessionEnd →
  `hooks/run.sh` → `orch hook <event>`
- `plugins/orchestra/adapters/` — adapters for automated executors (Python: `codex` — `codex exec --json`;
  `deepseek` — headless Claude Code on the DeepSeek API, also the `orch launch deepseek` lead; `claude` — headless
  Claude Code on the user's own login; `_claude_headless.py` — shared by the last two; contract template)
- `plugins/orchestra/bin/orch.cmd` — `orch` launcher for PowerShell/cmd on Windows
- `plugins/orchestra/tests/run_tests.sh` — self-test (fake codex and claude, temporary git repository)
- `install.sh` / `uninstall.sh` — plugin install and uninstall (the standard way, via `claude plugin`)
- `.github/workflows/tests.yml` — CI: the self-test on Ubuntu and Windows, Python 3.8 compatibility

## Before committing

```bash
bash plugins/orchestra/tests/run_tests.sh          # must report failed: 0 — both in Git Bash on Windows and in WSL:
wsl.exe -- bash -lc 'bash plugins/orchestra/tests/run_tests.sh'   # from the repo root, default WSL distro
claude plugin validate ./plugins/orchestra && claude plugin validate .
```
Changed `orch` behaviour — add a check to `run_tests.sh`. Changed the registry format — update SKILL.md and README.

## Rules

- `orch` and the adapters — Python standard library only, compatible with 3.8 (`vermin -t=3.8- bin/orch
  adapters/codex adapters/deepseek adapters/claude adapters/_claude_headless.py`).
- No machine-specific content: no absolute paths, user names, distro names or personal settings in code, docs,
  tests or commit messages (examples use `/path/to/…`, `<you>`; test data, the user `me`); the repository works from any
  location. `tests/check_portable.py` enforces this in the self-test and in the git hooks (`.githooks`); don't bypass it.
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
  by the orchestrator per SKILL.md. A profile holds only the key's variable name, never the key itself. An unreadable
  `profiles.json` means refusing to run, not "no profiles". Profile fields for an adapter — the directive
  `# orch-profile-env: field=VARIABLE`. Session-wide choices: `ORCH_PROFILES=provider=profile,…`.
- Usage log `~/.orchestra/usage.jsonl`: runs (`usage.json` from the adapter), manual tasks, session snapshots
  (SessionEnd). Writing to the log never breaks a run.
- Read-modify-write of shared state must hold its interprocess lock, re-read and validate under the lock, and
  release it before slow external work; hooks and the status line use a short wait and skip busy updates silently.
- Hooks (`orch hook …`) never crash and never make noise: any error → a silent `exit 0`; output — only on an event.
- Adapters follow the contract from `adapters/_template.example` (env `ORCH_*`, exit 75 = limit, `usage.json`).
- **No programmatic interaction with Antigravity** (or other manual agents): don't launch `agy`, don't use
  computer use, don't paste text, don't touch OAuth — this violates Google's ToS (account ban). The manual lane is
  files in the task's work folder only: TASK.md, RESULT.md and the rule `.agents/rules/orchestra-task.md` in its
  worktree.
- Personal data (limits, the personal registry, profiles and project bindings, keys, usage log) lives in
  `~/.orchestra/`, not in the repository.
- Bump the version in `plugins/orchestra/.claude-plugin/plugin.json` when behaviour changes: plugin installs from
  GitHub are cached by version.
- A version that reaches `main` gets a signed tag `vX.Y.Z` on its last commit, at the merge, once what CI runs passes
  locally (`.github/workflows/tests.yml`: the self-test in both environments, vermin). A tag never moves: a fix that
  external CI still calls for is a new patch version with its own tag, because installs are cached by version.
