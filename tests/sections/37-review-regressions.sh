echo "── review regressions (isolated processes and deterministic snapshots)"
# standalone setup (a no-op once the earlier sections have run)
mkdir -p "$T/claude-cfg"
review=$($PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/review")" <<'EOF'
import argparse
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import traceback
from unittest import mock

if not (os.environ.get("ORCH_CODEX_BIN") and os.environ.get("ORCH_CLAUDE_BIN")):
    sys.exit("This block runs inside run_tests.sh: without its fakes, its runs would call the real codex and claude.")
orch, root = str(Path(sys.argv[1]).resolve()), Path(sys.argv[2])
root.mkdir()
root = root.resolve()      # a Windows short name in TEMP: orch compares and reports the long form
home, proj = root / "home", root / "proj"
home.mkdir(); proj.mkdir()
env = dict(os.environ, ORCH_HOME=str(home), ORCH_PROJECT_DIR=str(proj), ORCH_NOTIFY_CMD="",
           PYTHONIOENCODING="utf-8", PYTHONUTF8="1", DUMMY_A="aaaaaaaaaaaa", DUMMY_B="bbbbbbbbbbbb")
for key in ("ORCH_WORKER", "ORCH_PROFILES", "CLAUDE_PROJECT_DIR", "ORCH_LEAD", "ORCH_LEAD_ENV", "CLAUDECODE",
            "ORCH_LEAD_VIA", "ORCH_LEAD_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
            "ANTHROPIC_MODEL"):
    env.pop(key, None)
for args in (["init", "-q"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"]):
    subprocess.run(["git"] + args, cwd=str(proj), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
(proj / "app.txt").write_text("initial\n", encoding="utf-8")
subprocess.run(["git", "add", "."], cwd=str(proj), check=True)
subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "-qm", "init"], cwd=str(proj), check=True)
os.environ.update(env)
loader = importlib.machinery.SourceFileLoader("review_orch", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("review_orch", loader)); loader.exec_module(m)
_h = importlib.machinery.SourceFileLoader("review_headless", str(Path(orch).parent.parent / "adapters" / "_claude_headless.py"))
H = importlib.util.module_from_spec(importlib.util.spec_from_loader("review_headless", _h)); _h.exec_module(H)

def run(args, data="task\n", extra=None):
    r = subprocess.run([sys.executable, orch] + args, input=data, text=True, encoding="utf-8",
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=str(proj),
                       env=dict(env, **(extra or {})), timeout=30)
    return r.returncode, r.stdout + r.stderr

def good(args, data="task\n", extra=None):
    rc, out = run(args, data, extra)
    assert rc == 0, (args, rc, out)
    return out

def start(args, data="task\n"):
    p = subprocess.Popen([sys.executable, orch] + args, env=env, cwd=str(proj), stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.stdin.write(data.encode("utf-8")); p.stdin.close(); p.stdin = None
    return p

def finish(p):
    out, err = p.communicate(timeout=30)
    return p.returncode, (out + err).decode("utf-8", "replace")

def offered(**kw):
    args = ["handoff", "offer", "--title", "review", "--max-offers", "50"]
    for k, v in kw.items():
        args += ["--" + k.replace("_", "-")] + ([] if v is True else [str(v)])
    return re.search(r"AG-\d+", good(args)).group()

def meta(hid):
    return m.read_json(m.handoffs_root() / hid / "meta.json", {})

def clear_tasks():
    for task in m.all_metas():
        if not task.get("archived"):
            good(["handoff", "cancel", task["id"]]); good(["handoff", "close", task["id"]])

def parallel_state():
    results = [finish(p) for p in [start(["handoff", "offer", "--title", "parallel-%d" % i,
                                         "--max-offers", "50"]) for i in range(4)]]
    assert all(rc == 0 and "Traceback" not in out for rc, out in results), results
    ids = [re.search(r"AG-\d+", out).group() for _, out in results]
    assert len(set(ids)) == 4
    assert {meta(h)["title"] for h in ids} == {"parallel-%d" % i for i in range(4)}
    for _ in range(2):
        hid = offered()
        take = start(["handoff", "take", hid]); reclaim = start(["handoff", "reclaim", hid])
        results = [finish(take), finish(reclaim)]
        assert sorted(rc for rc, _ in results) == [0, 1], results
        task = meta(hid)
        assert bool(task.get("taken")) != bool(task.get("reclaim")), task
        good(["handoff", "cancel", hid])
    ps = [start(["statusline"], json.dumps({"session_id": "parallel-%d" % i,
          "workspace": {"current_dir": str(proj)}, "rate_limits": {
              "five_hour": {"used_percentage": 10, "resets_at": 4102444800}}})) for i in range(8)]
    assert all(rc == 0 and "Traceback" not in out for rc, out in map(finish, ps))
    # a status line doesn't wait for a busy lock and registers on a later update; a hook waits, and none may be lost
    ps = [start(["hook", "user-prompt"], json.dumps({"session_id": "parallel-%d" % i, "cwd": str(proj)})) for i in range(8)]
    assert all(rc == 0 and "Traceback" not in out for rc, out in map(finish, ps))
    sessions = m.read_json(home / "sessions.json", {})
    assert all("parallel-%d" % i in sessions for i in range(8)), sessions
    assert not list(home.glob("*.tmp"))
    counter = m.handoffs_root() / "counter.json"
    high = max(int(x["id"].split("-")[1]) for x in m.all_metas())
    for corrupt in (True, False):
        if corrupt:
            counter.write_text("{broken", encoding="utf-8")
        else:
            counter.unlink()
        assert int(offered().split("-")[1]) > high
        high += 1
    clear_tasks()
    results = [finish(p) for p in [start(["handoff", "offer", "--title", "cap", "--max-offers", "1"])
                                    for _ in range(3)]]
    assert sorted(rc for rc, _ in results) == [0, 75, 75], results
    clear_tasks()

def state_failures():
    path = home / "io.json"
    m.write_json(path, {"preserved": True})
    original_replace = m.os.replace
    calls = []
    def sharing(src, dst):
        calls.append(src)
        if len(calls) < 3:
            raise PermissionError("sharing violation")
        return original_replace(src, dst)
    with mock.patch.object(m.os, "replace", sharing):
        m.write_json(path, {"preserved": "updated"})
    assert len(calls) == 3 and m.read_json(path, {})["preserved"] == "updated"
    with mock.patch.object(m.os, "replace", side_effect=PermissionError("busy")), mock.patch.object(m.time, "sleep"):
        try:
            m.write_json(path, {})
            raise AssertionError("replace failure ignored")
        except m.StateError:
            pass
    assert not list(home.glob("*.tmp")) and m.read_json(path, {})["preserved"] == "updated"
    with mock.patch.object(m.Path, "read_text", side_effect=PermissionError("busy")), mock.patch.object(m.time, "sleep"):
        try:
            m.read_json(path, {})
            raise AssertionError("unreadable state treated as empty")
        except m.StateError:
            pass
    # load_spend_limits retries the same sharing violation (it shares _read_text_retry, not a bare read_text).
    reads = []
    def flaky_read(*a, **k):
        reads.append(a)
        if len(reads) < 3:
            raise PermissionError("sharing violation")
        return '{"global": {}}'
    with mock.patch.object(m.Path, "read_text", side_effect=flaky_read), mock.patch.object(m.time, "sleep"):
        cfg, err = m.load_spend_limits()
        assert err is None and isinstance(cfg, dict) and cfg["global"] == {}, (cfg, err)
    assert len(reads) == 3
    hid = offered(write=True, base="missing-review-ref")     # the worktree cannot be made: the take fails
    rc, out = run(["handoff", "take", hid])
    assert rc != 0 and m.result_status(meta(hid)) == "OFFERED", (rc, out, meta(hid))
    clear_tasks()
    hid = offered()
    (m.handoffs_root() / hid / "BODY.md").unlink()           # the assignment cannot read its task: the take fails
    rc, out = run(["handoff", "take", hid])
    assert rc != 0 and m.result_status(meta(hid)) == "OFFERED", (rc, out, meta(hid))
    clear_tasks()
    # Both notification and assignment write meta: force their interleaving around external work.
    hid = offered()
    with m.state_lock(m.state_dir() / ".state.lock"):
        task = m.load_meta(hid); m.claim_handoff(task, m.resolve_profile("antigravity", proj))
    original_assign = m.assign_handoff
    def assign(claim, prof):
        good(["handoff", "check"])
        return original_assign(claim, prof)
    with mock.patch.object(m, "assign_handoff", assign):
        m.materialize_handoff(task, m.resolve_profile("antigravity", proj))
    assert meta(hid)["taken"] and not meta(hid).get("assigning")
    ps = [start(["handoff", "check"]), start(["handoff", "done", hid])]
    assert all(rc == 0 for rc, _ in map(finish, ps))
    assert meta(hid)["manual_status"] == "DONE" and meta(hid)["taken"]
    # A mode notification must preserve usage changed after its first budget read.
    m.save_usage({"five_hour": {"used": 10, "resets_at": m.iso(m.now() + dt.timedelta(hours=2))}}, "test")
    original_budget = m.claude_budget
    def new_usage():
        mode, line = original_budget()
        m.save_usage({"five_hour": {"used": 27, "resets_at": m.iso(m.now() + dt.timedelta(hours=2))}}, "test")
        return mode, line
    with mock.patch.object(m, "claude_budget", new_usage):
        m.budget_event("review-update")
    assert m.read_json(m.USAGE_SNAPSHOT, {})["five_hour"]["used"] == 27
    clear_tasks()
    # Real holder, bounded waiter, silent hook/statusline, and OS release on process death.
    holder_code = "import importlib.machinery,importlib.util,sys,time; l=importlib.machinery.SourceFileLoader('o',sys.argv[1]); m=importlib.util.module_from_spec(importlib.util.spec_from_loader('o',l)); l.exec_module(m); c=m.state_lock(m.ORCH_HOME/'.state.lock'); c.__enter__(); print('ready',flush=True); time.sleep(30)"
    holder = subprocess.Popen([sys.executable, "-B", "-c", holder_code, orch], env=env, cwd=str(proj),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert holder.stdout.readline().strip() == b"ready"
        with mock.patch.object(m, "LOCK_WAIT", 0.05):
            try:
                m.heartbeat("busy")
                raise AssertionError("lock not enforced")
            except m.StateError as ex:
                assert "timed out" in str(ex)
        assert run(["hook", "user-prompt"], '{"session_id":"busy"}') == (0, "")
        rc, out = run(["statusline"], '{"session_id":"busy"}')
        assert rc == 0 and "Traceback" not in out and "busy" not in m.read_json(home / "sessions.json", {})
    finally:
        holder.kill(); holder.communicate(timeout=10)
    m.heartbeat("after-crash")
    assert "after-crash" in m.read_json(home / "sessions.json", {})

def launch_profiles():
    good(["profile", "set", "deepseek", "personal", "--key", "DUMMY_A", "--default"])
    good(["profile", "set", "deepseek", "work", "--key", "DUMMY_B"])
    out = good(["launch", "deepseek", "--dry-run", "--use", "deepseek=work"])
    assert "Lead: DeepSeek@work" in out and "bbbb" in out, out
    for name, message in (("off", "PROFILE_OFF"), ("missing", "PROFILE_ERROR")):
        rc, out = run(["launch", "deepseek", "--dry-run", "--use", "deepseek=" + name])
        assert rc != 0 and message in out, out
    out = good(["launch", "deepseek", "--dry-run", "--use", "deepseek=off", "--profile", "work"])
    assert "Lead: DeepSeek@work" in out
    good(["profile", "use", "claude", "off"])
    assert "Claude: only as an executor" in good(["launch", "deepseek", "--dry-run", "--use", "claude=default"])
    assert "Claude: off" in good(["launch", "deepseek", "--dry-run", "--use", "claude=default", "--no-claude"])
    assert "Lead: DeepSeek@work" in good(["launch", "deepseek", "--dry-run"], extra={"ORCH_PROFILES":"deepseek=work"})
    good(["profile", "use", "claude", "inherit"])

def worker_guard():
    hid = offered()
    before = meta(hid)
    for args in (["list"], ["show", hid], ["check"], ["wait", "--any"], ["done", hid], ["cancel", hid],
                 ["close", hid], ["take", hid], ["reclaim", hid], ["hold", hid], ["new", "--title", "x"], ["offer", "--title", "x"]):
        rc, out = run(["handoff"] + args, extra={"ORCH_WORKER":"review-worker"})
        assert rc != 0 and "only the orchestrator may use orch handoff" in out, (args, rc, out)
    assert meta(hid) == before
    assert run(["hook", "user-prompt"], extra={"ORCH_WORKER":"review-worker"}) == (0, "")
    clear_tasks()

fixed = m.now().replace(microsecond=0)
def snapshot(five=None, week=None, age=0):
    data = {"updated": m.iso(fixed - dt.timedelta(seconds=age)), "source":"operator"}
    if five is not None: data["five_hour"] = five
    if week is not None: data["seven_day"] = week
    m.write_json(m.USAGE_SNAPSHOT, data)
def window(used, hours, age=0):
    return {"used":used, "resets_at":m.iso(fixed + dt.timedelta(hours=hours)),
            "updated":m.iso(fixed - dt.timedelta(seconds=age))}

def stale_budget():
    snapshot(window(40, 4))
    with mock.patch.object(m, "now", return_value=fixed):
        snap = m.read_json(m.USAGE_SNAPSHOT, {})
        rate, _ = m.window_pace(snap, 40, m.parse_iso(snap["five_hour"]["resets_at"]), 5)
        assert m.claude_budget()[0] == "tight"
    with mock.patch.object(m, "now", return_value=fixed + dt.timedelta(hours=3)):
        assert m.window_pace(snap, 40, m.parse_iso(snap["five_hour"]["resets_at"]), 5)[0] == rate
        mode, line = m.claude_budget()
        assert mode == "tight" and "3h ago" in line and "stale" in line and "≈" not in line, line
    snapshot({"used":10, "resets_at":m.iso(fixed + dt.timedelta(hours=2))}, age=3600)
    assert m.claude_budget()[0] != "surplus"
    out = good(["statusline"], '{}')
    assert "stale:" in out and "surplus:" not in out
    snapshot(window(10, 2), {"used":40, "resets_at":m.iso(fixed + dt.timedelta(days=4))}, age=3600)
    old = m.read_json(m.USAGE_SNAPSHOT, {})["updated"]
    good(["budget", "set", "--used", "15", "--resets", "+2h"])
    assert m.read_json(m.USAGE_SNAPSHOT, {})["seven_day"]["updated"] == old

def weekly_budget():
    for five in (None, window(10, -1), window(10, 2)):
        snapshot(five, window(82, 24 * 1.7))
        mode, line = m.claude_budget()
        assert mode == "tight" and "weekly limit" in line and "108% projected" in line, line
    assert "tight: week 108% projected" in good(["statusline"], '{}')
    snapshot(None, {"used":95})
    assert m.claude_budget()[0] == "tight"
    snapshot(window(10, 2), window(15, 167))
    assert m.claude_budget()[0] == "surplus"   # an early projection is noise: it neither raises TIGHT nor blocks SURPLUS
    snapshot(window(10, 2), window(95, 167))
    assert m.claude_budget()[0] == "tight"     # used share is sufficient even on day one

def weekly_pace():
    # The effective weekly reserve shrinks with the time left and floors at 1 (0 stays 0).
    reset = fixed + dt.timedelta(days=7)
    assert m.week_reserve(10, reset, reset - dt.timedelta(days=7)) == 10
    assert abs(m.week_reserve(10, reset, reset - dt.timedelta(days=3.5)) - 5) < 1e-9
    assert abs(m.week_reserve(10, reset, reset - dt.timedelta(hours=31)) - 1.85) < 0.01
    assert m.week_reserve(10, reset, reset - dt.timedelta(hours=1)) == 1
    assert m.week_reserve(0, reset, reset - dt.timedelta(days=7)) == 0
    assert m.week_reserve_text(10, 10) == "10%"
    assert m.week_reserve_text(10, 1.85) == "2% (10% at the start of the week)"

    # week_history sampling: at most one per 15 min, kept for 80 h, capped at 400, malformed entries dropped.
    t0 = fixed
    hist = m.week_history_update([], {"used": 80.0, "resets_at": m.iso(reset)}, t0)
    hist = m.week_history_update(hist, {"used": 81.0, "resets_at": m.iso(reset)}, t0 + dt.timedelta(minutes=5))
    assert len(hist) == 1                    # a change within 15 min adds no second sample
    hist = m.week_history_update(hist, {"used": 82.0, "resets_at": m.iso(reset)}, t0 + dt.timedelta(minutes=20))
    assert len(hist) == 2                    # past the gap a change adds a sample
    hist = m.week_history_update([["garbage", 80.0, m.iso(reset)]], {"used": 90.0, "resets_at": m.iso(reset)},
                                 t0 + dt.timedelta(hours=1))
    assert len(hist) == 1 and hist[0][1] == 90.0      # the malformed entry is skipped, never fatal
    many = [[m.iso(t0 + dt.timedelta(minutes=5 * i)), 1.0, m.iso(reset)] for i in range(450)]
    assert len(m.week_history_update(many, None, t0 + dt.timedelta(hours=72))) == 400   # the cap
    # a sample about 72 h old must survive the 80 h retention; one past it is dropped
    three_days = [[m.iso(t0 - dt.timedelta(hours=78)), 1.0, m.iso(reset)]]
    assert len(m.week_history_update(three_days, None, t0)) == 1
    assert m.week_history_update([[m.iso(t0 - dt.timedelta(hours=82)), 1.0, m.iso(reset)]], None, t0) == []

    # The weekly base sample: earliest within 72 h (three days), same reset (10 min), at least 6 h before the
    # measurement.
    hist8 = [[m.iso(fixed - dt.timedelta(hours=8)), 82.0, m.iso(reset)]]
    assert m.week_base_sample(hist8, reset, fixed) == (fixed - dt.timedelta(hours=8), 82.0)
    old = reset - dt.timedelta(days=7)                 # a sample from the previous week
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=8)), 50.0, m.iso(old)]], reset, fixed) is None
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=5)), 82.0, m.iso(reset)]], reset, fixed) is None
    rw = fixed + dt.timedelta(hours=24)                 # a week with 24 h still to its reset
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=75)), 82.0, m.iso(rw)]], rw, fixed) is None
    # three days back is the point: the earliest within 72 h wins over a nearer sample
    mixed = [[m.iso(fixed - dt.timedelta(hours=60)), 60.0, m.iso(rw)],
             [m.iso(fixed - dt.timedelta(hours=20)), 70.0, m.iso(rw)]]
    assert m.week_base_sample(mixed, rw, fixed) == (fixed - dt.timedelta(hours=60), 60.0)
    rate, basis = m.week_rate(mixed, 80.0, rw, fixed)
    assert basis == "the last 2d 12h" and abs(rate - 20.0 / 3600) < 1e-12, (rate, basis)
    # After the window, the newest older sample with the same reset stands in for a flat week: zero pace,
    # basis "the last 3 d" — only while the used value is unchanged (a change means the recent pace is unknown).
    rr2 = fixed + dt.timedelta(hours=48)
    idle = [[m.iso(fixed - dt.timedelta(hours=75)), 70.0, m.iso(rr2)]]
    assert m.week_base_sample(idle, rr2, fixed, 70.0) == (fixed - dt.timedelta(hours=72), 70.0)
    assert m.week_base_sample(idle, rr2, fixed, 71.0) is None
    rate, basis = m.week_rate(idle, 70.0, rr2, fixed)
    assert basis == "the last 3 d" and rate == 0.0, (rate, basis)
    assert m.week_recent_basis(3 * 24 * 60) == "the last 3 d"
    assert m.week_recent_basis(8 * 60) == "the last 8 h"
    assert m.week_recent_basis(6 * 60 + 30) == "the last 6h 30m"

    def week_snap(used, hours_left, hist=None):
        r = fixed + dt.timedelta(hours=hours_left)
        data = {"updated": m.iso(fixed), "source": "test",
                "seven_day": {"used": used, "resets_at": m.iso(r), "updated": m.iso(fixed)}}
        if hist is not None:
            data["week_history"] = hist
        m.write_json(m.USAGE_SNAPSHOT, data)

    # Real case: 84% used, 31 h to the reset, 82% 8 h ago → the recent pace says ~91%, not TIGHT.
    rr = fixed + dt.timedelta(hours=31)
    real_hist = [[m.iso(fixed - dt.timedelta(hours=8)), 82.0, m.iso(rr)]]
    week_snap(84, 31, real_hist)
    rate, basis = m.week_rate(real_hist, 84, rr, fixed)
    assert basis == "the last 8 h", basis
    assert abs(m.projected_at_reset(84, rr, rate, fixed) - 91.75) < 0.01
    assert m.claude_budget()[0] != "tight"
    # No history: the same numbers fall back to the window average → 103% projected → TIGHT.
    week_snap(84, 31)
    mode, line = m.claude_budget()
    assert mode == "tight" and "103% projected from the week's average" in line and "weekly limit is tight" in line, line
    # A real burn stays TIGHT: 10 points in 8 h with 60 h left.
    week_snap(30, 60, [[m.iso(fixed - dt.timedelta(hours=8)), 20.0, m.iso(fixed + dt.timedelta(hours=60))]])
    mode, line = m.claude_budget()
    assert mode == "tight" and "projected from the last 8 h" in line, line
    # The reserve: 90% with 6 days left is TIGHT; 92% with 5 h left and no recent use isn't.
    week_snap(90, 24 * 6)
    assert m.claude_budget()[0] == "tight"
    week_snap(92, 5)
    assert m.claude_budget()[0] != "tight"
    week_snap(99.5, 1)
    assert m.claude_budget()[0] == "tight"           # the 1-point floor keeps the last hour guarded
    # A week_reserve of 0 is TIGHT only at 100%.
    with mock.patch.object(m, "budget_settings", return_value={"surplus": 30, "reserve": 10, "week_reserve": 0}):
        week_snap(99, 1)
        assert m.claude_budget()[0] != "tight"
        week_snap(100, 1)
        assert m.claude_budget()[0] == "tight"
    # The surplus gate reads the effective weekly reserve, not the flat setting: with week_reserve=20 but the
    # reserve shrunk to eff=10, a 80% weekly projection still allows surplus (the flat 20 would block at 100-20=80).
    burn = [[m.iso(fixed - dt.timedelta(hours=8)), 40.0, m.iso(fixed + dt.timedelta(hours=24))]]
    m.write_json(m.USAGE_SNAPSHOT, {"updated": m.iso(fixed), "source": "test",
                                    "five_hour": window(10, 2), "seven_day": window(50, 24), "week_history": burn})
    with mock.patch.object(m, "budget_settings",
                           return_value={"surplus": 40, "reserve": 10, "week_reserve": 20}), \
         mock.patch.object(m, "week_reserve", return_value=10.0), \
         mock.patch.object(m, "now", return_value=fixed):
        mode, line = m.claude_budget()
        assert mode == "surplus", (mode, line)

