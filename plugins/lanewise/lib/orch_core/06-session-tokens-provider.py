# ───────────────────────── session tokens per provider (second status line) ─────────────────────────
#
# The second status line shows this session's cumulative input/output per provider, with cache reads beside them. The
# numbers must agree with `orch usage`: the orchestrator thread + subagents come from the transcript (each message
# counted once), the CLI executors from ~/.lanewise/usage.jsonl. Transcripts grow to many megabytes, so each file
# is parsed incrementally: ~/.lanewise/session_tokens/<session>.json holds the byte offset already parsed and the
# running totals; only appended bytes are read, a partial last line is left for the next call.
#
# The status line runs on every update and the next update may kill it, so a refresh rewrites only this session's small
# file, and at most once per SESSION_SAVE_SECONDS. In between it parses from the saved offset and shows the result
# without saving it: the parse is idempotent, the same bytes give the same totals on the next refresh.
#
# The same parse keeps the session's tokens per local day and model (the `daily` part of the entry), out of which the
# daily totals are folded: the status line never writes the shared store, it only carries the buckets in its own file.

SESSION_TOKENS_FILE = ORCH_HOME / "session_tokens.json"     # the old cache of all sessions: read only to migrate one
SESSION_TOKENS_DIR = ORCH_HOME / "session_tokens"
SESSION_SAVE_SECONDS = 30
SESSION_KEEP_SECONDS = 86400
SESSION_ID_RE = re.compile(r"[a-z0-9-]{8,100}")             # as a file name on any system; other ids are hashed
IDS_PER_FILE = 100             # a re-sent message is adjacent to its first copy (the lines of one streamed response)
IDS_IDLE_SECONDS = 600         # a file that has not grown for this long keeps no ids
PARSE_BYTES_PER_RUN = 8 * 1024 * 1024


def transcript_provider(model):
    m = str(model or "").lower()
    return "deepseek" if m.startswith("deepseek") else "claude"


def message_day(stamp):
    """The local day (YYYY-MM-DD) of a transcript timestamp, or None."""
    t = parse_iso(str(stamp).replace("Z", "+00:00")) if isinstance(stamp, str) and stamp else None
    return day_str(t) if t is not None else None


def daily_bucket(state, day, model, counts, cost):
    """Add a message's raw counts ({in, cr, cw, out}) and its own cost under one day and model of a parse state's
    per-day buckets (the buckets the daily totals are folded from)."""
    if not day:
        return
    buckets = state.get("daily")
    if not isinstance(buckets, dict):
        buckets = state["daily"] = {}
    by = buckets.setdefault(day, {}).setdefault(str(model), {"in": 0, "cr": 0, "cw": 0, "out": 0, "cost": 0.0})
    for k in ("in", "cr", "cw", "out"):
        by[k] = tok_int(by.get(k)) + tok_int(counts.get(k))
    by["cost"] = round(float(by.get("cost") or 0.0) + float(cost or 0.0), 6)


def daily_uncount(state, old):
    """Take an earlier copy of a message out of a parse state's per-day buckets: the id's raw counts, cost, day and
    model are saved with it, so a re-sent message replaces its first copy, in the buckets as in the totals."""
    raw, day, model = old.get("r"), old.get("d"), old.get("m")
    if not (isinstance(raw, list) and len(raw) == 4 and day and model):
        return
    buckets = state.get("daily") if isinstance(state.get("daily"), dict) else {}
    by = (buckets.get(day) or {}).get(str(model)) if isinstance(buckets.get(day), dict) else None
    if not isinstance(by, dict):
        return
    for k, v in zip(("in", "cr", "cw", "out"), raw):
        by[k] = max(tok_int(by.get(k)) - tok_int(v), 0)
    by["cost"] = max(round(float(by.get("cost") or 0.0) - float(old.get("x") or 0.0), 6), 0.0)


def read_new_lines(path, offset, size, limit=None):
    """The complete lines of a file between byte `offset` and `size`, about `limit` bytes of them at most; b"" while
    there is only a partial last line. One line longer than the limit is read whole, or it could never be passed."""
    left = size - offset
    with Path(path).open("rb") as f:
        f.seek(offset)
        data = f.read(left if limit is None else min(left, limit))
        while b"\n" not in data and len(data) < left:
            more = f.read(min(left - len(data), max(len(data), 65536)))
            if not more:
                break
            data += more
    return data[:data.rfind(b"\n") + 1]


