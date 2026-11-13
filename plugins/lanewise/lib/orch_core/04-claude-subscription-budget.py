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
HEARTBEAT_MIN_SECONDS = 60  # heartbeat writes a session's "seen" at most this often
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


def window_rates(snap, used, reset, hours):
    """[(%/min, basis, minutes of samples)]: the window average and, in a five-hour window, the recent pace of all
    sessions. Empty while no estimate is computable; in a five-hour window both are unknown until
    PROJECTION_MIN_ELAPSED minutes of it have passed at the measurement."""
    if reset is None:
        return []
    t = measured_at(snap, "five_hour" if hours == 5 else "seven_day")
    if t is None:
        return []
    elapsed = (t - (reset - dt.timedelta(hours=hours))).total_seconds() / 60
    if hours == 5 and elapsed < PROJECTION_MIN_ELAPSED:
        return []
    rates = []
    if elapsed >= PACE_MIN_ELAPSED:
        rates.append((used / elapsed, "window average", elapsed))
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
            rates.append((max(used - u0, 0) / mins, "last %d min, all sessions" % mins, mins))
    return rates


def window_pace(snap, used, reset, hours):
    """(%/min, basis): the higher of the window average and the recent pace of all sessions; (None, None) if unknown.
    In a five-hour window both are unknown until PROJECTION_MIN_ELAPSED minutes of it have passed at the measurement."""
    rates = window_rates(snap, used, reset, hours)
    if not rates:
        return None, None
    rate, basis, _ = max(rates)
    return rate, basis


def projected_at_reset(used, reset, rate, measured):
    return used + rate * (reset - measured).total_seconds() / 60


def window_projection(snap, name, hours):
    """The share a window reaches at its reset at the current pace — the budget's own estimate (window_pace for the
    5-hour window, week_rate for the week) through projected_at_reset, never below the used share. None when there
    is no current window, no measurement or rate, or the measurement is stale."""
    w = usage_window(snap, name)
    if w is None:
        return None
    used, reset = w
    measured = measured_at(snap, name)
    if reset is None or measured is None or (now() - measured).total_seconds() > USAGE_FRESH_SECONDS:
        return None
    if hours == 5:
        rate, _ = window_pace(snap, used, reset, hours)
    elif hours == 7:
        rate, _ = week_rate(snap.get("week_history"), used, reset, measured)
    else:
        return None
    if rate is None:
        return None
    return max(used, projected_at_reset(used, reset, rate, measured))


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


def week_rates(history, used, reset, measured, window_minutes=10080):
    """[(%/min, basis, minutes of samples)] of the week: the recent pace from week_history when a base sample exists,
    then the window average when it is computable — the recent pace first, so a caller that wants the one current
    estimate (week_rate) takes it and not the higher of the two."""
    out = []
    base = week_base_sample(history, reset, measured, used)
    if base is not None:
        ts0, u0 = base
        mins = (measured - ts0).total_seconds() / 60.0
        if mins > 0:
            out.append((max(used - u0, 0) / mins, week_recent_basis(mins), mins))
    if reset is None or measured is None:
        return out
    elapsed = (measured - (reset - dt.timedelta(minutes=window_minutes))).total_seconds() / 60.0
    if elapsed >= PACE_MIN_ELAPSED:
        out.append((used / elapsed, "the week's average", elapsed))
    return out


def week_rate(history, used, reset, measured, window_minutes=10080):
    """(%/min, basis) of the week: the recent pace from week_history when a base sample exists, else the
    window average; (None, None) when neither is computable. The recent pace is used when it is available,
    not the higher of the two — the weekly alarm must not stay on because of an old burst."""
    rates = week_rates(history, used, reset, measured, window_minutes)
    return (rates[0][0], rates[0][1]) if rates else (None, None)


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
    if seen and (t - seen).total_seconds() < HEARTBEAT_MIN_SECONDS and e.get("lead") == lead:
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


