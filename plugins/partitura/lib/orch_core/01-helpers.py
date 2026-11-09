# ───────────────────────── helpers ─────────────────────────

def now():
    return dt.datetime.now().astimezone()


def iso(t):
    return t.isoformat(timespec="seconds") if t else None


def iso_precise(t):
    """For what must order within one second: ledger entries against a spend baseline (a run that ended just
    before a reset stays out of the new count, one that ended just after is in it)."""
    return t.isoformat(timespec="microseconds")


def parse_iso(s):
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.astimezone()
    return t


def pct(x):
    """Round a percentage to the nearest integer (the %d form truncates, the apps show the rounded value)."""
    try:
        return int(round(float(x)))
    except (TypeError, ValueError):
        return 0


def human_delta(t):
    """'in 2h 10m' / '5m ago'."""
    secs = int((t - now()).total_seconds())
    if abs(secs) < 60:
        return "just now"
    future = secs >= 0
    secs = abs(secs)
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    parts = []
    if d:
        parts.append("%dd" % d)
    if h:
        parts.append("%dh" % h)
    if m or not parts:
        parts.append("%dm" % m)
    s = " ".join(parts[:2])
    return ("in " + s) if future else (s + " ago")


