# ───────────────────────── monthly spend limits (API-billed executors) ─────────────────────────
#
# DeepSeek bills per token always; Codex and Claude bill per token only when their active profile has a `key`.
# `orch spend` sets a USD limit per scope (a profile label: deepseek, deepseek@work, codex@work, claude@work, …)
# for all projects or one project. Spend is counted from the usage ledger: executor `run` records whose
# `billing` is api, and `session` records with a `lead` (the orchestrator itself on a key). The counters are
# cached incrementally in ~/.orchestra/spend_cache.json (like session_tokens): byte offset + running totals,
# restarted on a new calendar month or a shrunken ledger. --force does NOT bypass a limit, like profile max_open.

def _read_prices(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _price_layers():
    """(built-in, personal, personal model rates in effect, personal sources in effect, superseded) of the two price
    files. A personal source written by `orch prices apply` (it has a `models` list) that is older than the built-in
    source of the same provider is superseded: its model entries and the source are left out, so a newer plugin's
    prices replace an old check. Personal entries written by hand (no `models` list) always override.
    `superseded` maps a provider to (personal as_of, built-in as_of)."""
    base = _read_prices(PRICES_FILE)
    personal = _read_prices(PERSONAL_PRICES_FILE)
    rates = personal.get("usd_per_1m_tokens")
    rates = dict(rates) if isinstance(rates, dict) else {}
    sources = personal.get("sources")
    sources = dict(sources) if isinstance(sources, dict) else {}
    base_sources = base.get("sources") if isinstance(base.get("sources"), dict) else {}
    superseded = {}
    for prov, s in list(sources.items()):
        built_in = base_sources.get(prov)
        if not (isinstance(s, dict) and isinstance(s.get("models"), list) and isinstance(built_in, dict)):
            continue
        mine, theirs = _parse_date(s.get("as_of")), _parse_date(built_in.get("as_of"))
        if mine is None or theirs is None or mine >= theirs:
            continue
        for key in s["models"]:
            if isinstance(key, str):
                rates.pop(key, None)
        del sources[prov]
        superseded[prov] = (s.get("as_of"), built_in.get("as_of"))
    return base, personal, rates, sources, superseded


def load_prices():
    """Built-in registry/prices.json, overridden per model (and per source) by a personal ~/.orchestra/prices.json,
    except what a newer built-in source supersedes (see _price_layers)."""
    base, personal, personal_rates, personal_sources, _ = _price_layers()
    if not personal:
        return base
    rates = dict(base.get("usd_per_1m_tokens") or {})
    rates.update(personal_rates)
    sources = dict(base.get("sources") or {})
    sources.update(personal_sources)
    return {"usd_per_1m_tokens": rates,
            "default": personal.get("default") or base.get("default") or {},
            "sources": sources}


def _parse_date(v):
    if not v:
        return None
    if isinstance(v, dt.datetime):
        return v.astimezone().date()
    try:
        return dt.datetime.strptime(str(v), "%Y-%m-%d").date()
    except ValueError:
        t = parse_iso(str(v))
        return t.astimezone().date() if t else None


def _active_rate(entry, when):
    """Resolve a price entry that is a constant dict or a list of dated dicts (`from`/`to`, for promotions that end)."""
    when = (when or now()).astimezone()
    if isinstance(entry, dict):
        return entry
    if isinstance(entry, list):
        best = None
        for e in entry:
            if not isinstance(e, dict):
                continue
            frm, to = _parse_date(e.get("from")), _parse_date(e.get("to"))
            today = when.date()
            if frm and today < frm:
                continue
            if to and today >= to:
                continue
            key = frm or dt.date.min
            if best is None or key >= best[0]:
                best = (key, e)
        return best[1] if best else None
    return None


def price_multiplier(rates, when):
    """1.0 inside a provider's peak windows, else its off-peak multiplier (DeepSeek peaks Mon–Fri 01–04 & 06–10 UTC)."""
    if not isinstance(rates, dict):
        return 1.0
    off = rates.get("off_peak_multiplier")
    windows = rates.get("peak_windows_utc")
    if not off or not isinstance(windows, list) or not windows:
        return 1.0
    when = (when or now()).astimezone(dt.timezone.utc)
    days = [str(d).lower() for d in rates.get("peak_days") or []]
    if days and ["mon", "tue", "wed", "thu", "fri", "sat", "sun"][when.weekday()] not in days:
        return float(off)
    t = when.strftime("%H:%M")
    for w in windows:
        if isinstance(w, list) and len(w) == 2 and w[0] <= t < w[1]:
            return 1.0
    return float(off)


def price_entry(model, provider):
    """The raw rates entry (dict or dated list) for a model, else the default; None when nothing is priced."""
    prices = load_prices()
    rates = prices.get("usd_per_1m_tokens") or {}
    default = prices.get("default")
    m = str(model or "").lower().split("[")[0].strip()
    provider = (provider or "").lower()
    entry = None
    if provider == "claude":                      # the adapter reports aliases or ids like claude-sonnet-5-5-…
        for fam in ("fable", "opus", "sonnet", "haiku"):
            if fam in m:
                entry = rates.get(fam)
                break
    if entry is None and m in rates:
        entry = rates[m]
    if entry is None:
        for key in sorted(rates, key=len, reverse=True):   # gpt-6.1-sol-… → gpt-6.1-sol; gpt-5.6-terra → gpt-5.6
            if m.startswith(key):
                entry = rates[key]
                break
    if entry is None:
        entry = default if default else None
    return entry


def price_for(model, provider, when=None):
    """{input, cache_read, cache_write?, output} rates (USD per 1M tokens) for a model at `when`, else None when
    unpriced. Dated entries and peak windows are resolved here, so the returned numbers are already scaled."""
    entry = price_entry(model, provider)
    if entry is None:
        return None
    rates = _active_rate(entry, when)
    if not isinstance(rates, dict):
        rates = {}
    mult = price_multiplier(rates, when)
    return {"input": float(rates.get("input") or 0) * mult,
            "cache_read": float(rates.get("cache_read") or 0) * mult,
            "cache_write": float(rates.get("cache_write") or 0) * mult,
            "output": float(rates.get("output") or 0) * mult}


def price_as_of(provider):
    """The `as_of` date of the effective price list for a provider, or None."""
    prices = load_prices()
    s = (prices.get("sources") or {}).get((provider or "").lower())
    return s.get("as_of") if isinstance(s, dict) else None


def price_staleness(provider):
    """A warning when a provider's prices are older than 30 days; None otherwise. Kept out of `orch status`."""
    prices = load_prices()
    s = (prices.get("sources") or {}).get((provider or "").lower())
    if not isinstance(s, dict) or not s.get("as_of"):
        return None
    d = _parse_date(s["as_of"])
    if d is None:
        return None
    age = (now().astimezone().date() - d).days
    if age > 30:
        return "prices for %s are from %s (%d days old): run `orch prices check` (source: %s)" % (
            provider, s["as_of"], age, s.get("source") or "the provider's price list")
    return None


