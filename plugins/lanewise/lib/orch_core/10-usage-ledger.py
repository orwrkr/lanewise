# ───────────────────────── usage ledger ─────────────────────────
#
# ~/.lanewise/usage.jsonl, one record per line: kind run (CLI executor: model, task, tokens from the adapter's
# usage.json), handoff (manual task: agent, model, minutes) and session (Claude Code main thread + subagents,
# snapshot at SessionEnd so the numbers outlive transcript cleanup). `orch usage` joins them per session.

USAGE_FILE = ORCH_HOME / "usage.jsonl"

# ───────────────────────── daily totals (orch usage --daily) ─────────────────────────
#
# ~/.lanewise/daily_usage.json keeps each local day's tokens by project × provider × model × account (a profile
# label — deepseek@work, codex, claude — never a key), with the estimated cost at that day's prices, the points of
# each subscription limit used that day, and each day's first and last account balance. It is kept for 60 days and
# does not depend on transcripts surviving. Three sources, each folded with its own rule against counting twice:
#   runs     — the usage log's `run` records, deduplicated by their own id per day. The byte offset and a hash of
#              the first line only speed up reads; truncating or replacing the log never removes saved totals.
#   sessions — one slab per session id, each counter replaced by the larger of the stored and the new value on
#              every fold, so a live session's counter file and its SessionEnd transcript (or repeated folds) can
#              never count a token twice: a fold can only add. A session that ended is folded from the full
#              transcript (source "end"); one whose counter file has been unchanged for a day is folded from the
#              file (source "live") — that is what a crashed session leaves.
#              Each source covers the whole transcript: Claude Code only appends (compaction appends a summary).
#              A counter rebuilt from offset 0 covers it too; a session resuming after its folded file was deleted
#              rebuilds from 0. This is why the max merge works across all these sources.
#   limits   — the subscription samples (Claude's snapshot history, Codex's week history and current windows): the
#              positive steps between consecutive samples, each on the day of the later sample; a window whose reset
#              changed counts its first figure in full. A sample missed while nothing ran puts its whole step on the
#              day of the next sample; the interval total stays right.
# Days older than DAILY_KEEP_DAYS are pruned whenever the store is written.

DAILY_FILE = ORCH_HOME / "daily_usage.json"
DAILY_MARKER = ORCH_HOME / ".daily-fold"
DAILY_STALE_BATCH = 20
DAILY_FORMAT = 1
DAILY_KEEP_DAYS = 60           # today and the 59 days before it are kept
DAILY_DEFAULT_DAYS = 14        # `orch usage --daily` without --days/--since
DAILY_FOLD_GAP_SECONDS = 600   # the hooks fold the limit samples at most this often
DAILY_README = ("Lanewise daily token totals: per local day and project × provider × model × account, the "
                "subscription limit points used, and each day's first and last account balance; 60 days.")


def session_id():
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("ORCH_SESSION_ID") or None


def learn_session_id(data):
    if not session_id() and data.get("session_id"):
        os.environ["ORCH_SESSION_ID"] = str(data["session_id"])


def ledger_append(rec):
    if os.environ.get("ORCH_USAGE_LOG", "1") == "0":
        return
    try:
        USAGE_FILE.parent.mkdir(parents=True, exist_ok=True)
        with state_lock(ORCH_HOME / ".usage.lock"):
            with USAGE_FILE.open("a", encoding="utf-8") as f:
                f.write(json.dumps(dict(rec, ts=iso_precise(now())), ensure_ascii=False) + "\n")
    except (OSError, StateError):
        pass                     # the ledger is a convenience: never fail a run because of it


def ledger_read():
    """The ledger's records: a line that isn't a JSON object (damaged, or a stray value) is skipped, never fatal."""
    out = []
    try:
        with USAGE_FILE.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict):
                    out.append(rec)
    except OSError:
        pass
    return out


