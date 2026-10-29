#!/usr/bin/env bash
# Self-test for orch: fake codex + fake claude (DeepSeek worker) + temporary git repo + isolated ORCH_HOME.
# Runs in WSL/Linux/macOS and on Windows in Git Bash (native Windows Python).
# Usage: bash tests/run_tests.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
PY=""
for p in python3 python py; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PY="$p"; break
  fi
done
[[ -n "$PY" ]] || { echo "Python >= 3.8 not found"; exit 1; }
# path as Python sees it: Git Bash /c/… → C:/…, unchanged elsewhere
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ORCH="$PY $PLUGIN/bin/orch"
T="$(mktemp -d)"
export ORCH_HOME; ORCH_HOME="$(native "$T/home")"
export PATH="$T/fakebin:$PATH"
unset CLAUDE_PROJECT_DIR ORCH_PROJECT_DIR ORCH_WORKER ORCH_CODEX_BIN ORCH_CLAUDE_BIN DEEPSEEK_API_KEY ORCH_NOTIFY_CMD
pass=0; fail=0
ok()   { echo "  ✔ $1"; pass=$((pass+1)); }
bad()  { echo "  ✘ $1"; fail=$((fail+1)); }
expect_rc() { local want=$1 got=$2 name=$3; [[ "$got" == "$want" ]] && ok "$name (rc=$got)" || bad "$name: rc=$got, want $want"; }
# output is compared with Windows backslashes turned into slashes
contains() { local text="${1//\\//}"; grep -q -- "$2" <<<"$text" && ok "$3" || { bad "$3"; echo "----- output -----"; echo "$1"; echo "------------------"; }; }

# fake codex (`codex exec --json` event stream): behaviour selected by FAKE_CODEX env
mkdir -p "$T/fakebin" "$T/home"
cat > "$T/fakebin/fake_codex.py" <<'EOF'
import json, os, sys, time
args = sys.argv[1:]
with open(os.environ["FAKE_ENV_LOG"], "w") as f:
    f.write("msg=%s claudecode=%s worker=%s ds=%s cxhome=%s lead=%s\n" % tuple(os.environ.get(k) or "none" for k in (
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDECODE", "ORCH_WORKER", "DEEPSEEK_API_KEY", "CODEX_HOME",
        "ANTHROPIC_AUTH_TOKEN")))
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as f:
    f.write("ARGS: " + " ".join(args) + "\n")
if args[:2] == ["login", "status"]:
    print("Logged in using ChatGPT"); sys.exit(0)
out = args[args.index("-o") + 1] if "-o" in args else None
prompt = sys.stdin.buffer.read().decode("utf-8")
emit = lambda o: print(json.dumps(o, ensure_ascii=False), flush=True)
mode = os.environ.get("FAKE_CODEX", "ok")
emit({"type": "thread.started", "thread_id": "t-1"})
if mode == "ok":
    emit({"type": "item.started", "item": {"id": "i1", "type": "command_execution", "command": "ls", "status": "in_progress"}})
    emit({"type": "item.completed", "item": {"id": "i2", "type": "agent_message", "text": "working..."}})
    open(out, "w", encoding="utf-8").write("Done. Prompt was: " + prompt)
    emit({"type": "turn.completed", "usage": {"input_tokens": 1200, "cached_input_tokens": 1000, "output_tokens": 30}})
elif mode == "limit":
    emit({"type": "error", "message": "You've hit your usage limit. Try again in 2 hours."})
    emit({"type": "turn.failed", "error": {"message": "You've hit your usage limit. Try again in 2 hours."}})
    sys.exit(1)
elif mode == "fail":
    print("some unrelated error", flush=True); sys.exit(3)
elif mode == "slow":
    time.sleep(3); open(os.environ["FAKE_LATE"], "w").write("late")
elif mode == "linger":    # like codex on Windows: a helper keeps our stdout open after codex itself exits
    import subprocess
    helper = subprocess.Popen([sys.executable, "-c", "import sys, time; time.sleep(60); open(sys.argv[1], 'w').write('late')",
                               os.environ["FAKE_LATE"]], stdout=sys.stdout, stderr=sys.stderr, close_fds=False)
    open(os.environ["FAKE_LATE"] + ".pid", "w").write(str(helper.pid))
    open(out, "w", encoding="utf-8").write("Done")
    emit({"type": "turn.completed", "usage": {"input_tokens": 10, "cached_input_tokens": 0, "output_tokens": 1}})
EOF
export ORCH_CODEX_BIN; ORCH_CODEX_BIN="$(native "$T/fakebin/fake_codex.py")"     # never the real codex
export FAKE_LOG FAKE_ENV_LOG FAKE_LATE CLAUDE_CODE_SESSION_ID=sess-test
FAKE_LOG="$(native "$T/fake.log")"; FAKE_ENV_LOG="$(native "$T/fake_env.log")"; FAKE_LATE="$(native "$T/late.txt")"
export CLAUDE_CONFIG_DIR; CLAUDE_CONFIG_DIR="$(native "$T/claude-cfg")"          # fake transcripts for orch usage

# fake claude for the DeepSeek worker: records argv/env/system prompt, answers in stream-json
cat > "$T/fakebin/fake_claude.py" <<'EOF'
import json, os, sys
args = sys.argv[1:]
opt = lambda n: args[args.index(n) + 1] if n in args else None
sp = opt("--append-system-prompt-file")
system = open(sp, encoding="utf-8").read() if sp else ""
prompt = sys.stdin.read()
rec = {"args": args, "allowed": args[args.index("--allowedTools") + 1:] if "--allowedTools" in args else [],
       "role": "Orchestra executor" in system, "claude_md": "PROJECT-RULES-MARKER" in system,
       "agents_n": system.count("AGENTS-MARKER"), "claude_n": system.count("CLAUDE-MARKER"),
       "env": {k: os.environ.get(k) for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
               "ANTHROPIC_MODEL", "CLAUDE_CONFIG_DIR", "ORCH_WORKER", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDECODE",
               "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
               "ORCH_LEAD", "ORCH_LEAD_ENV", "ORCH_PROFILES")}}
