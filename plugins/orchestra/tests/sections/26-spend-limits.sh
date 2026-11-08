echo "── spend limits"
SDIR="$T/spend-home"; SH="$(native "$SDIR")"
SA="$(native "$T/spend-a")"; SB="$(native "$T/spend-b")"; SS="$(native "$T/spend-surf")"
mkdir -p "$SDIR" "$T/spend-a" "$T/spend-b" "$T/spend-surf"
printf 'DEEPSEEK_API_KEY=sk-spend\n' > "$SDIR/secrets.env"
# a personal price with no peak windows keeps the checks deterministic (peak/off-peak are unit-tested in the
# review): a fake deepseek run spends 150 input × $1.00/1M = $0.00015
printf '{"usd_per_1m_tokens": {"deepseek-v4-pro": {"input": 1.0, "cache_read": 0.0, "output": 0.0}}}' > "$SDIR/prices.json"
spend_run() { local d="$1"; shift; FAKE_CLAUDE=ok ORCH_HOME="$SH" ORCH_PROJECT_DIR="$d" $ORCH run deepseek --model deepseek-v4-pro "$@"; }
spend_reset() { rm -f "$SDIR/spend_limits.json" "$SDIR/spend_cache.json" "$SDIR/spend_events.json" "$SDIR/usage.jsonl"; }

# defaults ($10, evaluate) — show is read-only
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend)
contains "$out" "DeepSeek" "spend show lists the API-billed scope"
contains "$out" "10.00" "spend show default limit \$10"
contains "$out" "evaluate" "spend show default executor mode"
[[ -f "$SDIR/spend_limits.json" ]] && bad "spend show created state" || ok "spend show does not create state"

# reset kinds: a key scope (deepseek) is manual, a keyless scope (codex) is month
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit codex 10 >/dev/null
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend)
contains "$out" "manual" "a key scope (deepseek) defaults to a manual counter"
contains "$out" "this month" "a keyless scope (codex) defaults to a monthly counter"
spend_reset

# limit/mode set, global by default and per project; the per-project limit wins, the global mode still applies
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 5)
contains "$out" "global" "spend limit is global by default"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek stop)
contains "$out" "executor mode: stop" "spend mode global"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 6 --project)
contains "$out" "project" "spend limit per project"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend)
contains "$out" "6.00" "per-project limit overrides the global one"
contains "$out" "stop" "global mode still applies to the project"
spend_reset

# --project PATH: from project A set project B's own limit; B shows it, A keeps its default
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 5 --project "$SB" >/dev/null
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SB" $ORCH spend)
contains "$out" "5.00" "--project PATH: project B shows the limit set from project A"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend)
contains "$out" "10.00" "--project PATH: project A keeps its own default"
grep -q "5.00" <<<"$out" && bad "--project PATH: project A shows project B's limit: $out" || ok "--project PATH: project A is unaffected by project B's limit"
spend_reset

# stop: a run already at the limit refuses before starting (exit 75); --force does not bypass
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek stop >/dev/null
spend_run "$SA" "first" >/dev/null; expect_rc 0 $? "first run under the limit"
out=$(spend_run "$SA" "second"); expect_rc 75 $? "stop mode: at the limit → refused"
contains "$out" "SPEND_LIMIT" "stop refusal named SPEND_LIMIT"
contains "$out" "orch spend reset deepseek" "a blocked manual scope names the reset that clears it"
out=$(spend_run "$SA" --force "forced"); expect_rc 75 $? "--force does not bypass a spend limit"
spend_reset

# evaluate: refuses a new run at the limit like stop (the overrun only matters mid-run)
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
spend_run "$SA" "one" >/dev/null; expect_rc 0 $? "evaluate: first run"
out=$(spend_run "$SA" "two"); expect_rc 75 $? "evaluate: at the limit → refused"
contains "$out" "SPEND_LIMIT" "evaluate refusal named SPEND_LIMIT"
spend_reset

