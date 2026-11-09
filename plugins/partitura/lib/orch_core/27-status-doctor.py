# ───────────────────────── status / doctor ─────────────────────────

def cmd_status(a):
    if not a.brief:                    # the SessionStart hook (brief) starts a detached fetch instead of waiting for one
        balance_refresh_stale(project_dir())
    data = load_avail()
    lines = [lead_line()] if lead_line() else []
    if a.brief:
        line = "Partitura: executor registry — %s" % registry_path()
        note = registry_stale_note()
        if note:
            line += " · " + note
        lines.append(line)
    mode, budget = claude_budget()
    if budget:
        lines.append(budget)
    _, codex = codex_budget()
    if codex:
        lines.append(codex)
    spend = spend_status_part(project_dir())
    if spend:
        lines.append(spend)
    lines += balance_status_lines(project_dir())
    if data["entries"]:
        lines.append("Availability restrictions:")
        lines += ["  " + describe_entry(k, e) for k, e in sorted(data["entries"].items())]
    else:
        lines.append("No availability restrictions — every executor in the registry is available.")
    if PROFILES_FILE.exists():
        where = project_dir()
        lines.append("Executor profiles for %s (orch profile show):" % canon_path(project_root(where)))
        lines += profile_lines(where, budget=False)
    has_state = (project_dir() / ".orchestra").exists()
    metas = [m for m in all_metas() if result_status(m) not in TERMINAL] if has_state else []
    if metas:
        lines.append("Open manual tasks (pooled and handed out; board .orchestra/MANUAL.md):")
        lines += ["  " + handoff_line(m) for m in metas]
    if not a.brief and has_state:       # a read-only command must not create .orchestra in a folder it never used
        events = check_events(mark=False)
        if events:
            lines.append("Unreported events:")
            lines += ["  " + ev.splitlines()[0] for ev in events]
    print("\n".join(lines))
    return 0


def orch_path_hint(home=None):
    """The doctor hint for an `orch` that is not on PATH: the launchers may exist already, with their folder off PATH."""
    bindir = Path(home or Path.home()) / ".local" / "bin"
    if (bindir / ("orch.cmd" if IS_WINDOWS else "orch")).exists():
        return ("the launcher exists in ~/.local/bin, but that folder is not on PATH: add it, then open a new terminal "
                "(README: If orch isn't found)")
    if IS_WINDOWS:
        return "bash install.sh (creates the orch and orch.cmd launchers in ~/.local/bin)"
    return "ln -s %s ~/.local/bin/orch" % Path(__file__).resolve()


def launcher_python_warning(home=None):
    """The doctor warning for the Git Bash launcher in ~/.local/bin/orch: a bare interpreter command that resolves to
    the Microsoft Store alias, or an interpreter path that is gone, makes every `orch` call slower (about 0.2 s a
    start) or impossible; re-running install.sh records the current interpreter. None on POSIX (a symlink), when the
    launcher is missing and when it is fine."""
    try:
        path = Path(home or Path.home()) / ".local" / "bin" / "orch"
        if path.is_symlink():
            return None                 # POSIX install: a symlink to bin/orch, no interpreter named
        with path.open(encoding="utf-8", errors="replace") as f:
            if f.readline().strip() != "#!/bin/sh":
                return None
            match = None
            for line in f:
                match = re.match(r"\s*exec\s+(?:\"([^\"]+)\"|'([^']+)'|(\S+))", line)
                if match:
                    break
    except (OSError, RuntimeError):
        return None
    if not match:
        return None
    exe = match.group(1) or match.group(2) or match.group(3)
    if "/" not in exe and "\\" not in exe:      # the launcher of an older install: the bare command name
        import shutil
        resolved = shutil.which(exe)
        if resolved and "windowsapps" in resolved.replace("\\", "/").lower():
            return ("runs the Microsoft Store alias %s (%s): every orch call pays about 0.2 s more; re-run "
                    "`bash install.sh` to record the real interpreter" % (exe, resolved))
        return None
    if not Path(exe).exists():
        return ("records %s, which does not exist: orch does not start; re-run `bash install.sh` to record the "
                "current interpreter" % exe)
    return None


