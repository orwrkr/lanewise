# ───────────────────────── spend accounting (costs, scopes, baselines, limits) ─────────────────────────

def usage_cost(usage, provider, model=None, when=None):
    """USD of a token usage dict at the provider's prices: uncached input + cache reads + output (cache writes are
    folded into input, priced at the input rate)."""
    u = usage if isinstance(usage, dict) else {}
    models = u.get("models")
    if isinstance(models, dict) and len(models) > 1:   # several models (e.g. a lead's fast background calls)
        return sum(usage_cost(v, provider, m, when) for m, v in models.items() if isinstance(v, dict))
    m = (u.get("model") or model or "")
    rates = price_for(m, provider, when)
    if not rates:
        return 0.0
    inp = float(u.get("input_tokens") or 0)
    cache = float(u.get("cached_input_tokens") or 0)
    out = float(u.get("output_tokens") or 0)
    return (inp * float(rates.get("input") or 0) + cache * float(rates.get("cache_read") or 0)
            + out * float(rates.get("output") or 0)) / 1e6


def month_key(t=None):
    return (t or now()).strftime("%Y-%m")


def month_start(t=None):
    """Local midnight on the 1st of `t`'s month, with the UTC offset of that moment, not of `t`: a DST change in
    between would otherwise move it by an hour."""
    t = (t or now()).astimezone()
    return dt.datetime(t.year, t.month, 1).astimezone()


def spend_where(where):
    """Canonical project path of a directory; an already-canonical ledger path passes through unchanged."""
    if isinstance(where, str) and re.match(r"^[A-Za-z]:", where.replace("\\", "/")):
        return canon_path(where)
    return canon_path(project_root(where))


def _project_settings(config, canon):
    """The longest project entry covering a canonical path, or None."""
    projects = config.get("projects") or {}
    best, found = -1, None
    for k, v in projects.items():
        ck = canon_path(k)
        if (canon == ck or canon.startswith(ck + "/")) and isinstance(v, dict) and len(ck) > best:
            best = len(ck)
            found = v
    return found


def _project_entry(data, canon, create=False):
    """The project entry dict for a canonical path (reusing the operator's spelling when it exists)."""
    projects = data.setdefault("projects", {})
    for k, v in projects.items():
        if canon_path(k) == canon and isinstance(v, dict):
            return v
    if not create:
        return None
    projects[canon] = {}
    return projects[canon]


def counter_key(config, scope, canon):
    """(counter_scope, scope): the project owning this scope's own counter (its canonical path), else 'global'."""
    projects = config.get("projects") or {}
    best, owner_key, owner = -1, None, None
    for k, v in projects.items():
        ck = canon_path(k)
        if (canon == ck or canon.startswith(ck + "/")) and isinstance(v, dict) and len(ck) > best:
            best, owner_key, owner = len(ck), ck, v
    s = owner.get(scope) if owner else None
    if isinstance(s, dict) and "limit" in s:
        return owner_key, scope
    return "global", scope


def registry_providers():
    """Provider keys in the effective registry's `providers:` block (2-space indented; no YAML library)."""
    out = []
    try:
        text = registry_path().read_text(encoding="utf-8")
    except OSError:
        return out
    in_providers = False
    for line in text.splitlines():
        if not in_providers:
            if line.rstrip() == "providers:":
                in_providers = True
            continue
        if line and not line[0].isspace():
            break                                   # a later top-level key ends the block
        m = re.match(r"^  ([A-Za-z][A-Za-z0-9_-]*):\s*$", line)
        if m:
            out.append(m.group(1).lower())
    return out


def known_providers():
    """Providers a scope may name: the registry's providers plus every adapter, manual lane and profile provider."""
    try:
        data, _ = load_profiles()
    except Exception:
        data = {"providers": {}}
    return list(dict.fromkeys(registry_providers() + managed_providers(data)))


