# ───────────────────────── usage report (orch usage) ─────────────────────────
#
# Claude Code writes every API response of a session to ~/.claude/projects/<project>/<session>.jsonl (model,
# effort, usage) and each subagent to <session>/subagents/agent-<id>.jsonl (+ .meta.json: agent type,
# description). Streaming splits a response into several lines with the same message id — counted once.

def fmt_tok(n):
    if n is None:
        return "—"
    if n < 1000:
        return str(n)
    if n < 10000:
        return "%.1fk" % (n / 1000.0)
    if n < 1000000:
        return "%dk" % round(n / 1000.0)
    return "%.1fM" % (n / 1000000.0)


def fmt_dur(s):
    if s is None:
        return ""
    s = int(s)
    if s < 60:
        return "%ds" % s
    h, m = divmod(s // 60, 60)
    return ("%dh %dm" % (h, m)) if h else ("%dm" % m)


def usage_brief(u):
    return "tokens: input %s · cache %s · output %s" % (fmt_tok(u.get("input_tokens")),
                                                       fmt_tok(u.get("cached_input_tokens")),
                                                       fmt_tok(u.get("output_tokens")))


def claude_dir():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def transcript_for(session):
    base = claude_dir() / "projects"
    hits = sorted(base.glob("*/%s.jsonl" % session)) if base.is_dir() else []
    if not hits and base.is_dir() and len(session) >= 4:          # id prefix
        hits = sorted(base.glob("*/%s*.jsonl" % session))
    return hits[0] if hits else None


def project_transcripts(project):
    """Transcripts of the project's sessions, newest first (Claude Code names the folder after the path)."""
    base = claude_dir() / "projects"
    name = re.sub(r"[^A-Za-z0-9]", "-", str(project)).lower()
    dirs = [d for d in base.iterdir() if d.is_dir() and d.name.lower() == name] if base.is_dir() else []
    files = [f for d in dirs for f in d.glob("*.jsonl")]
    return sorted(files, key=lambda f: f.stat().st_mtime, reverse=True)


def claude_tokens(u):
    """Anthropic usage → uncached input (incl. cache writes), cache reads, output."""
    return {"input_tokens": int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0),
            "cached_input_tokens": int(u.get("cache_read_input_tokens") or 0),
            "output_tokens": int(u.get("output_tokens") or 0)}


def parse_transcript(path):
    path = Path(path)
    msgs, agents = {}, {}
    info = {"session": path.stem, "title": None, "start": None, "end": None, "cost_usd": None}

    def scan(f, who):
        first_stamp = None
        with f.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                assistant = '"type":"assistant"' in line
                special = '"type":"ai-title"' in line or '"type":"cost-state"' in line
                if first_stamp is None or assistant or special:
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(ev, dict):
                        continue
                    stamp = ev.get("timestamp")
                    if first_stamp is None and isinstance(stamp, str) and stamp:
                        first_stamp = stamp
                if assistant:
                    if first_stamp and isinstance(stamp, str) and stamp and stamp < first_stamp:
                        continue
                    msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
                    model = msg.get("model")
                    if ev.get("type") != "assistant" or not model or model.startswith("<"):
                        continue
                    owner = "agent:" + ev["agentId"] if ev.get("isSidechain") and ev.get("agentId") else who
                    msgs[msg.get("id") or ev.get("requestId") or ev.get("uuid")] = (owner, model, ev.get("effort"),
                                                                                     msg.get("usage") or {},
                                                                                     ev.get("timestamp"))
                    if who == "main" and ev.get("timestamp"):
                        info["start"] = info["start"] or ev["timestamp"]
                        info["end"] = ev["timestamp"]
                elif special:
                    if ev.get("type") == "ai-title" and ev.get("aiTitle"):
                        info["title"] = ev["aiTitle"]
                    elif ev.get("type") == "cost-state" and ev.get("totalCostUSD") is not None:
                        info["cost_usd"] = ev["totalCostUSD"]

    scan(path, "main")
    sub = path.with_suffix("") / "subagents"
    if sub.is_dir():
        for f in sorted(sub.glob("agent-*.jsonl")):
            meta = read_json(f.with_name(f.stem + ".meta.json"), {}) or {}
            agents[f.stem[len("agent-"):]] = meta
            scan(f, "agent:" + f.stem[len("agent-"):])
    rows = {}
    for owner, model, effort, u, _ts in msgs.values():
        r = rows.setdefault((owner, model), {"model": model, "efforts": [], "calls": 0, "input_tokens": 0,
                                             "cached_input_tokens": 0, "output_tokens": 0})
        r["calls"] += 1
        for k, v in claude_tokens(u).items():
            r[k] += v
        if effort and effort not in r["efforts"]:
            r["efforts"].append(effort)
    out = []
    for (owner, model), r in rows.items():
        if owner.startswith("agent:"):
            meta = agents.get(owner[6:], {})
            r.update({"who": "subagent", "agent_type": meta.get("agentType"), "task": meta.get("description")})
        else:
            r.update({"who": "main", "task": None})
        out.append(r)
    out.sort(key=lambda r: (r["who"] != "main", -(r["input_tokens"] + r["cached_input_tokens"] + r["output_tokens"])))
    info["rows"] = out
    # for computing only, never written to the ledger: each message's own time, model and tokens (main thread and
    # subagents alike), so a lead session's spend can be priced and split by time
    info["messages"] = [(ts if isinstance(ts, str) and ts else None, model, claude_tokens(u))
                        for _owner, model, _effort, u, ts in msgs.values()]
    # for the daily totals: each local day's raw counts and cost per model, a message without a time on the day the
    # session ended (the day it must at least belong to)
    end_time = message_time(info["end"]) if info.get("end") else None
    end_day = day_str(end_time) if end_time is not None else None
    daily = {}
    for _owner, model, _effort, u, ts in msgs.values():
        t = message_time(ts)
        day = day_str(t) if t is not None else end_day
        if not day:
            continue
        counts = transcript_counts(u)
        acc = daily.setdefault(day, {}).setdefault(str(model), {"in": 0, "cr": 0, "cw": 0, "out": 0, "cost": 0.0})
        for k in ("in", "cr", "cw", "out"):
            acc[k] += counts[k]
        acc["cost"] = round(acc["cost"] + daily_message_cost(model, counts, ts), 6)
    info["daily"] = daily
    return info


