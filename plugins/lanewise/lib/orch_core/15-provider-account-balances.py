# ───────────────────────── provider account balances ─────────────────────────
#
# What the account behind an API key really has left, read from the provider with that key. All keys of one account share
# the figure, and the account can be spent from outside orch, so it never stands for one key's spend. `orch spend` only
# estimates orch's own runs (tokens × prices); this is the provider's own figure. A provider is one fetch function and one BALANCE_PROVIDERS entry. Only what
# an ordinary key can read counts, and only DeepSeek offers it (GET /user/balance). OpenAI and Anthropic keep their
# billing and cost reports behind admin keys, and Google offers no balance API for the Gemini API or Vertex AI, so
# those scopes keep the estimate (`orch balance` says so). ~/.lanewise/balances.json keeps, per scope label,
# {amount, currency, at} and the last failure {error: {message, at}}; a failed fetch keeps the last amount. The key is
# never written anywhere, never printed, and no message contains it. The status line only reads that file.

class BalanceError(Exception):
    """A balance could not be read. The text is safe to show and to store: it never contains the key."""
    def __init__(self, message, rejected=False):
        Exception.__init__(self, message)
        self.rejected = rejected        # the provider refused the key (401/403): the caller names the variable


def balance_get(url, key, label):
    """GET `url` with the key as a bearer token → the parsed JSON object. Every failure is a BalanceError that says
    what went wrong without the key or the request headers; a redirect is never followed (it would carry the key on)."""
    import socket
    import urllib.error
    import urllib.request

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + key, "Accept": "application/json",
                                               "User-Agent": "orch"})
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=BALANCE_TIMEOUT) as r:
            raw = r.read(65536)
    except urllib.error.HTTPError as ex:
        if ex.code in (401, 403):
            raise BalanceError("%s rejected the key (HTTP %d)" % (label, ex.code), rejected=True)
        raise BalanceError("%s answered HTTP %d" % (label, ex.code))
    except urllib.error.URLError as ex:
        if isinstance(ex.reason, (socket.timeout, TimeoutError)):
            raise BalanceError("%s did not answer within %d s" % (label, BALANCE_TIMEOUT))
        raise BalanceError("cannot reach %s (%s)" % (label, type(ex.reason).__name__))
    except (socket.timeout, TimeoutError):
        raise BalanceError("%s did not answer within %d s" % (label, BALANCE_TIMEOUT))
    except Exception as ex:
        raise BalanceError("no usable answer from %s (%s)" % (label, type(ex).__name__))
    try:
        data = json.loads(raw.decode("utf-8"))
    except ValueError:
        raise BalanceError("%s sent an answer that is not JSON" % label)
    if not isinstance(data, dict):
        raise BalanceError("%s sent an unexpected answer" % label)
    return data


def deepseek_balance(key):
    """DeepSeek: GET /user/balance → {balance_infos: [{currency: CNY|USD, total_balance: "110.00", …}]}. The currency is
    the one DeepSeek reports (no conversion); with several, the first. ORCH_DEEPSEEK_BALANCE_URL replaces the URL."""
    url = os.environ.get("ORCH_DEEPSEEK_BALANCE_URL") or "https://api.deepseek.com/user/balance"
    data = balance_get(url, key, "DeepSeek")
    infos = data.get("balance_infos")
    for info in infos if isinstance(infos, list) else []:
        try:
            amount = float(info.get("total_balance"))
        except (AttributeError, TypeError, ValueError):
            continue
        currency = str(info.get("currency") or "").strip().upper()
        if currency and amount == amount and abs(amount) != float("inf"):
            return {"amount": amount, "currency": currency}
    raise BalanceError("DeepSeek sent a balance this version cannot read")


# provider → {fetch: key → {amount, currency}, key: the variable of the built-in profile, when that profile bills a key}
BALANCE_PROVIDERS = {
    "deepseek": {"fetch": deepseek_balance, "key": "DEEPSEEK_API_KEY"},
}
NO_BALANCE_API = "no balance API: see `orch spend`"


