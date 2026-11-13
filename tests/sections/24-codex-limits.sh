echo "── Codex subscription limits"
cat > "$T/gen_rollout.py" <<'EOF'
import datetime as dt, json, sys
path = sys.argv[1]
used5 = float(sys.argv[2]); r5h = float(sys.argv[3])
used7 = float(sys.argv[4]); r7h = float(sys.argv[5])
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": used5, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=r5h)).timestamp())},
        "secondary": {"used_percent": used7, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(hours=r7h)).timestamp())},
        "credits": {"has_credits": False}, "plan_type": "plus"}}})
open(path, "w", encoding="utf-8").write(ev + "\n")
EOF
cx_status() { printf '{"workspace":{"current_dir":"%s"}}' "$(native "$REPO")" | $ORCH statusline; }

# defensive parsing: a good event, then rate_limits:null, a garbage line, swapped windows, a cut last line
rm -rf "$T/cx1"; mkdir -p "$T/cx1/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx1")"
$PY - "$(native "$T/cx1/sessions/2026/11/02/rollout-0001.jsonl")" <<'EOF'
import datetime as dt, json, sys
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
def ev(t, primary, secondary):
    return json.dumps({"timestamp": iso(t), "type": "event_msg", "payload": {"type": "token_count",
        "rate_limits": {"limit_id": "codex", "primary": primary, "secondary": secondary,
        "credits": {"has_credits": False}, "plan_type": "plus"}}})
h2 = now + dt.timedelta(hours=2); d7 = now + dt.timedelta(days=7)
five = lambda used: {"used_percent": used, "window_minutes": 300, "resets_at": int(h2.timestamp())}
week = lambda used: {"used_percent": used, "window_minutes": 10080, "resets_at": int(d7.timestamp())}
lines = [
    ev(now - dt.timedelta(minutes=8), five(81.0), week(95.0)),
    json.dumps({"timestamp": iso(now - dt.timedelta(minutes=7)), "type": "event_msg",
                "payload": {"type": "token_count", "rate_limits": None}}),
    "this is not json",
    ev(now - dt.timedelta(minutes=2), week(20.0), five(30.0)),
    '{"timestamp": "' + iso(now) + '", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"primary": {"used_percent": 99.0, "window_minutes": 300, "resets_at": ' + str(int(h2.timestamp())) + '}',
]
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(lines))
EOF
out=$(cx_status); contains "$out" "Codex · 5h 30%" "codex status line: compact five-hour"
contains "$out" "week 20%" "codex status line: compact week"
out=$($ORCH status)
contains "$out" "Codex subscription: 5-hour window 30% used" "codex: five-hour window read from the swapped secondary slot"
contains "$out" "week 20%" "codex: week read from the swapped primary slot"

# a rollout larger than the tail size, newest event at the end
rm -rf "$T/cx2"; mkdir -p "$T/cx2/sessions/2026/11/01"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx2")"
$PY - "$(native "$T/cx2/sessions/2026/11/01/rollout-big.jsonl")" <<'EOF'
import datetime as dt, json, sys
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
filler = "\n".join(json.dumps({"type": "noise", "i": i}) for i in range(12000)) + "\n"
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": 50.0, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=2)).timestamp())},
        "secondary": {"used_percent": 60.0, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(days=7)).timestamp())},
        "plan_type": "plus"}}})
open(sys.argv[1], "w", encoding="utf-8").write(filler + ev + "\n")
EOF
size=$(wc -c < "$T/cx2/sessions/2026/11/01/rollout-big.jsonl")
[[ $size -gt 262144 ]] && ok "codex: rollout larger than the tail size ($size bytes)" || bad "codex: rollout too small ($size bytes)"
out=$(cx_status); contains "$out" "Codex · 5h 50%" "codex: newest event found in the tail of a large file"
contains "$out" "week 60%" "codex: week found in the tail of a large file"

# an expired window is dropped
rm -rf "$T/cx3"; mkdir -p "$T/cx3/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx3")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx3/sessions/2026/11/02/rollout-0001.jsonl")" 50 -1 40 168
out=$(cx_status); contains "$out" "week 40%" "codex: valid week window kept"
grep -q "5h" <<<"$out" && bad "codex: expired five-hour window still shown: $out" || ok "codex: expired five-hour window dropped"

# no rollouts at all: no line, no error
rm -rf "$T/cx4"; mkdir -p "$T/cx4"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx4")"
out=$(cx_status); rc=$?
[[ $rc -eq 0 ]] && ok "codex: no rollouts → statusline succeeds" || bad "codex: statusline rc=$rc"
grep -q "Codex" <<<"$out" && bad "codex: line shown with no rollouts: $out" || ok "codex: no rollouts → no line"
out=$($ORCH status); grep -q "Codex subscription" <<<"$out" && bad "codex: status shows a Codex line with no rollouts" || ok "codex: no Codex line in status"

