echo "── fallback profile (an exhausted key hands its project to another profile)"
FDIR="$T/fb-home"; FH="$(native "$FDIR")"
FA="$(native "$T/fb-a")"; FB="$(native "$T/fb-b")"; FC="$(native "$T/fb-c")"; FD="$(native "$T/fb-d")"
mkdir -p "$FDIR" "$T/fb-a" "$T/fb-b" "$T/fb-c" "$T/fb-d"
printf 'FB_KEY_CLIENT=sk-client\nFB_KEY_PERS=sk-pers\nFB_KEY_PLAIN=sk-plain\nFB_KEY_X=sk-x\n' > "$FDIR/secrets.env"
printf '{"usd_per_1m_tokens": {"deepseek-v4-pro": {"input": 1.0, "cache_read": 0.0, "output": 0.0}}}' > "$FDIR/prices.json"
fb() { local d="$1"; shift; ORCH_HOME="$FH" ORCH_PROJECT_DIR="$d" $ORCH "$@"; }
fb_run() { local d="$1"; shift; FAKE_CLAUDE="${FAKE_CLAUDE:-ok}" fb "$d" run deepseek --model deepseek-v4-pro "$@"; }
fb_hook() { printf '{"session_id":"s-fb"}' | ORCH_HOME="$FH" ORCH_PROJECT_DIR="$1" $ORCH hook "$2"; }
fb_spent() { $PY - "$FDIR/usage.jsonl" "$1" "$2" <<'EOF'     # fb_spent <label> <usd>: a ledger run that cost that much
import datetime as dt, json, sys
rec = {"kind": "run", "provider": "deepseek", "label": sys.argv[2], "model": "deepseek-v4-pro", "billing": "api",
       "project": "fb-project", "cost_usd": float(sys.argv[3]),
       "usage": {"input_tokens": 1, "cached_input_tokens": 0, "output_tokens": 0},
       "ts": dt.datetime.now().astimezone().isoformat(timespec="microseconds")}
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps(rec) + "\n")
EOF
}
fb "$FA" profile set deepseek client --key FB_KEY_CLIENT --prefer-for tests --rules "CLIENT-RULES first" >/dev/null
fb "$FA" profile set deepseek personal --key FB_KEY_PERS --prefer-for docs --rules "PERSONAL-RULES" >/dev/null
fb "$FA" profile set deepseek plain --key FB_KEY_PLAIN --rules "PLAIN-RULES" >/dev/null

# validation: the target exists in the same provider and differs from the profile; none clears it
out=$(fb "$FA" profile set deepseek client --fallback client 2>&1); rc=$?
[[ $rc -ne 0 ]] && contains "$out" "its own fallback" "fallback: a profile cannot fall back to itself" || bad "fallback to itself accepted"
out=$(fb "$FA" profile set deepseek client --fallback nope 2>&1); rc=$?
[[ $rc -ne 0 ]] && contains "$out" "no profile deepseek@nope" "fallback: an unknown target is refused" || bad "unknown fallback accepted"
out=$(fb "$FA" profile set deepseek client --fallback personal 2>&1); expect_rc 0 $? "fallback: set"
contains "$out" "fallback: personal" "fallback: the saved line names it"
out=$(fb "$FA" profile set codex client --fallback personal 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "fallback: a target must be of the same provider (codex has no personal)" || bad "cross-provider fallback accepted"
fb "$FA" profile set deepseek client --fallback none >/dev/null
grep -q '"fallback"' "$FDIR/profiles.json" && bad "fallback none left the field" || ok "fallback none clears the field"
fb "$FA" profile set deepseek client --fallback personal >/dev/null
fb "$FA" profile use deepseek client >/dev/null
fb "$FB" profile use deepseek plain >/dev/null
fb "$FA" spend limit deepseek@client 0.0002 >/dev/null
fb "$FA" spend mode deepseek@client stop >/dev/null
fb "$FA" spend limit deepseek@plain 0.0002 >/dev/null
fb "$FA" spend mode deepseek@plain stop >/dev/null
fb "$FA" spend reset deepseek@client >/dev/null          # baselines for the manual counters
fb "$FA" spend reset deepseek@plain >/dev/null