def heartbeat_session(key, where=None):
    """Keep a session orch already knows as a Claude consumer active while its `orch run` lasts (any provider).
    Never creates an entry: a run from an unknown or headless session must not invent a consumer. A busy home lock
    skips this beat (the next poll retries) and any error is swallowed — a run must never slow down or fail for it."""
    if not key:
        return
    try:
        with state_lock(ORCH_HOME / ".state.lock", wait=0.0):
            data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
            entry = data.get(key) if isinstance(data, dict) else None
            if isinstance(entry, dict) and entry.get("kind") == "session":
                heartbeat(key, where)      # the home lock is held here: heartbeat's own lock is reentrant
    except Exception:
        pass


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
    five_projection = window_projection(snap, "five_hour", 5)
    week_projection = window_projection(snap, "seven_day", 7)
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
            return "tight", "Claude subscription: 5-hour window: none open now;" + weekly_line
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
    five_note = (" (≈%d%% by the reset)" % pct(five_projection)) if five_projection is not None else ""
    week_note = (" (≈%d%% by the reset)" % pct(week_projection)) if week_projection is not None else ""
    line = "Claude subscription: 5-hour window %d%% used%s, resets %s (%s)%s%s; reserve %d%%%s" % (
        pct(used), five_note, at, human_delta(reset),
        (", week %d%%%s" % (pct(week[0]), week_note)) if week else "",
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


# ───────────────────────── watching the limits: the pause question ─────────────────────────
#
# The budget mode spends a surplus and conserves under a squeeze; this watcher answers a different question: will the
# orchestrator lose its own capacity before the limit resets? It reads the same snapshot and the same pace/projection
# (window_rates / week_rates / projected_at_reset) — no second model of usage. A five-hour window is at risk when its
# projection reaches 100% at the reset. A window of a day or more — the week, a monthly spend limit, a prepaid balance,
# a manual spend counter — is at risk when it runs out before the reset and either in under watch_horizon_h or with
# under watch_low % left; only non-Claude spend/balance limits use the low test without a pace. The early rule (the week
# and a monthly spend limit; not a balance or a manual counter): both pace estimates run out before the reset and the
# lower one at least watch_early_share % of the window length before it, on at least watch_early_min_data_h hours of
# samples. A non-Claude lead watches its spend limit and account balance, using the spend pace, instead of Claude's
# windows. The answer is per session (`orch watch answer`): pause until the reset, continue (ask again after
# watch_ask_again_min minutes or watch_ask_again_step points), or continue without asking in this session. Hooks ask,
# at most once per 15 minutes while no answer comes; PostToolUse checks at most once per 2 minutes (a marker file).
# Its only state is watch.json next to the snapshot; a hook swallows its failures as the hook entry point does.

WATCH_FILE = ORCH_HOME / "watch.json"
WATCH_MARKERS = ORCH_HOME / ".watch-post-tool"
WATCH_SPEND_FILE = ORCH_HOME / ".watch-spend.json"
WATCH_DEFAULTS = {"watch": "on", "watch_early": "on", "watch_horizon_h": 2, "watch_low": 5,
                  "watch_early_share": 15, "watch_early_min_data_h": 24,
                  "watch_ask_again_min": 60, "watch_ask_again_step": 10}    # profile claude: --opt watch=off, …
WATCH_RANGES = {"watch_horizon_h": (0.1, 24), "watch_low": (0, 50), "watch_early_share": (1, 50),
                "watch_early_min_data_h": (0, 168), "watch_ask_again_min": (1, 1440),
                "watch_ask_again_step": (1, 100)}
WATCH_REPEAT_MIN = 15          # minutes before an unanswered question is repeated
WATCH_POST_TOOL_SECONDS = 120  # PostToolUse checks the limits at most this often (the marker file)
WATCH_STATE_DAYS = 7           # a session that has not been seen for this long loses its answer
WATCH_WEEK_MINUTES = 7 * 24 * 60


def watch_settings(where=None):
    """watch / watch_early (on|off) and the watcher thresholds from the claude profile, else WATCH_DEFAULTS."""
    out = dict(WATCH_DEFAULTS)
    try:
        prof = resolve_profile("claude", where or project_dir())
    except ProfileError as ex:
        if str(PROFILES_FILE) in str(ex):
            warn_state(PROFILES_FILE, str(ex))
        return out
    for k in WATCH_DEFAULTS:
        raw = prof.data.get(k)
        if raw is None:
            continue
        if k in ("watch", "watch_early"):
            out[k] = "off" if str(raw).lower() in ("off", "no", "false", "0") else "on"
            continue
        try:
            value = float(raw)
        except (TypeError, ValueError):
            continue
        if value == value and value not in (float("inf"), float("-inf")):
            out[k] = value
    return out


def watch_clock(t):
    """A local time for a question: HH:MM today, 'Mon DD HH:MM' otherwise (as `orch status` shows a week reset)."""
    if t is None:
        return "?"
    t = t.astimezone()
    return t.strftime("%H:%M") if t.date() == now().date() else t.strftime("%b %d %H:%M")


def watch_exhaust(used, cap, rate, anchor):
    """When `cap` is reached at `rate` from `anchor` (measured/now) — at `anchor` when it is already reached."""
    if used >= cap:
        return anchor or now()
    if rate is None or rate <= 0 or anchor is None:
        return None
    return anchor + dt.timedelta(minutes=(cap - used) / rate)


def watch_five(snap, five, cfg):
    """The Claude 5-hour window as a watched limit: at risk when the projection at its reset reaches 100%."""
    used, reset = five
    used = float(used)
    measured = measured_at(snap, "five_hour")
    rates = window_rates(snap, used, reset, 5)
    rate, basis, _ = max(rates) if rates else (None, None, None)
    projected = projected_at_reset(used, reset, rate, measured) if rate is not None and measured and reset else None
    risk = used >= 100 or (projected is not None and projected >= 100)
    cons = min(rates, key=lambda r: r[0]) if rates else None
    cons_projected = projected_at_reset(used, reset, cons[0], measured) if cons and measured and reset else None
    cons_risk = used >= 100 or (cons_projected is not None and cons_projected >= 100)
    exhaust = watch_exhaust(used, 100.0, rate, measured)
    return {"key": "five_hour", "kind": "five_hour", "name": "Claude 5-hour window", "daily": False,
            "used": used, "used_text": "%d%% used" % pct(used), "projected": projected,
            "rate": rate, "basis": basis, "exhaust_at": exhaust, "reset": reset, "tie": iso(reset),
            "conservative_rate": cons[0] if cons else None, "conservative_projected": cons_projected,
            "conservative_risk": cons_risk, "risk": risk, "early": False, "levels": []}


def watch_early(used, reset, measured, rates, cfg, window_minutes):
    """The early rule for a window with a reset: both estimates run out before it, the lower one at least
    watch_early_share % of the window length before it, on watch_early_min_data_h hours of samples."""
    if cfg["watch_early"] != "on" or reset is None or measured is None or len(rates) < 2 or used >= 100:
        return None
    levels = []
    minutes_to_reset = (reset - measured).total_seconds() / 60.0
    for rate, basis, span in rates:
        if rate is None or rate <= 0 or span < cfg["watch_early_min_data_h"] * 60:
            return None
        if used + rate * minutes_to_reset < 100:
            return None
        levels.append((rate, basis, measured + dt.timedelta(minutes=(100 - used) / rate), span))
    cons = min(levels, key=lambda l: l[0])
    if (reset - cons[2]).total_seconds() / 60.0 < cfg["watch_early_share"] / 100.0 * window_minutes:
        return None
    return {"early": True, "risk": True, "levels": [(l[0], l[1], l[2]) for l in levels],
            "conservative_rate": cons[0], "conservative_projected": used + cons[0] * minutes_to_reset}


def watch_week(snap, week, cfg):
    """The Claude weekly limit as a watched limit (a window of a day or more: the regular and the early rule)."""
    used, reset = week
    used = float(used)
    measured = measured_at(snap, "seven_day")
    rates = week_rates(snap.get("week_history"), used, reset, measured)
    rate, basis = (rates[0][0], rates[0][1]) if rates else (None, None)
    projected = projected_at_reset(used, reset, rate, measured) if rate is not None and measured and reset else None
    remaining = max(100.0 - used, 0.0)
    low = used >= 100 or remaining <= cfg["watch_low"]
    exhaust = watch_exhaust(used, 100.0, rate, measured)
    horizon = exhaust is not None and exhaust <= now() + dt.timedelta(hours=cfg["watch_horizon_h"])
    before_reset = projected is not None and projected >= 100
    risk = before_reset and (low or horizon)
    item = {"key": "week", "kind": "week", "name": "Claude weekly limit", "daily": True,
            "used": used, "used_text": "%d%% used" % pct(used), "projected": projected,
            "rate": rate, "basis": basis, "exhaust_at": exhaust, "reset": reset, "tie": iso(reset),
            "conservative_rate": rate, "conservative_projected": projected,
            "conservative_risk": risk, "risk": risk, "early": False, "levels": []}
    early = watch_early(used, reset, measured, rates, cfg, WATCH_WEEK_MINUTES)
    if early:
        item.update(early)
    return item


def spend_rates(lead, where, config, start, records=None):
    """[(USD/min, basis, minutes of samples)] of the lead's spend: the recent pace over the longest span within the
    last 72 hours that is at least 6 hours old (like the week's base sample), then the counter's average."""
    out = []
    if records is None:
        records, _ = spend_cache_update()
    key = counter_key(config, lead, spend_where(where))[0]
    t = now()

    def spent_until(when):
        total = 0.0
        for r in records:
            if r.get("label") != lead:
                continue
            if counter_key(config, r.get("label"), r.get("project") or "")[0] != key:
                continue
            ts = parse_iso(str(r.get("ts") or ""))
            if ts is not None and ts <= when:
                total += float(r.get("cost") or 0)
        return total

    spent = current_spend(lead, where, records)
    if start is not None:
        base = max(start, t - dt.timedelta(hours=WEEK_PACE_MAX_AGE))
        mins = (t - base).total_seconds() / 60.0
        if mins >= WEEK_PACE_MIN_GAP * 60:
            recent = max(spent - spent_until(base), 0.0)
            out.append((recent / mins, week_recent_basis(mins), mins))
        elapsed = (t - start).total_seconds() / 60.0
        if elapsed >= PACE_MIN_ELAPSED:
            basis = "the month's average" if resolve_reset(config, lead, where) == "month" else "the counter's average"
            out.append((spent / elapsed, basis, elapsed))
    return out


def watch_spend_data(lead, where, config, start, cached=False):
    """Hook projections use the spend code's cached records, aggregated at most once per two minutes.
    No history scan or aggregate calculation holds the home lock; existing spend hooks refresh the ledger cache."""
    if not cached:
        records, _ = spend_cache_update()
        return current_spend(lead, where, records), spend_rates(lead, where, config, start, records)
    key = json.dumps([lead, spend_where(where), config, iso(start)], sort_keys=True)
    data = read_json(WATCH_SPEND_FILE, {}, recover_corrupt=False)
    t = now()

    def fresh(value):
        """A usable aggregate: recent, with a numeric spend and a list of rates; any other shape is stale."""
        if not isinstance(value, dict):
            return False
        at = parse_iso(str(value.get("at") or ""))
        spent = value.get("spent")
        return (at is not None and 0 <= (t - at).total_seconds() < WATCH_POST_TOOL_SECONDS
                and isinstance(spent, (int, float)) and not isinstance(spent, bool)
                and isinstance(value.get("rates"), list))

    entry = data.get(key) if isinstance(data, dict) else None
    if fresh(entry):
        return entry["spent"], entry["rates"]
    cache = read_json(SPEND_CACHE_FILE, {}, recover_corrupt=False)
    records = cache.get("records") if isinstance(cache, dict) else None
    if not isinstance(records, list):
        return 0.0, []              # the normal spend hooks populate this cache; retry at the next hook
    spent = current_spend(lead, where, records)
    rates = spend_rates(lead, where, config, start, records)
    try:
        with state_lock(ORCH_HOME / ".watch-spend.lock", wait=QUIET_LOCK_WAIT):
            data = read_json(WATCH_SPEND_FILE, {}, recover_corrupt=False)
            data = {k: v for k, v in (data.items() if isinstance(data, dict) else []) if fresh(v)}
            if key not in data:
                data[key] = {"at": iso(t), "spent": spent, "rates": rates}
                write_json(WATCH_SPEND_FILE, data)
            return data[key]["spent"], data[key]["rates"]
    except StateError:
        return spent, rates


def watch_spend(lead, limit, spent, start, reset, rates, cfg):
    """A non-Claude lead's spend limit as a watched limit (a window of a day or more)."""
    used = 100.0 * spent / limit if limit > 0 else 0.0
    rate, basis = (rates[0][0], rates[0][1]) if rates else (None, None)
    remaining = max(limit - spent, 0.0)
    low = spent >= limit or 100.0 * remaining / limit <= cfg["watch_low"]
    exhaust = watch_exhaust(spent, limit, rate, now())
    horizon = exhaust is not None and exhaust <= now() + dt.timedelta(hours=cfg["watch_horizon_h"])
    projected = used + rate * (reset - now()).total_seconds() / 60.0 / limit * 100.0 \
        if rate is not None and reset is not None else None
    before_reset = True if reset is None else (spent >= limit or (projected is not None and projected >= 100))
    pace = rate if rate is not None and rate > 0 else None
    risk = low if pace is None else (before_reset and (low or horizon))
    item = {"key": "spend:" + lead, "kind": "spend", "name": "%s spend limit" % scope_name(lead), "daily": True,
            "used": used, "used_text": "%d%% used (%s of %s)" % (pct(used), money(spent, "USD"), money(limit, "USD")),
            "projected": projected, "rate": rate, "basis": basis, "exhaust_at": exhaust, "reset": reset,
            "tie": iso(reset) if reset else iso(start), "conservative_rate": rate,
            "conservative_projected": projected, "conservative_risk": risk, "risk": risk, "early": False, "levels": []}
    window_minutes = (reset - start).total_seconds() / 60.0 if reset is not None and start is not None else 0.0
    pct_rates = [(rate / limit * 100.0, basis, span) for rate, basis, span in rates]    # %/min, as watch_early wants
    early = watch_early(used, reset, now(), pct_rates, cfg, window_minutes) if window_minutes > 0 else None
    if early:
        item.update(early)
    return item


def watch_balance(lead, amount, currency, spent, limit, start, reset, rates, cfg):
    """A non-Claude lead's account balance as a watched limit: the balance is spent at the lead's spend pace, and the
    period-start figure (the balance plus what was spent since) is its scale. No early rule (a top-up changes it)."""
    denom = max(limit or 0.0, amount + spent)
    remaining = 100.0 * max(amount, 0.0) / denom if denom > 0 else 0.0
    used = max(100.0 - remaining, 0.0)
    rate, basis = (rates[0][0], rates[0][1]) if rates else (None, None)
    low = amount <= 0 or remaining <= cfg["watch_low"]
    exhaust = watch_exhaust(0.0, amount, rate, now()) if amount > 0 else now()
    horizon = exhaust is not None and exhaust <= now() + dt.timedelta(hours=cfg["watch_horizon_h"])
    projected = None               # a top-up has no scheduled time, regardless of the spend counter's reset
    pace = rate if rate is not None and rate > 0 else None
    risk = low if pace is None else (low or horizon)
    return {"key": "balance:" + lead, "kind": "balance", "name": "%s account balance" % scope_name(lead), "daily": True,
            "used": used, "used_text": "%s left (%d%%)" % (money(amount, currency), pct(remaining)),
            "projected": projected, "rate": rate, "basis": basis, "exhaust_at": exhaust, "reset": None,
            "tie": iso(start), "conservative_rate": rate,
            "conservative_projected": projected, "conservative_risk": risk, "risk": risk, "early": False, "levels": []}


def watch_limits(where=None, settings=None, cached=False):
    """Every limit the orchestrator's own capacity depends on, projected: Claude's 5-hour and weekly windows for a
    Claude-led session, the lead's spend limit and account balance for a session led by another model. A missing or
    unreadable figure is no limit (no risk), never an error."""
    cfg = settings or watch_settings(where)
    where = where if where is not None else project_dir()
    out = []
    lead = (os.environ.get("ORCH_LEAD") or "").strip()
    if not lead:
        try:
            snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=not cached)
        except StateError:
            return out
        try:
            five = usage_window(snap, "five_hour")
            if five:
                out.append(watch_five(snap, five, cfg))
        except (TypeError, ValueError):
            pass
        try:
            week = usage_window(snap, "seven_day")
            if week:
                out.append(watch_week(snap, week, cfg))
        except (TypeError, ValueError):
            pass
        # Carry the already-read sibling into the question; hooks must not read the snapshot twice.
        for item in out:
            other_key = "week" if item["key"] == "five_hour" else "five_hour"
            other = next((w for w in out if w["key"] == other_key), None)
            item["other_window"] = {"key": other_key,
                                    "name": "the weekly limit" if other_key == "week" else "the 5-hour window",
                                    "used_text": other["used_text"] if other and other.get("reset") else None,
                                    "reset": other.get("reset") if other else None}
        return out
    try:
        config, err = load_spend_limits()
    except (StateError, OSError):
        return out
    if err:
        return out
    try:
        limit = _limit_number(resolve_spend(config, lead, where))
        start = counter_start(config, lead, where)
        reset = None
        if resolve_reset(config, lead, where) == "month":
            t = now().astimezone()
            reset = dt.datetime(t.year + (1 if t.month == 12 else 0), 1 if t.month == 12 else t.month + 1, 1).astimezone()
        spent, rates = watch_spend_data(lead, where, config, start, cached)
    except (StateError, OSError, TypeError, ValueError):
        return out
    if limit is not None and limit > 0:
        out.append(watch_spend(lead, limit, spent, start, reset, rates, cfg))
    try:
        known = balance_known(balance_cache().get(lead))
    except (StateError, OSError):
        known = None
    if known:
        amount, currency = known
        out.append(watch_balance(lead, amount, currency, spent, limit, start, reset, rates, cfg))
    return out