def valid_scope(scope):
    """True when a scope names a known provider, or a known provider@profile that exists."""
    scope = (scope or "").strip().lower()
    if not scope:
        return False
    provider, _, name = scope.partition("@")
    if provider not in known_providers():
        return False
    if not name:
        return True
    try:
        data, err = load_profiles()
    except Exception:
        return True
    if err:
        return True                          # a broken profiles file cannot answer; the provider part already passed
    _, profs = provider_section(data, provider)
    return name in {p.lower() for p in profs}


def scope_has_key(scope, where=None):
    """True when the scope bills an API key with a prepaid balance → default manual reset. DeepSeek always; other
    providers when the named profile has a `key` field (or the active profile, for a bare provider scope)."""
    provider, _, name = (scope or "").partition("@")
    provider = provider.lower()
    if provider == "deepseek":
        return True
    try:
        data, err = load_profiles()
        if err:
            return False
    except Exception:
        return False
    if name:
        sec, profs = provider_section(data, provider)
        d = profs.get(name.lower())
        return isinstance(d, dict) and bool(d.get("key"))
    return profile_key(provider, where or project_dir()) is not None


def _baseline_section(config, key):
    b = config.get("baselines")
    if not isinstance(b, dict):
        b = config["baselines"] = {}
    sec = b.get(key)
    if not isinstance(sec, dict):
        sec = b[key] = {}
    return sec


def get_baseline(config, scope, where):
    """The stored baseline timestamp of `scope`'s counter (manual reset), or None."""
    key = counter_key(config, scope, spend_where(where))[0]
    return _baseline_section(config, key).get(scope)


@locked("home")
def ensure_baseline(scope, where):
    """Write a baseline (now) for a manual scope the first time it is seen, so spending from before this feature
    doesn't count. Re-reads under the lock; returns the baseline datetime, or None for a month scope / a broken
    limits file (writes refuse)."""
    config, err = load_spend_limits()
    if err or resolve_reset(config, scope, where) != "manual":
        return None
    key = counter_key(config, scope, spend_where(where))[0]
    sec = _baseline_section(config, key)
    if scope in sec:
        return parse_iso(str(sec[scope]))
    t = now()
    sec[scope] = iso_precise(t)
    save_spend_limits(config)
    return t


def resolve_reset(config, scope, where):
    """The reset kind for a scope: project → global → default, else the rule (an API key → manual, else month)."""
    defaults = config.get("defaults") or {}
    g = (config.get("global") or {}).get(scope)
    p = (_project_settings(config, spend_where(where)) or {}).get(scope)
    g = g if isinstance(g, dict) else {}
    p = p if isinstance(p, dict) else {}
    for src in (p, g):
        if src.get("reset") in ("manual", "month"):
            return src["reset"]
    d = defaults.get("reset")
    if d in ("manual", "month"):
        return d
    return "manual" if scope_has_key(scope, where) else "month"


def counter_start(config, scope, where):
    """Datetime the counter for `scope` counts from in `where`: a manual scope counts from its baseline (None until
    one is written — first seen), a month scope from the 1st of this month."""
    if resolve_reset(config, scope, where) == "month":
        return month_start(now())
    ts = get_baseline(config, scope, where)
    return parse_iso(str(ts)) if ts else None


def resolve_spend(config, scope, where):
    """Effective {limit, mode, lead_mode, overrun} for a scope in a directory (project → global → defaults)."""
    defaults = config.get("defaults") or {}
    g = (config.get("global") or {}).get(scope)
    p = (_project_settings(config, spend_where(where)) or {}).get(scope)
    g = g if isinstance(g, dict) else {}
    p = p if isinstance(p, dict) else {}
    out = {}
    for field in ("limit", "mode", "lead_mode", "overrun"):
        if field in p and p[field] is not None:
            out[field] = p[field]
        elif field in g and g[field] is not None:
            out[field] = g[field]
        else:
            out[field] = defaults.get(field, DEFAULT_SPEND.get(field))
    return out


def _limit_number(eff):
    limit = eff.get("limit")
    if limit == "off" or limit is None:
        return None
    try:
        return float(limit)
    except (TypeError, ValueError):
        return None


