# ───────────────────────── spend during a run and in the status (live cost, warnings, fallback, orch spend) ─────────────────────────

def live_usage(run_dir, provider, where=None, prof=None):
    """The executor's token usage so far during a run (headless adapters write usage_live.json; codex reads its
    rollout's token_count)."""
    if provider == "codex":
        return codex_live_usage(run_dir, where, prof)
    return read_json(Path(run_dir) / "usage_live.json", None)


def codex_live_usage(run_dir, where=None, prof=None):
    """Codex reports usage at the end of a turn: read token_count.info.total_token_usage from the run's rollout
    (thread_id). Best-effort — if the rollout is unreadable, codex gets no mid-run stop (pre/post checks remain)."""
    try:
        tid = (Path(run_dir) / "thread_id").read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not tid:
        return None
    sessions = Path(codex_home(where, prof)) / "sessions"
    if not sessions.is_dir():
        return None
    files = [p for p in sessions.rglob("rollout-*.jsonl") if tid in p.name]
    if not files:
        return None
    files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    usage = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
    found = False
    for line in tail_lines(files[0], CODEX_TAIL_BYTES):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("type") != "event_msg":
            continue
        payload = ev.get("payload")
        info = payload.get("info") if isinstance(payload, dict) else None
        u = info.get("total_token_usage") if isinstance(info, dict) else None
        if not isinstance(u, dict):
            continue
        try:
            inp = int(u.get("input_tokens") or 0)
            cache = int(u.get("cached_input_tokens") or 0)
            out = int(u.get("output_tokens") or 0)
        except (TypeError, ValueError):
            continue                                    # a malformed usage line must not crash the run
        found = True
        usage["input_tokens"] = max(inp - cache, 0)      # codex counts cache reads inside input
        usage["cached_input_tokens"] = cache
        usage["output_tokens"] = out
    return usage if found else None


def spend_high_scopes(where, scopes=None):
    """[(scope, spent, limit, ratio)] of the API-billed scopes of a directory at ≥ 80% of their limit."""
    config = load_spend_limits()[0]
    records, _ = spend_cache_update()
    out = []
    for scope in (api_scopes(where) if scopes is None else scopes):
        eff = resolve_spend(config, scope, where)
        limit = _limit_number(eff)
        if limit is None or limit <= 0:
            continue
        spent = current_spend(scope, where, records)
        ratio = spent / limit
        if ratio >= SPEND_WARN_PCT / 100.0:
            out.append((scope, spent, limit, ratio))
    out.sort(key=lambda x: -x[3])
    return out


def spend_status_part(where):
    """A one-line 'API spend: …' summary for status, or None when nothing is at ≥ 80%."""
    parts = ["%s $%.2f/$%.0f (%.0f%%)" % (scope_name(s), spent, limit, ratio * 100)
             for s, spent, limit, ratio in spend_high_scopes(where)]
    return ("API spend: " + " · ".join(parts)) if parts else None


def limit_text(limit):
    """'$10' for a whole limit, '$12.16' for one that is not: a limit must not misread when it is shown."""
    return "$%d" % round(limit) if abs(limit - round(limit)) < 0.005 else "$%.2f" % limit


def shown_api_scopes(where, cache=None, records=None):
    """([(profile, scope, spent, limit or None, account figure or '')], balance cache) of the API-billed scopes a
    directory shows in the status line and in `orch status`, in provider order. The built-in profile of a provider
    (DeepSeek's) is shown once it has a key, some spend or a cached balance: a provider nobody uses stays silent.
    Reads files only: no network."""
    active = active_profiles(where)
    if not any(sc for _, sc in active):
        return [], {}
    cache = balance_cache() if cache is None else cache
    if records is None:
        records, _ = spend_cache_update()
    config = load_spend_limits()[0]
    account = balance_fragments([sc for _, sc in active if sc], cache)
    secrets, out = None, []
    for prof, scope in active:
        if not scope:
            continue
        spent = current_spend(scope, where, records)
        if not prof.explicit and scope not in account and spent <= 0:
            var = (BALANCE_PROVIDERS.get(prof.provider) or {}).get("key")
            secrets = load_secrets() if secrets is None else secrets
            if not (var and balance_secret(var, secrets)):
                continue
        out.append((prof, scope, spent, _limit_number(resolve_spend(config, scope, where)), account.get(scope, "")))
    return out, cache


