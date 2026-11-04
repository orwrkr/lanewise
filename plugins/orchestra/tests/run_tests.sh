#!/usr/bin/env bash
# Self-test for orch: fake codex + fake claude (DeepSeek worker) + temporary git repo + isolated ORCH_HOME.
# Runs in WSL/Linux/macOS and on Windows in Git Bash (native Windows Python).
# Usage: bash tests/run_tests.sh
set -uo pipefail
die() { echo "Self-test setup failed: $*" >&2; exit 1; }
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)" || die "cannot locate plugin"
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
T="$(mktemp -d)" || die "cannot create temporary directory"
[[ -n "$T" && -d "$T" ]] || die "invalid temporary directory"
export ORCH_HOME; ORCH_HOME="$(native "$T/home")"
export PATH="$T/fakebin:$PATH"
unset CLAUDE_PROJECT_DIR ORCH_PROJECT_DIR ORCH_WORKER ORCH_CODEX_BIN ORCH_CLAUDE_BIN DEEPSEEK_API_KEY ORCH_NOTIFY_CMD
export CODEX_HOME; CODEX_HOME="$(native "$T/no-codex")"     # the status line must never read the real ~/.codex here
pass=0; fail=0
last_check=$SECONDS
timing() { if [[ ${ORCH_TEST_TIMING:-0} == 1 ]]; then printf "  [timing %ss] %s\n" "$((SECONDS-last_check))" "$1"; fi; last_check=$SECONDS; }
ok()   { timing "$1"; echo "  ✔ $1"; pass=$((pass+1)); }
bad()  { timing "$1"; echo "  ✘ $1"; fail=$((fail+1)); }
expect_rc() { local want=$1 got=$2 name=$3; [[ "$got" == "$want" ]] && ok "$name (rc=$got)" || bad "$name: rc=$got, want $want"; }
# output is compared with Windows backslashes turned into slashes
contains() {
  local text="${1//\\//}" pattern=$2 matched=1
  # Literal patterns need no grep process. Keep grep's BRE semantics for regexes.
  if [[ "$pattern" != *"."* && "$pattern" != *"["* && "$pattern" != *"*"* &&
        "$pattern" != *"^"* && "$pattern" != *"$"* && "$pattern" != *\\* &&
        "$pattern" != *$'\n'* ]]; then
    [[ "$text" == *"$pattern"* ]] && matched=0
  else
    grep -q -- "$pattern" <<<"$text" && matched=0
  fi
  [[ $matched -eq 0 ]] && ok "$3" || { bad "$3"; echo "----- output -----"; echo "$1"; echo "------------------"; }
}

# fake codex (`codex exec --json` event stream): behaviour selected by FAKE_CODEX env
mkdir -p "$T/fakebin" "$T/home" "$T/no-codex" || die "cannot create fake and home directories"
cat > "$T/fakebin/fake_codex.py" <<'EOF' || die "cannot write fake codex"
import json, os, sys, time
args = sys.argv[1:]
with open(os.environ["FAKE_ENV_LOG"], "w") as f:
    f.write("msg=%s claudecode=%s worker=%s ds=%s cxhome=%s lead=%s cxkey=%s\n" % tuple(os.environ.get(k) or "none" for k in (
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDECODE", "ORCH_WORKER", "DEEPSEEK_API_KEY", "CODEX_HOME",
        "ANTHROPIC_AUTH_TOKEN", "CODEX_API_KEY")))
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
elif mode in ("blocked", "partial"):
    open(out, "w", encoding="utf-8").write("STATUS: " + mode.upper() + "\nNo complete result.\n")
    emit({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 1}})
elif mode == "preamble":
    open(out, "w", encoding="utf-8").write("Analysis complete.\nSTATUS: BLOCKED\n")
    emit({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 1}})
elif mode == "first_done":
    open(out, "w", encoding="utf-8").write("Analysis complete.\nSTATUS: DONE\nSTATUS: BLOCKED\n")
    emit({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 1}})
elif mode == "capacity":
    emit({"type": "turn.failed", "error": {"message": "Selected model is at capacity. Please try a different model."}})
    sys.exit(1)
elif mode == "limit":
    emit({"type": "error", "message": "You've hit your usage limit. Try again in 2 hours."})
    emit({"type": "turn.failed", "error": {"message": "You've hit your usage limit. Try again in 2 hours."}})
    sys.exit(1)
elif mode == "fail":
    print("some unrelated error", flush=True); sys.exit(3)
elif mode == "auth":
    print("Incorrect API key provided", flush=True); sys.exit(1)
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
cat > "$T/fakebin/fake_claude.py" <<'EOF' || die "cannot write fake claude"
import json, os, sys
args = sys.argv[1:]
opt = lambda n: args[args.index(n) + 1] if n in args else None
sp = opt("--append-system-prompt-file")
system = open(sp, encoding="utf-8").read() if sp else ""
prompt = sys.stdin.read()
rec = {"args": args, "allowed": args[args.index("--allowedTools") + 1:] if "--allowedTools" in args else [],
       "disallowed": args[args.index("--disallowedTools") + 1:args.index("--allowedTools")]
       if "--disallowedTools" in args and "--allowedTools" in args else [],
       "role": "Orchestra executor" in system, "claude_md": "PROJECT-RULES-MARKER" in system,
       "agents_n": system.count("AGENTS-MARKER"), "claude_n": system.count("CLAUDE-MARKER"),
       "env": {k: os.environ.get(k) for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
               "ANTHROPIC_MODEL", "CLAUDE_CONFIG_DIR", "ORCH_WORKER", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDECODE",
               "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
               "ORCH_LEAD", "ORCH_LEAD_ENV", "ORCH_PROFILES", "CLAUDE_CODE_OAUTH_TOKEN")}}
sf = os.path.join(os.environ.get("ORCH_HOME", ""), "sessions.json")
rec["sessions"] = json.load(open(sf, encoding="utf-8")) if os.path.isfile(sf) else {}   # consumers during the run
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
elif mode == "stream":          # reports a large usage mid-run, then keeps working (spend-limit stop tests)
    import time
    emit({"type": "assistant", "message": {"id": "stream-1", "model": opt("--model") or "deepseek-v4-pro",
          "usage": {"input_tokens": int(os.environ.get("FAKE_STREAM_INPUT", "1000000")),
                    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 0}}})
    time.sleep(int(os.environ.get("FAKE_STREAM_SLEEP", "60")))
    emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "duration_ms": 1,
          "result": "STATUS: DONE\nstreamed", "usage": {"input_tokens": 100, "cache_creation_input_tokens": 50,
          "cache_read_input_tokens": 400, "output_tokens": 25}})
elif mode == "fail_stream":     # reports partial usage, then fails without a final usage block
    emit({"type": "assistant", "message": {"id": "fs-1", "model": opt("--model") or "deepseek-v4-pro",
          "usage": {"input_tokens": 150, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 0}}})
    emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "boom"})
    sys.exit(1)
elif mode == "bad_live":        # leaves a half-written usage_live.json behind, then succeeds (poll must skip it)
    import time
    open(os.path.join(os.environ["ORCH_RUN_DIR"], "usage_live.json"), "w", encoding="utf-8").write("{half-written")
    time.sleep(int(os.environ.get("FAKE_STREAM_SLEEP", "20")))
    emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "duration_ms": 1,
          "result": "STATUS: DONE\nbad_live", "usage": {"input_tokens": 100, "cache_creation_input_tokens": 50,
          "cache_read_input_tokens": 400, "output_tokens": 25}})
EOF
export FAKE_CLAUDE_LOG; FAKE_CLAUDE_LOG="$(native "$T/claude.json")"
# check '<python expr over r (record) and a (argv)>' 'name'
check() {
  $PY -c 'import json, os, sys
r = json.load(open(sys.argv[1], encoding="utf-8")); a = r["args"]; e = r["env"]
sys.exit(0 if eval(sys.argv[2]) else 1)' "$FAKE_CLAUDE_LOG" "$1" && ok "$2" || { bad "$2"; cat "$T/claude.json"; echo; }
}

# temp git repo
REPO="$T/proj"
mkdir -p "$REPO" || die "cannot create test repository"
cd "$REPO" || die "cannot enter test repository"
T_ABS="$(cd "$T" && pwd -P)" || die "cannot resolve temporary directory"
HERE="$(pwd -P)" || die "cannot resolve test repository"
case "$HERE/" in "$T_ABS/"*) ;; *) die "test repository is outside temporary directory" ;; esac
# Refuse to initialize inside an existing repository outside the temporary directory.
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
if [[ -n "$TOP" ]]; then
  TOP="$(cd "$TOP" && pwd -P)" || die "cannot resolve existing repository"
  case "$TOP/" in "$T_ABS/"*) ;; *) die "existing repository is outside temporary directory" ;; esac
fi
git init -q || die "git init failed"
TOP="$(git rev-parse --show-toplevel)" || die "cannot find test repository root"
TOP="$(cd "$TOP" && pwd -P)" || die "cannot resolve test repository root"
case "$TOP/" in "$T_ABS/"*) ;; *) die "git repository is outside temporary directory" ;; esac
git config user.email t@t && git config user.name t || die "cannot configure test repository"
echo "hello" > app.txt && git add . && git commit -qm init || die "cannot initialize test commit"