json.dump(rec, open(os.environ["FAKE_CLAUDE_LOG"], "w", encoding="utf-8"), ensure_ascii=False)
emit = lambda o: print(json.dumps(o, ensure_ascii=False), flush=True)
mode = os.environ.get("FAKE_CLAUDE", "ok")
emit({"type": "system", "subtype": "init", "model": opt("--model")})
emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "npm test"}}]}})
if mode == "ok":
    res = {"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "duration_ms": 1500,
           "result": "STATUS: DONE\nPrompt was: " + prompt.strip(),
           "usage": {"input_tokens": 100, "cache_creation_input_tokens": 50, "cache_read_input_tokens": 400, "output_tokens": 25},
           "permission_denials": [{"tool_name": "Bash", "tool_input": {"command": "npm test"}}]}
    if os.environ.get("FAKE_MODEL_ID"):        # the id an alias resolved to, as the API reports it
        res["modelUsage"] = {os.environ["FAKE_MODEL_ID"]: {"inputTokens": 100, "outputTokens": 25}}
    emit(res)
elif mode == "limit":           # Claude subscription limit
    emit({"type": "result", "subtype": "success", "is_error": True, "result": "You've hit your limit · resets 3pm"})
    sys.exit(1)
elif mode in ("402", "429", "401"):
    emit({"type": "result", "subtype": "success", "is_error": True, "api_error_status": int(mode),
          "result": "API Error: %s %s" % (mode, {"402": "Insufficient Balance", "429": "Rate Limit Reached",
                                                  "401": "Authentication Fails"}[mode])})
    sys.exit(1)
elif mode == "quota-text":      # failure whose log mentions limits: must not block the provider
    emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "quota.py has a rate limit bug (429)"}]}})
    emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "boom"})
    sys.exit(1)
EOF
export FAKE_CLAUDE_LOG; FAKE_CLAUDE_LOG="$(native "$T/claude.json")"
# check '<python expr over r (record) and a (argv)>' 'name'
check() {
  $PY -c 'import json, os, sys
r = json.load(open(sys.argv[1], encoding="utf-8")); a = r["args"]; e = r["env"]
sys.exit(0 if eval(sys.argv[2]) else 1)' "$FAKE_CLAUDE_LOG" "$1" && ok "$2" || { bad "$2"; cat "$T/claude.json"; echo; }
}

# temp git repo
REPO="$T/proj"; mkdir -p "$REPO"; cd "$REPO"
git init -q && git config user.email t@t && git config user.name t
echo "hello" > app.txt && git add . && git commit -qm init

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

echo "── run codex (fake)"
out=$(FAKE_CODEX=ok CLAUDECODE=1 CLAUDE_CODE_MESSAGING_TOKEN=parent-secret \
      $ORCH run codex --model gpt-5.6-terra --effort high --mode write "add a function"); rc=$?
expect_rc 0 $rc "successful run"
contains "$out" "\[OK\]" "status OK printed"
contains "$out" "add a function" "final output returned"
contains "$out" "Prompt was: # Role: Orchestra executor" "executor role goes before the task"
contains "$out" "STATUS: DONE | PARTIAL | BLOCKED" "role defines the report format"
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
SECONDS=0; FAKE_CODEX=linger $ORCH run codex "x" >/dev/null; rc=$?; took=$SECONDS
[[ $rc -eq 0 && $took -lt 45 ]] && ok "codex exit ends the run although a helper keeps stdout open (${took}s)" || bad "linger: rc=$rc ${took}s"
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

echo "── adapters: python, nesting guard"
mkdir -p "$T/home/adapters"
printf '#!/usr/bin/env python3\nimport os\nopen(os.environ["ORCH_OUTPUT_FILE"], "w").write("py adapter ok " + os.environ["ORCH_MODE"])\n' \
  > "$T/home/adapters/pyecho"
out=$($ORCH run pyecho "x"); rc=$?
expect_rc 0 $rc "python adapter without +x runs via orch's interpreter"
contains "$out" "py adapter ok analysis" "python adapter output"
n=$(wc -l < "$FAKE_LOG")
out=$(ORCH_WORKER=cod-1 $ORCH run codex "x" 2>&1); rc=$?
[[ $rc -ne 0 && $(wc -l < "$FAKE_LOG") -eq $n ]] && ok "nested orch run refused inside a worker" || bad "nested run: rc=$rc"
contains "$out" "nested delegation is not allowed" "nested refusal explained"
printf 'task' | ORCH_WORKER=cod-1 $ORCH handoff new --title "nested" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "nested handoff refused inside a worker" || bad "nested handoff created"