def trim_ids(state, keep):
    """Keep the newest `keep` ids of a file's state; `floor` remembers the newest of those dropped, as {t, id}.
    True when any was dropped."""
    ids = state.get("ids")
    if not isinstance(ids, dict) or len(ids) <= keep:
        return False
    names = list(ids)
    floor = state.get("floor") if isinstance(state.get("floor"), dict) else {}
    for mid in names[:len(names) - keep]:
        stamp = ids[mid].get("t") if isinstance(ids[mid], dict) else None
        if isinstance(stamp, str) and stamp >= str(floor.get("t") or ""):
            floor = {"t": stamp, "id": mid}
        del ids[mid]
    if floor:
        state["floor"] = floor
    return True


def parse_append(path, state, limit=None):
    """Count assistant usage appended to a transcript file; state: {offset, ids, floor, in, out, cache, provider}. At
    most about `limit` bytes are read. Returns (changed, behind): the state changed (bytes consumed, the file was reset
    after shrinking, ids dropped), and the limit left bytes unread.

    The lines of one message share an id and carry its usage so far: the last one replaces the earlier ones. Only the
    newest IDS_PER_FILE ids are kept, none once the file is idle, so an id seen again after being dropped cannot be
    told from a new message. Its timestamp can: a line older than the newest dropped id, or that message itself, is a
    copy of what was already counted, and is skipped. A copy with a new timestamp would count again; re-sends are
    adjacent in practice (CHANGELOG 0.18.1)."""
    path = Path(path)
    try:
        st = path.stat()
    except OSError:
        return False, False
    size = st.st_size
    offset = tok_int(state.get("offset"))
    changed = False
    if size < offset:                      # the file shrank: start over
        offset = 0
        state["offset"] = 0
        state["ids"] = {}
        state.pop("floor", None)
        state.pop("start", None)
        state["in"] = 0
        state["out"] = 0
        state["cache"] = 0
        state["daily"] = {}
        changed = True
    if offset and "start" not in state:
        # Old state: inspect at most 64 KiB of complete head lines, once, without moving the saved offset.
        try:
            with path.open("rb") as f:
                head = f.read(min(size, 65536))
            for line in head[:head.rfind(b"\n") + 1].splitlines():
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                stamp = ev.get("timestamp") if isinstance(ev, dict) else None
                if isinstance(stamp, str) and stamp:
                    state["start"] = stamp
                    break
            else:
                state["start"] = None
            changed = True
        except OSError:
            return changed, False
    behind = limit is not None and size - offset > limit
    data = b""
    if size > offset:
        try:
            data = read_new_lines(path, offset, size, limit)
        except OSError:
            return changed, False
    if data:                               # else only a partial last line so far: leave it for the next call
        ids = state.get("ids")
        if not isinstance(ids, dict):
            ids = state["ids"] = {}
        floor = state.get("floor") if isinstance(state.get("floor"), dict) else {}
        floor_t = floor.get("t") if isinstance(floor.get("t"), str) else None
        for line in data.decode("utf-8", "replace").splitlines():
            assistant = '"type":"assistant"' in line
            if not assistant and state.get("start"):
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            stamp = ev.get("timestamp") if isinstance(ev.get("timestamp"), str) else None
            if not state.get("start") and stamp:
                state["start"] = stamp
            if not assistant or (state.get("start") and stamp and stamp < state["start"]):
                continue
            msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
            model = msg.get("model")
            if ev.get("type") != "assistant" or not model or str(model).startswith("<"):
                continue
            mid = msg.get("id") or ev.get("requestId") or ev.get("uuid")
            raw = transcript_counts(msg.get("usage") or {})
            cost = daily_message_cost(model, raw, stamp)
            inp, out, cache = raw["in"] + raw["cw"], raw["out"], raw["cr"]
            day = message_day(stamp)
            if mid:
                old = ids.pop(mid, None)   # put back below as the newest
                if isinstance(old, dict):
                    inp -= tok_int(old.get("i"))
                    out -= tok_int(old.get("o"))
                    cache -= tok_int(old.get("c"))
                    daily_uncount(state, old)
                elif floor_t and stamp and (stamp < floor_t or (stamp == floor_t and mid == floor.get("id"))):
                    continue
                ids[mid] = {"i": raw["in"] + raw["cw"], "o": raw["out"], "c": raw["cr"], "x": round(cost, 6),
                            "r": [raw["in"], raw["cr"], raw["cw"], raw["out"]], "d": day, "m": str(model)}
                if stamp:
                    ids[mid]["t"] = stamp
            daily_bucket(state, day, model, raw, cost)
            state["in"] = tok_int(state.get("in")) + inp
            state["out"] = tok_int(state.get("out")) + out
            state["cache"] = tok_int(state.get("cache")) + cache
            if not state.get("provider"):
                state["provider"] = transcript_provider(model)
        state["offset"] = offset + len(data)
        changed = True
    idle = not behind and time.time() - st.st_mtime >= IDS_IDLE_SECONDS
    if trim_ids(state, 0 if idle else IDS_PER_FILE):
        changed = True
    return changed, behind


