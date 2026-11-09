# ───────────────────────── usage ledger ─────────────────────────
#
# ~/.orchestra/usage.jsonl, one record per line: kind run (CLI executor: model, task, tokens from the adapter's
# usage.json), handoff (manual task: agent, model, minutes) and session (Claude Code main thread + subagents,
# snapshot at SessionEnd so the numbers outlive transcript cleanup). `orch usage` joins them per session.

USAGE_FILE = ORCH_HOME / "usage.jsonl"


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