def watch_risk_list(limits):
    """The limits at risk, the one that runs out first first — the order both `orch watch` and the hooks use."""
    risks = [l for l in limits if l.get("risk")]
    risks.sort(key=lambda l: (l.get("exhaust_at") is None,
                              l["exhaust_at"].timestamp() if l.get("exhaust_at") else 0,
                              l.get("reset") is None, l["reset"].timestamp() if l.get("reset") else 0, l["key"]))
    return risks


def watch_risks(where=None, settings=None, cached=False):
    """The limits at risk now, the one that runs out first first."""
    return watch_risk_list(watch_limits(where, settings, cached))


def watch_pause_target(risks):
    """An unscheduled top-up keeps the pause open; otherwise use the earliest reset."""
    without_reset = next((r for r in risks if not r.get("reset")), None)
    if without_reset is not None:
        return without_reset
    with_reset = [r for r in risks if r.get("reset")]
    return min(with_reset, key=lambda r: r["reset"]) if with_reset else None


def watch_question(risks):
    """The question a hook asks: the limit that runs out first, real numbers and times, and the three answers."""
    primary = risks[0]
    name = primary["name"]
    if primary.get("early"):
        levels = primary.get("levels") or []
        first = "the %s may run out well before it resets: %s" % (name, primary["used_text"])
        if len(levels) >= 2:
            first += "; at %s exhausted around %s, at %s around %s" % (
                levels[0][1], watch_clock(levels[0][2]), levels[1][1], watch_clock(levels[1][2]))
        if primary.get("reset"):
            first += "; it resets at %s" % watch_clock(primary["reset"])
    else:
        first = ("the %s may run out before it resets: %s" % (name, primary["used_text"])
                 if primary.get("reset") else "the %s may run out: %s" % (name, primary["used_text"]))
        if primary.get("exhaust_at") is not None:
            first += ", at this pace exhausted around %s" % watch_clock(primary["exhaust_at"])
        if primary.get("reset"):
            first += ", resets at %s" % watch_clock(primary["reset"])
    others = [r["name"] for r in risks[1:]]
    if others:
        first += ". Also at risk: " + ", ".join(others)
    risk_keys = {r["key"] for r in risks}
    shown = set()
    for risk in risks:
        other = risk.get("other_window")
        if not other or other["key"] in risk_keys or other["key"] in shown:
            continue
        shown.add(other["key"])
        first += ". %s: %s" % (other["name"],
                                 "%s, resets at %s" % (other["used_text"], watch_clock(other["reset"]))
                                 if other.get("reset") else
                                 "none open now" if other["key"] == "five_hour" else "no current data")
    target = watch_pause_target(risks)
    options = []
    if target is not None and target.get("reset"):
        options.append("pause this session until %s → `orch watch answer pause`" % watch_clock(target["reset"]))
    else:
        options.append("pause this session until the balance is topped up → `orch watch answer pause`"
                       if target and target.get("kind") == "balance" else
                       "pause this session until you continue → `orch watch answer pause`")
    options.append("continue, ask again later → `orch watch answer continue`")
    options.append("continue, don't ask again in this session → `orch watch answer continue-session`")
    return ("⚠ Lanewise: %s. Ask the user (one question with these options), then record the answer: %s."
            % (first, "; ".join(options)))