def spend_status_items(where):
    """For the status line, each API-billed scope active in the directory, always: [(lowercase label, display name,
    text)] where the text is our own estimate and limit and, where one is cached, the provider's figure for the account —
    'est. $1.47/$10, account $15.09, 3h ago' (the age once the figure is older than 30 minutes; 'est. $1.47' alone when
    the limit is off, and no account part before a balance was ever fetched). A provider whose active profile is a
    fallback also says so: 'fallback: DeepSeek@client at its limit; est. $0.99/$12'. The session part puts each text in
    parentheses after the counter of the same account. Reads files only: no network."""
    active = active_profiles(where)
    notes = {prof.label: "fallback: %s %s" % (scope_name("%s@%s" % (prof.provider, prof.fallback_from)),
                                              fallback_cause_words(prof.fallback_cause))
             for prof, _ in active if prof.fallback_from}
    rows = {prof.label: (spent, limit, acct) for prof, _, spent, limit, acct in shown_api_scopes(where)[0]}
    items = []
    for prof, _ in active:
        label = prof.label
        if label not in rows and label not in notes:
            continue
        text = []
        if label in rows:
            spent, limit, acct = rows[label]
            est = "est. $%.2f" % spent
            if limit is not None:
                est += "/" + limit_text(limit)
            text = [est] + ([acct] if acct else [])
        money_text = ", ".join(text)
        if label in notes:
            money_text = notes[label] + ("; " + money_text if money_text else "")
        items.append((label.lower(), scope_name(label), money_text))
    return items


@locked("home")
def spend_event(announce=True):
    """💡 events when a scope crosses 80% / 100% of its limit — once per month for a month counter, once per
    baseline for a manual one. announce=False only records the threshold (SessionStart already shows the status)."""
    state = read_json(SPEND_EVENTS_FILE, {}, recover_corrupt=True)
    if not isinstance(state, dict):
        state = {}
    announced = state.get("announced") if isinstance(state.get("announced"), dict) else {}
    config = load_spend_limits()[0]
    where = project_dir()
    events, changed = [], False
    for scope in api_scopes(where):
        eff = resolve_spend(config, scope, where)
        limit = _limit_number(eff)
        if limit is None or limit <= 0:
            continue
        spent = current_spend(scope, where)
        era = (get_baseline(config, scope, where) or "none") if resolve_reset(config, scope, where) == "manual" \
            else month_key()
        cur = announced.get(scope)
        level = cur.get("level") if isinstance(cur, dict) and cur.get("era") == era else None
        if spent >= limit and level != "100":
            announced[scope] = {"era": era, "level": "100"}
            changed = True
            events.append("💡 %s is at its spend limit ($%.2f/$%.2f, %s, mode %s) — %s" %
                          (scope_name(scope), spent, limit, counter_cover(config, scope, where), eff.get("mode"),
                           _way_out(config, scope, where)))
        elif spent >= limit * 0.8 and level not in ("80", "100"):
            announced[scope] = {"era": era, "level": "80"}
            changed = True
            events.append("💡 %s reached 80%% of its spend limit ($%.2f/$%.2f, %s) — orch spend" %
                          (scope_name(scope), spent, limit, counter_cover(config, scope, where)))
    if changed:                                          # this runs on every tool call: no write without news
        state["announced"] = announced
        write_json(SPEND_EVENTS_FILE, state)
    return events if announce else []