def tok_int(v):
    """A token count from untrusted JSON: 0 for anything that is not a number."""
    try:
        return int(v or 0)
    except (TypeError, ValueError, OverflowError):
        return 0


def parse_ledger_append(offset, sid, limit=None):
    """(new_offset, {label: {input, output, cache}}, changed, behind) from run records of sid appended to the ledger;
    `behind`: the limit left bytes unread. The key is the record's profile label (deepseek@work, codex, …), the provider
    for a record without one: usage on different accounts stays apart."""
    out = {}
    try:
        size = USAGE_FILE.stat().st_size
    except OSError:
        return offset, out, False, False
    changed = False
    if size < offset:
        offset = 0
        changed = True
    if size <= offset:
        return offset, out, changed, False
    behind = limit is not None and size - offset > limit
    try:
        data = read_new_lines(USAGE_FILE, offset, size, limit)
    except OSError:
        return offset, out, changed, False
    if not data:
        return offset, out, changed, False
    plain_id = isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9_-]+", sid)    # stored as is: a quick test for most lines
    for line in data.decode("utf-8", "replace").splitlines():
        if plain_id and sid not in line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("kind") != "run" or rec.get("session") != sid:
            continue
        u = rec.get("usage")
        if not isinstance(u, dict):
            continue
        acct = str(rec.get("label") or rec.get("provider") or "?").lower()
        t = out.setdefault(acct, {"input": 0, "output": 0, "cache": 0})
        t["input"] += tok_int(u.get("input_tokens"))
        t["output"] += tok_int(u.get("output_tokens"))
        t["cache"] += tok_int(u.get("cached_input_tokens"))
    return offset + len(data), out, True, behind


# Version of the cached entry. 2 = keyed by the run record's profile label (an entry without it was keyed by provider);
# 3 = cache reads counted too, in the ledger and in each transcript file; 4 = the per-day and per-model buckets of the
# daily totals. An older entry lacks a part of what is counted, so its ledger part and transcript files restart from 0.
SESSION_TOKENS_FORMAT = 4


def account_sort_key(label):
    """Provider, then the plain account first, then the labels alphabetically."""
    provider, _, name = str(label).partition("@")
    return (provider, bool(name), name)


def native_account(where):
    """The account this session's own thread (Claude) bills to: the label of a key profile (claude@work), else
    `claude` - the default login, the same account as `orch run claude` there. Any error or unknown directory: claude."""
    if not where:
        return "claude"
    try:
        prof = resolve_profile("claude", Path(where), follow=False)
        return prof.label if prof.explicit and prof.data.get("key") else "claude"
    except Exception:
        return "claude"


def lead_provider_label(provider):
    """The label `ORCH_LEAD` gives a provider whose own thread this is (deepseek@work), or None. A non-Claude lead
    runs its main thread and its orch-* subagents on that provider, so their tokens belong to the lead's account."""
    lead = (os.environ.get("ORCH_LEAD") or "").strip().lower()
    return lead if lead and lead.partition("@")[0] == str(provider or "").lower() else None


def session_tokens_path(sid):
    """This session's file. An id unfit for a file name (one from another tool, a device name, a case-only
    difference) is hashed."""
    if SESSION_ID_RE.fullmatch(sid):
        return SESSION_TOKENS_DIR / (sid + ".json")
    import hashlib
    return SESSION_TOKENS_DIR / ("x-" + hashlib.sha256(sid.encode("utf-8", "replace")).hexdigest() + ".json")


def read_session_entry(path, strict=False):
    """A saved entry, or None; strict readers distinguish missing/broken files from successfully read empty entries."""
    try:
        entry = json.loads(_read_text_retry(path))
    except (OSError, ValueError):
        if strict:
            raise
        return None
    if strict and not isinstance(entry, dict):
        raise ValueError("expected a session counter object")
    return entry if isinstance(entry, dict) else None


