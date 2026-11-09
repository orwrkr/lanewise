# needs: 30-account-balances
echo "── per-session account budgets (isolated home and the fake balance endpoint)"
bal_start || die "no fake balance server for session budgets"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$T/session-budget")" "$BANS" "$BURL" <<'SESSION_BUDGET_TEST'
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest import mock

orch, root, answers, url = sys.argv[1:]
root = Path(root)
home, project = root / "home", root / "work"
home.mkdir(parents=True)
project.mkdir()
(home / "adapters").mkdir()
(home / "adapters" / "deepseek").write_text(
    '#!/usr/bin/env python3\n# orch-secrets: DEEPSEEK_API_KEY\n'
    'import os\nfrom pathlib import Path\n'
    'Path(os.environ["ORCH_OUTPUT_FILE"]).write_text("STATUS: DONE\\n" + os.environ["ORCH_PROFILE"])\n',
    encoding="utf-8")
(home / "secrets.env").write_text("BUDGET_KEY=sk-fake-client\nPERSONAL_KEY=sk-fake-personal\n", encoding="utf-8")
env = dict(os.environ, ORCH_HOME=str(home), ORCH_PROJECT_DIR=str(project), ORCH_SESSION_ID="budget-one",
           ORCH_BALANCE="on", ORCH_DEEPSEEK_BALANCE_URL=url, NO_PROXY="127.0.0.1", no_proxy="127.0.0.1",
           PYTHONUTF8="1", CODEX_HOME=str(root / "no-codex"))
