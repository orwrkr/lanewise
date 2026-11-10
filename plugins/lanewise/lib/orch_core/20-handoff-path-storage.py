# ───────────────────────── handoff path storage ─────────────────────────
#
# meta.json stores path fields relative to the project root (forward slashes), so a moved project folder or a
# switch between Windows and WSL keeps them valid. In memory the same fields stay absolute native paths: convert
# on load (abs_path) and on save (rel_path); callers never see the on-disk form. An absolute path of the *other*
# OS (a Windows path read under WSL, a /mnt/c/… path read on Windows) is kept verbatim — no guessing at
# conversions; an absolute path under the current root becomes relative on the next save.

META_PATH_FIELDS = ("workdir", "task_path", "result_path")
WINDOWS_ABS_RE = re.compile(r"^[A-Za-z]:[\\/]")


def meta_base(meta_path):
    """Project root that owns a meta.json: <proj>/<state>/handoffs/<hid>/meta.json → <proj> (the state folder is
    .lanewise, or .partitura/.orchestra for a project that keeps an older name). Path arithmetic only (no
    .resolve(): a state-folder symlink must not redirect the project), so it never depends on the cwd."""
    return meta_path.parents[3]


def _looks_absolute(v):
    """Absolute in either OS: /…, \\…, C:\\…, \\\\server\\…. Stored-relative paths never start that way."""
    return v.startswith(("/", "\\")) or bool(WINDOWS_ABS_RE.match(v))


def abs_path(v, base):
    """meta.json value → absolute native path for callers. An absolute path (either OS) is kept verbatim; only a
    stored-relative path is resolved against base."""
    if not v:
        return v
    v = str(v)
    if _looks_absolute(v):
        return v
    return os.path.normpath(str(Path(base) / v))


def _foreign_abs(v):
    """An absolute path of the other OS, not valid here: keep it verbatim on save."""
    if IS_WINDOWS:
        return v.startswith("/")            # /mnt/c/… or any POSIX absolute path
    return bool(WINDOWS_ABS_RE.match(v)) or v.startswith("\\\\")


def rel_path(v, base):
    """in-memory absolute path → meta.json form: relative to base with forward slashes when reachable, else
    absolute as-is (a different drive, or a path of the other OS)."""
    if not v:
        return v
    v = str(v)
    if _foreign_abs(v):
        return v.replace("\\", "/")
    if not Path(v).is_absolute():
        return v.replace("\\", "/")         # already relative (defensive)
    try:
        rel = os.path.relpath(v, str(base))
    except ValueError:
        return v.replace("\\", "/")         # different drive on Windows: no relative form
    return rel.replace("\\", "/")


def meta_abs(m, base):
    """Absolute view of a raw meta dict (a copy; the on-disk form is left untouched)."""
    out = dict(m)
    for f in META_PATH_FIELDS:
        if out.get(f):
            out[f] = abs_path(out[f], base)
    return out


def workdir_win(m):
    """Windows form of the workdir for display, derived from the resolved workdir (never stored)."""
    w = m.get("workdir")
    if not w or IS_WINDOWS:
        return None
    return win_path(w)


def handoffs_root(create=False):
    return state_dir(create=create) / "handoffs"


@locked("project")
def next_handoff_id(prefix):
    root = handoffs_root(create=True)
    root.mkdir(parents=True, exist_ok=True)
    counter = read_json(root / "counter.json", {}, recover_corrupt=True)
    numbers = [int(d.name[len(prefix) + 1:]) for d in root.iterdir()
               if d.name.startswith(prefix + "-") and d.name[len(prefix) + 1:].isdigit()]
    value = counter.get(prefix, 0)
    n = max(numbers + [value if isinstance(value, int) else 0])
    while True:
        n += 1
        hid = "%s-%04d" % (prefix, n)
        try:
            (root / hid).mkdir()    # a reserved id survives a lost/corrupt counter or a failed assignment
            break
        except FileExistsError:
            continue
    counter[prefix] = n
    write_json(root / "counter.json", counter)
    return hid


def load_meta(hid):
    p = handoffs_root() / hid / "meta.json"
    m = read_json(p, None, object_required=True)
    if m is None:
        raise SystemExit("orch: handoff %s not found" % hid)
    return meta_abs(m, meta_base(p))


@locked("project")
def save_meta(m):
    path = handoffs_root() / m["id"] / "meta.json"
    out = dict(m)
    base = meta_base(path)
    for f in META_PATH_FIELDS:
        if f in out:
            out[f] = rel_path(out[f], base)
    write_json(path, out)
    try:
        write_board()
    except Exception:
        pass                         # the board is a view; hooks must never fail because of it


def all_metas():
    root = handoffs_root()
    if not root.exists():
        return []
    base = meta_base(root / "x" / "meta.json")     # the project the handoffs root belongs to, computed once
    out = []
    for d in sorted(root.iterdir()):
        p = d / "meta.json"
        try:
            m = read_json(p, None, object_required=True) if d.is_dir() else None
        except StateError as ex:
            warn_state(p, str(ex))
            continue
        if m:
            out.append(meta_abs(m, base))
    return out


