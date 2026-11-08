# ───────────────────────── Claude subscription budget (use it or lose it) ─────────────────────────
#
# Claude Code hands the statusLine command `rate_limits` (5-hour and 7-day windows: % used, reset time). The numbers
# are account-wide: every session on the account is already in them. `orch statusline`, running in every session,
# adds them to a shared snapshot with a short history; the operator can report the same numbers (`orch budget set`).
# The pace is the higher of the window average and the last 30–60 minutes, so the projection follows every instance
# consuming right now. A reserve is kept for other sessions and safety (profile claude: reserve, week_reserve):
# SURPLUS — the window would expire with a lot left beyond the reserve (shared between the active sessions);
# TIGHT — it would reach the reserve before the reset. A five-hour projection (either mode) needs at least
# PROJECTION_MIN_ELAPSED minutes of the window behind it; a used share that has reached the reserve needs none.
# A session that wakes up after a quiet spell reports its own old figures, so a status line reading is dropped when its
# window has already reset, or when it is lower than the stored status line reading of the same window (the same reset,
# not yet passed). The operator's report is a correction and always wins; the next status line reading replaces it.

USAGE_SNAPSHOT = ORCH_HOME / "claude_usage.json"
SESSIONS_FILE = ORCH_HOME / "sessions.json"
BUDGET_DEFAULTS = {"surplus": 30, "reserve": 10, "week_reserve": 10}    # % — profile claude: --opt surplus=N|off, …
PACE_MIN_ELAPSED = 30      # minutes into a week before its average pace is trusted
PROJECTION_MIN_ELAPSED = 60    # minutes of a five-hour window that must have passed before a projection counts
RECENT_PACE = (30, 60)     # the recent pace: the oldest sample 30–60 minutes back
ACTIVE_MIN = 15            # a session seen within this many minutes is active
HISTORY_KEEP_H = 6
WEEK_HISTORY_KEEP_H = 80   # hours a weekly sample is kept (a pace base about 72 h old must still be there)
WEEK_HISTORY_CAP = 400     # most weekly samples kept (one per 15 min over 80 h is 320)
WEEK_HISTORY_MIN_GAP = 15  # minutes between weekly samples
WEEK_PACE_MAX_AGE = 72     # hours back a weekly base sample may sit
WEEK_PACE_MIN_GAP = 6      # hours a weekly base sample must be before the measurement


def epoch_iso(v):
    try:
        return iso(dt.datetime.fromtimestamp(float(v)).astimezone())
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def stale_reading(old, new, t):
    """True when the status line reading `new` is a session's old one: its window has already reset, or it is lower
    than `old`, the stored status line reading of the same window (the same reset within 10 minutes, not yet passed),
    since usage never goes down within one window. `old` is None when the stored numbers are not a status line's."""
    if not isinstance(new, dict):
        return False
    new_reset = parse_iso(str(new.get("resets_at") or ""))
    if new_reset and new_reset <= t:
        return True
    if not isinstance(old, dict) or not new_reset:
        return False
    old_reset = parse_iso(str(old.get("resets_at") or ""))
    if not old_reset or old_reset <= t or abs((new_reset - old_reset).total_seconds()) >= 600:
        return False
    try:
        return float(new["used"]) < float(old["used"])
    except (KeyError, TypeError, ValueError):
        return False


@locked("home")
def save_usage(windows, source):
    """{"five_hour": {"used": %, "resets_at": iso}, "seven_day": {…}} → the snapshot shared by all sessions, plus a
    sample of the 5-hour window for the recent pace. A stale status line reading (stale_reading) is dropped, and
    nothing is written if all are. The operator's reports always win, and a status line reading replaces one."""
    snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
    t = now()
    if source == "statusline":
        mine = snap.get("source") == "statusline"     # an operator's estimate is not a reading to compare with
        windows = {k: v for k, v in windows.items() if not stale_reading(snap.get(k) if mine else None, v, t)}
        if not windows:
            return
    stale = any((t - (measured_at(snap, k) or t - dt.timedelta(days=1))).total_seconds() > 60 for k in windows)
    if all({f: snap.get(k, {}).get(f) for f in v} == v for k, v in windows.items()) \
            and snap.get("source") == source and not stale:
        return                     # the status line refreshes often: write only on a change (or once a minute)
    # Preserve the measurement time of windows absent from this update, including old snapshots.
    for name in ("five_hour", "seven_day"):
        if isinstance(snap.get(name), dict):
            if not snap[name].get("updated"):
                snap[name]["updated"] = snap.get("updated")
    snap.update({k: dict(v, updated=iso(t)) for k, v in windows.items()}, updated=iso(t), source=source)
    five = windows.get("five_hour")
    if five:
        keep = t - dt.timedelta(hours=HISTORY_KEEP_H)
        hist = [h for h in snap.get("history") or [] if isinstance(h, list) and len(h) == 3
                and (parse_iso(str(h[0])) or keep) > keep]
        if not hist or hist[-1][1:] != [five["used"], five["resets_at"]] or stale:
            hist.append([iso(t), five["used"], five["resets_at"]])
        snap["history"] = hist[-300:]
    snap["week_history"] = week_history_update(snap.get("week_history"), windows.get("seven_day"), t)
    write_json(USAGE_SNAPSHOT, snap)