def balance_off():
    """ORCH_BALANCE=off: no balance request is ever made (orch balance included); the cache is still shown."""
    return os.environ.get("ORCH_BALANCE", "").strip().lower() in ("off", "0", "no", "false")


def money(amount, currency):
    """'$8.42', '¥110.00', '3.50 EUR': the currency the provider reported."""
    symbol = {"USD": "$", "CNY": "¥"}.get(str(currency).upper())
    text = "%.2f" % abs(amount)
    return ("-" if amount < 0 else "") + (symbol + text if symbol else "%s %s" % (text, currency))


def balance_cache():
    """{scope: entry} from balances.json; an unreadable file or an odd entry is no data (never an error)."""
    try:
        data = read_json(BALANCE_FILE, {})
    except StateError:
        return {}
    return {k: v for k, v in data.items() if isinstance(v, dict)}


def balance_known(entry):
    """(amount, currency) of a cache entry, or None when it holds no figure."""
    if not isinstance(entry, dict):
        return None
    amount, currency = entry.get("amount"), entry.get("currency")
    if isinstance(amount, (int, float)) and not isinstance(amount, bool) and isinstance(currency, str) and currency:
        return float(amount), currency
    return None


def balance_checked(entry):
    """When the provider was last asked about this scope, success or not (the later of `at` and the error's time)."""
    if not isinstance(entry, dict):
        return None
    times = [parse_iso(str(entry.get("at") or ""))]
    if isinstance(entry.get("error"), dict):
        times.append(parse_iso(str(entry["error"].get("at") or "")))
    times = [t for t in times if t is not None]
    return max(times) if times else None


def has_session_budget(prof):
    return prof.provider in BALANCE_PROVIDERS and any(prof.data.get(f) is not None for f in SESSION_BUDGET_FIELDS)


def session_budget_store():
    """Read and validate without repairing: a broken baseline must never silently reset a budget."""
    try:
        import math
        data = read_json(SESSION_BUDGET_FILE, {}, object_required=True)
        for sessions in data.values():
            if not isinstance(sessions, dict):
                raise ValueError("expected sessions by scope")
            for entry in sessions.values():
                if not isinstance(entry, dict) or not balance_known({"amount": entry.get("baseline"),
                        "currency": entry.get("currency")}) or not balance_known({"amount": entry.get("last"),
                        "currency": entry.get("currency")}) or not parse_iso(str(entry.get("at") or "")):
                    raise ValueError("invalid session baseline")
                if not all(math.isfinite(entry[f]) for f in ("baseline", "last")):
                    raise ValueError("invalid session baseline")
        return data
    except (StateError, ValueError, TypeError) as ex:
        warn_state(SESSION_BUDGET_FILE, str(ex))
        return None


def session_budget_record(prof):
    """Only hooks and run preflight write baselines. Lock, re-read, prune, then update this session."""
    sid = session_id()
    if not sid or not has_session_budget(prof) or balance_off():
        return True
    entry = balance_cache().get(prof.label)
    known = balance_known(entry)
    if not known or not parse_iso(str(entry.get("at") or "")) or balance_age(entry) or entry.get("error"):
        return False
    amount, currency = known
    try:
        with state_lock(ORCH_HOME / ".session_budget.lock"):
            data = session_budget_store()
            if data is None:
                return False
            cutoff = now() - dt.timedelta(days=SESSION_STATE_DAYS)
            data = {scope: {s: e for s, e in sessions.items() if parse_iso(e["at"]) >= cutoff}
                    for scope, sessions in data.items()}
            data = {scope: sessions for scope, sessions in data.items() if sessions}
            sessions = data.setdefault(prof.label, {})
            old = sessions.get(sid)
            if not old or old["currency"] != currency or round(amount - old["last"], 8) >= 0.01:
                new = {"baseline": amount, "currency": currency, "at": iso_precise(now()), "last": amount}
            else:
                new = dict(old, last=amount)
            if new == old:                # hooks run after every tool call: no change, no write
                return True
            sessions[sid] = new
            write_json(SESSION_BUDGET_FILE, data)
        _exhaustion_memo.clear()
        return True
    except (StateError, OSError) as ex:
        warn_state(SESSION_BUDGET_FILE, str(ex))
        return False


