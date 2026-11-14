# ───────────────────────── Codex subscription limits (read from its session logs) ─────────────────────────
#
# Codex writes session logs to $CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl; a token_count event carries
# `rate_limits` (5-hour and weekly windows by window_minutes). The format is undocumented — parse defensively:
# anything unexpected means "no data", never an error. `orch statusline` caches the newest windows per account in
# ~/.lanewise/codex_usage.json, keyed by the effective CODEX_HOME (so a profile with --home has its own entry);
# `orch run codex` refreshes right after finishing. A window whose reset has passed counts as absent.

CODEX_USAGE_FILE = ORCH_HOME / "codex_usage.json"
CODEX_TAIL_BYTES = 256 * 1024
CODEX_REFRESH_SECONDS = 60
CODEX_WINDOWS = ((300, "five_hour"), (10080, "seven_day"))


def codex_home(where=None, prof=None):
    """Effective CODEX_HOME: the profile's --home (account) or the environment / the default ~/.codex.
    A resolved `prof` (the run's own profile) is used when given, so `--profile` is honoured."""
    home = os.environ.get("CODEX_HOME")
    try:
        p = prof if prof is not None else resolve_profile("codex", where or project_dir())
        if p.name != "off" and p.data.get("home"):
            home = local_path(str(p.data["home"]))
    except ProfileError:
        pass
    return str(Path(home).expanduser()) if home else str(Path.home() / ".codex")