def usage_window(snap, name):
    """(used %, reset time or None) while the window is current; None once it has reset (stale numbers)."""
    w = snap.get(name) if isinstance(snap.get(name), dict) else {}
    if w.get("used") is None:
        return None
    reset = parse_iso(w.get("resets_at") or "")
    if reset and reset <= now():
        return None
    return float(w["used"]), reset


USAGE_FRESH_SECONDS = 20 * 60


def measured_at(snap, name):
    w = snap.get(name) or {}
    return parse_iso(w.get("updated") or snap.get("updated") or "")


def window_pace(snap, used, reset, hours):
    """(%/min, basis): the higher of the window average and the recent pace of all sessions; (None, None) if unknown.
    In a five-hour window both are unknown until PROJECTION_MIN_ELAPSED minutes of it have passed at the measurement."""
    if reset is None:
        return None, None
    t = measured_at(snap, "five_hour" if hours == 5 else "seven_day")
    if t is None:
        return None, None
    elapsed = (t - (reset - dt.timedelta(hours=hours))).total_seconds() / 60
    if hours == 5 and elapsed < PROJECTION_MIN_ELAPSED:
        return None, None
    rates = []
    if elapsed >= PACE_MIN_ELAPSED:
        rates.append((used / elapsed, "window average"))
    if hours == 5:
        lo, hi = t - dt.timedelta(minutes=RECENT_PACE[1]), t - dt.timedelta(minutes=RECENT_PACE[0])
        base = []
        for h in snap.get("history") or []:
            if not (isinstance(h, list) and len(h) == 3):
                continue
            ts, r = parse_iso(str(h[0])), parse_iso(str(h[2] or ""))
            if ts and r and abs((r - reset).total_seconds()) < 600 and lo <= ts <= hi:
                base.append((ts, float(h[1])))
        if base:
            ts0, u0 = min(base)                     # the longest baseline in the range
            mins = (t - ts0).total_seconds() / 60
            rates.append((max(used - u0, 0) / mins, "last %d min, all sessions" % mins))
    return max(rates) if rates else (None, None)


def projected_at_reset(used, reset, rate, measured):
    return used + rate * (reset - measured).total_seconds() / 60


def week_base_sample(history, reset, measured, used=None):
    """The earliest week_history sample from the last 72 hours (three days) with the same reset (within 10 minutes)
    and at least 6 hours before the measurement — the longest recent baseline: one heavy or light day does not swing
    the pace. Without one, the newest older sample with the same reset stands in for a flat week: if its used equals
    the current one, the recent pace is zero and the base is (measured - 72 h, used), so the basis reads 'the last
    3 d'. Malformed entries are skipped, never fatal."""
    if reset is None or measured is None:
        return None
    lo = measured - dt.timedelta(hours=WEEK_PACE_MAX_AGE)
    best = None
    newest_older = None
    for h in history or []:
        if not (isinstance(h, list) and len(h) == 3):
            continue
        ts = parse_iso(str(h[0]))
        r = parse_iso(str(h[2] or ""))
        if not (ts and r) or abs((r - reset).total_seconds()) >= 600:
            continue
        try:
            u0 = float(h[1])
        except (TypeError, ValueError):
            continue
        if ts < lo and (newest_older is None or ts > newest_older[0]):
            newest_older = (ts, u0)
        if not (lo <= ts <= measured) or (measured - ts).total_seconds() < WEEK_PACE_MIN_GAP * 3600:
            continue
        if best is None or ts < best[0]:
            best = (ts, u0)
    if best is None and newest_older is not None and used is not None and newest_older[1] == used:
        return (measured - dt.timedelta(hours=WEEK_PACE_MAX_AGE), used)
    return best


