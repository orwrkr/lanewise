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
