# Roadmap

What is open, roughly in order. Finished work goes to [CHANGELOG.md](CHANGELOG.md) and the git history, not here: when
an item ships, delete it from this file in the same pull request.

Each item is marked:
- **product**: changes what the plugin does for the people who use it;
- **process**: changes how this repository is developed (docs, tests layout, CI, workflow).

At most one process item is in progress at a time. A new one starts only with the maintainer's go, given with its
expected benefit and a limit on what it may cost ([AGENTS.md](AGENTS.md#rules)). Work on the workflow itself can
quietly crowd out the product, and this rule keeps it in view.

## Small

- **`orch doctor` checks who can read `secrets.env`.** *product* On Linux, macOS and WSL, warn when
  `~/.lanewise/secrets.env` can be read by group or others, and give the fix (`chmod 600`). Native Windows has no
  such mode bits, so skip the check there. Why keys stay in that file: SECURITY.md, "Secrets".

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