def watch_state(recover=True):
    """The per-session answers ({sessions: {sid: {at, asked, answer}}}); a corrupt file is preserved as .corrupt."""
    try:
        data = read_json(WATCH_FILE, {}, recover_corrupt=recover)
    except StateError:
        if recover:
            raise
        data = {}
    if not isinstance(data, dict):
        data = {}
    if not isinstance(data.get("sessions"), dict):
        data["sessions"] = {}
    return data


def watch_prune(state):
    """Drop quiet sessions; a recent sessions.json heartbeat preserves even an old standing answer. Always called
    under the home lock, so a corrupt sessions.json is recovered here: it then counts as no recorded activity."""
    cutoff = now() - dt.timedelta(days=WATCH_STATE_DAYS)
    active = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    active = active if isinstance(active, dict) else {}

    def activity(key, entry):
        seen = active.get(key)
        seen = parse_iso(str(seen.get("seen") or "")) if isinstance(seen, dict) else None
        return max(seen or cutoff, parse_iso(str(entry.get("at") or "")) or cutoff)

    sessions = {k: v for k, v in state["sessions"].items()
                if isinstance(v, dict) and activity(k, v) > cutoff}
    state["sessions"] = sessions


def watch_save(state, key, entry):
    watch_prune(state)
    state["sessions"][key] = entry
    write_json(WATCH_FILE, state)