def message_time(ts):
    """A transcript timestamp (ISO text, usually ending in Z) or a datetime → an aware datetime, else None."""
    if isinstance(ts, dt.datetime):
        return ts if ts.tzinfo else ts.astimezone()
    if not isinstance(ts, str) or not ts:
        return None
    return parse_iso(ts.replace("Z", "+00:00"))


def spend_cuts(lead, first, last):
    """Sorted datetimes inside a session (after `first`, up to `last`) where a counter of the lead's scope may start:
    each 1st of a month (local midnight, as month_start computes it) and every manual baseline stored for the lead's
    scope label under any counter key. It only reads; a broken limits file leaves the month starts."""
    cuts = set()
    cur = month_start(first)
    while cur <= last:
        cuts.add(cur)
        cur = month_start(cur.replace(day=28) + dt.timedelta(days=4))     # any day of the next month
    try:
        config, err = load_spend_limits()
        sections = [] if err else list((config.get("baselines") or {}).values())
    except Exception:
        sections = []
    for sec in sections:
        t = parse_iso(str(sec[lead])) if isinstance(sec, dict) and lead in sec else None
        if t is not None:
            cuts.add(t)
    return sorted(c for c in cuts if first < c <= last)


def session_spend_parts(lead, messages, end=None):
    """A lead session's spend as [{"until": ISO, "spend_usd": USD}, …] in time order: each message priced at its own
    time, grouped into the intervals between the counter cuts (`spend_cuts`). A message exactly at a cut belongs to
    the later interval, as current_spend counts a record at the counter start. A message without a time is priced and
    placed at the session's end (the latest message time, else `end`, else now). Empty intervals are left out."""
    import bisect
    provider = str(lead or "").split("@")[0].lower()
    timed = [(message_time(ts), model, tokens) for ts, model, tokens in messages]
    known = [t for t, _, _ in timed if t is not None]
    stop = max(known) if known else (end or now())
    timed = [(t if t is not None else stop, model, tokens) for t, model, tokens in timed]
    if not timed:
        return []
    cuts = spend_cuts(lead, min(t for t, _, _ in timed), max(t for t, _, _ in timed))
    groups = {}
    for t, model, tokens in timed:
        g = groups.setdefault(bisect.bisect_right(cuts, t), {"until": t, "spend_usd": 0.0})
        g["until"] = max(g["until"], t)
        g["spend_usd"] += usage_cost(tokens, provider, model, when=t)
    return [{"until": iso_precise(g["until"]), "spend_usd": g["spend_usd"]} for _, g in sorted(groups.items())]


def log_session(data):
    """SessionEnd hook: keep the session's numbers in the ledger (transcripts are cleaned up after a while)."""
    tp = data.get("transcript_path")
    if not tp or not Path(tp).is_file():
        return
    info = parse_transcript(tp)
    if not info["rows"]:
        return
    proj = project_root(project_dir())
    lead = os.environ.get("ORCH_LEAD")
    # cost_usd is Claude Code's own totalCostUSD; spend_usd is our token×price estimate for the lead's API billing,
    # the sum of spend_parts: each message priced at its own time, split where a counter may start
    parts = session_spend_parts(lead, info["messages"]) if lead else None
    rec = {"kind": "session", "session": data.get("session_id") or info["session"], "project": canon_path(proj),
           "project_path": str(proj), "title": info["title"], "start": info["start"], "end": info["end"],
           "cost_usd": info["cost_usd"], "spend_usd": sum(p["spend_usd"] for p in parts) if lead else None,
           "rows": info["rows"], "lead": lead}
    if lead:
        rec["spend_parts"] = parts
    ledger_append(rec)
    daily_session_end(rec["session"], rec["project"], info.get("daily"), proj)   # never fails the snapshot


def sessionless_records(ledger, proj):
    """Runs and manual tasks logged with no session: a manual task closed from a terminal, `orch run` outside one."""
    canon = canon_path(proj)
    return [r for r in ledger if r.get("kind") in ("run", "handoff") and not r.get("session")
            and r.get("project") == canon]


def outside_info(records):
    """The pseudo-session of the records that have no session, so they report in the same format."""
    return {"session": "none", "outside": True, "title": "outside a session",
            "start": records[0].get("ts") if records else None,
            "end": records[-1].get("ts") if records else None, "rows": [], "cost_usd": None}


def session_data(sid, ledger):
    """(info, external records) of a session: live transcript if it still exists, else the SessionEnd snapshot."""
    tp = transcript_for(sid)
    info = parse_transcript(tp) if tp else None
    if info:
        sid = info["session"]
        info["lead"] = next((r.get("lead") for r in reversed(ledger)
                             if r.get("kind") == "session" and r.get("session") == sid), None)
    else:
        snaps = [r for r in ledger if r.get("kind") == "session" and str(r.get("session", "")).startswith(sid)]
        info = dict(snaps[-1]) if snaps else {"session": sid, "title": None, "start": None, "end": None, "rows": [],
                                             "cost_usd": None}
        sid = info["session"]
    ext = [r for r in ledger if r.get("kind") in ("run", "handoff") and r.get("session") == sid]
    return info, ext


def short_time(ts):
    t = parse_iso(ts.replace("Z", "+00:00")) if ts else None
    return t.astimezone().strftime("%d.%m %H:%M") if t else "?"


