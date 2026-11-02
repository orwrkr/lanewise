# Orchestra

[![tests](https://github.com/orwrkr/orchestra/actions/workflows/tests.yml/badge.svg)](https://github.com/orwrkr/orchestra/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A multi-model orchestrator plugin for [Claude Code](https://claude.com/claude-code).** The lead session breaks a
task down and decides who does each subtask, and at what effort:

- **Claude subagents** — Haiku, Sonnet, Opus, Fable at the right effort level;
- **Codex CLI** — on your ChatGPT subscription, in the background;
- **DeepSeek** — on an API key, as a full agent (headless Claude Code on DeepSeek's Anthropic-compatible API);
- **a pool of manual tasks** for Antigravity, Cursor and similar agents: you pick a task and paste one line.

Routing follows a model registry (difficulty, cost, strengths, cross-review between model families), subscription
limits and balance, your availability and per-project **executor profiles** (which key or account, which models,
which rules — or `off`). Every session gets a **usage log**: which model did what and how many tokens it spent.
A **budget mode** watches the Claude subscription's 5-hour window: when it would expire largely unused, Claude takes
the work that would otherwise cost money on API keys. Projections use each measurement's time; numbers older
than 20 minutes cannot enable SURPLUS, and a weekly overrun raises TIGHT even without five-hour numbers.
**DeepSeek can lead instead of Claude** (`orch launch deepseek`), with Claude models switched off entirely if you want.
Session `--use` choices govern the lead too; only `--profile` overrides them.

Shared state uses atomic writes and bounded OS locks, so parallel sessions preserve tasks and usage. Manual
profile capacity is enforced even with `--force`; `wait --any` returns an existing unreported result once.
Executor reports beginning `STATUS: BLOCKED` or `PARTIAL` keep that outcome in the header and usage log (exit 0).
A Codex model at capacity exits 75 and blocks only that model for about 10 minutes. Native Windows sandbox
setup for tests using temporary repositories is described in the Codex [registry notes](plugins/orchestra/registry/providers.yaml).

Works with Claude Code in WSL/Linux and natively on Windows. Python ≥ 3.8 (standard library only) and git.

## Quick start

```bash
git clone https://github.com/orwrkr/orchestra && cd orchestra
bash install.sh                 # Git Bash on Windows; inside WSL for a WSL installation
```

Or from inside Claude Code, without a clone (no terminal `orch` command then):

```
/plugin install orchestra --marketplace orwrkr/orchestra
```

Then just give Claude Code a multi-step task — the `orchestrate` skill takes over. Optional executors:

```bash
npm i -g @openai/codex && codex login     # Codex
# DeepSeek: add the line DEEPSEEK_API_KEY=sk-… to ~/.orchestra/secrets.env (never to a repository)
orch doctor                               # what is available
```

| In a session | |
|---|---|
| `/orchestra:run <task>` | plan → assign models and effort → execute |
| `/orchestra:status` | limits, profiles, manual tasks |
| `/orchestra:manual` | the manual task pool: "AG-0004 to Antigravity" |
| `/orchestra:profile …` | "no DeepSeek in this project", "Codex on the second account" |
| `/orchestra:usage` | who did what and how many tokens it took |

## Documentation

- [Plugin documentation](plugins/orchestra/README.md) — executors and their isolation, profiles, the manual lane,
  DeepSeek as the lead, the usage log, the registry, adding executors, storage, uninstalling
- [Routing rules](plugins/orchestra/skills/orchestrate/SKILL.md) the lead follows, and their
  [reference sections](plugins/orchestra/skills/orchestrate/reference/)
- [Model registry](plugins/orchestra/registry/providers.yaml)
- [Contributing](CONTRIBUTING.md) · [Development rules](AGENTS.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

**Antigravity and other manual agents are never automated** — no `agy`, computer use, text pasting or OAuth (that
violates Google's ToS). Orchestra only writes task files for them and reads their results.

Uninstall: `bash uninstall.sh` (standard `claude plugin uninstall`; `--purge` also deletes `~/.orchestra/`).
`orch footprint` lists everything the plugin created outside Claude Code.

## License

[MIT](LICENSE)