def session_budget_figure(prof):
    """The last known figure, however old: a balance only rises with a top-up, so age can't clear a budget and a failed
    read can't make a session flap. A run fetches a fresh one first; only a baseline insists on a recent figure."""
    if not has_session_budget(prof) or balance_off():
        return None
    entry = balance_cache().get(prof.label)
    known = balance_known(entry)
    if not known or not parse_iso(str(entry.get("at") or "")):
        return None
    amount, currency = known
    figure = {"amount": amount, "currency": currency}
    if session_id():
        data = session_budget_store()
        baseline = (data or {}).get(prof.label, {}).get(session_id())
        if data is None:
            return None
        if baseline and baseline["currency"] == currency and \
                parse_iso(baseline["at"]) >= now() - dt.timedelta(days=SESSION_STATE_DAYS):
            base = baseline["baseline"]
            down = max(base - amount, 0)
            figure.update(baseline=base, baseline_at=baseline["at"], down=down,
                          percent=round(100 * down / base, 10) if base > 0 else 0)
    return figure


def session_budget_settings(prof, currency="USD"):
    parts = []
    for field, name in (("session_soft", "soft"), ("session_hard", "hard")):
        if prof.data.get(field) is not None:
            parts.append("%s %g%%" % (name, prof.data[field]))
    if prof.data.get("balance_floor") is not None:
        parts.append("floor " + money(prof.data["balance_floor"], currency).replace(".00", ""))
    return ", ".join(parts)


def session_budget_text(prof, settings=True):
    fig = session_budget_figure(prof)
    if not fig:
        text = "no budget figure available"
    elif "baseline" in fig:
        text = "account down %s of %s (%.1f%%" % (money(fig["down"], fig["currency"]),
                money(fig["baseline"], fig["currency"]), fig["percent"])
        return text + ("; " + session_budget_settings(prof, fig["currency"]) if settings else "") + ")"
    else:
        text = "account " + money(fig["amount"], fig["currency"]) + "; no session baseline"
    return text + (" (" + session_budget_settings(prof, fig["currency"] if fig else "USD") + ")" if settings else "")


def session_budget_cause(prof, where):
    fig = session_budget_figure(prof)
    if not fig:
        return None
    floor = prof.data.get("balance_floor")
    if floor is not None and fig["amount"] <= floor:
        return "floor"
    if "percent" not in fig:
        return None
    hard, soft = prof.data.get("session_hard"), prof.data.get("session_soft")
    if hard is not None and fig["percent"] >= hard:
        return "session-hard"
    if soft is not None and fig["percent"] > soft and claude_budget(where)[0] != "tight":
        return "session-soft"
    return None


def session_budget_hooks(where):
    data, err = load_profiles()
    if err or balance_off():
        return
    for provider in managed_providers(data):
        try:
            prof = resolve_profile(provider, where, data=data, follow=False)
            if not has_session_budget(prof):
                continue
            session_budget_record(prof)
            active = resolve_profile(provider, where, data=data)
            if active.name != prof.name:
                session_budget_record(active)
        except ProfileError:
            continue


