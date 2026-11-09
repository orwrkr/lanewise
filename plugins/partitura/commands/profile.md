---
description: Executor profiles — which DeepSeek key, Codex account, whether manual Antigravity is allowed, which models and rules; per project, directory or default
argument-hint: "[show | deepseek work | codex off | antigravity off by default | new profile …]"
---
The operator manages executor profiles: "$ARGUMENTS"

Translate the request into `orch profile …` commands per `orch guide profiles` and run them.

1. Empty or "show" → `orch profile show` and `orch profile list`; answer compactly: for this project —
   who is enabled, with which profile and restrictions, and where that comes from (project / directory / default).
2. Switching → `orch profile use <provider> <profile|off|inherit>`: with no qualifier — for the current project;
   "by default / everywhere" → `--default`; "for all projects in <directory>" → `--path <directory>`.
3. New profile or an edit → `orch profile set <provider> <name> …` (fields — in `orch profile set --help`).
   Project-wide requirements → `orch profile rules --set "TEXT"` (or `--clear`, optionally `--path <directory>`).
   The API key in a profile is only the variable name (`--key DEEPSEEK_API_KEY_WORK`). Don't ask for the key itself
   or write it in chat: the operator adds the line `NAME=sk-…` to `~/.partitura/secrets.env` themselves. For a new
   Codex account, give the operator the login command from the output (`! CODEX_HOME=… codex login`).
4. Show the result of `orch profile show`. If the plan has unstarted subtasks on executors that are now disabled or
   restricted — replan them and say what changed.
5. A broader "how do I set this plugin up here?" question (keys, spend limits, availability, the registry) →
   `orch guide settings`.