# week over the reserve cap → TIGHT
rm -rf "$T/cx5"; mkdir -p "$T/cx5/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx5")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx5/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 95 168
out=$($ORCH status)         # no status line ran first: routing must not depend on one being configured
contains "$out" "Codex subscription: 5-hour window 10% used" "codex: orch status reads the limits by itself"
contains "$out" "week 95%" "codex: week over the cap in status"
contains "$out" "TIGHT: treat Codex as low" "codex: week over the cap → TIGHT"

# weekly projection counts only after 24 h of the week
rm -rf "$T/cx6a" "$T/cx6b"; mkdir -p "$T/cx6a/sessions/2026/11/02" "$T/cx6b/sessions/2026/11/02"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx6a/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 156
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx6b/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 143
export CODEX_HOME; CODEX_HOME="$(native "$T/cx6a")"
cx_status >/dev/null
out=$($ORCH status); grep -q "TIGHT: treat Codex as low" <<<"$out" && bad "codex: weekly projection before 24 h raised TIGHT: $out" || ok "codex: weekly projection before 24 h is ignored"
CODEX_HOME="$(native "$T/cx6b")"
cx_status >/dev/null
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: weekly projection after 24 h → TIGHT"

# the 💡 event fires once on a mode change
rm -rf "$T/cx7"; mkdir -p "$T/cx7/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx7")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx7/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 168
echo '{"session_id":"s-cx"}' | $ORCH statusline >/dev/null
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook session-start); contains "$out" "Codex subscription: 5-hour window 10% used" "codex: session-start shows the Codex line"
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook user-prompt); grep -q "Codex subscription" <<<"$out" && bad "codex: event before a mode change: $out" || ok "codex: no event while the mode is unchanged"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx7/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 95 168
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: cache aged past the refresh throttle" || bad "codex: could not age the cache"
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
echo '{"session_id":"s-cx"}' | $ORCH statusline >/dev/null
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook user-prompt); contains "$out" "💡 Codex subscription:" "codex: a mode change → 💡 event"
contains "$out" "TIGHT: treat Codex as low" "codex: the event names TIGHT"
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook user-prompt); grep -q "Codex subscription" <<<"$out" && bad "codex: event repeated" || ok "codex: a mode change is announced once"

# the cache is keyed per account (CODEX_HOME)
rm -rf "$T/cx8a" "$T/cx8b"; mkdir -p "$T/cx8a/sessions/2026/11/02" "$T/cx8b/sessions/2026/11/02"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx8a/sessions/2026/11/02/rollout-0001.jsonl")" 81 2 20 168
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx8b/sessions/2026/11/02/rollout-0001.jsonl")" 30 2 40 168
export CODEX_HOME; CODEX_HOME="$(native "$T/cx8a")"; cxA=$(cx_status)
CODEX_HOME="$(native "$T/cx8b")"; cxB=$(cx_status)
contains "$cxA" "Codex · 5h 81%" "codex: account A numbers"
contains "$cxB" "Codex · 5h 30%" "codex: account B numbers"
$PY - "$(native "$ORCH_HOME/codex_usage.json")" "$(native "$T/cx8a")" "$(native "$T/cx8b")" <<'EOF' && ok "codex: cache keyed per account" || bad "codex: cache not per account"
import json, sys
d = {k.replace("\\", "/"): v for k, v in json.load(open(sys.argv[1], encoding="utf-8")).items()}
a, b = sys.argv[2], sys.argv[3]
assert isinstance(d.get(a), dict) and isinstance(d.get(b), dict), list(d)
assert d[a]["five_hour"]["used"] == 81.0 and d[b]["five_hour"]["used"] == 30.0, d
EOF

# the model comes from a turn_context event in the same file as the limits; a known id is shown by its display name
cat > "$T/gen_rollout_tc.py" <<'EOF'
import datetime as dt, json, sys
path = sys.argv[1]; model = sys.argv[2]
used5 = float(sys.argv[3]); r5h = float(sys.argv[4])
used7 = float(sys.argv[5]); r7h = float(sys.argv[6])
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
tc = json.dumps({"timestamp": iso(now - dt.timedelta(minutes=3)), "type": "turn_context",
                 "payload": {"model": model, "effort": "medium"}})
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": used5, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=r5h)).timestamp())},
        "secondary": {"used_percent": used7, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(hours=r7h)).timestamp())},
        "credits": {"has_credits": False}, "plan_type": "plus"}}})
