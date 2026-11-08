# Contributing

Thanks for helping! Orchestra is a single Claude Code plugin (`plugins/orchestra/`) in a local-marketplace repository.
The development rules — structure, compatibility, isolation, language, what to run before a commit — are in
[AGENTS.md](AGENTS.md). They apply to people and to coding agents alike.

## Setup

```bash
git clone https://github.com/orwrkr/orchestra && cd orchestra
bash install.sh          # installs the plugin from this folder: edits are live after /reload-plugins
git config core.hooksPath .githooks     # stops absolute paths, your user name and private names (~/.orchestra/private_terms.txt, your profile names) from reaching a commit or a push
```

On Windows run it in Git Bash; under WSL run it inside WSL. Each environment has its own installation and its own
`~/.orchestra/`.

`~/.orchestra/private_terms.txt` is optional: one private name per line (`#` starts a comment). The portability
guard reads it at run time and flags those names — together with your profile names, key variables and bound
folders from `~/.orchestra/profiles.json` — in anything you would commit or push; each finding says where the name
came from, so a common-looking folder or profile name is not a mystery.

## Before you open a pull request

```bash
bash plugins/orchestra/tests/run_tests.sh      # must end with "failed: 0"
claude plugin validate ./plugins/orchestra && claude plugin validate .
```

Running the suite natively on Windows (Git Bash) takes half an hour or more: use WSL, or let CI run it on your pull
request, and keep a local Windows run for debugging a Windows-specific failure (AGENTS.md, "Before committing").

- Changed what `orch` does? Add a check to `tests/run_tests.sh` and bump the version in
  `plugins/orchestra/.claude-plugin/plugin.json`.
- `orch` and the adapters use only the Python standard library and must run on Python 3.8.
- English only, LF line endings (except `*.cmd`), no personal paths or keys.
- Keep the `orchestrate` skill compact: rarely needed details go to `skills/orchestrate/reference/`.
  `tests/check_sizes.py` holds what the plugin loads into a session to a budget.

Signed commits (SSH or GPG) are preferred. CI runs the self-test on Ubuntu and Windows and checks Python 3.8
compatibility with vermin.

## How a change ships

The maintainer works with coding agents, orchestrated by the plugin itself. The steps are the same for a person.

1. **Pick the item.** Take the next item from [ROADMAP.md](ROADMAP.md), or start from an issue.
2. **Write the spec.** Make it self-contained: context, goal, scope, acceptance criteria, how to verify, limits.
   - For an executor, it goes in `.orchestra/prompts/<name>.md`, which git ignores. An executor sees only the spec, not
     the conversation that led to it.
   - Use neutral labels such as `client` or `work`: executors copy what they read.
3. **Make a worktree.** `orch worktree add <name>` creates `../<repo>.wt/<name>` on the branch `orch/<name>`. Give each
   writer its own worktree.
4. **Hand it to an executor.** The plugin's routing picks it (`orch status`, `orch registry show`, the `orchestrate`
   skill): a Claude subagent, Codex or DeepSeek. The executor neither commits nor runs the whole self-test.
5. **Review.** Read the whole diff, then fix it or send it back.
   - Code that matters gets a review from another model family.
   - Behaviour that changed gets checks in `tests/run_tests.sh`.
   - Bump the version in `plugin.json` and add an entry to `CHANGELOG.md`.
6. **Test.** Run the self-test in WSL (or on Linux or macOS) and `claude plugin validate`, as above. The self-test
   needs a fair amount of free memory: on a busy machine, wait for it rather than run it beside heavy work.
7. **Commit and open a pull request.** Usually one commit per version. CI must be green on the pull request.
8. **Merge.**
   - Fast-forward `main` and put a signed tag `vX.Y.Z` on the merged commit (AGENTS.md).
   - Watch CI on `main`.
   - Remove the worktree and the branch.
   - Delete the item from ROADMAP.md.
