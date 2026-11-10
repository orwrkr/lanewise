# Renaming the plugin

The plugin has been renamed twice: Orchestra → Partitura (0.34.0, folders in 0.35.0) and Partitura → Lanewise
(0.36.0). This is what those two renames taught. Follow it if the name ever has to change again, so that nobody's
installation, data or open work breaks.

## 1. Choose a name that is really free

Partitura was picked from a list without a search, and a product of the same name in the same niche turned up a day
after the release. Check every candidate before proposing it:

- **GitHub:** `gh search repos <name>`. Read the descriptions, not just the counts: a small repo that orchestrates AI
  agents under that name is a collision, while a game or a library in another field is not.
- **The web:** the name with "AI", "agent", "app" and "company". Look for products, companies and trademarks.
  Trademark databases: [USPTO](https://tmsearch.uspto.gov), [EUIPO](https://euipo.europa.eu/eSearch/).
- **Package registries:** PyPI and npm (`https://pypi.org/pypi/<name>/json`, `https://registry.npmjs.org/<name>`).
- **Domains:** whether `<name>.com`, `.dev`, `.ai` and `.io` resolve.
- **Plugin directories.** Anthropic's directory refuses a name that matches an existing publisher or connector. It
  also treats a generic prefix or suffix (`orchestra-mcp`) or a one-to-two-letter difference as confusable, so a new
  name must not contain the old one either.

Words around orchestration ("conductor", "maestro", "symphony", "tutti", "baton", "switchyard", …) are crowded
with agent tools. Expect most of them to be taken.

## 2. Decide what keeps its name

Only the brand has to change: the plugin and marketplace name, which also sets the command namespace
(`/<name>:…`), the subagent types (`<name>:orch-…`) and the skill (`<name>:orchestrate`); the plugin folder; the
documentation and the site; the repository.

These have stayed through both renames and should stay again:

- **the `orch` CLI and the `ORCH_*` variables**: users' scripts and settings name them;
- **the registry marker `# orchestra-registry-base:`**: personal registry copies carry it.

The state folders (`~/.<name>`, `<project>/.<name>`) may follow the brand. That needs the migration support in
section 4, so plan it in the same version or the next one.

## 3. The mechanical rename

In a worktree:
1. `git mv plugins/<old> plugins/<new>`.
2. Replace the safe patterns in every tracked text file except CHANGELOG.md, whose history keeps the names it had:
   - `plugins/<old>`;
   - `orwrkr/<old>` and `orwrkr.github.io/<old>`;
   - `<old>@<old>`, `/<old>:` and `<old>:orch`;
   - `"name": "<old>"`;
   - `<old>-task.md`;
   - `.<old>` (the state folder);
   - the brand word, capitalised, as a whole word.

   Use `sed -E` with word boundaries. Never replace `.orchestra` or `orchestra-local` blindly: they are legacy names
   the code must keep.
3. **Fix what the automatic replacement got wrong:**
   - explanations of earlier names ("X was called Y before 0.34.0");
   - the `LEGACY_*` constants;
   - the scripts' `MARKET`, `PLUGIN` and `LEGACY_*` lines.
4. **Run the old-name check** (section 41 of the self-test). It lists every line that still names an old brand. A
   line may only do so when it explains a rename, which means it names that rename's version or a `LEGACY` constant.
   Add the new old name to its word list and the new version to its allowed versions.

   Do not trust a look at terminal output for this: long lines are cut off, and that is how 0.34.0 shipped the old
   name in the subagent descriptions.

## 4. Teach every alias the new old name

Keep each list newest first. Each place must accept every earlier name, because some users skip versions.

| what | where |
|---|---|
| personal folder: `ORCH_HOME`, else the first existing of `~/.<new>`, `~/.<old>`, …, else `~/.<new>` | `00-header.py` (`resolve_home`), the shell part and `_cache_file()` of `bin/orch`, `hooks/run.sh`, `adapters/_claude_headless.py` (`orch_home`), `install.sh`, `uninstall.sh`, `tests/check_portable.py` |
| project state folder | `STATE_DIR_NAME`, `LEGACY_STATE_DIR_NAMES` in `00-header.py` |
| registry subagent types | `PLUGIN_NAME`, `LEGACY_PLUGIN_NAMES`, `LEGACY_AGENT_RE` in `26-registry.py` |
| the Antigravity rule file | `AG_RULE_PATH`, `LEGACY_AG_RULE_PATHS` in `19-handoffs-manual-lane.py` |
| old installations | `LEGACY_MARKETS`, `LEGACY_PLUGINS` in `install.sh` and `uninstall.sh`; the launcher check in `uninstall.sh` |
| moving folders | `orch migrate` (`28-migrate.py`); it reads the lists above |

**The personal-folder order is critical.** If an old folder is not on the list, the new version creates an empty
`~/.<new>`, and the user loses their limits, keys and logs from view. Before release, run the new code read-only
against a real home: `python plugins/<new>/bin/orch doctor` must show the profiles in the old folder and create
no new one.

**Tests:** extend sections 17 (old rule files removed), 39 (install scripts, registry alias in every view), 41 (old
names) and 44 (migration: each old name, several present means report and do not merge, resolution order, the doctor
hint).

## 5. Version and changelog

A rename is a minor version. Its CHANGELOG entry says:
- why;
- what changes and what stays;
- where the repository is now;
- the upgrade steps, from a clone and without one;
- which old names keep working.

The README and the plugin README mention the earlier names once.

## 6. The repository

There are two ways to move the repository:

- **Rename it** (`gh repo rename`). GitHub redirects the old git and web addresses until a repository with the old
  name is created, and stars, issues and releases stay. GitHub Pages does not redirect: the old site address stops
  working.
- **Create a new repository** (as for Lanewise). Push the full history and every tag to it: `git push origin main`,
  then `git push origin --tags`. Never push backup branches. Then:
  - give the old repository a notice in its README, its plugin README and on its site, with links and a removal
    date;
  - delete the old repository on that date. That also ends any redirect still pointing at it.

**Settings to repeat on a new repository** (`gh repo edit` and `gh api`):
- description, homepage and topics;
- Issues and Discussions on, Wiki and Projects off, delete branches on merge;
- private vulnerability reporting, secret scanning with push protection, Dependabot alerts and security updates;
- rulesets: no force push or deletion on the default branch, `v*` tags that cannot move;
- GitHub Pages from `main` `/docs`, once the renamed site is on `main`.

**CodeQL** ties dismissed alerts to file paths. After the plugin folder moves, it raises the two by-design alerts
again: `orch key` prints the key for Claude Code's apiKeyHelper, and `--launch-env` hands the token to `orch launch`
through a pipe. Dismiss them again with the same reason.

**Keep a working installation working.** The maintainer's plugin is installed live from the local clone. Push the
renamed branch to `main` on GitHub with `git push origin <branch>:main`, and leave the local `main` alone until the
maintainer is ready to reinstall: pulling it removes the folder the running plugin reads.

## 7. Each installation

**First, reload or restart every open Claude Code session that uses the plugin, in every project.** A session
started under the old name keeps the old instructions. Its agent can go on writing task prompts to the old state
folder (`<project>/.<old>/prompts/`) after that folder has moved. The project then has two state folders, and
`orch migrate` stops there, because it never merges.

From a clone, in every environment where the plugin is installed (Git Bash, WSL):

```bash
git remote set-url origin https://github.com/orwrkr/<new>.git   # only if the repository moved
git pull --ff-only
bash install.sh                    # removes the old plugin and marketplace, installs the new ones
orch migrate --all --home          # what would move: changes nothing
orch migrate --all --home --yes    # move the personal and project folders
```

Then:
- `/reload-plugins` in open sessions;
- in the personal registry copy, replace `agent: <old>:` with `agent: <new>:` and the old folder paths in its
  comments, and keep your own edits. Then run `orch registry diff` (only your own edits should remain) and
  `orch registry diff --accept`.

`orch migrate` skips a project with a manual task that is handed out and not finished, because its agent would
write RESULT.md to the old path. Finish or cancel the task (`orch handoff cancel <id>`), then run it again.

If the old plugin folder is still there after the pull, it holds only Python's cache and can be deleted.

**When a project has two state folders** ("both … exist: nothing was merged"), look at what the newer one holds.
Usually it is a few prompt files that a session with old instructions wrote after the move.
1. Check that their names do not clash with files in the folder that holds the history, then move them there.
2. Delete the emptied folder.
3. Run `orch migrate <project> --yes`.

If the second folder holds runs or manual tasks of its own, sort them by hand: nothing may be lost.

**Finally, sweep:**
- `orch migrate --all --home` reports nothing to move;
- `orch doctor` names no old folder;
- no folder with an old name is left in the projects directory. `orch migrate --all` only knows projects from the
  usage log and the profiles, so search the disk too, e.g. `find <projects dir> -maxdepth 7 -type d -name '.<old>'`.

## 8. Projects and the outside world

- **Inside projects, `orch` handles what it created:** state folders (with `orch migrate`), their `.git/info/exclude`
  lines, and the Antigravity rule (at the next manual task).
- **Each project's own documents** (CLAUDE.md, AGENTS.md, `.agents/`, …) may name the plugin. Search them for the
  old name and update them from each project's own session or with its owner's agreement. Leave task history as it
  is.
- **Outside:** submissions to plugin directories, marketplaces, posts, and people who were sent the old address.
