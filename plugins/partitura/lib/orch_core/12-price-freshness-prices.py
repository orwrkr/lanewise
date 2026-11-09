# ───────────────────────── price freshness: `orch prices` ─────────────────────────
#
# `orch` makes no web request for prices. `orch prices check` writes a self-contained TASK.md for a cheap agent with web
# access; the agent's report holds a proposal (a fenced json block); `diff` shows what it changes and `apply --yes`
# writes it to the personal prices.json as dated entries. Nothing happens by itself.

PRICE_STALE_DAYS = 30
PRICE_RATE_FIELDS = ("input", "cache_read", "cache_write", "output")
PRICE_REQUIRED_FIELDS = ("input", "cache_read", "output")
PRICE_PEAK_FIELDS = ("off_peak_multiplier", "peak_days", "peak_windows_utc")
PRICE_LARGE_CHANGE_PCT = 25
PRICE_DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


class PricesError(Exception):
    """An invalid price proposal (or request): the reasons are the message, one per line."""


def price_provider(model_key):
    """The provider a price-table model key belongs to (`claude`, `codex`, `deepseek`), else None. Anything else is
    never put in a check task and never accepted in a proposal."""
    m = str(model_key or "").lower().split("[")[0].strip()
    if m.startswith("gpt-"):
        return "codex"
    if m.startswith("deepseek-"):
        return "deepseek"
    if any(fam in m for fam in ("fable", "opus", "sonnet", "haiku")):
        return "claude"
    return None


def _price_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) != float("inf")


def _price_fmt(v):
    return "(none)" if v is None else ("%.6g" % v if _price_number(v) else str(v))


def _price_url(source):
    s = str(source or "").strip()
    return s if "://" in s else "https://" + s


def _price_table_current(table, key, when=None):
    """The active element of a model's entry (a dict, or the dated element in force), {} when none applies, None when
    the table has no such key."""
    if key not in table:
        return None
    rates = _active_rate(table[key], when)
    return rates if isinstance(rates, dict) else {}


def _price_peak_text(rates):
    if not isinstance(rates, dict) or not rates.get("off_peak_multiplier"):
        return None
    days = rates.get("peak_days") or []
    wins = ", ".join("-".join(w) for w in rates.get("peak_windows_utc") or [] if isinstance(w, list))
    return "the rates are peak rates; off-peak x%s%s%s" % (
        _price_fmt(rates["off_peak_multiplier"]),
        ("; peak " + "/".join(str(d).capitalize() for d in days)) if days else "",
        (" " + wins + " UTC") if wins else "")


def _price_model_view(raw, personal):
    active = _active_rate(raw, None)
    view = {"origin": "personal" if personal else "built-in",
            "rates": {k: v for k, v in (active or {}).items() if k in PRICE_RATE_FIELDS + PRICE_PEAK_FIELDS}}
    if isinstance(raw, list):
        view["dated_entries"] = len([e for e in raw if isinstance(e, dict)])
        view["active"] = active is not None
        if isinstance(active, dict) and active.get("from"):
            view["active_from"] = active["from"]
    return view


def prices_overview():
    """The effective price table per provider, as data (the text and `--json` output both print this)."""
    base, _, personal_rates, personal_sources, superseded = _price_layers()
    eff = load_prices()
    table = eff.get("usd_per_1m_tokens") or {}
    base_sources = base.get("sources") if isinstance(base.get("sources"), dict) else {}
    today = now().astimezone().date()
    providers, seen = {}, set()
    for prov, s in (eff.get("sources") or {}).items():
        if not isinstance(s, dict):
            continue
        origin = "personal" if prov in personal_sources else "built-in"
        d = _parse_date(s.get("as_of"))
        age = (today - d).days if d else None
        built_in = base_sources.get(prov) if isinstance(base_sources.get(prov), dict) else {}
        bd = _parse_date(built_in.get("as_of"))
        entry = {"source": s.get("source"), "as_of": s.get("as_of"), "age_days": age, "origin": origin,
                 "stale": age is not None and age > PRICE_STALE_DAYS,
                 "older_than_built_in": bool(origin == "personal" and d and bd and d < bd),
                 "built_in_as_of": built_in.get("as_of"), "models": {}}
        if prov in superseded:
            entry["superseded_personal_as_of"] = superseded[prov][0]
        for key, raw in table.items():
            if price_provider(key) != prov:
                continue
            seen.add(key)
            entry["models"][key] = _price_model_view(raw, key in personal_rates)
        providers[prov] = entry
    other = {k: _price_model_view(v, k in personal_rates) for k, v in table.items() if k not in seen}
    return {"today": today.isoformat(), "stale_days": PRICE_STALE_DAYS, "providers": providers, "other": other,
            "default": eff.get("default") or {}}


