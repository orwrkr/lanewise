# needs: 15-manual-pool
echo "── hooks"
out=$(echo '{}' | $ORCH hook session-start); contains "$out" "executor registry" "session-start prints registry path"
contains "$out" "Open manual tasks" "session-start lists open handoffs"
ID3=$(printf 'task' | $ORCH handoff new --title "posttool" --max-open 9 | head -1 | grep -o 'AG-[0-9]*')
rm -f "$REPO/.orchestra/.last_hook_check"
out=$(echo '{}' | $ORCH hook post-tool); [[ -z "$out" ]] && ok "post-tool silent without events" || bad "post-tool noisy: $out"
printf 'STATUS: DONE\n' > "$REPO/.orchestra/handoffs/$ID3/RESULT.md"
out=$(echo '{}' | $ORCH hook post-tool); [[ -z "$out" ]] && ok "post-tool throttled" || bad "throttle failed"
rm -f "$REPO/.orchestra/.last_hook_check"
out=$(echo '{}' | $ORCH hook post-tool); contains "$out" "additionalContext" "post-tool injects context after throttle"
$PY -c "import json,sys; json.loads(sys.argv[1])" "$out" && ok "post-tool output is valid JSON" || bad "invalid JSON"
out=$(cd / || die "cannot enter root directory"; echo "{\"cwd\": \"$(native "$REPO")\"}" | $ORCH hook user-prompt); rc=$?
expect_rc 0 $rc "user-prompt hook resolves project from hook cwd"
out=$(echo 'not json' | $ORCH hook stop); expect_rc 0 $? "hook survives garbage input"
out=$(echo '{}' | sh "$PLUGIN/hooks/run.sh" session-start); contains "$out" "executor registry" "hooks/run.sh launcher finds python"
out=$(echo '{}' | ORCH_HOME="$(native "$T/hook-nopy")" PATH=/nonexistent /bin/sh "$PLUGIN/hooks/run.sh" stop); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "launcher is a silent no-op without python" || bad "launcher without python: rc=$rc out=$out"
out=$(echo '{}' | ORCH_WORKER=dee-1 $ORCH hook session-start); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "hooks silent inside a worker" || bad "worker hook: rc=$rc out=$out"
out=$(echo '{}' | ORCH_WORKER=dee-1 sh "$PLUGIN/hooks/run.sh" session-start); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "launcher skips python inside a worker" || bad "worker launcher: rc=$rc out=$out"

# run.sh: the interpreter cache — in Git Bash `python3` is often the Microsoft Store alias (~0.2 s a start)
HH="$T/hook-home"; HH_BIN="$T/hook-realbin"; HH_ALIAS="$T/hook-alias/WindowsApps"
mkdir -p "$HH" "$HH_BIN" "$HH_ALIAS" "$T/hook-tools"
hpc() { ls "$HH"/.hook-python-* 2>/dev/null | head -1; }    # the cache file, one per platform
realpy=$($PY -c 'import sys; print(sys.executable.replace("\\", "/"))')
for tool in dirname mkdir mv; do      # a PATH with no Python at all, but the tools run.sh itself needs
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$tool")" > "$T/hook-tools/$tool"
  chmod +x "$T/hook-tools/$tool"
done
alias_log="$T/hook-alias.log"; : > "$alias_log"
printf '#!/bin/sh\necho started >> "%s"\nexec "%s" "$@"\n' "$(native "$alias_log")" "$realpy" > "$HH_ALIAS/python3"
chmod +x "$HH_ALIAS/python3"                     # the alias stand-in: records each start, then runs the real Python
printf '#!/bin/sh\nexec "%s" "$@"\n' "$realpy" > "$HH_BIN/python"
chmod +x "$HH_BIN/python"                        # a real interpreter under another name, later on PATH
out=$(echo '{}' | ORCH_HOME="$(native "$HH")" PATH="$HH_ALIAS:$HH_BIN:$PATH" sh "$PLUGIN/hooks/run.sh" session-start)
contains "$out" "executor registry" "run.sh: the hook runs with a Store alias first on PATH"
[[ ! -s "$alias_log" ]] && ok "run.sh: the Store alias is skipped while a real interpreter passes" \
  || bad "run.sh: the Store alias was started"
[[ "$(cat "$(hpc)")" == "$realpy" ]] && ok "run.sh: the cache names the real interpreter" \
  || bad "run.sh: cache=$(cat "$(hpc)" 2>/dev/null)"
out=$(echo '{}' | ORCH_HOME="$(native "$HH")" PATH="$T/hook-tools" /bin/sh "$PLUGIN/hooks/run.sh" session-start)
contains "$out" "executor registry" "run.sh: a cached interpreter runs with no python on PATH"
printf '/no/such/python\n' > "$(hpc)"
out=$(echo '{}' | ORCH_HOME="$(native "$HH")" PATH="$HH_ALIAS:$HH_BIN:$PATH" sh "$PLUGIN/hooks/run.sh" session-start)
contains "$out" "executor registry" "run.sh: a cache naming a missing interpreter is ignored"
[[ "$(cat "$(hpc)")" == "$realpy" ]] && ok "run.sh: a broken cache is rewritten" \
  || bad "run.sh: cache after the rewrite=$(cat "$(hpc)" 2>/dev/null)"
: > "$alias_log"
out=$(echo '{}' | ORCH_HOME="$(native "$T/hook-home-alias")" PATH="$HH_ALIAS:$T/hook-tools" /bin/sh "$PLUGIN/hooks/run.sh" session-start)
contains "$out" "executor registry" "run.sh: a Store alias is used as the last resort"
[[ -s "$alias_log" ]] && ok "run.sh: the alias was started when nothing else passed" \
  || bad "run.sh: the alias was not used as the last resort"
rm -f "$HH"/.hook-python-*
out=$(echo '{}' | ORCH_WORKER=dee-1 ORCH_HOME="$(native "$HH")" PATH="$HH_ALIAS:$HH_BIN:$PATH" sh "$PLUGIN/hooks/run.sh" session-start)
[[ -z "$out" && -z "$(hpc)" ]] && ok "run.sh: a worker writes no cache" || bad "run.sh: worker out=$out"
$PY -B - "$(native "$PLUGIN/bin/orch")" <<'EOF' && ok "hook: the fast path skips the full argument parser" || bad "hook: parse_args was called"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
def boom(argv):
    raise AssertionError("parse_args was built for a plain hook call")
m.parse_args = boom
seen = []
m.cmd_hook = lambda a: seen.append((a.event, a.throttle)) or 0
assert m.main(["hook", "user-prompt"]) == 0
assert m.main(["hook", "post-tool", "--throttle", "30"]) == 0
assert seen == [("user-prompt", 60), ("post-tool", 30)], seen
EOF
out=$($ORCH hook --help); contains "$out" "usage: orch hook" "hook --help still comes from the full parser"