def session_budget_preflight(provider, where, override):
    """Fresh figures before a run. The configured key comes first even while the project is on its fallback, or a top-up
    would never bring it back; its failed read refuses only a run that would use it. Then a fallback's own budget."""
    configured = resolve_profile(provider, where, override, follow=False)
    prof = resolve_profile(provider, where, override)
    if balance_off():
        if has_session_budget(configured) or has_session_budget(prof):
            print("warning: ORCH_BALANCE=off — running with no session budget")
        return prof, None

    def refresh(target):
        var = target.data.get("key") or BALANCE_PROVIDERS[provider].get("key")
        results = balance_refresh([{"scope": target.label, "provider": provider, "var": str(var or "")}])
        data, error = results.get(target.label, (None, "no fresh balance"))
        fresh = not error and balance_known(data) and session_budget_record(target)
        _exhaustion_memo.clear()
        return fresh

    no_figure = "no fresh balance was available (or the session baseline is unreadable)"
    fresh = refresh(configured) if has_session_budget(configured) else True
    prof = resolve_profile(provider, where, override)
    if prof.label == configured.label:
        if not fresh:
            return prof, no_figure
    elif has_session_budget(prof) and not refresh(prof):
        return prof, no_figure
    cause = session_budget_cause(prof, where)
    if cause in ("floor", "session-hard"):
        return prof, "%s: %s" % (fallback_cause_words(cause), session_budget_text(prof))
    if cause == "session-soft":
        print("warning: %s is over its session budget; %s; no fallback move available" % (
              prof.label, session_budget_text(prof)))
    return prof, None


def balance_age(entry):
    """'3h ago' once a figure is older than BALANCE_FRESH_SECONDS, else ''."""
    at = parse_iso(str(entry.get("at") or "")) if isinstance(entry, dict) else None
    if at is not None and (now() - at).total_seconds() > BALANCE_FRESH_SECONDS:
        return human_delta(at)
    return ""


def balance_age_note(entry):
    """' (3h ago)' once a figure is older than BALANCE_FRESH_SECONDS, else ''."""
    age = balance_age(entry)
    return " (%s)" % age if age else ""


def balance_cell(entry):
    """The balance column of `orch spend`: '$8.42', '$8.42 (3h ago)', or '' where unknown."""
    known = balance_known(entry)
    return (money(*known) + balance_age_note(entry)) if known else ""


def balance_fragments(scopes, cache=None):
    """{scope: 'account $8.42, 3h ago'} for the scopes with a cached figure: the status line's read of the cache. The
    figure is the provider's balance of the whole account the key belongs to, not of the key."""
    scopes = [s for s in scopes if s.partition("@")[0] in BALANCE_PROVIDERS]
    if not scopes:
        return {}
    cache = balance_cache() if cache is None else cache
    out = {}
    for scope in scopes:
        known = balance_known(cache.get(scope))
        if known:
            age = balance_age(cache[scope])
            out[scope] = "account " + money(*known) + (", " + age if age else "")
    return out


API_KEYS_HEADING = ("API keys (spend and limit: our estimate of orch's own runs; account: the provider's figure, "
                    "for all keys of that account):")


def balance_status_lines(where):
    """`orch status`: a line per API-billed scope active in the directory, whether or not the provider has been asked —
    our estimate and limit (orch's own runs), and the provider's figure for the account with its age, the last failed
    fetch, or that the provider has no balance API. Never fails."""
    try:
        rows, cache = shown_api_scopes(where)
        if not rows:
            return []
        config = load_spend_limits()[0]
        lines = [API_KEYS_HEADING]
        for prof, scope, spent, limit, _ in rows:
            ours = "est. $%.2f" % spent
            ours += (" of " + limit_text(limit)) if limit is not None else ", limit off"
            ours += " (%s)" % counter_cover(config, scope, where)
            parts = [ours]
            entry = cache.get(scope)
            if scope.partition("@")[0] not in BALANCE_PROVIDERS:
                parts.append("no balance API")
            else:
                known = balance_known(entry)
                if known:
                    at = parse_iso(str(entry.get("at") or ""))
                    parts.append("account " + money(*known) + (" (checked %s)" % human_delta(at) if at else ""))
                elif not isinstance(entry, dict):
                    parts.append("account balance not fetched yet")
                else:
                    parts.append("account balance unknown")
                err = entry.get("error") if isinstance(entry, dict) else None
                if isinstance(err, dict) and err.get("message"):
                    parts.append("last fetch failed: %s" % err["message"])
            if has_session_budget(prof):
                parts.append("session: " + session_budget_text(prof))
            lines.append("  %-18s %s" % (scope_name(scope), " · ".join(parts)))
            if prof.fallback_from:
                configured = resolve_profile(prof.provider, where, follow=False)
                if has_session_budget(configured):
                    lines.append("  %-18s session: %s" % (scope_name(configured.label), session_budget_text(configured)))
        return lines
    except Exception:
        return []