def task_title(prompt, explicit=None):
    if explicit:
        return explicit.strip()[:80]
    for line in prompt.splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line[:80] + ("…" if len(line) > 80 else "")
    return ""


def read_usage(run_dir):
    """Adapter's usage.json → {input_tokens (uncached), cached_input_tokens, output_tokens, model?} or None."""
    u = read_json(run_dir / "usage.json", None)
    if not isinstance(u, dict):
        return None
    clean = {k: int(u[k]) for k in ("input_tokens", "cached_input_tokens", "output_tokens")
             if isinstance(u.get(k), (int, float))}
    if u.get("model"):
        clean["model"] = str(u["model"])
    if isinstance(u.get("models"), dict):
        clean["models"] = u["models"]
    return clean or None


def day_str(t):
    """The local day of a datetime, YYYY-MM-DD."""
    return t.astimezone().date().isoformat()


def day_start(day):
    """Local midnight of a YYYY-MM-DD day, with that day's UTC offset."""
    return dt.datetime.strptime(str(day), "%Y-%m-%d").astimezone()


def day_list(since, until):
    """Every YYYY-MM-DD day from `since` to `until`, both included."""
    out, d = [], since
    while d <= until:
        out.append(d.isoformat())
        d += dt.timedelta(days=1)
    return out


def transcript_counts(u):
    """{in, cr, cw, out} of a Claude Code message's usage: raw input, cache reads, cache writes, output."""
    u = u if isinstance(u, dict) else {}
    return {"in": tok_int(u.get("input_tokens")), "cr": tok_int(u.get("cache_read_input_tokens")),
            "cw": tok_int(u.get("cache_creation_input_tokens")), "out": tok_int(u.get("output_tokens"))}


def ledger_counts(u):
    """{in, cr, cw, out} of a ledger run record's usage (the adapter's own names)."""
    u = u if isinstance(u, dict) else {}
    return {"in": tok_int(u.get("input_tokens")), "cr": tok_int(u.get("cached_input_tokens")),
            "cw": tok_int(u.get("cache_creation_input_tokens")), "out": tok_int(u.get("output_tokens"))}


def daily_message_cost(model, counts, stamp=None):
    """USD of one transcript message at its model's price at its own time (cache writes at the input rate), or 0.
    Priced per message, so a session's day is priced at the times it ran, not at one time for the whole day."""
    usage = {"input_tokens": tok_int(counts.get("in")) + tok_int(counts.get("cw")),
             "cached_input_tokens": tok_int(counts.get("cr")), "output_tokens": tok_int(counts.get("out"))}
    t = parse_iso(str(stamp).replace("Z", "+00:00")) if isinstance(stamp, str) and stamp else None
    try:
        return usage_cost(usage, transcript_provider(model), str(model), when=t or now())
    except Exception:
        return 0.0


def daily_shape(data):
    """Fill absent fields; reject malformed fields so their saved copy can be preserved before recovery."""
    import math
    if not isinstance(data, dict):
        raise ValueError("expected a daily store object")
    for key in ("runs", "run_ids", "sessions", "limits", "balances", "limit_tails"):
        if key in data and not isinstance(data[key], dict):
            raise ValueError("expected an object for " + key)
        if not isinstance(data.get(key), dict):
            data[key] = {}
        if any(not isinstance(v, dict) for v in data[key].values()):
            raise ValueError("expected objects inside " + key)
    for slab in data["sessions"].values():
        if not isinstance(slab.get("days"), dict):
            raise ValueError("expected session days")
    for key in ("limits", "balances", "limit_tails"):
        for by in data[key].values():
            if any(not isinstance(v, dict) for v in by.values()):
                raise ValueError("expected objects inside " + key)
    for by in data["limits"].values():
        for windows in by.values():
            if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)
                   for v in windows.values()):
                raise ValueError("expected finite limit points")
    buckets = list(data["runs"].values())
    for slab in data["sessions"].values():
        buckets.extend(slab["days"].values())
    for bucket in buckets:
        if not isinstance(bucket, dict) or any(not isinstance(v, dict) for v in bucket.values()):
            raise ValueError("expected daily token leaves")
        for leaf in bucket.values():
            for k in ("runs", "in", "cr", "cw", "out", "cost"):
                v = leaf.get(k, 0)
                if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
                    raise ValueError("expected a finite token/cost figure")
    if "ledger_offset" in data and (isinstance(data["ledger_offset"], bool) or
                                     not isinstance(data["ledger_offset"], int)):
        raise ValueError("expected an integer ledger offset")
    if not isinstance(data.get("ledger_offset"), int):
        data["ledger_offset"] = 0
    return data