def _price_model_line(key, v):
    r = v["rates"]
    parts = ["%s %s" % (f, _price_fmt(r[f])) for f in PRICE_RATE_FIELDS if f in r]
    note = ""
    n = v.get("dated_entries", 0)
    if n and not v["active"]:
        note = "  (no entry in force today; %d dated)" % n
    elif n > 1:
        note = "  (+%d other dated entr%s)" % (n - 1, "y" if n == 2 else "ies")
    return "  %-18s %s%s%s" % (key, "  ".join(parts) or "(no rates)", note,
                               "   [personal]" if v["origin"] == "personal" else "")


def _cmd_prices_show(a):
    data = prices_overview()
    if getattr(a, "json", False):
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    print("Prices in effect, USD per 1,000,000 tokens (today %s). `orch prices check` makes a task to refresh them." %
          data["today"])
    for prov, p in data["providers"].items():
        age = "%d days old" % p["age_days"] if p["age_days"] is not None else "no date"
        print("\n%s: %s, as of %s (%s), %s" % (prov, p["source"] or "no source", p["as_of"] or "?", age,
                                              "from your personal prices.json" if p["origin"] == "personal"
                                              else "built in"))
        if p["stale"]:
            print("  ⚠ older than %d days: run `orch prices check`" % data["stale_days"])
        if "superseded_personal_as_of" in p:
            print("  ⚠ your personal check of %s is older than the built-in prices (%s): the built-in figures are used"
                  % (p["superseded_personal_as_of"], p["built_in_as_of"]))
        elif p["older_than_built_in"]:
            print("  ⚠ your personal entries (as of %s) are older than the built-in prices (%s) and still override them"
                  % (p["as_of"], p["built_in_as_of"]))
        for key, v in p["models"].items():
            print(_price_model_line(key, v))
        peaks = {k: _price_peak_text(v["rates"]) for k, v in p["models"].items()}
        texts = set(t for t in peaks.values() if t)
        if len(texts) == 1 and all(peaks.values()):
            print("  peak: " + texts.pop())
        else:
            for k, t in peaks.items():
                if t:
                    print("  peak (%s): %s" % (k, t))
    if data["other"]:
        print("\nnot assigned to a provider (never part of a check):")
        for key, v in data["other"].items():
            print(_price_model_line(key, v))
    return 0


