echo "── manual pool: offer → take → result"
echo "PROJECT-RULES-MARKER" > "$REPO/CLAUDE.md"; git -C "$REPO" add CLAUDE.md && git -C "$REPO" commit -qm rules
out=$(printf '## Goal\nCheck the form — café ✓\n' | $ORCH handoff offer --title "UI form check" --model "Gemini 4 Argon" \
      --model-key gemini-4-argon --effort High --fallback "codex gpt-6.1-sol high"); rc=$?
expect_rc 0 $rc "task offered to the pool"
PID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
contains "$out" "in the manual pool" "pool card shown"
contains "$out" "/partitura:manual $PID to Antigravity" "offer card: the slash form matches the command's argument hint"
contains "$out" "orch handoff take $PID " "offer card: the terminal form"
[[ -e "$REPO/.orchestra/handoffs/$PID/TASK.md" ]] && bad "TASK.md written before anyone took the task" || ok "no TASK.md until taken"
out=$($ORCH handoff list); contains "$out" "Pool — available to take (1)" "list shows the pool"
contains "$out" "$PID *OFFERED" "offered state"
grep -q "Pool — available to take (1)" "$REPO/.orchestra/MANUAL.md" && ok "board .orchestra/MANUAL.md lists the pool" || bad "board missing pool"
printf 'x' | $ORCH handoff new --title "taken" --max-open 99 >/dev/null
n_taken=$($ORCH handoff list --json | $PY -c "import json,sys; print(sum(1 for m in json.load(sys.stdin) if m['state'] in ('WAITING','STARTED?','IN_PROGRESS')))")
printf 'x' | $ORCH handoff new --title "cap" --max-open "$((n_taken + 1))" >/dev/null; expect_rc 0 $? "pooled tasks do not count against max_open"
out=$($ORCH handoff take "$PID" --max-open 99); rc=$?
expect_rc 0 $rc "operator takes the task"
contains "$out" "In Antigravity, in the project folder: " "take: the card says the project folder"
contains "$out" "Execute the task described in .orchestra/handoffs/$PID/TASK.md" "paste line after take"
contains "$out" "orch handoff check" "take card: a terminal picks completion up with handoff check"
TW="$REPO"
grep -q "an executor in the Partitura system" "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "TASK.md: executor role for the manual agent" || bad "role missing"
grep -q 'Project rules.*`CLAUDE.md`' "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "TASK.md points to the project rules" || bad "rules pointer missing"
grep -q "AGENT:" "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "protocol asks the agent to name itself" || bad "AGENT line missing"
grep -q "only that task.s RESULT.md and, for a task that changes files, its own worktree" "$TW/.agents/rules/partitura-task.md" 2>/dev/null && ok "the rule allows a writing task its own worktree" || bad "rule does not mention the task worktree"
grep -q "trigger: always_on" "$TW/.agents/rules/partitura-task.md" 2>/dev/null && ok "Antigravity workspace rule in the project folder" || bad "rule file missing"
git -C "$TW" status --porcelain | grep -q "orchestra\|\.agents" && bad "git status shows task files: $(git -C "$TW" status --porcelain)" || ok "rule and task files stay out of git status"
out=$($ORCH handoff take "$PID"); expect_rc 1 $? "second take refuses an already assigned task"
contains "$out" "not available in the pool" "second take explains that ownership is already claimed"
printf 'STATUS: DONE\nAGENT: Antigravity · Gemini 4 Argon\n## Summary\nok\n' > "$TW/.orchestra/handoffs/$PID/RESULT.md"
out=$($ORCH handoff check); contains "$out" "$PID finished: STATUS DONE — UI form check (Antigravity · Gemini 4 Argon)" "completion names the agent"
$PY - "$ORCH_HOME/usage.jsonl" "$PID" <<'EOF' && ok "manual task in the usage ledger (agent, model, session)" || bad "handoff ledger"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if '"handoff"' in l and sys.argv[2] in l][-1]
assert r["agent"] == "Antigravity · Gemini 4 Argon" and r["model"] == "Gemini 4 Argon" and r["session"] == "sess-test", r
EOF
out=$($ORCH usage); contains "$out" "Antigravity (manual) *Antigravity · Gemini" "manual task in the session report"
out=$(printf 'x' | $ORCH handoff offer --title "stale offer"); OID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
contains "$out" "No take from the pool for 5 min → the orchestrator starts taking tasks back, one at a time" "pool card explains the reclaim clock"
grep -q "After 5 min without a take the orchestrator starts taking tasks back" "$REPO/.orchestra/MANUAL.md" && ok "board explains the pool clock" || bad "board: no pool clock"
$ORCH handoff reclaim "$OID" >/dev/null; out=$($ORCH handoff list); grep -q "$OID" <<<"$out" && bad "reclaimed offer still listed" || ok "reclaim takes it back"
out=$(printf 'x' | $ORCH handoff offer --title "for cursor"); CID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
out=$($ORCH handoff take "$CID" --agent cursor --max-open 99); contains "$out" "In Cursor, in the project folder" "take for another manual agent"
# the pool clock: a check every 5 min since the operator's last take from the pool (or since the pool opened)
backdate_pool() { $PY - "$(native "$REPO/.orchestra/handoffs")" "$1" <<'EOF'
import datetime as dt, glob, json, os, sys
root, delta = sys.argv[1], dt.timedelta(minutes=int(sys.argv[2]), seconds=5)
shift = lambda v: (dt.datetime.fromisoformat(v) - delta).isoformat(timespec="seconds")   # keeps their order
for p in [os.path.join(root, ".pool.json")] + glob.glob(os.path.join(root, "*", "meta.json")):
    s = json.load(open(p, encoding="utf-8"))
    if p.endswith(".pool.json"):
        s["started"] = shift(s["started"])
    elif s.get("offered") and s.get("taken"):
        s["taken"] = shift(s["taken"])
    json.dump(s, open(p, "w", encoding="utf-8"))
EOF
}
out=$(printf 'x' | $ORCH handoff offer --title "next A"); AID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
out=$(printf 'x' | $ORCH handoff offer --title "next B" --fallback "deepseek flash"); BID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
out=$($ORCH handoff check --peek); grep -q "Manual pool: no task taken" <<<"$out" && bad "pool check too early" || ok "no pool check within the first 5 min"
backdate_pool 5
$ORCH handoff hold "$AID" --until +1h --note later >/dev/null
$ORCH handoff hold "$BID" >/dev/null
out=$($ORCH handoff list); contains "$out" "$AID.*on hold for the operator until" "hold shown in list"
out=$($ORCH status --brief); contains "$out" "$AID.*on hold for the operator" "hold shown in status"
contains "$(cat "$REPO/.orchestra/MANUAL.md")" "$AID.*on hold for the operator" "hold shown on board"
before=$(cat "$REPO/.orchestra/handoffs/.pool.json")
out=$($ORCH handoff check --peek); grep -q "Manual pool: no task taken" <<<"$out" && bad "held pool checked" || ok "only held tasks produce no pool check"
after=$(cat "$REPO/.orchestra/handoffs/.pool.json")
[[ "$before" == "$after" ]] && ok "held pool leaves state untouched" || bad "held pool changed state"
$ORCH handoff hold "$BID" --off >/dev/null
out=$($ORCH handoff check --peek); contains "$out" "$BID “next B”" "unheld task remains in check"
grep -q "$AID “next A”" <<<"$out" && bad "held task in check" || ok "held task omitted"
$ORCH handoff hold "$AID" --off >/dev/null
out=$($ORCH handoff check)
contains "$out" "Manual pool: no task taken for [5-9] min (since the pool opened; check 1, every 5 min)" "first pool check after 5 min without a take"
contains "$out" "$BID “next B” — .*fallback: deepseek flash" "the check lists the untaken tasks"
contains "$out" "If there is none, reclaim only the next one — orch handoff reclaim $AID --next" "the oldest task is the next one"
out=$($ORCH handoff check); grep -q "Manual pool" <<<"$out" && bad "pool check repeated" || ok "each pool check is reported once"
$ORCH handoff reclaim "$AID" --next >/dev/null; expect_rc 0 $? "reclaim the next task"
out=$($ORCH handoff reclaim "$BID" --next); expect_rc 75 $? "only one next task at a time"
contains "$out" "NEXT_BUSY: $AID" "refusal names the running next task"
backdate_pool 5
out=$($ORCH handoff check); contains "$out" "check 2, every 5 min" "the pool is checked every 5 min"
contains "$out" "not now: $AID “next A”, reclaimed as the next task" "the check knows the next task is still running"
FAKE_CODEX=ok $ORCH run codex --handoff "$AID" "do next A" >/dev/null; expect_rc 0 $? "orch run --handoff executes the reclaimed task"
$ORCH handoff reclaim "$BID" --next >/dev/null; expect_rc 0 $? "a successful run frees the slot for the next one"
out=$(printf 'x' | $ORCH handoff offer --title "next C"); C2=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
out=$(printf 'x' | $ORCH handoff offer --title "next D"); DID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
backdate_pool 5
$ORCH handoff take "$C2" --max-open 99 >/dev/null
out=$($ORCH handoff check --peek); grep -q "Manual pool: no task taken" <<<"$out" && bad "a take did not restart the clock: $out" || ok "a take restarts the pool clock"
backdate_pool 5; rm -f "$REPO/.orchestra/.last_hook_check"
out=$(echo '{}' | $ORCH hook post-tool); contains "$out" "Manual pool: no task taken for 5 min (since the last take" "post-tool hook reports a pool check while the orchestrator works"
backdate_pool 10
out=$($ORCH handoff wait --any --interval 1 --timeout 1m); expect_rc 3 $? "wait --any wakes the orchestrator for a pool check"
contains "$out" "$DID “next D”" "the wake-up lists the pool"
out=$($ORCH handoff reclaim "$DID" --next); expect_rc 75 $? "next task still running → no second one"
$ORCH handoff done "$BID" >/dev/null
$ORCH handoff reclaim "$DID" --next >/dev/null; expect_rc 0 $? "orch handoff done frees the slot too"
$ORCH handoff done "$DID" >/dev/null
# hold transitions: an expired --until does not hold, take and reclaim clear the hold, and a non-pooled task refuses
out=$(printf 'x' | $ORCH handoff offer --title "hold A"); HLD1=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
$ORCH handoff hold "$HLD1" --until "2020-01-01 00:00" >/dev/null
backdate_pool 5
out=$($ORCH handoff check --peek); contains "$out" "$HLD1 “hold A”" "an expired --until leaves the task in the check"
$ORCH handoff hold "$HLD1" >/dev/null
$ORCH handoff take "$HLD1" --max-open 99 >/dev/null
lacks "$(cat "$REPO/.orchestra/handoffs/$HLD1/meta.json")" '"hold"' "take clears a hold"
out=$(printf 'x' | $ORCH handoff offer --title "hold B"); HLD2=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
$ORCH handoff hold "$HLD2" >/dev/null
$ORCH handoff reclaim "$HLD2" >/dev/null
lacks "$(cat "$REPO/.orchestra/handoffs/$HLD2/meta.json")" '"hold"' "reclaim clears a hold"
out=$(printf 'x' | $ORCH handoff new --title "not pooled" --max-open 99); HLD3=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
out=$($ORCH handoff hold "$HLD3"); rc=$?
expect_rc 1 $rc "hold on a task not in the pool fails"
contains "$out" "not in the pool" "hold refusal says not in the pool"
$ORCH handoff cancel "$HLD1" >/dev/null; $ORCH handoff close "$HLD1" >/dev/null
$ORCH handoff cancel "$HLD2" >/dev/null; $ORCH handoff close "$HLD2" >/dev/null
$ORCH handoff cancel "$HLD3" >/dev/null; $ORCH handoff close "$HLD3" >/dev/null
$PY - "$(native "$REPO/.orchestra/MANUAL.md")" "$HLD3" <<'EOF' && ok "the board keeps a closed task under Recently finished" || bad "close emptied Recently finished"
import sys
tail = open(sys.argv[1], encoding="utf-8").read().split("## Recently finished", 1)[1]
assert sys.argv[2] in tail and "_none_" not in tail, tail
EOF
for i in 1 2 3 4 5; do printf 'x' | $ORCH handoff offer --title "bulk $i" --check-min 999 >/dev/null; done
printf 'x' | $ORCH handoff offer --title "too many" >/dev/null; expect_rc 75 $? "pool size limited (max_offers)"
git -C "$REPO" rm -q CLAUDE.md && git -C "$REPO" commit -qm "drop rules"