def daily_read():
    """The daily store as it is saved (no lock: write_json replaces it atomically, so a reader sees one whole file)."""
    data = read_json(DAILY_FILE, {}, recover_corrupt=True)
    try:
        return daily_shape(data)
    except ValueError:
        with state_lock(ORCH_HOME / ".state.lock"):
            data = read_json(DAILY_FILE, {}, recover_corrupt=True)
            try:
                return daily_shape(data)
            except ValueError:
                backup = Path(str(DAILY_FILE) + ".corrupt")
                n = 1
                while backup.exists():
                    backup = Path(str(DAILY_FILE) + ".corrupt.%d" % n)
                    n += 1
                try:
                    DAILY_FILE.rename(backup)
                except OSError as ex:
                    raise StateError("cannot preserve %s: %s" % (DAILY_FILE, ex))
                warn_state(DAILY_FILE, "corrupt state preserved as %s; starting fresh" % backup)
                return daily_shape({})


def daily_prune(store):
    """Drop the days older than DAILY_KEEP_DAYS, and the sessions left with none. True when anything went."""
    cutoff = (now().date() - dt.timedelta(days=DAILY_KEEP_DAYS - 1)).isoformat()
    changed = False
    for key in ("runs", "run_ids", "limits", "balances"):
        days = store.get(key) if isinstance(store.get(key), dict) else {}
        for day in [d for d in list(days) if not isinstance(d, str) or d < cutoff]:
            del days[day]
            changed = True
    sessions = store.get("sessions") if isinstance(store.get("sessions"), dict) else {}
    for sid in list(sessions):
        slab = sessions[sid]
        days = slab.get("days") if isinstance(slab, dict) else None
        if not isinstance(days, dict):
            del sessions[sid]
            changed = True
            continue
        for day in [d for d in list(days) if not isinstance(d, str) or d < cutoff]:
            del days[day]
            changed = True
        if not days:
            del sessions[sid]
            changed = True
    if store.get("pruned_before") != cutoff:
        store["pruned_before"] = cutoff
        changed = True
    return changed


def daily_update(mutator):
    """Read-modify-write the store under the home lock: `mutator(store)` returns True when it changed something;
    pruning runs in the same pass. → (store, changed). Read errors propagate: silent callers skip the update,
    and a report explains that it could not read the history. The status line never calls this function.
    With the usage log switched off (ORCH_USAGE_LOG=0) the daily totals are off too: nothing is written."""
    if os.environ.get("ORCH_USAGE_LOG", "1") == "0":
        return daily_read(), False
    with state_lock(ORCH_HOME / ".state.lock"):
        store = daily_read()
        changed = bool(mutator(store))
        if daily_prune(store):
            changed = True
        if changed:
            store["_readme"] = DAILY_README
            store["version"] = DAILY_FORMAT
            write_json(DAILY_FILE, store, compact=True)
        return store, changed


