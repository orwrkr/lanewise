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

1. **Split the code and the self-test.** *process*
   - Split `lib/orch_core.py` (about 9,000 lines) into modules, and `tests/run_tests.sh` (about 5,800) into sections
     that can run alone.
   - This ends the one-file layout described in AGENTS.md ("Structure"), so update it.
2. **A Gemini executor: a spike first.** *product*
   - Find out what Gemini CLI offers for headless runs: structured output, permissions, limit and usage reporting.
   - Decide whether it fits the adapter contract (`adapters/_template.example`), then propose the adapter.

## Small items

- **Spend at a window or month boundary.** *product* A session's spend is recorded at SessionEnd. So:
  - a limit reset in the middle of a session counts the whole session again in the new window;
  - a session across a month boundary lands in the new month.
- **`claude --resume`.** *product* Check whether a resumed session gets a new session id with the full history. That
  would count its tokens twice.
- **Guides against the parser.** *process* A self-test check that every `orch` command and option named in
  `skills/orchestrate/reference/*.md` exists in the argument parser. It is a manual research task today.

## Release

The repository stays private until the items above are done. Making it public is the maintainer's decision.
