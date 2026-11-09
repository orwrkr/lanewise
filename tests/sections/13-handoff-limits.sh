echo "── handoff limits & operator"
printf 'task' | $ORCH handoff new --title "two" >/dev/null
printf 'task' | $ORCH handoff new --title "three" --max-open 2 >/dev/null; rc=$?
printf 'task' | $ORCH handoff new --title "four" --max-open 2 >/dev/null; rc=$?
expect_rc 75 $rc "max_open_handoffs enforced"
$ORCH quota set operator away --until "+3h" >/dev/null
printf 'task' | $ORCH handoff new --title "away" --max-open 9 >/dev/null; rc=$?
expect_rc 75 $rc "operator away blocks new handoffs"
$ORCH quota clear operator >/dev/null
$ORCH handoff cancel AG-0002 --reassigned >/dev/null
out=$($ORCH handoff list); grep -q "AG-0002" <<<"$out" && bad "cancelled still listed" || ok "cancelled handoff hidden from open list"

