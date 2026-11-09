# ───────────────────────── availability (quota) ─────────────────────────

AVAIL_FILE = ORCH_HOME / "availability.json"
STATUSES = ("ok", "low", "exhausted", "disabled", "away", "busy")


@locked("home")
def load_avail(prune=True, strict=False):
    try:
        data = read_json(AVAIL_FILE, {"entries": {}})
        if not isinstance(data.get("entries", {}), dict) or any(not isinstance(v, dict) for v in data.get("entries", {}).values()):
            raise StateError("cannot read %s: invalid entries" % AVAIL_FILE)
    except StateError as ex:
        if strict:
            raise
        warn_state(AVAIL_FILE, str(ex))
        return {"entries": {}}
    entries = data.setdefault("entries", {})
    if prune:
        changed = False
        for k in list(entries):
            until = parse_iso(entries[k].get("until"))
            if until and until <= now():
                del entries[k]
                changed = True
        if changed:
            write_json(AVAIL_FILE, data)
    return data


def norm_key(key):
    return key.strip().lower().replace(":", "/")


def key_chain(key):
    """codex/gpt-5.6-sol -> [codex/gpt-5.6-sol, codex];
    deepseek@work/deepseek-flash -> [deepseek@work/deepseek-flash, deepseek/deepseek-flash, deepseek@work, deepseek]"""
    parts = norm_key(key).split("/")
    head, _, prof = parts[0].partition("@")
    out = []
    for i in range(len(parts) - 1, -1, -1):
        tail = "".join("/" + x for x in parts[1:i + 1])
        if prof:
            out.append(head + "@" + prof + tail)
        out.append(head + tail)
    return out


def availability(key):
    """Return (available: bool, entry or None, matched_key)."""
    entries = load_avail()["entries"]
    for k in key_chain(key):
        e = entries.get(k)
        if e:
            return (e.get("status") == "low", e, k)
    return (True, None, None)


@locked("home")
def set_avail(key, status, until=None, note=None, source="manual"):
    key = norm_key(key)
    data = load_avail(strict=True)
    if status == "ok":
        data["entries"].pop(key, None)
    else:
        data["entries"][key] = {
            "status": status, "until": iso(until), "note": note,
            "set_at": iso(now()), "source": source,
        }
    write_json(AVAIL_FILE, data)


def describe_entry(k, e):
    until = parse_iso(e.get("until"))
    when = ("until %s (%s)" % (until.strftime("%d.%m %H:%M"), human_delta(until))) if until else \
        "until cleared manually"
    note = (" — " + e["note"]) if e.get("note") else ""
    return "%-28s %-9s %s%s" % (k, e.get("status"), when, note)


def availability_status(entry):
    return "CAPACITY" if entry.get("status") == "busy" else "QUOTA_EXHAUSTED"


@locked("home")
def cmd_quota(a):
    if a.action == "show":
        data = load_avail()
        if a.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
            return 0
        if not data["entries"]:
            print("All executors available (no restrictions).")
        for k, e in sorted(data["entries"].items()):
            print(describe_entry(k, e))
        return 0
    if a.action == "set":
        if a.status not in STATUSES:
            raise SystemExit("orch: status must be one of %s" % ", ".join(STATUSES))
        until = parse_until(a.until) if a.until else None
        set_avail(a.key, a.status, until, a.note)
        if a.status == "ok":
            print("%s: restriction cleared" % norm_key(a.key))
        else:
            print(describe_entry(norm_key(a.key), load_avail()["entries"][norm_key(a.key)]))
        return 0
    if a.action == "clear":
        key = norm_key(a.key)
        data = load_avail(strict=True)
        # a bare provider also clears its profile entries (deepseek → deepseek@work), not its model entries
        gone = [k for k in data["entries"] if k == key or ("/" not in key and "@" not in key and "/" not in k
                                                             and k.startswith(key + "@"))]
        for k in gone:
            del data["entries"][k]
        write_json(AVAIL_FILE, data)
        print("\n".join("%s: restriction cleared" % k for k in gone) or "%s: was not restricted" % key)
        return 0
    if a.action == "check":
        ok, e, k = availability(a.key)
        if e is None:
            print("%s: available" % norm_key(a.key))
            return 0
        print(("%s: available (LOW) — " if ok else "%s: UNAVAILABLE — ") % norm_key(a.key) + describe_entry(k, e))
        return 0 if ok else EXIT_QUOTA
    return 1


