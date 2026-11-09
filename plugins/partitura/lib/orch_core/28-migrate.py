# ───────────────────────── migrate (.orchestra → .partitura) ─────────────────────────
#
# The folders were named .orchestra before 0.35.0. orch still reads them where they are (00-header.py and
# state_dir_name in 02-official-names.py); this command moves a project's state folder and the personal folder to the
# new name and points what is stored inside at the new path. A dry run is the default: nothing changes without --yes.

HOME_LOCKS = (".state.lock", ".settings.lock", ".usage.lock", ".session_budget.lock")
HOME_SKIP_JSON = ("sessions.json", "session_budget.json")     # session bookkeeping: no home paths to rewrite
RUN_STALE_S = 24 * 3600      # an unfinished run older than this was killed (no run lasts a day): it blocks nothing


def _pid_alive(pid):
    """Whether the process still exists. On Windows os.kill(pid, 0) would terminate it, so ask tasklist."""
    import subprocess
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if IS_WINDOWS:
        try:
            r = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL)
        except OSError:
            return False
        return bool(re.search(r"\b%d\b" % pid, r.stdout or ""))
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True              # it exists: this user may not signal it
    except OSError:
        return False


def state_meta_files(state):
    """(meta.json path, raw on-disk meta) of every manual task in a state folder, in id order. The stored form of the
    paths is kept: rewriting must write it back, not an absolute form."""
    root = Path(state) / "handoffs"
    out = []
    if not root.is_dir():
        return out
    for d in sorted(root.iterdir()):
        p = d / "meta.json"
        if not d.is_dir() or not p.is_file():
            continue
        try:
            m = read_json(p, None, object_required=True)
        except StateError as ex:
            print("    %s: unreadable, left as is (%s)" % (p, ex))
            continue
        if m:
            out.append((p, m))
    return out


def state_run_files(state):
    """(run id, raw meta) of every automated run in a state folder, in id order."""
    root = Path(state) / "runs"
    out = []
    if not root.is_dir():
        return out
    for d in sorted(root.iterdir()):
        p = d / "meta.json"
        if not d.is_dir() or not p.is_file():
            continue
        try:
            m = read_json(p, None, object_required=True)
        except StateError:
            continue
        if m:
            out.append((d.name, m))
    return out


def project_blocker(state):
    """Why a project's state folder cannot move right now, else None: a manual task is handed out and not finished
    (its agent writes RESULT.md to the old path), or an orch run that has not finished still has a live process."""
    base = Path(state).parent
    for _, raw in state_meta_files(state):
        m = meta_abs(raw, base)
        if result_status(m) in OPEN_TAKEN:
            return ("%s is handed out and not finished (its agent writes RESULT.md to the old folder): finish or "
                    "cancel it first (orch handoff done %s)" % (m.get("id", "?"), m.get("id", "?")))
    for run_id, raw in state_run_files(state):
        if raw.get("finished"):
            continue
        started = parse_iso(raw.get("started")) if isinstance(raw.get("started"), str) else None
        if started is not None and (now() - started).total_seconds() > RUN_STALE_S:
            continue                 # a run killed long ago: its pid may belong to another process by now
        if _pid_alive(raw.get("pid")):
            return ("run %s is still going (pid %s): wait for it to finish, then run orch migrate again"
                    % (run_id, raw["pid"]))
    return None


def _new_state_path(v):
    """A stored path that names the old folder at its start, under the new name. Anything else is left as is."""
    old, new = LEGACY_STATE_DIR_NAME, STATE_DIR_NAME
    if not isinstance(v, str) or not v:
        return v
    for sep in ("/", "\\"):
        if v == old:
            return new
        if v.startswith(old + sep):
            return new + v[len(old):]
    return v


def rewrite_state_metas(metas):
    """Point every handoff meta.json at the new name: the stored path fields and the paste line. `metas` is
    state_meta_files() of the state folder. Returns how many files changed."""
    changed = 0
    for p, m in metas:
        dirty = False
        for f in META_PATH_FIELDS:
            v = m.get(f)
            nv = _new_state_path(v)
            if nv != v:
                m[f] = nv
                dirty = True
        paste = m.get("paste")
        if isinstance(paste, str):
            np_ = paste.replace(LEGACY_STATE_DIR_NAME + "/", STATE_DIR_NAME + "/")
            if np_ != paste:
                m["paste"] = np_
                dirty = True
        if dirty:
            write_json(p, m)
            changed += 1
    return changed