def usage_rows(info, ext, display=False):
    """Uniform rows: who, model, effort, what for, tokens. With display=True the ids are shown as their
    official names (models via display_name, manual who labels via scope_name); --json always uses raw ids."""
    out = []
    for r in info["rows"]:
        who = "orchestrator" if r["who"] == "main" else "subagent " + (r.get("agent_type") or "?").split(":")[-1]
        model = r["model"]
        if display:
            model = display_name(model) or model
        out.append({"who": who, "model": model, "effort": ",".join(r.get("efforts") or []),
                    "task": r.get("task") or ("main thread" if r["who"] == "main" else ""), "usage": r})
    for r in ext:
        manual = r["kind"] == "handoff"
        who_label = r.get("label") or r.get("provider") or "?"
        model = r.get("agent") or r.get("model") or "(default)"
        if display:
            who_label = scope_name(who_label) or who_label
            model = display_name(model) or model
        out.append({"who": who_label + (" (manual)" if manual else ""), "model": model,
                    "effort": r.get("effort") or "",
                    "task": "%s · %s · %s" % (r.get("task") or "", r.get("status"), fmt_dur(r.get("elapsed_s"))),
                    "usage": r.get("usage")})
    return out


def print_session(info, ext):
    span = "%s–%s" % (short_time(info.get("start")), short_time(info.get("end"))[-5:]) if info.get("start") else "time ?"
    lead = info.get("lead") or (os.environ.get("ORCH_LEAD") if info["session"] == session_id() else None)
    main_models = {str(r.get("model")) for r in info.get("rows") or [] if r.get("who") == "main"} - {"<synthetic>"}
    if not lead and main_models and not any(m.startswith("claude") for m in main_models):
        lead = ", ".join(sorted(main_models))         # a session started with orch launch, seen in its transcript
    sid = info["session"] if info.get("outside") else info["session"][:8]
    print("Session %s · %s · %s%s" % (sid, ("“%s”" % info["title"]) if info.get("title") else "untitled",
                                      span, " · lead: %s" % display_name(lead) if lead else ""))
    rows = usage_rows(info, ext, display=True)
    if not rows:
        print("  (no usage data)")
        return
    def cut(s, n):
        return s if len(s) <= n else s[:n - 1] + "…"
    print("  %-28s %-24s %-7s %-44s %7s %7s %7s" % ("who", "model", "effort", "what for", "input", "cache", "output"))
    totals = {}
    for r in rows:
        u = r["usage"] or {}
        print("  %-28s %-24s %-7s %-44s %7s %7s %7s" % (cut(r["who"], 28), cut(r["model"], 24), cut(r["effort"], 7),
                                                       cut(r["task"], 44), fmt_tok(u.get("input_tokens")),
                                                       fmt_tok(u.get("cached_input_tokens")), fmt_tok(u.get("output_tokens"))))
        if r["usage"]:
            t = totals.setdefault(r["model"], [0, 0, 0])
            for i, k in enumerate(("input_tokens", "cached_input_tokens", "output_tokens")):
                t[i] += int(u.get(k) or 0)
    print("  Totals by model:")
    for model, (i, c, o) in sorted(totals.items(), key=lambda kv: -sum(kv[1])):
        print("    %-24s input %s · cache %s · output %s" % (model, fmt_tok(i), fmt_tok(c), fmt_tok(o)))
    if info.get("cost_usd") and lead:
        print("  Claude Code's estimate ($%.2f) assumes Claude prices: not meaningful with a %s lead." % (
            info["cost_usd"], display_name(lead)))
    elif info.get("cost_usd"):
        print("  Claude Code estimates the session at $%.2f at API prices (notional on a subscription)." % info["cost_usd"])
    if any(r["who"].endswith("(manual)") for r in rows):
        print("  Manual executors do not report tokens: for them the agent, model and time are shown.")


def usage_json_item(info, ext):
    item = {"session": None if info.get("outside") else info["session"], "title": info.get("title"),
            "start": info.get("start"), "end": info.get("end"), "cost_usd": info.get("cost_usd"),
            "rows": usage_rows(info, ext)}
    if info.get("outside"):
        item["outside_a_session"] = True
    return item


# ───────────────────────── orch usage --daily ─────────────────────────
#
# The daily totals from ~/.lanewise/daily_usage.json: per local day and project × provider × model × account, the
# tokens, the estimated cost, the subscription limit points and each account's first and last balance. A run counts on
# the day it ended; a session (the lead's thread and its subagents) by each message's time. The store keeps 60 days.

DAILY_ROW = "%-48s %5s %9s %11s %12s %9s %10s"


def daily_usd(amount):
    """'$1.23', '$0.0123' for a small sum: an estimate must not round down to a false zero."""
    amount = float(amount or 0.0)
    if amount and abs(amount) < 0.01:
        return "$%.4f" % amount
    return "$%.2f" % amount


def daily_points(x):
    """'78', '3.5': subscription points, one decimal only when it says more."""
    x = float(x or 0.0)
    return ("%.0f" % x) if abs(x - round(x)) < 0.05 else ("%.1f" % x)


def daily_cut(s, n):
    s = str(s)
    return s if len(s) <= n else s[:n - 1] + "…"


def daily_totals(leaves):
    t = {"runs": 0, "sessions": 0, "input": 0, "cache_read": 0, "cache_write": 0, "output": 0, "cost_usd": 0.0}
    for r in leaves:
        t["runs"] += r["runs"]
        t["sessions"] += r["sessions"]
        t["input"] += r["in"]
        t["cache_read"] += r["cr"]
        t["cache_write"] += r["cw"]
        t["output"] += r["out"]
        t["cost_usd"] += r["cost"]
    t["cost_usd"] = round(t["cost_usd"], 6)
    return t