def _price_check_task(providers, table, sources, today):
    lines = ["# Check the API prices of %s" % ", ".join(providers), "",
             "Today is %s. Read the official price pages below and report the rates you find, as the JSON in the "
             "schema at the end. You change nothing: no code, no other files." % today, "", "## What to check", ""]
    keys = {}
    for prov in providers:
        keys[prov] = [k for k in table if price_provider(k) == prov]
        lines.append("### %s: %s" % (prov, _price_url(sources[prov].get("source"))))
        lines.append("")
        lines.append("Model keys of our table that belong to it, with the rates we hold now (for orientation only, "
                     "not as truth). Report each under this key, whatever name the page uses for the model:")
        lines.append("")
        for key in keys[prov]:
            cur = _price_table_current(table, key) or {}
            rates = ", ".join("%s %s" % (f, _price_fmt(cur[f])) for f in PRICE_RATE_FIELDS if f in cur)
            lines.append("- `%s`: %s" % (key, rates or "no rates"))
        if prov == "claude":
            lines += ["", "The Claude keys are model families: report the rates of the newest model of that family "
                      "that the page lists."]
        lines.append("")
    lines += ["## Rules", "",
              "- Use only the official page named above and links within the same site.",
              "- Rates are USD per 1,000,000 tokens: `input` is the base input, `cache_read` the cache hit, "
              "`cache_write` the 5-minute cache write where the page lists one, `output` the output.",
              "- A promotion goes in `notes` with its end date, not in the rates.",
              "- Never guess. Leave out a model or a field you cannot find, and say why in `notes`."]
    if "deepseek" in providers:
        lines.append("- For DeepSeek give the peak rates, plus `off_peak_multiplier`, `peak_days` (`mon`..`sun`) and "
                     "`peak_windows_utc` (pairs of `HH:MM`) if the page states them.")
    first = providers[0]
    pad = " " * (len(first) + 20)
    lines += ["- Report exactly one fenced ```json block in the schema below, then a last line "
              "`STATUS: DONE | PARTIAL | BLOCKED`.", "", "## Schema", "", "```json",
              '{"checked_on": "YYYY-MM-DD",',
              ' "providers": {"%s": {"source": "https://...",' % first,
              '%s"models": {"%s": {"input": <number>, "cache_read": <number>, "output": <number>}},' % (pad, keys[first][0]),
              '%s"notes": "..."}}}' % pad,
              "```", ""]
    return "\n".join(lines)


def _cmd_prices_check(a):
    eff = load_prices()
    table = eff.get("usd_per_1m_tokens") or {}
    sources = {p: s for p, s in (eff.get("sources") or {}).items() if isinstance(s, dict)}
    wanted = [str(p).strip().lower() for p in (getattr(a, "provider", None) or [])]
    for p in wanted:
        if p not in sources:
            print("orch: unknown provider %r (known: %s)" % (p, ", ".join(sources) or "none"), file=sys.stderr)
            return 2
    chosen = list(dict.fromkeys(wanted or sources))
    chosen = [p for p in chosen if any(price_provider(k) == p for k in table)]
    if not chosen:
        print("orch: no provider with priced models to check", file=sys.stderr)
        return 2
    stamp = now().strftime("%Y%m%d-%H%M")
    base = ORCH_HOME / "prices"
    folder, n = base / ("check-" + stamp), 1
    while folder.exists():
        n += 1
        folder = base / ("check-%s-%d" % (stamp, n))
    folder.mkdir(parents=True, exist_ok=True)
    task = folder / "TASK.md"
    with open(str(task), "w", encoding="utf-8", newline="\n") as f:
        f.write(_price_check_task(chosen, table, sources, now().astimezone().date().isoformat()))
    print(task)
    print("Give it to a cheap executor with web access (see `orch guide spend`, section Prices), then run "
          "`orch prices diff <its report>`.")
    return 0


def prices_read_proposal(path):
    """A proposal object from a JSON file, or from the first fenced json block of a text file that parses into an
    object with `providers`. Raises PricesError."""
    try:
        text = Path(path).read_text(encoding="utf-8-sig")
    except (OSError, ValueError) as ex:
        raise PricesError("  - cannot read %s: %s" % (path, ex))
    candidates = [text] + [m.group(1) for m in re.finditer(r"```json[ \t]*\r?\n(.*?)```", text, re.S | re.I)]
    for chunk in candidates:
        try:
            obj = json.loads(chunk)
        except ValueError:
            continue
        if isinstance(obj, dict) and "providers" in obj:
            return obj
    raise PricesError("  - no JSON object with `providers` (a proposal file, or a fenced ```json block in a report)")