def daily_run_row(rec):
    """(day, project, provider, model, account, paid_via, {runs, in, cr, cw, out, cost}) of a ledger `run` record,
    or None. A run counts on the day it ended (its record's time), with the cost it reported."""
    if not isinstance(rec, dict) or rec.get("kind") != "run":
        return None
    project, u = rec.get("project"), rec.get("usage")
    provider = str(rec.get("provider") or "").strip().lower()
    if not project or not provider or not isinstance(u, dict):
        return None
    ts = parse_iso(str(rec.get("ts") or ""))
    if ts is None:
        return None
    model = str(rec.get("model") or u.get("model") or "(mixed)")
    account = str(rec.get("label") or provider).lower()
    paid_via = "api" if _api_billed_record(rec) else "subscription"
    counts = ledger_counts(u)
    counts["runs"] = 1
    cost = rec.get("cost_usd")
    if isinstance(cost, bool) or not isinstance(cost, (int, float)) or cost != cost or abs(cost) == float("inf"):
        try:
            cost = usage_cost(u, provider, model, when=ts)
        except Exception:
            cost = 0.0
    counts["cost"] = float(cost)
    return day_str(ts), canon_path(project), provider, model, account, paid_via, counts


def daily_fold_runs(store):
    """Fold by run id, with an offset and first-line fingerprint as read optimisations only."""
    import hashlib
    try:
        size = USAGE_FILE.stat().st_size
        with USAGE_FILE.open("rb") as f:
            first = f.readline()
        fingerprint = hashlib.sha256(first).hexdigest()[:16] if first.endswith(b"\n") else None
    except OSError:
        return False
    offset = tok_int(store.get("ledger_offset"))
    changed = False
    if size < offset or fingerprint != store.get("ledger_first"):
        offset = 0
    if size > offset:
        try:
            with USAGE_FILE.open("rb") as f:
                f.seek(offset)
                data = f.read(size - offset)
        except OSError:
            data = b""
        nl = data.rfind(b"\n")
        consumed = len(data) if nl == len(data) - 1 else (nl + 1 if nl != -1 else 0)
        runs = store.get("runs") if isinstance(store.get("runs"), dict) else {}
        for line in data[:consumed].decode("utf-8", "replace").splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            row = daily_run_row(rec)
            if row is None:
                continue
            day, project, provider, model, account, paid_via, counts = row
            run_id = str(rec.get("id") or "")
            if not run_id:                  # old external fixtures may lack ids: stable fallback, never an offset
                run_id = hashlib.sha256(line.encode("utf-8")).hexdigest()
            ids = store.setdefault("run_ids", {}).setdefault(day, {})
            if run_id in ids:
                continue
            ids[run_id] = True
            leaf = runs.setdefault(day, {}).setdefault(
                "|".join((project, provider, model, account, paid_via)), {})
            for k in ("runs", "in", "cr", "cw", "out"):
                leaf[k] = tok_int(leaf.get(k)) + tok_int(counts.get(k))
            leaf["cost"] = round(float(leaf.get("cost") or 0.0) + counts["cost"], 6)
        store["runs"] = runs
        if consumed:
            offset += consumed
            changed = True
    if store.get("ledger_offset") != offset:
        store["ledger_offset"] = offset
        changed = True
    if store.get("ledger_first") != fingerprint:
        store["ledger_first"] = fingerprint
        changed = True
    return changed