def cmd_doctor(a):
    import shutil
    import subprocess
    ok = True

    def row(name, good, info, optional=False):
        nonlocal ok
        ok = ok and (good or optional)
        print("%s %-22s %s" % ("✔" if good else "·" if optional else "✘", name, info))

    row("platform", True, platform_name())
    row("python", sys.version_info >= (3, 8), sys.version.split()[0])
    row("git", bool(shutil.which("git")), shutil.which("git") or "not found")
    if IS_WINDOWS:
        bash = find_bash()
        row("bash (shell adapters)", bool(bash), bash or "needed only for shell adapters: Git for Windows", optional=True)
    cx, note = find_codex()
    row("Codex CLI", bool(cx), (cx + note) if cx else "optional: npm i -g @openai/codex && codex login (or ORCH_CODEX_BIN)",
        optional=True)
    if cx:
        try:
            r = subprocess.run(exe_command(cx) + ["login", "status"], capture_output=True, text=True, timeout=20,
                               stdin=subprocess.DEVNULL)
            row("Codex login", r.returncode == 0, (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else "?")
        except Exception as ex:
            row("Codex login", False, str(ex))
    cl = os.environ.get("ORCH_CLAUDE_BIN") or shutil.which("claude")
    row("Claude CLI (headless)", bool(cl), cl or "needed for the DeepSeek and Claude executors and orch launch",
        optional=True)
    if os.environ.get("ORCH_LEAD"):
        row("lead", True, "%s · %s %s" % (scope_name(os.environ["ORCH_LEAD"]),
                                          display_name(os.environ.get("ORCH_LEAD_MODEL")) or "?", lead_via_text()))
    src = key_origin("DEEPSEEK_API_KEY")
    row("DEEPSEEK_API_KEY", bool(src), ("set: " + src) if src else "missing — add a line DEEPSEEK_API_KEY=sk-… to %s"
        % SECRETS_FILE, optional=True)
    data, err = load_profiles()
    if err:
        row("profiles", False, err)
    elif PROFILES_FILE.exists():
        row("profiles", True, str(PROFILES_FILE))
        for provider in sorted(data["providers"]):
            for name, d in provider_section(data, provider)[1].items():
                d = d if isinstance(d, dict) else {}
                if d.get("key"):
                    src = key_origin(d["key"])
                    row("%s@%s key" % (display_name(provider), name), bool(src), ("%s set: %s" % (d["key"], src)) if src else
                        "missing — add a line %s=… to %s" % (d["key"], SECRETS_FILE), optional=True)
                if provider == "codex" and d.get("home") and not d.get("key") and cx:
                    home = local_path(str(d["home"]))
                    try:
                        r = subprocess.run(exe_command(cx) + ["login", "status"], capture_output=True, text=True,
                                           timeout=20, stdin=subprocess.DEVNULL,
                                           env=dict(os.environ, CODEX_HOME=home))
                        info = ((r.stdout or r.stderr).strip().splitlines() or ["?"])[0]
                        row("Codex@%s login" % name, r.returncode == 0, info if r.returncode == 0 else
                            "%s — %s" % (info, login_hint(home)), optional=True)
                    except Exception as ex:
                        row("Codex@%s login" % name, False, str(ex), optional=True)
    row("orch on PATH", bool(shutil.which("orch")), shutil.which("orch") or orch_path_hint())
    note = launcher_python_warning()
    if note:
        print("⚠ %-22s %s" % ("orch launcher", note))
    row("registry", registry_path().exists(), str(registry_path()))
    note = registry_stale_note()
    if note:
        print("⚠ %-22s %s" % ("registry copy", note))
    row("adapters", True, ", ".join(sorted({p.name for b in (ORCH_HOME / "adapters", PLUGIN_ROOT / "adapters")
                                             if b.exists() for p in b.iterdir()
                                             if p.is_file() and not p.name.startswith(("_", "."))})) or "none")
    clip = next((c for c in ("clip.exe", "wl-copy", "xclip", "pbcopy") if shutil.which(c)), None)
    row("clipboard (optional)", True, clip or "none — copy the paste line by hand")
    return 0 if ok else 1