def prices_validate(obj, sources, today):
    """(proposal, errors): the proposal normalised (dates parsed, provider names lowercased), every problem listed."""
    errors = []
    checked = obj.get("checked_on")
    checked_on = today
    if checked is not None:
        try:
            checked_on = dt.datetime.strptime(checked, "%Y-%m-%d").date() if isinstance(checked, str) else None
        except ValueError:
            checked_on = None
        if checked_on is None:
            errors.append("checked_on %r is not a date (YYYY-MM-DD)" % (checked,))
            checked_on = today
        elif checked_on > today:
            errors.append("checked_on %s is in the future (today is %s)" % (checked_on, today))
    out = {"checked_on": checked_on, "providers": {},
           "notes": obj.get("notes") if isinstance(obj.get("notes"), str) else None}
    provs = obj.get("providers")
    if not isinstance(provs, dict) or not provs:
        errors.append("`providers` must be an object with at least one provider")
        return out, errors
    for raw_name, p in provs.items():
        name = str(raw_name).strip().lower()
        if name not in sources:
            errors.append("unknown provider %r (known: %s)" % (raw_name, ", ".join(sources)))
            continue
        if not isinstance(p, dict):
            errors.append("%s: expected an object" % name)
            continue
        source = p.get("source")
        if source is not None and not (isinstance(source, str) and source.strip() and len(source) <= 300
                                       and not re.search(r"\s", source.strip())):
            errors.append("%s: `source` must be a URL without spaces" % name)
            source = None
        models = p.get("models")
        if not isinstance(models, dict) or not models:
            errors.append("%s: `models` must be an object with at least one model (leave a provider out when "
                          "nothing was found)" % name)
            continue
        clean = {}
        for key, rates in models.items():
            who = "%s/%s" % (name, key)
            owner = price_provider(key)
            if owner != name:
                errors.append("%s: the model key belongs to %s" % (who, owner or "no known provider"))
                continue
            if not isinstance(rates, dict):
                errors.append("%s: expected an object of rates" % who)
                continue
            r, bad = {}, False
            for f in PRICE_RATE_FIELDS:
                if f not in rates:
                    if f in PRICE_REQUIRED_FIELDS:
                        errors.append("%s: `%s` is required" % (who, f))
                        bad = True
                elif not _price_number(rates[f]) or rates[f] < 0:
                    errors.append("%s: `%s` must be a number >= 0, got %r" % (who, f, rates[f]))
                    bad = True
                else:
                    r[f] = rates[f]
            if "off_peak_multiplier" in rates:
                v = rates["off_peak_multiplier"]
                if _price_number(v) and v > 0:
                    r["off_peak_multiplier"] = v
                else:
                    errors.append("%s: `off_peak_multiplier` must be a number > 0" % who)
                    bad = True
            if "peak_days" in rates:
                v = rates["peak_days"]
                if isinstance(v, list) and all(isinstance(d, str) and d.lower() in PRICE_DAYS for d in v):
                    r["peak_days"] = [d.lower() for d in v]
                else:
                    errors.append("%s: `peak_days` must be a list of %s" % (who, "/".join(PRICE_DAYS)))
                    bad = True
            if "peak_windows_utc" in rates:
                v = rates["peak_windows_utc"]
                if isinstance(v, list) and all(
                        isinstance(w, list) and len(w) == 2
                        and all(isinstance(t, str) and re.match(r"^\d\d:\d\d$", t) for t in w) for w in v):
                    r["peak_windows_utc"] = v
                else:
                    errors.append("%s: `peak_windows_utc` must be a list of [\"HH:MM\", \"HH:MM\"] pairs" % who)
                    bad = True
            if not bad:
                clean[key] = r
        out["providers"][name] = {"source": source.strip() if isinstance(source, str) else None, "models": clean,
                                  "notes": p.get("notes") if isinstance(p.get("notes"), str) else None}
    return out, errors


def prices_compare(proposal, table, only_providers=None):
    """Per provider: changed [(key, [(field, current, proposed)])], unchanged [key], new [key] (not in the table: never
    applied) and missing [key] (in the table, not in the proposal)."""
    result = {}
    for prov, p in proposal["providers"].items():
        if only_providers and prov not in only_providers:
            continue
        changed, unchanged, new = [], [], []
        for key, prop in p["models"].items():
            cur = _price_table_current(table, key)
            if cur is None:
                new.append(key)
                continue
            changes = []
            for f in PRICE_RATE_FIELDS + PRICE_PEAK_FIELDS:
                if f not in prop:
                    continue
                c, v = cur.get(f), prop[f]
                if _price_number(v) and _price_number(c):
                    differs = abs(c - v) > 1e-12
                else:
                    differs = c != v
                if differs:
                    changes.append((f, c, v))
            if changes:
                changed.append((key, changes))
            else:
                unchanged.append(key)
        missing = [k for k in table if price_provider(k) == prov and k not in p["models"]]
        result[prov] = {"changed": changed, "unchanged": unchanged, "new": new, "missing": missing}
    return result