def daily_merge_session(store, sid, project, daily, source, paid_via=None):
    """Merge one session's per-day counts into its slab: each counter becomes the larger of the stored and the new
    value, so repeated folds never add a token twice (the rule written at the top of this part). → changed.
    `daily` is {day: {account: {model: {in, cr, cw, out, cost}}}}."""
    if not sid or not isinstance(daily, dict) or not daily:
        return False
    sessions = store.get("sessions")
    if not isinstance(sessions, dict):
        sessions = store["sessions"] = {}
    slab = sessions.get(sid)
    if not isinstance(slab, dict):
        slab = sessions[sid] = {}
    days = slab.get("days")
    if not isinstance(days, dict):
        days = slab["days"] = {}
    changed = False
    if project:
        project = canon_path(project)
        if slab.get("project") != project:
            slab["project"] = project
            changed = True
    for day, accounts in daily.items():
        if not (isinstance(day, str) and len(day) == 10) or not isinstance(accounts, dict):
            continue
        for account, models in accounts.items():
            account = str(account).lower()
            if not isinstance(models, dict):
                continue
            for model, counts in models.items():
                if not isinstance(counts, dict):
                    continue
                provider = transcript_provider(model)
                bill = paid_via if paid_via in ("api", "subscription") else slab.get("paid_via")
                bill = bill or ("subscription" if account == "claude" else "api")
                if account != "claude":
                    bill = "api"
                key = "|".join((provider, str(model), account, bill))
                leaf = days.setdefault(day, {}).setdefault(key, {})
                for k in ("in", "cr", "cw", "out"):
                    v = tok_int(counts.get(k))
                    if v > tok_int(leaf.get(k)):
                        leaf[k] = v
                        changed = True
                cost = round(float(counts.get("cost") or 0.0), 6)
                if cost > round(float(leaf.get("cost") or 0.0), 6):
                    leaf["cost"] = cost
                    changed = True
    if changed:
        slab["at"] = iso(now())
        slab["source"] = source
        if paid_via:
            slab["paid_via"] = paid_via
    return changed


def daily_by_account(daily, accounts):
    """{day: {model: counts}} → {day: {account: {model: counts}}}, each model under the account of its provider
    (`accounts` is {provider: label}; a provider without one keeps its own name)."""
    out = {}
    for day, models in (daily or {}).items():
        if not isinstance(day, str) or not isinstance(models, dict):
            continue
        for model, counts in models.items():
            if not isinstance(counts, dict):
                continue
            prov = transcript_provider(model)
            acct = str(accounts.get(prov) or prov).lower()
            out.setdefault(day, {}).setdefault(acct, {})[str(model)] = counts
    return out


def session_accounts(sid, where=None):
    """{provider: account label} a session's counters were filed under: the mapping its counter file froze, else the
    current one — claude on the native account of `where`, deepseek on the lead's label. Reading the frozen mapping
    is what keeps a SessionEnd fold on the same account as the live folds, so the larger-value rule cannot keep a
    day's tokens twice, under two accounts."""
    entry = read_session_entry(session_tokens_path(sid)) if sid else None
    out = {}
    if isinstance(entry, dict) and isinstance(entry.get("accounts"), dict):
        out = {str(k): str(v).lower() for k, v in entry["accounts"].items() if v}
    out.setdefault("claude", native_account(where))
    lead = lead_provider_label("deepseek")
    if lead:
        out.setdefault("deepseek", lead)
    return out


def daily_session_end(sid, project, daily, where=None):
    """Fold a finished session's transcript counts (source "end") into the daily store. Never raises: a SessionEnd must
    not fail for the totals. → changed."""
    if not daily:
        return False
    try:
        session_paid_via_note(sid, where or project)
        entry = read_session_entry(session_tokens_path(sid), strict=True)
        payload = daily_by_account(daily, session_accounts(sid, where or project))
        return daily_update(lambda store: daily_merge_session(store, sid, project, payload, "end",
                                                               entry.get("paid_via")))[1]
    except Exception:
        return False


def daily_session_source(entry, fallback_sid=None):
    """(sid, project, {day: {account: {model: counts}}}) of a saved status-line entry, or None with nothing to
    count. The entry names its own session: a hashed file name cannot be turned back into the id."""
    if not isinstance(entry, dict):
        return None
    daily = entry.get("daily") if isinstance(entry.get("daily"), dict) else {}
    if not daily:
        return None
    sid = entry.get("session") if isinstance(entry.get("session"), str) and entry.get("session") else fallback_sid
    if not sid:
        return None
    accounts = entry.get("accounts") if isinstance(entry.get("accounts"), dict) else {}
    accounts = {str(k): str(v).lower() for k, v in accounts.items() if v}
    project = entry.get("project") if isinstance(entry.get("project"), str) and entry.get("project") else None
    return str(sid), project, daily_by_account(daily, accounts)