echo "── run deepseek (fake claude worker)"
export ORCH_CLAUDE_BIN; ORCH_CLAUDE_BIN="$(native "$T/fakebin/fake_claude.py")"
out=$($ORCH run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 1 $rc "no DEEPSEEK_API_KEY → failure"
contains "$out" "DEEPSEEK_API_KEY is not set" "missing key explained"
$ORCH quota check deepseek >/dev/null; expect_rc 0 $? "missing key does not mark quota"
printf '# keys\r\nexport DEEPSEEK_API_KEY="sk-from-file"\r\n' > "$T/home/secrets.env"
FAKE_CODEX=ok $ORCH run codex "x" >/dev/null
contains "$(cat "$FAKE_ENV_LOG")" "ds=none" "secrets go only to adapters that declare them"
echo "PROJECT-RULES-MARKER" > "$REPO/CLAUDE.md"
out=$(FAKE_CLAUDE=ok CLAUDECODE=1 CLAUDE_CODE_MESSAGING_TOKEN=parent-secret ANTHROPIC_AUTH_TOKEN=parent-token \
      ANTHROPIC_API_KEY=parent-key $ORCH run deepseek --model deepseek-v4-pro --effort high --mode write \
      --allow 'Bash(npm test:*)' "implement feature"); rc=$?
expect_rc 0 $rc "deepseek write run"
contains "$out" "Prompt was: implement feature" "worker result returned"
contains "$out" "denied by the executor's permissions" "permission denials surfaced to orchestrator"
contains "$out" "Bash npm test" "denied command named"
check 'e["ANTHROPIC_API_KEY"] == "sk-from-file"' "key from secrets.env (CRLF, export, quotes), parent key replaced"
check 'e["ANTHROPIC_AUTH_TOKEN"] is None' "parent ANTHROPIC_AUTH_TOKEN stripped"
check 'e["CLAUDE_CODE_MESSAGING_TOKEN"] is None and e["CLAUDECODE"] is None' "orchestrator session vars stripped"
check 'e["ANTHROPIC_BASE_URL"] == "https://api.deepseek.com/anthropic"' "DeepSeek Anthropic-compatible endpoint"
check 'e["ANTHROPIC_MODEL"] == "deepseek-v4-pro" and a[a.index("--model") + 1] == "deepseek-v4-pro"' "model passed"
check 'e["CLAUDE_CONFIG_DIR"].replace(chr(92), "/").startswith(os.environ["ORCH_HOME"] + "/workers/deepseek-")' "isolated config dir"
check 'e["ORCH_WORKER"].startswith("dee-") and e["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1"' "ORCH_WORKER set, auto-memory off"
check '"-p" in a and "--strict-mcp-config" in a and a[a.index("--setting-sources") + 1] == "user"' "headless, no MCP, no project settings/hooks"
check 'a[a.index("--permission-mode") + 1] == "dontAsk"' "dontAsk: only allowed actions run"
check '"Edit" in a[a.index("--tools") + 1] and {"Edit(./**)", "Write(./**)", "Bash(npm test:*)", "Bash(git diff:*)"} <= set(r["allowed"])' "write: edits confined to cwd + --allow rules"
check 'a[a.index("--effort") + 1] == "high"' "effort passed"
check 'r["role"] and r["claude_md"]' "role + project CLAUDE.md in system prompt"
FAKE_CLAUDE=ok DEEPSEEK_API_KEY=sk-env $ORCH run deepseek --model deepseek-flash --effort none "review" >/dev/null; rc=$?
expect_rc 0 $rc "deepseek analysis run"
check 'e["ANTHROPIC_API_KEY"] == "sk-env"' "real environment wins over secrets.env"
check '"Edit" not in a[a.index("--tools") + 1] and not any(x.startswith(("Edit", "Write")) for x in r["allowed"])' "analysis: no edit tools"
check '"--effort" not in a' "unsupported effort dropped"
out=$(FAKE_CLAUDE=402 $ORCH run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 75 $rc "402 insufficient balance → exit 75"
out=$($ORCH quota show); contains "$out" "deepseek .*exhausted .*until cleared manually" "balance blocks deepseek until manual clear"
FAKE_CLAUDE=ok $ORCH run deepseek "x" >/dev/null; expect_rc 75 $? "blocked before running while balance is empty"
$ORCH quota clear deepseek >/dev/null
out=$(FAKE_CLAUDE=429 $ORCH run deepseek "x"); rc=$?
expect_rc 75 $rc "429 rate limit → exit 75"
out=$($ORCH quota show); contains "$out" "deepseek .*exhausted .*in 1[45]m" "rate limit blocks for 15 minutes"
$ORCH quota clear deepseek >/dev/null
out=$(FAKE_CLAUDE=401 $ORCH run deepseek "x"); rc=$?
expect_rc 1 $rc "401 bad key → failure"
contains "$out" "rejected the key (401)" "bad key explained"
FAKE_CLAUDE=quota-text $ORCH run deepseek "x" >/dev/null; rc=$?
expect_rc 1 $rc "worker failure passes through"
$ORCH quota check deepseek >/dev/null; expect_rc 0 $? "limit words in worker output do not block deepseek"
rm -f "$REPO/CLAUDE.md"

echo "── claude executor, a non-Claude lead (orch launch)"
mkdir -p "$T/claude-cfg"
out=$(FAKE_CLAUDE=ok FAKE_MODEL_ID=claude-sonnet-5-5 ORCH_LEAD_ENV=ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN \
      ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic ANTHROPIC_AUTH_TOKEN=lead-token CLAUDECODE=1 \
      $ORCH run claude --model sonnet --effort high --mode write --task "Claude lane" "fix it"); rc=$?
expect_rc 0 $rc "claude executor run"
contains "$out" "Prompt was: fix it" "claude executor result returned"
check 'e["ANTHROPIC_BASE_URL"] is None and e["ANTHROPIC_AUTH_TOKEN"] is None and e["CLAUDECODE"] is None' "lead endpoint/token and session vars stripped"
check 'e["CLAUDE_CONFIG_DIR"] == os.environ["CLAUDE_CONFIG_DIR"]' "claude executor keeps your Claude config (the login)"
check 'json.loads(a[a.index("--settings") + 1]) == {"disableAllHooks": True} and a[a.index("--setting-sources") + 1] == "user"' "claude executor: no hooks, no project settings"
check '"--strict-mcp-config" in a and a[a.index("--permission-mode") + 1] == "dontAsk" and e["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1"' "claude executor: no MCP, dontAsk, no auto-memory"
check 'a[a.index("--model") + 1] == "sonnet" and a[a.index("--effort") + 1] == "high" and r["role"] and e["ORCH_WORKER"].startswith("cla-")' "alias, effort, role, ORCH_WORKER"
$PY - "$ORCH_HOME/usage.jsonl" <<'EOF' && ok "usage log: the model id the API reported for the alias" || bad "claude run ledger"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if '"Claude lane"' in l][-1]
assert r["provider"] == "claude" and r["model"] == "claude-sonnet-5-5", r
EOF
out=$(FAKE_CLAUDE=limit $ORCH run claude "x"); expect_rc 75 $? "Claude usage limit → exit 75"
out=$($ORCH quota show); contains "$out" "claude .*exhausted until .*15:00" "reset time from 'resets 3pm'"
$ORCH quota clear claude >/dev/null
$ORCH profile use claude off >/dev/null
out=$(FAKE_CLAUDE=ok $ORCH run claude "x"); expect_rc 75 $? "claude off → refused"
contains "$out" "PROFILE_OFF claude" "Claude switched off by its profile"
$ORCH profile use claude inherit >/dev/null
out=$(FAKE_CLAUDE=ok ORCH_PROFILES=claude=off $ORCH run claude "x"); expect_rc 75 $? "session choice ORCH_PROFILES=claude=off"
out=$(ORCH_PROFILES=claude=off $ORCH profile show 2>&1); contains "$out" "claude *OFF (session)" "profile show names the session choice"
FAKE_CODEX=ok ORCH_LEAD_ENV=ANTHROPIC_AUTH_TOKEN ANTHROPIC_AUTH_TOKEN=lead-token $ORCH run codex "x" >/dev/null
contains "$(cat "$FAKE_ENV_LOG")" "lead=none" "workers never get the lead's token"
out=$(CLAUDECODE=1 $ORCH launch deepseek 2>&1); expect_rc 1 $? "launch refused inside a Claude Code session"
contains "$out" "from a terminal" "launch explains where to run it"
out=$($ORCH launch codex --dry-run 2>&1); expect_rc 1 $? "a provider without orch-launch cannot lead"
out=$(ANTHROPIC_API_KEY=sk-ant-parent $ORCH launch deepseek --no-claude --use codex=alt --dry-run -- --resume 2>&1); rc=$?
expect_rc 0 $rc "launch --dry-run"
contains "$out" "Claude: off" "--no-claude: no Claude model in the session"
contains "$out" "Dropped for this session: ANTHROPIC_API_KEY" "your Anthropic key is not sent to DeepSeek"
contains "$out" "ANTHROPIC_AUTH_TOKEN=sk-f…" "DeepSeek key as the session's token"
grep -q "sk-from-file" <<<"$out" && bad "dry run printed the key" || ok "dry run masks the key"
contains "$out" "Command: .*--model deepseek-v4-pro --resume" "claude arguments after --"
contains "$out" "ORCH_PROFILES=codex=alt,claude=off" "session-wide choices go to the session"
out=$(env -u CLAUDECODE FAKE_CLAUDE=ok ANTHROPIC_API_KEY=sk-ant-parent $ORCH launch deepseek --model deepseek-flash -- --resume \
      </dev/null 2>&1); rc=$?
expect_rc 0 $rc "launch starts claude with DeepSeek as the lead"
check 'e["ANTHROPIC_BASE_URL"] == "https://api.deepseek.com/anthropic" and e["ANTHROPIC_AUTH_TOKEN"] == "sk-from-file" and e["ANTHROPIC_API_KEY"] is None' "lead: DeepSeek endpoint and token, no Anthropic key"
check 'e["ANTHROPIC_MODEL"] == e["CLAUDE_CODE_SUBAGENT_MODEL"] == "deepseek-flash" and a == ["--model", "deepseek-flash", "--resume"]' "lead model for the main thread and the subagents"
check 'e["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "deepseek-flash" and e["CLAUDE_CONFIG_DIR"] == os.environ["CLAUDE_CONFIG_DIR"]' "background calls on DeepSeek; your config and plugins"
check 'e["ORCH_LEAD"] == "deepseek" and "ANTHROPIC_AUTH_TOKEN" in e["ORCH_LEAD_ENV"] and e["ORCH_WORKER"] is None' "lead marked, not a worker"
$ORCH profile use deepseek off >/dev/null
out=$($ORCH launch deepseek --dry-run 2>&1); expect_rc 1 $? "no launch while the lead's profile is off"
$ORCH profile use deepseek inherit >/dev/null
rm -f "$ORCH_HOME/profiles.json"
out=$(ORCH_LEAD=deepseek ORCH_LEAD_MODEL=deepseek-v4-pro ORCH_PROFILES=claude=off $ORCH status)
contains "$out" "Lead: deepseek · deepseek-v4-pro .*Claude: off" "status tells a non-Claude lead who it is"
out=$(echo '{}' | ORCH_LEAD=deepseek ORCH_LEAD_MODEL=deepseek-v4-pro $ORCH hook session-start)
contains "$out" "orch guide lead" "session-start points a non-Claude lead to its guide"
out=$($ORCH guide lead); contains "$out" "orch run claude" "orch guide lead"

echo "── project rules for every executor, usage ledger"
printf '# Rules\nCLAUDE-MARKER\n@AGENTS.md\n' > "$REPO/CLAUDE.md"; printf 'AGENTS-MARKER\n' > "$REPO/AGENTS.md"
FAKE_CLAUDE=ok $ORCH run deepseek --task "Café parser tests" "x" >/dev/null
check 'r["claude_n"] == 1 and r["agents_n"] == 1' "deepseek: CLAUDE.md + AGENTS.md, @import inlined once"
FAKE_CODEX=ok $ORCH run codex --model gpt-6.1-terra --effort high "implement" >/dev/null
out=$(cat "$REPO"/.orchestra/runs/cod-*/codex_prompt.md | tail -c 2000)
contains "$out" "CLAUDE-MARKER" "codex: CLAUDE.md rules added to the prompt"
grep -q "AGENTS-MARKER" "$REPO"/.orchestra/runs/cod-*/codex_prompt.md && bad "codex got AGENTS.md twice" || ok "codex: AGENTS.md left to codex itself"
rm -f "$REPO/CLAUDE.md" "$REPO/AGENTS.md"
out=$(FAKE_CODEX=ok $ORCH run codex --model gpt-6.1-terra "Implement the café parser"); contains "$out" "tokens: input 200 · cache 1.0k · output 30" "codex usage parsed from --json (cached split out)"
$PY - "$ORCH_HOME/usage.jsonl" <<'EOF' && ok "ledger: runs with session, task, model, tokens" || bad "ledger content"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
cx = [r for r in recs if r["kind"] == "run" and r["provider"] == "codex" and r["task"] == "Implement the café parser"][-1]
ds = [r for r in recs if r["kind"] == "run" and r["provider"] == "deepseek" and r["task"] == "Café parser tests"][-1]
assert cx["session"] == "sess-test" and cx["model"] == "gpt-6.1-terra" and cx["usage"]["output_tokens"] == 30, cx
assert ds["usage"] == {"input_tokens": 150, "cached_input_tokens": 400, "output_tokens": 25, "model": "deepseek-v4-pro"}, ds
EOF
CFG="$T/claude-cfg/projects/$(native "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$CFG/sess-test/subagents"
$PY - "$CFG" <<'EOF'
import json, os, sys
d = sys.argv[1]
def a(mid, model, inp, cw, cr, out, agent=None, effort="high"):
    ev = {"type": "assistant", "timestamp": "2026-10-29T10:0%d:00.000Z" % (len(mid) % 9), "effort": effort,
          "message": {"id": mid, "model": model, "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw,
                                                          "cache_read_input_tokens": cr, "output_tokens": out}}}
    if agent:
        ev.update(isSidechain=True, agentId=agent)
    return json.dumps(ev, separators=(",", ":"))