def codex_weekly():
    cx = root / "cx-week"
    d = cx / "sessions" / "2026" / "11" / "02"
    d.mkdir(parents=True)
    def ev(used5, r5h, used7, r7h, t):
        return json.dumps({"timestamp": t.astimezone(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex",
            "primary": {"used_percent": used5, "window_minutes": 300, "resets_at": int((t + dt.timedelta(hours=r5h)).timestamp())},
            "secondary": {"used_percent": used7, "window_minutes": 10080, "resets_at": int((t + dt.timedelta(hours=r7h)).timestamp())},
            "credits": {"has_credits": False}, "plan_type": "plus"}}})
    f = d / "rollout-0001.jsonl"
    f.write_text(ev(10, 2, 84, 31, fixed) + "\n", encoding="utf-8")
    with mock.patch.dict(os.environ, {"CODEX_HOME": str(cx)}):
        m.refresh_codex(force=True)
        entry = m.read_json(m.CODEX_USAGE_FILE, {})[str(cx)]
        assert len(entry.get("week_history") or []) == 1      # the series is in the cached entry
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, entry) == "tight: week 103% projected"
        m.refresh_codex(force=True)
        entry = m.read_json(m.CODEX_USAGE_FILE, {})[str(cx)]
        assert len(entry.get("week_history") or []) == 1      # an unchanged measurement adds no sample
        # the same weekly cases as Claude, straight through the compact text
        def ce(used, hours_left, hist=None):
            r = fixed + dt.timedelta(hours=hours_left)
            e = {"seven_day": {"used": used, "resets_at": m.iso(r), "measured": m.iso(fixed)}}
            if hist is not None:
                e["week_history"] = hist
            return e
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10},
                                  ce(84, 31, [[m.iso(fixed - dt.timedelta(hours=8)), 82.0,
                                               m.iso(fixed + dt.timedelta(hours=31))]])) is None
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, ce(84, 31)) == "tight: week 103% projected"
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10},
                                  ce(30, 60, [[m.iso(fixed - dt.timedelta(hours=8)), 20.0,
                                               m.iso(fixed + dt.timedelta(hours=60))]])) == "tight: week 105% projected"
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, ce(92, 5)) is None
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, ce(99.5, 1)) == "tight: week over reserve"
        # a new weekly measurement adds a sample
        f.write_text(ev(10, 2, 86, 30, fixed + dt.timedelta(hours=1)) + "\n", encoding="utf-8")
        m.refresh_codex(force=True)
        entry = m.read_json(m.CODEX_USAGE_FILE, {})[str(cx)]
        assert len(entry.get("week_history") or []) == 2
        assert m.codex_budget()[0] == "tight"

