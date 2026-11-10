# Non-Claude lead: `orch launch deepseek`

Use it when Claude limits are exhausted, to save Claude quota, or for a setup without Claude at all.

## Launch (from a terminal, in the project)

```bash
orch launch deepseek [--profile P] [--model M] [--no-claude] [--use PROVIDER=PROFILE]... [-- <claude args>]
orch launch deepseek --dry-run      # print the command and the environment (key masked), start nothing
```

Claude Code starts with your usual config and plugins, but every model request goes to DeepSeek's
Anthropic-compatible API: the main thread runs on M (default `deepseek-flash`), background calls on the profile's
fast model, every subagent on M. The DeepSeek key comes from the profile (`orch profile … deepseek`) or
`~/.lanewise/secrets.env`; your `ANTHROPIC_*` variables and `CLAUDE_CODE_OAUTH_TOKEN` are dropped for the session. The session spends the DeepSeek balance (402 → top up, then `orch quota clear deepseek[@P]`).

`--no-claude` and `--use` are session-wide profile choices (`ORCH_PROFILES=claude=off,codex=work`): they win over
directory bindings and defaults, including the lead itself and the Claude lane. `--profile` on `launch` or a
single `run` is stronger. `--use deepseek=off` refuses to launch; an unknown profile is an error.

## A session started by hand (detected)

A Claude Code session started outside `orch launch` — for example `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=… claude` — is recognised as a non-Claude lead by the first `orch` process of every command,
hooks and the status line included, when:

- `ORCH_LEAD` and `ORCH_WORKER` are unset, and
- `ANTHROPIC_BASE_URL` is an endpoint an adapter declares for a lead (`# orch-endpoint:`; DeepSeek's is
  `https://api.deepseek.com/anthropic`, and the adapter's own `base_url` variable, `ORCH_DEEPSEEK_BASE_URL`, counts
  too). Anthropic's own API and other proxies are not a lead, and with no `ANTHROPIC_BASE_URL` nothing is read.

The label comes from the session's token (`ANTHROPIC_AUTH_TOKEN`, else `ANTHROPIC_API_KEY`): the profile whose key
variable holds it (`deepseek@work`), preferring the profile this project resolves to; with several matches and no
binding, the provider's default profile, else the first label alphabetically. A token that matches no key (and is
not the provider's default key variable) gives the bare provider (`deepseek`), and the Lead line says the session's
spend is not under a profile's limit. The token is never printed or stored.

Such a session behaves like a launched one: `orch status` starts with `Lead: … (detected: ANTHROPIC_BASE_URL)`,
`orch key claude` refuses, workers never get the endpoint or token, and the session's own thread counts under the
lead's label in `orch usage` and the status line. Two differences: no `--no-claude`/`--use` choices and no `--model`
of their own are applied (the overrides are already in the environment), and the session has already started, so at
SessionStart `orch` only warns when the lead's spend scope is at its limit — it cannot refuse.

## `orch run claude` from a lead

The Claude executor loads the user settings of its config dir (`--setting-sources user`). If that `settings.json`
has an `env` whose `ANTHROPIC_BASE_URL` is another provider's lead endpoint (one an adapter declares with
`# orch-endpoint:`), or an `ANTHROPIC_MODEL` that is not a Claude model, every request would go there instead of
Claude, so the run fails before starting (a gateway or proxy to Claude itself is fine): exit 1, `STATUS: BLOCKED`, the file and
the setting named. Remove the entry from the file's `env`, or give the profile a config dir without it
(`orch profile set claude <name> --home <dir>`).

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
  Claude slots; cross-review goes Codex ↔ DeepSeek.
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