def session_project(sid):
    """The project of a session whose counter file does not name one: its consumer entry, else this directory."""
    try:
        data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    except StateError:
        data = {}
    entry = data.get(sid) if isinstance(data, dict) else None
    if isinstance(entry, dict) and entry.get("project"):
        return canon_path(entry["project"])
    return canon_path(project_root(project_dir()))


def daily_session_paths(include_all=False, sid=None):
    """The counter files to fold: every one (a report), or `sid`'s own file plus at most DAILY_STALE_BATCH stale
    ones — unchanged for a day, which is what a crashed session leaves — oldest first, whatever order the file
    system lists them in: the oldest is the nearest to losing its transcript."""
    cutoff = time.time() - SESSION_KEEP_SECONDS
    out, stale_found, extra = [], [], session_tokens_path(sid) if sid else None
    try:
        with os.scandir(str(SESSION_TOKENS_DIR)) as it:
            for e in it:
                if not e.name.endswith(".json"):
                    continue
                path = Path(e.path)
                try:
                    mtime = e.stat().st_mtime
                except OSError:
                    continue
                if include_all or (extra is not None and path == extra):
                    out.append(path)
                elif mtime < cutoff:
                    stale_found.append((mtime, e.name, path))
    except OSError:
        pass
    stale_found.sort()
    return out + [path for _, _, path in stale_found[:DAILY_STALE_BATCH]]


def daily_session_items(paths):
    """Read counters strictly; failed reads/parses stay for the next try. Includes successfully read empty files."""
    items = []
    for path in paths:
        try:
            entry = read_session_entry(path, strict=True)
            daily = entry.get("daily", {})
            if not isinstance(daily, dict) or any(not isinstance(models, dict) or
                    any(not isinstance(counts, dict) for counts in models.values()) for models in daily.values()):
                raise ValueError("expected daily session counters")
        except (OSError, ValueError):
            continue
        stem = path.name[:-5] if path.name.endswith(".json") else path.name
        item = daily_session_source(entry, stem)
        if item is not None:
            sid, project, daily = item
            item = (sid, project or session_project(sid), daily, entry.get("paid_via"))
        items.append((path, item))
    return items


def daily_fold_session_file(path):
    """Fold one counter file. True when it may go (its counts went in, or it had none). A busy home lock raises
    StateError: the caller keeps the file for the next sweep."""
    with state_lock(ORCH_HOME / ".state.lock"):
        items = daily_session_items([Path(path)])
        if not items:
            return False
        daily_update(lambda store: daily_merge_items(store, items))
        return True


def daily_merge_items(store, items):
    changed = False
    for _path, item in items:
        if item is not None:
            sid, project, daily, paid_via = item
            changed = daily_merge_session(store, sid, project, daily, "live", paid_via) or changed
    return changed


def daily_remove_stale(items):
    """Called only after a successful store update, still under the lock protecting counter saves."""
    cutoff = time.time() - SESSION_KEEP_SECONDS
    for path, _item in items:
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            pass


def daily_maintenance(sid=None, ended=False):
    """Machine-wide throttled limit scan and one stale batch; SessionEnd also folds its own counters."""
    try:
        def due():
            try:
                return time.time() - DAILY_MARKER.stat().st_mtime >= DAILY_FOLD_GAP_SECONDS
            except FileNotFoundError:
                return True

        if not ended and not due():       # no store read on the common prompt path
            return
        with state_lock(ORCH_HOME / ".state.lock"):
            maintenance = due()
            paths = daily_session_paths() if maintenance else []
            if ended and sid and session_tokens_path(sid) not in paths:
                paths.append(session_tokens_path(sid))
            items = daily_session_items(paths)
            if maintenance:
                ORCH_HOME.mkdir(parents=True, exist_ok=True)
                DAILY_MARKER.touch()     # even an unchanged scan is throttled

            def mutate(store):
                changed = daily_fold_limits(store, force=True) if maintenance else False
                return daily_merge_items(store, items) or changed
            daily_update(mutate)
            daily_remove_stale(items)
    except Exception:
        pass


