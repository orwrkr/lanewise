echo "── Claude budget (statusline → surplus / tight)"
# standalone setup (a no-op once the earlier sections have run)
mkdir -p "$T/claude-cfg"
now=$($PY -c "import time; print(int(time.time()))")
sl() { printf '{"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s}%s}}' \
         "$1" "$2" "${3:-}" | $ORCH statusline; }
week() { printf ',"seven_day":{"used_percentage":%s,"resets_at":%s}' "$1" "$((now + 259200))"; }
out=$(echo '{}' | $ORCH statusline); rc=$?; [[ $rc -eq 0 && -n "$out" ]] && ok "statusline works without rate_limits" || bad "statusline: rc=$rc"
out=$(echo 'garbage' | $ORCH statusline); expect_rc 0 $? "statusline survives garbage input"
out=$($ORCH budget); contains "$out" "No current Claude subscription numbers" "budget: no numbers yet"
out=$(sl 10 $((now + 7200)) "$(week 40)")
contains "$out" "Claude Opus 5.5 · 5h 10% → .* · week 40% .*surplus: Claude first" "statusline shows the usage and the surplus mode"
[[ -f "$ORCH_HOME/claude_usage.json" ]] && ok "statusline keeps the snapshot in ORCH_HOME" || bad "no snapshot"
out=$($ORCH status); contains "$out" "SURPLUS: at the current pace (window average) about 7[0-9]% of the window would expire unused beyond the reserve" "status: surplus beyond the reserve, projected from the pace"
out=$(echo '{}' | $ORCH hook session-start); contains "$out" "Claude subscription: 5-hour window 10% used" "session-start shows the budget"
out=$(echo '{}' | $ORCH hook user-prompt); grep -q "Claude subscription" <<<"$out" && bad "budget re-announced" || ok "the mode shown at session start is not repeated"
sl 80 $((now + 7200)) >/dev/null
out=$(echo '{}' | $ORCH hook user-prompt); contains "$out" "💡 Claude subscription:" "budget mode event marker"
contains "$out" "5-hour window 80% used.*TIGHT" "a mode change → event (tight)"
out=$(echo '{}' | $ORCH hook user-prompt); grep -q "Claude subscription" <<<"$out" && bad "event repeated" || ok "a mode change is announced once"
$ORCH budget clear >/dev/null     # usage never goes down within a window: a lower reading needs a fresh snapshot
sl 10 $((now + 7200)) "$(week 95)" >/dev/null
out=$($ORCH budget); contains "$out" "weekly limit is tight" "no surplus while the weekly limit is tight"
$ORCH budget clear >/dev/null
sl 10 $((now + 17400)) >/dev/null
out=$($ORCH budget); grep -q "SURPLUS\|TIGHT" <<<"$out" && bad "projected too early: $out" || ok "no projection in the window's first hour"
$PY - "$(native "$ORCH_HOME/claude_usage.json")" <<'EOF'   # a stored window that has reset since (a reading of one is not saved)
import datetime as dt, json, sys
t = dt.datetime.now().astimezone()
json.dump({"updated": t.isoformat(timespec="seconds"), "source": "statusline",
           "five_hour": {"used": 10.0, "resets_at": (t - dt.timedelta(minutes=1)).isoformat(timespec="seconds")}},
          open(sys.argv[1], "w", encoding="utf-8"))