def spend_kill_at(eff, field="mode"):
    """Dollars at which a running executor (or the lead, field='lead_mode') stops: stop at 100%, evaluate at
    100% + overrun; None for continue (warn only) or an off/unlimited limit."""
    limit = _limit_number(eff)
    if limit is None:
        return None
    mode = eff.get(field)
    if mode == "stop":
        return limit
    if mode == "evaluate":
        try:
            overrun = float(eff.get("overrun"))
        except (TypeError, ValueError):
            overrun = DEFAULT_SPEND["overrun"]
        return limit * (1 + overrun / 100.0)
    return None


def load_spend_limits():
    """(data, error). A broken file is an error (writes refuse; reads keep the defaults) — never fail-open."""
    empty = {"defaults": dict(DEFAULT_SPEND), "global": {}, "projects": {}, "baselines": {}}
    try:
        data = json.loads(_read_text_retry(SPEND_FILE, encoding="utf-8-sig"))
    except FileNotFoundError:
        return empty, None
    except (OSError, ValueError) as ex:
        return empty, "%s is unreadable: %s" % (SPEND_FILE, ex)
    if not isinstance(data, dict):
        return empty, "%s: expected an object" % SPEND_FILE
    for k in ("defaults", "global", "projects", "baselines"):
        data.setdefault(k, {} if k != "defaults" else dict(DEFAULT_SPEND))
    if not isinstance(data["defaults"], dict):
        data["defaults"] = dict(DEFAULT_SPEND)
    for k in ("global", "projects", "baselines"):
        if not isinstance(data[k], dict):
            data[k] = {}
    return data, None


def save_spend_limits(data):
    data["_readme"] = ("Orchestra spend limits for API-billed executors: orch spend "
                       "(limit/mode/reset per scope, global or per project; baselines for manual counters).")
    data.setdefault("version", 1)
    write_json(SPEND_FILE, data)


def _api_billed_record(rec):
    """True when a run record bills to an API key: its `billing` field, else the old-entry heuristic (deepseek)."""
    billing = rec.get("billing")
    if billing in ("api", "subscription"):
        return billing == "api"
    return str(rec.get("provider") or "").lower() == "deepseek"


def session_cost(rec):
    """USD of a lead session's tokens (main thread + subagents), at the lead provider's prices."""
    lead = str(rec.get("lead") or "")
    provider = lead.split("@")[0].lower()
    total = 0.0
    for row in rec.get("rows") or []:
        if isinstance(row, dict):
            total += usage_cost(row, provider, row.get("model"))
    return total


def _run_cost(rec):
    """USD of a run record: its frozen `cost_usd` when present, else priced from usage at read time."""
    if isinstance(rec.get("cost_usd"), (int, float)):
        return float(rec["cost_usd"])
    return usage_cost(rec.get("usage"), str(rec.get("provider") or ""), rec.get("model"))


def _session_cost(rec):
    """USD of a session record: its frozen `spend_usd` when present, else priced from the rows at read time."""
    if isinstance(rec.get("spend_usd"), (int, float)):
        return float(rec["spend_usd"])
    return session_cost(rec)


def _spend_parts(rec):
    """[(cost, ts)] of a session record's `spend_parts`, or None when it has none or any part is malformed (the
    record then counts as one, from its frozen `spend_usd`, as records written before the parts did)."""
    parts = rec.get("spend_parts")
    if not isinstance(parts, list) or not parts:
        return None
    out = []
    for p in parts:
        cost = p.get("spend_usd") if isinstance(p, dict) else None
        if isinstance(cost, bool) or not isinstance(cost, (int, float)):
            return None
        try:
            cost = float(cost)
        except (OverflowError, ValueError):
            return None
        if cost != cost or cost in (float("inf"), float("-inf")):    # NaN or infinity
            return None
        ts = parse_iso(str(p.get("until") or "").replace("Z", "+00:00"))
        if ts is None:
            return None
        out.append((cost, ts))
    return out