# a run in progress is killed when it crosses the threshold: stop at 100%, evaluate past the overrun
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek stop >/dev/null
out=$(FAKE_CLAUDE=stream FAKE_STREAM_INPUT=1000000 ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 75 $rc "stop: a run crossing the limit mid-run is killed"
contains "$out" "SPEND_LIMIT" "stop mid-run named SPEND_LIMIT"
spend_reset
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek evaluate --overrun 20 >/dev/null
out=$(FAKE_CLAUDE=stream FAKE_STREAM_INPUT=110 FAKE_STREAM_SLEEP=20 ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 0 $rc "evaluate: a run past 100% but under the overrun finishes"
spend_reset
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek evaluate --overrun 20 >/dev/null
out=$(FAKE_CLAUDE=stream FAKE_STREAM_INPUT=1000000 ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 75 $rc "evaluate: a run crossing the overrun mid-run is killed"
contains "$out" "SPEND_LIMIT" "evaluate mid-run named SPEND_LIMIT"
spend_reset

# a half-written usage_live.json mid-run skips one poll instead of crashing the run
spend_reset
out=$(FAKE_CLAUDE=bad_live FAKE_STREAM_SLEEP=20 ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 0 $rc "a half-written usage_live.json skips a poll instead of crashing"
contains "$out" "DONE" "the run finished despite the malformed mid-run usage"
spend_reset

# a failed run still logs the tokens it reported before failing (usage_live.json falls back when usage.json is missing)
spend_reset
FAKE_CLAUDE=fail_stream ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH run deepseek --model deepseek-v4-pro "boom" >/dev/null; rc=$?
expect_rc 1 $rc "a failed run still fails"
$PY - "$SH/usage.jsonl" <<'EOF' && ok "a failed run logs the tokens it reported before failing" || bad "failed run logged \$0"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if '"FAILED"' in l][-1]
assert r["usage"]["input_tokens"] == 150, r["usage"]
assert r["cost_usd"] > 0, r
EOF
spend_reset

# continue: warn only, never refuses
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek continue >/dev/null
spend_run "$SA" "one" >/dev/null; expect_rc 0 $? "continue: first run"
out=$(spend_run "$SA" "two"); expect_rc 0 $? "continue: a run at/over the limit still runs"
contains "$out" "executor mode continue" "continue: warns instead of refusing"
spend_reset

# global vs per-project counters: a project with its own limit does not consume the global counter
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0003 --project >/dev/null   # $SA: its own counter
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0002 >/dev/null             # others share the global one
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek stop >/dev/null
spend_run "$SB" "g1" >/dev/null; expect_rc 0 $? "global counter: first run"
spend_run "$SB" "g2" >/dev/null; expect_rc 0 $? "global counter: second run"
out=$(spend_run "$SB" "g3"); expect_rc 75 $? "global counter: at the global limit → refused"
out=$(spend_run "$SA" "own"); expect_rc 0 $? "a project's own counter is unaffected by the global one"
spend_reset

# reset zeroes the counter at once; --limit sets a new limit in the same step
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek stop >/dev/null
spend_run "$SA" "one" >/dev/null; expect_rc 0 $? "reset: first run"
out=$(spend_run "$SA" "two"); expect_rc 75 $? "reset: at the limit → refused"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend reset deepseek)
contains "$out" "manual counter" "reset names the counter kind"
spend_run "$SA" "three" >/dev/null; expect_rc 0 $? "after a reset the same limit allows a run again"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend reset deepseek --limit 1)
contains "$out" "1.00" "reset --limit sets a new limit in the same step"
spend_reset

# raising the limit above the spend unblocks (a manual counter keeps growing)
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 0.0001 >/dev/null
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend mode deepseek stop >/dev/null
spend_run "$SA" "one" >/dev/null; expect_rc 0 $? "raise: first run"
out=$(spend_run "$SA" "two"); expect_rc 75 $? "raise: blocked at the limit"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 1 >/dev/null
spend_run "$SA" "three" >/dev/null; expect_rc 0 $? "raising the limit above the spend unblocks"
spend_reset

# corrupt spend_limits.json: reads keep defaults, writes refuse, the file is left unchanged
printf '{broken' > "$SDIR/spend_limits.json"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek 5 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "corrupt spend_limits.json: writes refused" || bad "corrupt spend_limits.json: write accepted (rc=$rc)"
contains "$out" "unreadable" "corrupt spend_limits.json: error named"
[[ "$(cat "$SDIR/spend_limits.json")" == "{broken" ]] && ok "corrupt spend_limits.json left unchanged" || bad "corrupt spend_limits.json modified"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend)
contains "$out" "defaults shown" "corrupt spend_limits.json: defaults shown"
contains "$out" "10.00" "corrupt spend_limits.json: default \$10 kept"
rm -f "$SDIR/spend_limits.json"