echo "── portability guard (no machine-specific content)"
GUARD="$(native "$PLUGIN/tests/check_portable.py")"
ROOT_REPO="$(cd "$PLUGIN/../.." && pwd)"
out=$($PY "$GUARD" --root "$(native "$ROOT_REPO")" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "the repository itself is clean" || { bad "machine-specific content in the repository"; echo "$out"; }
GT="$T/guard"; mkdir -p "$GT" || die "cannot create guard repository"
git -C "$GT" init -q && git -C "$GT" config user.email t@t.invalid && git -C "$GT" config user.name t || die "guard repository"
guard_on() { printf '%s\n' "$1" > "$GT/f.txt"; $PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1; }
u=someone     # the paths are assembled here, so this file stays clean for the guard
for text in "C:/Users/$u/x" 'C:\Users\'"$u"'\x' "C:\\\\Users\\\\$u\\\\x" "/c/Users/$u/x" "/mnt/c/Users/$u/x" "/home/$u/x" "/Users/$u/x" \
            "D:/$u/x" "/mnt/d/$u/x"; do
  guard_on "see $text here" && bad "guard missed: $text" || ok "guard flags: $text"
done
for text in "C:/Users/me/x" "/home/you/x" "/path/to/x" 'C:\path\to\x' "https://github.com/x/home/y" '$T/home/z' '~/.orchestra' \
            'STATUS:\s*' "C:/Users/Public/x" 'C:\Program Files\Git' '$HOME/.local' '"C:\\"'; do
  guard_on "see $text here" && ok "guard allows: $text" || bad "guard false alarm: $text"
done
guard_on "see C:\Program Files\Git here" && ok "guard allows a system path with a space" || bad "guard false alarm on a system path"
GW="$T/guard-nogit"; mkdir -p "$GW/sub" || die "cannot create guard directory"; printf 'gitdir: /nowhere\n' > "$GW/.git"
printf 'x /home/%s/y\n' "$u" > "$GW/sub/f.txt"
$PY "$GUARD" --root "$(native "$GW")" >/dev/null 2>&1 && bad "guard passed a tree git can't read" || ok "guard still scans a worktree git can't read"
printf 'a zzguardname b\n' > "$GT/f.txt"
USER=zzguardname USERNAME=zzguardname LOGNAME=zzguardname $PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1 \
  && bad "guard missed this machine's user name" || ok "guard flags this machine's user name"
$PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1 && ok "another name is no finding" || bad "guard flagged a name that isn't this machine's"
printf 'x /home/%s/y\n' "$u" > "$GT/f.txt"; git -C "$GT" add f.txt; printf 'clean\n' > "$GT/f.txt"
( cd "$GT" && $PY "$GUARD" --staged >/dev/null 2>&1 ) && bad "guard --staged missed the index" || ok "guard --staged reads the index, not the file"
printf 'clean\n' > "$GT/f.txt"; git -C "$GT" add f.txt
printf 'subject\n\n/home/%s/y\n' "$u" > "$GT/msg"
$PY "$GUARD" --message "$(native "$GT/msg")" >/dev/null 2>&1 && bad "guard missed a commit message" || ok "guard flags a commit message"
printf 'subject\n# /home/%s/y\n' "$u" > "$GT/msg"
$PY "$GUARD" --message "$(native "$GT/msg")" >/dev/null 2>&1 && ok "guard skips comment lines in a message" || bad "guard flagged a message comment"
HOOKS="$(native "$ROOT_REPO/.githooks")"
printf 'x /home/%s/y\n' "$u" > "$GT/f.txt"; git -C "$GT" add f.txt
git -C "$GT" -c core.hooksPath="$HOOKS" commit -qm bad >/dev/null 2>&1 && bad "pre-commit let a home path through" || ok "pre-commit stops a home path"
printf 'clean\n' > "$GT/f.txt"; git -C "$GT" add f.txt
# through a file: Git Bash rewrites a `-m /home/…` argument before git ever sees it
printf 'subject /home/%s/y\n' "$u" > "$GT/msg"
git -C "$GT" -c core.hooksPath="$HOOKS" commit -q -F "$(native "$GT/msg")" >/dev/null 2>&1 && bad "commit-msg let a home path through" || ok "commit-msg stops a home path"
git -C "$GT" -c core.hooksPath="$HOOKS" commit -qm "fine" >/dev/null 2>&1 && ok "a clean commit passes both hooks" || bad "hooks stopped a clean commit"

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
check '"Edit" in a[a.index("--tools") + 1] and {"Edit(/**)", "Write(/**)", "Bash(npm test:*)", "Bash(git diff:*)"} <= set(r["allowed"]) and not any("./" in x for x in r["allowed"])' "write: edits anchored at the working directory, not at a later cd + --allow rules"
check 'a[a.index("--effort") + 1] == "high"' "effort passed"
check 'r["role"] and r["claude_md"]' "role + project CLAUDE.md in system prompt"
check '{"Read(**/.env)", "Read(**/.env.*)"} <= set(r["disallowed"])' "worker is denied .env reads"
check '{"Bash(grep *)", "Bash(rg *)", "Bash(git grep *--no-index*)", "Bash(git grep *--untracked*)"} <= set(r["disallowed"])' "worker is denied Bash searches that read ignored files"
check 'not any(".env" in x for x in r["allowed"])' "no allow rule pretends to reopen a .env file (a deny outranks it)"
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
out=$(ORCH_PROFILES=claude=off $ORCH profile show 2>&1); contains "$out" "Claude *OFF (session)" "profile show names the session choice"
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
contains "$out" "Lead: DeepSeek · DeepSeek V4 Pro .*Claude: off" "status tells a non-Claude lead who it is"
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
contains "$out" "orchestrator *Claude Opus 5.5 *high .* 115 *3.0k *70" "main thread: streamed lines counted once"
contains "$out" "subagent orch-sonnet-high *Claude Sonnet 5.5 *medium *Find naïve parse calls" "subagent: type, model, what for"
contains "$out" "Codex *GPT-6.1 Terra *.*Implement the café parser · OK" "CLI executor in the session report"
contains "$out" "DeepSeek *DeepSeek V4 Pro .*Café parser tests" "DeepSeek executor in the session report"
echo "{\"session_id\": \"sess-test\", \"transcript_path\": \"$(native "$CFG/sess-test.jsonl")\", \"cwd\": \"$(native "$REPO")\"}" | \
  $ORCH hook session-end >"$T/se.out"; rc=$?
[[ $rc -eq 0 && ! -s "$T/se.out" ]] && ok "SessionEnd hook silent" || bad "session-end: rc=$rc $(cat "$T/se.out")"
mv "$CFG" "$T/cfg-gone"
out=$($ORCH usage --session sess-test); contains "$out" "orchestrator *Claude Opus 5.5" "usage survives transcript cleanup (SessionEnd snapshot)"
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
out=$($ORCH usage --session sess-lead); contains "$out" "lead: DeepSeek V4 Pro" "a DeepSeek-led session is recognised in its transcript"
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

echo "── handoff paths: relative on disk, absolute in output, move-safe"
out=$(printf 'task' | $ORCH handoff new --title "paths" --max-open 99); HID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
$PY - "$(native "$REPO/.orchestra/handoffs/$HID/meta.json")" "$HID" <<'EOF' && ok "meta.json stores paths relative to the project root" || bad "meta.json has absolute paths"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid = sys.argv[2]
assert m["workdir"] == "." and m["task_path"] == ".orchestra/handoffs/%s/TASK.md" % hid, m
assert m["result_path"] == ".orchestra/handoffs/%s/RESULT.md" % hid, m
EOF
out=$($ORCH handoff show "$HID")
contains "$out" "$(native "$REPO")/.orchestra/handoffs/$HID/RESULT.md" "show prints the absolute result path"
$PY - "$(native "$REPO/.orchestra/MANUAL.md")" "$(native "$REPO")" <<'EOF' && ok "board shows the absolute folder" || bad "board folder not absolute"
import sys
text = open(sys.argv[1], encoding="utf-8").read().replace("\\", "/")
proj = sys.argv[2].replace("\\", "/").rstrip("/")
assert ("folder: `" + proj + "`") in text, text
EOF
out=$(printf 'x' | $ORCH handoff offer --title "wt rel" --worktree --max-offers 99); WID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
$ORCH handoff take "$WID" --max-open 99 >/dev/null
$PY - "$(native "$REPO/.orchestra/handoffs/$WID/meta.json")" "$WID" <<'EOF' && ok "worktree task keeps a relative sibling path" || bad "worktree path not relative"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid = sys.argv[2]
assert m["workdir"] == "../proj.wt/" + hid, m["workdir"]
assert m["result_path"] == "../proj.wt/%s/.orchestra/handoffs/%s/RESULT.md" % (hid, hid), m["result_path"]
EOF
mkdir -p "$REPO/sub"
out=$(cd "$REPO/sub" && $ORCH handoff list); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "$HID" "list works from a subdirectory" || bad "list from subdirectory: rc=$rc"
out=$(cd "$REPO/sub" && $ORCH handoff show "$HID")
contains "$out" "$(native "$REPO")/.orchestra/handoffs/$HID/RESULT.md" "show from a subdirectory prints the absolute path"
$ORCH handoff cancel "$HID" >/dev/null; $ORCH handoff cancel "$WID" >/dev/null

# a taken task whose project folder was moved still works; a RESULT.md at the new place is detected
MV="$T/mvproj"; mkdir -p "$MV" && cd "$MV" || die "mv repo"
git init -q && git config user.email t@t && git config user.name t
echo hi > f.txt && git add . && git commit -qm init
MA=$(printf 'task' | $ORCH handoff new --title "moved A" --max-open 99 | grep -o 'AG-[0-9]*' | head -1)
MB=$(printf 'task' | $ORCH handoff new --title "moved B" --max-open 99 | grep -o 'AG-[0-9]*' | head -1)
cd "$REPO" || die "back from mv repo"
MV2="$T/mvproj-new"; mv "$MV" "$MV2" && cd "$MV2" || die "enter moved repo"
out=$($ORCH handoff list); contains "$out" "$MA" "list after the project folder moved"
contains "$out" "$MB" "list after the move names the second task"
out=$($ORCH status); contains "$out" "Open manual tasks" "status after the move"
printf 'STATUS: DONE\nmoved result\n' > "$MV2/.orchestra/handoffs/$MA/RESULT.md"
out=$($ORCH handoff check); contains "$out" "$MA finished: STATUS DONE" "RESULT.md at the new place is detected"
out=$($ORCH handoff done "$MB" --note "marked after the move"); contains "$out" "DONE" "done after the move"
out=$($ORCH handoff show "$MB"); contains "$out" "DONE" "show after the move"
cd "$REPO" || die "back from moved repo"

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
out=$(echo '{}' | PATH=/nonexistent /bin/sh "$PLUGIN/hooks/run.sh" stop); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "launcher is a silent no-op without python" || bad "launcher without python: rc=$rc out=$out"
out=$(echo '{}' | ORCH_WORKER=dee-1 $ORCH hook session-start); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "hooks silent inside a worker" || bad "worker hook: rc=$rc out=$out"
out=$(echo '{}' | ORCH_WORKER=dee-1 sh "$PLUGIN/hooks/run.sh" session-start); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "launcher skips python inside a worker" || bad "worker launcher: rc=$rc out=$out"

echo "── profiles"
out=$($ORCH profile show); contains "$out" "DeepSeek *default (built-in) · no limits" "no profiles → built-in profile, no limits"
[[ -f "$ORCH_HOME/profiles.json" ]] && bad "show created profiles.json" || ok "show does not create profiles.json"
printf 'DEEPSEEK_API_KEY_WORK=sk-work\n' >> "$T/home/secrets.env"
$ORCH profile set deepseek personal --key DEEPSEEK_API_KEY --default >/dev/null
$ORCH profile set deepseek work --key DEEPSEEK_API_KEY_WORK --models deepseek-flash,deepseek-v4-pro --max-effort high \
  --write no --use-for tests,review --rules "open-source code only" >/dev/null; expect_rc 0 $? "profile created"
$ORCH profile set deepseek bad --key sk-12345 >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "key value instead of a variable name refused" || bad "key value accepted"
grep -q "sk-" "$ORCH_HOME/profiles.json" && bad "key leaked into profiles.json" || ok "profiles.json holds only variable names"
$ORCH profile set antigravity x --home /tmp >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "field the provider does not take refused" || bad "field accepted"
$ORCH profile use deepseek nope >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "unknown profile refused" || bad "unknown profile bound"
out=$($ORCH profile show); contains "$out" "DeepSeek *personal (default)" "provider default applies"
contains "$out" "Codex *default (built-in)" "providers without profiles keep the built-in one"
$ORCH profile use deepseek work >/dev/null
out=$($ORCH profile show); contains "$out" "DeepSeek *work (project)" "project binding wins over the default"
contains "$out" "rules: open-source code only" "rules shown to the orchestrator"
out=$($ORCH status); contains "$out" "Executor profiles" "status shows profiles"
out=$(echo '{}' | $ORCH hook session-start); contains "$out" "DeepSeek *work (project)" "session-start tells the orchestrator the profiles"
rm -f "$T/claude.json"
out=$(FAKE_CLAUDE=ok $ORCH run deepseek --effort max "x"); rc=$?
expect_rc 0 $rc "run under the project profile"
check 'e["ANTHROPIC_API_KEY"] == "sk-work"' "profile key reaches the worker as DEEPSEEK_API_KEY"
check 'a[a.index("--model") + 1] == "deepseek-flash"' "first allowed model is the profile default"
check 'a[a.index("--effort") + 1] == "high"' "effort capped by the profile"
contains "$out" "DeepSeek@work DeepSeek V4.1 Flash" "run reports profile and model"
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
out=$($ORCH profile show); contains "$out" "DeepSeek *personal (default)" "inherit → back to the default"
$ORCH profile use deepseek work >/dev/null
out=$($ORCH profile show --path "$(native "$T/proj.wt/feat-x")"); contains "$out" "DeepSeek *work (project)" "worktree inherits its project's profile"
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
out=$($ORCH doctor </dev/null); contains "$out" "DeepSeek@work key *DEEPSEEK_API_KEY_WORK set" "doctor checks profile keys"
$ORCH profile rm deepseek work >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "bound profile not removed silently" || bad "bound profile removed"
$ORCH profile rm deepseek work --force >/dev/null; out=$($ORCH profile show); contains "$out" "DeepSeek *personal (default)" "rm --force drops its bindings"
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
contains "$out" "Claude Opus 5.5 · 5h 10% → .* · week 40% .*surplus: Claude first" "statusline shows the usage and the surplus mode"
[[ -f "$ORCH_HOME/claude_usage.json" ]] && ok "statusline keeps the snapshot in ORCH_HOME" || bad "no snapshot"
out=$($ORCH status); contains "$out" "SURPLUS: at the current pace (window average) about 7[0-9]% of the window would expire unused beyond the reserve" "status: surplus beyond the reserve, projected from the pace"
out=$(echo '{}' | $ORCH hook session-start); contains "$out" "Claude subscription: 5-hour window 10% used" "session-start shows the budget"
out=$(echo '{}' | $ORCH hook user-prompt); grep -q "Claude subscription" <<<"$out" && bad "budget re-announced" || ok "the mode shown at session start is not repeated"
sl 80 $((now + 7200)) >/dev/null
out=$(echo '{}' | $ORCH hook user-prompt); contains "$out" "💡 Claude subscription:" "budget mode event marker"
contains "$out" "5-hour window 80% used.*TIGHT" "a mode change → event (tight)"
out=$(echo '{}' | $ORCH hook user-prompt); grep -q "Claude subscription" <<<"$out" && bad "event repeated" || ok "a mode change is announced once"
sl 10 $((now + 7200)) "$(week 95)" >/dev/null
out=$($ORCH budget); contains "$out" "weekly limit is tight" "no surplus while the weekly limit is tight"
$ORCH budget clear >/dev/null
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
# reserve and the pace of all sessions: snap USED [BASE_USED MINUTES_AGO] — window resets in 2 h, optional sample
snap() { $PY - "$(native "$ORCH_HOME/claude_usage.json")" "$@" <<'EOF'
import datetime as dt, json, sys
p, used = sys.argv[1], float(sys.argv[2])
t = dt.datetime.now().astimezone()
reset = (t + dt.timedelta(hours=2)).isoformat(timespec="seconds")
s = {"updated": t.isoformat(timespec="seconds"), "source": "statusline", "five_hour": {"used": used, "resets_at": reset}}
if len(sys.argv) > 3:
    s["history"] = [[(t - dt.timedelta(minutes=int(sys.argv[4]))).isoformat(timespec="seconds"), float(sys.argv[3]), reset]]
json.dump(s, open(p, "w", encoding="utf-8"))
EOF
}
snap 50
out=$($ORCH budget); grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "50% after 3 h: $out" || ok "default reserve: 50% after 3 h is neither tight nor surplus"
$ORCH profile set claude r --opt reserve=20 >/dev/null && $ORCH profile use claude r >/dev/null
out=$($ORCH budget); contains "$out" "reserve 20%.*TIGHT: at the current pace (window average) it reaches the reserve" "a larger reserve turns the same pace tight"
$ORCH profile set claude r --opt reserve=95 >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "reserve out of range refused" || bad "reserve=95 accepted"
rm -f "$ORCH_HOME/profiles.json"
snap 35
out=$($ORCH budget); contains "$out" "SURPLUS: at the current pace (window average)" "35% after 3 h at the window average: surplus"
snap 35 10 40
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (last 4[0-9] min, all sessions)" "the recent pace of all sessions wins: 10% → 35% in 40 min is tight"
# the consumers: Claude Code sessions (hooks, status line), Claude executor runs; a DeepSeek-led session doesn't count
rm -f "$ORCH_HOME/sessions.json"
echo '{"session_id": "s-a"}' | $ORCH hook user-prompt >/dev/null
echo '{"session_id": "s-b"}' | $ORCH hook user-prompt >/dev/null
echo '{"session_id": "s-lead"}' | ORCH_LEAD=deepseek $ORCH hook user-prompt >/dev/null
snap 10
out=$($ORCH budget); contains "$out" "active: 2 sessions" "active sessions counted, a DeepSeek-led one not"
contains "$out" "≈3[0-9]% for each of the 2 sessions" "the surplus is shared between the sessions"
contains "$out" "s-a .*session" "budget lists the active consumers"
out=$(printf '{"session_id": "s-c", "rate_limits": {"five_hour": {"used_percentage": 10, "resets_at": %s}}}' "$((now + 7200))" | $ORCH statusline)
contains "$out" "3 sessions" "the status line marks its session as a consumer"
echo '{"session_id": "s-b"}' | $ORCH hook session-end >/dev/null
out=$($ORCH budget); contains "$out" "active: 2 sessions" "SessionEnd removes the session"
FAKE_CLAUDE=ok $ORCH run claude --model haiku "x" >/dev/null
check 'any(v.get("kind") == "executor" for v in r["sessions"].values())' "a running Claude executor counts as a consumer"
grep -q '"executor"' "$ORCH_HOME/sessions.json" && bad "finished run still listed" || ok "the run leaves the consumer list when it ends"
rm -f "$ORCH_HOME/sessions.json"
$ORCH budget clear >/dev/null

# a single active session still shows "1 session" (never hidden); a headless sdk-* entrypoint does not register
rm -f "$ORCH_HOME/sessions.json" "$ORCH_HOME/claude_usage.json"
echo '{"session_id": "s-one"}' | $ORCH hook user-prompt >/dev/null
out=$(sl 10 $((now + 7200)))
contains "$out" "Claude Opus 5.5 · 5h 10% → .* · 1 session" "the Claude line shows a single session as 1 session"
rm -f "$ORCH_HOME/sessions.json"
snap 10
echo '{"session_id": "s-sdk"}' | CLAUDE_CODE_ENTRYPOINT=sdk-cli $ORCH hook user-prompt >/dev/null
out=$($ORCH budget); grep -q "s-sdk" <<<"$out" && bad "sdk-cli entrypoint registered as a consumer" || ok "an sdk-* entrypoint does not register as a consumer"
echo '{"session_id": "s-cli"}' | CLAUDE_CODE_ENTRYPOINT=cli $ORCH hook user-prompt >/dev/null
out=$($ORCH budget); contains "$out" "s-cli" "a cli entrypoint registers as a consumer"
rm -f "$ORCH_HOME/sessions.json"
$ORCH budget clear >/dev/null

echo "── Codex subscription limits"
cat > "$T/gen_rollout.py" <<'EOF'
import datetime as dt, json, sys
path = sys.argv[1]
used5 = float(sys.argv[2]); r5h = float(sys.argv[3])
used7 = float(sys.argv[4]); r7h = float(sys.argv[5])
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": used5, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=r5h)).timestamp())},
        "secondary": {"used_percent": used7, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(hours=r7h)).timestamp())},
        "credits": {"has_credits": False}, "plan_type": "plus"}}})
open(path, "w", encoding="utf-8").write(ev + "\n")
EOF
cx_status() { printf '{"workspace":{"current_dir":"%s"}}' "$(native "$REPO")" | $ORCH statusline; }

# defensive parsing: a good event, then rate_limits:null, a garbage line, swapped windows, a cut last line
rm -rf "$T/cx1"; mkdir -p "$T/cx1/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx1")"
$PY - "$(native "$T/cx1/sessions/2026/11/02/rollout-0001.jsonl")" <<'EOF'
import datetime as dt, json, sys
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
def ev(t, primary, secondary):
    return json.dumps({"timestamp": iso(t), "type": "event_msg", "payload": {"type": "token_count",
        "rate_limits": {"limit_id": "codex", "primary": primary, "secondary": secondary,
        "credits": {"has_credits": False}, "plan_type": "plus"}}})
h2 = now + dt.timedelta(hours=2); d7 = now + dt.timedelta(days=7)
five = lambda used: {"used_percent": used, "window_minutes": 300, "resets_at": int(h2.timestamp())}
week = lambda used: {"used_percent": used, "window_minutes": 10080, "resets_at": int(d7.timestamp())}
lines = [
    ev(now - dt.timedelta(minutes=8), five(81.0), week(95.0)),
    json.dumps({"timestamp": iso(now - dt.timedelta(minutes=7)), "type": "event_msg",
                "payload": {"type": "token_count", "rate_limits": None}}),
    "this is not json",
    ev(now - dt.timedelta(minutes=2), week(20.0), five(30.0)),
    '{"timestamp": "' + iso(now) + '", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"primary": {"used_percent": 99.0, "window_minutes": 300, "resets_at": ' + str(int(h2.timestamp())) + '}',
]
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(lines))
EOF
out=$(cx_status); contains "$out" "Codex · 5h 30%" "codex status line: compact five-hour"
contains "$out" "week 20%" "codex status line: compact week"
out=$($ORCH status)
contains "$out" "Codex subscription: 5-hour window 30% used" "codex: five-hour window read from the swapped secondary slot"
contains "$out" "week 20%" "codex: week read from the swapped primary slot"

# a rollout larger than the tail size, newest event at the end
rm -rf "$T/cx2"; mkdir -p "$T/cx2/sessions/2026/11/01"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx2")"
$PY - "$(native "$T/cx2/sessions/2026/11/01/rollout-big.jsonl")" <<'EOF'
import datetime as dt, json, sys
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
filler = "\n".join(json.dumps({"type": "noise", "i": i}) for i in range(12000)) + "\n"
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": 50.0, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=2)).timestamp())},
        "secondary": {"used_percent": 60.0, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(days=7)).timestamp())},
        "plan_type": "plus"}}})
open(sys.argv[1], "w", encoding="utf-8").write(filler + ev + "\n")
EOF
size=$(wc -c < "$T/cx2/sessions/2026/11/01/rollout-big.jsonl")
[[ $size -gt 262144 ]] && ok "codex: rollout larger than the tail size ($size bytes)" || bad "codex: rollout too small ($size bytes)"
out=$(cx_status); contains "$out" "Codex · 5h 50%" "codex: newest event found in the tail of a large file"
contains "$out" "week 60%" "codex: week found in the tail of a large file"

# an expired window is dropped
rm -rf "$T/cx3"; mkdir -p "$T/cx3/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx3")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx3/sessions/2026/11/02/rollout-0001.jsonl")" 50 -1 40 168
out=$(cx_status); contains "$out" "week 40%" "codex: valid week window kept"
grep -q "5h" <<<"$out" && bad "codex: expired five-hour window still shown: $out" || ok "codex: expired five-hour window dropped"

# no rollouts at all: no line, no error
rm -rf "$T/cx4"; mkdir -p "$T/cx4"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx4")"
out=$(cx_status); rc=$?
[[ $rc -eq 0 ]] && ok "codex: no rollouts → statusline succeeds" || bad "codex: statusline rc=$rc"
grep -q "Codex" <<<"$out" && bad "codex: line shown with no rollouts: $out" || ok "codex: no rollouts → no line"
out=$($ORCH status); grep -q "Codex subscription" <<<"$out" && bad "codex: status shows a Codex line with no rollouts" || ok "codex: no Codex line in status"

# week over the reserve cap → TIGHT
rm -rf "$T/cx5"; mkdir -p "$T/cx5/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx5")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx5/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 95 168
out=$($ORCH status)         # no status line ran first: routing must not depend on one being configured
contains "$out" "Codex subscription: 5-hour window 10% used" "codex: orch status reads the limits by itself"
contains "$out" "week 95%" "codex: week over the cap in status"
contains "$out" "TIGHT: treat Codex as low" "codex: week over the cap → TIGHT"