EOF
out=$($ORCH budget); contains "$out" "No current Claude subscription numbers" "numbers of a window that has reset are ignored"
sl 10 $((now + 7200)) >/dev/null
$ORCH profile set claude main --opt surplus=off >/dev/null && $ORCH profile use claude main >/dev/null
out=$($ORCH budget); grep -q "SURPLUS" <<<"$out" && bad "surplus=off ignored" || ok "profile surplus=off switches the mode off"
$ORCH profile set claude main --opt surplus=90 >/dev/null
out=$($ORCH budget); grep -q "SURPLUS" <<<"$out" && bad "threshold ignored" || ok "profile surplus=N sets the threshold"
$ORCH profile set claude main --opt surplus=200 >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "surplus out of range refused" || bad "surplus=200 accepted"
rm -f "$ORCH_HOME/profiles.json"
$ORCH budget set --used 20 --resets +3h --week 50 >/dev/null
out=$($ORCH budget); contains "$out" "20% used.*reported by the operator.*SURPLUS" "numbers reported by the operator"
out=$(echo '{}' | $ORCH statusline --then "echo mine"); contains "$out" "^mine  " "statusline --then keeps your own status line first"
# reserve and the pace of all sessions: snap USED [BASE_USED MINUTES_AGO] — window resets in 2 h (SNAP_LEFT minutes),
# optional sample
snap() { $PY - "$(native "$ORCH_HOME/claude_usage.json")" "$@" <<'EOF'
import datetime as dt, json, os, sys
p, used = sys.argv[1], float(sys.argv[2])
t = dt.datetime.now().astimezone()
reset = (t + dt.timedelta(minutes=int(os.environ.get("SNAP_LEFT", "120")))).isoformat(timespec="seconds")
s = {"updated": t.isoformat(timespec="seconds"), "source": "statusline", "five_hour": {"used": used, "resets_at": reset}}
if len(sys.argv) > 3:
    s["history"] = [[(t - dt.timedelta(minutes=int(sys.argv[4]))).isoformat(timespec="seconds"), float(sys.argv[3]), reset]]
json.dump(s, open(p, "w", encoding="utf-8"))
EOF
}
snap 50
out=$($ORCH budget); grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "50% after 3 h: $out" || ok "default reserve: 50% after 3 h is neither tight nor surplus"
$ORCH profile set claude r --opt reserve=20 >/dev/null && $ORCH profile use claude r >/dev/null
out=$($ORCH budget); contains "$out" "reserve 20%.*TIGHT: at the current pace (window average) it reaches the reserve" "a larger reserve turns the same pace tight"
$ORCH profile set claude r --opt reserve=95 >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "reserve out of range refused" || bad "reserve=95 accepted"
rm -f "$ORCH_HOME/profiles.json"
snap 35
out=$($ORCH budget); contains "$out" "SURPLUS: at the current pace (window average)" "35% after 3 h at the window average: surplus"
snap 35 10 40
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (last 4[0-9] min, all sessions)" "the recent pace of all sessions wins: 10% → 35% in 40 min is tight"
# early in the window a projection is too thin to act on: a five-hour projection needs 60 minutes of the window
# behind it, the recent pace a base sample at least 30 minutes old; a used share at the reserve is TIGHT at once
SNAP_LEFT=270 snap 5 0 15
out=$($ORCH budget); contains "$out" "5-hour window 5% used" "early window: the line is shown"
grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "5% used, a 15-min burst, 30 min in: $out" || ok "30 min in: a short burst is not projected over the window"
SNAP_LEFT=241 snap 40
out=$($ORCH budget); grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "59 min in: $out" || ok "59 min in: the window average is not yet a projection"
SNAP_LEFT=239 snap 40
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (window average)" "61 min in: the window average projects, and 40% is tight"
SNAP_LEFT=255 snap 1
out=$($ORCH budget); grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "45 min in, 1% used: $out" || ok "45 min in: no surplus from a window too young to project"
SNAP_LEFT=225 snap 1
out=$($ORCH budget); contains "$out" "SURPLUS: at the current pace (window average)" "75 min in: the same light use is a surplus"
SNAP_LEFT=210 snap 20 5 15
out=$($ORCH budget); grep -q "TIGHT" <<<"$out" && bad "a 15-min sample at 90 min in: $out" || ok "90 min in: a base sample under 30 min old gives no recent pace"
SNAP_LEFT=210 snap 40 10 40
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (last 4[0-9] min, all sessions) it reaches the reserve" "90 min in: a squeeze measured over 40 min is tight"
SNAP_LEFT=290 snap 95
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (used share) the reserve is already reached" "10 min in: a used share over the reserve is tight at once"
# the consumers: Claude Code sessions (hooks, status line), Claude executor runs; a DeepSeek-led session doesn't count
rm -f "$ORCH_HOME/sessions.json"
echo '{"session_id": "s-a"}' | $ORCH hook user-prompt >/dev/null
echo '{"session_id": "s-b"}' | $ORCH hook user-prompt >/dev/null
echo '{"session_id": "s-lead"}' | ORCH_LEAD=deepseek $ORCH hook user-prompt >/dev/null
snap 10
out=$($ORCH budget); contains "$out" "active: 2 sessions" "active sessions counted, a DeepSeek-led one not"
contains "$out" "≈3[0-9]% for each of the 2 sessions" "the surplus is shared between the sessions"
contains "$out" "s-a .*session" "budget lists the active consumers"
out=$(printf '{"session_id": "s-c", "rate_limits": {"five_hour": {"used_percentage": 10, "resets_at": %s}}}' "$((now + 7200))" | $ORCH statusline)
contains "$out" "3 sessions" "the status line marks its session as a consumer"
echo '{"session_id": "s-b"}' | $ORCH hook session-end >/dev/null
out=$($ORCH budget); contains "$out" "active: 2 sessions" "SessionEnd removes the session"
FAKE_CLAUDE=ok $ORCH run claude --model haiku "x" >/dev/null
check 'any(v.get("kind") == "executor" for v in r["sessions"].values())' "a running Claude executor counts as a consumer"
grep -q '"executor"' "$ORCH_HOME/sessions.json" && bad "finished run still listed" || ok "the run leaves the consumer list when it ends"
rm -f "$ORCH_HOME/sessions.json"
$ORCH budget clear >/dev/null