def daily_groups(leaves):
    """The leaves grouped by provider, then by model and account, each group with its totals: the provider rows with
    per-model and per-account rows under them. Sorted by size, the biggest first."""
    by_provider = {}
    for r in leaves:
        by_provider.setdefault(r["provider"], []).append(r)
    out = []
    for provider, items in by_provider.items():
        rows = {}
        for r in items:
            rows.setdefault((r["model"], r["account"], r["billing"]), []).append(r)
        children = []
        for (model, account, billing), group in rows.items():
            children.append({"model": model, "account": account, "billing": billing, "totals": daily_totals(group)})
        children.sort(key=lambda c: (-(c["totals"]["input"] + c["totals"]["cache_read"] + c["totals"]["output"]),
                                     c["model"], c["account"]))
        out.append({"provider": provider, "name": display_name(provider) or provider,
                    "totals": daily_totals(items), "rows": children})
    out.sort(key=lambda g: (-(g["totals"]["input"] + g["totals"]["cache_read"] + g["totals"]["output"]), g["provider"]))
    return out


def daily_group_row(label, totals):
    return DAILY_ROW % (daily_cut(label, 48), totals["runs"] + totals["sessions"], fmt_tok(totals["input"]),
                        fmt_tok(totals["cache_read"]), fmt_tok(totals["cache_write"]), fmt_tok(totals["output"]),
                        daily_usd(totals["cost_usd"]))


def daily_table(groups, totals=None):
    lines = [DAILY_ROW % ("what", "runs", "input", "cache read", "cache write", "output", "est. cost")]
    for g in groups:
        lines.append(daily_group_row(g["name"], g["totals"]))
        for c in g["rows"]:
            lines.append(daily_group_row("  %s · %s" % (display_name(c["model"]) or c["model"],
                                                        scope_name(c["account"])), c["totals"]))
    if totals and len(groups) > 1:
        lines.append(daily_group_row("total", totals))
    return lines


def daily_leaves(store, days, projects=None):
    """Rows of the daily store for `days` (a set of YYYY-MM-DD): one per day × project × provider × model × account ×
    billing, with the tokens, the estimated cost, executor runs and the session-days. A session counts once on the
    leaf with the most tokens of its day, so summing leaves never counts a session twice."""
    wanted = set(days)
    out = []
    for day, leaves in (store.get("runs") or {}).items():
        if day not in wanted or not isinstance(leaves, dict):
            continue
        for key, leaf in leaves.items():
            parts = str(key).split("|")
            if len(parts) != 5 or not isinstance(leaf, dict):
                continue
            project, provider, model, account, billing = parts
            if projects is not None and project not in projects:
                continue
            out.append({"day": day, "project": project, "provider": provider, "model": model,
                        "account": account, "billing": billing, "runs": tok_int(leaf.get("runs")), "sessions": 0,
                        "in": tok_int(leaf.get("in")), "cr": tok_int(leaf.get("cr")), "cw": tok_int(leaf.get("cw")),
                        "out": tok_int(leaf.get("out")), "cost": float(leaf.get("cost") or 0.0)})
    for slab in (store.get("sessions") or {}).values():
        if not isinstance(slab, dict):
            continue
        project = str(slab.get("project") or "")
        if projects is not None and project not in projects:
            continue
        for day, leaves in (slab.get("days") or {}).items():
            if day not in wanted or not isinstance(leaves, dict):
                continue
            made = []
            for key, leaf in leaves.items():
                parts = str(key).split("|")
                if len(parts) != 4 or not isinstance(leaf, dict):
                    continue
                provider, model, account, billing = parts
                made.append({"day": day, "project": project, "provider": provider, "model": model,
                             "account": account, "billing": billing, "runs": 0, "sessions": 0,
                             "in": tok_int(leaf.get("in")), "cr": tok_int(leaf.get("cr")),
                             "cw": tok_int(leaf.get("cw")), "out": tok_int(leaf.get("out")),
                             "cost": float(leaf.get("cost") or 0.0)})
            if not any(r["in"] + r["cr"] + r["cw"] + r["out"] for r in made):
                continue                    # nothing counted for that session that day
            max(made, key=lambda r: r["in"] + r["cw"] + r["out"])["sessions"] = 1
            out.extend(made)
    return out


def daily_match(leaf, providers, models, accounts):
    if providers:
        names = {str(p).lower() for p in providers}
        if leaf["provider"].lower() not in names and (display_name(leaf["provider"]) or "").lower() not in names:
            return False
    if models:
        wanted = [str(m).lower() for m in models]
        model = leaf["model"].lower()
        if not any(model == w or model.startswith(w) for w in wanted):
            return False
    return not accounts or leaf["account"].lower() in accounts


def daily_key_labels(values):
    """The account labels `--key` values stand for: a label as stored (deepseek@work), a bare provider, or the name
    of a profile's key variable in profiles.json — the variable itself never reaches the store."""
    out = set()
    data, err = load_profiles()
    providers = (data.get("providers") or {}) if not err and isinstance(data, dict) else {}
    for v in values or ():
        v = str(v).strip()
        if not v:
            continue
        out.add(v.lower())
        for provider, sec in providers.items():
            profs = sec.get("profiles") if isinstance(sec, dict) else None
            for name, d in (profs.items() if isinstance(profs, dict) else []):
                if isinstance(d, dict) and str(d.get("key") or "") == v:
                    out.add("%s@%s" % (str(provider).lower(), str(name).lower()))
    keys = {str(v).strip() for v in (values or ()) if str(v).strip()}
    for provider, spec in BALANCE_PROVIDERS.items():
        if str((spec or {}).get("key") or "") in keys:
            out.add(provider)
    return out


def daily_day(value):
    try:
        return dt.datetime.strptime(str(value), "%Y-%m-%d").date()
    except (TypeError, ValueError):
        return None