def record_spend(rec):
    """[(label, project, cost, ts, sid, snap)] of a ledger record: empty when it does not count toward spend. `sid` is
    the session id for session records (None for runs) and `snap` marks the snapshot (the session record's own ts):
    snapshots of one session are deduplicated. A session record with `spend_parts` gives one entry per part, at the
    part's own time, so a counter reset or a month start inside the session splits it."""
    if not isinstance(rec, dict):
        return []
    ts = parse_iso(str(rec.get("ts") or "")) or now()
    if rec.get("kind") == "run":
        if not _api_billed_record(rec):
            return []
        label = str(rec.get("label") or rec.get("provider") or "?")
        return [(label, rec.get("project"), _run_cost(rec), ts, None, None)]
    if rec.get("kind") == "session":
        lead = str(rec.get("lead") or "")
        if not lead:
            return []
        sid = rec.get("session")
        sid = str(sid) if sid else None
        snap = str(rec.get("ts") or "")
        parts = _spend_parts(rec)
        if parts is None:
            return [(lead, rec.get("project"), _session_cost(rec), ts, sid, snap)]
        return [(lead, rec.get("project"), cost, when, sid, snap) for cost, when in parts]
    return []


def spend_cache_update():
    """Update the spend cache from the usage ledger. → (records, changed). Records: {label, project, cost, ts, sid,
    snap, n}. Restarts on a shrunken ledger (byte offset, like session_tokens); a reset (baseline/month) is applied at
    read time, so it takes effect at once without re-reading the ledger. Session records are deduplicated by session
    id: each SessionEnd snapshot is cumulative, so only the last one per session counts (all its parts). A cache that
    is up to date takes no lock; a hook or the status line that finds the lock busy uses the cached records as they are."""
    cache = read_json(SPEND_CACHE_FILE, {}, recover_corrupt=True)
    records = cache.get("records") if isinstance(cache, dict) and isinstance(cache.get("records"), list) else []
    try:
        size = USAGE_FILE.stat().st_size
    except OSError:
        size = 0
    if isinstance(cache, dict) and cache.get("format") == 4 and cache.get("offset") == size:
        return records, False
    try:
        with state_lock(ORCH_HOME / ".state.lock"):
            return _spend_cache_update()
    except StateError:
        if _quiet_state:
            return records, False
        raise


def _spend_cache_update():
    cache = read_json(SPEND_CACHE_FILE, {}, recover_corrupt=True)
    if not isinstance(cache, dict):
        cache = {}
    records = cache.get("records") if isinstance(cache.get("records"), list) else []
    offset = cache.get("offset") if isinstance(cache.get("offset"), int) else 0
    changed = False
    if cache.get("format") != 4:                          # migrate: v3 counted a session wholly at its end
        cache = {"format": 4, "offset": 0}
        records, offset, changed = [], 0, True
    try:
        size = USAGE_FILE.stat().st_size
    except OSError:
        size = 0
    if size < offset:                                     # the ledger was rotated/shrunk: recompute from zero
        records, offset, changed = [], 0, True
    if size > offset:
        try:
            with USAGE_FILE.open("rb") as f:
                f.seek(offset)
                data = f.read(size - offset)
        except OSError:
            data = b""
        nl = data.rfind(b"\n")
        consumed = len(data) if nl == len(data) - 1 else (nl + 1 if nl != -1 else 0)
        new = []
        for line in data[:consumed].decode("utf-8", "replace").splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            for n, r in enumerate(record_spend(rec)):     # n: the part's place in its snapshot
                new.append({"label": r[0], "project": r[1], "cost": r[2], "ts": r[3].isoformat(), "sid": r[4],
                            "snap": r[5], "n": n})
        if new:
            records = records + new
        if consumed:                                      # persist the offset even when nothing counted
            changed = True
        offset += consumed
    if changed:
        # keep only the last snapshot per session: all its records, in ledger order (they arrive together). A new
        # snapshot starts at a record with another marker or at the first part (n == 0).
        gens, last = [], {}
        for r in records:
            sid = r.get("sid")
            if sid is None:
                gens.append(0)
                continue
            gen, snap = last.get(sid, (0, None))
            if gen == 0 or r.get("n") in (0, None) or r.get("snap") != snap:
                gen += 1
            last[sid] = (gen, r.get("snap"))
            gens.append(gen)
        records = [r for r, gen in zip(records, gens) if r.get("sid") is None or gen == last[r["sid"]][0]]
        write_json(SPEND_CACHE_FILE, {"format": 4, "offset": offset, "records": records})
    return records, changed


