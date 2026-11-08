echo "── Claude budget (a stale status line reading is not saved)"
# standalone setup (a no-op once the earlier sections have run): the status line helper of the previous section
sl() { printf '{"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s}%s}}' \
         "$1" "$2" "${3:-}" | $ORCH statusline; }
usage_assert() { $PY - "$(native "$ORCH_HOME/claude_usage.json")" "$1" <<'EOF' && ok "$2" || bad "$2"
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
assert eval(sys.argv[2], {"s": s}), s
EOF
}
usage_age() { $PY - "$(native "$ORCH_HOME/claude_usage.json")" <<'EOF'
import datetime as dt, json, sys
p = sys.argv[1]
s = json.load(open(p, encoding="utf-8"))
hour_ago = (dt.datetime.now().astimezone() - dt.timedelta(hours=1)).isoformat(timespec="seconds")
s["updated"] = "2020-01-01T00:00:00+00:00"
for k in ("five_hour", "seven_day"):
    s[k]["updated"] = s["updated"]
for k in ("history", "week_history"):
    for h in s.get(k, []):
        h[0] = hour_ago
json.dump(s, open(p, "w", encoding="utf-8"))
EOF
}
usage_len() { $PY - "$(native "$ORCH_HOME/claude_usage.json")" "$1" <<'EOF' | tr -d '\r'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]))
EOF
}
slw() { sl "$1" "$2" ",\"seven_day\":{\"used_percentage\":$3,\"resets_at\":$4}"; }   # slw FIVE_USED FIVE_RESET WEEK_USED WEEK_RESET
now=$($PY -c "import time; print(int(time.time()))")
R5=$((now + 7200)); RW=$((now + 259200))
$ORCH budget clear >/dev/null
slw 40 $R5 50 $RW >/dev/null                      # the stored numbers are a status line's
usage_age; h5=$(usage_len history); hw=$(usage_len week_history)
slw 30 $R5 45 $RW >/dev/null
usage_assert 's["five_hour"]["used"] == 40 and s["seven_day"]["used"] == 50' "stale: lower readings of both windows leave the stored usage alone"
usage_assert 's["updated"].startswith("2020") and s["five_hour"]["updated"].startswith("2020") and s["seven_day"]["updated"].startswith("2020")' "stale: the measurement times stay (all windows dropped, nothing written)"
usage_assert 'len(s["history"]) == '"$h5"' and len(s["week_history"]) == '"$hw"'' "stale: no history sample"
slw 30 $R5 60 $RW >/dev/null
usage_assert 's["five_hour"]["used"] == 40 and s["five_hour"]["updated"].startswith("2020") and len(s["history"]) == '"$h5"'' "stale: only the lower window is dropped from an update"
usage_assert 's["seven_day"]["used"] == 60 and not s["seven_day"]["updated"].startswith("2020")' "stale: the higher window of the same update is saved"
usage_age
slw 55 $R5 70 $RW >/dev/null
usage_assert 's["five_hour"]["used"] == 55 and s["seven_day"]["used"] == 70 and not s["five_hour"]["updated"].startswith("2020") and not s["seven_day"]["updated"].startswith("2020")' "a higher reading is saved"
usage_age; h5=$(usage_len history)
slw 1 $((now - 60)) 1 $((now - 60)) >/dev/null
usage_assert 's["five_hour"]["used"] == 55 and s["seven_day"]["used"] == 70 and s["updated"].startswith("2020") and len(s["history"]) == '"$h5"'' "stale: a reading of a window that has already reset is not saved"
slw 5 $((R5 + 18000)) 1 $((RW + 604800)) >/dev/null
usage_assert 's["five_hour"]["used"] == 5 and s["seven_day"]["used"] == 1 and not s["five_hour"]["updated"].startswith("2020") and len(s["history"]) == '"$h5"' + 1' "a lower reading for a new reset (a new window) is saved, with a sample"
usage_age
$ORCH budget set --used 2 --resets +7h --week 0.5 --week-resets +240h >/dev/null
usage_assert 's["five_hour"]["used"] == 2 and s["seven_day"]["used"] == 0.5 and s["source"] == "operator"' "a lower orch budget set is saved: the operator's report is a correction"
slw 1 $((now + 25200)) 0.2 $((now + 864000)) >/dev/null
usage_assert 's["five_hour"]["used"] == 1 and s["seven_day"]["used"] == 0.2 and s["source"] == "statusline"' "a status line reading replaces the operator's estimate, even a lower one"
$PY - "$(native "$ORCH_HOME/claude_usage.json")" <<'EOF'
import datetime as dt, json, sys
p = sys.argv[1]
t = dt.datetime.now().astimezone()
gone = (t - dt.timedelta(minutes=1)).isoformat(timespec="seconds")      # both windows have just reset
s = {"updated": "2020-01-01T00:00:00+00:00", "source": "statusline",
     "five_hour": {"used": 60.0, "resets_at": gone, "updated": "2020-01-01T00:00:00+00:00"},
     "seven_day": {"used": 70.0, "resets_at": gone, "updated": "2020-01-01T00:00:00+00:00"}}
json.dump(s, open(p, "w", encoding="utf-8"))
EOF
slw 5 $((now + 18000)) 3 $((now + 604800)) >/dev/null
usage_assert 's["five_hour"]["used"] == 5 and s["seven_day"]["used"] == 3 and not s["five_hour"]["updated"].startswith("2020")' "after the stored windows have reset, lower readings of the next ones are saved"
$ORCH budget clear >/dev/null

