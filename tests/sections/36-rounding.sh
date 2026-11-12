# needs: 32-session-tokens
echo "── rounding"
# standalone setup (a no-op once the earlier sections have run): the status line helper of section 22
sl() { printf '{"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s}%s}}' \
         "$1" "$2" "${3:-}" | $ORCH statusline; }
now=$($PY -c "import time; print(int(time.time()))")
out=$(sl 82.6 $((now + 7200))); contains "$out" "5h 83%" "Claude status line rounds 82.6 → 83"
out=$($ORCH status); contains "$out" "Claude subscription: 5-hour window 83% used" "Claude subscription line rounds 82.6 → 83"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx9/sessions/2026/11/02/rollout-0001.jsonl")" 82.6 2 20 168
$PY - "$(native "$ORCH_HOME/codex_usage.json")" "$(native "$T/cx9")" <<'EOF'
import datetime as dt, json, sys
p, home = sys.argv[1], sys.argv[2]
d = json.load(open(p, encoding="utf-8"))
for entry in d.values():                  # let the once-a-minute refresh run again (keys are native paths)
    if isinstance(entry, dict) and entry.get("updated"):
        entry["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "Codex · 5h 83%" "codex status line rounds 82.6 → 83"
CODEX_HOME="$(native "$T/no-codex")"
# 82.6% used with 2 h left is a watched risk; leave no risky snapshot for the session-start size budget (section 38)
$ORCH budget clear >/dev/null