def current_spend(scope, where, records=None):
    """Dollars spent against `scope`'s counter for a directory (runs + lead sessions), since the counter's start."""
    if records is None:
        records, _ = spend_cache_update()
    config = load_spend_limits()[0]
    key = counter_key(config, scope, spend_where(where))[0]
    start = counter_start(config, scope, where)
    if start is None:                                    # manual scope not yet seen: nothing counts yet
        return 0.0
    total = 0.0
    for r in records:
        if r.get("label") != scope:
            continue
        if counter_key(config, r.get("label"), r.get("project") or "")[0] != key:
            continue
        ts = parse_iso(str(r.get("ts") or ""))
        if ts is not None and ts < start:
            continue
        total += float(r.get("cost") or 0)
    return total


def profile_api_scope(prof, provider, where=None):
    """The spend scope label for a run/launch on this profile, or None when it does not bill to an API key."""
    provider = (provider or "").lower()
    if prof.name == "off":
        return None
    if provider == "deepseek":
        return prof.label
    if prof.explicit and prof.data.get("key"):
        return prof.label
    return None


def spend_scope(provider, where=None):
    """The API-billed scope label active for a directory (re-resolves the profile), or None."""
    try:
        prof = resolve_profile(provider, where or project_dir())
    except ProfileError:
        return None
    return profile_api_scope(prof, provider, where or project_dir())


def api_billed(provider, where=None):
    return spend_scope(provider, where) is not None


def active_profiles(where):
    """[(profile, spend scope or None)]: the profile each provider resolves to in a directory (a fallback while its
    key is exhausted), in provider order; a provider whose profile cannot be resolved is left out."""
    where = where or project_dir()
    out = []
    for provider in known_providers():
        try:
            prof = resolve_profile(provider, where)
        except ProfileError:
            continue
        out.append((prof, profile_api_scope(prof, provider, where)))
    return out


def api_scopes(where):
    """The API-billed scope labels active in a directory (DeepSeek + any key profiles), in provider order."""
    return [scope for _, scope in active_profiles(where) if scope]


def preferred_api_profiles(where):
    """[(display name, [task types])] of the API-billed profiles active in a directory that have `prefer for`: while
    their key has budget they go first for those task types, ahead of Claude in a SURPLUS. An exhausted profile
    resolves to its fallback, whose own `prefer for` (if any) applies instead."""
    try:
        out = []
        for prof, scope in active_profiles(where):
            types = prof.data.get("prefer_for")
            types = [types] if isinstance(types, str) else list(types or [])
            if scope and types and prof.provider != "claude":
                out.append((scope_name(prof.label), [str(t) for t in types]))
        return out
    except Exception:
        return []


def counter_cover(config, scope, where):
    """What the counter covers, for the user: 'manual, since Nov 02 18:40' or 'this month'."""
    if resolve_reset(config, scope, where) == "manual":
        ts = get_baseline(config, scope, where)
        t = parse_iso(str(ts)) if ts else None
        return "manual, since %s" % t.strftime("%b %d %H:%M") if t else "manual"
    return "this month"


def _way_out(config, scope, where):
    """The operator's way out of a blocked scope, for messages."""
    if resolve_reset(config, scope, where) == "manual":
        return "top up and orch spend reset %s [--limit N]" % scope
    return "raise the limit (orch spend limit %s N) or wait for the 1st" % scope