main = [a("m1", "claude-opus-5-5", 10, 100, 1000, 50), a("m1", "claude-opus-5-5", 10, 100, 1000, 50),
        a("m22", "claude-opus-5-5", 5, 0, 2000, 20), json.dumps({"type": "ai-title", "aiTitle": "Café parser"}, separators=(",", ":"))]
open(os.path.join(d, "sess-test.jsonl"), "w", encoding="utf-8").write("\n".join(main) + "\n")
open(os.path.join(d, "sess-test", "subagents", "agent-a1.jsonl"), "w", encoding="utf-8").write(
    a("s1", "claude-sonnet-5-5", 3, 30, 300, 7, agent="a1", effort="medium") + "\n")
json.dump({"agentType": "orchestra:orch-sonnet-high", "description": "Find naïve parse calls"},
          open(os.path.join(d, "sess-test", "subagents", "agent-a1.meta.json"), "w", encoding="utf-8"), ensure_ascii=False)
EOF
out=$($ORCH usage)
contains "$out" "Session sess-tes · “Café parser”" "usage: current session with its title"
contains "$out" "orchestrator *claude-opus-5-5 *high .* 115 *3.0k *70" "main thread: streamed lines counted once"
contains "$out" "subagent orch-sonnet-high *claude-sonnet-5-5 *medium *Find naïve parse calls" "subagent: type, model, what for"
contains "$out" "codex *gpt-6.1-terra *.*Implement the café parser · OK" "CLI executor in the session report"
contains "$out" "deepseek *deepseek-v4-pro .*Café parser tests" "DeepSeek executor in the session report"
echo "{\"session_id\": \"sess-test\", \"transcript_path\": \"$(native "$CFG/sess-test.jsonl")\", \"cwd\": \"$(native "$REPO")\"}" | \
  $ORCH hook session-end >"$T/se.out"; rc=$?