open(path, "w", encoding="utf-8").write(tc + "\n" + ev + "\n")
EOF
rm -rf "$T/cxmk" "$T/cxmu"; mkdir -p "$T/cxmk/sessions/2026/11/02" "$T/cxmu/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxmk")"
$PY "$(native "$T/gen_rollout_tc.py")" "$(native "$T/cxmk/sessions/2026/11/02/rollout-0001.jsonl")" gpt-6.1-sol 30 2 20 168
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 30%" "codex: a known model is shown by its display name"
CODEX_HOME="$(native "$T/cxmu")"
$PY "$(native "$T/gen_rollout_tc.py")" "$(native "$T/cxmu/sessions/2026/11/02/rollout-0001.jsonl")" my-custom-model-7b 30 2 20 168
out=$(cx_status); contains "$out" "my-custom-model-7b · 5h 30%" "codex: an unknown model id is shown as-is"

# a turn_context scrolled out of the tail keeps the last seen model
rm -rf "$T/cxr"; mkdir -p "$T/cxr/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxr")"
f="$(native "$T/cxr/sessions/2026/11/02/rollout-0001.jsonl")"
$PY "$(native "$T/gen_rollout_tc.py")" "$f" gpt-6.1-sol 30 2 20 168
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 30%" "codex: model seen while the turn_context is still in the tail"
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: cache aged for the retention re-scan" || bad "codex: could not age the cache"
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
$PY - "$f" <<'EOF'
import datetime as dt, json, sys
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
filler = "\n".join(json.dumps({"type": "noise", "i": i}) for i in range(12000)) + "\n"
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": 40.0, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=2)).timestamp())},
        "secondary": {"used_percent": 25.0, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(days=7)).timestamp())},
        "plan_type": "plus"}}})
open(sys.argv[1], "a", encoding="utf-8").write(filler + ev + "\n")
EOF
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 40%" "codex: model retained after the turn_context scrolled out of the tail"

# Codex's internal auto-review step writes turn_context events too: its model is not the one the operator works with
cat > "$T/gen_rollout_ar.py" <<'EOF'
import datetime as dt, json, sys
path = sys.argv[1]; models = sys.argv[2:]          # the turn_context models, in file order
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
lines = [json.dumps({"timestamp": iso(now - dt.timedelta(minutes=10 - i)), "type": "turn_context",
                     "payload": {"model": m, "effort": "medium"}}) for i, m in enumerate(models)]
lines.append(json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": 30.0, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=2)).timestamp())},
        "secondary": {"used_percent": 20.0, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(days=7)).timestamp())},
        "plan_type": "plus"}}}))
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
EOF
ar_home() { rm -rf "$T/$1"; mkdir -p "$T/$1/sessions/2026/11/02"; export CODEX_HOME; CODEX_HOME="$(native "$T/$1")"; }
ar_roll() { local h=$1; shift; $PY "$(native "$T/gen_rollout_ar.py")" "$(native "$T/$h/sessions/2026/11/02/rollout-0001.jsonl")" "$@"; }
ar_home cxar1; ar_roll cxar1 codex-auto-review
out=$(cx_status); contains "$out" "^Codex · 5h 30%" "codex: only the auto-review model in the rollout → just Codex"
lacks "$out" "auto-review" "codex: the auto-review model is not shown"
ar_home cxar2; ar_roll cxar2 gpt-6.1-sol codex-auto-review
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 30%" "codex: an auto-review turn after the real one keeps the real model"
lacks "$out" "auto-review" "codex: nothing of the auto-review turn shows after a real model"
ar_home cxar3; ar_roll cxar3 codex-auto-review my-custom-model-7b codex-auto-review
out=$(cx_status); contains "$out" "my-custom-model-7b · 5h 30%" "codex: the last real model is shown between auto-review turns"
ar_home cxar4; ar_roll cxar4 gpt-6.1-sol codex-auto-review gpt-6.1-terra
out=$(cx_status); contains "$out" "GPT-6.1 Terra · 5h 30%" "codex: a real model after an auto-review turn is shown"
# an entry saved by an older version holds the internal model: it is no model, on show and on every re-scan
rm -f "$ORCH_HOME/codex_usage.json"          # the seeding below touches every entry of the cache
ar_home cxar5; ar_roll cxar5 codex-auto-review
cx_status >/dev/null
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: stored entry set to the auto-review model" || bad "codex: could not seed the stored entry"
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["model"] = "codex-auto-review"
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "^Codex · 5h 30%" "codex: a stored auto-review model is shown as no model"
lacks "$out" "auto-review" "codex: nothing of the stored auto-review model shows"
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF'
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "^Codex · 5h 30%" "codex: a re-scan with no real model leaves no model"
lacks "$(cat "$ORCH_HOME/codex_usage.json")" "auto-review" "codex: a re-scan drops the stored auto-review model"