def hard_cap():
    good(["profile", "set", "antigravity", "zero", "--max-open", "0", "--default"])
    rc, out = run(["handoff", "new", "--title", "cap", "--force"])
    assert rc == 75 and "profile limit 0" in out and "--force" not in out, out
    hid = offered()
    rc, out = run(["handoff", "take", hid, "--force"])
    assert rc == 75 and "--force" not in out and m.result_status(meta(hid)) == "OFFERED", out
    good(["profile", "use", "antigravity", "inherit", "--default"])
    good(["handoff", "take", hid, "--max-open", "0", "--force"])
    clear_tasks()

def existing_result():
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "ready"])).group()
    Path(m.load_meta(hid)["result_path"]).write_text("STATUS: DONE\nfinished\n", encoding="utf-8")
    assert "STATUS DONE" in good(["handoff", "wait", "--any", "--timeout", "1s"])
    assert "No manual tasks" in good(["handoff", "wait", "--any", "--timeout", "1s"])
    clear_tasks()

def overdue_activity():
    # a task in the project folder shares it with other work: a changed file starts nothing
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "shared"])).group()
    task = meta(hid)
    task.update(created=m.iso(fixed - dt.timedelta(hours=8)), taken=m.iso(fixed - dt.timedelta(hours=8)))
    m.save_meta(task)
    (proj / "app.txt").write_text("someone else\n", encoding="utf-8")
    with mock.patch.object(m, "scan_latest_mtime", side_effect=AssertionError("a shared folder was scanned")):
        assert m.last_activity(m.load_meta(hid)) is None and m.effective_state(m.load_meta(hid)) == "WAITING"
    assert not any("in progress" in e and hid in e for e in m.check_events()), "a shared edit counted as activity"
    subprocess.run(["git", "checkout", "--", "app.txt"], cwd=str(proj), check=True)
    clear_tasks()
    # an older task has a worktree of its own: the folder scan stays for it
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "activity"])).group()
    task = meta(hid)
    task.update(created=m.iso(fixed - dt.timedelta(hours=8)), taken=m.iso(fixed - dt.timedelta(hours=8)), branch="ag/older")
    task.pop("activity_baseline", None)
    m.save_meta(task)
    (proj / "app.txt").write_text("activity\n", encoding="utf-8")
    with mock.patch.object(m, "scan_latest_mtime", side_effect=AssertionError("fast check scanned workdir")):
        assert not m.check_events(fast=True)
    with mock.patch.object(m, "last_activity", wraps=m.last_activity) as activity:
        events = m.check_events()
        assert activity.call_count == 1
    assert any("in progress" in e and hid in e for e in events), events
    assert not m.check_events()
    clear_tasks()

def token_hygiene():
    out = good(["launch", "deepseek", "--dry-run"], extra={"CLAUDE_CODE_OAUTH_TOKEN":"sensitive"})
    assert any("CLAUDE_CODE_OAUTH_TOKEN" in l for l in out.splitlines() if l.startswith("Dropped")), out
    good(["run", "claude", "--model", "haiku", "review"], extra={"FAKE_CLAUDE":"ok", "ORCH_LEAD":"deepseek",
         "ORCH_LEAD_ENV":"ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN":"lead-secret", "CLAUDE_CODE_OAUTH_TOKEN":"sensitive"})
    record = json.loads(Path(env["FAKE_CLAUDE_LOG"]).read_text(encoding="utf-8"))
    assert not record["env"].get("CLAUDE_CODE_OAUTH_TOKEN") and not record["env"].get("ANTHROPIC_AUTH_TOKEN")

