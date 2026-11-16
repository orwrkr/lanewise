# Roadmap

What is open, roughly in order. Finished work goes to [CHANGELOG.md](CHANGELOG.md) and the git history, not here: when
an item ships, delete it from this file in the same pull request.

Each item is marked:
- **product**: changes what the plugin does for the people who use it;
- **process**: changes how this repository is developed (docs, tests layout, CI, workflow).

At most one process item is in progress at a time. A new one starts only with the maintainer's go, given with its
expected benefit and a limit on what it may cost ([AGENTS.md](AGENTS.md#rules)). Work on the workflow itself can
quietly crowd out the product, and this rule keeps it in view.

## Next

- **The early-exhaustion warning and the status line agree on the projection.** *product* The warning that a limit
  runs out before its reset (the pause question, `orch watch`) can show other figures than the status line's
  `→ ≈N%` for the same window. Likely sources:
  - for the week, the early rule weighs both paces (the recent one and the week's average) and quotes the lower one,
    while the status line and the budget take the recent pace first;
  - the five-hour window also carries a conservative projection from the lower pace.

  Compare the two on a real case, then either show one figure in both places or have the warning say which pace its
  figure comes from.

## Parked

- **A Gemini executor.** *product* Gemini CLI fits the adapter contract technically:
  - headless `-p` with JSON output;
  - a read-only plan mode;
  - a separate config home;
  - token counts per model.

  But since 2026-06-18, individual and Google AI Pro/Ultra accounts use Antigravity CLI instead, which stays manual
  here (AGENTS.md). Gemini CLI is left to Code Assist Enterprise and paid Gemini API or Vertex keys, and scripted use
  through a consumer login risks the account. Revisit if a paid Gemini API key or Vertex project is wanted. A quota hit
  shows up only as exit 1 with text on stderr, so the adapter would have to read that text.

- **DeepSeek Harness as an executor.** *product* DeepSeek's own open-source agent (`dsh`, npm `@deepseek-ai/dsh`,
  MIT) fits the contract technically:
  - headless mode (`dsh --profile headless "task"`) with `--json` events, `--approval-policy never` and
    `--permission-mode`;
  - a Python SDK and a JSON-RPC stdio server;
  - it reads AGENTS.md/CLAUDE.md, and has `read_image`, web search and web fetch.

  Not adopted yet because, as of 2026-11-16: only pre-releases (`dsh-v0.2.2-rc.3`, 2026-11-13) with announced
  breaking changes; the `--json` event schema is undocumented; no token usage per run, which orch's spend limits
  need; no documented read-only preset, and its workspace-write preset leaves reads and network unconfined, so a
  worker could read files such as `~/.lanewise/secrets.env` that the current executor is denied; no flags for model
  or working directory. Revisit at a stable release that reports usage and confines reads.