def session_paid_via_note(sid, where=None):
    """Freeze how the lead is paid (`paid_via`: api or subscription) on first observation, even before the status line sees a transcript."""
    if not sid:
        return
    with state_lock(ORCH_HOME / ".state.lock"):
        path = session_tokens_path(sid)
        try:
            entry = read_session_entry(path, strict=True)
        except FileNotFoundError:
            entry = {}
        if entry.get("paid_via") not in ("api", "subscription"):
            entry["paid_via"] = session_paid_via(where)
            entry["session"] = sid
            write_json(path, entry, compact=True)


def session_entry_saved_recently(entry, t):
    updated = parse_iso(entry.get("updated")) if isinstance(entry.get("updated"), str) else None
    return updated is not None and 0 <= (t - updated).total_seconds() < SESSION_SAVE_SECONDS


def save_session_entry(sid, entry, t, always):
    """Save under the lock, unless another run of this session did so just now. A busy lock skips the save: the next
    refresh parses the same bytes from the same saved offset. An entry is a whole snapshot (offsets with their totals),
    so even a run overtaken by a newer save only makes the next refresh parse a little more."""
    path = session_tokens_path(sid)
    with state_lock(ORCH_HOME / ".state.lock"):
        if not always:
            saved = read_session_entry(path)
            if saved is not None and session_entry_saved_recently(saved, t):
                return
        write_json(path, dict(entry, updated=iso(t)), compact=True)


def session_tokens(sid, transcript_path, native="claude", where=None):
    """Refresh this session's token counters and return {account: {input, output, cache}}: account is a profile label
    (deepseek@work, codex), so one provider's separate accounts stay separate. The session's own Claude thread counts
    under `native`. The entry also carries the session's own id, its project and its tokens per local day and model
    (with the account each provider froze at), which the daily totals are folded from. See above for when the counters
    are saved; a backlog over PARSE_BYTES_PER_RUN (a long transcript seen for the first time) is the exception, its
    progress is saved at once, so runs that get killed still get through it."""
    t = now()
    path = session_tokens_path(sid)
    entry = read_session_entry(path)
    first = entry is None
    if first:                               # a session running across the upgrade continues from its old entry
        try:
            old = read_json(SESSION_TOKENS_FILE, {}).get(sid)
        except StateError:
            old = None
        entry = old if isinstance(old, dict) else {}
    entry.setdefault("files", {})
    if not isinstance(entry["files"], dict):
        entry["files"] = {}
    if first:
        for state in entry["files"].values():
            if isinstance(state, dict):
                trim_ids(state, IDS_PER_FILE)
    changed = False
    if entry.get("paid_via") not in ("api", "subscription"):
        entry["paid_via"] = session_paid_via(where, native)
        changed = True
    if entry.get("format") != SESSION_TOKENS_FORMAT or not isinstance(entry.get("ledger"), dict) \
            or not isinstance(entry.get("ledger_offset"), int):
        changed = True                      # an old-format (or damaged) entry: rebuild ledger and transcripts
        entry["ledger"] = {}
        entry["ledger_offset"] = 0
        entry["files"] = {}                 # their saved totals carry no cache: parse the transcripts from 0 again
        entry["format"] = SESSION_TOKENS_FORMAT
    files = []
    if transcript_path and Path(transcript_path).is_file():
        files.append(Path(transcript_path))
    else:
        found = transcript_for(sid)
        if found:
            files.append(found)
    if files:
        sub = files[0].with_suffix("") / "subagents"
        if sub.is_dir():
            files += sorted(sub.glob("agent-*.jsonl"))
    left, behind = PARSE_BYTES_PER_RUN, False
    for f in files:
        if left <= 0:
            behind = True
            break
        state = entry["files"].get(str(f))
        if not isinstance(state, dict):
            state = entry["files"][str(f)] = {}
        start = tok_int(state.get("offset"))
        file_changed, file_behind = parse_append(f, state, left)
        changed = changed or file_changed
        behind = behind or file_behind
        left -= max(tok_int(state.get("offset")) - start, 0)
    offset, ledg, ledger_changed, ledger_behind = parse_ledger_append(entry["ledger_offset"], sid, PARSE_BYTES_PER_RUN)
    entry["ledger_offset"] = offset
    changed = changed or ledger_changed
    behind = behind or ledger_behind
    for acct, d in ledg.items():
        tt = entry["ledger"].get(acct)
        if not isinstance(tt, dict):
            tt = entry["ledger"][acct] = {"input": 0, "output": 0, "cache": 0}
        tt["input"] = tok_int(tt.get("input")) + d["input"]
        tt["output"] = tok_int(tt.get("output")) + d["output"]
        tt["cache"] = tok_int(tt.get("cache")) + d["cache"]
    if entry.get("session") != sid:
        entry["session"] = sid
        changed = True
    if where:
        project = canon_path(project_root(where))
        if entry.get("project") != project:
            entry["project"] = project
            changed = True
    accounts = entry.get("accounts")
    if not isinstance(accounts, dict):
        accounts = entry["accounts"] = {}
    for state in entry["files"].values():
        prov = str(state.get("provider") or "claude") if isinstance(state, dict) else ""
        if prov and prov not in accounts:       # frozen: a profile switch later cannot move earlier tokens
            accounts[prov] = native if prov == "claude" else lead_provider_label(prov) or prov
            changed = True
    daily = {}
    for state in entry["files"].values():
        if not (isinstance(state, dict) and isinstance(state.get("daily"), dict)):
            continue
        for day, models in state["daily"].items():
            if not isinstance(models, dict):
                continue
            target = daily.setdefault(day, {})
            for model, counts in models.items():
                if not isinstance(counts, dict):
                    continue
                total = target.setdefault(str(model), {"in": 0, "cr": 0, "cw": 0, "out": 0, "cost": 0.0})
                for k in ("in", "cr", "cw", "out"):
                    total[k] += tok_int(counts.get(k))
                total["cost"] = round(float(total.get("cost") or 0.0) + float(counts.get("cost") or 0.0), 6)
    if daily != entry.get("daily"):
        entry["daily"] = daily
        changed = True
    if first or behind or (changed and not session_entry_saved_recently(entry, t)):
        try:
            save_session_entry(sid, entry, t, first or behind)
        except StateError:
            pass
    totals = {}

    def add(acct, inp, out, cache):
        tt = totals.setdefault(acct, {"input": 0, "output": 0, "cache": 0})
        tt["input"] += tok_int(inp)
        tt["output"] += tok_int(out)
        tt["cache"] += tok_int(cache)

    for f in entry["files"].values():
        if isinstance(f, dict):
            prov = f.get("provider") or "claude"
            # the lead's own thread (and its orch-* subagents) bills to the lead's account, not the bare provider
            add(native if prov == "claude" else lead_provider_label(prov) or prov,
                f.get("in"), f.get("out"), f.get("cache"))
    for acct, d in entry["ledger"].items():
        if isinstance(d, dict):
            add(acct, d.get("input"), d.get("output"), d.get("cache"))
    return totals