# weekly projection counts only after 24 h of the week
rm -rf "$T/cx6a" "$T/cx6b"; mkdir -p "$T/cx6a/sessions/2026/11/02" "$T/cx6b/sessions/2026/11/02"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx6a/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 156
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx6b/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 143
export CODEX_HOME; CODEX_HOME="$(native "$T/cx6a")"
cx_status >/dev/null
out=$($ORCH status); grep -q "TIGHT: treat Codex as low" <<<"$out" && bad "codex: weekly projection before 24 h raised TIGHT: $out" || ok "codex: weekly projection before 24 h is ignored"
CODEX_HOME="$(native "$T/cx6b")"
cx_status >/dev/null
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: weekly projection after 24 h → TIGHT"

# the 💡 event fires once on a mode change
rm -rf "$T/cx7"; mkdir -p "$T/cx7/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx7")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx7/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 168
echo '{"session_id":"s-cx"}' | $ORCH statusline >/dev/null
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook session-start); contains "$out" "Codex subscription: 5-hour window 10% used" "codex: session-start shows the Codex line"
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook user-prompt); grep -q "Codex subscription" <<<"$out" && bad "codex: event before a mode change: $out" || ok "codex: no event while the mode is unchanged"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx7/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 95 168
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: cache aged past the refresh throttle" || bad "codex: could not age the cache"
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
echo '{"session_id":"s-cx"}' | $ORCH statusline >/dev/null
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook user-prompt); contains "$out" "💡 Codex subscription:" "codex: a mode change → 💡 event"
contains "$out" "TIGHT: treat Codex as low" "codex: the event names TIGHT"
out=$(echo '{"session_id":"s-cx"}' | $ORCH hook user-prompt); grep -q "Codex subscription" <<<"$out" && bad "codex: event repeated" || ok "codex: a mode change is announced once"

# the cache is keyed per account (CODEX_HOME)
rm -rf "$T/cx8a" "$T/cx8b"; mkdir -p "$T/cx8a/sessions/2026/11/02" "$T/cx8b/sessions/2026/11/02"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx8a/sessions/2026/11/02/rollout-0001.jsonl")" 81 2 20 168
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx8b/sessions/2026/11/02/rollout-0001.jsonl")" 30 2 40 168
export CODEX_HOME; CODEX_HOME="$(native "$T/cx8a")"; cxA=$(cx_status)
CODEX_HOME="$(native "$T/cx8b")"; cxB=$(cx_status)
contains "$cxA" "Codex · 5h 81%" "codex: account A numbers"
contains "$cxB" "Codex · 5h 30%" "codex: account B numbers"
$PY - "$(native "$ORCH_HOME/codex_usage.json")" "$(native "$T/cx8a")" "$(native "$T/cx8b")" <<'EOF' && ok "codex: cache keyed per account" || bad "codex: cache not per account"
import json, sys
d = {k.replace("\\", "/"): v for k, v in json.load(open(sys.argv[1], encoding="utf-8")).items()}
a, b = sys.argv[2], sys.argv[3]
assert isinstance(d.get(a), dict) and isinstance(d.get(b), dict), list(d)
assert d[a]["five_hour"]["used"] == 81.0 and d[b]["five_hour"]["used"] == 30.0, d
EOF

# the model comes from a turn_context event in the same file as the limits; a known id is shown by its display name
cat > "$T/gen_rollout_tc.py" <<'EOF'
import datetime as dt, json, sys
path = sys.argv[1]; model = sys.argv[2]
used5 = float(sys.argv[3]); r5h = float(sys.argv[4])
used7 = float(sys.argv[5]); r7h = float(sys.argv[6])
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
tc = json.dumps({"timestamp": iso(now - dt.timedelta(minutes=3)), "type": "turn_context",
                 "payload": {"model": model, "effort": "medium"}})
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": used5, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=r5h)).timestamp())},
        "secondary": {"used_percent": used7, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(hours=r7h)).timestamp())},
        "credits": {"has_credits": False}, "plan_type": "plus"}}})
open(path, "w", encoding="utf-8").write(tc + "\n" + ev + "\n")
EOF
rm -rf "$T/cxmk" "$T/cxmu"; mkdir -p "$T/cxmk/sessions/2026/11/02" "$T/cxmu/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxmk")"
$PY "$(native "$T/gen_rollout_tc.py")" "$(native "$T/cxmk/sessions/2026/11/02/rollout-0001.jsonl")" gpt-6.1-sol 30 2 20 168
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 30%" "codex: a known model is shown by its display name"
CODEX_HOME="$(native "$T/cxmu")"
$PY "$(native "$T/gen_rollout_tc.py")" "$(native "$T/cxmu/sessions/2026/11/02/rollout-0001.jsonl")" my-custom-model-7b 30 2 20 168
out=$(cx_status); contains "$out" "my-custom-model-7b · 5h 30%" "codex: an unknown model id is shown as-is"

# a turn_context scrolled out of the tail keeps the last seen model
rm -rf "$T/cxr"; mkdir -p "$T/cxr/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxr")"
f="$(native "$T/cxr/sessions/2026/11/02/rollout-0001.jsonl")"
$PY "$(native "$T/gen_rollout_tc.py")" "$f" gpt-6.1-sol 30 2 20 168
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 30%" "codex: model seen while the turn_context is still in the tail"
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: cache aged for the retention re-scan" || bad "codex: could not age the cache"
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
$PY - "$f" <<'EOF'
import datetime as dt, json, sys
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
filler = "\n".join(json.dumps({"type": "noise", "i": i}) for i in range(12000)) + "\n"
ev = json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": 40.0, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=2)).timestamp())},
        "secondary": {"used_percent": 25.0, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(days=7)).timestamp())},
        "plan_type": "plus"}}})
open(sys.argv[1], "a", encoding="utf-8").write(filler + ev + "\n")
EOF
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 40%" "codex: model retained after the turn_context scrolled out of the tail"

# a missing week (only the five-hour window) leaves the week part out
rm -rf "$T/cxmw"; mkdir -p "$T/cxmw/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxmw")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmw/sessions/2026/11/02/rollout-0001.jsonl")" 30 2 40 -1
out=$(cx_status); contains "$out" "Codex · 5h 30%" "codex: five-hour shown without a week"
grep -q "week" <<<"$out" && bad "codex: week shown when missing: $out" || ok "codex: no week part when the week window is missing"

# the same compact mode texts as Claude, from the codex windows
rm -rf "$T/cxmo1" "$T/cxmo2" "$T/cxmo3"; mkdir -p "$T/cxmo1/sessions/2026/11/02" "$T/cxmo2/sessions/2026/11/02" "$T/cxmo3/sessions/2026/11/02"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmo1/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 95 168
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmo2/sessions/2026/11/02/rollout-0001.jsonl")" 95 2 20 168
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxmo3/sessions/2026/11/02/rollout-0001.jsonl")" 10 2 15 143
export CODEX_HOME; CODEX_HOME="$(native "$T/cxmo1")"; out=$(cx_status)
contains "$out" "week 95%" "codex: over-reserve week in the line"
contains "$out" "tight: week over reserve" "codex: over-reserve mode text"
CODEX_HOME="$(native "$T/cxmo2")"; out=$(cx_status)
contains "$out" "tight: 5h" "codex: five-hour-tight mode text"
CODEX_HOME="$(native "$T/cxmo3")"; out=$(cx_status)
contains "$out" "tight: week 101% projected" "codex: projected week mode text"

# a measurement older than the freshness constant is marked stale on the codex line too
rm -rf "$T/cxs"; mkdir -p "$T/cxs/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxs")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxs/sessions/2026/11/02/rollout-0001.jsonl")" 30 2 20 168
cx_status >/dev/null
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: measurement aged for the stale check" || bad "codex: could not age the measurement"
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict):
        for w in ("five_hour", "seven_day"):
            if isinstance(v.get(w), dict) and "measured" in v[w]:
                v[w]["measured"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=25)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "stale:" "codex: a stale measurement is marked"

# Codex profile off → no line even with data
rm -rf "$T/cxoff"; mkdir -p "$T/cxoff/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cxoff")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxoff/sessions/2026/11/02/rollout-0001.jsonl")" 81 2 20 168
out=$(cx_status); contains "$out" "Codex · 5h 81%" "codex: data present before switching off"
$ORCH profile use codex off >/dev/null
out=$(cx_status); grep -q "Codex" <<<"$out" && bad "codex: line shown while the profile is off: $out" || ok "codex: profile off → no line"
out=$($ORCH status); grep -q "Codex subscription" <<<"$out" && bad "codex: status line while the profile is off" || ok "codex: profile off → no Codex status line"
rm -f "$ORCH_HOME/profiles.json"

echo "── Codex & Claude on an API key"
export CODEX_HOME; CODEX_HOME="$(native "$T/no-codex")"
printf 'CODEX_API_KEY=sk-codex\nANTHROPIC_API_KEY_WORK=sk-ant-work\n' >> "$T/home/secrets.env"
rm -f "$ORCH_HOME/profiles.json"

# an explicit profile key passes the key; a login profile never picks it up from secrets.env
$ORCH profile set codex keyed --key CODEX_API_KEY >/dev/null; expect_rc 0 $? "codex key profile created"
FAKE_CODEX=ok $ORCH run codex --profile keyed "x" >/dev/null; expect_rc 0 $? "codex key profile runs"
contains "$(cat "$FAKE_ENV_LOG")" "cxkey=sk-codex" "codex key profile passes CODEX_API_KEY"
FAKE_CODEX=ok $ORCH run codex "x" >/dev/null; expect_rc 0 $? "a login codex profile still runs"
contains "$(cat "$FAKE_ENV_LOG")" "cxkey=none" "a login codex profile ignores a stray CODEX_API_KEY in secrets.env"
out=$(FAKE_CODEX=auth $ORCH run codex --profile keyed "x"); rc=$?
expect_rc 1 $rc "codex rejected key → exit 1, not the 75 limit"
contains "$out" "rejected the API key" "codex 401 names the key"
contains "$out" "check the key of codex@keyed" "codex 401 names the profile"
$ORCH quota check codex >/dev/null; expect_rc 0 $? "codex 401 does not block the provider"
out=$(FAKE_CODEX=auth $ORCH run codex "x"); rc=$?
expect_rc 1 $rc "codex 401 on a login account → exit 1"
contains "$out" "rejected the credentials" "a login codex 401 says to log in again, not that the API key was rejected"
contains "$out" "log in again" "the login codex 401 points at codex login"
grep -q "rejected the API key" <<<"$out" && bad "login codex 401 blames an API key: $out" || ok "login codex 401 does not blame an API key"

# a key profile is API-billed: no Codex subscription line even with rollout data present
rm -rf "$T/cxkey"; mkdir -p "$T/cxkey/sessions/2026/11/02"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cxkey/sessions/2026/11/02/rollout-0001.jsonl")" 81 2 95 168
CODEX_HOME="$(native "$T/cxkey")"
$ORCH profile use codex keyed >/dev/null
out=$(cx_status); grep -q "Codex" <<<"$out" && bad "codex key profile: limits in the status line: $out" || ok "codex key profile: no limits in the status line"
out=$($ORCH status); grep -q "Codex subscription" <<<"$out" && bad "codex key profile: Codex line in status: $out" || ok "codex key profile: no Codex subscription line"
rm -f "$ORCH_HOME/profiles.json"

# `orch key claude@<profile>` prints only the key; refused inside a worker / a non-Claude lead
$ORCH profile set claude keyed --key ANTHROPIC_API_KEY_WORK >/dev/null; expect_rc 0 $? "claude key profile created"
out=$($ORCH key claude@keyed); expect_rc 0 $? "orch key prints the key"
[[ "$out" == "sk-ant-work" ]] && ok "orch key prints only the key" || bad "orch key: got «$out»"
$ORCH key claude >/dev/null 2>&1; expect_rc 1 $? "orch key without a key profile fails"
ORCH_WORKER=w-1 $ORCH key claude@keyed >/dev/null 2>&1; expect_rc 1 $? "orch key refused in a worker"
ORCH_LEAD=deepseek $ORCH key claude@keyed >/dev/null 2>&1; expect_rc 1 $? "orch key refused for a non-Claude lead"

# `orch profile use claude <key profile>` writes apiKeyHelper to the project settings, keeps other settings
$ORCH profile use claude keyed >/dev/null; expect_rc 0 $? "claude key profile bound"
settings="$REPO/.claude/settings.local.json"
[[ -f "$settings" ]] && ok "apiKeyHelper written to settings.local.json" || bad "no settings.local.json"
$PY - "$(native "$settings")" "$(native "$PLUGIN/bin/orch")" <<'EOF' && ok "apiKeyHelper points at orch key claude@keyed" || bad "apiKeyHelper wrong"
import json, os, sys
s = json.load(open(sys.argv[1], encoding="utf-8")); h = s["apiKeyHelper"]
orch = os.path.normcase(os.path.realpath(sys.argv[2]))
assert "key" in h and "claude@keyed" in h and orch in os.path.normcase(h), h
EOF
grep -q "settings.local.json" "$REPO/.git/info/exclude" && ok "settings.local.json git-excluded" || bad "settings.local.json not git-excluded"
$PY - "$(native "$settings")" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p, encoding="utf-8")); s["other"] = "keep"; json.dump(s, open(p, "w", encoding="utf-8"))
EOF
$ORCH profile use claude inherit >/dev/null
$PY - "$(native "$settings")" <<'EOF' && ok "switching away removes only the helper, keeps other settings" || bad "helper removal wrong"
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
assert "apiKeyHelper" not in s and s.get("other") == "keep", s
EOF
# the operator's own helper is left alone
$PY - "$(native "$settings")" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p, encoding="utf-8")); s["apiKeyHelper"] = "/some/other/command"; json.dump(s, open(p, "w", encoding="utf-8"))
EOF
$ORCH profile use claude inherit >/dev/null
$PY - "$(native "$settings")" <<'EOF' && ok "operator's own helper left alone" || bad "operator helper removed"
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8")); assert s.get("apiKeyHelper") == "/some/other/command", s
EOF
# a broken settings file is refused and changed not at all
printf '{broken' > "$settings"
$ORCH profile use claude keyed >/dev/null 2>&1
$PY - "$(native "$settings")" <<'EOF' && ok "broken settings JSON refused, unchanged" || bad "broken settings JSON modified"
import sys
assert open(sys.argv[1], encoding="utf-8").read().strip() == "{broken", open(sys.argv[1], encoding="utf-8").read()
EOF
rm -rf "$REPO/.claude"

# --default targets the user settings (CLAUDE_CONFIG_DIR); --path binds without a helper
$ORCH profile use claude keyed --default >/dev/null; expect_rc 0 $? "claude key profile default set"
u="$CLAUDE_CONFIG_DIR/settings.json"
$PY - "$(native "$u")" <<'EOF' && ok "--default writes apiKeyHelper to the user settings" || bad "--default settings wrong"
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8")); assert "claude@keyed" in s["apiKeyHelper"], s
EOF
$ORCH profile use claude inherit --default >/dev/null
$PY - "$(native "$u")" <<'EOF' && ok "--default removed the helper it wrote" || bad "--default helper not removed"
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8")); assert "apiKeyHelper" not in s, s
EOF
rm -f "$u"
out=$($ORCH profile use claude keyed --path "$(native "$T/other")"); contains "$out" "covers" "profile use --path says it covers orch run claude only"
rm -f "$ORCH_HOME/profiles.json"

# a Claude run on a key profile: API-billed — passes the key, is not a subscription consumer, no TIGHT/SURPLUS
$ORCH profile set claude keyed --key ANTHROPIC_API_KEY_WORK >/dev/null
$ORCH profile use claude keyed >/dev/null
rm -f "$T/claude.json" "$ORCH_HOME/sessions.json" "$ORCH_HOME/claude_usage.json"
out=$(FAKE_CLAUDE=ok $ORCH run claude --model haiku "x"); rc=$?
expect_rc 0 $rc "claude run on a key profile"
check 'e["ANTHROPIC_API_KEY"] == "sk-ant-work"' "claude key profile passes ANTHROPIC_API_KEY"
check 'not any(v.get("kind") == "executor" for v in r["sessions"].values())' "a key-billed Claude run is not a subscription consumer"
out=$(FAKE_CLAUDE=401 $ORCH run claude --profile keyed "x"); rc=$?
expect_rc 1 $rc "claude 401 → exit 1, not 75"
contains "$out" "rejected the API key" "claude 401 names the key"
contains "$out" "check the key of claude@keyed" "claude 401 names the profile"
$ORCH quota check claude >/dev/null; expect_rc 0 $? "claude 401 does not block the provider"
# status / statusline on a key profile: no subscription line, no percentages, no numbers written to the snapshot
export CODEX_HOME; CODEX_HOME="$(native "$T/no-codex")"
rm -f "$ORCH_HOME/codex_usage.json"
now=$($PY -c "import time; print(int(time.time()))")
sl_key() { printf '{"session_id":"s-key","workspace":{"current_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":80,"resets_at":%s}}}' \
  "$(native "$REPO")" "$((now + 7200))"; }
