# Non-Claude lead: `orch launch deepseek`

Use it when Claude limits are exhausted, to save Claude quota, or for a setup without Claude at all.

## Launch (from a terminal, in the project)

```bash
orch launch deepseek [--profile P] [--model M] [--no-claude] [--use PROVIDER=PROFILE]... [-- <claude args>]
orch launch deepseek --dry-run      # print the command and the environment (key masked), start nothing
```

Claude Code starts with your usual config and plugins, but every model request goes to DeepSeek's
Anthropic-compatible API: the main thread runs on M (default `deepseek-v4-pro`), background calls on the profile's
fast model, every subagent on M. The DeepSeek key comes from the profile (`orch profile … deepseek`) or
`~/.orchestra/secrets.env`; your `ANTHROPIC_*` variables and `CLAUDE_CODE_OAUTH_TOKEN` are dropped for the session. The session spends the DeepSeek balance (402 → top up, then `orch quota clear deepseek[@P]`).

`--no-claude` and `--use` are session-wide profile choices (`ORCH_PROFILES=claude=off,codex=work`): they win over
directory bindings and defaults, including the lead itself and the Claude lane. `--profile` on `launch` or a
single `run` is stronger. `--use deepseek=off` refuses to launch; an unknown profile is an error.

## Orchestrating as a non-Claude lead

- Same skill, registry, profiles and manual pool. `orch status` starts with `Lead: …`.
- **The orch-\* subagents are not Claude here**: they run on the lead's model. Use them only to isolate context,
  never as a "Claude" slot in routing or cross-review.
- **Claude lane** — headless Claude Code on the operator's Claude login (subscription limits apply), in the
  background like Codex:
  `orch run claude --model <alias> --effort <effort> --mode analysis|write [--cd <worktree>] --task "…" "<task>"`.
  Registry slot `claude/<alias>-<effort>` → `--model <alias> --effort <effort>` (aliases: haiku, sonnet, opus, fable;
  `never_auto` still applies). Exit 75 = Claude limit → fallback.
- **Claude off** (`--no-claude`, `orch profile use claude off`): `orch run claude` answers `PROFILE_OFF`; plan no
  Claude slots; cross-review goes codex ↔ deepseek.
- `orch run deepseek` workers are separate isolated instances: use them for parallel or write tasks in their own
  worktree, exactly as in a Claude-led session.
- Cross-review: the lead's own code is DeepSeek-family code, so it is reviewed by Codex or the Claude lane.

## Limits of the mode

The lead runs with the operator's config directory and its tools can read what the operator's account can,
so dropping credentials from its environment is credential hygiene, not a sandbox.

- Claude Code features that rely on Anthropic-only API capabilities (web search, image input, some server tools)
  may fail on the DeepSeek endpoint; do such steps through Codex or the Claude lane.
- `orch usage`: the transcript shows DeepSeek model ids; Claude Code's cost estimate assumes Claude prices and is
  not meaningful for this session.