def daily_interval(a):
    """(since, until, notes) of the interval: local days, both ends included; the 60-day store is the limit, and a
    `--since` before it says how far back the data goes instead of printing a silent zero."""
    today = now().date()
    keep_from = today - dt.timedelta(days=DAILY_KEEP_DAYS - 1)
    notes = []
    until = today
    if getattr(a, "until", None):
        until = daily_day(a.until)
        if until is None:
            raise ValueError("--until wants YYYY-MM-DD, not %r" % a.until)
    if until > today:
        notes.append("there is nothing after today: showing the days up to %s" % today.isoformat())
        until = today
    if getattr(a, "days", None) is not None:
        if getattr(a, "since", None):
            raise ValueError("use either --days or --since, not both")
        if a.days < 1:
            raise ValueError("--days wants a number of days, 1 or more")
        since = until - dt.timedelta(days=a.days - 1)
    elif getattr(a, "since", None):
        since = daily_day(a.since)
        if since is None:
            raise ValueError("--since wants YYYY-MM-DD, not %r" % a.since)
    else:
        since = until - dt.timedelta(days=DAILY_DEFAULT_DAYS - 1)
    if since > until:
        raise ValueError("--since %s is after --until %s" % (since.isoformat(), until.isoformat()))
    if since < keep_from:
        notes.append("daily totals are kept for %d days: the data goes back to %s"
                     % (DAILY_KEEP_DAYS, keep_from.isoformat()))
        since = keep_from
    return since, until, notes


def daily_project_of(value):
    """The canonical project a `--project` value names, or the current project — as the usage log keys it."""
    if not value:
        return canon_path(project_root(project_dir()))
    p = Path(local_path(str(value))).expanduser()
    if not p.is_absolute():
        p = Path.cwd() / p
    try:
        return canon_path(project_root(p))
    except Exception:
        return canon_path(p)


def daily_available(store):
    """Every local day the store holds anything for, oldest first."""
    days = set()
    for key in ("runs", "limits", "balances"):
        days.update(d for d in (store.get(key) or {}) if isinstance(d, str))
    for slab in (store.get("sessions") or {}).values():
        if isinstance(slab, dict) and isinstance(slab.get("days"), dict):
            days.update(d for d in slab["days"] if isinstance(d, str))
    return sorted(days)


def daily_balances(store, days):
    """[{account, name, currency, first, last, change, days, rises}] of the balances kept in the interval: each
    account's first and last figure (the balance belongs to the whole account, not to one project) and any rise."""
    wanted = set(days)
    scopes = {}
    for day, by_scope in (store.get("balances") or {}).items():
        if day not in wanted or not isinstance(by_scope, dict):
            continue
        for scope, entry in by_scope.items():
            if isinstance(entry, dict):
                scopes.setdefault(str(scope), []).append((day, entry))
    out = []
    for scope, entries in sorted(scopes.items()):
        entries.sort(key=lambda de: de[0])
        points = []
        for day, entry in entries:
            first, last = balance_known(entry.get("first")), balance_known(entry.get("last"))
            if first or last:
                points.append({"day": day,
                               "first": {"amount": first[0], "currency": first[1]} if first else None,
                               "last": {"amount": last[0], "currency": last[1]} if last else None})
        if not points:
            continue
        first_pt = next((p["first"] for p in points if p["first"]), None)
        last_pt = next((p["last"] for p in reversed(points) if p["last"]), None)
        series = []
        for p in points:
            for point in (p["first"], p["last"]):
                if point and (not series or series[-1][1:] != (point["amount"], point["currency"])):
                    series.append((p["day"], point["amount"], point["currency"]))
        rises = []
        for prev, cur in zip(series, series[1:]):
            if cur[2] == prev[2] and cur[1] > prev[1]:
                rises.append({"day": cur[0], "amount": round(cur[1] - prev[1], 2), "currency": cur[2]})
        change = None
        if first_pt and last_pt and first_pt["currency"] == last_pt["currency"]:
            change = round(last_pt["amount"] - first_pt["amount"], 2)
        out.append({"account": scope, "name": scope_name(scope) or scope,
                    "currency": (last_pt or first_pt)["currency"],
                    "first": dict(first_pt, day=next(p["day"] for p in points if p["first"])) if first_pt else None,
                    "last": dict(last_pt, day=next(p["day"] for p in reversed(points) if p["last"])) if last_pt else None,
                    "change": change, "days": points, "rises": rises})
    return out


def daily_limit_sum(store, days, account, window):
    """(points, days with a sample, days without) of one subscription window in the interval."""
    total, have, missing = 0.0, 0, 0
    limits = store.get("limits") if isinstance(store.get("limits"), dict) else {}
    for day in days:
        by = limits.get(day) if isinstance(limits.get(day), dict) else {}
        by = by.get(account) if isinstance(by.get(account), dict) else {}
        if window in by:
            total += float(by.get(window) or 0.0)
            have += 1
        else:
            missing += 1
    return total, have, missing