[[ $rc -eq 0 && ! -s "$T/se.out" ]] && ok "SessionEnd hook silent" || bad "session-end: rc=$rc $(cat "$T/se.out")"
mv "$CFG" "$T/cfg-gone"
out=$($ORCH usage --session sess-test); contains "$out" "orchestrator *claude-opus-5-5" "usage survives transcript cleanup (SessionEnd snapshot)"
out=$($ORCH usage --list); contains "$out" "sess-tes *Café parser" "usage --list shows the project's sessions"
mv "$T/cfg-gone" "$CFG"
$PY - "$CFG" <<'EOF'
import json, os, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
ev = {"type": "assistant", "timestamp": "2026-10-29T11:00:00.000Z", "message": {"id": "d1", "model": "deepseek-v4-pro",
      "usage": {"input_tokens": 9, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 90, "output_tokens": 4}}}
open(os.path.join(sys.argv[1], "sess-lead.jsonl"), "w", encoding="utf-8").write(
    c(ev) + "\n" + c({"type": "cost-state", "totalCostUSD": 1.5}) + "\n")
EOF
out=$($ORCH usage --session sess-lead); contains "$out" "lead: deepseek-v4-pro" "a DeepSeek-led session is recognised in its transcript"
contains "$out" "assumes Claude prices" "no misleading Claude cost estimate for a DeepSeek lead"

echo "── worktree"
out=$($ORCH worktree add feat-x); contains "$out" "proj.wt/feat-x" "worktree created next to repo"
git -C "$REPO" branch | grep -q "orch/feat-x" && ok "branch orch/feat-x" || bad "branch missing"
grep -q ".orchestra/" "$REPO/.git/info/exclude" && ok ".orchestra/ excluded from git" || bad "exclude missing"

echo "── handoff"
out=$(printf '## Goal\nDo X — naïve café ✓\n' | $ORCH handoff new --title "UI check" --model "Gemini 4 Argon" --model-key gemini-4-argon --effort High --worktree --fallback "codex gpt-5.6-sol high")
contains "$out" "AG-0001" "handoff id assigned"
contains "$out" "Execute the task described in .orchestra/handoffs/AG-0001/TASK.md" "paste line in card"
WT="$T/proj.wt/AG-0001"
[[ -f "$WT/.orchestra/handoffs/AG-0001/TASK.md" ]] && ok "TASK.md inside worktree" || bad "TASK.md missing"
grep -q "STATUS: IN_PROGRESS" "$WT/.orchestra/handoffs/AG-0001/TASK.md" && ok "protocol appended" || bad "protocol missing"
grep -q "ag/ag-0001" "$WT/.orchestra/handoffs/AG-0001/TASK.md" && ok "branch named in TASK.md" || bad "branch not in TASK"
out=$($ORCH handoff list); contains "$out" "AG-0001 *WAITING" "state WAITING"
out=$($ORCH handoff check); contains "$out" "No new events" "no events yet"
sleep 2; echo "edit by antigravity" >> "$WT/app.txt"
out=$($ORCH handoff list); contains "$out" "AG-0001 *STARTED?" "file activity in worktree → STARTED?"
echo "STATUS: IN_PROGRESS" > "$WT/.orchestra/handoffs/AG-0001/RESULT.md"
out=$($ORCH handoff check); contains "$out" "AG-0001 picked up" "start detected from RESULT.md"
printf 'STATUS: DONE\n## Summary\nall good\n' > "$WT/.orchestra/handoffs/AG-0001/RESULT.md"
out=$($ORCH hook stop </dev/null); contains "$out" '"decision": "block"' "Stop hook blocks on completion"
contains "$out" "AG-0001 finished: STATUS DONE" "completion text in Stop reason"
out=$($ORCH hook stop </dev/null); [[ -z "$out" ]] && ok "event reported only once" || bad "event repeated: $out"

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

echo "── reminders & wait"
printf 'task' | $ORCH handoff new --title "remind" --pickup-min 0 --reassign-min 999 --max-open 9 >/dev/null
out=$($ORCH handoff check); contains "$out" "waiting for the operator" "pickup reminder"
printf 'task' | $ORCH handoff new --title "stale" --pickup-min 0 --reassign-min 0 --max-open 9 >/dev/null
out=$($ORCH handoff check); contains "$out" "not started .* Reassign" "reassign suggestion"
ID=$(printf 'task' | $ORCH handoff new --title "waitme" --max-open 9 | head -1 | grep -o 'AG-[0-9]*')
( sleep 3; printf 'STATUS: DONE\nok\n' > "$REPO/.orchestra/handoffs/$ID/RESULT.md" ) &
out=$($ORCH handoff wait "$ID" --interval 1 --timeout 1m); rc=$?
expect_rc 0 $rc "wait returns on DONE"
contains "$out" "$ID: STATUS DONE" "wait prints result"
ID2=$(printf 'task' | $ORCH handoff new --title "blocked" --max-open 9 | head -1 | grep -o 'AG-[0-9]*')
printf 'STATUS: BLOCKED\nneed creds\n' > "$REPO/.orchestra/handoffs/$ID2/RESULT.md"
$ORCH handoff wait "$ID2" --interval 1 --timeout 10s >/dev/null; expect_rc 2 $? "wait returns 2 on BLOCKED"
$ORCH handoff done AG-0003 --note "operator said “done”" >/dev/null
out=$($ORCH handoff show AG-0003); contains "$out" "DONE" "manual done recorded"

echo "── manual pool: offer → take → result"
echo "PROJECT-RULES-MARKER" > "$REPO/CLAUDE.md"; git -C "$REPO" add CLAUDE.md && git -C "$REPO" commit -qm rules
out=$(printf '## Goal\nCheck the form — café ✓\n' | $ORCH handoff offer --title "UI form check" --model "Gemini 4 Argon" \
      --model-key gemini-4-argon --effort High --worktree --fallback "codex gpt-6.1-sol high"); rc=$?
