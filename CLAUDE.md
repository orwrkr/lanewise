@AGENTS.md

## Claude Code only

- The plugin is installed straight from this folder (`bash install.sh`), so **edits here are live**: they take effect
  after `/reload-plugins` or in a new session, nothing needs reinstalling. Uninstall — `bash uninstall.sh`
  (the standard `claude plugin uninstall` + `marketplace remove`).
- Shared rules live in `AGENTS.md` (both Codex and Antigravity read it): edit them there, and put here only what
  concerns Claude Code alone.
- The plugin's weight in context: `claude --plugin-dir ./plugins/orchestra plugin details orchestra`. The core of the
  `orchestrate` skill is ≈3.9k tokens per invocation, the whole plugin ≈1.1k always-on; put new and rarely needed
  material in `skills/orchestrate/reference/`, not in SKILL.md.