def worktree_dirs(state):
    root = Path(state) / "wt"
    return sorted(d for d in root.iterdir() if d.is_dir()) if root.is_dir() else []


def repair_worktrees(proj, state):
    """Repair the worktrees moved with the state folder, then check git sees them at the new paths.
    (repaired count, problem text or None)."""
    wts = worktree_dirs(state)
    if not wts:
        return 0, None
    r = git(["rev-parse", "--is-inside-work-tree"], proj)
    if r is None or r.returncode != 0 or r.stdout.strip() != "true":
        return 0, None           # no repository: the folders were left by something else, nothing git can repair
    r = git(["worktree", "repair"] + [str(w) for w in wts], proj)
    if r is None or r.returncode != 0:
        why = (r.stderr.strip().splitlines() or [""])[0] if r is not None else "git not found"
        return 0, ("git worktree repair failed (%s); if git is older than 2.30, run it by hand: git worktree repair %s"
                   % (why, " ".join(str(w) for w in wts)))
    listed = set()
    r = git(["worktree", "list", "--porcelain"], proj)
    if r is not None and r.returncode == 0:
        for line in r.stdout.splitlines():
            if line.startswith("worktree "):
                listed.add(os.path.normcase(str(Path(line[len("worktree "):]).resolve())))
    broken = []
    for w in wts:
        status = git(["status", "--porcelain"], w)
        if os.path.normcase(str(w.resolve())) not in listed or status is None or status.returncode != 0:
            broken.append(str(w))
    if broken:
        return len(wts) - len(broken), ("git still does not see %s at its new path: check git worktree list, and run "
                                        "git worktree repair %s" % (", ".join(broken), " ".join(broken)))
    return len(wts), None


def _exclude_text(excl):
    """The exclude file's text with its line endings kept (read_text would turn CRLF into LF)."""
    try:
        with excl.open(encoding="utf-8", newline="") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except OSError:
        return None


def exclude_plan(proj):
    """What moving the folder does to .git/info/exclude: replace the old line, add the new one, or nothing."""
    excl = git_exclude_file(proj)
    if excl is None:
        return None
    text = _exclude_text(excl)
    if text is None:
        return None
    lines = [line.strip() for line in text.splitlines()]
    old_line, new_line = LEGACY_STATE_DIR_NAME + "/", STATE_DIR_NAME + "/"
    if old_line in lines:
        return "replace %s with %s in %s" % (old_line, new_line, excl)
    if new_line not in lines:
        return "add %s to %s" % (new_line, excl)
    return None


def move_exclude_line(proj):
    """Point the git exclude at the new folder name: replace the old line, or add the new one when it is missing;
    every other line stays. Returns what was done, or None."""
    excl = git_exclude_file(proj)
    if excl is None:
        return None
    text = _exclude_text(excl)
    if text is None:
        return None
    old_line, new_line = LEGACY_STATE_DIR_NAME + "/", STATE_DIR_NAME + "/"
    out, replaced = [], False
    for line in text.splitlines(True):
        body = line.rstrip("\r\n")
        if body == old_line:
            if not replaced:
                out.append(new_line + line[len(body):])
                replaced = True
            continue
        out.append(line)
    new_text = "".join(out)
    if new_text != text:
        excl.parent.mkdir(parents=True, exist_ok=True)
        with excl.open("w", encoding="utf-8", newline="") as f:
            f.write(new_text)
    if new_line not in new_text.split():
        ensure_git_exclude(proj, (new_line,))
        return "added %s (it was missing)" % new_line
    return "%s → %s" % (old_line, new_line) if replaced else None


def regenerate_board(proj):
    """Rewrite the project's MANUAL.md with the existing writer (it reads its project from the environment).
    Never fails: the board is a view."""
    old = os.environ.get("ORCH_PROJECT_DIR")
    os.environ["ORCH_PROJECT_DIR"] = str(proj)
    try:
        write_board()
        return True
    except Exception:
        return False
    finally:
        if old is None:
            os.environ.pop("ORCH_PROJECT_DIR", None)
        else:
            os.environ["ORCH_PROJECT_DIR"] = old