def run_outcomes():
    for status in ("BLOCKED", "PARTIAL"):
        out = good(["run", "codex", "--model", "review-model", "review"], extra={"FAKE_CODEX":status.lower()})
        assert "[" + status + "]" in out, out
        entries = [x for x in m.ledger_read() if x.get("kind") == "run"]
        assert entries[-1]["status"] == status
        assert status in good(["usage"])
    rc, out = run(["run", "codex", "--model", "capacity-model", "review"], extra={"FAKE_CODEX":"capacity"})
    assert rc == 75 and "CAPACITY" in out, out
    entries = m.read_json(m.AVAIL_FILE, {})["entries"]
    assert set(entries) == {"codex/capacity-model"}, entries
    assert entries["codex/capacity-model"]["status"] == "busy"
    until = m.parse_iso(entries["codex/capacity-model"]["until"])     # checked at once: the runs below take time
    assert 9 * 60 < (until - m.now()).total_seconds() <= 10 * 60, (until, m.now())
    assert "CAPACITY" in run(["run", "codex", "--model", "capacity-model", "review"])[1]
    assert "CAPACITY" in good(["usage"])
    # capacity with an unknown model id: no --model and no model in the codex config → no block is recorded
    before = m.read_json(m.AVAIL_FILE, {})["entries"]
    rc, out = run(["run", "codex", "review"], extra={"FAKE_CODEX": "capacity"})
    assert rc == 75 and "CAPACITY" in out and "no availability block was recorded" in out, out
    assert m.read_json(m.AVAIL_FILE, {})["entries"] == before, out
    rc, out = run(["run", "codex", "--model", "trace-model", "review"], extra={"FAKE_CODEX":"trace_fail"})
    assert rc != 75 and "[FAILED]" in out, out
    assert set(m.read_json(m.AVAIL_FILE, {})["entries"]) == {"codex/capacity-model"}
    rc, out = run(["run", "codex", "--model", "trace-model", "review"], extra={"FAKE_CODEX":"trace_limit"})
    assert rc == 75 and "[QUOTA_EXHAUSTED]" in out, out
    assert "subscription limit: You've hit your usage limit" in out, out
    assert all("cloud-quotas" not in line for line in out.splitlines() if "subscription limit:" in line), out
    assert m.read_json(m.AVAIL_FILE, {})["entries"]["codex"]["status"] == "exhausted"
    good(["quota", "clear", "codex"])
    rc, out = run(["run", "codex", "--model", "trace-model", "review"], extra={"FAKE_CODEX":"trace_only_limit"})
    assert rc == 75 and "[QUOTA_EXHAUSTED]" in out, out
    good(["quota", "clear", "codex"])
    assert run(["quota", "check", "codex/sibling"])[0] == 0
    assert run(["run", "codex", "--model", "sibling", "review"], extra={"FAKE_CODEX":"fail"})[0] == 3
    notes = (Path(orch).parent.parent / "registry/providers.yaml").read_text(encoding="utf-8")
    assert "ORCH_CODEX_EXTRA_ARGS" in notes and "TMPDIR" in notes and "C:/Users/Public/" in notes

def run_cost_fallback():
    # A corrupt personal price table must not lose the ledger line: keep the tokens, price 0, and say so.
    (home / "prices.json").write_text(json.dumps(
        {"usd_per_1m_tokens": {"pricing-model": {"input": "not-a-number"}}}), encoding="utf-8")
    try:
        out = good(["run", "codex", "--model", "pricing-model", "review"], extra={"FAKE_CODEX": "ok"})
        assert "cost not priced" in out, out
        rec = [x for x in m.ledger_read() if x.get("kind") == "run"][-1]
        assert rec["usage"]["input_tokens"] == 200 and rec["cost_usd"] == 0.0, rec
    finally:
        (home / "prices.json").unlink()

def corruption_recovery():
    hid = offered()
    broken = m.handoffs_root() / "BAD" / "meta.json"
    broken.parent.mkdir(exist_ok=True)
    for raw in ("{", "[1]"):
        broken.write_text(raw, encoding="utf-8")
        for args in (["status"], ["handoff", "list"], ["handoff", "offer", "--title", "other"]):
            rc, out = run(args)
            assert rc == 0 and "meta.json" in out and "Traceback" not in out, out
        assert run(["handoff", "take", "BAD"])[0] == 1
    broken.unlink()
    for path, args in ((m.USAGE_SNAPSHOT, ["budget"]), (m.SESSIONS_FILE, ["budget"]),
                       (m.handoffs_root() / ".pool.json", ["status"]),
                       (m.handoffs_root() / "counter.json", ["handoff", "offer", "--title", "counter"])):
        if path == m.SESSIONS_FILE:
            m.write_json(m.USAGE_SNAPSHOT, {"five_hour": {"used": 10, "resets_at": m.iso(m.now() + dt.timedelta(hours=1))}})
        path.write_text("[1]", encoding="utf-8")
        rc, out = run(args)
        assert rc == 0 and str(path) in out and Path(str(path) + ".corrupt").exists(), out
    m.AVAIL_FILE.write_text("{", encoding="utf-8")
    assert run(["status"])[0] == 0 and run(["handoff", "offer", "--title", "available"])[0] == 0
    for args in (["quota", "set", "codex", "exhausted"], ["quota", "clear", "codex"]):
        rc, out = run(args)
        assert rc == 1 and "availability.json" in out and m.AVAIL_FILE.read_text() == "{", out
    m.AVAIL_FILE.unlink()
    saved_profiles = m.PROFILES_FILE.read_bytes() if m.PROFILES_FILE.exists() else None
    m.PROFILES_FILE.write_text("[1]", encoding="utf-8")
    for args in (["status"], ["budget"]):
        rc, out = run(args)
        assert rc == 0 and "profiles.json" in out and "Traceback" not in out, out
    assert run(["handoff", "offer", "--title", "refused"])[0] == 1
    if saved_profiles is None: m.PROFILES_FILE.unlink()
    else: m.PROFILES_FILE.write_bytes(saved_profiles)
    original = m.USAGE_SNAPSHOT.read_bytes()
    with mock.patch.object(m.Path, "read_text", side_effect=PermissionError("busy")), mock.patch.object(m.time, "sleep"):
        try:
            m.read_json(m.USAGE_SNAPSHOT, {}, recover_corrupt=True)
            raise AssertionError("permission error treated as corruption")
        except m.StateError:
            pass
    assert m.USAGE_SNAPSHOT.read_bytes() == original
    clear_tasks()

def assignment_recovery():
    hid = offered()
    task = meta(hid)
    task.update(taken=m.iso(m.now() - dt.timedelta(minutes=11)), assigning="old-token")
    m.save_meta(task)
    old = dict(task)
    assert not any(hid in e for e in m.check_events(fast=True))
    events = m.check_events()
    assert sum(hid in e and "returned to the pool" in e for e in events) == 1, events
    assert m.result_status(meta(hid)) == "OFFERED" and not meta(hid).get("assigning")
    with mock.patch.object(m, "assign_handoff", return_value=old):
        try:
            m.materialize_handoff(old, None)
            raise AssertionError("late finisher accepted")
        except SystemExit:
            pass
    good(["handoff", "take", hid])
    assert meta(hid)["branch"] is None and Path(m.load_meta(hid)["workdir"]) == proj, meta(hid)
    clear_tasks()
    hid = offered(write=True)
    task = meta(hid)
    task.update(taken=m.iso(m.now() - dt.timedelta(minutes=11)), assigning="old-token")
    m.save_meta(task)
    assert any(hid in e and "returned to the pool" in e for e in m.check_events())
    branch = "ag/" + hid.lower()
    subprocess.run(["git", "branch", branch], cwd=str(proj), check=True)     # the branch is left from the first try
    good(["handoff", "take", hid])
    assert meta(hid)["branch"] == branch and meta(hid)["workdir"] == ".orchestra/wt/" + hid, meta(hid)
    clear_tasks()
    hid = offered()
    task = meta(hid); task.update(offered=None, taken=m.iso(m.now()), assigning="failure")
    m.save_meta(task)
    with mock.patch.object(m, "assign_handoff", side_effect=RuntimeError("test failure")):
        try:
            m.materialize_handoff(task, None)
            raise AssertionError("failure swallowed")
        except RuntimeError:
            pass
    task = meta(hid)
    assert task["manual_status"] == "CANCELLED" and task["archived"] and "test failure" in task["manual_note"]
    hid = offered(); task = meta(hid)
    task.update(offered=None, taken=m.iso(m.now() - dt.timedelta(minutes=11)), assigning="stale")
    m.save_meta(task); assert any(hid in e and "cancelled" in e for e in m.check_events())
    assert meta(hid)["manual_status"] == "CANCELLED" and meta(hid)["archived"]
    hid = offered(); task = meta(hid); task.update(taken=m.iso(m.now()), assigning="failure")
    m.save_meta(task)
    with mock.patch.object(m, "assign_handoff", side_effect=RuntimeError("test")):
        try: m.materialize_handoff(task, None)
        except RuntimeError: pass
    assert m.result_status(meta(hid)) == "OFFERED"
    clear_tasks()

def report_reclaimed():
    for mode, expected in (("preamble", "BLOCKED"), ("first_done", "OK"), ("partial", "PARTIAL")):
        hid = offered()
        good(["handoff", "reclaim", hid, "--next"])
        out = good(["run", "codex", "--handoff", hid, "review"], extra={"FAKE_CODEX":mode})
        assert "[" + expected + "]" in out, out
        if expected != "OK":
            assert "slot stays busy" in out and not meta(hid)["reclaim"]["finished"], out
            good(["handoff", "done", hid])
        assert meta(hid)["reclaim"]["finished"]
    clear_tasks()

