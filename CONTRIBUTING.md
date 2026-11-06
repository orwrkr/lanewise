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

Signed commits (SSH or GPG) are preferred. CI runs the self-test on Ubuntu and Windows and checks Python 3.8
compatibility with vermin.