def codex_rollouts(home, days=3, per_day=3):
    """Newest rollout files: the latest date directories first, a bounded few only."""
    sessions = Path(home) / "sessions"
    if not sessions.is_dir():
        return []
    day_dirs = []
    for y in sessions.iterdir():
        if not y.is_dir() or not y.name.isdigit():
            continue
        for m in y.iterdir():
            if not m.is_dir() or not m.name.isdigit():
                continue
            for d in m.iterdir():
                if d.is_dir() and d.name.isdigit():
                    day_dirs.append(d)
    day_dirs.sort(key=lambda d: (d.parent.parent.name, d.parent.name, d.name), reverse=True)
    out = []
    for d in day_dirs[:days]:
        try:
            found = sorted(d.glob("rollout-*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)
        except OSError:
            continue
        out.extend(found[:per_day])
    return out


def tail_lines(path, max_bytes):
    """The last `max_bytes` of a file, as lines, with the first partial line dropped."""
    try:
        size = path.stat().st_size
        start = max(0, size - max_bytes)
        with path.open("rb") as f:
            f.seek(start)
            data = f.read()
    except OSError:
        return []
    if start > 0:
        nl = data.find(b"\n")
        if nl != -1:
            data = data[nl + 1:]
    return data.decode("utf-8", "replace").splitlines()


def codex_event_limits(line):
    """(measured, {window_minutes: {used, resets_at}}, plan_type) of one rollout line, or None."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    if not isinstance(ev, dict) or ev.get("type") != "event_msg":
        return None
    measured = parse_iso(str(ev.get("timestamp") or "").replace("Z", "+00:00"))
    payload = ev.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None
    rl = payload.get("rate_limits")
    if not isinstance(rl, dict) or measured is None:
        return None
    windows = {}
    for name in ("primary", "secondary"):
        w = rl.get(name)
        if not isinstance(w, dict):
            continue
        wm = w.get("window_minutes")
        used = w.get("used_percent")
        if used is None:
            used = w.get("used")
        resets = epoch_iso(w.get("resets_at"))
        if not isinstance(wm, (int, float)) or not isinstance(used, (int, float)) or resets is None:
            continue
        windows[int(wm)] = {"used": float(used), "resets_at": resets}
    if not windows:
        return None
    return measured, windows, rl.get("plan_type")


def codex_work_model(model):
    """The model id, or None for no model or for Codex's internal auto-review step (`codex-auto-review`), which
    runs between the operator's own turns and is not the model they work with."""
    m = str(model).strip() if model else ""
    return None if not m or "auto-review" in m.lower() else m


def codex_event_model(line):
    """The model of a `turn_context` event (the last turn), or None; the internal auto-review model is ignored,
    so the last real model of the tail stays."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    if not isinstance(ev, dict) or ev.get("type") != "turn_context":
        return None
    payload = ev.get("payload")
    if not isinstance(payload, dict):
        return None
    return codex_work_model(payload.get("model"))


def scan_codex_limits(home):
    """The newest windows seen in the newest rollout tails, plus the last turn's model; or None when nothing is
    readable. The model comes from the same file that gave the limits; only the tail of each file is read."""
    try:
        best = None
        model = None
        for f in codex_rollouts(home):
            file_model = None
            for line in tail_lines(f, CODEX_TAIL_BYTES):
                m = codex_event_model(line)
                if m:
                    file_model = m
                ev = codex_event_limits(line)
                if ev and (best is None or ev[0] > best[0]):
                    best = (ev[0], ev[1], ev[2], f)
            if best is not None and best[3] == f:
                model = file_model
        if best is None:
            return None
        return best[0], best[1], best[2], model
    except OSError:
        return None


def codex_windows(measured, windows, plan_type):
    """Cache entry {five_hour: {…}, seven_day: {…}, plan_type} with each window's own measurement time."""
    out = {}
    for wm, name in CODEX_WINDOWS:
        w = windows.get(wm)
        if w and parse_iso(w["resets_at"]) > now():
            out[name] = {"used": w["used"], "resets_at": w["resets_at"], "measured": iso(measured)}
    if plan_type:
        out["plan_type"] = str(plan_type)
    return out


def read_codex_cache(home):
    """(whole cache, this account's entry)."""
    snap = read_json(CODEX_USAGE_FILE, {}, recover_corrupt=True)
    if not isinstance(snap, dict):
        snap = {}
    return snap, snap.get(home) if isinstance(snap.get(home), dict) else {}


def codex_scanned_recently(snap, home, entry):
    """True within the throttle of the last finished scan, or of a scan that was started: a scan that finds nothing
    updates no entry, and a run killed mid-scan none at all."""
    started = snap.get("scanning") if isinstance(snap.get("scanning"), dict) else {}
    t = now()
    for stamp in (entry.get("updated"), started.get(home)):
        when = parse_iso(stamp) if isinstance(stamp, str) else None
        if when and (t - when).total_seconds() < CODEX_REFRESH_SECONDS:
            return True
    return False


def refresh_codex(where=None, force=False, prof=None):
    """Update the cached Codex windows; one scan a minute per account (unless forced), by all sessions together, however
    the scan ends. The scan runs outside the lock. Returns the (possibly empty) entry. A busy lock raises StateError."""
    home = codex_home(where, prof)
    snap, entry = read_codex_cache(home)
    if not force and codex_scanned_recently(snap, home, entry):
        return entry
    if not (Path(home) / "sessions").is_dir():
        return entry                     # no rollouts at all: this check is the whole scan, nothing to throttle
    with state_lock(ORCH_HOME / ".state.lock"):
        snap, entry = read_codex_cache(home)
        if not force and codex_scanned_recently(snap, home, entry):
            return entry
        started = snap.get("scanning") if isinstance(snap.get("scanning"), dict) else {}
        started[home] = iso(now())
        snap["scanning"] = started
        write_json(CODEX_USAGE_FILE, snap)
    scanned = scan_codex_limits(home)
    if scanned is None:
        return entry
    measured, windows, plan_type, model = scanned
    with state_lock(ORCH_HOME / ".state.lock"):
        snap, entry = read_codex_cache(home)
        old_model = codex_work_model(entry.get("model"))      # an entry saved with the auto-review model: none
        old_week_history = entry.get("week_history")
        entry = codex_windows(measured, windows, plan_type)
        if model:
            entry["model"] = model
        elif old_model:
            entry["model"] = old_model       # a turn_context scrolled out of the tail: keep the last seen model
        entry["week_history"] = week_history_update(old_week_history, entry.get("seven_day"), measured)
        entry["updated"] = iso(now())
        snap[home] = entry
        t = now()      # drop accounts untouched for over a day (but keep the 💡 announcement state)
        announced = snap.get("announced")
        started = snap.get("scanning") if isinstance(snap.get("scanning"), dict) else {}
        started = {k: v for k, v in started.items() if k != home and isinstance(v, str) and parse_iso(v)
                   and (t - parse_iso(v)).total_seconds() < 86400}
        snap = {k: v for k, v in snap.items() if k != "scanning" and isinstance(v, dict) and (k == home or (
            parse_iso(v.get("updated") or "") and (t - parse_iso(v["updated"])).total_seconds() < 86400))}
        if isinstance(announced, dict):
            snap["announced"] = announced
        if started:
            snap["scanning"] = started
        write_json(CODEX_USAGE_FILE, snap)
    return entry


def codex_reserve(where=None):
    """reserve / week_reserve (%) from the codex profile, else 10/10; None when Codex is off for the project."""
    out = {"reserve": 10, "week_reserve": 10}
    try:
        prof = resolve_profile("codex", where or project_dir())
    except ProfileError as ex:
        if str(PROFILES_FILE) in str(ex):
            warn_state(PROFILES_FILE, str(ex))
        return out
    if prof.name == "off":
        return None
    if prof.explicit and prof.data.get("key"):
        return None          # API-billed: no subscription limits to show
    for k in out:
        v = str(prof.data.get(k, out[k])).lower()
        out[k] = 0 if v in ("off", "no", "false") else int(v) if v.isdigit() else out[k]
    return out


def codex_window(entry, name):
    """(used %, reset time, measured time) while the window is current; None once it has reset or has no data."""
    w = entry.get(name) if isinstance(entry.get(name), dict) else {}
    if w.get("used") is None:
        return None
    reset = parse_iso(w.get("resets_at") or "")
    if reset and reset <= now():
        return None
    return float(w["used"]), reset, parse_iso(w.get("measured") or "")


def codex_projected(used, reset, measured, window_minutes):
    """Projected used % at the reset, from the window average; None when it cannot be computed or when fewer
    than PROJECTION_MIN_ELAPSED minutes of the window have passed at the measurement (too early to tell)."""
    if reset is None or measured is None:
        return None
    elapsed = (measured - (reset - dt.timedelta(minutes=window_minutes))).total_seconds() / 60.0
    if elapsed < PROJECTION_MIN_ELAPSED:
        return None
    return used * window_minutes / elapsed


def codex_projections(entry):
    """{window: share at its reset} from the Codex budget's own estimates (codex_projected for the 5-hour window,
    week_rate for the week), never below the used share. A window without one is absent: too little data, no rate,
    or a stale measurement."""
    out, t = {}, now()
    for name, hours in (("five_hour", 5), ("seven_day", 7)):
        w = codex_window(entry, name)
        if not w:
            continue
        used, reset, m = w
        if m is None or (t - m).total_seconds() > USAGE_FRESH_SECONDS:
            continue
        if hours == 5:
            proj = codex_projected(used, reset, m, 300)
        else:
            rate, _ = week_rate(entry.get("week_history"), used, reset, m)
            proj = projected_at_reset(used, reset, rate, m) if rate is not None else None
        if proj is not None:
            out[name] = max(used, proj)
    return out


def codex_state(where=None):
    """(cfg, home, entry) of the Codex budget for a directory; (None, None, None) when Codex is off."""
    cfg = codex_reserve(where)
    if cfg is None:
        return None, None, None
    home = codex_home(where)
    snap = read_json(CODEX_USAGE_FILE, {}, recover_corrupt=True)
    entry = snap.get(home) if isinstance(snap, dict) else None
    if not isinstance(entry, dict):
        entry = None
    return cfg, home, entry


def codex_budget(where=None):
    """(mode, line) of the Codex subscription: TIGHT when a window's used share or its projection reaches its
    reserve (a weekly projection counts only after 24 h). No current data → no line and no mode."""
    try:
        refresh_codex(where)     # at most once a minute; routing must not depend on a status line being configured
    except Exception:
        pass
    cfg, _, entry = codex_state(where)
    if cfg is None or not entry:
        return "unknown", None
    five = codex_window(entry, "five_hour")
    week = codex_window(entry, "seven_day")
    if not five and not week:
        return "unknown", None
    parts = []
    tight = False
    measured = None
    if five:
        used, reset, m = five
        measured = m or measured
        cap = 100 - cfg["reserve"]
        proj = codex_projected(used, reset, m, 300)
        if used >= cap or (proj is not None and proj >= cap):
            tight = True
        parts.append("5-hour window %d%% used, resets %s" % (pct(used), reset.astimezone().strftime("%H:%M")))
    if week:
        used, reset, m = week
        measured = min(measured, m) if measured and m else (m or measured)    # the older of the two windows
        cap = 100 - week_reserve(cfg["week_reserve"], reset, m)
        rate, _ = week_rate(entry.get("week_history"), used, reset, m)
        weekly = max(used, projected_at_reset(used, reset, rate, m)) if rate is not None else used
        elapsed = (m - (reset - dt.timedelta(minutes=10080))).total_seconds() if m and reset else 0
        if used >= cap or (elapsed >= 86400 and weekly >= cap):
            tight = True
        parts.append("week %d%%" % pct(used) + (", resets %s" % reset.astimezone().strftime("%b %d %H:%M")
                                               if reset else ""))
    line = "Codex subscription: " + ", ".join(parts)
    if measured and is_stale(measured):   # an old measurement says how old and what refreshes it (nothing is fetched)
        line += " (measured %s, %s; stale: the next Codex run refreshes it)" % (watch_clock(measured),
                                                                               human_delta(measured))
    elif measured:
        line += " (measured %s)" % measured.astimezone().strftime("%H:%M")
    line += "."
    if tight:
        line += " TIGHT: treat Codex as low; offload to other providers."
    return ("tight" if tight else "normal"), line


def codex_short_mode(cfg, entry, week_shown=False):
    """The compact Codex mode text: 'tight: week' while the week's projection stands beside the window (week_shown),
    else 'tight: week N% projected'; 'tight: week over reserve', 'tight: 5h', or None. Mirrors codex_budget: a
    weekly cap is checked first, then the five-hour window."""
    five = codex_window(entry, "five_hour")
    week = codex_window(entry, "seven_day")
    if week:
        used, reset, m = week
        cap = 100 - week_reserve(cfg["week_reserve"], reset, m)
        if used >= cap:
            return "tight: week over reserve"
        rate, _ = week_rate(entry.get("week_history"), used, reset, m)
        weekly = max(used, projected_at_reset(used, reset, rate, m)) if rate is not None else used
        elapsed = (m - (reset - dt.timedelta(minutes=10080))).total_seconds() if m and reset else 0
        if elapsed >= 86400 and rate is not None and weekly >= cap:
            return "tight: week" if week_shown else "tight: week %d%% projected" % pct(weekly)
    if five:
        used, reset, m = five
        cap = 100 - cfg["reserve"]
        proj = codex_projected(used, reset, m, 300)
        if used >= cap or (proj is not None and proj >= cap):
            return "tight: 5h"
    return None


def codex_status_part(where=None):
    """Compact Codex limits part of the second status line ('GPT-6.1 Terra · 5h 81% (≈90%) → 18:28 · week 95%'),
    built by the same provider_line helper as Claude; or None with no data."""
    cfg, _, entry = codex_state(where)
    if cfg is None or not entry:
        return None
    five = codex_window(entry, "five_hour")
    week = codex_window(entry, "seven_day")
    stamps = [w[2] for w in (five, week) if w and w[2]]
    measured = min(stamps) if stamps else None     # the older of the windows shown
    projections = codex_projections(entry)
    m = codex_work_model(entry.get("model"))
    name = (display_name(m) if m else None) or m or "Codex"   # a known id → display name, an unknown id as-is, no model → Codex
    return provider_line(
        name,
        (five[0], five[1]) if five else None,
        (week[0], week[1]) if week else None,
        codex_short_mode(cfg, entry, week_shown="seven_day" in projections),
        measured,
        five_projection=projections.get("five_hour"),
        week_projection=projections.get("seven_day"),
    )


@locked("home")
def codex_event(session, announce=True):
    """A hook event when this session's Codex budget mode changes (tight / normal), once per change."""
    mode, line = codex_budget()
    if mode == "unknown":
        return None
    snap = read_json(CODEX_USAGE_FILE, {}, recover_corrupt=True)
    if not isinstance(snap, dict):
        snap = {}
    seen = snap.get("announced") if isinstance(snap.get("announced"), dict) else {}
    key = session or "-"
    if seen.get(key) == mode:
        return None
    seen.pop(key, None)
    seen[key] = mode
    snap["announced"] = dict(list(seen.items())[-30:])
    write_json(CODEX_USAGE_FILE, snap)
    return ("💡 " + line) if announce else None