# a corrupt spend_limits.json fails closed: a run refuses instead of counting $0 (SPEND_LIMIT names the file)
printf '{broken' > "$SDIR/spend_limits.json"
out=$(spend_run "$SA" "blocked"); expect_rc 75 $? "corrupt spend_limits.json: a run refuses instead of counting \$0"
contains "$out" "SPEND_LIMIT" "corrupt spend_limits.json: the run refusal is a SPEND_LIMIT"
contains "$out" "unreadable" "corrupt spend_limits.json: the run refusal names the broken file"
rm -f "$SDIR/spend_limits.json"

# limits reject nan / inf instead of accepting a non-finite amount
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek nan 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "spend limit nan refused" || bad "spend limit nan accepted"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek inf 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "spend limit inf refused" || bad "spend limit inf accepted"

# scopes are lowercased; an unknown profile is refused; reset --project needs its own limit
spend_reset
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit DEEPSEEK 5 2>&1); rc=$?
expect_rc 0 $rc "a scope is lowercased (DEEPSEEK sets deepseek)"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend)
contains "$out" "5.00" "the lowercased scope carries the limit"
grep -q '"deepseek"' "$SDIR/spend_limits.json" && ok "the scope is stored lowercased" || bad "the scope was not lowercased"
spend_reset
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend limit deepseek@nope 5 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "an unknown profile scope is refused" || bad "unknown profile scope accepted"
spend_reset
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SA" $ORCH spend reset deepseek --project 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "reset --project without a project limit is refused" || bad "reset --project no-op accepted"
contains "$out" "limit" "reset --project refusal says to set a limit first"
spend_reset

# surfaces at ≥ 80%: status, the status line, and a once-per-baseline 💡 event
spend_ledger() { $PY - "$SH/usage.jsonl" "$1" <<'EOF'
import datetime as dt, json, sys
rec = {"kind": "run", "provider": "deepseek", "label": "deepseek", "model": "deepseek-v4-pro",
       "billing": "api", "project": "spend-surf",
       "usage": {"input_tokens": int(sys.argv[2]), "cached_input_tokens": 0, "output_tokens": 0},
       "ts": dt.datetime.now().astimezone().isoformat(timespec="microseconds")}   # as ledger_append writes it
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps(rec) + "\n")
EOF
}
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend reset deepseek >/dev/null   # baseline for the manual counter
spend_ledger 8100000      # $8.10 of the default $10 → 81%
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH status)
contains "$out" "API spend: DeepSeek" "status: spend line at ≥ 80%"
contains "$out" "8.10" "status: spend amount"
contains "$out" "81%" "status: spend percentage"
contains "$out" "API keys (spend and limit: our estimate of orch's own runs; account: the provider's figure, for all keys of that account):" \
  "status: the API keys block says where each number comes from"
contains "$out" "DeepSeek  *est. \$8.10 of \$10 (manual, since .*) · account balance not fetched yet" "status: the key scope's block line, no balance fetched yet"
out=$(printf '{"session_id":"s-spend","workspace":{"current_dir":"%s"}}' "$SS" | ORCH_HOME="$SH" $ORCH statusline)
contains "$out" "DeepSeek (est. \$8.10/\$10)" "status line: spend fragment at ≥ 80%"
lacks "$out" "account" "status line: no account part where no balance was ever fetched"
out=$(printf '{"session_id":"s-spend"}' | ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH hook user-prompt)
contains "$out" "80%" "spend event: 80% announced"
contains "$out" "DeepSeek" "spend event: names the scope"
out=$(printf '{"session_id":"s-spend"}' | ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH hook user-prompt)
[[ -z "$out" ]] && ok "spend event: announced once" || bad "spend event: 80% repeated: $out"
spend_ledger 2700000      # +$2.70 → $10.80, past the limit
out=$(printf '{"session_id":"s-spend"}' | ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH hook user-prompt)
contains "$out" "is at its spend limit" "spend event: 100% announced"
contains "$out" "orch spend reset deepseek" "spend event: names the manual way out"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend reset deepseek >/dev/null
spend_ledger 8100000      # $8.10 again against the new baseline
out=$(printf '{"session_id":"s-spend"}' | ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH hook user-prompt)
contains "$out" "80%" "spend event: a reset re-arms the 80% event for the new baseline"
spend_ledger 2700000      # $10.80 against the new baseline: the same event, through the other hook
out=$(printf '{"session_id":"s-spend"}' | ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH hook post-tool)
contains "$out" "is at its spend limit" "spend event: reaches the model through PostToolUse too"