def meta_paths():
    proj_str = str(proj.resolve())
    base = m.meta_base(m.handoffs_root() / "X-0001" / "meta.json")
    assert Path(str(base)) == Path(proj_str), (base, proj_str)
    # meta_base is pure path arithmetic: it never calls .resolve(), so a symlinked .orchestra can't redirect the
    # project, and the result does not depend on the cwd.
    fake = m.handoffs_root() / "X-9999" / "meta.json"
    with mock.patch.object(m.Path, "resolve", side_effect=AssertionError("meta_base resolved the path")):
        assert Path(str(m.meta_base(fake))) == Path(proj_str)
    # relative → absolute in memory, absolute → relative on save (round-trip)
    assert Path(m.abs_path(".orchestra/handoffs/X-0001/RESULT.md", base)) == proj / ".orchestra/handoffs/X-0001/RESULT.md"
    assert Path(m.abs_path(".", base)) == Path(proj_str)
    assert Path(m.abs_path("../proj.wt/X-0001", base)) == Path(proj_str).parent / "proj.wt" / "X-0001"
    assert m.rel_path(proj_str, base) == "."
    assert m.rel_path(str(Path(proj_str).parent / "proj.wt" / "X-0001"), base) == "../proj.wt/X-0001"
    # a path of the other OS is kept verbatim: no cross-OS guessing
    assert m.abs_path("C:\\Users\\Me\\Proj", base) == "C:\\Users\\Me\\Proj"
    assert m.abs_path("/mnt/c/Users/Me/Proj", base) == "/mnt/c/Users/Me/Proj"
    assert m.rel_path("D:\\Users\\me\\x", base) == "D:/Users/me/x"
    # no relative form (a different drive on Windows) → stay absolute
    with mock.patch.object(m.os.path, "relpath", side_effect=ValueError("different drive")):
        assert m.rel_path(str(Path(proj_str) / "x"), base) == str(Path(proj_str) / "x").replace("\\", "/")
    # a real task: on-disk relative, in-memory absolute, the card prints the full path
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "paths"])).group()
    raw = meta(hid)
    assert raw["workdir"] == "." and raw["task_path"].startswith(".orchestra/handoffs/"), raw
    task = m.load_meta(hid)
    assert Path(task["workdir"]) == Path(proj_str), task
    assert Path(task["result_path"]) == proj / ".orchestra/handoffs" / hid / "RESULT.md", task
    assert task["workdir"] in good(["handoff", "show", hid])
    # an old meta with absolute paths loads, works, and becomes relative after a save
    old = dict(raw)
    for f in ("workdir", "task_path", "result_path"):
        old[f] = str(Path(task[f]))
    m.write_json(m.handoffs_root() / hid / "meta.json", old)
    assert Path(m.load_meta(hid)["workdir"]) == Path(proj_str)
    m.save_meta(m.load_meta(hid))
    after = meta(hid)
    assert after["workdir"] == "." and after["task_path"].startswith(".orchestra/handoffs/"), after
    clear_tasks()