def watch_reask(entry, risks, cfg):
    """(counted risks, ask due) under this session's 'continue': a five-hour window counts only while its lower pace
    estimate agrees, every window of a day or more keeps its rule; ask after the minutes or the points of growth."""
    answer = entry.get("answer") if isinstance(entry.get("answer"), dict) else {}
    at = parse_iso(str(answer.get("at") or ""))
    stored = [l for l in answer.get("limits") or [] if isinstance(l, dict)]
    counted, grew, new = [], False, False
    for r in risks:
        match = next((l for l in stored if l.get("key") == r["key"] and l.get("tie") == r.get("tie")), None)
        if match is None:
            new = True
            counted.append(r)
            continue
        if not r.get("daily") and not r.get("conservative_risk"):
            continue
        counted.append(r)
        try:
            if r["used"] - float(match.get("used") or 0) >= cfg["watch_ask_again_step"]:
                grew = True
        except (TypeError, ValueError):
            pass
    if not counted:
        return [], False
    due = new or grew or (at is not None and (now() - at).total_seconds() >= cfg["watch_ask_again_min"] * 60)
    return counted, due


def watch_record(key, expected, ended=False):
    """Commit a due event only if the session entry still matches the unlocked decision."""
    try:
        with state_lock(ORCH_HOME / ".state.lock", wait=QUIET_LOCK_WAIT):
            state = watch_state()
            entry = state["sessions"].get(key)
            entry = entry if isinstance(entry, dict) else {}
            if entry != expected:
                return False
            entry["at"] = iso(now())
            entry["asked"] = None if ended else entry["at"]
            if ended:
                entry["answer"] = None
            watch_save(state, key, entry)
            return True
    except (StateError, OSError):
        return False