sl_key | $ORCH statusline >/dev/null
out=$(sl_key | $ORCH statusline)
grep -q "5h" <<<"$out" && bad "claude key profile: subscription percentage in the status line: $out" || ok "claude key profile: no subscription percentage in the status line"
[[ -f "$ORCH_HOME/claude_usage.json" ]] && bad "claude key profile wrote its numbers to the shared snapshot" || ok "claude key profile does not write to the shared snapshot"
out=$($ORCH status); grep -q "Claude subscription" <<<"$out" && bad "claude key profile: subscription line in status: $out" || ok "claude key profile: no subscription line in status"
contains "$out" "bills to the profile key" "status says the Claude profile bills to the key"
rm -f "$ORCH_HOME/profiles.json" "$ORCH_HOME/sessions.json"
rm -rf "$REPO/.claude"

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
out=$(printf '{"session_id":"s-spend","workspace":{"current_dir":"%s"}}' "$SS" | ORCH_HOME="$SH" $ORCH statusline)
contains "$out" "8.10" "status line: spend fragment at ≥ 80%"
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
lacks() { if grep -qF -- "$2" <<<"${1//\\//}"; then bad "$3"; echo "$1"; else ok "$3"; fi; }
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

# below the limit: the project's own profile, its key, its label, its priorities; the field shows though inactive
out=$(fb "$FA" profile show)
contains "$out" "client (project)" "below the limit: the project's profile"
contains "$out" "fallback: personal" "below the limit: the configured profile shows its fallback"
contains "$out" "CLIENT-RULES" "below the limit: the profile's rules"
contains "$out" "prefer for: tests" "below the limit: the profile's prefer_for"
fb_run "$FA" "one" >/dev/null; expect_rc 0 $? "below the limit: a run"
check 'e["ANTHROPIC_API_KEY"] == "sk-client"' "below the limit: the run uses the project's key"
tail -n1 "$FDIR/usage.jsonl" | grep -q '"label": "deepseek@client"' && ok "below the limit: the ledger label is the project's profile" \
  || bad "below the limit: ledger label: $(tail -n1 "$FDIR/usage.jsonl")"
out=$(fb_hook "$FA" user-prompt); [[ -z "$out" ]] && ok "below the limit: no event" || bad "event below the limit: $out"

# at the limit: everything resolves to the fallback at once
fb_spent deepseek@client 0.001
out=$(fb "$FA" profile show)
contains "$out" "personal (fallback: client is at its limit)" "at the limit: show names the fallback and why"
contains "$out" "PERSONAL-RULES" "at the limit: the fallback's rules"
lacks "$out" "CLIENT-RULES" "at the limit: the exhausted profile's rules are gone"
lacks "$out" "prefer for: tests" "at the limit: the exhausted profile's prefer_for is gone"
contains "$out" "prefer for: docs" "at the limit: the fallback's prefer_for"
out=$(fb "$FA" status)
contains "$out" "personal (fallback: client is at its limit)" "at the limit: status shows it too"
out=$(fb "$FA" profile show --json)
contains "$out" '"fallback_from": "client"' "at the limit: --json names the configured profile"
out=$(fb_run "$FA" "two"); expect_rc 0 $? "at the limit: the run is not refused"
check 'e["ANTHROPIC_API_KEY"] == "sk-pers"' "at the limit: the run uses the fallback's key"
tail -n1 "$FDIR/usage.jsonl" | grep -q '"label": "deepseek@personal"' && ok "at the limit: the ledger label is the fallback's" \
  || bad "at the limit: ledger label: $(tail -n1 "$FDIR/usage.jsonl")"
out=$(fb "$FA" spend)
contains "$out" "DeepSeek@client" "spend show still lists the exhausted scope"
contains "$out" "DeepSeek@personal" "spend show lists the fallback's scope too"
out=$(ORCH_PROFILES=deepseek=client fb "$FA" profile show)
contains "$out" "personal (fallback: client is at its limit)" "a session-wide choice follows the fallback like a binding"
out=$(fb_run "$FA" --profile client "explicit"); expect_rc 75 $? "--profile bypasses the fallback: the exhausted profile refuses"
contains "$out" "SPEND_LIMIT DeepSeek@client" "--profile: the refusal names the exhausted scope"
contains "$out" "Without --profile, DeepSeek@personal (its fallback) takes over" "--profile: the refusal says what happens instead"
out=$(fb "$FB" profile show)
lacks "$out" "fallback" "another project without the field is not affected"

# events: once when it moves, once when it returns
out=$(fb_hook "$FA" user-prompt)
contains "$out" "DeepSeek@client is at its limit" "event: names the exhausted profile by its display name"
contains "$out" "moved to its fallback DeepSeek@personal" "event: names the fallback"
contains "$out" "orch spend reset deepseek@client" "event: the suggested command keeps ids"
out=$(fb_hook "$FA" user-prompt); [[ -z "$out" ]] && ok "event: the move is announced once" || bad "event repeated: $out"
out=$(fb_hook "$FA" post-tool); [[ -z "$out" ]] && ok "event: silent through PostToolUse once announced" || bad "event repeated in PostToolUse: $out"
fb "$FA" spend limit deepseek@client 5 >/dev/null
out=$(fb "$FA" profile show)
contains "$out" "client (project)" "raising the limit returns at once"
contains "$out" "CLIENT-RULES" "raising the limit: the rules return"
out=$(fb_hook "$FA" user-prompt)
contains "$out" "DeepSeek@client is usable again" "event: the way back is announced"
contains "$out" "was on its fallback DeepSeek@personal" "event: the way back names the fallback it left"
out=$(fb_hook "$FA" user-prompt); [[ -z "$out" ]] && ok "event: the return is announced once" || bad "return event repeated: $out"
fb_run "$FA" "three" >/dev/null
check 'e["ANTHROPIC_API_KEY"] == "sk-client"' "back below the limit: the run uses the project's key again"

# spend reset returns at once; continue never switches
fb "$FA" spend limit deepseek@client 0.0002 >/dev/null
out=$(fb "$FA" profile show); contains "$out" "personal (fallback: client is at its limit)" "a lowered limit moves to the fallback again"
fb "$FA" spend reset deepseek@client >/dev/null
out=$(fb "$FA" profile show); contains "$out" "client (project)" "spend reset returns at once"
fb_spent deepseek@client 0.001
fb "$FA" spend mode deepseek@client continue >/dev/null
out=$(fb "$FA" profile show)
contains "$out" "client (project)" "mode continue is never exhausted"
lacks "$out" "(fallback:" "mode continue: no fallback shown as active"
fb_run "$FA" "four" >/dev/null; expect_rc 0 $? "mode continue: the run goes on"
check 'e["ANTHROPIC_API_KEY"] == "sk-client"' "mode continue: the project's key"
fb "$FA" spend mode deepseek@client evaluate >/dev/null
out=$(fb "$FA" profile show); contains "$out" "personal (fallback: client is at its limit)" "mode evaluate counts as exhausted"
fb "$FA" spend reset deepseek@client >/dev/null
fb "$FA" spend mode deepseek@client stop >/dev/null

# availability: an entry on the profile's own key switches; on the provider or `low` it does not
fb "$FA" quota set deepseek@client exhausted >/dev/null
out=$(fb "$FA" profile show); contains "$out" "personal (fallback: client is exhausted)" "availability: exhausted on the profile's key switches"
fb "$FA" quota set deepseek@client disabled >/dev/null
out=$(fb "$FA" profile show); contains "$out" "personal (fallback: client is disabled)" "availability: disabled on the profile's key switches"
fb "$FA" quota set deepseek@client low >/dev/null
out=$(fb "$FA" profile show); contains "$out" "client (project)" "availability: low is not exhausted"
fb "$FA" quota clear deepseek@client >/dev/null
fb "$FA" quota set deepseek exhausted >/dev/null
out=$(fb "$FA" profile show); contains "$out" "client (project)" "availability: an entry on the whole provider is no reason to switch"
fb "$FA" quota clear deepseek >/dev/null
fb "$FA" quota set deepseek@client/deepseek-v4-pro exhausted >/dev/null
out=$(fb "$FA" profile show); contains "$out" "client (project)" "availability: an entry on one model of the profile is no reason to switch"
fb "$FA" quota clear deepseek@client/deepseek-v4-pro >/dev/null
# the entry orch records itself when the provider reports an empty balance (402)
out=$(FAKE_CLAUDE=402 fb_run "$FA" "empty"); expect_rc 75 $? "an empty balance (402) is exit 75"
out=$(fb "$FA" profile show); contains "$out" "personal (fallback: client is exhausted)" "a recorded 402 moves the project to its fallback"
fb "$FA" quota clear deepseek@client >/dev/null
out=$(fb "$FA" profile show); contains "$out" "client (project)" "clearing the entry returns at once"
# a rate limit is recorded with a timed reset: it blocks the profile for minutes, but is no reason to spend another key
out=$(FAKE_CLAUDE=429 fb_run "$FA" "busy"); expect_rc 75 $? "a rate limit (429) is exit 75"
out=$(fb "$FA" profile show); contains "$out" "client (project)" "a rate limit doesn't move the project to its fallback"
fb "$FA" quota clear deepseek@client >/dev/null
fb_hook "$FA" user-prompt >/dev/null          # the moves above: settle the event state

# an unreadable limits or profiles file is not exhaustion and never moves to another key
fb_spent deepseek@client 0.001
cp "$FDIR/spend_limits.json" "$FDIR/spend_limits.good"
printf '{broken' > "$FDIR/spend_limits.json"
out=$(fb "$FA" profile show); contains "$out" "client (project)" "a broken limits file: no move to another key"
lacks "$out" "(fallback:" "a broken limits file: no fallback shown as active"
out=$(fb_run "$FA" "blocked"); expect_rc 75 $? "a broken limits file: the run refuses as before"
contains "$out" "unreadable" "a broken limits file: the refusal names the file"
cp "$FDIR/spend_limits.good" "$FDIR/spend_limits.json"
cp "$FDIR/profiles.json" "$FDIR/profiles.good"
printf '{broken' > "$FDIR/profiles.json"
out=$(fb_run "$FA" "blocked"); expect_rc 1 $? "a broken profiles file: the run refuses"
contains "$out" "PROFILE_ERROR" "a broken profiles file: not a silent switch"
cp "$FDIR/profiles.good" "$FDIR/profiles.json"
out=$(fb "$FA" profile show); contains "$out" "personal (fallback: client is at its limit)" "the files restored: the fallback applies again"
fb "$FA" spend reset deepseek@client >/dev/null

# a profile without fallback behaves as before
fb_spent deepseek@plain 0.001
out=$(fb "$FB" profile show); contains "$out" "plain (project)" "no fallback: the exhausted profile stays resolved"
out=$(fb_run "$FB" "plain"); expect_rc 75 $? "no fallback: the exhausted profile refuses as before"
contains "$out" "SPEND_LIMIT DeepSeek@plain" "no fallback: the usual SPEND_LIMIT"
lacks "$out" "Without --profile" "no fallback: the refusal adds nothing"
out=$(fb_hook "$FB" user-prompt); lacks "$out" "fallback" "no fallback: no event"

# one level only; a deleted target; the note when setting a target that has a fallback
fb "$FA" profile set deepseek c1 --key FB_KEY_CLIENT --rules "C1-RULES" >/dev/null
fb "$FA" profile set deepseek c2 --key FB_KEY_PERS --rules "C2-RULES" >/dev/null
fb "$FA" profile set deepseek c3 --key FB_KEY_X --rules "C3-RULES" >/dev/null
fb "$FA" profile set deepseek c1 --fallback c2 >/dev/null
out=$(fb "$FA" profile set deepseek c2 --fallback c3); contains "$out" "fallback: c3" "a profile used as a fallback may have one of its own"
out=$(fb "$FA" profile set deepseek c1 --fallback c2); contains "$out" "only one level" "setting a target that has a fallback says one level is followed"
fb "$FA" profile use deepseek c1 --path "$FD" >/dev/null
for l in c1 c2; do
  fb "$FD" spend limit deepseek@$l 0.0002 >/dev/null; fb "$FD" spend mode deepseek@$l stop >/dev/null
  fb "$FD" spend reset deepseek@$l >/dev/null; fb_spent deepseek@$l 0.001
done
out=$(fb "$FD" profile show)
contains "$out" "c2 (fallback: c1 is at its limit)" "one level: the target of an exhausted profile"
contains "$out" "C2-RULES" "one level: the target's rules"
lacks "$out" "C3-RULES" "one level: the target's own fallback is not followed"
lacks "$out" "fallback: c3" "one level: the target shows no fallback of its own while it stands in"
out=$(fb_hook "$FD" session-start)
contains "$out" "c2 (fallback: c1 is at its limit)" "SessionStart shows the fallback"
lacks "$out" "moved to its fallback" "SessionStart records the move without announcing it"
out=$(fb_hook "$FD" user-prompt); lacks "$out" "moved to its fallback" "the move recorded at SessionStart is not announced later"
fb "$FA" profile set deepseek g1 --key FB_KEY_CLIENT >/dev/null
fb "$FA" profile set deepseek g2 --key FB_KEY_PERS >/dev/null
fb "$FA" profile set deepseek g1 --fallback g2 >/dev/null
fb "$FA" profile use deepseek g1 --path "$FC" >/dev/null
fb "$FC" spend limit deepseek@g1 0.0002 >/dev/null; fb "$FC" spend mode deepseek@g1 stop >/dev/null
fb "$FC" spend reset deepseek@g1 >/dev/null; fb_spent deepseek@g1 0.001
out=$(fb "$FC" profile show); contains "$out" "g2 (fallback: g1 is at its limit)" "a target that exists is used"
out=$(fb "$FA" profile rm deepseek g2); contains "$out" "deepseek@g1 had it as its fallback" "removing a target says who loses its fallback"
out=$(fb "$FC" profile show)
contains "$out" "g1 (project)" "a deleted target: no fallback, the profile stays"
contains "$out" "fallback: g2 (no such profile: ignored)" "a deleted target: show says so"
out=$(fb_run "$FC" "gone"); expect_rc 75 $? "a deleted target: the exhausted profile refuses"

echo "── session tokens per provider (their own status line)"
rm -rf "$T/cx9"; mkdir -p "$T/cx9/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx9")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx9/sessions/2026/11/02/rollout-0001.jsonl")" 81 2 20 168
TCFG="$T/claude-cfg/projects/$(native "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$TCFG"
$PY - "$(native "$TCFG/sess-tok.jsonl")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
def a(mid, inp, cw, cr, out):
    return c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
              "message": {"id": mid, "model": "claude-opus-5-5",
                          "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw,
                                    "cache_read_input_tokens": cr, "output_tokens": out}}})
open(sys.argv[1], "w", encoding="utf-8").write(
    a("t1", 1000, 200, 5000, 100) + "\n" + a("t2", 300, 0, 1000, 50) + "\n")
EOF
$PY - "$(native "$ORCH_HOME/usage.jsonl")" <<'EOF'
import json, sys
def rec(prov, model, inp, out):
    return json.dumps({"kind": "run", "session": "sess-tok", "provider": prov, "model": model,
                       "usage": {"input_tokens": inp, "cached_input_tokens": 0, "output_tokens": out}})
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(rec("codex", "gpt-6.1-terra", 400, 40) + "\n")
    f.write(rec("deepseek", "deepseek-v4-pro", 500, 60) + "\n")