def spend_limits():
    peak = dt.datetime(2026, 11, 2, 2, 0, tzinfo=dt.timezone.utc)       # Monday 02:00 UTC — DeepSeek peak
    offpeak = dt.datetime(2026, 11, 2, 12, 0, tzinfo=dt.timezone.utc)   # Monday 12:00 UTC — off-peak
    u = {"input_tokens": 1_000_000, "cached_input_tokens": 0, "output_tokens": 0}

    # prices: claude alias and codex prefix matching, default fallback
    assert m.price_for("claude-sonnet-5-5-2026", "claude")["output"] == 10.0
    assert m.price_for("gpt-6.1-terra-something", "codex")["input"] == 1.0
    d = m.price_for("no-such-model", "deepseek")
    assert d["input"] == 3.0 and d["output"] == 15.0
    # DeepSeek peak vs off-peak (off_peak_multiplier 0.5 outside the weekday UTC windows)
    assert m.price_for("deepseek-v4-pro", "deepseek", peak)["input"] == 1.32
    assert m.price_for("deepseek-v4-pro", "deepseek", offpeak)["input"] == 0.66
    assert m.price_for("deepseek-v4-pro", "deepseek", offpeak)["output"] == 1.98
    assert abs(m.usage_cost(u, "deepseek", "deepseek-v4-pro", peak) - 1.32) < 1e-9
    assert abs(m.usage_cost(u, "deepseek", "deepseek-v4-pro", offpeak) - 0.66) < 1e-9
    # a dated price (gpt-6-astra): cheaper before the promo ends, higher after
    assert m.price_for("gpt-6-astra", "codex", dt.datetime(2026, 10, 15, tzinfo=dt.timezone.utc))["input"] == 5.0
    assert m.price_for("gpt-6-astra", "codex", dt.datetime(2026, 11, 5, tzinfo=dt.timezone.utc))["input"] == 10.0
    # a personal ~/.orchestra/prices.json overrides per model, leaves the rest alone
    (home / "prices.json").write_text(json.dumps(
        {"usd_per_1m_tokens": {"deepseek-v4-pro": {"input": 1.0, "cache_read": 0.1, "output": 2.0}}}), encoding="utf-8")
    assert m.price_for("deepseek-v4-pro", "deepseek", peak)["input"] == 1.0
    assert m.price_for("deepseek-flash", "deepseek", peak)["input"] == 0.30
    (home / "prices.json").unlink()
    # staleness: prices older than 30 days warn and name the source; a fresh list doesn't
    with mock.patch.object(m, "now", return_value=dt.datetime(2026, 11, 2, tzinfo=dt.timezone.utc)):
        assert m.price_staleness("deepseek") is None
    with mock.patch.object(m, "now", return_value=dt.datetime(2027, 1, 15, tzinfo=dt.timezone.utc)):
        assert "api-docs.deepseek.com" in m.price_staleness("deepseek")

    # cost_usd is frozen in the ledger and preferred over the table; sessions freeze spend_usd
    assert abs(m._run_cost({"kind": "run", "provider": "codex", "model": "gpt-6.1-terra", "usage": u}) - 1.0) < 1e-9
    assert m._run_cost({"kind": "run", "provider": "codex", "model": "gpt-6.1-terra", "usage": u, "cost_usd": 0.5}) == 0.5
    assert m._session_cost({"kind": "session", "lead": "deepseek", "spend_usd": 0.75, "rows": []}) == 0.75

    # counter key and effective settings: project → global → defaults
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg = m.load_spend_limits()[0]
    canon = m.canon_path(proj)
    cfg["projects"][canon] = {"deepseek": {"limit": 5}}
    assert m.counter_key(cfg, "deepseek", canon)[0] == canon
    assert m.counter_key(cfg, "deepseek", canon + "/sub")[0] == canon
    assert m.counter_key(cfg, "codex", canon)[0] == "global"
    eff = m.resolve_spend(cfg, "deepseek", proj)
    assert eff["limit"] == 5 and eff["mode"] == "evaluate" and eff["lead_mode"] == "continue"
    assert m.spend_kill_at({"limit": 10, "mode": "stop"}) == 10
    assert m.spend_kill_at({"limit": 10, "mode": "evaluate", "overrun": 20}) == 12
    assert m.spend_kill_at({"limit": 10, "mode": "continue"}) is None

    # reset kinds: a key scope is manual, a keyless one is month; --reset overrides both ways
    assert m.scope_has_key("deepseek", proj) is True
    assert m.scope_has_key("codex", proj) is False
    assert m.resolve_reset(cfg, "deepseek", proj) == "manual"
    assert m.resolve_reset(cfg, "codex", proj) == "month"
    cfg["global"]["deepseek"] = {"reset": "month"}
    cfg["global"]["codex"] = {"reset": "manual"}
    assert m.resolve_reset(cfg, "deepseek", proj) == "month"
    assert m.resolve_reset(cfg, "codex", proj) == "manual"
    # each message names the right way out per kind
    assert "orch spend reset codex" in m._way_out(cfg, "codex", proj)          # manual → top up and reset
    assert "orch spend limit deepseek" in m._way_out(cfg, "deepseek", proj)    # month → raise or wait

    # baselines: a manual scope never rolls over, a month scope does
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    t0 = dt.datetime(2026, 11, 15, 12, 0, tzinfo=dt.timezone.utc)
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    cfg["global"]["codex"] = {"limit": 10}
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0):
        assert m.ensure_baseline("deepseek", proj) == t0    # first seen: the baseline is written now
    def mk(label, cost, ts):
        return {"label": label, "project": canon, "cost": cost, "ts": m.iso(ts)}
    manual = [mk("deepseek", 2.0, t0 + dt.timedelta(hours=1))]
    month = [mk("codex", 3.0, t0 + dt.timedelta(hours=1))]
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=2)):
        assert abs(m.current_spend("deepseek", proj, manual) - 2.0) < 1e-9
        assert abs(m.current_spend("codex", proj, month) - 3.0) < 1e-9
    later = t0 + dt.timedelta(days=40)                      # the next calendar month
    with mock.patch.object(m, "now", return_value=later):
        assert abs(m.current_spend("deepseek", proj, manual) - 2.0) < 1e-9   # manual: never rolls over
        assert m.current_spend("codex", proj, month) == 0.0                  # month: cleared

    # a first-seen manual scope ignores spending from before it was seen; a reset zeroes it at once
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0):
        m.ensure_baseline("deepseek", proj)                 # first seen at t0
    old = [mk("deepseek", 5.0, t0 - dt.timedelta(days=1)), mk("deepseek", 2.0, t0 + dt.timedelta(hours=1))]
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=2)):
        assert abs(m.current_spend("deepseek", proj, old) - 2.0) < 1e-9   # the pre-baseline entry is ignored
    cfg, _ = m.load_spend_limits()                          # a reset moves the baseline to now
    m._baseline_section(cfg, "global")["deepseek"] = (t0 + dt.timedelta(hours=3)).isoformat()
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=4)):
        assert m.current_spend("deepseek", proj, old) == 0.0                # reset zeroes the counter at once

    # within one second: what ended just before a baseline stays out, what ended just after counts
    base = t0.replace(microsecond=0) + dt.timedelta(hours=5, microseconds=500000)
    cfg, _ = m.load_spend_limits()
    m._baseline_section(cfg, "global")["deepseek"] = m.iso_precise(base)
    m.save_spend_limits(cfg)
    same_second = [{"label": "deepseek", "project": canon, "cost": 4.0,
                    "ts": m.iso_precise(base - dt.timedelta(microseconds=400000))},
                   {"label": "deepseek", "project": canon, "cost": 1.0,
                    "ts": m.iso_precise(base + dt.timedelta(microseconds=1000))}]
    with mock.patch.object(m, "now", return_value=base + dt.timedelta(hours=1)):
        assert abs(m.current_spend("deepseek", proj, same_second) - 1.0) < 1e-9
    usage_file = home / "usage.jsonl"
    usage_file.unlink() if usage_file.exists() else None
    m.ledger_append({"kind": "probe"})                      # the real writer keeps that resolution
    assert "." in json.loads(usage_file.read_text(encoding="utf-8").splitlines()[-1])["ts"]

    # the cache builds incrementally and restarts on a shrunken ledger (records keep ts, so resets apply at read time)
    for p in (home / "spend_cache.json", home / "spend_limits.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["codex"] = {"limit": 10}                  # a month scope needs no baseline
    m.save_spend_limits(cfg)
    def led(label, tokens, ts):
        return json.dumps({"kind": "run", "provider": "codex", "label": label, "model": "gpt-6.1-terra",
                           "billing": "api", "project": canon,
                           "usage": {"input_tokens": tokens, "cached_input_tokens": 0, "output_tokens": 0},
                           "ts": m.iso(ts)}, separators=(",", ":"))
    ledger = home / "usage.jsonl"
    fixed2 = dt.datetime(2026, 11, 15, 12, 0, tzinfo=dt.timezone.utc)
    ledger.write_text(led("codex", 1_000_000, fixed2) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=fixed2):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("codex", proj, records) - 1.0) < 1e-9
        cache = m.read_json(home / "spend_cache.json", {})
        assert cache["format"] == 4 and cache["offset"] > 0 and len(cache["records"]) == 1
    with open(ledger, "a", encoding="utf-8") as f:          # appending reads only the new bytes
        f.write(led("codex", 500_000, fixed2) + "\n")
    with mock.patch.object(m, "now", return_value=fixed2):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("codex", proj, records) - 1.5) < 1e-9
    ledger.write_text(led("codex", 250_000, fixed2) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=fixed2):  # a shrunken ledger recomputes from zero
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("codex", proj, records) - 0.25) < 1e-9

    # a corrupt limits file fails closed: spend_start refuses with a line naming the file
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    (home / "spend_limits.json").write_text("{broken", encoding="utf-8")
    allowed, line = m.spend_start("deepseek", proj)
    assert allowed is False and "unreadable" in line, line
    (home / "spend_limits.json").unlink()

    # limits reject nan / inf / negative amounts (parse_limit)
    for bad_value in ("nan", "inf", "-inf", "-1"):
        try:
            m.parse_limit(bad_value)
            raise AssertionError("parse_limit accepted %r" % bad_value)
        except SystemExit:
            pass
    assert m.parse_limit("off") is None and m.parse_limit("5") == 5.0

    # display_name: a trailing [bracket] variant is stripped; an unknown model version stays as-is
    assert m.display_name("deepseek-v4-pro[1m]") == "DeepSeek V4 Pro"
    assert m.display_name("claude-opus-5-5-2026") == "Claude Opus 5.5"
    assert m.display_name("gpt-6.1-terra-something") == "GPT-6.1 Terra"
    assert m.display_name("claude-opus-6-0") == "claude-opus-6-0"
    assert m.display_name("deepseek-v4-pro") == "DeepSeek V4 Pro"

    # valid_scope: lowercased, and provider@profile must name a real profile (not the built-in "default")
    good(["profile", "set", "deepseek", "work", "--key", "DUMMY_A"])
    assert m.valid_scope("DEEPSEEK") is True and m.valid_scope("deepseek") is True
    assert m.valid_scope("deepseek@work") is True
    assert m.valid_scope("deepseek@default") is False       # "default" isn't a real profile → refused
    assert m.valid_scope("deepseek@nope") is False and m.valid_scope("nosuch@work") is False
    good(["profile", "set", "deepseek", "default", "--key", "DUMMY_B"])
    assert m.valid_scope("deepseek@default") is True        # a profile literally named "default" is a valid scope
    (home / "profiles.json").unlink()

    # session snapshots are deduplicated: two snapshots of one session count only the last
    for p in (home / "spend_cache.json", home / "spend_limits.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0):
        m.ensure_baseline("deepseek", proj)
    def sess(sid, usd, ts):
        return json.dumps({"kind": "session", "lead": "deepseek", "project": canon,
                           "spend_usd": usd, "session": sid, "ts": m.iso(ts)}, separators=(",", ":"))
    ledger = home / "usage.jsonl"
    ledger.write_text(sess("s1", 1.0, t0 + dt.timedelta(hours=1)) + "\n" +
                      sess("s1", 4.0, t0 + dt.timedelta(hours=2)) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=3)):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("deepseek", proj, records) - 4.0) < 1e-9   # only the last snapshot counts

    # a lead session recorded in parts: a counter reset or a month start inside it leaves the earlier parts out
    H1 = dt.timedelta(hours=1)
    def sess_parts(sid, ts, parts, lead="deepseek"):
        return json.dumps({"kind": "session", "lead": lead, "project": canon, "session": sid, "ts": m.iso_precise(ts),
                           "spend_usd": sum(c for _, c in parts),
                           "spend_parts": [{"until": m.iso_precise(u), "spend_usd": c} for u, c in parts]},
                          separators=(",", ":"))
    def clean_spend_state():
        for p in (home / "spend_cache.json", home / "spend_limits.json", home / "spend_events.json", home / "usage.jsonl"):
            if p.exists(): p.unlink()
    def set_baseline(scope, when):
        cfg, _ = m.load_spend_limits()
        m._baseline_section(cfg, "global")[scope] = m.iso_precise(when)
        m.save_spend_limits(cfg)
    ledger = home / "usage.jsonl"
    # a manual baseline inside the session: only the parts after it count
    clean_spend_state()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    m.save_spend_limits(cfg)
    set_baseline("deepseek", t0)
    ledger.write_text(sess_parts("p1", t0 + 3 * H1, [(t0 - 2 * H1, 5.0), (t0 - H1, 1.0), (t0 + H1, 2.0),
                                                     (t0 + 2 * H1, 0.5)]) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=t0 + 4 * H1):
        records, _ = m.spend_cache_update()
        assert len(records) == 4 and {r["sid"] for r in records} == {"p1"}, records
        assert abs(m.current_spend("deepseek", proj, records) - 2.5) < 1e-9       # not the whole 8.5
    # a part that ends exactly at the baseline belongs to the new counter (current_spend counts ts == start)
    clean_spend_state()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    m.save_spend_limits(cfg)
    set_baseline("deepseek", t0)
    ledger.write_text(sess_parts("p1b", t0 + H1, [(t0 - H1, 5.0), (t0, 2.0)]) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=t0 + 2 * H1):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("deepseek", proj, records) - 2.0) < 1e-9

    # a month boundary: a monthly scope counts only the part in the current month
    clean_spend_state()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10, "reset": "month"}
    m.save_spend_limits(cfg)
    first = m.month_start(t0)
    ledger.write_text(sess_parts("p2", t0, [(first - H1, 4.0), (first + H1, 1.0)]) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=t0):
        records, _ = m.spend_cache_update()
        assert m.resolve_reset(cfg, "deepseek", proj) == "month"
        assert abs(m.current_spend("deepseek", proj, records) - 1.0) < 1e-9       # not 5.0 in November

    # two snapshots: the second is cumulative and split at the reset between them; the first one is dropped, and the
    # part spent before the reset is not counted in the new counter (nor by the cache built in two steps)
    clean_spend_state()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    m.save_spend_limits(cfg)
    set_baseline("deepseek", t0)
    ledger.write_text(sess_parts("p3", t0 + H1, [(t0 + H1 // 2, 3.0)]) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=t0 + H1):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("deepseek", proj, records) - 3.0) < 1e-9       # counted in the old counter
    set_baseline("deepseek", t0 + 2 * H1)                                         # orch spend reset
    with open(ledger, "a", encoding="utf-8") as f:
        f.write(sess_parts("p3", t0 + 4 * H1, [(t0 + H1 // 2, 3.0), (t0 + 3 * H1, 1.5)]) + "\n")
    with mock.patch.object(m, "now", return_value=t0 + 5 * H1):
        records, _ = m.spend_cache_update()
        assert [(r["sid"], r["cost"]) for r in records] == [("p3", 3.0), ("p3", 1.5)], records   # first snapshot gone
        assert abs(m.current_spend("deepseek", proj, records) - 1.5) < 1e-9
    (home / "spend_cache.json").unlink()                                          # rebuilt from the whole ledger
    with mock.patch.object(m, "now", return_value=t0 + 5 * H1):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("deepseek", proj, records) - 1.5) < 1e-9
    # records of other sessions and of runs stay beside a split session; a malformed parts list counts as one record
    with open(ledger, "a", encoding="utf-8") as f:
        f.write(sess_parts("p4", t0 + 4 * H1, [(t0 + 3 * H1, 0.25)]) + "\n")
        f.write(json.dumps({"kind": "session", "lead": "deepseek", "project": canon, "session": "p5", "spend_usd": 0.75,
                            "ts": m.iso_precise(t0 + 4 * H1),
                            "spend_parts": [{"until": "garbage", "spend_usd": 9.0}]}) + "\n")
    with mock.patch.object(m, "now", return_value=t0 + 5 * H1):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("deepseek", proj, records) - 2.5) < 1e-9       # 1.5 + 0.25 + 0.75
    # a part with a number too big for a float, or NaN, also counts the record as one, from its spend_usd
    huge = {"kind": "session", "lead": "deepseek", "project": canon, "session": "p6", "spend_usd": 0.5,
            "ts": m.iso_precise(t0), "spend_parts": [{"until": m.iso_precise(t0), "spend_usd": 10 ** 400}]}
    assert [r[2] for r in m.record_spend(huge)] == [0.5]
    huge["spend_parts"][0]["spend_usd"] = float("nan")
    assert [r[2] for r in m.record_spend(huge)] == [0.5]
    # the cache is format 4: an older cache is rebuilt from the ledger
    cache = m.read_json(home / "spend_cache.json", {})
    assert cache["format"] == 4
    (home / "spend_cache.json").write_text(json.dumps({"format": 3, "offset": ledger.stat().st_size,
                                                        "records": [{"label": "deepseek", "cost": 99.0}]}), encoding="utf-8")
    with mock.patch.object(m, "now", return_value=t0 + 5 * H1):
        records, _ = m.spend_cache_update()
        assert all(r["cost"] != 99.0 for r in records) and len(records) == 4, records

    # session_spend_parts: messages before, at and after a cut; one without a time; off-peak at half price
    clean_spend_state()
    ds = {"input_tokens": 1_000_000, "cached_input_tokens": 0, "output_tokens": 0}
    cut = dt.datetime(2026, 11, 2, 12, 0, tzinfo=dt.timezone.utc)               # Monday off-peak: $0.66 per message
    set_baseline("deepseek", cut)
    set_baseline("deepseek@work", cut + H1)                                       # another scope's baseline is not a cut
    s1 = dt.timedelta(seconds=1)
    def z(t):
        return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    msgs = [(z(cut + s1), "deepseek-v4-pro", ds), (None, "deepseek-v4-pro", ds), (z(cut), "deepseek-v4-pro", ds),
            (z(cut - s1), "deepseek-v4-pro", ds)]                                # out of order on purpose
    with mock.patch.object(m, "now", return_value=cut + 5 * H1):
        parts = m.session_spend_parts("deepseek", msgs)
    assert len(parts) == 2, parts
    assert m.parse_iso(parts[0]["until"]) == cut - s1 and abs(parts[0]["spend_usd"] - 0.66) < 1e-9, parts
    assert m.parse_iso(parts[1]["until"]) == cut + s1 and abs(parts[1]["spend_usd"] - 3 * 0.66) < 1e-9, parts
    assert m.session_spend_parts("deepseek", []) == []
    with mock.patch.object(m, "now", return_value=cut + 5 * H1):                  # no time at all: priced at the end
        parts = m.session_spend_parts("deepseek", [(None, "deepseek-v4-pro", ds)])
    assert len(parts) == 1 and m.parse_iso(parts[0]["until"]) == cut + 5 * H1, parts
    # a cut that falls on no message leaves no empty part; a message is never lost
    assert [round(p["spend_usd"], 2) for p in m.session_spend_parts("deepseek", [(z(cut + H1), "deepseek-v4-pro", ds)])] == [0.66]
    # the same message costs half at an off-peak hour
    peak_t = dt.datetime(2026, 11, 3, 2, 0, tzinfo=dt.timezone.utc)               # Tuesday 02:00 UTC, a peak window
    peak = m.session_spend_parts("deepseek", [(z(peak_t), "deepseek-v4-pro", ds)])[0]["spend_usd"]
    off = m.session_spend_parts("deepseek", [(z(peak_t + 10 * H1), "deepseek-v4-pro", ds)])[0]["spend_usd"]
    assert abs(peak - 1.32) < 1e-9 and abs(off - 0.66) < 1e-9 and abs(peak - 2 * off) < 1e-9, (peak, off)
    # the month start is a cut as well, and a message exactly on it belongs to the new month
    ms = m.month_start(dt.datetime(2026, 12, 15, 12, 0, tzinfo=dt.timezone.utc))
    msgs = [(z(ms - H1), "deepseek-v4-pro", ds), (z(ms), "deepseek-v4-pro", ds), (z(ms + H1), "deepseek-v4-pro", ds)]
    parts = m.session_spend_parts("deepseek", msgs)
    one = lambda t: m.usage_cost(ds, "deepseek", "deepseek-v4-pro", when=t)    # each at its own hour's price
    assert len(parts) == 2 and abs(parts[0]["spend_usd"] - one(ms - H1)) < 1e-9, parts
    assert abs(parts[1]["spend_usd"] - one(ms) - one(ms + H1)) < 1e-9 and m.parse_iso(parts[1]["until"]) == ms + H1, parts
    # spend_cuts reads only: a broken limits file leaves the month starts and is not touched
    assert cut in m.spend_cuts("deepseek", cut - H1, cut + H1) and cut + H1 not in m.spend_cuts("deepseek", cut - H1, cut + 2 * H1)
    (home / "spend_limits.json").write_text("{broken", encoding="utf-8")
    assert m.spend_cuts("deepseek", ms - H1, ms + H1) == [ms] and m.spend_cuts("deepseek", cut - H1, cut + H1) == []
    assert (home / "spend_limits.json").read_text(encoding="utf-8") == "{broken"
    # month_start is local midnight of the 1st with that day's own offset, also after a DST change, so a monthly
    # counter starts exactly at the cut (a POSIX TZ rule, so no zone database is needed; time.tzset is POSIX only)
    import time
    if hasattr(time, "tzset"):
        old_tz = os.environ.get("TZ")
        os.environ["TZ"] = "EST5EDT,M3.2.0,M11.1.0"
        time.tzset()
        try:
            utc = dt.timezone.utc
            assert m.month_start(dt.datetime(2026, 3, 20, 12, tzinfo=utc)) == dt.datetime(2026, 3, 1, 5, tzinfo=utc)
            assert m.month_start(dt.datetime(2026, 11, 20, 12, tzinfo=utc)) == dt.datetime(2026, 11, 1, 4, tzinfo=utc)
            dst_cuts = m.spend_cuts("nobody", dt.datetime(2026, 2, 28, tzinfo=utc), dt.datetime(2026, 3, 2, tzinfo=utc))
            assert dst_cuts == [dt.datetime(2026, 3, 1, 5, tzinfo=utc)], dst_cuts
        finally:
            if old_tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old_tz
            time.tzset()

    # the cache persists its byte offset even when the new bytes contain no API-billed record
    for p in (home / "spend_cache.json", home / "spend_limits.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["codex"] = {"limit": 10}
    m.save_spend_limits(cfg)
    ledger = home / "usage.jsonl"
    ledger.write_text(json.dumps({"kind": "probe", "ts": m.iso(fixed2)}) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=fixed2):
        m.spend_cache_update()
        cache = m.read_json(home / "spend_cache.json", {})
        assert cache["offset"] == ledger.stat().st_size and cache["records"] == []

def worker_env_leak():
    with mock.patch.dict(os.environ, {
            "ANTHROPIC_API_KEY": "sk-leak", "ANTHROPIC_AUTH_TOKEN": "tok-leak",
            "CODEX_API_KEY": "cx-leak", "OPENAI_API_KEY": "oai-leak",
            "DEEPSEEK_API_KEY": "ds-keep", "CLAUDE_CONFIG_DIR": "/cfg-keep",
            "CLAUDECODE": "1"}, clear=True):
        env = m.worker_env({})
        assert "ANTHROPIC_API_KEY" not in env and "ANTHROPIC_AUTH_TOKEN" not in env
        assert "CODEX_API_KEY" not in env and "OPENAI_API_KEY" not in env
        assert env.get("DEEPSEEK_API_KEY") == "ds-keep"          # not a leak var, kept
        assert env.get("CLAUDE_CONFIG_DIR") == "/cfg-keep"       # KEEP_CLAUDE_VARS
        assert "CLAUDECODE" not in env
        env = m.worker_env({"ANTHROPIC_API_KEY": "sk-profile"})  # a profile's own key re-enters via extra
        assert env.get("ANTHROPIC_API_KEY") == "sk-profile"

def worker_env_declared():
    # A declared secret that isn't explicit takes its value from the real environment ("real env wins"), and any
    # ANTHROPIC_*_API_KEY / _AUTH_TOKEN beyond the four in WORKER_LEAK_VARS never leaks.
    with mock.patch.dict(os.environ, {"ANTHROPIC_FOUNDRY_API_KEY": "foundry-leak",
                                      "OPENAI_API_KEY": "shell-key"}, clear=True):
        env = m.worker_env({}, secrets=["OPENAI_API_KEY"])
        assert "ANTHROPIC_FOUNDRY_API_KEY" not in env      # any ANTHROPIC_*_API_KEY never leaks
        assert env.get("OPENAI_API_KEY") == "shell-key"    # declared, non-explicit → the real environment wins
    # A key named in profiles.json is dropped even though it isn't a hardcoded leak var; the run's own key re-enters.
    m.save_profiles({"providers": {"deepseek": {"profiles": {"work": {"key": "DEEPSEEK_API_KEY_WORK"}}}},
                     "projects": {}})
    try:
        assert m.profile_key_vars() == {"DEEPSEEK_API_KEY_WORK"}
        with mock.patch.dict(os.environ, {"DEEPSEEK_API_KEY_WORK": "work-leak"}, clear=True):
            assert "DEEPSEEK_API_KEY_WORK" not in m.worker_env({})
            assert m.worker_env({"DEEPSEEK_API_KEY_WORK": "work-val"})["DEEPSEEK_API_KEY_WORK"] == "work-val"
    finally:
        (home / "profiles.json").unlink()
    # From secrets.env only when the real environment lacks it (real env wins).
    (home / "secrets.env").write_text("OPENAI_API_KEY=from-file\n", encoding="utf-8")
    try:
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "shell-key"}, clear=True):
            assert m.worker_env({}, secrets=["OPENAI_API_KEY"]).get("OPENAI_API_KEY") == "shell-key"
        with mock.patch.dict(os.environ, {}, clear=True):
            assert m.worker_env({}, secrets=["OPENAI_API_KEY"]).get("OPENAI_API_KEY") == "from-file"
    finally:
        (home / "secrets.env").unlink()

def settings_deny_bom():
    sd = root / "denyproj"
    (sd / ".claude").mkdir(parents=True)
    (sd / ".git").mkdir()                              # stop the walk right here
    rules = {"permissions": {"deny": ["Read(**/.env)", "Bash(git push:*)", "Edit(**/*)"]}}
    # A UTF-8 BOM (as PowerShell 5 writes) must still yield the deny rules.
    (sd / ".claude" / "settings.json").write_bytes(b"\xef\xbb\xbf" + json.dumps(rules).encode("utf-8"))
    with mock.patch.dict(os.environ, {"ORCH_CWD": str(sd)}):
        warned = []
        deny = H.settings_deny(warned.append)
        assert "Read(**/.env)" in deny and "Bash(git push:*)" in deny, deny
        assert "Edit(**/*)" not in deny                # only Read/Bash rules are forwarded
        assert warned == []
    # A settings file that exists but isn't JSON is named, not silently dropped.
    (sd / ".claude" / "settings.json").write_text("{broken", encoding="utf-8")
    with mock.patch.dict(os.environ, {"ORCH_CWD": str(sd)}):
        warned = []
        deny = H.settings_deny(warned.append)
        assert deny == []
        assert any("settings.json" in w for w in warned), warned

def codex_home_profile():
    prof = m.Profile("codex", "work", {"home": str(home / "cx-work")}, "test", True)
    with mock.patch.dict(os.environ, {"CODEX_HOME": str(home / "no-codex")}):
        assert m.codex_home(proj, prof) == str(Path(str(home / "cx-work")).expanduser())
        assert m.codex_home(proj) == str(Path(str(home / "no-codex")).expanduser())

def detected_lead():
    for key in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
                "ORCH_LEAD", "ORCH_LEAD_MODEL", "ORCH_LEAD_ENV", "ORCH_LEAD_VIA", "ORCH_LEAD_KEY"):
        os.environ.pop(key, None)
    # the common path: no override, and not one file is read
    calls = []
    def reading(name):
        def f(*a, **kw):
            calls.append(name)
            raise AssertionError("read without an ANTHROPIC_BASE_URL override: " + name)
        return f
    with mock.patch.object(m, "adapter_head", reading("adapter_head")), \
         mock.patch.object(m, "adapter_directives", reading("adapter_directives")), \
         mock.patch.object(m, "find_adapter", reading("find_adapter")), \
         mock.patch.object(m, "load_profiles", reading("load_profiles")), \
         mock.patch.object(m, "load_secrets", reading("load_secrets")):
        assert m.detect_lead() is None and calls == [] and not os.environ.get("ORCH_LEAD")
    good(["profile", "use", "deepseek", "inherit", "--default"])     # no default profile from an earlier test
    good(["profile", "use", "deepseek", "inherit", "--path", str(proj)])
    good(["profile", "set", "deepseek", "work", "--key", "DEEPSEEK_API_KEY_WORK"])
    good(["profile", "set", "deepseek", "team", "--key", "DEEPSEEK_API_KEY_TEAM"])
    (home / "secrets.env").write_text("DEEPSEEK_API_KEY_WORK=sk-lead-work\nDEEPSEEK_API_KEY_TEAM=sk-lead-team\n",
                                      encoding="utf-8")
    # the endpoint is compared normalised (case, trailing slash); the profile whose key is the token is the label
    with mock.patch.dict(os.environ, {"ANTHROPIC_BASE_URL": "https://API.DeepSeek.com/anthropic/",
                                      "ANTHROPIC_AUTH_TOKEN": "sk-lead-work",
                                      "ANTHROPIC_MODEL": "deepseek-v4-pro"}):
        assert m.detect_lead() == "deepseek@work"
        assert os.environ["ORCH_LEAD"] == "deepseek@work" and os.environ["ORCH_LEAD_VIA"] == "detected"
        assert os.environ["ORCH_LEAD_MODEL"] == "deepseek-v4-pro" and "ORCH_LEAD_KEY" not in os.environ
        assert {"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"} <= set(os.environ["ORCH_LEAD_ENV"].split(","))
        assert m.lead_via_text() == "(detected: ANTHROPIC_BASE_URL)"
        assert "DeepSeek@work" in m.lead_line() and "none of your profiles' keys" not in m.lead_line()
    # two profiles share the key: the directory binding decides
    good(["profile", "set", "deepseek", "team", "--key", "DEEPSEEK_API_KEY_WORK"])
    good(["profile", "use", "deepseek", "team", "--path", str(proj)])
    with mock.patch.dict(os.environ, {"ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                                      "ANTHROPIC_AUTH_TOKEN": "sk-lead-work"}):
        assert m.detect_lead() == "deepseek@team"
    good(["profile", "use", "deepseek", "work", "--path", str(proj)])
    with mock.patch.dict(os.environ, {"ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                                      "ANTHROPIC_AUTH_TOKEN": "sk-lead-work"}):
        assert m.detect_lead() == "deepseek@work"
    good(["profile", "use", "deepseek", "inherit", "--path", str(proj)])
    good(["profile", "set", "deepseek", "team", "--key", "DEEPSEEK_API_KEY_TEAM"])     # distinct keys again
    # the adapter's own base_url variable is the same endpoint
    with mock.patch.dict(os.environ, {"ANTHROPIC_BASE_URL": "https://deepseek.example/v1/",
                                      "ORCH_DEEPSEEK_BASE_URL": "HTTPS://DeepSeek.example/v1",
                                      "ANTHROPIC_AUTH_TOKEN": "sk-lead-work"}):
        assert m.detect_lead() == "deepseek@work"
    # a token that is none of the keys: the bare provider, and the Lead line says the spend is unaccounted
    with mock.patch.dict(os.environ, {"ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                                      "ANTHROPIC_AUTH_TOKEN": "sk-nobody"}):
        assert m.detect_lead() == "deepseek" and os.environ["ORCH_LEAD_KEY"] == "none"
        assert "none of your profiles' keys" in m.lead_line()
    # the provider's own default key variable matches too, with no such note
    with mock.patch.dict(os.environ, {"ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                                      "ANTHROPIC_API_KEY": "sk-default", "DEEPSEEK_API_KEY": "sk-default"}):
        assert m.detect_lead() == "deepseek" and "ORCH_LEAD_KEY" not in os.environ
    # Anthropic itself and another proxy are not a lead
    for url in ("https://api.anthropic.com", "https://gateway.example/anthropic", "not a url"):
        with mock.patch.dict(os.environ, {"ANTHROPIC_BASE_URL": url, "ANTHROPIC_AUTH_TOKEN": "sk-lead-work"}):
            assert m.detect_lead() is None and not os.environ.get("ORCH_LEAD"), url

failed = 0
for name, test in [("1 parallel offers, take/reclaim, sessions and capacity", parallel_state),
                   ("1 atomic I/O failures, rollback, nested lock and crash release", state_failures),
                   ("2 launch session profile precedence and errors", launch_profiles),
                   ("3 central worker guard for every handoff command", worker_guard),
                   ("4 stale measurement pace and independent window timestamps", stale_budget),
                   ("5 weekly TIGHT without current five-hour numbers", weekly_budget),
                   ("5b weekly recent pace and shrinking reserve", weekly_pace),
                   ("5c Codex weekly recent pace and reserve", codex_weekly),
                   ("6 force cannot bypass manual profile capacity", hard_cap),
                   ("7 wait any reports an existing result exactly once", existing_result),
                   ("8 inferred activity gets one overdue warning; fast check never scans", overdue_activity),
                   ("9 lead drops OAuth token; Claude executor works without it", token_hygiene),
                   ("10 blocked/partial ledger and model-only capacity fallback", run_outcomes),
                   ("10b corrupt price data keeps the ledger line, priced 0", run_cost_fallback),
                   ("review corrupt state recovery and operator protection", corruption_recovery),
                   ("review stale claims, late finishers and assignment failures", assignment_recovery),
                   ("review report first status and reclaimed slot", report_reclaimed),
                   ("review handoff path storage and old metas", meta_paths),
                   ("review monthly spend: prices, counters, cache restart", spend_limits),
                   ("review worker env strips login/API keys", worker_env_leak),
                   ("review worker env: declared secrets, profile keys, anthropic key vars", worker_env_declared),
                   ("review settings deny survives a BOM and names a broken file", settings_deny_bom),
                   ("review --profile honoured by codex account lookups", codex_home_profile),
                   ("review a session's own ANTHROPIC_* override is a lead", detected_lead)]:
    try:
        test()
        print("PASS " + name)
    except Exception:
        failed += 1
        print("FAIL " + name)
        traceback.print_exc()
sys.exit(bool(failed))
EOF
); review_rc=$?
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) [[ -z "$line" ]] || echo "$line" ;;
  esac
done <<<"$review"
[[ $review_rc -eq 0 ]] || bad "review regression process failed (rc=$review_rc)"