def migrate_project(proj, apply):
    """Move one project's state folder to the new name and point what is stored there at it. True when the project is
    done (moved, or nothing to move); False when it was skipped or failed."""
    proj = Path(proj)
    old, new = proj / LEGACY_STATE_DIR_NAME, proj / STATE_DIR_NAME
    if not proj.is_dir():
        print("✘ %s — no such folder; nothing moved" % proj)
        return False
    if new.exists() and old.exists():
        print("✘ %s — both %s/ and %s/ exist: nothing was merged; keep one of them, then run orch migrate again"
              % (proj, LEGACY_STATE_DIR_NAME, STATE_DIR_NAME))
        return False
    if new.exists():
        print("· %s — nothing to move (it uses %s/ already)" % (proj, STATE_DIR_NAME))
        return True
    if not old.exists():
        print("· %s — no state folder; nothing to move" % proj)
        return True
    blocker = project_blocker(old)
    if blocker:
        print("✘ %s — skipped: %s; nothing changed" % (proj, blocker))
        return False
    metas = state_meta_files(old)
    wts = worktree_dirs(old)
    if not apply:
        print("would move %s → %s" % (old, new))
        if metas:
            print("    %d handoff meta.json file(s): stored paths and paste lines to the new name" % len(metas))
        if wts:
            print("    %d git worktree(s) to repair" % len(wts))
        plan = exclude_plan(proj)
        if plan:
            print("    " + plan)
        if (proj / AG_RULE_PATH).is_file():
            print("    rewrite %s" % AG_RULE_PATH)
        if metas:
            print("    regenerate %s/MANUAL.md" % STATE_DIR_NAME)
        return True
    try:
        os.rename(str(old), str(new))
    except OSError as ex:
        print("✘ %s — cannot move: busy, try again (%s); nothing changed" % (proj, ex))
        return False
    print("moved %s → %s" % (old, new))
    ok = True
    moved_metas = state_meta_files(new)
    changed = rewrite_state_metas(moved_metas)
    if changed:
        print("    meta.json: %d file(s) now name %s" % (changed, STATE_DIR_NAME))
    repaired, problem = repair_worktrees(proj, new)
    if repaired:
        print("    worktrees: %d repaired" % repaired)
    if problem:
        print("    ! worktrees: %s" % problem)
        ok = False
    note = move_exclude_line(proj)
    if note:
        print("    .git/info/exclude: %s" % note)
    if (proj / AG_RULE_PATH).is_file():
        ensure_ag_rule(proj, list(dict.fromkeys(name for _, name, _ in instruction_files(proj))))
        print("    %s: rewritten for %s/" % (AG_RULE_PATH, STATE_DIR_NAME))
    if moved_metas:
        print("    MANUAL.md: regenerated" if regenerate_board(proj) else
              "    MANUAL.md: not regenerated (it is rewritten on the next task event)")
    return ok


def known_projects():
    """Project roots the plugin knows of: the ledger's project_path values, the keys of profiles.json's `projects`
    and `project_rules`, and the current project. Only folders that still exist."""
    seen, out = set(), []

    def add(value):
        if not value:
            return
        try:
            path = Path(local_path(str(value)))
        except (OSError, ValueError):
            return
        if not path.is_dir():
            return
        key = os.path.normcase(str(path.resolve()))
        if key not in seen:
            seen.add(key)
            out.append(path)

    for rec in ledger_read():
        add(rec.get("project_path"))
    data, err = load_profiles()
    if not err:
        for section in ("projects", "project_rules"):
            for key in (data.get(section) or {}):
                add(key)
    add(project_dir())              # the state folder lives in the working tree the command runs in
    return out