EOF
out=$(printf '{"session_id":"sess-tok","transcript_path":"%s","workspace":{"current_dir":"%s"}}' \
      "$(native "$TCFG/sess-tok.jsonl")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Codex · 5h 81%" "status line: codex limits part"
contains "$out" "week 20%" "status line: codex week part"
contains "$out" "Session in/out: Claude 1.5k/150 · Codex 400/40 · DeepSeek 500/60" "session tokens: claude from the transcript, runs from the ledger"
[[ "$(sed -n 2p <<<"$out")" == "Codex · 5h 81%"* && "$(sed -n 3p <<<"$out")" == "Session in/out: "* ]] \
  && ok "Codex limits and session tokens are on lines of their own" || bad "status line layout: $out"
out=$(printf '{"session_id":"sess-tok","transcript_path":"%s","workspace":{"current_dir":"%s"}}' \
      "$(native "$TCFG/sess-tok.jsonl")" "$(native "$REPO")" | $ORCH statusline --then "echo mine")
contains "$out" "^mine  " "statusline --then: the operator's own line stays first"
contains "$out" "Session in/out: Claude 1.5k/150" "statusline --then keeps the Codex and session lines"
$ORCH usage --session sess-tok --json > "$T/usage-tok.json"
$PY - "$(native "$T/usage-tok.json")" <<'EOF' && ok "session tokens agree with orch usage --session" || bad "session tokens disagree with orch usage"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["rows"]
by = {}
for r in rows:
    u = r.get("usage") or {}
    by[r["who"]] = (int(u.get("input_tokens") or 0), int(u.get("output_tokens") or 0))
assert by["orchestrator"] == (1500, 150), by
assert by["codex"] == (400, 40), by
assert by["deepseek"] == (500, 60), by
assert {r["model"] for r in rows} == {"claude-opus-5-5", "gpt-6.1-terra", "deepseek-v4-pro"}, [r["model"] for r in rows]
EOF
INCF="$TCFG/sess-inc.jsonl"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
open(sys.argv[1], "w", encoding="utf-8").write(c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
    "message": {"id": "i1", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 1000, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 5000, "output_tokens": 100}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 1.2k/100" "first run counts the transcript once"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(c({"type": "assistant", "timestamp": "2026-11-02T10:05:00.000Z",
               "message": {"id": "i2", "model": "claude-opus-5-5",
                           "usage": {"input_tokens": 300, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1000, "output_tokens": 50}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 1.5k/150" "appended lines are counted once (not re-read)"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
open(sys.argv[1], "w", encoding="utf-8").write(c({"type": "assistant", "timestamp": "2026-11-02T10:06:00.000Z",
    "message": {"id": "i3", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 500, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 30}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 500/30" "a shrunken transcript restarts from scratch"
out=$(printf '{"session_id":"sess-empty","workspace":{"current_dir":"%s"}}' "$(native "$REPO")" | $ORCH statusline)
grep -q "Session in/out:" <<<"$out" && bad "session line shown with no tokens" || ok "no session line with no tokens"

echo "── session tokens per account (a profile label, never a sum over a provider)"
AH="$(native "$T/acct-home")"; mkdir -p "$AH"
acct() { ORCH_HOME="$AH" $ORCH "$@"; }
acct_sl() {      # acct_sl <session> [extra env…]: the status line of that session, run in the test repository
  local sid=$1; shift
  printf '{"session_id":"%s","transcript_path":"%s","workspace":{"current_dir":"%s"}}' \
    "$sid" "$(native "$TCFG/$sid.jsonl")" "$(native "$REPO")" | env "$@" ORCH_HOME="$AH" $ORCH statusline
}
cp "$TCFG/sess-tok.jsonl" "$TCFG/sess-acct.jsonl"       # the native thread: 1500 in / 150 out
$PY - "$AH/usage.jsonl" <<'EOF'
import json, sys
def rec(sid, prov, label, inp, out):
    r = {"kind": "run", "session": sid, "provider": prov, "model": "m",
         "usage": {"input_tokens": inp, "cached_input_tokens": 0, "output_tokens": out}}
    if label is not None:
        r["label"] = label
    return json.dumps(r)
with open(sys.argv[1], "a", encoding="utf-8") as f:
    for line in (rec("sess-acct", "deepseek", "deepseek@client", 500, 60),
                 rec("sess-acct", "deepseek", "deepseek@personal", 100, 10),
                 rec("sess-acct", "deepseek", "deepseek@client", 20, 5),
                 rec("sess-acct", "codex", None, 400, 40),               # an old record: no label
                 rec("sess-acct", "codex", "codex", 100, 10),
                 rec("sess-acct", "codex", "codex@work", 90, 10),        # a non-default login profile
                 rec("sess-acct", "claude", "claude", 200, 20),          # orch run claude on the default login
                 rec("sess-other", "deepseek", "deepseek@other", 7, 7)):
        f.write(line + "\n")
EOF
out=$(acct_sl sess-acct)
contains "$out" "Session in/out: Claude 1.7k/170 · Codex 500/50 · Codex@work 90/10 · DeepSeek@client 520/65 · DeepSeek@personal 100/10" \
  "session tokens: one counter per account, plain account first, labels alphabetical"
grep -qE "DeepSeek [0-9]|DeepSeek@other" <<<"$out" && bad "session tokens: a sum over the keys, or another session's run: $out" \
  || ok "session tokens: two keys of one provider are not added up"
contains "$out" "Codex 500/50 · Codex@work" "a run without a label counts under its provider, with the plain codex runs"
contains "$out" "Claude 1.7k/170" "orch run claude on the default login adds up with the native thread"
out2=$(acct_sl sess-acct); [[ "$out2" == "$out" ]] && ok "session tokens: a second refresh changes nothing" || bad "session tokens drifted on refresh: $out2"
# a native session billed to a key profile counts under that profile's label, the default-login run stays apart
acct profile set claude work --key ANTHROPIC_API_KEY_WORK >/dev/null
out=$(acct_sl sess-acct ORCH_PROFILES=claude=work)
contains "$out" "Session in/out: Claude 200/20 · Claude@work 1.5k/150 · Codex" "a native session on a key profile shows its label"
# its apiKeyHelper names that profile, so the thread keeps billing there while runs have moved to the fallback
acct profile set claude personal >/dev/null
acct profile set claude work --fallback personal >/dev/null
acct quota set claude@work exhausted >/dev/null
out=$(acct_sl sess-acct ORCH_PROFILES=claude=work)
contains "$out" "Session in/out: Claude 200/20 · Claude@work 1.5k/150 · Codex" "a native session keeps its key's label while runs use the fallback"
acct quota clear claude@work >/dev/null
acct profile set claude work --fallback none >/dev/null
out=$(acct_sl sess-acct)
contains "$out" "Session in/out: Claude 1.7k/170 · Codex" "the same session on the default login adds up again"
# an old-format cache entry (keyed by provider, no format mark) is rebuilt from the ledger with labels
$PY - "$AH" <<'EOF'
import json, os, sys, time
home = sys.argv[1]
size = os.path.getsize(os.path.join(home, "usage.jsonl"))
with open(os.path.join(home, "usage.jsonl"), "a", encoding="utf-8") as f:
    for label, i, o in (("deepseek@client", 500, 60), ("deepseek@personal", 100, 10)):
        f.write(json.dumps({"kind": "run", "session": "sess-old", "provider": "deepseek", "label": label,
                            "usage": {"input_tokens": i, "output_tokens": o}}) + "\n")
cache = os.path.join(home, "session_tokens.json")
data = json.load(open(cache, encoding="utf-8"))
data["sess-old"] = {"files": {}, "ledger": {"deepseek": {"input": 600, "output": 70}},
                    "ledger_offset": size + 1000000, "updated": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())}
json.dump(data, open(cache, "w", encoding="utf-8"))
EOF
out=$(acct_sl sess-old)
contains "$out" "Session in/out: DeepSeek@client 500/60 · DeepSeek@personal 100/10" "an old-format cache entry is rebuilt with labels"
grep -qE "DeepSeek [0-9]" <<<"$out" && bad "old cache: the stale provider sum survived: $out" || ok "old cache: no stale provider sum next to the keys"
out2=$(acct_sl sess-old); [[ "$out2" == "$out" ]] && ok "a rebuilt entry is not read twice" || bad "rebuilt entry drifted: $out2"
$PY - "$AH" <<'EOF' && ok "the rebuilt entry carries the format mark" || bad "the rebuilt entry has no format mark"
import json, os, sys
e = json.load(open(os.path.join(sys.argv[1], "session_tokens.json"), encoding="utf-8"))["sess-old"]
assert e.get("format") == 2 and "deepseek" not in e["ledger"] and set(e["ledger"]) == {"deepseek@client", "deepseek@personal"}, e
EOF
# a malformed cache entry and malformed ledger lines never break the status line
$PY - "$AH" <<'EOF'
import json, os, sys, time
home = sys.argv[1]
with open(os.path.join(home, "usage.jsonl"), "a", encoding="utf-8") as f:
    f.write("[1, 2]\n")
    f.write(json.dumps({"kind": "run", "session": "sess-bad", "provider": "codex", "label": "codex@work",
                        "usage": {"input_tokens": "many", "output_tokens": 1}}) + "\n")
    f.write(json.dumps({"kind": "run", "session": "sess-bad", "provider": "codex", "label": "codex@work",
                        "usage": {"input_tokens": 10, "output_tokens": 1}}) + "\n")
    for prov, i in (("deepseek", 3), ("codex", 4)):        # land on the damaged cache values below
        f.write(json.dumps({"kind": "run", "session": "sess-bad", "provider": prov,
                            "usage": {"input_tokens": i, "output_tokens": 1}}) + "\n")
cache = os.path.join(home, "session_tokens.json")
data = json.load(open(cache, encoding="utf-8"))
data["sess-bad"] = {"format": 2, "files": {"x": "junk", "y": {"in": "a", "out": None, "provider": 5}},
                    "ledger": {"deepseek": "junk", "codex": {"input": "x", "output": None}, "claude": [1]},
                    "ledger_offset": 0, "updated": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())}
json.dump(data, open(cache, "w", encoding="utf-8"))
EOF
out=$(acct_sl sess-bad); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "Session in/out: Codex 4/1 · Codex@work 10/2 · DeepSeek 3/1" "the status line survives a malformed cache entry and ledger lines" \
  || bad "malformed entry: rc=$rc out=$out"
# end to end: the labels `orch run` writes (two deepseek keys, the default claude login) reach the status line
acct profile set deepseek client --key DEEPSEEK_KEY_CLIENT >/dev/null
acct profile set deepseek personal --key DEEPSEEK_KEY_PERSONAL >/dev/null
cp "$TCFG/sess-tok.jsonl" "$TCFG/sess-e2e.jsonl"
e2e() { CLAUDE_CODE_SESSION_ID=sess-e2e FAKE_CLAUDE=ok DEEPSEEK_KEY_CLIENT=sk-a DEEPSEEK_KEY_PERSONAL=sk-b ORCH_HOME="$AH" $ORCH run "$@" >/dev/null; }
e2e deepseek --profile client "x"; expect_rc 0 $? "run on the first deepseek key"
e2e deepseek --profile personal "x"; expect_rc 0 $? "run on the second deepseek key"
e2e claude "x"; expect_rc 0 $? "run claude on the default login"
line=$(acct_sl sess-e2e | grep "^Session in/out:")
grep -qE "^Session in/out: Claude 1\.[0-9]k/[0-9]+ · DeepSeek@client [0-9]+/[0-9]+ · DeepSeek@personal [0-9]+/[0-9]+$" <<<"$line" \
  && ok "end to end: two keys and the native login, three counters" || bad "end to end session line: $line"
[[ "$line" == *"Claude 1.5k/150"* ]] && bad "end to end: the claude run did not add to the native thread: $line" \
  || ok "end to end: orch run claude adds to the native Claude counter"

echo "── rounding"
now=$($PY -c "import time; print(int(time.time()))")
out=$(sl 82.6 $((now + 7200))); contains "$out" "5h 83%" "Claude status line rounds 82.6 → 83"
out=$($ORCH status); contains "$out" "Claude subscription: 5-hour window 83% used" "Claude subscription line rounds 82.6 → 83"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx9/sessions/2026/11/02/rollout-0001.jsonl")" 82.6 2 20 168
$PY - "$(native "$ORCH_HOME/codex_usage.json")" "$(native "$T/cx9")" <<'EOF'
import datetime as dt, json, sys
p, home = sys.argv[1], sys.argv[2]
d = json.load(open(p, encoding="utf-8"))
for entry in d.values():                  # let the once-a-minute refresh run again (keys are native paths)
    if isinstance(entry, dict) and entry.get("updated"):
        entry["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "Codex · 5h 83%" "codex status line rounds 82.6 → 83"
CODEX_HOME="$(native "$T/no-codex")"

echo "── review regressions (isolated processes and deterministic snapshots)"
review=$($PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/review")" <<'EOF'
import argparse
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import traceback
from unittest import mock

orch, root = str(Path(sys.argv[1]).resolve()), Path(sys.argv[2])
root.mkdir()
home, proj = root / "home", root / "proj"
home.mkdir(); proj.mkdir()
env = dict(os.environ, ORCH_HOME=str(home), ORCH_PROJECT_DIR=str(proj), ORCH_NOTIFY_CMD="",
           PYTHONIOENCODING="utf-8", PYTHONUTF8="1", DUMMY_A="aaaaaaaaaaaa", DUMMY_B="bbbbbbbbbbbb")
for key in ("ORCH_WORKER", "ORCH_PROFILES", "CLAUDE_PROJECT_DIR", "ORCH_LEAD", "ORCH_LEAD_ENV", "CLAUDECODE"):
    env.pop(key, None)
for args in (["init", "-q"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"]):
    subprocess.run(["git"] + args, cwd=str(proj), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
(proj / "app.txt").write_text("initial\n", encoding="utf-8")
subprocess.run(["git", "add", "."], cwd=str(proj), check=True)
subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "-qm", "init"], cwd=str(proj), check=True)
os.environ.update(env)
loader = importlib.machinery.SourceFileLoader("review_orch", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("review_orch", loader)); loader.exec_module(m)
_h = importlib.machinery.SourceFileLoader("review_headless", str(Path(orch).parent.parent / "adapters" / "_claude_headless.py"))
H = importlib.util.module_from_spec(importlib.util.spec_from_loader("review_headless", _h)); _h.exec_module(H)

def run(args, data="task\n", extra=None):
    r = subprocess.run([sys.executable, orch] + args, input=data, text=True, encoding="utf-8",
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=str(proj),
                       env=dict(env, **(extra or {})), timeout=30)
    return r.returncode, r.stdout + r.stderr

def good(args, data="task\n", extra=None):
    rc, out = run(args, data, extra)
    assert rc == 0, (args, rc, out)
    return out

def start(args, data="task\n"):
    p = subprocess.Popen([sys.executable, orch] + args, env=env, cwd=str(proj), stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.stdin.write(data.encode("utf-8")); p.stdin.close(); p.stdin = None
    return p

def finish(p):
    out, err = p.communicate(timeout=30)
    return p.returncode, (out + err).decode("utf-8", "replace")

def offered(**kw):
    args = ["handoff", "offer", "--title", "review", "--max-offers", "50"]
    for k, v in kw.items():
        args += ["--" + k.replace("_", "-")] + ([] if v is True else [str(v)])
    return re.search(r"AG-\d+", good(args)).group()

def meta(hid):
    return m.read_json(m.handoffs_root() / hid / "meta.json", {})

def clear_tasks():
    for task in m.all_metas():
        if not task.get("archived"):
            good(["handoff", "cancel", task["id"]]); good(["handoff", "close", task["id"]])

def parallel_state():
    results = [finish(p) for p in [start(["handoff", "offer", "--title", "parallel-%d" % i,
                                         "--max-offers", "50"]) for i in range(4)]]
    assert all(rc == 0 and "Traceback" not in out for rc, out in results), results
    ids = [re.search(r"AG-\d+", out).group() for _, out in results]
    assert len(set(ids)) == 4
    assert {meta(h)["title"] for h in ids} == {"parallel-%d" % i for i in range(4)}
    for _ in range(2):
        hid = offered(worktree=True)
        take = start(["handoff", "take", hid]); reclaim = start(["handoff", "reclaim", hid])
        results = [finish(take), finish(reclaim)]
        assert sorted(rc for rc, _ in results) == [0, 1], results
        task = meta(hid)
        assert bool(task.get("taken")) != bool(task.get("reclaim")), task
        good(["handoff", "cancel", hid])
    ps = [start(["statusline"], json.dumps({"session_id": "parallel-%d" % i,
          "workspace": {"current_dir": str(proj)}, "rate_limits": {
              "five_hour": {"used_percentage": 10, "resets_at": 4102444800}}})) for i in range(8)]
    assert all(rc == 0 and "Traceback" not in out for rc, out in map(finish, ps))
    sessions = m.read_json(home / "sessions.json", {})
    assert all("parallel-%d" % i in sessions for i in range(8)), sessions
    assert not list(home.glob("*.tmp"))
    counter = m.handoffs_root() / "counter.json"
    high = max(int(x["id"].split("-")[1]) for x in m.all_metas())
    for corrupt in (True, False):
        if corrupt:
            counter.write_text("{broken", encoding="utf-8")
        else:
            counter.unlink()
        assert int(offered().split("-")[1]) > high
        high += 1
    clear_tasks()
    results = [finish(p) for p in [start(["handoff", "offer", "--title", "cap", "--max-offers", "1"])
                                    for _ in range(3)]]
    assert sorted(rc for rc, _ in results) == [0, 75, 75], results
    clear_tasks()

def state_failures():
    path = home / "io.json"
    m.write_json(path, {"preserved": True})
    original_replace = m.os.replace
    calls = []
    def sharing(src, dst):
        calls.append(src)
        if len(calls) < 3:
            raise PermissionError("sharing violation")
        return original_replace(src, dst)
    with mock.patch.object(m.os, "replace", sharing):
        m.write_json(path, {"preserved": "updated"})
    assert len(calls) == 3 and m.read_json(path, {})["preserved"] == "updated"
    with mock.patch.object(m.os, "replace", side_effect=PermissionError("busy")), mock.patch.object(m.time, "sleep"):
        try:
            m.write_json(path, {})
            raise AssertionError("replace failure ignored")
        except m.StateError:
            pass
    assert not list(home.glob("*.tmp")) and m.read_json(path, {})["preserved"] == "updated"
    with mock.patch.object(m.Path, "read_text", side_effect=PermissionError("busy")), mock.patch.object(m.time, "sleep"):
        try:
            m.read_json(path, {})
            raise AssertionError("unreadable state treated as empty")
        except m.StateError:
            pass
    # load_spend_limits retries the same sharing violation (it shares _read_text_retry, not a bare read_text).
    reads = []
    def flaky_read(*a, **k):
        reads.append(a)
        if len(reads) < 3:
            raise PermissionError("sharing violation")
        return '{"global": {}}'
    with mock.patch.object(m.Path, "read_text", side_effect=flaky_read), mock.patch.object(m.time, "sleep"):
        cfg, err = m.load_spend_limits()
        assert err is None and isinstance(cfg, dict) and cfg["global"] == {}, (cfg, err)
    assert len(reads) == 3
    hid = offered(worktree=True, base="missing-review-ref")
    rc, out = run(["handoff", "take", hid])
    assert rc != 0 and m.result_status(meta(hid)) == "OFFERED", (rc, out, meta(hid))
    clear_tasks()
    # Both notification and assignment write meta: force their interleaving around external work.
    hid = offered()
    with m.state_lock(m.state_dir() / ".state.lock"):
        task = m.load_meta(hid); m.claim_handoff(task, m.resolve_profile("antigravity", proj))
    original_assign = m.assign_handoff
    def assign(claim, prof):
        good(["handoff", "check"])
        return original_assign(claim, prof)
    with mock.patch.object(m, "assign_handoff", assign):
        m.materialize_handoff(task, m.resolve_profile("antigravity", proj))
    assert meta(hid)["taken"] and not meta(hid).get("assigning")
    ps = [start(["handoff", "check"]), start(["handoff", "done", hid])]
    assert all(rc == 0 for rc, _ in map(finish, ps))
    assert meta(hid)["manual_status"] == "DONE" and meta(hid)["taken"]
    # A mode notification must preserve usage changed after its first budget read.
    m.save_usage({"five_hour": {"used": 10, "resets_at": m.iso(m.now() + dt.timedelta(hours=2))}}, "test")
    original_budget = m.claude_budget
    def new_usage():
        mode, line = original_budget()
        m.save_usage({"five_hour": {"used": 27, "resets_at": m.iso(m.now() + dt.timedelta(hours=2))}}, "test")
        return mode, line
    with mock.patch.object(m, "claude_budget", new_usage):
        m.budget_event("review-update")
    assert m.read_json(m.USAGE_SNAPSHOT, {})["five_hour"]["used"] == 27
    clear_tasks()
    # Real holder, bounded waiter, silent hook/statusline, and OS release on process death.
    holder_code = "import importlib.machinery,importlib.util,sys,time; l=importlib.machinery.SourceFileLoader('o',sys.argv[1]); m=importlib.util.module_from_spec(importlib.util.spec_from_loader('o',l)); l.exec_module(m); c=m.state_lock(m.ORCH_HOME/'.state.lock'); c.__enter__(); print('ready',flush=True); time.sleep(30)"
    holder = subprocess.Popen([sys.executable, "-B", "-c", holder_code, orch], env=env, cwd=str(proj),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert holder.stdout.readline().strip() == b"ready"
        with mock.patch.object(m, "LOCK_WAIT", 0.05):
            try:
                m.heartbeat("busy")
                raise AssertionError("lock not enforced")
            except m.StateError as ex:
                assert "timed out" in str(ex)
        assert run(["hook", "user-prompt"], '{"session_id":"busy"}') == (0, "")
        rc, out = run(["statusline"], '{"session_id":"busy"}')
        assert rc == 0 and "Traceback" not in out and "busy" not in m.read_json(home / "sessions.json", {})
    finally:
        holder.kill(); holder.communicate(timeout=10)
    m.heartbeat("after-crash")
    assert "after-crash" in m.read_json(home / "sessions.json", {})

def launch_profiles():
    good(["profile", "set", "deepseek", "personal", "--key", "DUMMY_A", "--default"])
    good(["profile", "set", "deepseek", "work", "--key", "DUMMY_B"])
    out = good(["launch", "deepseek", "--dry-run", "--use", "deepseek=work"])
    assert "Lead: DeepSeek@work" in out and "bbbb" in out, out
    for name, message in (("off", "PROFILE_OFF"), ("missing", "PROFILE_ERROR")):
        rc, out = run(["launch", "deepseek", "--dry-run", "--use", "deepseek=" + name])
        assert rc != 0 and message in out, out
    out = good(["launch", "deepseek", "--dry-run", "--use", "deepseek=off", "--profile", "work"])
    assert "Lead: DeepSeek@work" in out
    good(["profile", "use", "claude", "off"])
    assert "Claude: only as an executor" in good(["launch", "deepseek", "--dry-run", "--use", "claude=default"])
    assert "Claude: off" in good(["launch", "deepseek", "--dry-run", "--use", "claude=default", "--no-claude"])
    assert "Lead: DeepSeek@work" in good(["launch", "deepseek", "--dry-run"], extra={"ORCH_PROFILES":"deepseek=work"})
    good(["profile", "use", "claude", "inherit"])

def worker_guard():
    hid = offered()
    before = meta(hid)
    for args in (["list"], ["show", hid], ["check"], ["wait", "--any"], ["done", hid], ["cancel", hid],
                 ["close", hid], ["take", hid], ["reclaim", hid], ["new", "--title", "x"], ["offer", "--title", "x"]):
        rc, out = run(["handoff"] + args, extra={"ORCH_WORKER":"review-worker"})
        assert rc != 0 and "only the orchestrator may use orch handoff" in out, (args, rc, out)
    assert meta(hid) == before
    assert run(["hook", "user-prompt"], extra={"ORCH_WORKER":"review-worker"}) == (0, "")
    clear_tasks()

fixed = m.now().replace(microsecond=0)
def snapshot(five=None, week=None, age=0):
    data = {"updated": m.iso(fixed - dt.timedelta(seconds=age)), "source":"operator"}
    if five is not None: data["five_hour"] = five
    if week is not None: data["seven_day"] = week
    m.write_json(m.USAGE_SNAPSHOT, data)
def window(used, hours, age=0):
    return {"used":used, "resets_at":m.iso(fixed + dt.timedelta(hours=hours)),
            "updated":m.iso(fixed - dt.timedelta(seconds=age))}

def stale_budget():
    snapshot(window(40, 4))
    with mock.patch.object(m, "now", return_value=fixed):
        snap = m.read_json(m.USAGE_SNAPSHOT, {})
        rate, _ = m.window_pace(snap, 40, m.parse_iso(snap["five_hour"]["resets_at"]), 5)
        assert m.claude_budget()[0] == "tight"
    with mock.patch.object(m, "now", return_value=fixed + dt.timedelta(hours=3)):
        assert m.window_pace(snap, 40, m.parse_iso(snap["five_hour"]["resets_at"]), 5)[0] == rate
        mode, line = m.claude_budget()
        assert mode == "tight" and "3h ago" in line and "stale" in line and "≈" not in line, line
    snapshot({"used":10, "resets_at":m.iso(fixed + dt.timedelta(hours=2))}, age=3600)
    assert m.claude_budget()[0] != "surplus"
    out = good(["statusline"], '{}')
    assert "stale:" in out and "surplus:" not in out
    snapshot(window(10, 2), {"used":40, "resets_at":m.iso(fixed + dt.timedelta(days=4))}, age=3600)
    old = m.read_json(m.USAGE_SNAPSHOT, {})["updated"]
    good(["budget", "set", "--used", "15", "--resets", "+2h"])
    assert m.read_json(m.USAGE_SNAPSHOT, {})["seven_day"]["updated"] == old

def weekly_budget():
    for five in (None, window(10, -1), window(10, 2)):
        snapshot(five, window(82, 24 * 1.7))
        mode, line = m.claude_budget()
        assert mode == "tight" and "weekly limit" in line and "108% projected" in line, line
    assert "tight: week 108% projected" in good(["statusline"], '{}')
    snapshot(None, {"used":95})
    assert m.claude_budget()[0] == "tight"
    snapshot(window(10, 2), window(15, 167))
    assert m.claude_budget()[0] == "normal"    # early noisy projection blocks surplus, not TIGHT
    snapshot(window(10, 2), window(95, 167))
    assert m.claude_budget()[0] == "tight"     # used share is sufficient even on day one

def weekly_pace():
    # The effective weekly reserve shrinks with the time left and floors at 1 (0 stays 0).
    reset = fixed + dt.timedelta(days=7)
    assert m.week_reserve(10, reset, reset - dt.timedelta(days=7)) == 10
    assert abs(m.week_reserve(10, reset, reset - dt.timedelta(days=3.5)) - 5) < 1e-9
    assert abs(m.week_reserve(10, reset, reset - dt.timedelta(hours=31)) - 1.85) < 0.01
    assert m.week_reserve(10, reset, reset - dt.timedelta(hours=1)) == 1
    assert m.week_reserve(0, reset, reset - dt.timedelta(days=7)) == 0
    assert m.week_reserve_text(10, 10) == "10%"
    assert m.week_reserve_text(10, 1.85) == "2% (10% at the start of the week)"

    # week_history sampling: at most one per 15 min, capped at 300, malformed entries dropped.
    t0 = fixed
    hist = m.week_history_update([], {"used": 80.0, "resets_at": m.iso(reset)}, t0)
    hist = m.week_history_update(hist, {"used": 81.0, "resets_at": m.iso(reset)}, t0 + dt.timedelta(minutes=5))
    assert len(hist) == 1                    # a change within 15 min adds no second sample
    hist = m.week_history_update(hist, {"used": 82.0, "resets_at": m.iso(reset)}, t0 + dt.timedelta(minutes=20))
    assert len(hist) == 2                    # past the gap a change adds a sample
    hist = m.week_history_update([["garbage", 80.0, m.iso(reset)]], {"used": 90.0, "resets_at": m.iso(reset)},
                                 t0 + dt.timedelta(hours=1))
    assert len(hist) == 1 and hist[0][1] == 90.0      # the malformed entry is skipped, never fatal
    many = [[m.iso(t0 + dt.timedelta(minutes=5 * i)), 1.0, m.iso(reset)] for i in range(350)]
    assert len(m.week_history_update(many, None, t0 + dt.timedelta(hours=72))) == 300

    # The weekly base sample: earliest within 24 h, same reset (10 min), at least 6 h before the measurement.
    hist8 = [[m.iso(fixed - dt.timedelta(hours=8)), 82.0, m.iso(reset)]]
    assert m.week_base_sample(hist8, reset, fixed) == (fixed - dt.timedelta(hours=8), 82.0)
    old = reset - dt.timedelta(days=7)                 # a sample from the previous week
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=8)), 50.0, m.iso(old)]], reset, fixed) is None
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=5)), 82.0, m.iso(reset)]], reset, fixed) is None
    # After an idle day, the newest older sample with the same reset stands in for a flat week: zero pace,
    # basis "the last 24 h" — only while the used value is unchanged (a change means the recent pace is unknown).
    rr2 = fixed + dt.timedelta(hours=48)
    idle = [[m.iso(fixed - dt.timedelta(hours=26)), 70.0, m.iso(rr2)]]
    assert m.week_base_sample(idle, rr2, fixed, 70.0) == (fixed - dt.timedelta(hours=24), 70.0)
    assert m.week_base_sample(idle, rr2, fixed, 71.0) is None
    rate, basis = m.week_rate(idle, 70.0, rr2, fixed)
    assert basis == "the last 24 h" and rate == 0.0, (rate, basis)

    def week_snap(used, hours_left, hist=None):
        r = fixed + dt.timedelta(hours=hours_left)
        data = {"updated": m.iso(fixed), "source": "test",
                "seven_day": {"used": used, "resets_at": m.iso(r), "updated": m.iso(fixed)}}
        if hist is not None:
            data["week_history"] = hist
        m.write_json(m.USAGE_SNAPSHOT, data)

    # Real case: 84% used, 31 h to the reset, 82% 8 h ago → the recent pace says ~91%, not TIGHT.
    rr = fixed + dt.timedelta(hours=31)
    real_hist = [[m.iso(fixed - dt.timedelta(hours=8)), 82.0, m.iso(rr)]]
    week_snap(84, 31, real_hist)
    rate, basis = m.week_rate(real_hist, 84, rr, fixed)
    assert basis == "the last 8 h", basis
    assert abs(m.projected_at_reset(84, rr, rate, fixed) - 91.75) < 0.01
    assert m.claude_budget()[0] != "tight"
    # No history: the same numbers fall back to the window average → 103% projected → TIGHT.
    week_snap(84, 31)
    mode, line = m.claude_budget()
    assert mode == "tight" and "103% projected from the week's average" in line and "weekly limit is tight" in line, line
    # A real burn stays TIGHT: 10 points in 8 h with 60 h left.
    week_snap(30, 60, [[m.iso(fixed - dt.timedelta(hours=8)), 20.0, m.iso(fixed + dt.timedelta(hours=60))]])
    mode, line = m.claude_budget()
    assert mode == "tight" and "projected from the last 8 h" in line, line
    # The reserve: 90% with 6 days left is TIGHT; 92% with 5 h left and no recent use isn't.
    week_snap(90, 24 * 6)
    assert m.claude_budget()[0] == "tight"
    week_snap(92, 5)
    assert m.claude_budget()[0] != "tight"
    week_snap(99.5, 1)
    assert m.claude_budget()[0] == "tight"           # the 1-point floor keeps the last hour guarded
    # A week_reserve of 0 is TIGHT only at 100%.
    with mock.patch.object(m, "budget_settings", return_value={"surplus": 30, "reserve": 10, "week_reserve": 0}):
        week_snap(99, 1)
        assert m.claude_budget()[0] != "tight"
        week_snap(100, 1)
        assert m.claude_budget()[0] == "tight"
    # The surplus gate reads the effective weekly reserve, not the flat setting: with week_reserve=20 but the
    # reserve shrunk to eff=10, a 80% weekly projection still allows surplus (the flat 20 would block at 100-20=80).
    burn = [[m.iso(fixed - dt.timedelta(hours=8)), 40.0, m.iso(fixed + dt.timedelta(hours=24))]]
    m.write_json(m.USAGE_SNAPSHOT, {"updated": m.iso(fixed), "source": "test",
                                    "five_hour": window(10, 2), "seven_day": window(50, 24), "week_history": burn})
    with mock.patch.object(m, "budget_settings",
                           return_value={"surplus": 40, "reserve": 10, "week_reserve": 20}), \
         mock.patch.object(m, "week_reserve", return_value=10.0), \
         mock.patch.object(m, "now", return_value=fixed):
        mode, line = m.claude_budget()
        assert mode == "surplus", (mode, line)