def watch_post_tool_due(key):
    """One cheap mtime per session; touching a marker also removes markers quiet for a day."""
    import hashlib
    marker = WATCH_MARKERS / hashlib.sha256(key.encode("utf-8")).hexdigest()
    stamp = time.time()
    try:
        if stamp - marker.stat().st_mtime < WATCH_POST_TOOL_SECONDS:
            return False
    except OSError:
        pass
    try:
        WATCH_MARKERS.mkdir(exist_ok=True)
        marker.touch()
        for old in WATCH_MARKERS.iterdir():
            try:
                if old.is_file() and stamp - old.stat().st_mtime > 86400:
                    old.unlink()
            except OSError:
                pass
    except OSError:
        pass
    return True


def watch_event(session, event):
    """A hook event for this session: the pause reminder or its end, or the one question when a limit may run out
    before it resets. None when there is nothing to say (the usual case)."""
    if os.environ.get("ORCH_WORKER"):
        return None
    cfg = watch_settings()
    if cfg["watch"] != "on":
        return None
    state = watch_state(recover=False)
    key = session or "-"
    entry = state["sessions"].get(key) if isinstance(state["sessions"].get(key), dict) else {}
    t = now()
    answer = entry.get("answer") if isinstance(entry.get("answer"), dict) else None
    if answer and answer.get("kind") == "pause":
        until = parse_iso(str(answer.get("until") or ""))
        if until is None or t < until:
            if event != "user-prompt":
                return None
            source = answer.get("source") or "the limit"
            if until is None:
                duration = "until the balance is topped up" if answer.get("balance") else "until you continue"
                return ("⏸ Lanewise: this session is paused %s (%s). Finish nothing new; answer briefly; if the user "
                        "says to continue, run `orch watch answer continue`." % (duration, source))
            return ("⏸ Lanewise: this session is paused until %s (%s). Finish nothing new; answer briefly; if the user "
                    "says to continue, run `orch watch answer continue`." % (watch_clock(until), source))
        if watch_record(key, entry, ended=True):
            return "▶ Lanewise: the pause is over (the limit reset); continue where you stopped."
        return None
    if answer and answer.get("kind") == "continue-session":
        return None
    if event == "post-tool":       # tool calls come fast: the limits are checked at most once per 2 minutes
        if not watch_post_tool_due(key):
            return None
    risks = watch_risks(settings=cfg, cached=True)
    if not risks:
        return None
    counted = risks
    if answer and answer.get("kind") == "continue":
        counted, due = watch_reask(entry, risks, cfg)
        if not counted or not due:
            return None
    asked = parse_iso(str(entry.get("asked") or ""))
    if asked is not None and (t - asked).total_seconds() < WATCH_REPEAT_MIN * 60:
        return None
    return watch_question(counted) if watch_record(key, entry) else None