def daily_subscriptions(store, days, leaves, project, all_projects):
    """The subscription estimate of the interval, per subscription account: the points of the weekly limit used in
    all (and of the 5-hour windows), the token and cost share of each project on it, and the points those shares
    stand for. Subscription tokens only: API-key use on the same model is left out, as it costs money of its own."""
    accounts = {r["account"] for r in leaves if r["billing"] == "subscription"}
    for day in days:
        by = (store.get("limits") or {}).get(day)
        if isinstance(by, dict):
            accounts.update(str(a) for a in by)
    out = []
    for account in sorted(accounts):
        windows = {}
        rows = [r for r in leaves if r["account"] == account and r["billing"] == "subscription" and r["day"] in days]
        token_days = {r["day"] for r in rows if r["in"] + r["cr"] + r["cw"] + r["out"] > 0}
        for window in ("seven_day", "five_hour"):
            sampled = {d for d in days if window in (store.get("limits", {}).get(d, {}).get(account, {}))}
            covered = sampled & token_days
            selected = [r for r in rows if r["day"] in covered]
            tokens = sum(r["in"] + r["cw"] + r["out"] for r in selected)
            cost = sum(r["cost"] for r in selected)
            used = daily_limit_sum(store, covered, account, window)[0]
            per = {}
            for r in selected:
                p = per.setdefault(r["project"], {"project": r["project"], "tokens": 0, "cost_usd": 0.0})
                p["tokens"] += r["in"] + r["cw"] + r["out"]
                p["cost_usd"] += r["cost"]
            projects = []
            for name, p in sorted(per.items()):
                st = p["tokens"] / tokens if tokens else 0.0
                sc = p["cost_usd"] / cost if cost else 0.0
                projects.append(dict(p, cost_usd=round(p["cost_usd"], 6), token_share=round(st, 4),
                                     cost_share=round(sc, 4), points_by_tokens=round(used * st, 2),
                                     points_by_cost=round(used * sc, 2)))
            windows[window] = {"points": round(used, 4),
                               "total_points": round(daily_limit_sum(store, days, account, window)[0], 4),
                               "covered_days": sorted(covered),
                               "missing_days": sorted(set(days) - sampled), "days_with_limits": len(sampled),
                               "no_limit_data": not covered, "tokens": tokens, "cost_usd": round(cost, 6),
                               "projects": projects}
        weekly, have, missing = daily_limit_sum(store, days, account, "seven_day")
        five = daily_limit_sum(store, days, account, "five_hour")[0]
        item = {"account": account, "name": scope_name(account) or account, "windows": windows,
                "points": {"seven_day": round(weekly, 4), "five_hour": round(five, 4)},
                "days_with_limits": have, "days_without_limits": missing,
                "tokens": windows["seven_day"]["tokens"], "cost_usd": windows["seven_day"]["cost_usd"],
                "no_limit_data": have == 0, "no_token_data": not token_days,
                "projects": windows["seven_day"]["projects"]}
        out.append(item)
    return out


def daily_subscription_lines(subs, since, until, project, all_projects):
    lines = []
    for s in subs:
        if s["no_token_data"] and s["no_limit_data"]:
            continue
        head = "%s subscription, %s–%s:" % (s["name"], since.isoformat(), until.isoformat())
        totals = []
        for window, label in (("seven_day", "weekly limit"), ("five_hour", "5-hour windows")):
            w = s["windows"][window]
            if not w["days_with_limits"]:
                totals.append("no %s data for these days" % ("limit" if window == "seven_day" else "5-hour"))
            else:
                text = "%s points of the %s used in all" % (daily_points(s["points"][window]), label)
                if window == "five_hour":
                    text += " (about %.1f full windows)" % (s["points"][window] / 100.0)
                totals.append(text)
        lines.append("  " + head + " " + " and ".join(totals) + ".")
        if s["no_token_data"]:
            lines.append("    No token data for these days, so no share can be estimated.")
            continue
        for window, label in (("seven_day", "weekly"), ("five_hour", "5-hour")):
            w = s["windows"][window]
            coverage = "%s estimate covers %d of %d days" % (
                label, len(w["covered_days"]), (until - since).days + 1)
            if w["missing_days"]:
                coverage += "; %s have no %s data" % (", ".join(w["missing_days"]),
                                                       "limit" if window == "seven_day" else "5-hour")
            lines.append("    " + coverage + ".")
            if w["no_limit_data"]:
                lines.append("    no %s data for these days." % ("limit" if window == "seven_day" else "5-hour"))
                continue
            rows = w["projects"] if all_projects else [p for p in w["projects"] if p["project"] == project]
            if not rows and not all_projects:
                lines.append("  This project: no tokens on this subscription's covered %s days." % label)
            for p in rows:
                lo, hi = sorted((p["points_by_tokens"], p["points_by_cost"]))
                lines.append("  %s: %d%% of the tokens (%d%% by cost), about %s–%s %s points." % (
                    p["project"] if all_projects else "This project", pct(p["token_share"] * 100),
                    pct(p["cost_share"] * 100), daily_points(lo), daily_points(hi), label))
    if lines:
        lines.append("  Lanewise sees only this machine's sessions and runs: other devices, claude.ai and sessions "
                     "without the plugin are not in the denominator, so a share can come out too high.")
        lines.append("  The share counts input + cache writes + output; cache reads are left out (they cost about a "
                     "tenth), which also explains a small difference from the cost share.")
    return lines


def daily_balance_lines(balances, leaves):
    lines = []
    if not balances:
        return lines
    lines.append("Balances — each account's whole balance, every project and key on it:")
    for b in balances:
        spent = sum(r["cost"] for r in leaves if r["account"] == b["account"])
        first, last = b["first"], b["last"]
        if first and last and first["currency"] == last["currency"]:
            text = "%s %s → %s %s" % (first["day"], money(first["amount"], first["currency"]),
                                      last["day"], money(last["amount"], last["currency"]))
            if b["change"] is not None:
                text += " (%s%s" % (b["change"] > 0 and "+" or "", money(b["change"], b["currency"]))
                if spent:
                    text += "; est. cost %s" % daily_usd(spent)
                text += ")"
        else:
            seen = [p for p in (first, last) if p]
            text = ", ".join("%s %s" % (p["day"], money(p["amount"], p["currency"])) for p in seen) or "no figure"
        lines.append("  %-20s %s" % (daily_cut(b["name"], 20), text))
        for rise in b["rises"]:
            lines.append("    %s: a rise of %s (a top-up)" % (rise["day"], money(rise["amount"], rise["currency"])))
    return lines


def daily_day_limits(store, day):
    by_day = (store.get("limits") or {}).get(day)
    parts = []
    if isinstance(by_day, dict):
        for account, by in sorted(by_day.items()):
            if not isinstance(by, dict):
                continue
            bits = []
            for window, label in (("seven_day", "weekly limit"), ("five_hour", "5-hour windows")):
                bits.append("%s of the %s" % (daily_points(by[window]), label) if window in by else
                            "no %s data for these days" % ("limit" if window == "seven_day" else "5-hour"))
            if bits:
                parts.append("%s %s" % (scope_name(account), ", ".join(bits)))
    return ("    limits: " + "; ".join(parts)) if parts else None