def sweep_orch_home():
    """Remove day-old *.tmp leftovers and the old all-session cache. Only directory metadata is read;
    session counters belong to hook/report maintenance, never the status line."""
    cutoff = time.time() - SESSION_KEEP_SECONDS
    for base in (ORCH_HOME, SESSION_TOKENS_DIR):
        try:
            with os.scandir(str(base)) as it:
                for e in it:
                    if e.name.endswith(".tmp") or e.name == SESSION_TOKENS_FILE.name:
                        if e.stat().st_mtime < cutoff:
                            os.unlink(e.path)
        except OSError:
            pass


def quietly(fn, *args):
    """A status line part: its failure (a busy lock above all) costs only that part, and only until the next update."""
    try:
        return fn(*args)
    except Exception:
        return None


def session_status_part(sid, transcript_path, where=None, spend=None):
    """'Session in/out: Claude 370k/111k +28M cache\n  DeepSeek@work 90k/9k (est. $0.99/$12, account $9.73)', or None
    with nothing to show. One counter per account (profile label), never a sum over a provider's accounts; cache reads
    follow the in/out pair as '+N cache', left out when there are none. One account per line: the first on the heading
    line, each further one indented by two spaces. `spend` is [(account label, display name, text)] from
    spend_status_items: each text joins the counter of the same account, in parentheses, matched on the lowercase label
    (the ledger's key), since two accounts can display alike; a scope with money but no tokens in this session follows
    the counters on a line of its own, and with no tokens at all the line is only those, with no 'Session in/out:'
    heading. Any error in the tokens costs only the tokens."""
    counters = []
    if sid:
        try:
            totals = session_tokens(sid, transcript_path, native_account(where), where)
            counters = [(str(acct).lower(), scope_name(acct),
                         "%s/%s%s" % (fmt_tok(d["input"]), fmt_tok(d["output"]),
                                      (" +%s cache" % fmt_tok(d["cache"])) if d.get("cache") else ""))
                        for acct, d in sorted(totals.items(), key=lambda kv: account_sort_key(kv[0]))
                        if d["input"] + d["output"] > 0]
        except Exception:
            counters = []
    extra = {label: text for label, _, text in spend or ()}
    parts = []
    for label, name, tokens in counters:
        text = extra.pop(label, None)
        parts.append("%s %s%s" % (name, tokens, " (%s)" % text if text else ""))
    loose = ["%s (%s)" % (name, text) for label, name, text in spend or () if label in extra]
    if not parts and not loose:
        return None
    return ("Session in/out: " if parts else "") + "\n  ".join(parts + loose)