# a session waiting on its own orch run: the run refreshes a session orch already knows, whatever the provider,
# and never creates one; the refreshes stop with the run, so the session ages out as usual afterwards
wait_home="$T/home-wait"; mkdir -p "$wait_home"
saved_home="$ORCH_HOME"; export ORCH_HOME="$wait_home"
# stale_session KEY MINUTES_AGO — a known Claude session last seen that long ago
stale_session() { $PY - "$(native "$ORCH_HOME/sessions.json")" "$1" "$2" <<'EOF'
import datetime as dt, json, sys
t = dt.datetime.now().astimezone() - dt.timedelta(minutes=int(sys.argv[3]))
json.dump({sys.argv[2]: {"seen": t.isoformat(timespec="seconds"), "since": t.isoformat(timespec="seconds"),
                         "kind": "session", "lead": None, "project": "/nowhere"}},
          open(sys.argv[1], "w", encoding="utf-8"))
EOF
}
# fresh_session KEY — the session was refreshed within the last minute
fresh_session() { $PY - "$(native "$ORCH_HOME/sessions.json")" "$1" <<'EOF'
import datetime as dt, json, sys
e = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2]) or {}
try:
    seen = dt.datetime.fromisoformat(e.get("seen") or "")
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if (dt.datetime.now().astimezone() - seen).total_seconds() < 60 else 1)
EOF
}
stale_session s-wait 20
snap 10
out=$($ORCH budget)
lacks "$out" "s-wait" "a session last seen 20 minutes ago is not active"
# the fake executor runs a few seconds: by the time it started, the launching session is already refreshed
FAKE_CODEX=slow CLAUDE_CODE_SESSION_ID=s-wait $ORCH run codex "wait for me" >"$T/wait-run.out" 2>&1 &
wait_pid=$!
for _ in $(seq 1 100); do fresh_session s-wait && break; sleep 0.1; done
out=$($ORCH budget)
contains "$out" "active: 1 session" "a session waiting on its run is counted as active"
contains "$out" "s-wait .*session" "orch budget lists the waiting session"
wait "$wait_pid"; expect_rc 0 $? "the waiting run finishes normally"
# the beat repeats through the run (in process: the poll interval and the write throttle are patched, so it takes
# seconds rather than a minute); a long run keeps writing, not just the reading at its start
stale_session s-wait 20
out=$(FAKE_CODEX=slow $PY -B - "$PLUGIN/bin/orch" 2>&1 <<'EOF'
import importlib.machinery, importlib.util, os, sys, time
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
m.SPEND_POLL_SECONDS = 0.2      # polls 75 times as often as a real run
m.HEARTBEAT_MIN_SECONDS = 0     # every poll writes, instead of at most once a minute
beats, orig = [], m.heartbeat
def beat(key, where=None, kind="session"):
    out = orig(key, where, kind)
    beats.append((key, time.time(), (m.read_json(m.SESSIONS_FILE, {}).get(key) or {}).get("seen")))
    return out
m.heartbeat = beat
os.environ["CLAUDE_CODE_SESSION_ID"] = "s-wait"
assert m.main(["run", "codex", "x"]) == 0
assert len(beats) >= 3 and all(k == "s-wait" for k, _, _ in beats), beats
assert max(t for _, t, _ in beats) - min(t for _, t, _ in beats) > 0.5, beats
assert len({seen for _, _, seen in beats}) >= 2, beats
print("periodic")
EOF
); rc=$?
[[ $rc -eq 0 && "$out" == *periodic* ]] && ok "the run refreshes its session periodically, not once" || { bad "no periodic refresh"; echo "$out"; }
# a session orch has never seen: no entry is invented
rm -f "$ORCH_HOME/sessions.json"
FAKE_CODEX=ok CLAUDE_CODE_SESSION_ID=s-unknown $ORCH run codex "x" >/dev/null 2>&1
expect_rc 0 $? "a run from an unknown session succeeds"
[[ ! -e "$ORCH_HOME/sessions.json" ]] && ok "a run from an unknown session creates no consumer" || { bad "the run invented a session"; cat "$ORCH_HOME/sessions.json"; }
# no session id at all: nothing written
stale_session s-other 20
cp "$ORCH_HOME/sessions.json" "$T/sessions-before.json"
CLAUDE_CODE_SESSION_ID= ORCH_SESSION_ID= FAKE_CODEX=ok $ORCH run codex "x" >/dev/null 2>&1
expect_rc 0 $? "a run with no session id succeeds"
cmp -s "$ORCH_HOME/sessions.json" "$T/sessions-before.json" && ok "a run with no session id writes nothing" || bad "sessions.json changed without a session id"
# a broken sessions.json: the run is unaffected (the refresh skips it, the file is preserved by read_json)
printf '{broken' > "$ORCH_HOME/sessions.json"
out=$(FAKE_CODEX=ok CLAUDE_CODE_SESSION_ID=s-broken $ORCH run codex "x" 2>&1); rc=$?
expect_rc 0 $rc "a broken sessions.json does not fail the run"
contains "$out" "\[OK\] cod-" "the run's report is unchanged"
# a busy home lock: the beat skips that poll and the run goes on (the lock is busy only at the beat's wait=0)
out=$($PY -B - "$PLUGIN/bin/orch" 2>&1 <<'EOF'
import contextlib, importlib.machinery, importlib.util, io, os, sys
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
real_lock = m.state_lock
def lock(path, wait=None):
    if wait == 0.0:                 # the beat's own non-blocking attempt: another process holds the home lock
        raise m.StateError("shared state busy")
    return real_lock(path, wait)
m.state_lock = lock
os.environ["CLAUDE_CODE_SESSION_ID"] = "s-locked"
report = io.StringIO()
with contextlib.redirect_stdout(report):
    rc = m.main(["run", "codex", "x"])
assert rc == 0, rc
assert "[OK] cod-" in report.getvalue(), report.getvalue()
print("ran")
EOF
); rc=$?
[[ $rc -eq 0 && "$out" == *ran* ]] && ok "a busy home lock does not fail or change the run" || { bad "a busy lock broke the run"; echo "$out"; }
rm -f "$ORCH_HOME/sessions.json" "$ORCH_HOME/claude_usage.json"
export ORCH_HOME="$saved_home"