def _price_change_text(field, cur, new):
    if _price_number(cur) and _price_number(new):
        if cur:
            pct = (new - cur) / cur * 100.0
            text = "%s: %s → %s (%+.1f%%)" % (field, _price_fmt(cur), _price_fmt(new), pct)
            return text + ("  ⚠ large change" if abs(pct) >= PRICE_LARGE_CHANGE_PCT else "")
        return "%s: %s → %s (from zero)  ⚠ large change" % (field, _price_fmt(cur), _price_fmt(new))
    return "%s: %s → %s" % (field, json.dumps(cur) if cur is not None else "(none)", json.dumps(new))


def prices_print_diff(proposal, cmp_, sources):
    print("Proposal checked on %s." % proposal["checked_on"])
    built_in_sources = _read_prices(PRICES_FILE).get("sources")
    built_in_sources = built_in_sources if isinstance(built_in_sources, dict) else {}
    for prov, c in cmp_.items():
        p = proposal["providers"][prov]
        print("\n%s (%s)" % (prov, p["source"] or sources.get(prov, {}).get("source") or "no source"))
        built_in = built_in_sources.get(prov)
        bd = _parse_date(built_in.get("as_of")) if isinstance(built_in, dict) else None
        if bd and proposal["checked_on"] < bd:
            print("  note: the built-in prices are newer (as of %s) than this check, so it will not take effect" % bd)
        for key, changes in c["changed"]:
            print("  %s" % key)
            for f, cur, new in changes:
                print("    " + _price_change_text(f, cur, new))
        if not c["changed"]:
            print("  no rate changes")
        if c["unchanged"]:
            print("  unchanged: " + ", ".join(c["unchanged"]))
        if c["new"]:
            print("  new (not in our table, never applied): " + ", ".join(c["new"]))
        if c["missing"]:
            print("  not found on the page: " + ", ".join(c["missing"]))
        if p["notes"]:
            print("  notes: " + p["notes"])
    if proposal.get("notes"):
        print("\nnotes: " + proposal["notes"])


def _prices_load(a):
    """(proposal, comparison, sources) of a diff/apply request; PricesError when invalid."""
    eff = load_prices()
    sources = {p: s for p, s in (eff.get("sources") or {}).items() if isinstance(s, dict)}
    proposal, errors = prices_validate(prices_read_proposal(a.file), sources, now().astimezone().date())
    if errors:
        raise PricesError("\n".join("  - " + e for e in errors))
    wanted = [str(p).strip().lower() for p in (getattr(a, "provider", None) or [])]
    for p in wanted:
        if p not in proposal["providers"]:
            raise PricesError("  - --provider %s is not in the proposal (it has: %s)" % (
                p, ", ".join(proposal["providers"])))
    return proposal, prices_compare(proposal, eff.get("usd_per_1m_tokens") or {}, set(wanted) or None), sources


def _cmd_prices_diff(a):
    try:
        proposal, cmp_, sources = _prices_load(a)
    except PricesError as ex:
        print("orch: invalid price proposal (%s):\n%s" % (a.file, ex), file=sys.stderr)
        return 2
    prices_print_diff(proposal, cmp_, sources)
    return 0


def _price_new_entry(current, prop, checked_on):
    """The dated element for a changed model: the proposal's rates, with cache_write and the peak fields kept from
    the current entry where the proposal leaves them out."""
    merged = {f: current[f] for f in ("cache_write",) + PRICE_PEAK_FIELDS if f in current}
    merged.update(prop)
    entry = {"from": checked_on}
    for f in PRICE_RATE_FIELDS + PRICE_PEAK_FIELDS:
        if f in merged:
            entry[f] = merged[f]
    return entry