@locked("home")
def watch_forget(session):
    """SessionEnd: the session's answer must not outlive it."""
    state = watch_state()
    if state["sessions"].pop(session or "-", None) is not None:
        write_json(WATCH_FILE, state)


def watch_pause_line(sid):
    """'⏸ paused until 16:50' while this session's pause lasts — a read of watch.json only (the status line)."""
    if not sid:
        return None
    data = read_json(WATCH_FILE, {}, recover_corrupt=False)
    sessions = data.get("sessions") if isinstance(data, dict) else None
    entry = sessions.get(sid) if isinstance(sessions, dict) else None
    answer = entry.get("answer") if isinstance(entry, dict) and isinstance(entry.get("answer"), dict) else None
    if not answer or answer.get("kind") != "pause":
        return None
    until = parse_iso(str(answer.get("until") or ""))
    if until is None:
        return "⏸ paused until the balance is topped up" if answer.get("balance") else "⏸ paused"
    return "⏸ paused until %s" % watch_clock(until) if until > now() else None


def watch_limit_line(l):
    """One limit for `orch watch`: used, reset, projection, time to exhaustion, risk."""
    text = "%s: %s" % (l["name"], l["used_text"])
    if l.get("reset"):
        text += ", resets at %s" % watch_clock(l["reset"])
    parts = []
    if l.get("early"):
        parts.append("EARLY")
        levels = l.get("levels") or []
        if len(levels) >= 2:
            parts.append("at %s exhausted around %s, at %s around %s" % (
                levels[0][1], watch_clock(levels[0][2]), levels[1][1], watch_clock(levels[1][2])))
    elif l.get("rate") is None:
        parts.append("projection unavailable")
    else:
        parts.append("at this pace (%s)" % l.get("basis"))
        if l.get("projected") is not None:
            parts.append("projected %d%% at the reset" % pct(l["projected"]))
        if l.get("exhaust_at") is not None:
            parts.append("exhausted around %s" % watch_clock(l["exhaust_at"]))
    return text + "; " + ", ".join(parts) + " — " + ("RISK" if l.get("risk") else "no risk") + "."


def watch_answer_line(answer, entry, cfg):
    if not isinstance(answer, dict):
        asked = parse_iso(str(entry.get("asked") or "")) if isinstance(entry, dict) else None
        return "no answer" + (" (asked %s)" % human_delta(asked) if asked else "")
    kind = answer.get("kind")
    if kind == "pause":
        until = parse_iso(str(answer.get("until") or ""))
        source = answer.get("source") or "the limit"
        return ("paused until %s (%s)" % (watch_clock(until), source)) if until else (
            "paused until the balance is topped up (%s)" % source if answer.get("balance") else "paused (%s)" % source)
    if kind == "continue-session":
        return "continue, not asked again in this session"
    return "continue: ask again after %g min or %g points" % (cfg["watch_ask_again_min"], cfg["watch_ask_again_step"])