# the status line always shows the estimate and the limit of an API-billed scope, not only from 80%
spend_reset
sl_spend() { printf '{"session_id":"s-spend-sl","workspace":{"current_dir":"%s"}}' "${1:-$SS}" | ORCH_HOME="${2:-$SH}" $ORCH statusline; }
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend reset deepseek >/dev/null
out=$(sl_spend); contains "$out" "^DeepSeek (est. \$0.00/\$10)\$" "status line: the fragment shows at 0% too, with a known limit"
spend_ledger 3000000      # $3.00 of $10: 30%, well below the 80% warning
out=$(sl_spend); contains "$out" "^DeepSeek (est. \$3.00/\$10)\$" "status line: the fragment shows below 80%"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH status); lacks "$out" "API spend:" "status: still no API spend warning below 80%"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend limit deepseek 12.16 >/dev/null
out=$(sl_spend); contains "$out" "^DeepSeek (est. \$3.00/\$12.16)\$" "status line: a limit that is not whole is not rounded"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend limit deepseek 12 >/dev/null
out=$(sl_spend); contains "$out" "^DeepSeek (est. \$3.00/\$12)\$" "status line: a whole limit shows without cents"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend limit deepseek off >/dev/null
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend show); grep -E '^DeepSeek ' <<<"$out" | grep -q '\$10' && bad "orch spend limit off left the default limit: $out" || ok "orch spend limit off really turns the limit off"
out=$(sl_spend); contains "$out" "^DeepSeek (est. \$3.00)\$" "status line: limit off shows the estimate alone"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH status)
contains "$out" "DeepSeek  *est. \$3.00, limit off (manual, since" "status: limit off in the block line"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend limit deepseek 10 >/dev/null
# a built-in profile without a key, spend or balance stays silent
SNK="$T/spend-nokey-home"; mkdir -p "$SNK"
out=$(sl_spend "$SS" "$(native "$SNK")"); lacks "$out" "DeepSeek" "status line: the built-in profile with no key stays silent"
out=$(ORCH_HOME="$(native "$SNK")" ORCH_PROJECT_DIR="$SS" $ORCH status); lacks "$out" "API keys (" "status: no API keys block for a provider nobody uses"
# the account figure: one cached balance shows next to the estimate; its age shows once it is old
$PY - "$SDIR/balances.json" 0 <<'EOF'
import datetime as dt, json, sys
at = (dt.datetime.now().astimezone() - dt.timedelta(seconds=int(sys.argv[2]))).isoformat(timespec="seconds")
json.dump({"deepseek": {"amount": 15.09, "currency": "USD", "at": at}}, open(sys.argv[1], "w", encoding="utf-8"))
EOF
out=$(sl_spend); contains "$out" "^DeepSeek (est. \$3.00/\$10, account \$15.09)\$" "status line: the account figure follows the estimate"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH status); contains "$out" "DeepSeek  *est. \$3.00 of \$10 (manual, since .*) · account \$15.09 (checked" \
  "status: the block line carries the account figure and when it was checked"
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend)
contains "$out" "\`account\` is the provider's figure for the whole account" "spend show: the header says what the account column is"
contains "$out" "which can include spending outside orch" "spend show: the header says the account can be spent from outside orch"
contains "$out" "\`spent\` is our estimate of orch's own runs" "spend show: the header says spent is our estimate of orch's runs"
grep -qE "^scope +spent +limit +account " <<<"$out" && ok "spend show: the column is called account" || bad "spend show: column header: $out"
$PY - "$SDIR/balances.json" 10800 <<'EOF'
import datetime as dt, json, sys
at = (dt.datetime.now().astimezone() - dt.timedelta(seconds=int(sys.argv[2]))).isoformat(timespec="seconds")
json.dump({"deepseek": {"amount": 15.09, "currency": "USD", "at": at}}, open(sys.argv[1], "w", encoding="utf-8"))
EOF
out=$(sl_spend); contains "$out" "^DeepSeek (est. \$3.00/\$10, account \$15.09, 3h ago)\$" "status line: an old account figure says how old it is"
# the money joins the token counter of the same scope; the age sits inside the same parentheses
lacks "$out" "Session in/out" "status line: with no session tokens at all there is no heading"
lacks "$out" "))" "status line: the age is not a nested parenthesis"
sl_sess() { printf '{"session_id":"%s","workspace":{"current_dir":"%s"}}' "$1" "$SS" | ORCH_HOME="$SH" $ORCH statusline; }
$PY - "$SH/usage.jsonl" <<'EOF'
import json, sys
def rec(sid, prov, label, inp, out):
    return json.dumps({"kind": "run", "session": sid, "provider": prov, "label": label, "model": "m",
                       "usage": {"input_tokens": inp, "cached_input_tokens": 0, "output_tokens": out}})
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(rec("s-sl-same", "deepseek", "deepseek", 1500, 988) + "\n")
    f.write(rec("s-sl-other", "codex", "codex", 400, 40) + "\n")