def scope_fallback_note(scope):
    """' Without --profile, DeepSeek@personal (its fallback) takes over.' for a scope whose profile has a usable
    fallback, else ''. Only an explicit --profile can still reach a refusal for such a scope."""
    provider, _, name = (scope or "").partition("@")
    try:
        data, err = load_profiles()
        if err or not name:
            return ""
        _, profs = provider_section(data, provider.lower())
        d = profs.get(name.lower())
        if not isinstance(d, dict):
            return ""
        target = fallback_target(Profile(provider.lower(), name.lower(), d, "profile", True), profs)
    except Exception:
        return ""
    return (" Without --profile, %s (its fallback) takes over." % scope_name(target.label)) if target else ""


def _spend_warn(scope, spent, eff, kind, config=None, where=None):
    limit = _limit_number(eff)
    if limit is None or limit <= 0 or spent < limit * SPEND_WARN_PCT / 100.0:
        return None
    mode = eff.get("mode" if kind == "executor" else "lead_mode")
    if config is None:
        config = load_spend_limits()[0]
    if where is None:
        where = project_dir()
    return "%s: $%.2f of $%.2f (%s, %.0f%%), %s mode %s — orch spend" % (
        scope_name(scope), spent, limit, counter_cover(config, scope, where), spent / limit * 100, kind, mode)


def spend_start(scope, where):
    """Pre-start check of an executor run. → (allowed, line). Refuses at the limit under stop/evaluate; --force
    does not bypass it; a broken limits file refuses (fail-closed, like profiles)."""
    config, err = load_spend_limits()
    if err:
        return False, ("SPEND_LIMIT %s — %s; fix or remove it, then retry" % (scope_name(scope), err))
    ensure_baseline(scope, where)
    eff = resolve_spend(config, scope, where)
    spent = current_spend(scope, where)
    limit = _limit_number(eff)
    if limit is None:
        return True, None
    if eff.get("mode") in ("stop", "evaluate") and spent >= limit:
        return False, ("SPEND_LIMIT %s — $%.2f already spent (%s; limit $%.2f, mode %s). %s.%s" %
                       (scope_name(scope), spent, counter_cover(config, scope, where), limit, eff.get("mode"),
                        _way_out(config, scope, where), scope_fallback_note(scope)))
    return True, _spend_warn(scope, spent, eff, "executor", config, where)


def spend_lead_start(scope, where):
    """Pre-start check of a lead session (orch launch). → (allowed, line)."""
    config, err = load_spend_limits()
    if err:
        return False, ("SPEND_LIMIT %s — %s; fix or remove it, then retry" % (scope_name(scope), err))
    ensure_baseline(scope, where)
    eff = resolve_spend(config, scope, where)
    spent = current_spend(scope, where)
    limit = _limit_number(eff)
    if limit is None:
        return True, None
    if eff.get("lead_mode") in ("stop", "evaluate") and spent >= limit:
        return False, ("SPEND_LIMIT %s — $%.2f already spent (%s; limit $%.2f, lead mode %s). %s." %
                       (scope_name(scope), spent, counter_cover(config, scope, where), limit, eff.get("lead_mode"),
                        _way_out(config, scope, where)))
    return True, _spend_warn(scope, spent, eff, "lead", config, where)


def spend_lead_key(scope, where):
    """orch key refusal: a Claude lead's requests fail past the threshold (stop at 100%, evaluate past the
    overrun). → (allowed, line)."""
    config, err = load_spend_limits()
    if err:
        return False, ("SPEND_LIMIT %s — %s; fix or remove it, then retry" % (scope_name(scope), err))
    eff = resolve_spend(config, scope, where)
    spent = current_spend(scope, where)
    kill = spend_kill_at(eff, "lead_mode")
    if kill is not None and spent >= kill:
        return False, ("SPEND_LIMIT %s — $%.2f of the $%.2f limit spent (%s; lead mode %s). %s" %
                       (scope_name(scope), spent, _limit_number(eff), counter_cover(config, scope, where),
                        eff.get("lead_mode"), _way_out(config, scope, where)))
    return True, None


