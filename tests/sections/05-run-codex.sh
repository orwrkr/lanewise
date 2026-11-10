echo "── run codex (fake)"
out=$(FAKE_CODEX=ok CLAUDECODE=1 CLAUDE_CODE_MESSAGING_TOKEN=parent-secret \
      $ORCH run codex --model gpt-5.6-terra --effort high --mode write "add a function"); rc=$?
expect_rc 0 $rc "successful run"
contains "$out" "\[OK\]" "status OK printed"
contains "$out" "add a function" "final output returned"
contains "$out" "Prompt was: # Role: Lanewise executor" "executor role goes before the task"
contains "$out" "STATUS: DONE | PARTIAL | BLOCKED" "role defines the report format"
contains "$out" 'Run an allowed command on its own, without `cd`, `git -C`, `&&`, `;` or' "role: run an allowed command unwrapped"
contains "$out" "a permission rule matches the command as written" "role: says why a wrapped command is denied"
contains "$(cat "$FAKE_ENV_LOG")" "msg=none claudecode=none worker=cod-" "orchestrator session vars stripped, ORCH_WORKER set"
args=$(tail -1 "$FAKE_LOG")
contains "$args" "-m gpt-5.6-terra" "model passed"
contains "$args" 'model_reasoning_effort="high"' "effort passed"
contains "$args" "--sandbox workspace-write" "write mode → workspace-write"
FAKE_CODEX=ok $ORCH run codex --model gpt-5.6-luna --effort low "review" >/dev/null
contains "$(tail -1 "$FAKE_LOG")" "--sandbox read-only" "analysis mode → read-only"
out=$(FAKE_CODEX=limit $ORCH run codex --model gpt-5.6-sol --effort high "x"); rc=$?
expect_rc 75 $rc "usage limit detected"
contains "$out" "QUOTA_EXHAUSTED" "quota status printed"
out=$($ORCH quota show); contains "$out" "codex .*exhausted" "codex auto-marked exhausted"
contains "$out" "in 1h 5[0-9]m\|in 2h" "reset time parsed from 'try again in 2 hours'"
out=$(FAKE_CODEX=ok $ORCH run codex --model gpt-5.6-terra "x"); rc=$?
expect_rc 75 $rc "blocked before running while exhausted"
$ORCH quota clear codex >/dev/null
FAKE_CODEX=fail $ORCH run codex "x" >/dev/null; rc=$?
expect_rc 3 $rc "unrelated failure passes exit code through"
$ORCH quota check codex >/dev/null; expect_rc 0 $? "unrelated failure does not mark quota"
FAKE_CODEX=slow $ORCH run codex --timeout 1s "x" >/dev/null; rc=$?
expect_rc 124 $rc "timeout"
sleep 4; [[ -f "$FAKE_LATE" ]] && bad "timeout left the worker tree running" || ok "timeout stops the whole worker tree"
# the helper would hold stdout for 60 s: the run must end with codex itself, and the helper must not survive it
start=$SECONDS; FAKE_CODEX=linger $ORCH run codex "x" >/dev/null; rc=$?; took=$((SECONDS-start))
[[ $rc -eq 0 && $took -lt 60 ]] && ok "codex exit ends the run although a helper keeps stdout open (${took}s)" || bad "linger: rc=$rc ${took}s"
sleep 1
$PY - "$FAKE_LATE.pid" <<'EOF' && ok "processes left by the worker are reaped" || bad "leftover worker process kept running"
import os, subprocess, sys
pid = int(open(sys.argv[1]).read())
if os.name == "nt":
    alive = str(pid) in subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True).stdout
else:
    try:
        os.kill(pid, 0); alive = True
    except OSError:
        alive = False
sys.exit(1 if alive else 0)
EOF