def _rewrite_home_strings(value, old_home, new_home):
    """(new value, changed): every path string that names the old home now names the new one, in its native and
    forward-slash forms and in the `~/.orchestra` form. The match ends at a separator, so `.orchestra2` stays."""
    if isinstance(value, str):
        forms = []
        for o, n in ((str(old_home), str(new_home)),
                     (str(old_home).replace("\\", "/"), str(new_home).replace("\\", "/")),
                     ("~/" + LEGACY_STATE_DIR_NAME, "~/" + STATE_DIR_NAME)):
            if o and (o, n) not in forms:
                forms.append((o, n))
        text = value
        for o, n in forms:
            text = re.sub(re.escape(o) + r"(?=$|[\\/])", lambda m: n, text)
        return text, text != value
    if isinstance(value, list):
        out, changed = [], False
        for item in value:
            new_item, item_changed = _rewrite_home_strings(item, old_home, new_home)
            out.append(new_item)
            changed = changed or item_changed
        return out, changed
    if isinstance(value, dict):
        out, changed = {}, False
        for key, item in value.items():
            new_item, item_changed = _rewrite_home_strings(item, old_home, new_home)
            out[key] = new_item
            changed = changed or item_changed
        return out, changed
    return value, False


def rewrite_home_json(root, old_home, new_home, apply):
    """Rewrite paths into the old home in the JSON files at a home's top level (profiles.json and the like): the usage
    ledger and the session files hold none and are left alone. Returns how many files changed (or would)."""
    changed = 0
    for p in sorted(Path(root).glob("*.json")):
        if p.name in HOME_SKIP_JSON or not p.is_file():
            continue
        try:
            data = read_json(p, None)
        except StateError as ex:
            print("    %s: unreadable, left as is (%s)" % (p.name, ex))
            continue
        if data is None:
            continue
        new_data, dirty = _rewrite_home_strings(data, old_home, new_home)
        if dirty:
            changed += 1
            if apply:
                write_json(p, new_data)
    return changed


def home_idle(home, create):
    """True when no orch process holds one of the home's locks. With create=False (a dry run) only locks that exist are
    tried, so the check leaves no files behind."""
    import contextlib
    try:
        with contextlib.ExitStack() as stack:
            for name in HOME_LOCKS:
                path = Path(home) / name
                if not create and not path.exists():
                    continue
                stack.enter_context(state_lock(path, wait=0))
        return True
    except StateError:
        return False


def migrate_home(apply):
    """Move ~/.orchestra to ~/.partitura, when ORCH_HOME does not decide the home. True when done or nothing to move."""
    if os.environ.get("ORCH_HOME"):
        print("· home — ORCH_HOME is set: it decides the personal folder; nothing to move")
        return True
    home = Path.home()
    old, new = home / LEGACY_STATE_DIR_NAME, home / STATE_DIR_NAME
    if new.exists():
        if old.exists():
            print("✘ home — both %s and %s exist: nothing was merged; keep one of them, then run orch migrate --home "
                  "again" % (old, new))
            return False
        print("· home — nothing to move (it is %s)" % new)
        return True
    if not old.is_dir():
        print("· home — no %s; nothing to move" % old)
        return True
    if not home_idle(old, create=apply):
        print("✘ home — skipped: an orch process is using %s (busy, try again); nothing changed" % old)
        return False
    if not apply:
        print("would move %s → %s" % (old, new))
        changed = rewrite_home_json(old, old, new, apply=False)
        if changed:
            print("    %d JSON file(s): paths into the old folder to the new one" % changed)
        print("    open sessions: /reload-plugins afterwards")
        return True
    try:
        os.rename(str(old), str(new))
    except OSError as ex:
        print("✘ home — cannot move: busy, try again (%s); nothing changed" % ex)
        return False
    print("moved %s → %s" % (old, new))
    changed = rewrite_home_json(new, old, new, apply=True)
    if changed:
        print("    %d JSON file(s) now name %s (a profile's home folder and the like)" % (changed, STATE_DIR_NAME))
    print("Open Claude Code sessions: run /reload-plugins to pick up the new folder.")
    return True


def cmd_migrate(a):
    if os.environ.get("ORCH_WORKER"):
        raise SystemExit("orch: you are an executor (ORCH_WORKER=%s) — only the orchestrator moves the folders"
                         % os.environ["ORCH_WORKER"])
    apply = bool(a.yes)
    ok = True
    targets = []
    if a.all:
        targets = known_projects()
        if a.path:
            targets.append(Path(a.path).resolve())
    elif a.path:
        targets = [Path(a.path).resolve()]
    elif not a.home:
        targets = [project_dir()]
    for proj in targets:
        ok = migrate_project(proj, apply) and ok
    if a.home:
        ok = migrate_home(apply) and ok
    if not apply and (targets or a.home):
        print("Nothing changed: add --yes to move.")
    return 0 if ok else 1
