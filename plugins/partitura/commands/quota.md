---
description: Report a subscription limit, balance, or their recovery (codex, claude/opus, deepseek, antigravity/argon…)
argument-hint: "<what and until when, e.g.: codex is out until 18:00>"
---
The operator reports a change in executor availability: "$ARGUMENTS"

1. Get the current date and time: `date`.
2. Translate the message into `orch quota set|clear` commands using the table in `orch guide quota` (keys: provider,
   provider/model or profile `deepseek@work`; time — absolute `YYYY-MM-DD HH:MM`, `HH:MM`,
   `tomorrow HH:MM` or `+3h`). No reset time given — don't make one up: set it without `--until` and say the
   restriction is lifted by the phrase "… works again".
3. Run them and show `orch quota show`.
4. Move unstarted subtasks off unavailable slots to their fallback and briefly say what changed.
