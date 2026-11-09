# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](https://github.com/orwrkr/partitura/security/advisories/new) rather than a public issue.
Include the affected version (`plugins/partitura/.claude-plugin/plugin.json`), your platform (WSL/Linux/macOS or
native Windows) and the steps to reproduce. You should get a first answer within a week.

## What is in scope

Partitura runs other AI agents on your machine and handles API keys, so these areas matter most:

- **Secrets.** API keys live only in `~/.orchestra/secrets.env` and reach only the adapters that declare them
  (`# orch-secrets: …`). Profiles store variable names, never key values. A key showing up in a repository, a log,
  `orch` output or another adapter's environment is a vulnerability. Keys are not plugin options (`userConfig`):
  Claude Code never passes those to commands run through the Bash tool, which is how `orch` starts executors (plugin
  README, "What it runs, sends and fetches").
- **Worker isolation.** Workers must not inherit the orchestrating session's variables (`CLAUDECODE`, `CLAUDE_*`,
  a non-Claude lead's endpoint and token), must not be able to delegate further (`ORCH_WORKER`), and must stay within
  the permissions of their mode (`analysis` / `write`, `--allow` rules).
- **Hooks.** Plugin hooks run on every prompt and tool call; they must never execute content from task files.

Manual agents (Antigravity and similar) are never automated by design: Partitura only writes task files for them.
