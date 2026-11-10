# Privacy policy

Lanewise is a Claude Code plugin that runs on your computer. Its author runs no service for it: there is no
account, no server, no telemetry and no analytics, and nothing about you or your work is sent to the author.

## What stays on your computer

- `~/.lanewise/`: your settings, executor profiles, API keys (`secrets.env`), spend limits, balances and the usage
  log (which model did what, and how many tokens it spent).
- `<project>/.lanewise/` in projects where you used the plugin: executor runs, task prompts and manual tasks.

Before 0.36.0 both folders were named `.partitura`; before 0.35.0, `.orchestra`. `orch` reads either where it is,
and `orch migrate` moves it to the new name.

`orch footprint` lists everything the plugin created. `bash uninstall.sh --purge` removes the plugin and
`~/.lanewise`; project folders are yours to delete.

## What leaves your computer, and to whom

- **Executors you choose.** When the orchestrator gives a task to Codex, DeepSeek or Claude, that executor sends the
  task, your project's rules (CLAUDE.md, AGENTS.md) and the files it reads to its own provider: OpenAI, DeepSeek or
  Anthropic. It uses your account or API key, under that provider's terms and privacy policy. Claude subagents run
  inside your Claude Code session, like any subagent.
- **One request of the plugin's own.** `orch` reads your DeepSeek account balance from DeepSeek
  (`GET https://api.deepseek.com/user/balance`), with your DeepSeek key. `ORCH_BALANCE=off` turns it off.
- **Manual agents** (Antigravity and similar) receive nothing from the plugin. It writes task files into your
  project, and you hand them over yourself.

What those providers do with the data is governed by their own privacy policies:

- Anthropic (Claude, and Claude Code itself): [anthropic.com/legal/privacy](https://www.anthropic.com/legal/privacy)
- OpenAI (Codex): [openai.com/policies](https://openai.com/policies/), which lists the privacy policy for your region
- DeepSeek: [DeepSeek Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- Google (Antigravity, when you use it for a manual task): [policies.google.com/privacy](https://policies.google.com/privacy)

The plugin README lists every case, with what triggers it:
[What it runs, sends and fetches](plugins/lanewise/README.md#what-it-runs-sends-and-fetches).

## The website

[orwrkr.github.io/lanewise](https://orwrkr.github.io/lanewise/) is a static page. It loads nothing from other
sites, sets no cookies and runs no analytics. GitHub hosts it and the repository, and GitHub's own privacy statement
covers what GitHub itself records.

## Questions and changes

Ask through [GitHub issues](https://github.com/orwrkr/lanewise/issues). Report security problems privately, as
[SECURITY.md](SECURITY.md) describes. Changes to this policy are in this file's git history.