def balance_secret(var, secrets):
    """The key's value the way a run resolves it: the environment first, then secrets.env."""
    return os.environ.get(var) or secrets.get(var)


def balance_targets(data=None):
    """[{scope, provider, var}]: a profile with a `key` (any provider: an unsupported one is reported as such), and the
    built-in profile of a supported provider that bills a key, when its variable is set."""
    if data is None:
        data = load_profiles()[0]
    out, secrets = [], None
    for provider in data["providers"]:
        for name, d in provider_section(data, provider)[1].items():
            if isinstance(d, dict) and d.get("key"):
                out.append({"scope": "%s@%s" % (provider.lower(), name), "provider": provider.lower(),
                            "var": str(d["key"])})
    for provider, spec in BALANCE_PROVIDERS.items():
        # a profile already holding the variable is the same account: one row and one request, not two
        if spec.get("key") and not any(t["provider"] == provider and t["var"] == spec["key"] for t in out):
            secrets = load_secrets() if secrets is None else secrets
            if balance_secret(spec["key"], secrets):
                out.append({"scope": provider, "provider": provider, "var": spec["key"]})
    return out


def balance_active_targets(where):
    """The targets with a balance API among the API-billed scopes active in a directory (a fallback included). The
    built-in profile counts only when its key variable is set, so a provider nobody uses stays silent."""
    out, secrets = [], None
    for prof, scope in active_profiles(where):
        spec = BALANCE_PROVIDERS.get(prof.provider)
        if not scope or spec is None:
            continue
        var = prof.data.get("key") if prof.explicit else spec.get("key")
        if not var:
            continue
        if not prof.explicit:
            secrets = load_secrets() if secrets is None else secrets
            if not balance_secret(var, secrets):
                continue
        out.append({"scope": scope, "provider": prof.provider, "var": str(var)})
    return out


def balance_fetch_all(targets):
    """Ask the providers about these targets at once (a thread each), the whole call bounded by one timeout.
    → {scope: (data, error)}: data {amount, currency} or None, error a text or None. No lock is held and nothing is
    stored here. The key is read, used for the request and dropped; error texts are scrubbed of it."""
    import threading
    secrets = load_secrets()
    results, pending = {}, []
    for t in targets:
        spec = BALANCE_PROVIDERS.get(t["provider"])
        if spec is None:
            continue
        key = balance_secret(t["var"], secrets)
        if not key:
            results[t["scope"]] = (None, "%s is neither in the environment nor in %s" % (t["var"], SECRETS_FILE))
            continue
        box = {}

        def work(fn=spec["fetch"], key=key, box=box):
            try:
                box["data"] = fn(key)
            except BalanceError as ex:
                box["error"], box["rejected"] = str(ex), ex.rejected
            except Exception as ex:
                box["error"] = "unexpected failure (%s)" % type(ex).__name__
        th = threading.Thread(target=work)
        th.daemon = True
        th.start()
        pending.append((t, key, box, th))
    deadline = time.monotonic() + BALANCE_TIMEOUT + 1
    for t, key, box, th in pending:
        th.join(max(0.0, deadline - time.monotonic()))
        data, error = box.get("data"), box.get("error")
        if th.is_alive():
            error = "%s did not answer within %d s" % (display_name(t["provider"]), BALANCE_TIMEOUT)
        elif error is None and not balance_known(data):
            error = "%s sent a balance this version cannot read" % display_name(t["provider"])
        if error is not None:
            data = None
            if box.get("rejected"):
                error += ": check %s" % t["var"]
            error = error.replace(key, "…")
        results[t["scope"]] = (data, error)
    return results