for key in ("ORCH_WORKER", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR", "ORCH_PROFILES", "ORCH_USAGE_LOG"):
    env.pop(key, None)


def call(*args, **kwargs):
    e = dict(env)
    for key, value in kwargs.pop("env", {}).items():
        if value is None:
            e.pop(key, None)
        else:
            e[key] = value
    rc = kwargs.pop("rc", 0)
    p = subprocess.run([sys.executable, orch] + list(args), input=kwargs.pop("stdin", ""),
                       env=e, encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    assert p.returncode == rc, (args, p.returncode, p.stdout)
    assert "Traceback" not in p.stdout, p.stdout
    return p.stdout


def answer(amount=15.5, fail=False):
    Path(answers).write_text(json.dumps({"sk-fake-client": {"total": str(amount), "status": 500 if fail else 200},
                                       "sk-fake-personal": {"total": "50"}}), encoding="utf-8")


def fetch(amount):
    answer(amount)
    call("balance", "deepseek@client")


def hook(**kwargs):
    return call("hook", "user-prompt", stdin='{"session_id":"budget-one"}', **kwargs)


def shown(**kwargs):
    return json.loads(call("profile", "show", "--json", **kwargs))["providers"]["deepseek"]


def run(*args, **kwargs):
    return call("run", "deepseek", *args, "budget check", **kwargs)


def baseline(sid="budget-one"):
    return json.loads((home / "session_budget.json").read_text())["deepseek@client"][sid]


call("profile", "set", "deepseek", "personal", "--key", "PERSONAL_KEY")
out = call("profile", "set", "deepseek", "client", "--key", "BUDGET_KEY", "--session-soft", "30",
           "--session-hard", "90", "--balance-floor", "1", "--fallback", "personal", "--default")
assert "session budget: soft 30%, hard 90%, floor $1" in out, out
assert shown()["profile"] == "client"  # no first figure is not exhaustion
for option, value in (("--session-soft", "0"), ("--session-soft", "-1"), ("--session-soft", "101"), ("--session-hard", "0"),
                      ("--session-hard", "101"), ("--session-soft", "90"), ("--session-hard", "30"),
                      ("--balance-floor", "-1"), ("--balance-floor", "nan"), ("--session-hard", "inf"),
                      ("--session-soft", "bad")):
    call("profile", "set", "deepseek", "client", option, value, rc=1)
for option in ("--session-soft", "--session-hard", "--balance-floor"):
    assert "no balance API" in call("profile", "set", "codex", "client", option, "30", rc=1)
call("profile", "set", "deepseek", "fields", "--session-soft", "30", "--session-hard", "90", "--balance-floor", "0")
call("profile", "set", "deepseek", "fields", "--session-soft", "", "--session-hard", "", "--balance-floor", "")
fields = json.loads((home / "profiles.json").read_text())["providers"]["deepseek"]["profiles"]["fields"]
assert not any(f in fields for f in ("session_soft", "session_hard", "balance_floor"))
print("fields: set, shown, cleared; invalid percentages, ordering, floor and unsupported provider refused")

answer()
assert "client" in run()
assert baseline()["baseline"] == 15.5
fetch(15)
hook()
assert baseline()["baseline"] == 15.5 and baseline()["last"] == 15
hook(env={"ORCH_SESSION_ID": "budget-two"})
assert baseline("budget-two")["baseline"] == 15
hook(env={"ORCH_SESSION_ID": None})  # stdin supplies the same session id, including after compaction
assert baseline()["baseline"] == 15.5
fetch(10.85)  # exactly 30%: soft is strictly above, not at
hook()
assert shown()["profile"] == "client"
answer(10.8)
assert "personal" in run()  # fresh preflight itself moves before starting the fake adapter
out = hook()
assert "moved to personal" in out and "$4.70" in out and "$15.50" in out and "30.3%" in out, out
assert "moved to" not in hook()
other_event = hook(env={"ORCH_SESSION_ID": "budget-two"})
assert "returned to" not in other_event and "moved to" not in other_event, other_event
assert "moved to" not in hook()  # parallel sessions do not overwrite each other's transition state
assert shown()["profile"] == "personal" and shown()["fallback_cause"] == "session-soft"
assert shown()["session_budget"]["baseline"] == 15.5
assert "session: account down $4.70 of $15.50" in call("profile", "show")
assert "session: account down $4.70 of $15.50" in call("status")
assert "personal" in run()
call("profile", "set", "deepseek", "personal", "--balance-floor", "50")
assert "SESSION_BUDGET" in run(rc=75)  # the one-level fallback's own budget is enforced too
call("profile", "set", "deepseek", "personal", "--balance-floor", "")
print("baselines: isolated sessions and persistent baseline; show, status and run agree above soft; one move event")

call("budget", "set", "--used", "95", "--resets", "+2h")
out = hook()
assert "returned to client" in out and "Claude is TIGHT" in out and "$4.70" in out, out
assert shown()["profile"] == "client"
assert "returned to" not in hook()
call("budget", "clear")
assert "moved to personal" in hook()
call("budget", "set", "--used", "95", "--resets", "+2h")
fetch(1.55)  # exactly 90%, above the floor
hook()
assert shown()["fallback_cause"] == "session-hard"
fetch(1)
assert shown(env={"ORCH_SESSION_ID": None})["fallback_cause"] == "floor"
fetch(16)
out = hook()
assert "returned to client" in out and "topped up" in out and "$16.00" in out, out
assert baseline()["baseline"] == 16 and shown()["profile"] == "client"
assert "returned to" not in hook()
call("budget", "clear")
fetch(10)
assert "moved to personal" in hook()
fetch(16)  # a top-up to the same numeric baseline must still be announced as a top-up
assert "topped up" in hook()
fetch(10)
assert "moved to personal" in hook()
assert call("status").count("session: account down") == 1  # not repeated under the profiles
budget_file = home / "session_budget.json"
before = budget_file.stat().st_mtime_ns
hook()
assert budget_file.stat().st_mtime_ns == before  # hooks run after every tool call: no change, no write
balances = json.loads((home / "balances.json").read_text())
balances["deepseek@client"]["at"] = (dt.datetime.now().astimezone() - dt.timedelta(hours=5)).isoformat(timespec="seconds")
(home / "balances.json").write_text(json.dumps(balances), encoding="utf-8")
assert shown()["profile"] == "personal"  # an old figure can't clear a budget
answer(10, fail=True)
assert "personal" in run()  # the configured key's failed read doesn't stop a run on the fallback
assert shown()["profile"] == "personal"  # nor does it bring the project back
answer(18)
assert "DeepSeek@client" in run()  # a run reads the configured key first, so a top-up brings the project back
assert "topped up" in hook()
print("TIGHT: soft returns and reactivates; hard and no-session floor still move; top-up returns with figures")

call("profile", "set", "deepseek", "client", "--fallback", "none")
answer(fail=True)
out = run(rc=75)
assert "SESSION_BUDGET" in out and "no fresh balance" in out, out
assert json.loads((home / "usage.jsonl").read_text().splitlines()[-1])["status"] == "SESSION_BUDGET"
out = run(env={"ORCH_BALANCE": "off"})
assert out.count("warning: ORCH_BALANCE=off") == 1 and "[OK]" in out, out
answer(1)
assert "SESSION_BUDGET" in run(rc=75)
assert "SESSION_BUDGET" in run("--force", rc=75)
call("profile", "set", "deepseek", "client", "--fallback", "personal")
assert "SESSION_BUDGET" in run("--profile", "client", rc=75)
call("profile", "set", "deepseek", "client", "--fallback", "none")
fetch(20)
hook()
answer(13)
out = run()
assert "over its session budget" in out and "[OK]" in out, out
call("spend", "limit", "deepseek@client", "0")
assert "SPEND_LIMIT" in run(rc=75)
call("spend", "limit", "deepseek@client", "1000")
answer(1)
assert "SESSION_BUDGET" in run(rc=75)
print("preflight: failure, hard, explicit profile and force refuse; off and soft-only warn; spend limit remains independent")

# A corrupt baseline is never repaired into a fresh allowance by hooks or status.
answer(20)
baseline_path = home / "session_budget.json"
baseline_path.write_text("{broken", encoding="utf-8")
call("status")
hook()
assert baseline_path.read_text() == "{broken"
assert "SESSION_BUDGET" in run(rc=75)
baseline_path.unlink()
fetch(20)
hook()

# Pruning and top-ups of exactly 0.01; another session's record is preserved under the lock.
data = json.loads(baseline_path.read_text())
data["deepseek@client"]["old-session"] = dict(baseline(), at=(dt.datetime.now().astimezone() - dt.timedelta(days=8)).isoformat())
baseline_path.write_text(json.dumps(data), encoding="utf-8")
fetch(20.01)
hook()
assert baseline()["baseline"] == 20.01
assert "old-session" not in json.loads(baseline_path.read_text())["deepseek@client"]

sl_input = json.dumps({"session_id": "budget-one", "workspace": {"current_dir": str(project)}})
before = baseline_path.read_bytes(), baseline_path.stat().st_mtime_ns
with_fields = call("statusline", stdin=sl_input)
call("profile", "set", "deepseek", "client", "--session-soft", "", "--session-hard", "", "--balance-floor", "")
assert call("statusline", stdin=sl_input) == with_fields
assert (baseline_path.read_bytes(), baseline_path.stat().st_mtime_ns) == before
baseline_path.unlink()
call("profile", "set", "deepseek", "client", "--session-soft", "30", "--session-hard", "90", "--balance-floor", "1")
call("statusline", stdin=sl_input, env={"ORCH_SESSION_ID": None})
assert not baseline_path.exists()

# Exercise the recursion from both directions and prohibit all network/process/writes in the new status-line path.
os.environ.clear()  # exactly the hooks' environment: an inherited CLAUDE_CODE_SESSION_ID would be another session
os.environ.update(env)
loader = importlib.machinery.SourceFileLoader("session_budget_orch", orch)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.session_budget_hooks(project)
fetch(13)
call("profile", "set", "deepseek", "client", "--fallback", "personal", "--prefer-for", "tests")
call("budget", "set", "--used", "1", "--resets", "+2h")
m._exhaustion_memo.clear()
assert m.claude_budget(project)[0] == "surplus"
m._exhaustion_memo.clear()
assert m.resolve_profile("deepseek", project).name == "personal"
for field, value, cause in (("session_soft", 30, "session-soft"), ("session_hard", 30, "session-hard"),
                            ("balance_floor", 13, "floor")):
    p = m.Profile("deepseek", "client", {field: value}, "profile", True)
    assert m.session_budget_cause(p, project) == cause
cached = m.balance_cache()
with mock.patch.object(m, "balance_cache", return_value=dict(cached, **{"deepseek@client":
        dict(cached["deepseek@client"], error={"at": m.iso(m.now()), "message": "offline"})})):
    assert m.session_budget_cause(m.resolve_profile("deepseek", project, follow=False), project) == "session-soft"
with mock.patch.object(m, "balance_cache", return_value=dict(cached, **{"deepseek@client":
        dict(cached["deepseek@client"], at=m.iso(m.now() - dt.timedelta(hours=1)))})):
    assert m.session_budget_cause(m.resolve_profile("deepseek", project, follow=False), project) == "session-soft"
with mock.patch.object(m, "balance_cache", return_value=dict(cached, **{"deepseek@client":
        dict(cached["deepseek@client"], at="invalid")})):
    assert m.session_budget_cause(m.resolve_profile("deepseek", project, follow=False), project) is None
with mock.patch.object(m, "balance_refresh", side_effect=AssertionError("network")), \
        mock.patch.object(m, "write_json", side_effect=AssertionError("write")), \
        mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")):
    m._exhaustion_memo.clear()
    assert m.resolve_profile("deepseek", project).name == "personal"
    m.session_budget_figure(m.resolve_profile("deepseek", project, follow=False))
print("state/status line: corrupt file fails closed, pruning and cent top-up work; no baseline writes, network or subprocess; recursion guarded")

# A per-session fallback entry records its session and time once; a later hook neither repeats nor rewrites the file.
out = hook()
assert "moved to personal" in out, out
events_file = home / "spend_events.json"


def fallback_entries():
    return json.loads(events_file.read_text()).get("fallback") or {}


mine = [v for v in fallback_entries().values() if v.get("session") == "budget-one"]
assert len(mine) == 1 and mine[0].get("from") == "client" and mine[0].get("to") == "personal", mine
assert dt.datetime.fromisoformat(mine[0]["at"])
before = events_file.stat().st_mtime_ns
assert "moved to" not in hook()
assert events_file.stat().st_mtime_ns == before  # hooks run after every tool call: no change, no write

# Ending that session drops its entry only: another session's entry and a project-wide one stay.
state = json.loads(events_file.read_text())
state["fallback"]["project|deepseek|budget-two"] = {
    "from": "client", "to": "personal", "session": "budget-two",
    "at": dt.datetime.now().astimezone().isoformat(timespec="microseconds")}
state["fallback"]["project|deepseek"] = {"from": "client", "to": "personal"}
events_file.write_text(json.dumps(state), encoding="utf-8")
assert call("hook", "session-end", stdin='{"session_id":"budget-one"}') == ""
left = fallback_entries()
assert not any(v.get("session") == "budget-one" for v in left.values()), left
assert left.get("project|deepseek|budget-two", {}).get("session") == "budget-two", left
assert left.get("project|deepseek") == {"from": "client", "to": "personal"}, left

# Expiry: eight days old or undated per-session entries go at the next write; six days old and project-wide stay.
stamp = lambda days: (dt.datetime.now().astimezone() - dt.timedelta(days=days)).isoformat(timespec="microseconds")
state = json.loads(events_file.read_text())
for key, entry in (("project|deepseek|old", {"session": "old", "at": stamp(8)}),
                   ("project|deepseek|fresh", {"session": "fresh", "at": stamp(6)}),
                   ("project|deepseek|undated", {"session": "undated"})):
    state["fallback"][key] = dict(entry, **{"from": "client", "to": "personal"})
events_file.write_text(json.dumps(state), encoding="utf-8")
assert call("hook", "session-end", stdin='{"session_id":"nobody"}') == ""
left = fallback_entries()
assert "project|deepseek|old" not in left and "project|deepseek|undated" not in left, left
assert "project|deepseek|fresh" in left and "project|deepseek" in left, left

# Nothing to drop and nothing expired: session-end leaves the file alone.
before = events_file.stat().st_mtime_ns
assert call("hook", "session-end", stdin='{"session_id":"nobody"}') == ""
assert events_file.stat().st_mtime_ns == before

# fallback_event prunes expired entries too when it writes: this session lost its entry, so the move is news again.
state = json.loads(events_file.read_text())
state["fallback"]["project|deepseek|older"] = {"from": "client", "to": "personal",
                                               "session": "older", "at": stamp(8)}
events_file.write_text(json.dumps(state), encoding="utf-8")
assert "moved to personal" in hook()
assert "project|deepseek|older" not in fallback_entries()
print("fallback state: session and time recorded once; session-end drops only its entry; expired and undated entries go, fresh and project-wide stay")
SESSION_BUDGET_TEST
expect_rc 0 $? "session budget checks"
bal_stop
unset -f bal bal_answers bal_start bal_stop bal_count bal_ms bal_cache_get bal_age sl_bal
BWHERE=""; BURL=""

