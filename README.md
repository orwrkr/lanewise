# <img src="assets/icon.svg" alt="" width="40" align="top"> Partitura

[![tests](https://github.com/orwrkr/partitura/actions/workflows/tests.yml/badge.svg)](https://github.com/orwrkr/partitura/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A multi-model orchestrator plugin for [Claude Code](https://claude.com/claude-code).** The lead session breaks a
task down and decides who does each subtask, and at what effort:

- **Claude subagents** — Haiku, Sonnet, Opus, Fable at the right effort level;
- **Codex CLI** — on your ChatGPT subscription or an API key, in the background;
- **DeepSeek** — on an API key, as a full agent (headless Claude Code on DeepSeek's Anthropic-compatible API);
- **a pool of manual tasks** for Antigravity, Cursor and similar agents: you pick a task and paste one line.

Routing follows a model registry (difficulty, cost, strengths, cross-review between model families), subscription
limits and balance, your availability and per-project **executor profiles** (which key or account, which models,
which rules — or `off`). **Spend limits** cap what API-billed executors (DeepSeek, Codex/Claude on a key) may
spend — a manual counter for prepaid keys, a monthly budget otherwise — `orch spend`. Every session gets a
**usage log**: which model did what and how many tokens it spent. A **budget mode** watches the Claude
subscription's 5-hour window: when it would expire largely unused, Claude takes the work that would otherwise cost
money on API keys. **DeepSeek can lead instead of Claude** (`orch launch deepseek`), with Claude models switched off
entirely if you want.

Works with Claude Code in WSL/Linux and natively on Windows. Needs Claude Code itself (installed and logged in),
Python ≥ 3.8 (standard library only) and git; npm only for the optional Codex line below.

Partitura was called **Orchestra** before 0.34.0: [upgrading](CHANGELOG.md#0340) takes one command.

## Quick start

```bash
git clone https://github.com/orwrkr/partitura && cd partitura
bash install.sh                 # Git Bash on Windows; inside WSL for a WSL installation
```

If `orch` isn't found in a new terminal, `~/.local/bin` is not on your PATH (Claude Code's own installer
puts `claude` in that folder too, so you may already have it there). In Git Bash or bash:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

In PowerShell on Windows (for `orch.cmd`; then open a new terminal):

```powershell
[Environment]::SetEnvironmentVariable('Path', "$env:USERPROFILE\.local\bin;" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')
```

Or without a clone, from a terminal (the plugin's `orch` is then not in your terminal, only in the session's Bash
tool):

```bash
claude plugin install partitura --marketplace orwrkr/partitura
```

Then `cd` into your project, start `claude` and run `/partitura:status`; `claude plugin list` shows whether the
plugin is enabled. Give Claude Code a multi-step task and the `orchestrate` skill takes over. Optional executors:

```bash
npm i -g @openai/codex && codex login     # Codex
# DeepSeek: add the line DEEPSEEK_API_KEY=sk-… to ~/.partitura/secrets.env (never to a repository)
orch doctor                               # what is available
```

In `orch doctor`, `✔` is fine, `·` is optional and not set up, `✘` is a problem to fix.

| In a session | |
|---|---|
| `/partitura:run <task>` | plan → assign models and effort → execute |
| `/partitura:status` | limits, profiles, manual tasks |
| `/partitura:manual` | the manual task pool: "AG-0004 to Antigravity" |
| `/partitura:profile …` | "no DeepSeek in this project", "Codex on the second account" |
| `/partitura:usage` | who did what and how many tokens it took |

All eight commands, including `/partitura:quota`, `/partitura:done` and `/partitura:away`:
[plugin documentation](plugins/partitura/README.md#usage).

## Documentation

- [Plugin documentation](plugins/partitura/README.md) — executors and their isolation, profiles, the manual lane,
  DeepSeek as the lead, the usage log, the registry, adding executors, storage, uninstalling
- [Routing rules](plugins/partitura/skills/orchestrate/SKILL.md) the lead follows, and their
  [reference sections](plugins/partitura/skills/orchestrate/reference/)
- [Model registry](plugins/partitura/registry/providers.yaml)
- [Contributing](CONTRIBUTING.md) · [Development rules](AGENTS.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)
- [Privacy policy](PRIVACY.md) · [Terms of use](TERMS.md)

**Antigravity and other manual agents are never automated** — no `agy`, computer use, text pasting or OAuth (that
violates Google's ToS). Partitura only writes task files for them and reads their results.

Uninstall: `bash uninstall.sh` (standard `claude plugin uninstall`; `--purge` also deletes `~/.partitura/`).
`orch footprint` lists everything the plugin created outside Claude Code.

## License

[MIT](LICENSE)