def watch_settings_line(cfg):
    return ("watch %s, early %s, horizon %g h, low %g%% left, early share %g%% of the window after %g h of samples, "
            "ask again after %g min or %g points." % (
                cfg["watch"], cfg["watch_early"], cfg["watch_horizon_h"], cfg["watch_low"],
                cfg["watch_early_share"], cfg["watch_early_min_data_h"],
                cfg["watch_ask_again_min"], cfg["watch_ask_again_step"]))


def watch_object(l):
    """One limit as JSON: datetimes as ISO strings, the projection as a percentage of the limit."""
    return {"key": l["key"], "kind": l["kind"], "name": l["name"], "daily": bool(l.get("daily")),
            "used_percent": round(l["used"], 1) if l.get("used") is not None else None,
            "used_text": l.get("used_text"), "projected_percent_at_reset":
                round(l["projected"], 1) if l.get("projected") is not None else None,
            "rate_per_minute": l.get("rate"), "basis": l.get("basis"),
            "exhausted_at": iso(l.get("exhaust_at")), "resets_at": iso(l.get("reset")),
            "risk": bool(l.get("risk")), "early": bool(l.get("early")),
            "conservative_risk": bool(l.get("conservative_risk")),
            "levels": [{"basis": b, "exhausted_at": iso(e)} for _, b, e in l.get("levels") or []]}


def watch_show(as_json=False):
    """`orch watch`: every current limit with its projection, the risks, this session's answer and the thresholds."""
    cfg = watch_settings()
    limits = watch_limits(settings=cfg)
    risks = watch_risk_list(limits)
    sid = session_id()
    state = watch_state()
    entry = state["sessions"].get(sid or "-") if isinstance(state["sessions"].get(sid or "-"), dict) else {}
    answer = entry.get("answer") if isinstance(entry.get("answer"), dict) else None
    if as_json:
        print(json.dumps({"session": sid, "settings": dict(cfg), "limits": [watch_object(l) for l in limits],
                          "risks": [l["key"] for l in risks], "answer": answer if isinstance(answer, dict) else None},
                         indent=2, ensure_ascii=False))
        return 0
    print("The orchestrator's own limits%s:" % (" — session %s" % sid if sid else ""))
    if not limits:
        print("  No figures to watch: no current Claude subscription numbers%s." % (
              " and no lead spend or balance" if os.environ.get("ORCH_LEAD") else ""))
    for l in limits:
        print("  " + watch_limit_line(l))
    print("At risk now: " + (", ".join("the " + l["name"] for l in risks) + "." if risks else "nothing."))
    print("This session: " + watch_answer_line(answer, entry, cfg))
    print("Settings: " + watch_settings_line(cfg))
    if cfg["watch"] != "on":
        print("The watcher is off: hooks do not ask (profile claude: --opt watch=on).")
    return 0


@locked("home")
def watch_answer(kind):
    """Record this session's answer: pause until the reset, continue (ask again later), or stop asking here."""
    sid = session_id()
    if not sid:
        raise SystemExit("orch: no session id (CLAUDE_CODE_SESSION_ID) — run this in the session that was asked")
    cfg = watch_settings()
    if cfg["watch"] != "on":
        raise SystemExit("orch: the limit watch is off (profile claude: --opt watch=on)")
    state = watch_state()
    entry = state["sessions"].get(sid) if isinstance(state["sessions"].get(sid), dict) else {}
    risks = watch_risks(settings=cfg)
    t = now()
    limits = [{"key": r["key"], "kind": r["kind"], "tie": r["tie"], "used": round(r["used"], 1)} for r in risks]
    if kind == "continue-session":
        answer = {"kind": kind, "at": iso(t)}
    elif kind == "continue":
        answer = {"kind": kind, "at": iso(t), "limits": limits}
    else:
        target = watch_pause_target(risks)
        source = target or (risks[0] if risks else None)
        answer = {"kind": "pause", "at": iso(t), "until": iso(target["reset"]) if target else None,
                  "source": (source or {}).get("name") or "the limit", "limits": limits,
                  "balance": bool(source and source.get("kind") == "balance")}
    entry["answer"] = answer
    entry["asked"] = None
    entry["at"] = iso(t)
    watch_save(state, sid, entry)
    if kind == "pause":
        until = parse_iso(str(answer.get("until") or ""))
        duration = watch_clock(until) if until else "the balance is topped up" if answer.get("balance") else "you continue"
        print("Paused this session until %s (%s)." % (duration, answer["source"]))
    elif kind == "continue-session":
        print("Continue: this session will not be asked again.")
    else:
        print("Continue: ask again after %g minutes or %g points." % (
            cfg["watch_ask_again_min"], cfg["watch_ask_again_step"]))
    if not risks:
        print("No limit is at risk now; the answer is recorded.")
    return 0


def cmd_watch(a):
    """orch watch [--json] | orch watch answer pause|continue|continue-session."""
    if a.action == "answer":
        if not a.answer:
            raise SystemExit("orch: orch watch answer pause|continue|continue-session")
        return watch_answer(a.answer)
    return watch_show(a.json)