@locked("home")
def balance_store(results):
    """Write fetch results into balances.json, re-reading it under the lock: a figure replaces the entry; a failure
    keeps the last amount and records the error with its time. Held only for the write, never during a request."""
    cache = read_json(BALANCE_FILE, {}, recover_corrupt=True)
    stamp = iso(now())
    for scope, (data, error) in results.items():
        old = cache.get(scope) if isinstance(cache.get(scope), dict) else {}
        if data is not None:
            cache[scope] = {"amount": data["amount"], "currency": data["currency"], "at": stamp}
        else:
            entry = {k: old[k] for k in ("amount", "currency", "at") if k in old}
            entry["error"] = {"message": error, "at": stamp}
            cache[scope] = entry
    write_json(BALANCE_FILE, cache)


def balance_refresh(targets):
    """Fetch and store; a failure of any kind is swallowed (it shows as staleness). → the fetch results."""
    try:
        results = balance_fetch_all(targets)
        if results:
            balance_store(results)
        return results
    except Exception:
        return {}


def balance_stale(targets, cache):
    """True when some target has not been asked about for BALANCE_STALE_SECONDS (a failed ask counts as asked)."""
    for t in targets:
        at = balance_checked(cache.get(t["scope"]))
        if at is None or (now() - at).total_seconds() > BALANCE_STALE_SECONDS:
            return True
    return False


def balance_refresh_stale(where, all_keys=False):
    """`orch status` (the scopes active in `where`) and `orch spend show` (`all_keys`: every key, as its table shows
    them): fetch the scopes whose figure is stale, bounded by the timeout. Never fails, and does nothing in a worker or
    with ORCH_BALANCE=off."""
    if balance_off() or os.environ.get("ORCH_WORKER"):
        return
    try:
        cache = balance_cache()
        targets = balance_targets() if all_keys else balance_active_targets(where)
        stale = [t for t in targets if t["provider"] in BALANCE_PROVIDERS and balance_stale([t], cache)]
    except Exception:
        return
    if stale:
        balance_refresh(stale)


def balance_spawn_recent():
    """True when a hook started a detached fetch within BALANCE_SPAWN_GAP_SECONDS: several sessions and prompts then
    start one fetch, not many. A missing or unreadable marker is no recent spawn."""
    try:
        return time.time() - BALANCE_REFRESH_MARKER.stat().st_mtime < BALANCE_SPAWN_GAP_SECONDS
    except OSError:
        return False


def balance_start_refresh(targets=None):
    """SessionStart / UserPromptSubmit: when a balance is stale, start `orch balance --quiet` detached and go on at
    once. `targets` defaults to every key `orch balance` would fetch (with a balance API), not only the ones the current
    directory uses; the marker keeps prompts and sessions within BALANCE_SPAWN_GAP_SECONDS to one fetch. The child has
    no console window (Windows) or its own session (POSIX), no inherited stdio, and outlives the hook."""
    if balance_off() or os.environ.get("ORCH_WORKER"):
        return
    try:
        if targets is None:
            targets = [t for t in balance_targets() if t["provider"] in BALANCE_PROVIDERS]
        if not balance_stale(targets, balance_cache()) or balance_spawn_recent():
            return
        import subprocess
        kw = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "close_fds": True}
        if IS_WINDOWS:
            kw["creationflags"] = 0x00000008 | 0x00000200 | 0x08000000   # DETACHED_PROCESS | NEW_PROCESS_GROUP | NO_WINDOW
        else:
            kw["start_new_session"] = True
        # claim the gap before spawning, so a hook running at the same moment sees it; give it back if the spawn fails
        try:
            BALANCE_REFRESH_MARKER.touch()
        except OSError:
            pass
        try:
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "balance", "--quiet"], **kw)
        except Exception:
            try:
                BALANCE_REFRESH_MARKER.unlink()
            except OSError:
                pass
            raise
    except Exception:
        pass


