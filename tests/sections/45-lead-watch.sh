# needs:
echo "── watching the orchestrator's own limits (a pause question before work stops)"
# Each scene is its own home and project: a snapshot written directly (the established way, as sections 22 and 36 do),
# then the hooks and `orch watch` read it. The driver below emits OK/NO lines; this shell turns them into checks.
lw_out=$($PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/lead-watch")" <<'LEAD_WATCH_TEST'
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ORCH = sys.argv[1]
BASE = Path(sys.argv[2])
PY = sys.executable
BASE.mkdir(parents=True, exist_ok=True)

# `orch` runs the way the suite runs it, but never as a session of this machine: no inherited id, lead or profiles.
STRIP = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR", "ORCH_PROJECT_DIR", "ORCH_PROFILES", "ORCH_USAGE_LOG",
         "ORCH_LEAD", "ORCH_LEAD_MODEL", "ORCH_LEAD_ENV", "ORCH_LEAD_VIA", "ORCH_LEAD_KEY", "ORCH_SESSION_ID",
         "ORCH_WORKER", "ORCH_HOME", "ORCH_BALANCE", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")
BASE_ENV = {k: v for k, v in os.environ.items() if k not in STRIP}


def now():
    return dt.datetime.now().astimezone()


def iso(t):
    return t.isoformat(timespec="seconds")


def check(cond, name, detail=""):
    print(("OK " if cond else "NO ") + name + ("" if cond else " :: " + str(detail)))


def has(name, text, needle):
    check(needle in text, name, "missing %r in:\n%s" % (needle, text))


def lacks(name, text, needle):
    check(needle not in text, name, "unexpected %r in:\n%s" % (needle, text))


class Scene:
    def __init__(self, name, lead=None):
        self.root = BASE / name
        self.home = self.root / "home"
        self.project = self.root / "proj"
        self.home.mkdir(parents=True, exist_ok=True)
        self.project.mkdir(parents=True, exist_ok=True)
        self.lead = lead
        self.resets = {}

    def run(self, *args, stdin="", sid=None, extra=None, code=None):
        env = dict(BASE_ENV, ORCH_HOME=str(self.home), ORCH_PROJECT_DIR=str(self.project), ORCH_BALANCE="off")
        if self.lead:
            env["ORCH_LEAD"] = self.lead
        if extra:
            env.update(extra)
        if sid is not None:
            env["ORCH_SESSION_ID"] = sid
        command = [PY, "-B", "-c", code, ORCH] if code else [PY, ORCH] + list(args)
        return subprocess.run(command, input=stdin, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", env=env, cwd=str(self.project), timeout=180)

    def hook(self, event, sid, extra=None):
        return self.run("hook", event, stdin=json.dumps({"session_id": sid}), extra=extra)

    def write(self, name, data):
        (self.home / name).write_text(json.dumps(data) if not isinstance(data, str) else data, encoding="utf-8")

    def state(self):
        try:
            return json.loads((self.home / "watch.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def entry(self, sid):
        return (self.state().get("sessions") or {}).get(sid) or {}

    def backdate(self, sid, minutes, field="asked", sub=None):
        data = self.state()
        target = data["sessions"][sid] if sub is None else data["sessions"][sid][sub]
        target[field] = iso(now() - dt.timedelta(minutes=minutes))
        self.write("watch.json", data)


def write_snapshot(scene, five=None, history=None, week=None, week_history=None, reset_min=120, week_reset_min=2880):
    t = now()
    snap = {"updated": iso(t), "source": "statusline"}
    def reset_at(name, minutes):
        # Repeated measurements belong to the same window; only an explicit new duration changes its tie.
        return scene.resets.setdefault((name, minutes), iso(t + dt.timedelta(minutes=minutes)))
    if five is not None:
        snap["five_hour"] = {"used": float(five), "resets_at": reset_at("five_hour", reset_min)}
    if history is not None:
        reset = snap["five_hour"]["resets_at"]
        snap["history"] = [[iso(t - dt.timedelta(minutes=m)), float(u), reset] for m, u in history]
    if week is not None:
        snap["seven_day"] = {"used": float(week), "resets_at": reset_at("seven_day", week_reset_min)}
    if week_history is not None:
        reset = snap["seven_day"]["resets_at"]
        snap["week_history"] = [[iso(t - dt.timedelta(minutes=m)), float(u), reset] for m, u in week_history]
    scene.write("claude_usage.json", snap)
    return snap


def is_asked(proc):
    return "⚠ Lanewise:" in proc.stdout


def no_question(name, proc):
    check(not is_asked(proc), name, proc.stdout + proc.stderr)


def profile(scene, name, opts, use=True):
    args = ["profile", "set", "claude", name]
    for opt in opts:
        args += ["--opt", opt]
    first = scene.run(*args)
    if use:
        scene.run("profile", "use", "claude", name)
    return first


# Load the plugin's code in process: a check can then replace one function and observe its calls.
LOAD_ORCH = """
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader('watch_under_test', sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
m._quiet_state = True
"""


# ── an empty home: nothing to watch, no question ──────────────────────────────────────────────────────────────────
empty = Scene("empty")
p = empty.run("watch")
has("empty home: watch says there are no figures", p.stdout, "No figures to watch: no current Claude subscription numbers.")
has("empty home: nothing is at risk", p.stdout, "At risk now: nothing.")
p = empty.run("watch", "--json")
try:
    data = json.loads(p.stdout)
except ValueError:
    data = {}
check(data.get("limits") == [] and data.get("risks") == [] and data.get("settings", {}).get("watch") == "on",
      "empty home: watch --json has no limits, no risks, watch on", p.stdout)
no_question("empty home: session-start asks nothing", empty.hook("session-start", "e1"))

# ── the Claude 5-hour window: any projection that reaches 100% at the reset ──────────────────────────────────────
five = Scene("five")
write_snapshot(five, five=82, history=[(45, 70)])
p = five.run("watch")
has("5-hour risk: the used share and the reset", p.stdout, "Claude 5-hour window: 82% used, resets at ")
has("5-hour risk: the window average projects 137% at the reset", p.stdout,
    "at this pace (window average), projected 137% at the reset")
has("5-hour risk: watch marks it RISK", p.stdout, "— RISK.")
p = five.hook("session-start", "s1")
has("5-hour risk: session-start asks with real numbers",
    p.stdout, "⚠ Lanewise: the Claude 5-hour window may run out before it resets: 82% used, at this pace exhausted around ")
has("5-hour risk: the question names the reset", p.stdout, ", resets at ")
has("5-hour risk: the question says to ask once with these options",
    p.stdout, "Ask the user (one question with these options), then record the answer: pause this session until ")
has("5-hour risk: the pause answer", p.stdout, "`orch watch answer pause`")
has("5-hour risk: the continue answer", p.stdout, "continue, ask again later → `orch watch answer continue`")
has("5-hour risk: the continue-session answer", p.stdout,
    "continue, don't ask again in this session → `orch watch answer continue-session`")
no_question("5-hour risk: the question is not repeated while it is open", five.hook("user-prompt", "s1"))
five.backdate("s1", 16)
has("5-hour risk: an unanswered question repeats after 15 minutes",
    five.hook("user-prompt", "s1").stdout, "⚠ Lanewise:")
p = five.run("watch", sid="s1")
has("5-hour risk: watch shows the session was asked", p.stdout, "This session: no answer (asked ")

# PostToolUse carries the question as additionalContext, at most once per two minutes (the marker file)
p = five.hook("post-tool", "t1")
try:
    payload = json.loads(p.stdout)
except ValueError:
    payload = {}
ctx = (payload.get("hookSpecificOutput") or {})
check(ctx.get("hookEventName") == "PostToolUse" and "⚠ Lanewise: the Claude 5-hour window" in ctx.get("additionalContext", ""),
      "post-tool: additionalContext carries the question", p.stdout)
p = five.hook("post-tool", "t2")
has("post-tool: session A does not silence session B", p.stdout, "⚠ Lanewise:")
five.backdate("t1", 16)                # make another question due, independently of the tool throttle
p = five.hook("post-tool", "t1")
try:
    payload = json.loads(p.stdout)
except ValueError:
    payload = {}
check("⚠ Lanewise" not in ((payload.get("hookSpecificOutput") or {}).get("additionalContext") or ""),
      "post-tool: a second check within 2 minutes is silent", p.stdout)
marker_dir = five.home / ".watch-post-tool"
marker = marker_dir / hashlib.sha256(b"t1").hexdigest()
os.utime(str(marker), (time.time() - 180, time.time() - 180))
stale_marker = marker_dir / "quiet-session"
stale_marker.touch()
os.utime(str(stale_marker), (time.time() - 90000, time.time() - 90000))
p = five.hook("post-tool", "t1")
try:
    payload = json.loads(p.stdout)
except ValueError:
    payload = {}
check("⚠ Lanewise" in ((payload.get("hookSpecificOutput") or {}).get("additionalContext") or ""),
      "post-tool: the marker older than 2 minutes lets the question through", p.stdout)
check(not stale_marker.exists(), "post-tool: touching a marker prunes files older than a day")

# ── no risk when the projection stays under the cap or the window is too young to project ────────────────────────
safe = Scene("safe")
write_snapshot(safe, five=10)
p = safe.run("watch")
has("a light window: no risk", p.stdout, "— no risk.")
no_question("a light window: session-start asks nothing", safe.hook("session-start", "a1"))

young = Scene("young")
write_snapshot(young, five=95, reset_min=270)          # 30 minutes into a five-hour window
p = young.run("watch")
has("a young window: the projection is unavailable", p.stdout, "projection unavailable")
has("a young window: no risk without a projection", p.stdout, "— no risk.")
no_question("a young window: session-start asks nothing", young.hook("session-start", "y1"))

# ── a window of a day or more: out before the reset, and in the horizon or with watch_low left ───────────────────
week_low = Scene("week-low")
write_snapshot(week_low, week=96, week_reset_min=2880)
p = week_low.hook("session-start", "w1")
has("weekly low: 4% left asks", p.stdout,
    "⚠ Lanewise: the Claude weekly limit may run out before it resets: 96% used, at this pace exhausted around ")
has("weekly low: the question names the reset", p.stdout, ", resets at ")
p = week_low.run("watch")
has("weekly low: watch marks the weekly limit RISK", p.stdout, "Claude weekly limit: 96% used")
check("— RISK." in p.stdout, "weekly low: the risk line ends RISK", p.stdout)

week_no_pace = Scene("week-no-pace")
write_snapshot(week_no_pace, week=96, week_reset_min=10070)    # ten minutes into the week
p = week_no_pace.run("watch", "--json")
limit = json.loads(p.stdout)["limits"][0]
check(limit["projected_percent_at_reset"] is None and not limit["risk"],
      "weekly low: 96% used without enough pace data is no risk", p.stdout)
no_question("weekly low: no hook event without a projection", week_no_pace.hook("user-prompt", "wp1"))

week_far = Scene("week-far")
write_snapshot(week_far, week=70, week_history=[(1800, 40)], week_reset_min=2400)
p = week_far.run("watch", "--json")
limit = json.loads(p.stdout)["limits"][0]
hours = (dt.datetime.fromisoformat(limit["exhausted_at"]) - now()).total_seconds() / 3600
check(limit["projected_percent_at_reset"] > 100 and 29 < hours < 31 and not limit["risk"],
      "weekly horizon: projected over 100% but exhaustion in 30 hours is no risk", p.stdout)
no_question("weekly horizon: distant exhaustion asks nothing", week_far.hook("user-prompt", "wf1"))

week_horizon = Scene("week-horizon")
profile(week_horizon, "noearly", ["watch_early=off"])
write_snapshot(week_horizon, week=85, week_history=[(420, 20)], week_reset_min=2880)   # 15% left, exhausted in ~1.6 h
p = week_horizon.hook("user-prompt", "h1")
has("weekly horizon: exhausted within watch_horizon_h asks", p.stdout,
    "⚠ Lanewise: the Claude weekly limit may run out before it resets: 85% used, at this pace exhausted around ")
lacks("weekly horizon: watch_early=off keeps the question regular", p.stdout, "well before")
p = week_horizon.run("watch")
has("weekly horizon: early off in the settings", p.stdout, "Settings: watch on, early off")
has("weekly horizon: watch marks it RISK", p.stdout, "— RISK.")
lacks("weekly horizon: early off leaves no EARLY line", p.stdout, "EARLY")

# the early rule: both paces run out before the reset, the lower one at least 15% of the window early, on 24 h+ samples
week_early = Scene("week-early")
write_snapshot(week_early, week=70, week_history=[(1800, 50)], week_reset_min=4320)
p = week_early.hook("session-start", "w2")
has("weekly early: the question says it runs out well before the reset", p.stdout,
    "⚠ Lanewise: the Claude weekly limit may run out well before it resets: 70% used; at the last 1d 6h exhausted around ")
has("weekly early: the question names the week's average too", p.stdout, ", at the week's average around ")
has("weekly early: the question names the reset", p.stdout, "; it resets at ")
p = week_early.run("watch")
has("weekly early: watch shows EARLY", p.stdout, "EARLY")
has("weekly early: watch marks it RISK", p.stdout, "— RISK.")

week_young = Scene("week-young")
write_snapshot(week_young, week=70, week_history=[(1200, 60)], week_reset_min=4320)    # the pace rests on 20 h only
p = week_young.run("watch")
has("early needs 24 h of samples: no risk", p.stdout, "— no risk.")
lacks("early needs 24 h of samples: no EARLY", p.stdout, "EARLY")
no_question("early needs 24 h of samples: session-start asks nothing", week_young.hook("session-start", "w3"))

week_late = Scene("week-late")
write_snapshot(week_late, week=70, week_history=[(1800, 70 - 30 * 30 / 62)], week_reset_min=4320)
no_question("early: the slower pace exhausting only 10 hours before reset is no risk",
            week_late.hook("user-prompt", "wl1"))
p = week_late.run("watch", "--json")
limit = json.loads(p.stdout)["limits"][0]
check(limit["projected_percent_at_reset"] > 100 and not limit["risk"],
      "early: both project exhaustion, but the conservative margin is too small", p.stdout)

week_fast_young = Scene("week-fast-young")
write_snapshot(week_fast_young, week=70, week_history=[(720, 46)], week_reset_min=4320)
no_question("early: the faster recent estimate also needs 24 hours of data",
            week_fast_young.hook("user-prompt", "wy1"))
p = week_fast_young.run("watch", "--json")
check(not json.loads(p.stdout)["limits"][0]["risk"], "early: a mature slower average cannot validate a young fast pace", p.stdout)

# ── continue: ask again after 60 minutes or 10 points, while the risk persists ───────────────────────────────────
cont = Scene("continue")
snap = write_snapshot(cont, five=82, history=[(45, 70)])
p = cont.run("watch", "answer", "continue", sid="c1")
has("continue: the answer says when the next question comes", p.stdout, "Continue: ask again after 60 minutes or 10 points.")
entry = cont.entry("c1")
answer = entry.get("answer") or {}
stored = (answer.get("limits") or [{}])[0]
check(answer.get("kind") == "continue" and stored.get("key") == "five_hour"
      and stored.get("tie") == snap["five_hour"]["resets_at"] and stored.get("used") == 82,
      "continue: the answer is tied to the limit and its reset", json.dumps(entry))
no_question("continue: no new question at once", cont.hook("user-prompt", "c1"))
cont.backdate("c1", 59, field="at", sub="answer")
no_question("continue: time alone does not ask before 60 minutes", cont.hook("user-prompt", "c1"))
cont.backdate("c1", 61, field="at", sub="answer")
has("continue: time alone asks after 60 minutes with no growth", cont.hook("user-prompt", "c1").stdout, "⚠ Lanewise:")
cont.run("watch", "answer", "continue", sid="c1")
write_snapshot(cont, five=93, history=[(45, 70)])
has("continue: 11 points of growth asks again", cont.hook("user-prompt", "c1").stdout, "⚠ Lanewise:")

# a five-hour risk counts under continue only while the lower pace estimate agrees; a new reset ends the answer
conservative = Scene("conservative")
write_snapshot(conservative, five=62, history=[(45, 55)])
p = conservative.run("watch", "--json")
try:
    data = json.loads(p.stdout)
except ValueError:
    data = {}
limit = (data.get("limits") or [{}])[0]
check(limit.get("risk") is True and limit.get("conservative_risk") is False,
      "continue: the 5-hour average projects 100% while the lower pace does not", p.stdout)
conservative.run("watch", "answer", "continue", sid="k1")
conservative.backdate("k1", 61, field="at", sub="answer")
conservative.backdate("k1", 16)
no_question("continue: the raised bar holds 61 minutes later without the lower pace agreeing",
            conservative.hook("user-prompt", "k1"))
write_snapshot(conservative, five=75, history=[(45, 55)])
has("continue: 13 points of growth asks when the lower pace now agrees",
    conservative.hook("user-prompt", "k1").stdout, "⚠ Lanewise:")
conservative.backdate("k1", 16)
write_snapshot(conservative, five=75, history=[(45, 55)], reset_min=90)
has("continue: a five-hour reset ends the answer and the risk is asked again",
    conservative.hook("user-prompt", "k1").stdout, "⚠ Lanewise:")

never = Scene("continue-session")
write_snapshot(never, five=82, history=[(45, 70)])
p = never.run("watch", "answer", "continue-session", sid="v1")
has("continue-session: the answer is confirmed", p.stdout, "Continue: this session will not be asked again.")
p = never.run("watch", sid="v1")
has("continue-session: watch shows the standing answer", p.stdout, "This session: continue, not asked again in this session")
never.backdate("v1", 120)
write_snapshot(never, five=99, history=[(45, 70)])
no_question("continue-session: even a higher risk is not asked again", never.hook("user-prompt", "v1"))
never.backdate("v1", 9 * 24 * 60, field="at")
never.write("sessions.json", {"v1": {"seen": iso(now()), "kind": "session"}})
never.run("watch", "answer", "continue", sid="v2")     # a different session's write triggers pruning
check((never.entry("v1").get("answer") or {}).get("kind") == "continue-session",
      "pruning: an old answer survives while its session is active", never.state())
no_question("pruning: an active old continue-session is still honored", never.hook("user-prompt", "v1"))
has("continue-session: another session is still asked", never.hook("user-prompt", "v3").stdout, "⚠ Lanewise:")

# ── pause until the reset: a reminder in this session only, then the pause ends by itself ────────────────────────
pause = Scene("pause")
write_snapshot(pause, five=82, history=[(45, 70)])
p = pause.run("watch", "answer", "pause", sid="p1")
has("pause: the answer names the reset", p.stdout, "Paused this session until ")
has("pause: the answer names the limit", p.stdout, "(Claude 5-hour window).")
p = pause.hook("user-prompt", "p1")
has("pause: the reminder", p.stdout, "⏸ Lanewise: this session is paused until ")
has("pause: the reminder says what to do", p.stdout,
    "Finish nothing new; answer briefly; if the user says to continue, run `orch watch answer continue`.")
has("pause: another session is still asked", pause.hook("user-prompt", "p2").stdout, "⚠ Lanewise:")
p = pause.run("statusline", stdin=json.dumps({"session_id": "p1"}))
has("pause: the status line only reads the answer", p.stdout, "⏸ paused until ")
pause.backdate("p1", 2, field="until", sub="answer")
(pause.home / "claude_usage.json").unlink()
p = pause.hook("user-prompt", "p1")
has("pause: it ends by itself with one marker", p.stdout,
    "▶ Lanewise: the pause is over (the limit reset); continue where you stopped.")
p = pause.hook("user-prompt", "p1")
check("▶ Lanewise" not in p.stdout and "⏸ Lanewise" not in p.stdout,
      "pause: the end is said once and never repeated", p.stdout)

# ── watch=off, watch_early=off, ORCH_WORKER, a broken state file ─────────────────────────────────────────────────
off = Scene("off")
write_snapshot(off, five=82, history=[(45, 70)])
profile(off, "quiet", ["watch=off"])
no_question("watch=off: session-start asks nothing", off.hook("session-start", "o1"))
p = off.run("watch")
has("watch=off: watch still shows the figures", p.stdout, "Claude 5-hour window: 82% used")
has("watch=off: watch says the watcher is off", p.stdout, "The watcher is off")
has("watch=off: the settings say watch off", p.stdout, "Settings: watch off")
p = off.run("watch", "answer", "continue", sid="o1")
check(p.returncode != 0 and "the limit watch is off" in p.stderr, "watch=off: the answers are refused", p.stderr)

noearly = Scene("noearly")
write_snapshot(noearly, week=70, week_history=[(1800, 50)], week_reset_min=4320)
profile(noearly, "quiet", ["watch_early=off"])
no_question("watch_early=off: the early fixture asks nothing", noearly.hook("session-start", "q1"))
p = noearly.run("watch")
has("watch_early=off: the settings say early off", p.stdout, "Settings: watch on, early off")
has("watch_early=off: no risk without the early rule", p.stdout, "— no risk.")

worker = Scene("worker")
write_snapshot(worker, five=82, history=[(45, 70)])
p = worker.hook("session-start", "x1", extra={"ORCH_WORKER": "1"})
check(p.returncode == 0 and not p.stdout.strip(), "ORCH_WORKER: the hook stays silent", p.stdout + p.stderr)

corrupt = Scene("corrupt")
write_snapshot(corrupt, five=82, history=[(45, 70)])
corrupt.write("watch.json", "{not json")
p = corrupt.hook("session-start", "z1")
has("a corrupt watch.json: the question still comes", p.stdout, "⚠ Lanewise:")
check((corrupt.home / "watch.json.corrupt").exists(), "a corrupt watch.json is preserved as .corrupt",
      sorted(x.name for x in corrupt.home.iterdir()))

corrupt_sessions = Scene("corrupt-sessions")
write_snapshot(corrupt_sessions, five=82, history=[(45, 70)])
corrupt_sessions.write("sessions.json", "{not json")
p = corrupt_sessions.run("watch", "answer", "continue", sid="cs1")
check(p.returncode == 0 and "Continue: ask again after 60 minutes or 10 points." in p.stdout,
      "a corrupt sessions.json does not block an answer", p.stdout + p.stderr)
check((corrupt_sessions.entry("cs1").get("answer") or {}).get("kind") == "continue",
      "a corrupt sessions.json: the answer is recorded", corrupt_sessions.state())

# ── orch watch: every figure, the standing answer, the settings, and --json ──────────────────────────────────────
show = Scene("show")
write_snapshot(show, five=82, history=[(45, 70)])
p = show.run("watch")
has("watch: the limit line", p.stdout, "Claude 5-hour window: 82% used, resets at ")
has("watch: the risk list", p.stdout, "At risk now: the Claude 5-hour window.")
has("watch: no answer yet", p.stdout, "This session: no answer")
has("watch: the settings in effect", p.stdout,
    "Settings: watch on, early on, horizon 2 h, low 5% left, early share 15% of the window after 24 h of samples, "
    "ask again after 60 min or 10 points.")
show.run("watch", "answer", "continue", sid="sh1")
p = show.run("watch", sid="sh1")
has("watch: the standing answer", p.stdout, "This session: continue: ask again after 60 min or 10 points")
p = show.run("watch", "--json", sid="sh1")
try:
    data = json.loads(p.stdout)
except ValueError:
    data = {}
first = (data.get("limits") or [{}])[0]
check(data.get("risks") == ["five_hour"] and first.get("key") == "five_hour" and first.get("risk") is True
      and data.get("settings", {}).get("watch") == "on"
      and float(data.get("settings", {}).get("watch_horizon_h")) == 2.0
      and (data.get("answer") or {}).get("kind") == "continue",
      "watch --json: the risk, the settings and this session's answer", p.stdout)

# ── a non-Claude lead: its spend limit (a monthly counter) and its account balance (no pace → only the low test) ──
def lead_spend_scene(name, reset):
    scene = Scene(name, lead="deepseek")
    scene.write("spend_limits.json", {
        "defaults": {"limit": 10, "mode": "evaluate", "lead_mode": "continue", "overrun": 20},
        "global": {"deepseek": {"limit": 100, "reset": reset}},
        "projects": {}, "baselines": {}})
    return scene


lead = lead_spend_scene("lead-spend", "month")
lead.write("usage.jsonl", json.dumps({
    "kind": "run", "provider": "deepseek", "label": "deepseek", "project": "", "cost_usd": 96,
    "ts": iso(now())}) + "\n")
# The early rule at unit level: a monthly counter starts on the 1st, so through a hook it depends on the date (on
# the 1st there are neither 6-hour nor 30-minute samples yet). An explicit start and reset keep it deterministic.
early_code = LOAD_ORCH + """
start, reset = m.now() - m.dt.timedelta(days=30), m.now() + m.dt.timedelta(days=10)
item = m.watch_spend('deepseek', 100, 96, start, reset,
                     [(0.4, 'recent spend', 4320), (0.1, "the month's average", 43200)], m.WATCH_DEFAULTS)
levels = {basis: at for _, basis, at in item['levels']}
assert item['early'] is True and item['risk'] is True, item
assert set(levels) == {'recent spend', "the month's average"}, item
assert abs((levels['recent spend'] - (start + m.dt.timedelta(days=30, minutes=10))).total_seconds()) < 120, item
assert abs((levels["the month's average"] - (start + m.dt.timedelta(days=30, minutes=40))).total_seconds()) < 120, item
"""
p = lead.run(code=early_code)
check(p.returncode == 0 and not p.stdout and not p.stderr,
      "lead spend: a monthly spend limit at 96% is asked early", p.stdout + p.stderr)
p = lead.hook("session-start", "lp1")
has("lead spend: a monthly spend limit at 96% asks", p.stdout,
    "⚠ Lanewise: the DeepSeek spend limit may run out")
p = lead.run("watch")
has("lead spend: watch shows the spend limit", p.stdout, "DeepSeek spend limit: 96% used ($96.00 of $100.00)")
has("lead spend: watch marks it RISK", p.stdout, "— RISK.")
profile(lead, "noearly", ["watch_early=off"])
p = lead.hook("user-prompt", "lp2")
has("lead spend: without the early rule the low test asks", p.stdout,
    "⚠ Lanewise: the DeepSeek spend limit may run out before it resets: 96% used ($96.00 of $100.00)")
lacks("lead spend: the regular question does not say well before", p.stdout, "well before")

balance = lead_spend_scene("lead-balance", "manual")
balance.write("balances.json", {"deepseek": {"amount": 4, "currency": "USD", "at": iso(now())}})
p = balance.hook("session-start", "lb1")
has("lead balance: 4% left asks without a pace", p.stdout,
    "⚠ Lanewise: the DeepSeek account balance may run out: $4.00 left (4%)")
lacks("lead balance: no reset is named without one", p.stdout, "before it resets")
has("lead balance: pause lasts until a top-up", p.stdout,
    "pause this session until the balance is topped up → `orch watch answer pause`")
p = balance.run("watch")
has("lead balance: watch shows the balance", p.stdout, "DeepSeek account balance: $4.00 left (4%)")
has("lead balance: no pace, projection unavailable", p.stdout, "projection unavailable")
has("lead balance: watch marks it RISK", p.stdout, "— RISK.")

balance_month = lead_spend_scene("lead-balance-month", "month")
balance_month.write("balances.json", {"deepseek": {"amount": 4, "currency": "USD", "at": iso(now())}})
p = balance_month.run("watch", "--json")
limits = json.loads(p.stdout)["limits"]
spend_limit = next(l for l in limits if l["kind"] == "spend")
balance_limit = next(l for l in limits if l["kind"] == "balance")
check(spend_limit["resets_at"] is not None and balance_limit["resets_at"] is None
      and balance_limit["projected_percent_at_reset"] is None and balance_limit["risk"],
      "lead balance: the monthly spend reset is not the balance reset", p.stdout)
p = balance_month.run("watch", "answer", "pause", sid="bm1")
has("lead balance: the pause command names the top-up", p.stdout, "until the balance is topped up")
check((balance_month.entry("bm1").get("answer") or {}).get("until") is None,
      "lead balance: the pause has no end time", balance_month.entry("bm1"))
has("lead balance: an indefinite pause reminds on a prompt", balance_month.hook("user-prompt", "bm1").stdout,
    "⏸ Lanewise: this session is paused until the balance is topped up")
balance_month.run("watch", "answer", "continue", sid="bm1")
check((balance_month.entry("bm1").get("answer") or {}).get("kind") == "continue",
      "lead balance: continue replaces the indefinite pause", balance_month.entry("bm1"))
lacks("lead balance: continue ends the pause reminder", balance_month.hook("user-prompt", "bm1").stdout, "⏸ Lanewise")

# A balance also keeps a mixed spend/balance pause open across the spend reset.
balance_month.write("usage.jsonl", json.dumps({"kind": "run", "provider": "deepseek", "label": "deepseek",
    "project": "", "cost_usd": 96, "ts": iso(now())}) + "\n")
balance_month.run("watch", "answer", "pause", sid="bm2")
answer = balance_month.entry("bm2").get("answer") or {}
check(answer.get("until") is None and answer.get("balance")
      and len(answer.get("limits") or []) == 2,
      "lead balance: a simultaneous spend risk cannot impose a pause reset", answer)

# ── the home lock: a read never asks for it, a write that cannot take it skips, and the next hook retries ────────
# The behaviour is proven in process — the lock acquisition is replaced by one that records each call and reports
# busy at once — so the checks do not depend on how fast this machine starts a process or takes a lock.
BUSY_LOCK = """
calls = []
def busy(path, wait=None):
    calls.append((str(path), wait))
    raise m.StateError('busy')
m.state_lock = busy
"""
locked_scene = Scene("home-lock")
write_snapshot(locked_scene, five=10)
locked_scene.hook("session-start", "lock1")
p = locked_scene.run(code=LOAD_ORCH + BUSY_LOCK + """
assert m.watch_event('lock1', 'user-prompt') is None, 'an event with nothing to record'
assert not calls, calls
""")
check(p.returncode == 0 and not p.stdout and not p.stderr,
      "home lock: a watcher read with nothing to record never requests the lock", p.stdout + p.stderr)
write_snapshot(locked_scene, five=82, history=[(45, 70)])
p = locked_scene.run(code=LOAD_ORCH + BUSY_LOCK + """
assert m.watch_event('lock2', 'user-prompt') is None, 'a due write with the lock busy'
assert len(calls) == 1 and calls[0][0].endswith('state.lock'), calls
assert not (m.watch_state(recover=False)['sessions'].get('lock2') or {}).get('asked'), 'no asked recorded'
""")
check(p.returncode == 0 and not p.stdout and not p.stderr,
      "home lock: a due write skips silently when the lock is busy", p.stdout + p.stderr)

# End to end: a real competing process holds the lock; the hook must exit 0 silently rather than hang (generous bound).
holder_code = LOAD_ORCH + """
lock = m.state_lock(m.ORCH_HOME / '.state.lock')
lock.__enter__()
print('ready', flush=True)
sys.stdin.read()
"""
holder_env = dict(BASE_ENV, ORCH_HOME=str(locked_scene.home), ORCH_PROJECT_DIR=str(locked_scene.project), ORCH_BALANCE="off")
holder = subprocess.Popen([PY, "-B", "-c", holder_code, ORCH], env=holder_env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    check(holder.stdout.readline().strip() == b"ready", "home lock: competing process is holding the lock")
    start = time.monotonic()
    p = locked_scene.hook("user-prompt", "lock2")
    check(p.returncode == 0 and not p.stdout and not p.stderr and time.monotonic() - start < 15,
          "home lock: a prompt with a risk never hangs or prints an error", p.stdout + p.stderr)
finally:
    holder.communicate(input=b"", timeout=5)
has("home lock: the next hook retries once the lock is free", locked_scene.hook("user-prompt", "lock2").stdout, "⚠ Lanewise:")

# Race the unlocked decisions: only one hook may commit the question or the pause-over event.
race = Scene("event-race")
write_snapshot(race, five=82, history=[(45, 70)])
race_code = LOAD_ORCH + """
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
original = m.watch_record
barrier = Barrier(2)
# Threads share the process's reentrant-lock map: serialize only the actual lock acquisition for this test.
from threading import Lock
mutex = Lock()
def record_serial(*args, **kwargs):
    barrier.wait(timeout=5)
    with mutex:
        return original(*args, **kwargs)
m.watch_record = record_serial
with ThreadPoolExecutor(max_workers=2) as pool:
    events = list(pool.map(lambda _: m.watch_event('race1', 'user-prompt'), range(2)))
assert sum(bool(e) for e in events) == 1, events
"""
p = race.run(code=race_code)
check(p.returncode == 0 and not p.stderr, "home lock: concurrent decisions give the question once", p.stdout + p.stderr)
race.run("watch", "answer", "pause", sid="race1")
race.backdate("race1", 2, field="until", sub="answer")
p = race.run(code=race_code + "assert any('pause is over' in (e or '') for e in events)\n")
check(p.returncode == 0 and not p.stderr, "home lock: concurrent decisions give the pause-over event once", p.stdout + p.stderr)

cached_lead = lead_spend_scene("lead-cached-pace", "month")
cached_lead.write("usage.jsonl", json.dumps({"kind": "run", "provider": "deepseek", "label": "deepseek",
    "project": "", "cost_usd": 96, "ts": iso(now())}) + "\n")
cached_lead.run("watch")              # the existing spend code maintains its records cache
cache_code = LOAD_ORCH + """
original = m.spend_rates
calls = []
def rates(*args, **kwargs):
    assert not m._held_locks, m._held_locks
    calls.append(1)
    return original(*args, **kwargs)
m.spend_rates = rates
def no_refresh():
    raise AssertionError('a watcher hook must not scan the ledger under the home lock')
m.spend_cache_update = no_refresh
assert m.watch_event('cache1', 'user-prompt')
assert m.watch_event('cache2', 'user-prompt')
assert len(calls) == 1, calls
"""
p = cached_lead.run(code=cache_code)
check(p.returncode == 0 and not p.stderr,
      "lead pace: hooks aggregate cached spend outside locks at most once per two minutes", p.stdout + p.stderr)
balance_code = LOAD_ORCH + """
item = m.watch_balance('deepseek', 20, 'USD', 80, 100, m.now() - m.dt.timedelta(days=10),
                       m.now() + m.dt.timedelta(minutes=10), [(0.2, 'recent spend', 4320)], m.WATCH_DEFAULTS)
assert item['risk'] and item['reset'] is None and not item['early'], item
"""
p = cached_lead.run(code=balance_code)
check(p.returncode == 0 and not p.stderr,
      "lead balance: exhaustion within two hours is a risk across the spend reset", p.stdout + p.stderr)
cold_lead = lead_spend_scene("lead-cold-prompt", "month")
cold_lead.write("usage.jsonl", json.dumps({"kind": "run", "provider": "deepseek", "label": "deepseek",
    "project": "", "cost_usd": 96, "ts": iso(now())}) + "\n")
has("lead pace: the first prompt populates the spend cache before checking risk",
    cold_lead.hook("user-prompt", "cold1").stdout, "⚠ Lanewise:")

# An aggregate spend cache entry of another shape is stale, not a crash: the limits are recomputed from the ledger.
cache_shape = lead_spend_scene("lead-cache-shape", "month")
shape_code = LOAD_ORCH + """
config, _ = m.load_spend_limits()
start = m.counter_start(config, 'deepseek', m.project_dir())
key = m.json.dumps(['deepseek', m.spend_where(m.project_dir()), config, m.iso(start)], sort_keys=True)
m.write_json(m.WATCH_SPEND_FILE, {key: {'at': m.iso(m.now())}})
"""
p = cache_shape.run(code=shape_code)
check(p.returncode == 0 and not p.stderr, "lead cache: a malformed aggregate entry is written", p.stdout + p.stderr)
p = cache_shape.run("watch")           # also populates the spend records cache the hook then reads
check(p.returncode == 0 and not p.stderr and "At risk now: nothing." in p.stdout,
      "lead cache: a malformed aggregate entry does not crash orch watch", p.stdout + p.stderr)
p = cache_shape.hook("user-prompt", "mc1")
check(p.returncode == 0 and not p.stdout.strip() and not p.stderr.strip(),
      "lead cache: a malformed aggregate entry keeps the hook silent", p.stdout + p.stderr)
try:
    cached = json.loads((cache_shape.home / ".watch-spend.json").read_text(encoding="utf-8"))
except (OSError, ValueError):
    cached = {}
entry = next(iter(cached.values()), None)
check(isinstance(entry, dict) and isinstance(entry.get("spent"), (int, float))
      and isinstance(entry.get("rates"), list),
      "lead cache: a malformed aggregate entry is recomputed", cached)

# ── the settings live in the claude profile and are validated ────────────────────────────────────────────────────
settings = Scene("settings")
p = settings.run("profile", "set", "claude", "q", "--opt", "watch=maybe")
check(p.returncode != 0 and "on|off" in p.stderr, "watch=maybe is refused", p.stderr)
p = settings.run("profile", "set", "claude", "q", "--opt", "watch_horizon_h=0")
check(p.returncode != 0 and "must be a number" in p.stderr, "watch_horizon_h=0 is refused", p.stderr)
p = settings.run("profile", "set", "claude", "q", "--opt", "watch_ask_again_step=10")
check(p.returncode == 0, "watch_ask_again_step=10 is accepted", p.stderr)

# ── SessionEnd removes the session's answer ──────────────────────────────────────────────────────────────────────
end = Scene("end")
write_snapshot(end, five=82, history=[(45, 70)])
end.run("watch", "answer", "continue", sid="e1")
check("e1" in (end.state().get("sessions") or {}), "session-end: the answer is recorded first", end.state())
end.hook("session-end", "e1")
check("e1" not in (end.state().get("sessions") or {}), "session-end: the session loses its answer", end.state())
LEAD_WATCH_TEST
); lw_rc=$?
while IFS= read -r lw_line; do
  case "$lw_line" in
    "OK "*) ok "${lw_line#OK }" ;;
    "NO "*) bad "${lw_line#NO }" ;;
    "") ;;
    *) printf '%s\n' "$lw_line" ;;
  esac
done <<<"$lw_out"
[[ $lw_rc -eq 0 ]] && ok "lead-watch checks completed" || bad "lead-watch checks aborted (rc=$lw_rc)"
