# Privacy policy

Partitura is a Claude Code plugin that runs on your computer. Its author runs no service for it: there is no
account, no server, no telemetry and no analytics, and nothing about you or your work is sent to the author.

## What stays on your computer

- `~/.partitura/`: your settings, executor profiles, API keys (`secrets.env`), spend limits, balances and the usage
  log (which model did what, and how many tokens it spent).
- `<project>/.partitura/` in projects where you used the plugin: executor runs, task prompts and manual tasks.

Before 0.35.0 both folders were named `.orchestra`.

`orch footprint` lists everything the plugin created. `bash uninstall.sh --purge` removes the plugin and
`~/.partitura`; project folders are yours to delete.

## What leaves your computer, and to whom

- **Executors you choose.** When the orchestrator gives a task to Codex, DeepSeek or Claude, that executor sends the
  task, your project's rules (CLAUDE.md, AGENTS.md) and the files it reads to its own provider: OpenAI, DeepSeek or
  Anthropic. It uses your account or API key, under that provider's terms and privacy policy. Claude subagents run
  inside your Claude Code session, like any subagent.
- **One request of the plugin's own.** `orch` reads your DeepSeek account balance from DeepSeek
  (`GET https://api.deepseek.com/user/balance`), with your DeepSeek key. `ORCH_BALANCE=off` turns it off.
- **Manual agents** (Antigravity and similar) receive nothing from the plugin. It writes task files into your
  project, and you hand them over yourself.

The plugin README lists every case, with what triggers it:
[What it runs, sends and fetches](plugins/partitura/README.md#what-it-runs-sends-and-fetches).

## The website

[orwrkr.github.io/partitura](https://orwrkr.github.io/partitura/) is a static page. It loads nothing from other
sites, sets no cookies and runs no analytics. GitHub hosts it and the repository, and GitHub's own privacy statement
covers what GitHub itself records.

## Questions and changes

Ask through [GitHub issues](https://github.com/orwrkr/partitura/issues). Report security problems privately, as
[SECURITY.md](SECURITY.md) describes. Changes to this policy are in this file's git history.