def codex_weekly():
    cx = root / "cx-week"
    d = cx / "sessions" / "2026" / "11" / "02"
    d.mkdir(parents=True)
    def ev(used5, r5h, used7, r7h, t):
        return json.dumps({"timestamp": t.astimezone(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex",
            "primary": {"used_percent": used5, "window_minutes": 300, "resets_at": int((t + dt.timedelta(hours=r5h)).timestamp())},
            "secondary": {"used_percent": used7, "window_minutes": 10080, "resets_at": int((t + dt.timedelta(hours=r7h)).timestamp())},
            "credits": {"has_credits": False}, "plan_type": "plus"}}})
    f = d / "rollout-0001.jsonl"
    f.write_text(ev(10, 2, 84, 31, fixed) + "\n", encoding="utf-8")
    with mock.patch.dict(os.environ, {"CODEX_HOME": str(cx)}):
        m.refresh_codex(force=True)
        entry = m.read_json(m.CODEX_USAGE_FILE, {})[str(cx)]
        assert len(entry.get("week_history") or []) == 1      # the series is in the cached entry
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, entry) == "tight: week 103% projected"
        m.refresh_codex(force=True)
        entry = m.read_json(m.CODEX_USAGE_FILE, {})[str(cx)]
        assert len(entry.get("week_history") or []) == 1      # an unchanged measurement adds no sample
        # the same weekly cases as Claude, straight through the compact text
        def ce(used, hours_left, hist=None):
            r = fixed + dt.timedelta(hours=hours_left)
            e = {"seven_day": {"used": used, "resets_at": m.iso(r), "measured": m.iso(fixed)}}
            if hist is not None:
                e["week_history"] = hist
            return e
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10},
                                  ce(84, 31, [[m.iso(fixed - dt.timedelta(hours=8)), 82.0,
                                               m.iso(fixed + dt.timedelta(hours=31))]])) is None
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, ce(84, 31)) == "tight: week 103% projected"
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10},
                                  ce(30, 60, [[m.iso(fixed - dt.timedelta(hours=8)), 20.0,
                                               m.iso(fixed + dt.timedelta(hours=60))]])) == "tight: week 105% projected"
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, ce(92, 5)) is None
        assert m.codex_short_mode({"reserve": 10, "week_reserve": 10}, ce(99.5, 1)) == "tight: week over reserve"
        # a new weekly measurement adds a sample
        f.write_text(ev(10, 2, 86, 30, fixed + dt.timedelta(hours=1)) + "\n", encoding="utf-8")
        m.refresh_codex(force=True)
        entry = m.read_json(m.CODEX_USAGE_FILE, {})[str(cx)]
        assert len(entry.get("week_history") or []) == 2
        assert m.codex_budget()[0] == "tight"

def hard_cap():
    good(["profile", "set", "antigravity", "zero", "--max-open", "0", "--default"])
    rc, out = run(["handoff", "new", "--title", "cap", "--force"])
    assert rc == 75 and "profile limit 0" in out and "--force" not in out, out
    hid = offered()
    rc, out = run(["handoff", "take", hid, "--force"])
    assert rc == 75 and "--force" not in out and m.result_status(meta(hid)) == "OFFERED", out
    good(["profile", "use", "antigravity", "inherit", "--default"])
    good(["handoff", "take", hid, "--max-open", "0", "--force"])
    clear_tasks()

def existing_result():
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "ready"])).group()
    Path(m.load_meta(hid)["result_path"]).write_text("STATUS: DONE\nfinished\n", encoding="utf-8")
    assert "STATUS DONE" in good(["handoff", "wait", "--any", "--timeout", "1s"])
    assert "No manual tasks" in good(["handoff", "wait", "--any", "--timeout", "1s"])
    clear_tasks()