expect_rc 0 $rc "task offered to the pool"
PID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
contains "$out" "in the manual pool" "pool card shown"
[[ -d "$T/proj.wt/$PID" ]] && bad "worktree created before anyone took the task" || ok "no worktree until taken"
out=$($ORCH handoff list); contains "$out" "Pool — available to take (1)" "list shows the pool"
contains "$out" "$PID *OFFERED" "offered state"
grep -q "Pool — available to take (1)" "$REPO/.orchestra/MANUAL.md" && ok "board .orchestra/MANUAL.md lists the pool" || bad "board missing pool"
printf 'x' | $ORCH handoff new --title "taken" --max-open 99 >/dev/null
n_taken=$($ORCH handoff list --json | $PY -c "import json,sys; print(sum(1 for m in json.load(sys.stdin) if m['state'] in ('WAITING','STARTED?','IN_PROGRESS')))")
printf 'x' | $ORCH handoff new --title "cap" --max-open "$((n_taken + 1))" >/dev/null; expect_rc 0 $? "pooled tasks do not count against max_open"
out=$($ORCH handoff take "$PID" --max-open 99); rc=$?
expect_rc 0 $rc "operator takes the task"
contains "$out" "Open in Antigravity: .*proj.wt/$PID" "take creates the worktree card"
contains "$out" "Execute the task described in .orchestra/handoffs/$PID/TASK.md" "paste line after take"
TW="$T/proj.wt/$PID"
grep -q "an executor in the Orchestra system" "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "TASK.md: executor role for the manual agent" || bad "role missing"
grep -q 'Project rules.*`CLAUDE.md`' "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "TASK.md points to the project rules" || bad "rules pointer missing"
grep -q "AGENT:" "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "protocol asks the agent to name itself" || bad "AGENT line missing"
grep -q "trigger: always_on" "$TW/.agents/rules/orchestra-task.md" 2>/dev/null && ok "Antigravity workspace rule in the task worktree" || bad "rule file missing"
[[ -z "$(git -C "$TW" status --porcelain)" ]] && ok "rule and task files stay out of git status" || bad "git status: $(git -C "$TW" status --porcelain)"
out=$($ORCH handoff take "$PID"); contains "$out" "already handed out" "second take shows the existing card"
printf 'STATUS: DONE\nAGENT: Antigravity · Gemini 4 Argon\n## Summary\nok\n' > "$TW/.orchestra/handoffs/$PID/RESULT.md"
out=$($ORCH handoff check); contains "$out" "$PID finished: STATUS DONE — UI form check (Antigravity · Gemini 4 Argon)" "completion names the agent"
$PY - "$ORCH_HOME/usage.jsonl" "$PID" <<'EOF' && ok "manual task in the usage ledger (agent, model, session)" || bad "handoff ledger"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if '"handoff"' in l and sys.argv[2] in l][-1]
assert r["agent"] == "Antigravity · Gemini 4 Argon" and r["model"] == "Gemini 4 Argon" and r["session"] == "sess-test", r
EOF
out=$($ORCH usage); contains "$out" "antigravity (manual) *Antigravity · Gemini" "manual task in the session report"
out=$(printf 'x' | $ORCH handoff offer --title "stale offer"); OID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
contains "$out" "No take from the pool for 5 min → the orchestrator starts taking tasks back, one at a time" "pool card explains the reclaim clock"
grep -q "After 5 min without a take the orchestrator starts taking tasks back" "$REPO/.orchestra/MANUAL.md" && ok "board explains the pool clock" || bad "board: no pool clock"
$ORCH handoff reclaim "$OID" >/dev/null; out=$($ORCH handoff list); grep -q "$OID" <<<"$out" && bad "reclaimed offer still listed" || ok "reclaim takes it back"
out=$(printf 'x' | $ORCH handoff offer --title "for cursor"); CID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
out=$($ORCH handoff take "$CID" --agent cursor --max-open 99); contains "$out" "Open in Cursor" "take for another manual agent"
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
out=$($ORCH handoff check)
contains "$out" "Manual pool: no task taken for 5 min (since the pool opened; check 1, every 5 min)" "first pool check after 5 min without a take"
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
for i in 1 2 3 4 5; do printf 'x' | $ORCH handoff offer --title "bulk $i" --check-min 999 >/dev/null; done
printf 'x' | $ORCH handoff offer --title "too many" >/dev/null; expect_rc 75 $? "pool size limited (max_offers)"
git -C "$REPO" rm -q CLAUDE.md && git -C "$REPO" commit -qm "drop rules"

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
out=$(cd /; echo "{\"cwd\": \"$(native "$REPO")\"}" | $ORCH hook user-prompt); rc=$?
expect_rc 0 $rc "user-prompt hook resolves project from hook cwd"
out=$(echo 'not json' | $ORCH hook stop); expect_rc 0 $? "hook survives garbage input"
out=$(echo '{}' | sh "$PLUGIN/hooks/run.sh" session-start); contains "$out" "executor registry" "hooks/run.sh launcher finds python"
out=$(echo '{}' | PATH=/nonexistent /bin/sh "$PLUGIN/hooks/run.sh" stop); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "launcher is a silent no-op without python" || bad "launcher without python: rc=$rc out=$out"
out=$(echo '{}' | ORCH_WORKER=dee-1 $ORCH hook session-start); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "hooks silent inside a worker" || bad "worker hook: rc=$rc out=$out"
out=$(echo '{}' | ORCH_WORKER=dee-1 sh "$PLUGIN/hooks/run.sh" session-start); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "launcher skips python inside a worker" || bad "worker launcher: rc=$rc out=$out"

echo "── profiles"
out=$($ORCH profile show); contains "$out" "deepseek *default (built-in) · no limits" "no profiles → built-in profile, no limits"
[[ -f "$ORCH_HOME/profiles.json" ]] && bad "show created profiles.json" || ok "show does not create profiles.json"
printf 'DEEPSEEK_API_KEY_WORK=sk-work\n' >> "$T/home/secrets.env"
$ORCH profile set deepseek personal --key DEEPSEEK_API_KEY --default >/dev/null
$ORCH profile set deepseek work --key DEEPSEEK_API_KEY_WORK --models deepseek-flash,deepseek-v4-pro --max-effort high \
  --write no --use-for tests,review --rules "open-source code only" >/dev/null; expect_rc 0 $? "profile created"