def cmd_statusline(a):
    """Claude Code statusLine command: keep the subscription usage for routing; print a short status line.
    Never fails (a broken status line would be visible on every screen)."""
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""
    parts = []
    try:
        data = json.loads(raw or "{}")
        learn_session_id(data)
        rl = data.get("rate_limits") if isinstance(data.get("rate_limits"), dict) else {}
        windows = {}
        for name in ("five_hour", "seven_day"):
            w = rl.get(name)
            if isinstance(w, dict) and w.get("used_percentage") is not None and epoch_iso(w.get("resets_at")):
                windows[name] = {"used": round(float(w["used_percentage"]), 1), "resets_at": epoch_iso(w["resets_at"])}
        cwd = (data.get("workspace") or {}).get("current_dir") if isinstance(data.get("workspace"), dict) else None
        api_billed = session_paid_via(Path(cwd) if cwd else None) == "api"
        if windows and not api_billed:
            quietly(save_usage, windows, "statusline")
        model = (data.get("model") or {}).get("display_name") if isinstance(data.get("model"), dict) else None
        if data.get("session_id") and not api_billed:
            quietly(heartbeat, str(data["session_id"]), cwd)  # this session counts among the Claude consumers
        if not api_billed:
            snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
            five, week = usage_window(snap, "five_hour"), usage_window(snap, "seven_day")
            mode, budget_line = claude_budget(Path(cwd) if cwd else None)
            n = sum(1 for v in claude_consumers().values() if v.get("kind") != "executor")
            five_projection = window_projection(snap, "five_hour", 5) if five and five[1] else None
            week_projection = window_projection(snap, "seven_day", 7) if week else None
            shown = [n for n, w in (("five_hour", five and five[1]), ("seven_day", week)) if w]
            stamps = [m for m in (measured_at(snap, n) for n in shown) if m]   # the older of the windows shown
            claude_line = provider_line(
                claude_status_name(model),
                (five[0], five[1]) if five and five[1] else None,
                (week[0], week[1]) if week else None,
                short_mode(mode, budget_line, Path(cwd) if cwd else None, week_shown=week_projection is not None),
                min(stamps) if stamps else None,
                sessions=n,
                five_projection=five_projection,
                week_projection=week_projection,
            )
            if claude_line:
                parts.append(claude_line)
        elif model:
            parts.append(claude_status_name(model))
    except Exception:
        pass
    line = " · ".join(parts) or "Lanewise"
    extra = []                 # one more line each: the Codex limits, this session's tokens
    try:
        data = json.loads(raw or "{}")
        cwd = (data.get("workspace") or {}).get("current_dir") if isinstance(data.get("workspace"), dict) else None
        sid = data.get("session_id")
        where = Path(cwd) if cwd else None
        quietly(refresh_codex, where)
        spend = (quietly(spend_status_items, where) or []) if where else []   # always shown, beside the tokens
        session_line = session_status_part(str(sid) if sid else None, data.get("transcript_path"), where, spend)
        pause_line = quietly(watch_pause_line, str(sid) if sid else None)     # read-only: the status line only reads
        extra = [p for p in (pause_line, quietly(codex_status_part, where), session_line) if p]
        quietly(sweep_orch_home)
    except Exception:
        extra = []
    if a.then:
        try:
            import subprocess         # the operator's own command is the one process a status line may start
            r = subprocess.run(a.then, shell=True, input=raw.encode("utf-8"), stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=5)
            theirs = r.stdout.decode("utf-8", "replace").replace("\r\n", "\n").rstrip("\n")   # cmd.exe: CRLF
            line = (theirs + "  " + line) if theirs and "\n" not in theirs else (theirs + "\n" + line if theirs else line)
        except Exception:
            pass
    print(line)
    for part in extra:
        print(part)
    return 0