def daily_refresh():
    """Fold everything a report reads before it: every session's counter file (a live session's too), the usage
    log's runs, and a forced limit scan. → the store. A busy home lock raises StateError."""
    with state_lock(ORCH_HOME / ".state.lock"):
        items = daily_session_items(daily_session_paths(include_all=True))

        def mutate(store):
            changed = daily_fold_limits(store, force=True)
            changed = daily_fold_runs(store) or changed
            return daily_merge_items(store, items) or changed
        store = daily_update(mutate)[0]
        daily_remove_stale(items)
        return store


def daily_sample(at, used, resets_at):
    """(time, used %, resets_at ISO) of one limit sample, or None when it is malformed."""
    t = parse_iso(str(at or "").replace("Z", "+00:00"))
    if isinstance(used, bool) or not isinstance(used, (int, float)) or t is None:
        return None
    return t, float(used), (str(resets_at) if resets_at else None)


def codex_account_label(home):
    """The profile label of a CODEX_HOME (`codex@work` when a profile's `home` is that folder), else `codex`: the
    account the limits belong to."""
    target = os.path.normcase(os.path.expanduser(str(home or "")))
    try:
        data, err = load_profiles()
    except Exception:
        data, err = None, "error"
    if target and not err and isinstance(data, dict):
        _, profs = provider_section(data, "codex")
        for name, d in profs.items():
            if isinstance(d, dict) and d.get("home") and \
                    os.path.normcase(os.path.expanduser(local_path(str(d["home"])))) == target:
                return "codex@" + str(name).lower()
    return "codex"


def daily_limit_samples():
    """[(account, window, [(time, used %, resets_at)])] of the subscription snapshots: Claude's 5-hour history and
    weekly history plus the current windows, and each Codex account's weekly history plus the current windows."""
    out = []
    try:
        snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
    except StateError:
        snap = {}
    if isinstance(snap, dict):
        for window, key in (("five_hour", "history"), ("seven_day", "week_history")):
            samples = [daily_sample(h[0], h[1], h[2]) for h in (snap.get(key) or [])
                       if isinstance(h, list) and len(h) == 3]
            current = snap.get(window)
            if isinstance(current, dict):
                samples.append(daily_sample(current.get("updated") or snap.get("updated"),
                                            current.get("used"), current.get("resets_at")))
            out.append(("claude", window, [s for s in samples if s]))
    try:
        cache = read_json(CODEX_USAGE_FILE, {}, recover_corrupt=True)
    except StateError:
        cache = {}
    for home, entry in sorted((cache.items() if isinstance(cache, dict) else [])):
        if not isinstance(entry, dict) or not entry.get("updated"):
            continue
        account = codex_account_label(home)
        for window, key in (("five_hour", None), ("seven_day", "week_history")):
            samples = [daily_sample(h[0], h[1], h[2]) for h in ((entry.get(key) or []) if key else [])
                       if isinstance(h, list) and len(h) == 3]
            current = entry.get(window)
            if isinstance(current, dict):
                samples.append(daily_sample(current.get("measured") or entry.get("updated"),
                                            current.get("used"), current.get("resets_at")))
            out.append((account, window, [s for s in samples if s]))
    return out