$ORCH profile set deepseek bad --key sk-12345 >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "key value instead of a variable name refused" || bad "key value accepted"
grep -q "sk-" "$ORCH_HOME/profiles.json" && bad "key leaked into profiles.json" || ok "profiles.json holds only variable names"
$ORCH profile set antigravity x --home /tmp >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "field the provider does not take refused" || bad "field accepted"
$ORCH profile use deepseek nope >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "unknown profile refused" || bad "unknown profile bound"
out=$($ORCH profile show); contains "$out" "deepseek *personal (default)" "provider default applies"
contains "$out" "codex *default (built-in)" "providers without profiles keep the built-in one"
$ORCH profile use deepseek work >/dev/null
out=$($ORCH profile show); contains "$out" "deepseek *work (project)" "project binding wins over the default"
contains "$out" "rules: open-source code only" "rules shown to the orchestrator"
out=$($ORCH status); contains "$out" "Executor profiles" "status shows profiles"
out=$(echo '{}' | $ORCH hook session-start); contains "$out" "deepseek *work (project)" "session-start tells the orchestrator the profiles"
rm -f "$T/claude.json"
out=$(FAKE_CLAUDE=ok $ORCH run deepseek --effort max "x"); rc=$?
expect_rc 0 $rc "run under the project profile"
check 'e["ANTHROPIC_API_KEY"] == "sk-work"' "profile key reaches the worker as DEEPSEEK_API_KEY"
check 'a[a.index("--model") + 1] == "deepseek-flash"' "first allowed model is the profile default"
check 'a[a.index("--effort") + 1] == "high"' "effort capped by the profile"
contains "$out" "deepseek@work deepseek-flash" "run reports profile and model"
contains "$out" "effort max → high" "cap noted in the result"
FAKE_CLAUDE=ok $ORCH run deepseek --model 'deepseek-flash[1m]' "x" >/dev/null; expect_rc 0 $? "[1m] variant of an allowed model"
rm -f "$T/claude.json"
out=$($ORCH run deepseek --model deepseek-v3 "x"); rc=$?
expect_rc 75 $rc "model outside the profile → 75"
contains "$out" "PROFILE_DENIED" "denial explained"
[[ -f "$T/claude.json" ]] && bad "adapter ran despite the denial" || ok "adapter not started on denial"
out=$($ORCH run deepseek --mode write "x"); rc=$?
expect_rc 75 $rc "write denied by the profile"
contains "$out" "analysis only" "write denial explained"
FAKE_CLAUDE=402 $ORCH run deepseek "x" >/dev/null; expect_rc 75 $? "402 under a profile"
out=$($ORCH quota show); contains "$out" "deepseek@work *exhausted" "empty balance blocks only that profile's key"
FAKE_CLAUDE=ok $ORCH run deepseek "x" >/dev/null; expect_rc 75 $? "blocked profile refuses before running"
mkdir -p "$T/other"
FAKE_CLAUDE=ok $ORCH run deepseek --cd "$(native "$T/other")" "x" >/dev/null; expect_rc 0 $? "another directory (default profile) still runs"
check 'e["ANTHROPIC_API_KEY"] == "sk-from-file"' "default profile uses its own key"
$ORCH quota clear deepseek >/dev/null
$ORCH quota check deepseek@work >/dev/null; expect_rc 0 $? "quota clear <provider> also clears its profiles"
$ORCH profile use deepseek off >/dev/null
rm -f "$T/claude.json"
out=$($ORCH run deepseek "x"); rc=$?
expect_rc 75 $rc "provider off for the project → 75"
contains "$out" "PROFILE_OFF" "off explained"
[[ -f "$T/claude.json" ]] && bad "adapter ran while off" || ok "adapter not started while off"
FAKE_CLAUDE=ok $ORCH run deepseek --profile personal "x" >/dev/null; expect_rc 0 $? "explicit --profile for one run"
$ORCH profile use deepseek inherit >/dev/null
out=$($ORCH profile show); contains "$out" "deepseek *personal (default)" "inherit → back to the default"
$ORCH profile use deepseek work >/dev/null
out=$($ORCH profile show --path "$(native "$T/proj.wt/feat-x")"); contains "$out" "deepseek *work (project)" "worktree inherits its project's profile"
$ORCH profile set deepseek nokey --key DEEPSEEK_API_KEY_MISSING >/dev/null
out=$($ORCH run deepseek --profile nokey "x"); expect_rc 1 $? "profile key missing → failure before start"
contains "$out" "DEEPSEEK_API_KEY_MISSING" "missing profile key named"
$ORCH profile set codex alt --home "$(native "$T/cxhome")" --codex-profile fast >/dev/null
[[ -d "$T/cxhome" ]] && ok "codex profile home created" || bad "codex home not created"
$ORCH profile use codex off --path "$(native "$T")" >/dev/null
FAKE_CODEX=ok $ORCH run codex "x" >/dev/null; expect_rc 75 $? "parent directory binding covers projects inside"
$ORCH profile use codex alt >/dev/null
FAKE_CODEX=ok $ORCH run codex "x" >/dev/null; expect_rc 0 $? "nearer (project) binding wins"
contains "$(cat "$FAKE_ENV_LOG")" "cxhome=.*cxhome" "codex account: CODEX_HOME from the profile"
contains "$(tail -1 "$FAKE_LOG")" "--profile fast" "codex config profile passed"
$ORCH profile use antigravity off >/dev/null
printf 'task' | $ORCH handoff new --title "ag off" --max-open 99 --force >/dev/null; expect_rc 75 $? "Antigravity off: no handoffs, even with --force"
$ORCH profile set antigravity argon --models gemini-4-argon --max-open 0 >/dev/null
$ORCH profile use antigravity argon >/dev/null
printf 'task' | $ORCH handoff new --title "flash" --model-key gemini-3.8-flash --max-open 99 >/dev/null; expect_rc 75 $? "manual model outside the profile refused"
printf 'task' | $ORCH handoff new --title "cap" --model-key gemini-4-argon --max-open 99 >/dev/null; expect_rc 75 $? "profile max_open caps open handoffs"
$ORCH profile set antigravity argon --max-open "" >/dev/null
out=$(printf 'task' | $ORCH handoff new --title "argon" --model-key gemini-4-argon --max-open 99); expect_rc 0 $? "allowed manual model passes"
grep -q '"profile": "argon"' "$REPO/.orchestra/handoffs/$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)/meta.json" && \
  ok "handoff records its profile" || bad "handoff profile missing"
