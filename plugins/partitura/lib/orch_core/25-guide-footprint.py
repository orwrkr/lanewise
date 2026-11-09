# ───────────────────────── guide / footprint ─────────────────────────

GUIDE_DIR = PLUGIN_ROOT / "skills" / "orchestrate" / "reference"


def cmd_guide(a):
    """Reference parts of the orchestrate skill, loaded only when needed (keeps the skill itself small)."""
    topics = sorted(p.stem for p in GUIDE_DIR.glob("*.md"))
    if not a.topic:
        print("Topics: %s\norch guide <topic>" % ", ".join(topics))
        return 0
    p = GUIDE_DIR / (a.topic.lower() + ".md")
    if not p.is_file():
        raise SystemExit("orch: no topic %r (available: %s)" % (a.topic, ", ".join(topics)))
    print(p.read_text(encoding="utf-8").rstrip())
    return 0


def cmd_footprint(a):
    """What Partitura created outside Claude Code's own plugin registry — the cleanup list after uninstalling."""
    print("In Claude Code (the standard way): the partitura marketplace and the partitura@partitura plugin "
          "with its hooks, commands, subagents and skill.\n"
          "  Disable: claude plugin disable partitura@partitura · remove: "
          "claude plugin uninstall partitura@partitura && claude plugin marketplace remove partitura")
    print("Outside Claude Code:")
    for p in (Path.home() / ".local" / "bin" / "orch", Path.home() / ".local" / "bin" / "orch.cmd"):
        if p.exists() or p.is_symlink():
            print("  %s — orch launcher" % p)
    if ORCH_HOME.exists():
        print("  %s — personal data: %s" % (ORCH_HOME, ", ".join(sorted(
            c.name + ("/" if c.is_dir() else "") for c in ORCH_HOME.iterdir())) or "empty"))
    data, _ = load_profiles()
    for provider in data["providers"]:
        for name, d in provider_section(data, provider)[1].items():
            home = local_path(str(d["home"])) if isinstance(d, dict) and d.get("home") else None
            if home and Path(home).exists():
                print("  %s — account directory of profile %s@%s (holds the login; delete it yourself if the account "
                      "is no longer needed)" % (home, provider, name))
    projects = {r.get("project_path") for r in ledger_read() if r.get("project_path")}
    if (project_dir() / state_dir_name()).exists():
        projects.add(str(project_root(project_dir())))
    for p in sorted(x for x in projects if x):
        p = Path(p)
        found = [s for s in (p / STATE_DIR_NAME, p / LEGACY_STATE_DIR_NAME, p / AG_RULE_PATH, p / LEGACY_AG_RULE_PATH,
                             p.parent / (p.name + ".wt")) if s.exists()]
        if found:
            names = []
            for s in found:                 # a path inside the project as it reads there, not the project's path again
                try:
                    names.append(str(s.relative_to(p)))
                except ValueError:
                    names.append(str(s))    # a sibling worktree, <project>.wt
            print("  project %s: %s (+ their lines in .git/info/exclude; %s is the general Antigravity rule, which "
                  "stays after a task closes; the state folder (its older name is %s) holds the worktrees of tasks "
                  "that change files in wt/, and if it is deleted by hand run `git worktree prune` there)"
                  % (p, ", ".join(names), AG_RULE_PATH, LEGACY_STATE_DIR_NAME))
    print("Remove everything outside Claude Code: bash uninstall.sh --purge (without --purge personal data is kept).")
    return 0