def overdue_activity():
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "activity"])).group()
    task = meta(hid)
    task.update(created=m.iso(fixed - dt.timedelta(hours=8)), taken=m.iso(fixed - dt.timedelta(hours=8)))
    task.pop("activity_baseline", None)
    m.save_meta(task)
    (proj / "app.txt").write_text("activity\n", encoding="utf-8")
    with mock.patch.object(m, "scan_latest_mtime", side_effect=AssertionError("fast check scanned workdir")):
        assert not m.check_events(fast=True)
    with mock.patch.object(m, "last_activity", wraps=m.last_activity) as activity:
        events = m.check_events()
        assert activity.call_count == 1
    assert any("in progress" in e and hid in e for e in events), events
    assert not m.check_events()
    clear_tasks()

def token_hygiene():
    out = good(["launch", "deepseek", "--dry-run"], extra={"CLAUDE_CODE_OAUTH_TOKEN":"sensitive"})
    assert any("CLAUDE_CODE_OAUTH_TOKEN" in l for l in out.splitlines() if l.startswith("Dropped")), out
    good(["run", "claude", "--model", "haiku", "review"], extra={"FAKE_CLAUDE":"ok", "ORCH_LEAD":"deepseek",
         "ORCH_LEAD_ENV":"ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN":"lead-secret", "CLAUDE_CODE_OAUTH_TOKEN":"sensitive"})
    record = json.loads(Path(env["FAKE_CLAUDE_LOG"]).read_text(encoding="utf-8"))
    assert not record["env"].get("CLAUDE_CODE_OAUTH_TOKEN") and not record["env"].get("ANTHROPIC_AUTH_TOKEN")

def run_outcomes():
    for status in ("BLOCKED", "PARTIAL"):
        out = good(["run", "codex", "--model", "review-model", "review"], extra={"FAKE_CODEX":status.lower()})
        assert "[" + status + "]" in out, out
        entries = [x for x in m.ledger_read() if x.get("kind") == "run"]
        assert entries[-1]["status"] == status
        assert status in good(["usage"])
    rc, out = run(["run", "codex", "--model", "capacity-model", "review"], extra={"FAKE_CODEX":"capacity"})
    assert rc == 75 and "QUOTA_EXHAUSTED" in out, out
    entries = m.read_json(m.AVAIL_FILE, {})["entries"]
    assert set(entries) == {"codex/capacity-model"}, entries
    until = m.parse_iso(entries["codex/capacity-model"]["until"])
    assert 9 * 60 < (until - m.now()).total_seconds() <= 10 * 60
    assert run(["quota", "check", "codex/sibling"])[0] == 0
    assert run(["run", "codex", "--model", "sibling", "review"], extra={"FAKE_CODEX":"fail"})[0] == 3
    notes = (Path(orch).parent.parent / "registry/providers.yaml").read_text(encoding="utf-8")
    assert "ORCH_CODEX_EXTRA_ARGS" in notes and "TMPDIR" in notes and "C:/Users/Public/" in notes

def run_cost_fallback():
    # A corrupt personal price table must not lose the ledger line: keep the tokens, price 0, and say so.
    (home / "prices.json").write_text(json.dumps(
        {"usd_per_1m_tokens": {"pricing-model": {"input": "not-a-number"}}}), encoding="utf-8")
    try:
        out = good(["run", "codex", "--model", "pricing-model", "review"], extra={"FAKE_CODEX": "ok"})
        assert "cost not priced" in out, out
        rec = [x for x in m.ledger_read() if x.get("kind") == "run"][-1]
        assert rec["usage"]["input_tokens"] == 200 and rec["cost_usd"] == 0.0, rec
    finally:
        (home / "prices.json").unlink()

def corruption_recovery():
    hid = offered()
    broken = m.handoffs_root() / "BAD" / "meta.json"
    broken.parent.mkdir(exist_ok=True)
    for raw in ("{", "[1]"):
        broken.write_text(raw, encoding="utf-8")
        for args in (["status"], ["handoff", "list"], ["handoff", "offer", "--title", "other"]):
            rc, out = run(args)
            assert rc == 0 and "meta.json" in out and "Traceback" not in out, out
        assert run(["handoff", "take", "BAD"])[0] == 1
    broken.unlink()
    for path, args in ((m.USAGE_SNAPSHOT, ["budget"]), (m.SESSIONS_FILE, ["budget"]),
                       (m.handoffs_root() / ".pool.json", ["status"]),
                       (m.handoffs_root() / "counter.json", ["handoff", "offer", "--title", "counter"])):
        if path == m.SESSIONS_FILE:
            m.write_json(m.USAGE_SNAPSHOT, {"five_hour": {"used": 10, "resets_at": m.iso(m.now() + dt.timedelta(hours=1))}})
        path.write_text("[1]", encoding="utf-8")
        rc, out = run(args)
        assert rc == 0 and str(path) in out and Path(str(path) + ".corrupt").exists(), out
    m.AVAIL_FILE.write_text("{", encoding="utf-8")
    assert run(["status"])[0] == 0 and run(["handoff", "offer", "--title", "available"])[0] == 0
    for args in (["quota", "set", "codex", "exhausted"], ["quota", "clear", "codex"]):
        rc, out = run(args)
        assert rc == 1 and "availability.json" in out and m.AVAIL_FILE.read_text() == "{", out
    m.AVAIL_FILE.unlink()
    saved_profiles = m.PROFILES_FILE.read_bytes() if m.PROFILES_FILE.exists() else None
    m.PROFILES_FILE.write_text("[1]", encoding="utf-8")
    for args in (["status"], ["budget"]):
        rc, out = run(args)
        assert rc == 0 and "profiles.json" in out and "Traceback" not in out, out
    assert run(["handoff", "offer", "--title", "refused"])[0] == 1
    if saved_profiles is None: m.PROFILES_FILE.unlink()
    else: m.PROFILES_FILE.write_bytes(saved_profiles)
    original = m.USAGE_SNAPSHOT.read_bytes()
    with mock.patch.object(m.Path, "read_text", side_effect=PermissionError("busy")), mock.patch.object(m.time, "sleep"):
        try:
            m.read_json(m.USAGE_SNAPSHOT, {}, recover_corrupt=True)
            raise AssertionError("permission error treated as corruption")
        except m.StateError:
            pass
    assert m.USAGE_SNAPSHOT.read_bytes() == original
    clear_tasks()

def assignment_recovery():
    hid = offered(worktree=True)
    task = meta(hid)
    task.update(taken=m.iso(m.now() - dt.timedelta(minutes=11)), assigning="old-token")
    m.save_meta(task)
    old = dict(task)
    assert not any(hid in e for e in m.check_events(fast=True))
    events = m.check_events()
    assert sum(hid in e and "returned to the pool" in e for e in events) == 1, events
    assert m.result_status(meta(hid)) == "OFFERED" and not meta(hid).get("assigning")
    with mock.patch.object(m, "assign_handoff", return_value=old):
        try:
            m.materialize_handoff(old, None)
            raise AssertionError("late finisher accepted")
        except SystemExit:
            pass
    branch = "ag/" + hid.lower()
    subprocess.run(["git", "branch", branch], cwd=str(proj), check=True)
    good(["handoff", "take", hid])
    assert meta(hid)["branch"] == branch
    clear_tasks()
    hid = offered()
    task = meta(hid); task.update(offered=None, taken=m.iso(m.now()), assigning="failure")
    m.save_meta(task)
    with mock.patch.object(m, "assign_handoff", side_effect=RuntimeError("test failure")):
        try:
            m.materialize_handoff(task, None)
            raise AssertionError("failure swallowed")
        except RuntimeError:
            pass
    task = meta(hid)
    assert task["manual_status"] == "CANCELLED" and task["archived"] and "test failure" in task["manual_note"]
    hid = offered(); task = meta(hid)
    task.update(offered=None, taken=m.iso(m.now() - dt.timedelta(minutes=11)), assigning="stale")
    m.save_meta(task); assert any(hid in e and "cancelled" in e for e in m.check_events())
    assert meta(hid)["manual_status"] == "CANCELLED" and meta(hid)["archived"]
    hid = offered(); task = meta(hid); task.update(taken=m.iso(m.now()), assigning="failure")
    m.save_meta(task)
    with mock.patch.object(m, "assign_handoff", side_effect=RuntimeError("test")):
        try: m.materialize_handoff(task, None)
        except RuntimeError: pass
    assert m.result_status(meta(hid)) == "OFFERED"
    clear_tasks()

def report_reclaimed():
    for mode, expected in (("preamble", "BLOCKED"), ("first_done", "OK"), ("partial", "PARTIAL")):
        hid = offered()
        good(["handoff", "reclaim", hid, "--next"])
        out = good(["run", "codex", "--handoff", hid, "review"], extra={"FAKE_CODEX":mode})
        assert "[" + expected + "]" in out, out
        if expected != "OK":
            assert "slot stays busy" in out and not meta(hid)["reclaim"]["finished"], out
            good(["handoff", "done", hid])
        assert meta(hid)["reclaim"]["finished"]
    clear_tasks()

def meta_paths():
    proj_str = str(proj.resolve())
    base = m.meta_base(m.handoffs_root() / "X-0001" / "meta.json")
    assert Path(str(base)) == Path(proj_str), (base, proj_str)
    # meta_base is pure path arithmetic: it never calls .resolve(), so a symlinked .orchestra can't redirect the
    # project, and the result does not depend on the cwd.
    fake = m.handoffs_root() / "X-9999" / "meta.json"
    with mock.patch.object(m.Path, "resolve", side_effect=AssertionError("meta_base resolved the path")):
        assert Path(str(m.meta_base(fake))) == Path(proj_str)
    # relative → absolute in memory, absolute → relative on save (round-trip)
    assert Path(m.abs_path(".orchestra/handoffs/X-0001/RESULT.md", base)) == proj / ".orchestra/handoffs/X-0001/RESULT.md"
    assert Path(m.abs_path(".", base)) == Path(proj_str)
    assert Path(m.abs_path("../proj.wt/X-0001", base)) == Path(proj_str).parent / "proj.wt" / "X-0001"
    assert m.rel_path(proj_str, base) == "."
    assert m.rel_path(str(Path(proj_str).parent / "proj.wt" / "X-0001"), base) == "../proj.wt/X-0001"
    # a path of the other OS is kept verbatim: no cross-OS guessing
    assert m.abs_path("C:\\Users\\Me\\Proj", base) == "C:\\Users\\Me\\Proj"
    assert m.abs_path("/mnt/c/Users/Me/Proj", base) == "/mnt/c/Users/Me/Proj"
    assert m.rel_path("D:\\Users\\me\\x", base) == "D:/Users/me/x"
    # no relative form (a different drive on Windows) → stay absolute
    with mock.patch.object(m.os.path, "relpath", side_effect=ValueError("different drive")):
        assert m.rel_path(str(Path(proj_str) / "x"), base) == str(Path(proj_str) / "x").replace("\\", "/")
    # a real task: on-disk relative, in-memory absolute, the card prints the full path
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "paths"])).group()
    raw = meta(hid)
    assert raw["workdir"] == "." and raw["task_path"].startswith(".orchestra/handoffs/"), raw
    task = m.load_meta(hid)
    assert Path(task["workdir"]) == Path(proj_str), task
    assert Path(task["result_path"]) == proj / ".orchestra/handoffs" / hid / "RESULT.md", task
    assert task["workdir"] in good(["handoff", "show", hid])
    # an old meta with absolute paths loads, works, and becomes relative after a save
    old = dict(raw)
    for f in ("workdir", "task_path", "result_path"):
        old[f] = str(Path(task[f]))
    m.write_json(m.handoffs_root() / hid / "meta.json", old)
    assert Path(m.load_meta(hid)["workdir"]) == Path(proj_str)
    m.save_meta(m.load_meta(hid))
    after = meta(hid)
    assert after["workdir"] == "." and after["task_path"].startswith(".orchestra/handoffs/"), after
    clear_tasks()