out=$($ORCH doctor </dev/null); contains "$out" "deepseek@work key *DEEPSEEK_API_KEY_WORK set" "doctor checks profile keys"
$ORCH profile rm deepseek work >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "bound profile not removed silently" || bad "bound profile removed"
$ORCH profile rm deepseek work --force >/dev/null; out=$($ORCH profile show); contains "$out" "deepseek *personal (default)" "rm --force drops its bindings"
$PY -B - "$PLUGIN/bin/orch" <<'EOF' && ok "directory keys equal in Windows and WSL; profile quota keys" || bad "canon_path / key_chain"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
c = m.canon_path
assert c("/mnt/c/Users/Me/Proj/") == c("C:\\Users\\me\\proj") == "c:/users/me/proj"
assert c("/home/me/x/") == "/home/me/x" and c("C:\\") == "c:/"
chain = m.key_chain("deepseek@work/deepseek-flash")
assert chain == ["deepseek@work/deepseek-flash", "deepseek/deepseek-flash", "deepseek@work", "deepseek"], chain
assert m.key_chain("codex/gpt-5.6-sol") == ["codex/gpt-5.6-sol", "codex"]
EOF
echo '{broken' > "$ORCH_HOME/profiles.json"
FAKE_CODEX=ok $ORCH run codex "x" >/dev/null; expect_rc 1 $? "broken profiles.json → refuse (an off must not turn into on)"
out=$(echo '{}' | $ORCH hook session-start); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "is unreadable" "session-start warns about a broken profiles.json" || bad "hook failed: rc=$rc"
rm -f "$ORCH_HOME/profiles.json"

echo "── Claude budget (statusline → surplus / tight)"
now=$($PY -c "import time; print(int(time.time()))")
sl() { printf '{"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s}%s}}' \
         "$1" "$2" "${3:-}" | $ORCH statusline; }
week() { printf ',"seven_day":{"used_percentage":%s,"resets_at":%s}' "$1" "$((now + 259200))"; }
out=$(echo '{}' | $ORCH statusline); rc=$?; [[ $rc -eq 0 && -n "$out" ]] && ok "statusline works without rate_limits" || bad "statusline: rc=$rc"
out=$(echo 'garbage' | $ORCH statusline); expect_rc 0 $? "statusline survives garbage input"
out=$($ORCH budget); contains "$out" "No current Claude subscription numbers" "budget: no numbers yet"
out=$(sl 10 $((now + 7200)) "$(week 40)")
contains "$out" "Opus 5.5 · 5h 10% → .* · week 40% · surplus: Claude first" "statusline shows the usage and the surplus mode"
[[ -f "$ORCH_HOME/claude_usage.json" ]] && ok "statusline keeps the snapshot in ORCH_HOME" || bad "no snapshot"
out=$($ORCH status); contains "$out" "SURPLUS: about 8[0-9]% of the window would expire unused" "status: surplus projected from the pace"
out=$(echo '{}' | $ORCH hook session-start); contains "$out" "Claude subscription: 5-hour window 10% used" "session-start shows the budget"
out=$(echo '{}' | $ORCH hook user-prompt); grep -q "Claude subscription" <<<"$out" && bad "budget re-announced" || ok "the mode shown at session start is not repeated"
sl 80 $((now + 7200)) >/dev/null
out=$(echo '{}' | $ORCH hook user-prompt); contains "$out" "💡 Claude subscription: 5-hour window 80% used.*TIGHT" "a mode change → event (tight)"
out=$(echo '{}' | $ORCH hook user-prompt); grep -q "Claude subscription" <<<"$out" && bad "event repeated" || ok "a mode change is announced once"
sl 10 $((now + 7200)) "$(week 95)" >/dev/null
out=$($ORCH budget); contains "$out" "weekly limit is tight" "no surplus while the weekly limit is tight"
sl 10 $((now + 17400)) >/dev/null
out=$($ORCH budget); grep -q "SURPLUS\|TIGHT" <<<"$out" && bad "projected too early: $out" || ok "no projection in the window's first 30 minutes"
sl 10 $((now - 60)) >/dev/null
out=$($ORCH budget); contains "$out" "No current Claude subscription numbers" "numbers of a window that has reset are ignored"
sl 10 $((now + 7200)) >/dev/null
$ORCH profile set claude main --opt surplus=off >/dev/null && $ORCH profile use claude main >/dev/null
out=$($ORCH budget); grep -q "SURPLUS" <<<"$out" && bad "surplus=off ignored" || ok "profile surplus=off switches the mode off"
$ORCH profile set claude main --opt surplus=90 >/dev/null
out=$($ORCH budget); grep -q "SURPLUS" <<<"$out" && bad "threshold ignored" || ok "profile surplus=N sets the threshold"
$ORCH profile set claude main --opt surplus=200 >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "surplus out of range refused" || bad "surplus=200 accepted"
rm -f "$ORCH_HOME/profiles.json"
$ORCH budget set --used 20 --resets +3h --week 50 >/dev/null
out=$($ORCH budget); contains "$out" "20% used.*reported by the operator.*SURPLUS" "numbers reported by the operator"
out=$(echo '{}' | $ORCH statusline --then "echo mine"); contains "$out" "^mine  " "statusline --then keeps your own status line first"
$ORCH budget clear >/dev/null

echo "── registry & doctor"
out=$($ORCH registry path); contains "$out" "registry/providers.yaml" "default registry path"
$ORCH registry init >/dev/null; out=$($ORCH registry path); contains "$out" "$ORCH_HOME/providers.yaml" "user registry overrides default"
out=$($ORCH doctor); ok "doctor runs (rc=$?)"
contains "$out" "DEEPSEEK_API_KEY *set" "doctor sees the DeepSeek key"
contains "$out" "codex login *Logged in" "doctor checks the codex login"

echo "── guide, footprint, plugin wiring"
out=$($ORCH guide); contains "$out" "manual" "guide lists the reference parts"
for t in manual profiles quota usage; do
  out=$($ORCH guide $t); [[ -n "$out" ]] && ok "guide $t" || bad "guide $t empty"
done
$ORCH guide nope >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "unknown guide topic refused" || bad "guide nope accepted"
out=$($ORCH footprint); contains "$out" "$ORCH_HOME" "footprint names ORCH_HOME"
contains "$out" "  project .*proj.*\.orchestra" "footprint lists project state"
contains "$out" "claude plugin uninstall orchestra@orchestra " "footprint shows the standard uninstall"
grep -q '"SessionEnd"' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd hook registered" || bad "SessionEnd hook missing"
grep -q 'run.sh\\" session-end' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd → orch hook session-end" || bad "session-end wiring"

echo
echo "passed: $pass  failed: $fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