def fallback_expired(entry, cutoff):
    """A per-session fallback entry outlives its session only this long (an unreadable `at` counts as expired);
    a project-wide entry, one without `session`, never expires."""
    if not isinstance(entry, dict) or "session" not in entry:
        return False
    at = parse_iso(str(entry.get("at") or ""))
    return at is None or at < cutoff


@locked("home")
def fallback_forget(sid):
    """Drop the fallback state of an ended session, and every per-session entry older than SESSION_STATE_DAYS:
    a session that ends (or dies) while its provider is on a fallback must not leave an entry for every hook to read.
    Writes only when something was removed; the rest of spend_events.json stays as it was."""
    state = read_json(SPEND_EVENTS_FILE, {}, recover_corrupt=True)
    if not isinstance(state, dict):
        return
    seen = state.get("fallback")
    if not isinstance(seen, dict):
        return
    cutoff = now() - dt.timedelta(days=SESSION_STATE_DAYS)
    kept = {key: entry for key, entry in seen.items()
            if not fallback_expired(entry, cutoff)
            and not (sid and isinstance(entry, dict) and entry.get("session") == sid)}
    if len(kept) != len(seen):
        state["fallback"] = kept
        write_json(SPEND_EVENTS_FILE, state)


@locked("home")
def fallback_event(announce=True):
    """💡 events when a provider moves from its exhausted profile to the profile's `fallback` in this project, and when
    it returns — once each way (the last move is kept in spend_events.json). A per-session entry also keeps its
    `session` and `at`, so `fallback_forget` can drop it when the session ends, and any per-session entry older than
    SESSION_STATE_DAYS is dropped whenever this state is written. announce=False only records the state
    (SessionStart already shows it in the profiles)."""
    where = project_dir()
    data, err = load_profiles()
    if err:
        return []
    state = read_json(SPEND_EVENTS_FILE, {}, recover_corrupt=True)
    if not isinstance(state, dict):
        state = {}
    seen = state.get("fallback") if isinstance(state.get("fallback"), dict) else {}
    canon = canon_path(project_root(where))
    sid = session_id()
    config = None
    events, changed = [], False
    for provider in managed_providers(data):
        key = "%s|%s" % (canon, provider)
        try:
            configured = resolve_profile(provider, where, data=data, follow=False)
            prof = resolve_profile(provider, where, data=data)
        except ProfileError:
            continue
        per_session = bool(has_session_budget(configured) and sid)
        if per_session:
            key += "|" + sid
        was = seen.get(key) if isinstance(seen.get(key), dict) else None
        shown = display_name(provider)
        if prof.fallback_from:
            moved = {"from": prof.fallback_from, "to": prof.name}
            if was and all(was.get(k) == v for k, v in moved.items()):     # `at`/`session` never decide this
                continue
            if prof.fallback_cause in ("floor", "session-hard", "session-soft"):
                fig = session_budget_figure(configured) or {}
                moved.update(cause=prof.fallback_cause, baseline_at=fig.get("baseline_at"), amount=fig.get("amount"))
                if per_session:
                    moved.update(session=sid, at=iso_precise(now()))
                seen[key], changed = moved, True
                events.append("💡 %s moved to %s: %s (%s)" % (shown, prof.name,
                              fallback_cause_text(prof.fallback_from, prof.fallback_cause),
                              session_budget_text(configured, settings=False)))
                continue
            if per_session:
                moved.update(session=sid, at=iso_precise(now()))
            seen[key], changed = moved, True
            label = provider + "@" + prof.fallback_from
            if prof.fallback_cause == "limit":
                if config is None:
                    config = load_spend_limits()[0]
                way = _way_out(config, label, where)
            else:
                way = "orch quota clear " + label
            events.append("💡 %s is %s — %s in this project moved to its fallback %s: that profile's key, limits and "
                          "routing apply instead. It returns by itself when %s is usable again (%s)" % (
                              scope_name(label), "at its limit" if prof.fallback_cause == "limit"
                              else prof.fallback_cause, shown, scope_name(provider + "@" + prof.name),
                              scope_name(label), way))
        elif was:
            del seen[key]
            changed = True
            if prof.name == was.get("from"):         # still bound to the configured profile: it is usable again
                if was.get("cause") in ("floor", "session-hard", "session-soft"):
                    fig = session_budget_figure(prof) or {}
                    topped_up = fig.get("baseline_at") != was.get("baseline_at") or (
                        fig.get("amount") is not None and was.get("amount") is not None
                        and round(fig["amount"] - was["amount"], 8) >= 0.01)
                    reason = "topped up" if topped_up else (
                        "Claude is TIGHT" if was["cause"] == "session-soft" and claude_budget(where)[0] == "tight"
                        else "budget clear")
                    events.append("💡 %s returned to %s: %s (%s)" % (
                                  shown, prof.name, reason, session_budget_text(prof, settings=False)))
                    continue
                events.append("💡 %s is usable again — %s in this project is back on it (it was on its fallback %s)"
                              % (scope_name(provider + "@" + prof.name), shown,
                                 scope_name(provider + "@" + str(was.get("to")))))
    if changed:
        cutoff = now() - dt.timedelta(days=SESSION_STATE_DAYS)
        state["fallback"] = {key: entry for key, entry in seen.items() if not fallback_expired(entry, cutoff)}
        write_json(SPEND_EVENTS_FILE, state)
    return events if announce else []