# a single active session still shows "1 session" (never hidden); a headless sdk-* entrypoint does not register
rm -f "$ORCH_HOME/sessions.json" "$ORCH_HOME/claude_usage.json"
echo '{"session_id": "s-one"}' | $ORCH hook user-prompt >/dev/null
out=$(sl 10 $((now + 7200)))
contains "$out" "Claude Opus 5.5 · 5h 10% → .* · 1 session" "the Claude line shows a single session as 1 session"
rm -f "$ORCH_HOME/sessions.json"
snap 10
echo '{"session_id": "s-sdk"}' | CLAUDE_CODE_ENTRYPOINT=sdk-cli $ORCH hook user-prompt >/dev/null
out=$($ORCH budget); grep -q "s-sdk" <<<"$out" && bad "sdk-cli entrypoint registered as a consumer" || ok "an sdk-* entrypoint does not register as a consumer"
echo '{"session_id": "s-cli"}' | CLAUDE_CODE_ENTRYPOINT=cli $ORCH hook user-prompt >/dev/null
out=$($ORCH budget); contains "$out" "s-cli" "a cli entrypoint registers as a consumer"
rm -f "$ORCH_HOME/sessions.json"
$ORCH budget clear >/dev/null

# a status line reading lower than the stored one of the same window is a stale session's: dropped, never saved;
# usage_assert EXPR MESSAGE evaluates EXPR against the snapshot `s`; usage_age backdates the snapshot's measurement
# times (and its samples to an hour ago) so that an unwanted write would show