def _price_close(raw, checked_on):
    """A model's entry as a dated list with `to` set on its open-ended elements (a dict entry first becomes a
    one-element list; an element that began today is replaced instead, one that begins later is left alone, closed
    ones are kept)."""
    elements = [raw] if isinstance(raw, dict) else [e for e in raw or [] if isinstance(e, dict)]
    out = []
    for e in elements:
        frm = _parse_date(e.get("from"))
        if e.get("to") or (frm and frm > checked_on):
            out.append(dict(e))
        elif not (frm and frm == checked_on):
            out.append(dict(e, to=checked_on.isoformat()))
    return out


@locked("home")
def _prices_write(proposal, only_providers, only_models):
    """Read-modify-write of the personal prices.json under the home lock: the file and the table are read again here,
    so what changed since the diff was shown is compared afresh. Returns (models written, providers confirmed)."""
    personal = read_json(PERSONAL_PRICES_FILE, {}, object_required=True)
    eff = load_prices()
    table = eff.get("usd_per_1m_tokens") or {}
    sources_now = eff.get("sources") or {}
    if not isinstance(personal.get("usd_per_1m_tokens"), dict):
        personal["usd_per_1m_tokens"] = {}
    if not isinstance(personal.get("sources"), dict):
        personal["sources"] = {}
    rates, srcs = personal["usd_per_1m_tokens"], personal["sources"]
    when = proposal["checked_on"].isoformat()
    applied = []
    cmp_ = prices_compare(proposal, table, only_providers)
    for prov, c in cmp_.items():
        skipped = False
        for key, _changes in c["changed"]:
            if only_models and key not in only_models:
                skipped = True
                continue
            current = _price_table_current(table, key) or {}
            elements = _price_close(table[key], proposal["checked_on"])
            elements.append(_price_new_entry(current, proposal["providers"][prov]["models"][key], when))
            rates[key] = elements
            applied.append(key)
        now_src = sources_now.get(prov) if isinstance(sources_now.get(prov), dict) else {}
        # a change left out by --model is not confirmed, so the provider keeps the date it had
        srcs[prov] = {"as_of": now_src.get("as_of") if skipped else when,
                      "source": proposal["providers"][prov]["source"] or now_src.get("source"),
                      "models": [k for k in rates if price_provider(k) == prov]}
    write_json(PERSONAL_PRICES_FILE, personal)
    return applied, sorted(cmp_)


def _cmd_prices_apply(a):
    only_models = [str(m).strip() for m in (getattr(a, "model", None) or [])]
    try:
        proposal, cmp_, sources = _prices_load(a)
        known = {k for c in cmp_.values() for k in c["unchanged"] + c["new"] + [x for x, _ in c["changed"]]}
        for m in only_models:
            if m not in known:
                raise PricesError("  - --model %s is not in the proposal (within the --provider filter)" % m)
    except PricesError as ex:
        print("orch: invalid price proposal (%s):\n%s" % (a.file, ex), file=sys.stderr)
        return 2
    prices_print_diff(proposal, cmp_, sources)
    if not getattr(a, "yes", False):
        print("\nNothing written. Once the operator has confirmed, run the same command again with --yes.")
        return 0
    wanted = {str(p).strip().lower() for p in (getattr(a, "provider", None) or [])}
    applied, provs = _prices_write(proposal, wanted or None, set(only_models) or None)
    print("\nWritten to %s: %s; confirmed as of %s for %s." % (
        PERSONAL_PRICES_FILE, ("changed " + ", ".join(applied)) if applied else "no rate changed",
        proposal["checked_on"], ", ".join(provs)))
    return 0


def cmd_prices(a):
    """orch prices [show] [--json] | check [--provider P]... | diff FILE | apply FILE [--provider P]... [--model M]...
    [--yes]."""
    action = getattr(a, "action", None) or "show"
    return {"show": _cmd_prices_show, "check": _cmd_prices_check, "diff": _cmd_prices_diff,
            "apply": _cmd_prices_apply}[action](a)