def parse_limit(value):
    """USD amount (float) or None for 'off'; exits on a bad value (negative, NaN or infinity)."""
    import math
    if value == "off":
        return None
    try:
        v = float(value)
        if not math.isfinite(v) or v < 0:
            raise ValueError
        return v
    except (TypeError, ValueError):
        raise SystemExit("orch: limit is a USD amount or 'off', got %r" % value)


def _scope_entry(data, scope, where, project):
    """The dict to mutate for a scope: defaults / global / this project's entry (created on demand)."""
    if scope == "default":
        return data.setdefault("defaults", dict(DEFAULT_SPEND))
    if project:
        return _project_entry(data, spend_where(where), create=True).setdefault(scope, {})
    return data.setdefault("global", {}).setdefault(scope, {})


def cmd_spend(a):
    """The balance fetch of `show` runs before the home lock is taken (a network call never holds it)."""
    if getattr(a, "action", None) in (None, "show"):
        balance_refresh_stale(project_dir(), all_keys=True)      # the table shows every key, not just this project's
    return _cmd_spend(a)


@locked("home")
def _cmd_spend(a):
    """orch spend [show] | limit SCOPE USD|off [--project [PATH]] [--reset month|manual]
       | mode SCOPE stop|evaluate|continue [--lead] [--overrun PCT] [--project [PATH]]
       | reset SCOPE [--limit USD] [--project [PATH]]."""
    data, err = load_spend_limits()
    where = project_dir()
    action = getattr(a, "action", None)
    if action in (None, "show"):
        records, _ = spend_cache_update()
        canon = spend_where(where)
        labels = set((data.get("global") or {}).keys())
        labels |= set((_project_settings(data, canon) or {}).keys())
        labels |= set(api_scopes(where))
        labels |= {r.get("label") for r in records if r.get("label")}
        labels.discard("default")
        balances = balance_cache()
        print("Spend limits for API-billed executors (USD). `spent` is our estimate of orch's own runs (tokens × "
              "prices). `account` is the provider's figure for the whole account (orch balance), which can include "
              "spending outside orch.")
        print("%-18s %-11s %-11s %-18s %-10s %-10s %-24s %s" % ("scope", "spent", "limit", "account", "mode", "lead",
                                                                  "counter", ""))
        if err:
            print("  (%s — defaults shown)" % err)
        for scope in sorted(labels):
            eff = resolve_spend(data, scope, where)
            limit = _limit_number(eff)
            spent = current_spend(scope, where, records)
            shown_limit = "off" if limit is None else "%.2f" % limit
            ratio = ("%.0f%%" % (spent / limit * 100)) if limit and limit > 0 else "—"
            print("%-18s $%-10.2f $%-10s %-18s %-10s %-10s %-24s %s" % (
                scope_name(scope), spent, shown_limit, balance_cell(balances.get(scope)), eff.get("mode"),
                eff.get("lead_mode"), counter_cover(data, scope, where), ratio))
        for prov in sorted({s.split("@")[0].lower() for s in labels}):
            w = price_staleness(prov)
            if w:
                print("  ⚠ " + w)
        return 0
    if err:
        raise SystemExit("orch: %s — fix or remove it before changing limits" % err)
    scope = (a.scope or "").strip().lower()
    if scope != "default" and not valid_scope(scope):
        raise SystemExit("orch: scope is 'default', a provider, or <provider>@<profile>, got %r" % scope)
    proj_arg = getattr(a, "project", None)
    project = proj_arg is not None
    if project and isinstance(proj_arg, str) and proj_arg != ".":
        where = Path(proj_arg).resolve()          # --project PATH: another project's own counter
    where_ = "project " + canon_path(project_root(where)) if project else "global"
    if action == "limit":
        value = parse_limit(a.value)
        entry = _scope_entry(data, scope, where, project)
        entry["limit"] = "off" if value is None else value       # null would mean "unset": back to the default limit
        if getattr(a, "reset", None) in ("month", "manual"):
            entry["reset"] = a.reset
        save_spend_limits(data)
        print("%s limit %s: %s" % (scope_name(scope), where_, "off" if value is None else "$%.2f" % value))
    elif action == "mode":
        if a.value not in ("stop", "evaluate", "continue"):
            raise SystemExit("orch: mode is stop, evaluate or continue, got %r" % a.value)
        field = "lead_mode" if getattr(a, "lead", False) else "mode"
        entry = _scope_entry(data, scope, where, project)
        entry[field] = a.value
        overrun = getattr(a, "overrun", None)
        if overrun is not None:
            try:
                overrun = float(overrun)
                if overrun < 0:
                    raise ValueError
            except ValueError:
                raise SystemExit("orch: --overrun is a percentage, got %r" % a.overrun)
            entry["overrun"] = overrun
        save_spend_limits(data)
        print("%s %s %s: %s" % (scope_name(scope), where_, "lead mode" if field == "lead_mode" else "executor mode", a.value))
    elif action == "reset":
        canon = spend_where(where)
        if project and counter_key(data, scope, canon)[0] != canon and getattr(a, "limit", None) is None:
            raise SystemExit("orch: %s has no %s limit of its own — set one first: orch spend limit %s N --project"
                             % (where_, scope_name(scope), scope))
        owner = canon if project else counter_key(data, scope, canon)[0]
        spent = current_spend(scope, where)
        old_limit = _limit_number(resolve_spend(data, scope, where))
        kind = resolve_reset(data, scope, where)
        if getattr(a, "limit", None) is not None:
            new = parse_limit(a.limit)
            _scope_entry(data, scope, where, project)["limit"] = "off" if new is None else new
        _baseline_section(data, owner)[scope] = iso_precise(now())
        save_spend_limits(data)
        new_limit = _limit_number(resolve_spend(data, scope, where))
        old = "off" if old_limit is None else "$%.2f" % old_limit
        new = "off" if new_limit is None else "$%.2f" % new_limit
        owner_desc = "global" if owner == "global" else "project " + canon_path(project_root(where))
        print("%s reset: $%.2f spent, limit %s → %s, %s counter (%s)" %
              (scope_name(scope), spent, old, new, kind, owner_desc))
    return 0


