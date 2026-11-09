echo "── quota"
out=$($ORCH quota show); contains "$out" "all executors available\|All executors available" "empty availability"
$ORCH quota set codex/gpt-5.6-sol exhausted --until "+2h" --note "test" >/dev/null
$ORCH quota check codex/gpt-5.6-sol >/dev/null; expect_rc 75 $? "model key blocked"
$ORCH quota check codex/gpt-5.6-terra >/dev/null; expect_rc 0 $? "sibling model still available"
$ORCH quota set codex exhausted --until 18:00 >/dev/null
$ORCH quota check codex/gpt-5.6-terra >/dev/null; expect_rc 75 $? "provider key blocks all models"
$ORCH quota set claude/opus low >/dev/null
$ORCH quota check claude/opus >/dev/null; expect_rc 0 $? "low = available with warning"
$PY - <<EOF
import json,os
p=os.path.join(os.environ["ORCH_HOME"],"availability.json"); d=json.load(open(p))
d["entries"]["codex"]["until"]="2020-01-01T00:00:00+00:00"; json.dump(d,open(p,"w"))
EOF
$ORCH quota check codex/gpt-5.6-terra >/dev/null; expect_rc 0 $? "expired entry auto-pruned"
$ORCH quota clear codex/gpt-5.6-sol >/dev/null; $ORCH quota clear claude/opus >/dev/null
out=$($ORCH quota set antigravity/gemini-4-argon exhausted --until "2030-01-01 09:00"); contains "$out" "01.01 09:00" "absolute datetime parsed"
$ORCH quota clear antigravity/gemini-4-argon >/dev/null

