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


def cmd_usage(a):
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