EOF
out=$(sl_sess s-sl-same)
contains "$out" "^Session in/out: DeepSeek 1.5k/988 (est. \$3.0[0-9]/\$10, account \$15.09, 3h ago)\$" \
  "status line: the money joins the counter of the same scope, in one pair of parentheses"
[[ $(grep -o "DeepSeek" <<<"$out" | wc -l) -eq 1 ]] && ok "status line: the name is not repeated" || bad "status line: the name repeats: $out"
out=$(sl_sess s-sl-other)
contains "$out" "^Session in/out: Codex 400/40" "status line: a scope with money and no tokens follows the counters"
contains "$out" "^  DeepSeek (est. \$3.0[0-9]/\$10, account \$15.09, 3h ago)" \
  "status line: a spend-only scope gets a line of its own, indented"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend limit deepseek off >/dev/null
out=$(sl_sess s-sl-same); contains "$out" "^Session in/out: DeepSeek 1.5k/988 (est. \$3.0[0-9], account \$15.09, 3h ago)\$" \
  "status line: the limit off leaves the estimate and the account figure"
ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend limit deepseek 10 >/dev/null
rm -f "$SDIR/balances.json"
out=$(sl_sess s-sl-same); contains "$out" "^Session in/out: DeepSeek 1.5k/988 (est. \$3.0[0-9]/\$10)\$" \
  "status line: no balance yet leaves our part alone"
unset -f sl_sess
rm -f "$SDIR/balances.json"
spend_reset

# a lead session is recorded split at the counter's baseline, and only the part after the baseline counts: the
# SessionEnd hook of a DeepSeek lead, a fake transcript with one message before and two after the baseline (the
# personal price above makes 1M input tokens cost $1.00)
LEADT="$SDIR/lead-transcript.jsonl"
$PY - "$LEADT" "$SDIR/spend_limits.json" <<'EOF2'
import json, sys
def msg(mid, ts):
    return json.dumps({"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": "deepseek-v4-pro",
                       "usage": {"input_tokens": 1000000, "cache_creation_input_tokens": 0,
                                 "cache_read_input_tokens": 0, "output_tokens": 0}}}, separators=(",", ":"))
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write("\n".join([msg("l1", "2026-11-02T11:00:00.000Z"), msg("l2", "2026-11-02T13:00:00.000Z"),
                       msg("l3", "2026-11-02T14:00:00.000Z")]) + "\n")
json.dump({"baselines": {"global": {"deepseek": "2026-11-02T12:00:00+00:00"}}}, open(sys.argv[2], "w", encoding="utf-8"))
EOF2
echo "{\"session_id\": \"sess-lead-split\", \"transcript_path\": \"$(native "$LEADT")\", \"cwd\": \"$SS\"}" | \
  ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" ORCH_LEAD=deepseek $ORCH hook session-end >"$T/lead-se.out"; rc=$?
[[ $rc -eq 0 && ! -s "$T/lead-se.out" ]] && ok "SessionEnd hook of a lead session is silent" || bad "lead session-end: rc=$rc $(cat "$T/lead-se.out")"
$PY - "$SH/usage.jsonl" <<'EOF2' && ok "the lead session record carries spend_parts split at the baseline" || bad "the lead session record lacks the split parts"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if '"sess-lead-split"' in l]
assert len(recs) == 1 and recs[0]["lead"] == "deepseek", recs
parts = recs[0]["spend_parts"]
assert [p["spend_usd"] for p in parts] == [1.0, 2.0], parts
assert parts[0]["until"].startswith("2026-11-02T11:00:00") and parts[1]["until"].startswith("2026-11-02T14:00:00"), parts
assert abs(recs[0]["spend_usd"] - 3.0) < 1e-9, recs[0]
assert "messages" not in recs[0], recs[0]
EOF2
out=$(ORCH_HOME="$SH" ORCH_PROJECT_DIR="$SS" $ORCH spend)
contains "$out" '\$2\.00 ' "orch spend counts only the part of the lead session after the baseline"
spend_reset
unset -f sl_spend