def result_status(m):
    """Status from RESULT.md (or manual override in meta); OFFERED = in the pool, nobody has taken it yet."""
    if m.get("manual_status"):
        return m["manual_status"]
    if m.get("offered") and not m.get("taken"):
        return "OFFERED"
    rp = Path(m["result_path"])
    if rp.exists():
        mt = STATUS_RE.search(rp.read_text(encoding="utf-8", errors="replace")[:2000])
        if mt:
            st = mt.group(1)
            return st if st in TERMINAL + ("IN_PROGRESS",) else "IN_PROGRESS"
        return "IN_PROGRESS"
    return "WAITING"


def agent_reported(m):
    """'AGENT: Antigravity · Gemini 4 Argon' line the executor wrote into RESULT.md."""
    rp = Path(m["result_path"]) if m.get("result_path") else None
    if rp and rp.exists():
        mt = AGENT_RE.search(rp.read_text(encoding="utf-8", errors="replace")[:2000])
        if mt and not mt.group(1).startswith("<"):
            return mt.group(1)[:80]
    return None


def scan_latest_mtime(root, limit=20000):
    latest, seen = 0.0, 0
    for dirpath, dirnames, filenames in os.walk(str(root)):
        dirnames[:] = [d for d in dirnames if d not in SCAN_SKIP]
        for f in filenames:
            seen += 1
            if seen > limit:
                return latest
            try:
                mt = os.path.getmtime(os.path.join(dirpath, f))
            except OSError:
                continue
            if mt > latest:
                latest = mt
    return latest


def taken_at(m):
    return parse_iso(m.get("taken") or m["created"])


def last_activity(m, limit=20000):
    """Latest change after the task was handed out (None if nothing changed). A task in the project folder (no
    `branch`) shares it with other work, so a changed file says nothing about the agent: only its RESULT.md counts.
    A task with a worktree of its own (a branch) is scanned in that worktree."""
    if result_status(m) == "OFFERED" or not m.get("workdir"):
        return None
    rp = Path(m["result_path"])
    if m.get("branch"):
        baseline = max(taken_at(m).timestamp(), m.get("activity_baseline") or 0) + 1.0
        latest = scan_latest_mtime(Path(m["workdir"]), limit)
    else:
        baseline, latest = taken_at(m).timestamp() + 1.0, 0.0
    if rp.exists():
        latest = max(latest, rp.stat().st_mtime)
    if latest <= baseline:
        return None
    return dt.datetime.fromtimestamp(latest).astimezone()


def effective_state(m):
    st = result_status(m)
    if st == "WAITING" and last_activity(m):
        return "STARTED?"   # files changed in workdir but no RESULT.md yet
    return st


def suggestion(m):
    s = agent_name(m.get("provider"))
    if m.get("model"):
        s += " · " + m["model"]
    if m.get("effort"):
        s += " · " + m["effort"]
    return s


def operator_card(m):
    if result_status(m) == "OFFERED":
        lines = ["┌ %s · %s — in the manual pool" % (m["id"], m["title"]),
                 "│ Suggested: %s%s" % (suggestion(m), " (changes files, in its own worktree)" if task_writes(m) else ""),
                 "│ Take it: say “%s to %s” (or /lanewise:manual %s to %s); from a terminal:"
                 " orch handoff take %s — you then get the line to paste."
                 % (m["id"], agent_name(m.get("provider")), m["id"], agent_name(m.get("provider")), m["id"])]
        every = read_json(handoffs_root() / ".pool.json", {}, recover_corrupt=True).get("check_min") or POOL_CHECK_MIN
        lines.append("│ No take from the pool for %d min → the orchestrator starts taking tasks back, one at a time while "
                     "waiting still makes sense%s." % (every, " (this one: %s)" % m["fallback"] if m.get("fallback") else ""))
        lines.append("└ Not needed: “%s: cancel”" % m["id"])
        return "\n".join(lines)
    agent = agent_name(m.get("provider"))
    lines = ["┌ %s · %s" % (m["id"], m["title"])]
    nested = nested_worktree(m)
    if m.get("branch") and not nested:     # a task handed out by an older version, in a worktree next to the project
        lines.append("│ Open in %s: %s" % (agent, m["workdir"]))
    else:
        lines.append("│ In %s, in the project folder: %s" % (agent, project_dir() if nested else m["workdir"]))
    ww = win_path(project_dir()) if nested else workdir_win(m)
    if ww:
        lines.append("│   (Windows path:      %s)" % ww)
    if nested:
        lines.append("│ It works in: %s (its own worktree, branch %s); no need to open it" % (nested, m["branch"]))
    elif m.get("branch"):
        lines.append("│ Branch: %s" % m["branch"])
    model = m.get("model") or "your choice"
    if m.get("effort"):
        model += " · thinking/effort: %s" % m["effort"]
    lines.append("│ Model: %s" % model)
    lines.append("│ Paste into the %s chat:" % agent)
    lines.append("│   %s" % m["paste"])
    lines.append("│ The watcher sees completion via RESULT.md — no need to report back (from a terminal, "
                 "`orch handoff check` picks it up; in a session the hooks do).")
    if m.get("fallback"):
        lines.append("│ Fallback: %s if not started within %d min / not done within %d min." % (
            m["fallback"], m["pickup_min"], m["reassign_min"]))
    lines.append("└ Postpone/cancel: “AG-…: cancel” or orch handoff cancel %s" % m["id"])
    return "\n".join(lines)