def week_recent_basis(mins):
    """'the last 8 h' / 'the last 6h 30m' / 'the last 2d 12h' from the minutes between the base sample and the
    measurement. From 24 hours on the coarse scale is days and hours, minutes dropped ('the last 3 d' at a whole
    number of days)."""
    total = int(round(mins))
    h, m = divmod(total, 60)
    if total >= 24 * 60:
        d, h = divmod(h, 24)
        if h == 0:
            return "the last %d d" % d
        return "the last %dd %dh" % (d, h)
    if m == 0:
        return "the last %d h" % h
    if h:
        return "the last %dh %dm" % (h, m)
    return "the last %d min" % max(total, 1)


def week_rate(history, used, reset, measured, window_minutes=10080):
    """(%/min, basis) of the week: the recent pace from week_history when a base sample exists, else the
    window average; (None, None) when neither is computable. The recent pace is used when it is available,
    not the higher of the two — the weekly alarm must not stay on because of an old burst."""
    base = week_base_sample(history, reset, measured, used)
    if base is not None:
        ts0, u0 = base
        mins = (measured - ts0).total_seconds() / 60.0
        if mins > 0:
            return max(used - u0, 0) / mins, week_recent_basis(mins)
    if reset is None or measured is None:
        return None, None
    elapsed = (measured - (reset - dt.timedelta(minutes=window_minutes))).total_seconds() / 60.0
    if elapsed >= PACE_MIN_ELAPSED:
        return used / elapsed, "the week's average"
    return None, None


def week_reserve(reserve, reset, measured, window_minutes=10080):
    """The effective weekly reserve: reserve × (time left / window), floored at 1 point (0 stays 0). The
    margin for what may still come shrinks as the window runs out; a reserve set to 0 stays 0."""
    if reserve <= 0:
        return 0.0
    if reset is None or measured is None:
        return float(reserve)
    remaining = (reset - measured).total_seconds() / 60.0
    if remaining <= 0 or window_minutes <= 0:
        return float(reserve)
    return float(min(reserve, max(1.0, reserve * remaining / window_minutes)))


def week_reserve_text(reserve, effective):
    """'10%' when the effective reserve rounds to the flat one, '2% (10% at the start of the week)' otherwise."""
    if pct(effective) == pct(reserve):
        return "%d%%" % pct(reserve)
    return "%d%% (%d%% at the start of the week)" % (pct(effective), pct(reserve))


def week_history_update(hist, week, t):
    """Retained week_history ([ts, used, resets_at]), plus a sample when `week` is a new measurement (used or
    reset changed) and at least WEEK_HISTORY_MIN_GAP minutes have passed. Malformed entries are dropped; the
    series is kept for WEEK_HISTORY_KEEP_H hours and capped at WEEK_HISTORY_CAP entries."""
    keep = t - dt.timedelta(hours=WEEK_HISTORY_KEEP_H)
    out = [h for h in hist or [] if isinstance(h, list) and len(h) == 3
           and (parse_iso(str(h[0])) or keep) > keep]
    if week and week.get("resets_at"):
        last = out[-1] if out else None
        last_ts = parse_iso(str(last[0])) if last else None
        changed = not last or last[1:] != [week["used"], week["resets_at"]]
        gap_ok = not last_ts or (t - last_ts).total_seconds() >= WEEK_HISTORY_MIN_GAP * 60
        if changed and gap_ok:
            out.append([iso(t), week["used"], week["resets_at"]])
    return out[-WEEK_HISTORY_CAP:]


def budget_settings(where=None):
    """surplus / reserve / week_reserve (%) from the claude profile, else BUDGET_DEFAULTS; Claude off → no surplus."""
    out = dict(BUDGET_DEFAULTS)
    try:
        prof = resolve_profile("claude", where or project_dir())
    except ProfileError as ex:
        if str(PROFILES_FILE) in str(ex):
            warn_state(PROFILES_FILE, str(ex))
        return out
    if prof.name == "off":
        out["surplus"] = 0
        return out
    for k in out:
        v = str(prof.data.get(k, out[k])).lower()
        out[k] = 0 if v in ("off", "no", "false") else int(v) if v.isdigit() else out[k]
    return out


