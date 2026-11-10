echo "── reminders & wait"
printf 'task' | $ORCH handoff new --title "remind" --pickup-min 0 --reassign-min 999 --max-open 9 >/dev/null
out=$($ORCH handoff check); contains "$out" "waiting for the operator" "pickup reminder"
printf 'task' | $ORCH handoff new --title "stale" --pickup-min 0 --reassign-min 0 --max-open 9 >/dev/null
out=$($ORCH handoff check); contains "$out" "not started .* Reassign" "reassign suggestion"
ID=$(printf 'task' | $ORCH handoff new --title "waitme" --max-open 9 | head -1 | grep -o 'AG-[0-9]*')
( sleep 3; printf 'STATUS: DONE\nok\n' > "$REPO/.lanewise/handoffs/$ID/RESULT.md" ) &
out=$($ORCH handoff wait "$ID" --interval 1 --timeout 1m); rc=$?
expect_rc 0 $rc "wait returns on DONE"
contains "$out" "$ID: STATUS DONE" "wait prints result"
ID2=$(printf 'task' | $ORCH handoff new --title "blocked" --max-open 9 | head -1 | grep -o 'AG-[0-9]*')
printf 'STATUS: BLOCKED\nneed creds\n' > "$REPO/.lanewise/handoffs/$ID2/RESULT.md"
$ORCH handoff wait "$ID2" --interval 1 --timeout 10s >/dev/null; expect_rc 2 $? "wait returns 2 on BLOCKED"
$ORCH handoff done AG-0003 --note "operator said “done”" >/dev/null
out=$($ORCH handoff show AG-0003); contains "$out" "DONE" "manual done recorded"

