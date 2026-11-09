# Limits and availability: operator phrases → commands

Get the current date and time with `date`. Time — absolute `YYYY-MM-DD HH:MM`, `HH:MM`, `tomorrow HH:MM` or `+3h`.
No reset time given — don't make one up: set it without `--until` and say the restriction is lifted by the phrase
"… works again".

| The operator says | Command |
|---|---|
| "Codex hit its limit until 18:00" | `orch quota set codex exhausted --until 18:00` |
| "Sol is out until 9 am tomorrow" | `orch quota set codex/gpt-6.1-sol exhausted --until "tomorrow 09:00"` |
| "the weekly Argon quota is used up, resets on Wednesday" | `orch quota set antigravity/gemini-4-argon exhausted --until "<Wednesday's date> 09:00"` |
| "Opus is running low" | `orch quota set claude/opus low --note "conserve"` |
| "Codex works again" | `orch quota clear codex` |
| "topped up DeepSeek" / "DeepSeek is available again" | `orch quota clear deepseek` (also lifts blocks on `deepseek@…` profiles) |
| "topped up the DeepSeek work key" | `orch quota clear deepseek@work` |
| "leave DeepSeek alone today" | `orch quota set deepseek disabled --until "tomorrow 09:00"` |
| "I'm away until the evening" / "no Antigravity for me today" | `orch quota set operator away --until 19:00` |
| "I'm back" | `orch quota clear operator` |

- Keys: provider (`codex`), provider/model (`codex/gpt-6.1-sol`), profile (`deepseek@work` — its own key or
  account), `operator` — the whole manual lane.
- Restrictions with `--until` are lifted automatically when the time comes. `orch run` catches the Codex limit and
  the DeepSeek balance itself (exit 75) and records them on the profile's key.
- `busy` is set automatically for a model at provider capacity and lifts by itself.
- After any change, move unstarted subtasks off unavailable slots to their fallback.
- Stored in `~/.partitura/availability.json`, shared by all projects. If unreadable, reads warn and assume no restrictions; quota changes refuse until the file is fixed.