def spend_limits():
    peak = dt.datetime(2026, 11, 2, 2, 0, tzinfo=dt.timezone.utc)       # Monday 02:00 UTC — DeepSeek peak
    offpeak = dt.datetime(2026, 11, 2, 12, 0, tzinfo=dt.timezone.utc)   # Monday 12:00 UTC — off-peak
    u = {"input_tokens": 1_000_000, "cached_input_tokens": 0, "output_tokens": 0}

    # prices: claude alias and codex prefix matching, default fallback
    assert m.price_for("claude-sonnet-5-5-2026", "claude")["output"] == 10.0
    assert m.price_for("gpt-6.1-terra-something", "codex")["input"] == 1.0
    d = m.price_for("no-such-model", "deepseek")
    assert d["input"] == 3.0 and d["output"] == 15.0
    # DeepSeek peak vs off-peak (off_peak_multiplier 0.5 outside the weekday UTC windows)
    assert m.price_for("deepseek-v4-pro", "deepseek", peak)["input"] == 1.32
    assert m.price_for("deepseek-v4-pro", "deepseek", offpeak)["input"] == 0.66
    assert m.price_for("deepseek-v4-pro", "deepseek", offpeak)["output"] == 1.98
    assert abs(m.usage_cost(u, "deepseek", "deepseek-v4-pro", peak) - 1.32) < 1e-9
    assert abs(m.usage_cost(u, "deepseek", "deepseek-v4-pro", offpeak) - 0.66) < 1e-9
    # a dated price (gpt-6-astra): cheaper before the promo ends, higher after
    assert m.price_for("gpt-6-astra", "codex", dt.datetime(2026, 10, 15, tzinfo=dt.timezone.utc))["input"] == 5.0
    assert m.price_for("gpt-6-astra", "codex", dt.datetime(2026, 11, 5, tzinfo=dt.timezone.utc))["input"] == 10.0
    # a personal ~/.orchestra/prices.json overrides per model, leaves the rest alone
    (home / "prices.json").write_text(json.dumps(
        {"usd_per_1m_tokens": {"deepseek-v4-pro": {"input": 1.0, "cache_read": 0.1, "output": 2.0}}}), encoding="utf-8")
    assert m.price_for("deepseek-v4-pro", "deepseek", peak)["input"] == 1.0
    assert m.price_for("deepseek-flash", "deepseek", peak)["input"] == 0.30
    (home / "prices.json").unlink()
    # staleness: prices older than 30 days warn and name the source; a fresh list doesn't
    with mock.patch.object(m, "now", return_value=dt.datetime(2026, 11, 2, tzinfo=dt.timezone.utc)):
        assert m.price_staleness("deepseek") is None
    with mock.patch.object(m, "now", return_value=dt.datetime(2027, 1, 15, tzinfo=dt.timezone.utc)):
        assert "api-docs.deepseek.com" in m.price_staleness("deepseek")

    # cost_usd is frozen in the ledger and preferred over the table; sessions freeze spend_usd
    assert abs(m._run_cost({"kind": "run", "provider": "codex", "model": "gpt-6.1-terra", "usage": u}) - 1.0) < 1e-9
    assert m._run_cost({"kind": "run", "provider": "codex", "model": "gpt-6.1-terra", "usage": u, "cost_usd": 0.5}) == 0.5
    assert m._session_cost({"kind": "session", "lead": "deepseek", "spend_usd": 0.75, "rows": []}) == 0.75

    # counter key and effective settings: project → global → defaults
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg = m.load_spend_limits()[0]
    canon = m.canon_path(proj)
    cfg["projects"][canon] = {"deepseek": {"limit": 5}}
    assert m.counter_key(cfg, "deepseek", canon)[0] == canon
    assert m.counter_key(cfg, "deepseek", canon + "/sub")[0] == canon
    assert m.counter_key(cfg, "codex", canon)[0] == "global"
    eff = m.resolve_spend(cfg, "deepseek", proj)
    assert eff["limit"] == 5 and eff["mode"] == "evaluate" and eff["lead_mode"] == "continue"
    assert m.spend_kill_at({"limit": 10, "mode": "stop"}) == 10
    assert m.spend_kill_at({"limit": 10, "mode": "evaluate", "overrun": 20}) == 12
    assert m.spend_kill_at({"limit": 10, "mode": "continue"}) is None

    # reset kinds: a key scope is manual, a keyless one is month; --reset overrides both ways
    assert m.scope_has_key("deepseek", proj) is True
    assert m.scope_has_key("codex", proj) is False
    assert m.resolve_reset(cfg, "deepseek", proj) == "manual"
    assert m.resolve_reset(cfg, "codex", proj) == "month"
    cfg["global"]["deepseek"] = {"reset": "month"}
    cfg["global"]["codex"] = {"reset": "manual"}
    assert m.resolve_reset(cfg, "deepseek", proj) == "month"
    assert m.resolve_reset(cfg, "codex", proj) == "manual"
    # each message names the right way out per kind
    assert "orch spend reset codex" in m._way_out(cfg, "codex", proj)          # manual → top up and reset
    assert "orch spend limit deepseek" in m._way_out(cfg, "deepseek", proj)    # month → raise or wait

    # baselines: a manual scope never rolls over, a month scope does
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    t0 = dt.datetime(2026, 11, 15, 12, 0, tzinfo=dt.timezone.utc)
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    cfg["global"]["codex"] = {"limit": 10}
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0):
        assert m.ensure_baseline("deepseek", proj) == t0    # first seen: the baseline is written now
    def mk(label, cost, ts):
        return {"label": label, "project": canon, "cost": cost, "ts": m.iso(ts)}
    manual = [mk("deepseek", 2.0, t0 + dt.timedelta(hours=1))]
    month = [mk("codex", 3.0, t0 + dt.timedelta(hours=1))]
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=2)):
        assert abs(m.current_spend("deepseek", proj, manual) - 2.0) < 1e-9
        assert abs(m.current_spend("codex", proj, month) - 3.0) < 1e-9
    later = t0 + dt.timedelta(days=40)                      # the next calendar month
    with mock.patch.object(m, "now", return_value=later):
        assert abs(m.current_spend("deepseek", proj, manual) - 2.0) < 1e-9   # manual: never rolls over
        assert m.current_spend("codex", proj, month) == 0.0                  # month: cleared

    # a first-seen manual scope ignores spending from before it was seen; a reset zeroes it at once
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0):
        m.ensure_baseline("deepseek", proj)                 # first seen at t0
    old = [mk("deepseek", 5.0, t0 - dt.timedelta(days=1)), mk("deepseek", 2.0, t0 + dt.timedelta(hours=1))]
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=2)):
        assert abs(m.current_spend("deepseek", proj, old) - 2.0) < 1e-9   # the pre-baseline entry is ignored
    cfg, _ = m.load_spend_limits()                          # a reset moves the baseline to now
    m._baseline_section(cfg, "global")["deepseek"] = (t0 + dt.timedelta(hours=3)).isoformat()
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=4)):
        assert m.current_spend("deepseek", proj, old) == 0.0                # reset zeroes the counter at once

    # within one second: what ended just before a baseline stays out, what ended just after counts
    base = t0.replace(microsecond=0) + dt.timedelta(hours=5, microseconds=500000)
    cfg, _ = m.load_spend_limits()
    m._baseline_section(cfg, "global")["deepseek"] = m.iso_precise(base)
    m.save_spend_limits(cfg)
    same_second = [{"label": "deepseek", "project": canon, "cost": 4.0,
                    "ts": m.iso_precise(base - dt.timedelta(microseconds=400000))},
                   {"label": "deepseek", "project": canon, "cost": 1.0,
                    "ts": m.iso_precise(base + dt.timedelta(microseconds=1000))}]
    with mock.patch.object(m, "now", return_value=base + dt.timedelta(hours=1)):
        assert abs(m.current_spend("deepseek", proj, same_second) - 1.0) < 1e-9
    usage_file = home / "usage.jsonl"
    usage_file.unlink() if usage_file.exists() else None
    m.ledger_append({"kind": "probe"})                      # the real writer keeps that resolution
    assert "." in json.loads(usage_file.read_text(encoding="utf-8").splitlines()[-1])["ts"]

    # the cache builds incrementally and restarts on a shrunken ledger (records keep ts, so resets apply at read time)
    for p in (home / "spend_cache.json", home / "spend_limits.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["codex"] = {"limit": 10}                  # a month scope needs no baseline
    m.save_spend_limits(cfg)
    def led(label, tokens, ts):
        return json.dumps({"kind": "run", "provider": "codex", "label": label, "model": "gpt-6.1-terra",
                           "billing": "api", "project": canon,
                           "usage": {"input_tokens": tokens, "cached_input_tokens": 0, "output_tokens": 0},
                           "ts": m.iso(ts)}, separators=(",", ":"))
    ledger = home / "usage.jsonl"
    fixed2 = dt.datetime(2026, 11, 15, 12, 0, tzinfo=dt.timezone.utc)
    ledger.write_text(led("codex", 1_000_000, fixed2) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=fixed2):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("codex", proj, records) - 1.0) < 1e-9
        cache = m.read_json(home / "spend_cache.json", {})
        assert cache["format"] == 3 and cache["offset"] > 0 and len(cache["records"]) == 1
    with open(ledger, "a", encoding="utf-8") as f:          # appending reads only the new bytes
        f.write(led("codex", 500_000, fixed2) + "\n")
    with mock.patch.object(m, "now", return_value=fixed2):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("codex", proj, records) - 1.5) < 1e-9
    ledger.write_text(led("codex", 250_000, fixed2) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=fixed2):  # a shrunken ledger recomputes from zero
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("codex", proj, records) - 0.25) < 1e-9

    # a corrupt limits file fails closed: spend_start refuses with a line naming the file
    for p in (home / "spend_limits.json", home / "spend_cache.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    (home / "spend_limits.json").write_text("{broken", encoding="utf-8")
    allowed, line = m.spend_start("deepseek", proj)
    assert allowed is False and "unreadable" in line, line
    (home / "spend_limits.json").unlink()

    # limits reject nan / inf / negative amounts (parse_limit)
    for bad_value in ("nan", "inf", "-inf", "-1"):
        try:
            m.parse_limit(bad_value)
            raise AssertionError("parse_limit accepted %r" % bad_value)
        except SystemExit:
            pass
    assert m.parse_limit("off") is None and m.parse_limit("5") == 5.0

    # display_name: a trailing [bracket] variant is stripped; an unknown model version stays as-is
    assert m.display_name("deepseek-v4-pro[1m]") == "DeepSeek V4 Pro"
    assert m.display_name("claude-opus-5-5-2026") == "Claude Opus 5.5"
    assert m.display_name("gpt-6.1-terra-something") == "GPT-6.1 Terra"
    assert m.display_name("claude-opus-6-0") == "claude-opus-6-0"
    assert m.display_name("deepseek-v4-pro") == "DeepSeek V4 Pro"

    # valid_scope: lowercased, and provider@profile must name a real profile (not the built-in "default")
    good(["profile", "set", "deepseek", "work", "--key", "DUMMY_A"])
    assert m.valid_scope("DEEPSEEK") is True and m.valid_scope("deepseek") is True
    assert m.valid_scope("deepseek@work") is True
    assert m.valid_scope("deepseek@default") is False       # "default" isn't a real profile → refused
    assert m.valid_scope("deepseek@nope") is False and m.valid_scope("nosuch@work") is False
    good(["profile", "set", "deepseek", "default", "--key", "DUMMY_B"])
    assert m.valid_scope("deepseek@default") is True        # a profile literally named "default" is a valid scope
    (home / "profiles.json").unlink()

    # session snapshots are deduplicated: two snapshots of one session count only the last
    for p in (home / "spend_cache.json", home / "spend_limits.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["deepseek"] = {"limit": 10}
    m.save_spend_limits(cfg)
    with mock.patch.object(m, "now", return_value=t0):
        m.ensure_baseline("deepseek", proj)
    def sess(sid, usd, ts):
        return json.dumps({"kind": "session", "lead": "deepseek", "project": canon,
                           "spend_usd": usd, "session": sid, "ts": m.iso(ts)}, separators=(",", ":"))
    ledger = home / "usage.jsonl"
    ledger.write_text(sess("s1", 1.0, t0 + dt.timedelta(hours=1)) + "\n" +
                      sess("s1", 4.0, t0 + dt.timedelta(hours=2)) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=t0 + dt.timedelta(hours=3)):
        records, _ = m.spend_cache_update()
        assert abs(m.current_spend("deepseek", proj, records) - 4.0) < 1e-9   # only the last snapshot counts

    # the cache persists its byte offset even when the new bytes contain no API-billed record
    for p in (home / "spend_cache.json", home / "spend_limits.json", home / "spend_events.json", home / "usage.jsonl"):
        if p.exists(): p.unlink()
    cfg, _ = m.load_spend_limits()
    cfg["global"]["codex"] = {"limit": 10}
    m.save_spend_limits(cfg)
    ledger = home / "usage.jsonl"
    ledger.write_text(json.dumps({"kind": "probe", "ts": m.iso(fixed2)}) + "\n", encoding="utf-8")
    with mock.patch.object(m, "now", return_value=fixed2):
        m.spend_cache_update()
        cache = m.read_json(home / "spend_cache.json", {})
        assert cache["offset"] == ledger.stat().st_size and cache["records"] == []

def worker_env_leak():
    with mock.patch.dict(os.environ, {
            "ANTHROPIC_API_KEY": "sk-leak", "ANTHROPIC_AUTH_TOKEN": "tok-leak",
            "CODEX_API_KEY": "cx-leak", "OPENAI_API_KEY": "oai-leak",
            "DEEPSEEK_API_KEY": "ds-keep", "CLAUDE_CONFIG_DIR": "/cfg-keep",
            "CLAUDECODE": "1"}, clear=True):
        env = m.worker_env({})
        assert "ANTHROPIC_API_KEY" not in env and "ANTHROPIC_AUTH_TOKEN" not in env
        assert "CODEX_API_KEY" not in env and "OPENAI_API_KEY" not in env
        assert env.get("DEEPSEEK_API_KEY") == "ds-keep"          # not a leak var, kept
        assert env.get("CLAUDE_CONFIG_DIR") == "/cfg-keep"       # KEEP_CLAUDE_VARS
        assert "CLAUDECODE" not in env
        env = m.worker_env({"ANTHROPIC_API_KEY": "sk-profile"})  # a profile's own key re-enters via extra
        assert env.get("ANTHROPIC_API_KEY") == "sk-profile"

def worker_env_declared():
    # A declared secret that isn't explicit takes its value from the real environment ("real env wins"), and any
    # ANTHROPIC_*_API_KEY / _AUTH_TOKEN beyond the four in WORKER_LEAK_VARS never leaks.
    with mock.patch.dict(os.environ, {"ANTHROPIC_FOUNDRY_API_KEY": "foundry-leak",
                                      "OPENAI_API_KEY": "shell-key"}, clear=True):
        env = m.worker_env({}, secrets=["OPENAI_API_KEY"])
        assert "ANTHROPIC_FOUNDRY_API_KEY" not in env      # any ANTHROPIC_*_API_KEY never leaks
        assert env.get("OPENAI_API_KEY") == "shell-key"    # declared, non-explicit → the real environment wins
    # A key named in profiles.json is dropped even though it isn't a hardcoded leak var; the run's own key re-enters.
    m.save_profiles({"providers": {"deepseek": {"profiles": {"work": {"key": "DEEPSEEK_API_KEY_WORK"}}}},
                     "projects": {}})
    try:
        assert m.profile_key_vars() == {"DEEPSEEK_API_KEY_WORK"}
        with mock.patch.dict(os.environ, {"DEEPSEEK_API_KEY_WORK": "work-leak"}, clear=True):
            assert "DEEPSEEK_API_KEY_WORK" not in m.worker_env({})
            assert m.worker_env({"DEEPSEEK_API_KEY_WORK": "work-val"})["DEEPSEEK_API_KEY_WORK"] == "work-val"
    finally:
        (home / "profiles.json").unlink()
    # From secrets.env only when the real environment lacks it (real env wins).
    (home / "secrets.env").write_text("OPENAI_API_KEY=from-file\n", encoding="utf-8")
    try:
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "shell-key"}, clear=True):
            assert m.worker_env({}, secrets=["OPENAI_API_KEY"]).get("OPENAI_API_KEY") == "shell-key"
        with mock.patch.dict(os.environ, {}, clear=True):
            assert m.worker_env({}, secrets=["OPENAI_API_KEY"]).get("OPENAI_API_KEY") == "from-file"
    finally:
        (home / "secrets.env").unlink()

def settings_deny_bom():
    sd = root / "denyproj"
    (sd / ".claude").mkdir(parents=True)
    (sd / ".git").mkdir()                              # stop the walk right here
    rules = {"permissions": {"deny": ["Read(**/.env)", "Bash(git push:*)", "Edit(**/*)"]}}
    # A UTF-8 BOM (as PowerShell 5 writes) must still yield the deny rules.
    (sd / ".claude" / "settings.json").write_bytes(b"\xef\xbb\xbf" + json.dumps(rules).encode("utf-8"))
    with mock.patch.dict(os.environ, {"ORCH_CWD": str(sd)}):
        warned = []
        deny = H.settings_deny(warned.append)
        assert "Read(**/.env)" in deny and "Bash(git push:*)" in deny, deny
        assert "Edit(**/*)" not in deny                # only Read/Bash rules are forwarded
        assert warned == []
    # A settings file that exists but isn't JSON is named, not silently dropped.
    (sd / ".claude" / "settings.json").write_text("{broken", encoding="utf-8")
    with mock.patch.dict(os.environ, {"ORCH_CWD": str(sd)}):
        warned = []
        deny = H.settings_deny(warned.append)
        assert deny == []
        assert any("settings.json" in w for w in warned), warned

def codex_home_profile():
    prof = m.Profile("codex", "work", {"home": str(home / "cx-work")}, "test", True)
    with mock.patch.dict(os.environ, {"CODEX_HOME": str(home / "no-codex")}):
        assert m.codex_home(proj, prof) == str(Path(str(home / "cx-work")).expanduser())
        assert m.codex_home(proj) == str(Path(str(home / "no-codex")).expanduser())

failed = 0
for name, test in [("1 parallel offers, take/reclaim, sessions and capacity", parallel_state),
                   ("1 atomic I/O failures, rollback, nested lock and crash release", state_failures),
                   ("2 launch session profile precedence and errors", launch_profiles),
                   ("3 central worker guard for every handoff command", worker_guard),
                   ("4 stale measurement pace and independent window timestamps", stale_budget),
                   ("5 weekly TIGHT without current five-hour numbers", weekly_budget),
                   ("5b weekly recent pace and shrinking reserve", weekly_pace),
                   ("5c Codex weekly recent pace and reserve", codex_weekly),
                   ("6 force cannot bypass manual profile capacity", hard_cap),
                   ("7 wait any reports an existing result exactly once", existing_result),
                   ("8 inferred activity gets one overdue warning; fast check never scans", overdue_activity),
                   ("9 lead drops OAuth token; Claude executor works without it", token_hygiene),
                   ("10 blocked/partial ledger and model-only capacity fallback", run_outcomes),
                   ("10b corrupt price data keeps the ledger line, priced 0", run_cost_fallback),
                   ("review corrupt state recovery and operator protection", corruption_recovery),
                   ("review stale claims, late finishers and assignment failures", assignment_recovery),
                   ("review report first status and reclaimed slot", report_reclaimed),
                   ("review handoff path storage and old metas", meta_paths),
                   ("review monthly spend: prices, counters, cache restart", spend_limits),
                   ("review worker env strips login/API keys", worker_env_leak),
                   ("review worker env: declared secrets, profile keys, anthropic key vars", worker_env_declared),
                   ("review settings deny survives a BOM and names a broken file", settings_deny_bom),
                   ("review --profile honoured by codex account lookups", codex_home_profile)]:
    try:
        test()
        print("PASS " + name)
    except Exception:
        failed += 1
        print("FAIL " + name)
        traceback.print_exc()
sys.exit(bool(failed))
EOF
); review_rc=$?
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) [[ -z "$line" ]] || echo "$line" ;;
  esac
done <<<"$review"
[[ $review_rc -eq 0 ]] || bad "review regression process failed (rc=$review_rc)"

echo "── registry & doctor"
out=$($ORCH registry path); contains "$out" "registry/providers.yaml" "default registry path"
$ORCH registry init >/dev/null; out=$($ORCH registry path); contains "$out" "$ORCH_HOME/providers.yaml" "user registry overrides default"
out=$($ORCH doctor); ok "doctor runs (rc=$?)"
contains "$out" "DEEPSEEK_API_KEY *set" "doctor sees the DeepSeek key"
contains "$out" "Codex login *Logged in" "doctor checks the codex login"

echo "── guide, footprint, plugin wiring"
out=$($ORCH guide); contains "$out" "manual" "guide lists the reference parts"
for t in manual profiles quota usage spend settings; do
  out=$($ORCH guide $t); [[ -n "$out" ]] && ok "guide $t" || bad "guide $t empty"
done
$ORCH guide nope >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "unknown guide topic refused" || bad "guide nope accepted"
out=$($ORCH guide settings); contains "$out" "secrets.env" "settings guide names secrets.env"
contains "$out" "orch registry show" "settings guide names orch registry show"
contains "$out" "orch profile use claude <name>" "settings guide pairs the budget thresholds with their use"
contains "$out" "ANTHROPIC_AUTH_TOKEN" "settings guide: a worker never sees the operator's Anthropic credentials"
grep -q 'description:.*config' "$PLUGIN/skills/orchestrate/SKILL.md" && ok "skill description names configuration" || bad "skill description does not name configuration"
grep -q 'subscription slots before API-billed' "$PLUGIN/skills/orchestrate/SKILL.md" && ok "routing: subscriptions before API-billed slots" || bad "SKILL.md lost the rule: subscriptions before API-billed slots"
grep -q 'subscriptions go before API-billed' "$PLUGIN/skills/orchestrate/reference/budget.md" && ok "budget guide states the default order" || bad "budget.md lost the default order"
out=$($ORCH footprint); contains "$out" "$ORCH_HOME" "footprint names ORCH_HOME"
contains "$out" "  project .*proj.*\.orchestra" "footprint lists project state"
contains "$out" "claude plugin uninstall orchestra@orchestra " "footprint shows the standard uninstall"
grep -q '"SessionEnd"' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd hook registered" || bad "SessionEnd hook missing"
grep -q 'run.sh\\" session-end' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd → orch hook session-end" || bad "session-end wiring"

echo
echo "passed: $pass  failed: $fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