def daily_limit_steps(tail, samples):
    """([(day, points)], new_tail) of one window's samples: the rise between consecutive samples of one window; a
    window whose reset time changed restarted, so its first figure counts in full. A lower figure within one window
    is a stale reading: it adds nothing and does not lower the tail. Samples at the same moment are one."""
    events, seen = [], set()
    state = dict(tail) if isinstance(tail, dict) else None
    for t, used, reset in sorted(samples, key=lambda s: s[0]):
        key = (iso(t), round(used, 4), reset)
        if key in seen:
            continue
        seen.add(key)
        if state is None:
            state = {"at": iso(t), "used": used, "resets_at": reset, "day": day_str(t)}
            continue
        last = parse_iso(str(state.get("at") or ""))
        if last is not None and t <= last:      # the same moment: the higher figure of that moment is the real one
            old = float(state.get("used") or 0.0)
            if reset == state.get("resets_at") and used > old:
                events.append((day_str(t), used - old))
                state = {"at": iso(t), "used": used, "resets_at": reset, "day": day_str(t)}
            continue
        if reset != state.get("resets_at"):
            step = max(used, 0.0)
        else:
            step = max(used - float(state.get("used") or 0.0), 0.0)
        if step > 0:
            events.append((day_str(t), step))
        same = reset == state.get("resets_at")
        state = {"at": iso(t), "used": max(used, float(state.get("used") or 0.0)) if same else used,
                 "resets_at": reset, "day": day_str(t)}
    return events, state


def daily_fold_limits(store, force=False):
    """Fold subscription samples per day and window. The caller's small marker throttles hook scans;
    reports always scan. True only when the stored samples or points changed."""
    t = now()
    if not USAGE_SNAPSHOT.exists() and not CODEX_USAGE_FILE.exists():
        return False
    limits = store.get("limits") if isinstance(store.get("limits"), dict) else store.setdefault("limits", {})
    tails = store.get("limit_tails") if isinstance(store.get("limit_tails"), dict) else store.setdefault("limit_tails", {})
    changed = False
    for account, window, samples in daily_limit_samples():
        if not samples:
            continue
        tail = tails.get(account) if isinstance(tails.get(account), dict) else {}
        events, state = daily_limit_steps(tail.get(window), samples)
        for sampled_at, _used, _reset in samples:
            by = limits.setdefault(day_str(sampled_at), {}).setdefault(account, {})
            if window not in by:             # zero steps still provide coverage for this window on that day
                by[window] = 0.0
                changed = True
        for day, points in events:
            by = limits.setdefault(day, {}).setdefault(account, {})
            by[window] = round(float(by.get(window) or 0.0) + points, 4)
            changed = True
        if state is not None:
            by = limits.setdefault(state.get("day") or day_str(t), {}).setdefault(account, {})
            if window not in by:                 # a sample for that day, even with no rise: the limit data exists
                by[window] = 0.0
                changed = True
        if state is not None and state != tail.get(window):
            tails.setdefault(account, {})[window] = state
            changed = True
    return changed


def daily_balance_note(results, stamp=None):
    """Record what balance_store just kept: for each scope and local day, the first and the last figure. The
    balance is the whole account's, shared by its keys and projects. Never fails a balance write."""
    t = parse_iso(str(stamp or "")) or now()
    day = day_str(t)
    figures = []
    for scope, pair in (results or {}).items():
        data = pair[0] if isinstance(pair, (tuple, list)) and len(pair) == 2 else None
        known = balance_known(data)
        if known:
            figures.append((str(scope), known[0], known[1]))
    if not figures:
        return False

    def mutate(store):
        balances = store.get("balances") if isinstance(store.get("balances"), dict) else store.setdefault("balances", {})
        changed = False
        for scope, amount, currency in figures:
            entry = balances.setdefault(day, {}).setdefault(scope, {})
            point = {"amount": amount, "currency": currency, "at": iso(t)}
            if not balance_known(entry.get("first")):
                entry["first"] = point
                changed = True
            if entry.get("last") != point:
                entry["last"] = point
                changed = True
        return changed
    return daily_update(mutate)[1]


