@AGENTS.md

## Claude Code only

- The plugin is installed straight from this folder (`bash install.sh`), so **edits here are live**: they take effect
  after `/reload-plugins` or in a new session. Uninstall — `bash uninstall.sh`.
- Shared rules go in `AGENTS.md` (Codex and Antigravity read it); here only what concerns Claude Code alone.
- What the plugin puts into a session (`claude --plugin-dir ./plugins/lanewise plugin details lanewise`) is held to a
  budget by `tests/check_sizes.py`: put rarely needed material in `skills/orchestrate/reference/`, not in SKILL.md.
- Claude Code stops background shells when memory runs low. So a local test run waits in the background for free
  memory and starts by itself; stopped again, it waits again and runs only the sections not yet passed; after a long
  wait it starts anyway if memory may suffice.