def daily_day_balances(store, day):
    by_day = (store.get("balances") or {}).get(day)
    parts = []
    if isinstance(by_day, dict):
        for scope, entry in sorted(by_day.items()):
            if not isinstance(entry, dict):
                continue
            first, last = balance_known(entry.get("first")), balance_known(entry.get("last"))
            if first or last:
                parts.append("%s %s → %s" % (scope_name(scope),
                                             money(*first) if first else "?", money(*last) if last else "?"))
    return ("    balance: " + "; ".join(parts)) if parts else None


def daily_groups_json(groups):
    out = []
    for g in groups:
        t = g["totals"]
        out.append({"provider": g["provider"], "name": g["name"],
                    "runs": t["runs"], "sessions": t["sessions"], "input": t["input"],
                    "cache_read": t["cache_read"], "cache_write": t["cache_write"], "output": t["output"],
                    "cost_usd": t["cost_usd"],
                    "rows": [{"model": c["model"], "account": c["account"], "billing": c["billing"],
                              "runs": c["totals"]["runs"], "sessions": c["totals"]["sessions"],
                              "input": c["totals"]["input"], "cache_read": c["totals"]["cache_read"],
                              "cache_write": c["totals"]["cache_write"], "output": c["totals"]["output"],
                              "cost_usd": c["totals"]["cost_usd"]} for c in g["rows"]]})
    return out


def daily_projects(leaves):
    groups = {}
    for r in leaves:
        groups.setdefault(r["project"], []).append(r)
    out = []
    for project, items in groups.items():
        t = daily_totals(items)
        out.append({"project": project, "runs": t["runs"], "sessions": t["sessions"], "input": t["input"],
                    "cache_read": t["cache_read"], "cache_write": t["cache_write"], "output": t["output"],
                    "cost_usd": t["cost_usd"]})
    out.sort(key=lambda p: (-(p["input"] + p["cache_read"] + p["output"]), p["project"]))
    return out


def daily_csv(leaves, subs=(), day_subs=()):
    """Token leaves plus rows for each subscription window's covered points and project shares."""
    def field(v):
        s = str(v)
        return '"' + s.replace('"', '""') + '"' if any(c in s for c in ',"\n') else s
    lines = ["day,project,provider,model,account,billing,runs,sessions,input_tokens,cache_read_tokens,"
             "cache_write_tokens,output_tokens,cost_usd,kind,window,limit_points,token_share,cost_share,"
             "points_by_tokens,points_by_cost,covered_days,missing_days,total_limit_points"]
    for r in sorted(leaves, key=lambda r: (r["day"], r["project"], r["provider"], r["model"], r["account"])):
        lines.append(",".join(field(v) for v in (
            r["day"], r["project"], r["provider"], r["model"], r["account"], r["billing"], r["runs"], r["sessions"],
            r["in"], r["cr"], r["cw"], r["out"], "%.6f" % r["cost"], "tokens", "", "", "", "", "", "", "", "", "")))
    for day, s in [("", s) for s in subs] + list(day_subs):
        for window, w in s["windows"].items():
            for p in w["projects"] or [{"project": ""}]:
                lines.append(",".join(field(v) for v in (
                    day, p["project"], s["account"].partition("@")[0], "", s["account"], "subscription",
                    "", "", "", "", "", "", "", "subscription", window,
                    w["points"] if not w["no_limit_data"] else "no limit data for these days",
                    p.get("token_share", ""), p.get("cost_share", ""), p.get("points_by_tokens", ""),
                    p.get("points_by_cost", ""), " ".join(w["covered_days"]), " ".join(w["missing_days"]),
                    w["total_points"] if w["days_with_limits"] else "no limit data for these days")))
    return "\n".join(lines)