@locked("home")
def heartbeat(key, where=None, kind="session"):
    """Mark a session (or a running Claude executor) as a Claude consumer; at most once a minute."""
    if not key:
        return
    data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    data = data if isinstance(data, dict) else {}
    t = now()
    e = data.get(key) if isinstance(data.get(key), dict) else {}
    seen, lead = parse_iso(e.get("seen") or ""), os.environ.get("ORCH_LEAD") or None
    if seen and (t - seen).total_seconds() < 60 and e.get("lead") == lead:
        return
    data = {k: v for k, v in data.items() if isinstance(v, dict) and parse_iso(v.get("seen") or "")
            and (t - parse_iso(v["seen"])).total_seconds() < 86400}
    project = e.get("project")
    if where is not None or not project:
        project = canon_path(project_root(Path(where) if where else project_dir()))
    data[key] = {"seen": iso(t), "since": e.get("since") or iso(t), "kind": kind, "lead": lead, "project": project}
    write_json(SESSIONS_FILE, data)


@locked("home")
def forget(key):
    data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    if isinstance(data, dict) and data.pop(key, None) is not None:
        write_json(SESSIONS_FILE, data)


def claude_consumers():
    """Active Claude consumers orch knows of: Claude-led sessions seen within ACTIVE_MIN minutes, and
    Claude executor runs in progress (a session led by another model does not spend Claude)."""
    data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    t, out = now(), {}
    for k, v in (data.items() if isinstance(data, dict) else []):
        seen = parse_iso(v.get("seen") or "") if isinstance(v, dict) else None
        if not seen:
            continue
        age = (t - seen).total_seconds()
        if (v.get("kind") == "executor" and age < 3 * 3600) or (not v.get("lead") and age < ACTIVE_MIN * 60):
            out[k] = v
    return out


_claude_budget_active = False


def claude_budget(where=None):
    # SURPLUS routing resolves API profiles, whose soft budgets ask about Claude again.
    # TIGHT returns before that routing step, so a recursive query is necessarily not TIGHT.
    global _claude_budget_active
    if _claude_budget_active:
        return "normal", None
    _claude_budget_active = True
    try:
        return _claude_budget(where)
    finally:
        _claude_budget_active = False


def _claude_budget(where=None):
    """(mode, line): projections stay anchored to measurements; either limit can make Claude tight."""
    kvar = profile_key("claude", where, follow=False)
    if kvar:
        return "api", ("Claude: bills to the profile key (%s) instead of the subscription — no budget mode "
                       "(SURPLUS/TIGHT off)" % kvar)
    snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
    five, week = usage_window(snap, "five_hour"), usage_window(snap, "seven_day")
    cfg = budget_settings(where)
    weekly = None
    week_tight = False
    week_reserve_txt = "%d%%" % cfg["week_reserve"]
    if week:
        wu, wr = week
        wm = measured_at(snap, "seven_day")
        wrate, wbasis = week_rate(snap.get("week_history"), wu, wr, wm)
        weekly = max(wu, projected_at_reset(wu, wr, wrate, wm)) if wrate is not None else wu
        projection = ("%d%% projected from %s" % (pct(weekly), wbasis)) if wrate is not None else "projection unavailable"
        elapsed = (wm - (wr - dt.timedelta(days=7))).total_seconds() if wm and wr else 0
        eff = week_reserve(cfg["week_reserve"], wr, wm)
        week_reserve_txt = week_reserve_text(cfg["week_reserve"], eff)
        week_tight = wu >= 100 - eff or (
            elapsed >= 86400 and weekly >= 100 - eff)
    instruction = "treat Claude as low (conserve it; offload to Codex / DeepSeek)."
    weekly_line = (" TIGHT: weekly limit is tight (%s, %d%% used, reserve %s) — %s"
                   % (projection, pct(week[0]), week_reserve_txt, instruction)) if week_tight else ""
    if not five or five[1] is None:
        if week_tight:
            return "tight", "Claude subscription:" + weekly_line
        return "unknown", None
    used, reset = five
    measured = measured_at(snap, "five_hour")
    age = max((now() - measured).total_seconds(), 0) if measured else None
    stale = age is None or age > USAGE_FRESH_SECONDS
    users = claude_consumers()
    sessions = sum(1 for v in users.values() if v.get("kind") != "executor")
    runs = len(users) - sessions
    at = reset.astimezone().strftime("%H:%M")
    active = ("; active: %d session%s%s" % (sessions, "" if sessions == 1 else "s",
                                                        ", %d Claude executor run%s" % (runs, "" if runs == 1 else "s")
                                                        if runs else "")) if users else ""
    line = "Claude subscription: 5-hour window %d%% used, resets %s (%s)%s%s; reserve %d%%%s" % (
        pct(used), at, human_delta(reset), ", week %d%%" % pct(week[0]) if week else "",
        " — reported by the operator" if snap.get("source") == "operator" else "", cfg["reserve"], active)
    if stale:
        line += "; measured %s (stale)" % (human_delta(measured) if measured else "at an unknown time")
    if week_tight:
        return "tight", line + "." + weekly_line
    rate, basis = window_pace(snap, used, reset, 5)
    cap = 100 - cfg["reserve"]
    projected = projected_at_reset(used, reset, rate, measured) if rate is not None else used
    if used >= cap or (projected >= cap and rate is not None and rate > 0):
        hit = measured + dt.timedelta(minutes=max(cap - used, 0) / rate) if rate else None
        when = ("it reaches the reserve ≈%s, before the reset" % hit.astimezone().strftime("%H:%M")
                if hit and hit > now() else "the reserve is already reached or projected to be reached")
        return "tight", line + ". TIGHT: at the current pace (%s) %s — %s" % (basis or "used share", when, instruction)
    spare = cap - projected
    if rate is None or stale or cfg["surplus"] <= 0 or spare < cfg["surplus"]:
        return "normal", line + "."
    each = " — ≈%d%% for each of the %d sessions" % (pct(spare / sessions), sessions) if sessions > 1 else ""
    exceptions = preferred_api_profiles(where)
    except_text = (", except the task types preferred for " + " and ".join(
        "%s (%s)" % (name, ", ".join(types)) for name, types in exceptions)) if exceptions else ""
    return "surplus", line + (". SURPLUS: at the current pace (%s) about %d%% of the window would expire unused beyond "
                              "the reserve%s — until %s give subtasks to Claude subagents rather than to API-billed "
                              "executors (DeepSeek, API-key profiles)%s; orch guide budget." % (
                                  basis, pct(spare), each, at, except_text))