# a missing week (only the five-hour window) leaves the week part out
rm -rf "$T/cxmw"; mkdir -p "$T/cxmw/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxmw")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmw/sessions/2026/11/02/rollout-0001.jsonl")" 30 2 40 -1
out=$(cx_status); contains "$out" "Codex · 5h 30%" "codex: five-hour shown without a week"
grep -q "week" <<<"$out" && bad "codex: week shown when missing: $out" || ok "codex: no week part when the week window is missing"

# the same compact mode texts as Claude, from the codex windows
rm -rf "$T/cxmo1" "$T/cxmo2" "$T/cxmo3"; mkdir -p "$T/cxmo1/sessions/2026/11/02" "$T/cxmo2/sessions/2026/11/02" "$T/cxmo3/sessions/2026/11/02"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmo1/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 95 168
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmo2/sessions/2026/11/02/rollout-0001.jsonl")" 95 2 20 168
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmo3/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 143
export CODEX_HOME; CODEX_HOME="$(native "$T/cxmo1")"; out=$(cx_status)
contains "$out" "week 95%" "codex: over-reserve week in the line"
contains "$out" "tight: week over reserve" "codex: over-reserve mode text"
CODEX_HOME="$(native "$T/cxmo2")"; out=$(cx_status)
contains "$out" "tight: 5h" "codex: five-hour-tight mode text"
CODEX_HOME="$(native "$T/cxmo3")"; out=$(cx_status)
contains "$out" "(≈101%) · tight: week" "codex: the week's projection beside the window, not repeated in the mode text"

# a few minutes into a window its average is no projection: it needs 60 minutes of the window behind it, while a used
# share at the reserve is TIGHT at once
cx_early() {     # NAME USED_5H MINUTES_INTO_THE_WINDOW
  rm -rf "$T/$1"; mkdir -p "$T/$1/sessions/2026/11/02"
  export CODEX_HOME; CODEX_HOME="$(native "$T/$1")"
  $PY "$(native "$T/gen_rollout.py")" "$(native "$T/$1/sessions/2026/11/02/rollout-0001.jsonl")" "$2"       "$($PY -c "print((300 - $3) / 60)")" 2 168
}
cx_early cxe1 15 5
out=$($ORCH status); contains "$out" "Codex subscription: 5-hour window 15% used" "codex: 15% used 5 min after a reset is in the line"
lacks "$out" "TIGHT" "codex: 15% used 5 min after a reset is not TIGHT"
out=$(cx_status); contains "$out" "Codex · 5h 15%" "codex: 15% used 5 min after a reset in the compact text"
lacks "$out" "tight" "codex: 15% used 5 min after a reset has no mode in the compact text"
cx_early cxe2 50 55
out=$($ORCH status); lacks "$out" "TIGHT" "codex: 50% used 55 min in is still too early to project"
cx_early cxe3 50 65
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: 50% used 65 min in projects past the reserve → TIGHT"
out=$(cx_status); contains "$out" "tight: 5h" "codex: the projection past the reserve in the compact text"
cx_early cxe4 80 120
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: 80% used two hours in → TIGHT"
out=$(cx_status); contains "$out" "tight: 5h" "codex: 80% used two hours in, compact text"
cx_early cxe5 95 10
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: 95% used 10 min in → TIGHT at once"
out=$(cx_status); contains "$out" "tight: 5h" "codex: 95% used 10 min in, compact text"

# a measurement older than the freshness constant is marked stale on the codex line too
rm -rf "$T/cxs"; mkdir -p "$T/cxs/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxs")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxs/sessions/2026/11/02/rollout-0001.jsonl")" 30 2 20 168
cx_status >/dev/null
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: measurement aged for the stale check" || bad "codex: could not age the measurement"
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict):
        for w in ("five_hour", "seven_day"):
            if isinstance(v.get(w), dict) and "measured" in v[w]:
                v[w]["measured"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=25)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "stale:" "codex: a stale measurement is marked"

# Codex profile off → no line even with data
rm -rf "$T/cxoff"; mkdir -p "$T/cxoff/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxoff")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxoff/sessions/2026/11/02/rollout-0001.jsonl")" 81 2 20 168
out=$(cx_status); contains "$out" "Codex · 5h 81%" "codex: data present before switching off"
$ORCH profile use codex off >/dev/null
out=$(cx_status); grep -q "Codex" <<<"$out" && bad "codex: line shown while the profile is off: $out" || ok "codex: profile off → no line"
out=$($ORCH status); grep -q "Codex subscription" <<<"$out" && bad "codex: status line while the profile is off" || ok "codex: profile off → no Codex status line"
rm -f "$ORCH_HOME/profiles.json"