def balance_refresh_run(prof):
    """End of `orch run`: read the account balance behind the run's key. Never fails, never delays more than the timeout."""
    if balance_off() or os.environ.get("ORCH_WORKER"):
        return
    try:
        spec = BALANCE_PROVIDERS.get(prof.provider)
        var = (prof.data.get("key") if prof.explicit else spec.get("key")) if spec else None
        if var:
            balance_refresh([{"scope": prof.label, "provider": prof.provider, "var": str(var)}])
    except Exception:
        pass


def balance_row(target, entry):
    """One scope as shown by `orch balance` and as its --json object (variable names only, never a key)."""
    supported = target["provider"] in BALANCE_PROVIDERS
    row = {"scope": target["scope"], "provider": target["provider"], "key_variable": target["var"],
           "supported": supported, "amount": None, "currency": None, "checked_at": None, "error": None,
           "error_at": None, "note": None if supported else NO_BALANCE_API}
    if not supported or not isinstance(entry, dict):
        return row
    known = balance_known(entry)
    if known:
        row["amount"], row["currency"], row["checked_at"] = known[0], known[1], entry.get("at")
    if isinstance(entry.get("error"), dict):
        row["error"], row["error_at"] = entry["error"].get("message"), entry["error"].get("at")
    return row


def cmd_balance(a):
    """orch balance [SCOPE …] [--json] [--quiet]: ask each provider for the balance of the account behind every API
    key (a profile with a `key`, DeepSeek's built-in key) and keep it for status, spend and the status line. Keys of
    one account share the figure. Exit 1 when a fetch
    failed (the last amount is kept); --quiet prints nothing and always exits 0."""
    if os.environ.get("ORCH_WORKER"):
        if a.quiet:
            return 0
        raise SystemExit("orch: you are an executor (ORCH_WORKER) — only the orchestrator reads balances")
    if balance_off():
        if not a.quiet:
            print("[]" if a.json else "Balance checks are off (ORCH_BALANCE=off): nothing was fetched.")
        return 0
    data, err = load_profiles()
    if err and not a.quiet:
        print("orch: warning: %s" % err, file=sys.stderr)
    targets = balance_targets(data)
    if a.scopes:
        want = [s.strip().lower() for s in a.scopes]
        unknown = [s for s in want if s not in {t["scope"] for t in targets}]
        if unknown and not a.quiet:
            raise SystemExit("orch: no API key for %s (orch balance lists the keys it knows)" % ", ".join(unknown))
        targets = [t for t in targets if t["scope"] in want]
    results = {}
    try:
        results = balance_fetch_all([t for t in targets if t["provider"] in BALANCE_PROVIDERS])
        if results:
            balance_store(results)
    except Exception:
        if not a.quiet:
            raise
    if a.quiet:
        return 0
    cache = balance_cache()
    rows = [balance_row(t, cache.get(t["scope"])) for t in targets]
    failed = any(got is None for got, _ in results.values())
    if a.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 1 if failed else 0
    if not rows:
        print("No API keys: DeepSeek (DEEPSEEK_API_KEY in %s or the environment) or a profile with a key "
              "(orch profile set <provider> <name> --key VAR)." % SECRETS_FILE)
        return 0
    print("Account balances: the provider's own figure for the account a key belongs to, shared by all its keys "
          "(`orch spend` shows our estimate of orch's own runs).")
    width = max([len("key variable")] + [len(row["key_variable"] or "") for row in rows])
    print("%-20s %-*s %-16s %-12s %s" % ("scope", width, "key variable", "account balance", "checked", ""))
    for row in rows:
        shown = money(row["amount"], row["currency"]) if row["amount"] is not None else "—"
        at = parse_iso(str(row["checked_at"] or ""))
        note = row["note"] or ("error: %s" % row["error"] if row["error"] else "")
        print("%-20s %-*s %-16s %-12s %s" % (scope_name(row["scope"]), width, row["key_variable"], shown,
                                             human_delta(at) if at else "—", note))
    return 1 if failed else 0