@locked("home")
def budget_event(session, announce=True):
    """A hook event when this session's budget mode changes (surplus / tight / normal), once per change.
    announce=False only records the mode (SessionStart already prints it in the status)."""
    mode, line = claude_budget()
    if mode in ("unknown", "api"):
        return None
    snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
    seen = snap.get("announced") if isinstance(snap.get("announced"), dict) else {}
    key = session or "-"
    if seen.get(key) == mode:
        return None
    seen.pop(key, None)
    seen[key] = mode
    snap["announced"] = dict(list(seen.items())[-30:])
    write_json(USAGE_SNAPSHOT, snap)
    return ("💡 " + line) if announce else None


@locked("home")
def cmd_budget(a):
    """orch budget [show|set|clear]: the Claude subscription budget used for routing (surplus / tight)."""
    if a.action == "set":
        if a.used is None or not a.resets:
            raise SystemExit("orch: orch budget set --used PERCENT --resets TIME [--week PERCENT [--week-resets TIME]]")
        windows = {"five_hour": {"used": float(a.used), "resets_at": iso(parse_until(a.resets))}}
        if a.week is not None:
            windows["seven_day"] = {"used": float(a.week),
                                    "resets_at": iso(parse_until(a.week_resets)) if a.week_resets else None}
        save_usage(windows, "operator")
    elif a.action == "clear":
        if USAGE_SNAPSHOT.exists():
            USAGE_SNAPSHOT.unlink()
        print("Claude budget snapshot cleared.")
        return 0
    mode, line = claude_budget()
    if mode == "unknown":
        print("No current Claude subscription numbers. Add `orch statusline` as the Claude Code status line "
              "(orch guide budget), or report them: orch budget set --used 40 --resets 18:00")
        return 0
    if mode == "api":
        print(line)
        return 0
    print(line)
    users = claude_consumers()
    if users:
        print("Active Claude consumers known to orch (sessions seen within %d min, Claude executor runs):" % ACTIVE_MIN)
        for k, v in sorted(users.items(), key=lambda kv: kv[1].get("since") or ""):
            print("  %-14s %-8s %s · since %s · seen %s%s" % (
                k[:14], "run" if v.get("kind") == "executor" else "session", v.get("project") or "?",
                short_time(v.get("since")), human_delta(parse_iso(v["seen"])), " (this session)" if k == session_id() else ""))
    cfg = budget_settings()
    print("Thresholds: surplus ≥ %d%% beyond a reserve of %d%% of the window, week reserve %d%% "
          "(profile claude: --opt surplus=N|off, reserve=N, week_reserve=N)." % (
              cfg["surplus"], cfg["reserve"], cfg["week_reserve"]))
    return 0