def cmd_usage_daily(a):
    """`orch usage --daily`: the daily totals per project × provider × model × account, their estimated cost, the
    subscription limit points and each account's first and last balance."""
    try:
        since, until, notes = daily_interval(a)
    except ValueError as ex:
        print("orch: %s" % ex, file=sys.stderr)
        return 2
    if getattr(a, "all_projects", False) and getattr(a, "project", None):
        print("orch: use either --project or --all-projects, not both", file=sys.stderr)
        return 2
    if getattr(a, "json", False) and getattr(a, "csv", False):
        print("orch: use either --json or --csv, not both", file=sys.stderr)
        return 2
    try:
        store = daily_refresh()
    except (StateError, OSError) as ex:
        print("orch: daily totals were not updated: %s" % ex, file=sys.stderr)
        return 1
    days = day_list(since, until)
    if os.environ.get("ORCH_USAGE_LOG", "1") == "0":
        notes.append("ORCH_USAGE_LOG=0: the usage log and the daily totals are off, so nothing new is recorded")
    available = daily_available(store)
    if not available:
        notes.append("no daily totals are stored yet")
    elif since.isoformat() < available[0]:
        notes.append("the stored totals begin on %s" % available[0])
    project = daily_project_of(getattr(a, "project", None))
    all_projects = bool(getattr(a, "all_projects", False))
    every = daily_leaves(store, days)
    leaves = every if all_projects else [r for r in every if r["project"] == project]
    accounts = daily_key_labels(getattr(a, "key", None) or [])
    providers = getattr(a, "provider", None) or []
    models = getattr(a, "model", None) or []
    chosen = [r for r in leaves if daily_match(r, providers, models, accounts)]
    totals = daily_totals(chosen)
    groups = daily_groups(chosen)
    projects = daily_projects(chosen)
    balances = daily_balances(store, days)
    subs = daily_subscriptions(store, days, every, project, all_projects)
    filters = {"provider": list(providers), "model": list(models), "key": list(getattr(a, "key", None) or []),
               "accounts": sorted(accounts)}
    if getattr(a, "csv", False):
        day_subs = [(day, s) for day in days
                    for s in daily_subscriptions(store, [day], every, project, all_projects)] \
            if getattr(a, "by", None) == "day" else []
        print(daily_csv(chosen, subs, day_subs))
        return 0
    if getattr(a, "json", False):
        data = {"since": since.isoformat(), "until": until.isoformat(), "days": len(days),
                "project": None if all_projects else project, "all_projects": all_projects,
                "notes": notes, "filters": filters,
                "totals": totals, "providers": daily_groups_json(groups), "projects": projects,
                "balances": balances, "subscriptions": subs}
        if getattr(a, "by", None) == "day":
            data["daily"] = []
            for day in days:
                day_leaves = [r for r in chosen if r["day"] == day]
                by = (store.get("limits") or {}).get(day)
                if not day_leaves and not isinstance(by, dict):
                    continue
                item = {"day": day, "providers": daily_groups_json(daily_groups(day_leaves)),
                        "subscriptions": daily_subscriptions(store, [day], every, project, all_projects)}
                if isinstance(by, dict) and by:
                    item["limits"] = by
                data["daily"].append(item)
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    print("Daily usage, %s–%s (%d days) · %s" % (since.isoformat(), until.isoformat(), len(days),
                                                "all projects" if all_projects else "project " + project))
    for note in notes:
        print("  %s." % note)
    if not chosen:
        print("  No daily totals for these days%s." % (" with these filters" if (providers or models or accounts) else ""))
    else:
        for line in daily_table(groups, totals):
            print(line)
    if all_projects and projects:
        print()
        print("By project:")
        print(DAILY_ROW % ("project", "runs", "input", "cache read", "cache write", "output", "est. cost"))
        for p in projects:
            t = {"runs": p["runs"], "sessions": p["sessions"], "input": p["input"], "cache_read": p["cache_read"],
                 "cache_write": p["cache_write"], "output": p["output"], "cost_usd": p["cost_usd"]}
            print(daily_group_row(p["project"], t))
    if getattr(a, "by", None) == "day":
        for day in days:
            day_leaves = [r for r in chosen if r["day"] == day]
            limits = daily_day_limits(store, day)
            balance = daily_day_balances(store, day)
            if not day_leaves and not limits and not balance:
                continue
            print()
            print(day)
            if day_leaves:
                for line in daily_table(daily_groups(day_leaves)):
                    print("  " + line)
            if limits:
                print(limits)
                day_subs = daily_subscriptions(store, [day], every, project, all_projects)
                for line in daily_subscription_lines(day_subs, day_start(day).date(), day_start(day).date(),
                                                       project, all_projects):
                    print(line)
            if balance:
                print(balance)
    lines = daily_balance_lines(balances, every)
    if lines:
        print()
        for line in lines:
            print(line)
    lines = daily_subscription_lines(subs, since, until, project, all_projects)
    if lines:
        print()
        for line in lines:
            print(line)
    return 0


def usage_daily_requested(a):
    """True when the flags of `orch usage --daily` were given (--json alone keeps the per-session report)."""
    if getattr(a, "daily", False) or getattr(a, "by", None) or getattr(a, "csv", False):
        return True
    if getattr(a, "since", None) or getattr(a, "until", None) or getattr(a, "project", None):
        return True
    if getattr(a, "days", None) is not None or getattr(a, "all_projects", False):
        return True
    return bool(getattr(a, "provider", None) or getattr(a, "model", None) or getattr(a, "key", None))


def cmd_usage(a):
    if usage_daily_requested(a):
        return cmd_usage_daily(a)
    ledger = ledger_read()
    proj = project_root(project_dir())
    outside = sessionless_records(ledger, proj)     # records with no session: reachable, never an error
    if a.list:
        seen, lines = set(), []
        for tp in project_transcripts(proj)[:a.limit]:
            info = parse_transcript(tp)
            seen.add(info["session"])
            lines.append((info, [r for r in ledger if r.get("session") == info["session"] and r.get("kind") != "session"]))
        for r in reversed(ledger):
            sid = r.get("session")
            if r.get("project") == canon_path(proj) and sid and sid not in seen and len(lines) < a.limit:
                seen.add(sid)
                lines.append(session_data(sid, ledger))
        if outside:
            lines.append((outside_info(outside), outside))
        if a.json:
            print(json.dumps([usage_json_item(i, e) for i, e in lines], ensure_ascii=False, indent=2))
            return 0
        if not lines:
            print("No sessions with usage data for %s." % canon_path(proj))
        for info, ext in lines:
            tok = sum(int((r["usage"] or {}).get(k) or 0) for r in usage_rows(info, ext)
                      for k in ("input_tokens", "output_tokens"))
            models = sorted({display_name(r["model"]) for r in usage_rows(info, ext)})
            label = "(outside a session)" if info.get("outside") else info["session"][:8]
            print("%s  %-8s  %-40s  %s tokens (uncached) · %s" % (
                short_time(info.get("start")), label, (info.get("title") or "")[:40], fmt_tok(tok),
                ", ".join(models)[:80]))
        print("Details: orch usage --session <id>" + (" · records outside a session: orch usage --session none"
                                                     if outside else ""))
        return 0
    sid = a.session or session_id()
    if (sid or "").lower() == "none":
        if not outside:
            print("No usage records outside a session for %s." % canon_path(proj))
            return 0
        info, ext = outside_info(outside), outside
    else:
        if not sid:
            latest = project_transcripts(proj)
            sid = latest[0].stem if latest else next((r["session"] for r in reversed(ledger)
                                                       if r.get("project") == canon_path(proj) and r.get("session")), None)
        if not sid:
            print("Usage is collected per Claude Code session: from a terminal, pick one with `orch usage --list` "
                  "and `orch usage --session <id>`; a manual task closed from a terminal or an `orch run` outside "
                  "a session is under `orch usage --session none`.")
            return 0
        info, ext = session_data(sid, ledger)
    if a.json:
        print(json.dumps(usage_json_item(info, ext), ensure_ascii=False, indent=2))
        return 0
    print_session(info, ext)
    return 0


