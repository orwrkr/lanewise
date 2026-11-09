#!/usr/bin/env bash
# Self-test for orch: fake codex + fake claude (DeepSeek worker) + temporary git repo + isolated ORCH_HOME.
# Runs in WSL/Linux/macOS and on Windows in Git Bash (native Windows Python).
# Usage: bash tests/run_tests.sh
set -uo pipefail
die() { echo "Self-test setup failed: $*" >&2; exit 1; }
TESTS="$(cd "$(dirname "$0")" && pwd)" || die "cannot locate the tests"
PLUGIN="$(cd "$TESTS/../plugins/orchestra" && pwd)" || die "cannot locate plugin"
PY=""
# Real interpreters before a Windows Store / Python install manager alias (…/WindowsApps/), as hooks/run.sh does: an
# alias costs a redirect on every start, and the install manager reads a script's first line (bin/orch: #!/bin/sh).
for KIND in real alias; do
  for p in python3 python py; do
    CMD="$(command -v "$p" 2>/dev/null)" || continue
    case "$CMD" in
      *WindowsApps*) [[ "$KIND" == real ]] && continue ;;
      *) [[ "$KIND" == alias ]] && continue ;;
    esac
    if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      PY="$p"; break 2
    fi
  done
done
[[ -n "$PY" ]] || { echo "Python >= 3.8 not found"; exit 1; }
# path as Python sees it: Git Bash /c/… → C:/…, unchanged elsewhere
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ORCH="$PY $PLUGIN/bin/orch"
T="$(mktemp -d)" || die "cannot create temporary directory"
[[ -n "$T" && -d "$T" ]] || die "invalid temporary directory"
# TEMP can hold a Windows short name (RUNNER~1), and orch reports the long one: compare like with like
if command -v cygpath >/dev/null 2>&1; then T="$(cygpath -u "$(cygpath -w -l "$T")")"; fi
export ORCH_HOME; ORCH_HOME="$(native "$T/home")"
export PATH="$T/fakebin:$PATH"
unset CLAUDE_PROJECT_DIR ORCH_PROJECT_DIR ORCH_WORKER ORCH_CODEX_BIN ORCH_CLAUDE_BIN DEEPSEEK_API_KEY ORCH_NOTIFY_CMD ORCH_DEEPSEEK_BALANCE_URL
# the suite's own ANTHROPIC_* would make every orch process a detected lead (a test runs inside a lead session too)
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL ORCH_LEAD ORCH_LEAD_ENV ORCH_LEAD_VIA ORCH_LEAD_KEY
export ORCH_BALANCE=off     # no check reaches a real provider for a balance; the balance section turns it on against a local server
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
lacks() { if grep -qF -- "$2" <<<"${1//\\//}"; then bad "$3"; echo "$1"; else ok "$3"; fi; }

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
elif mode in ("trace_fail", "trace_limit", "trace_only_limit"):
    print("2026-11-05T14:12:02.128535Z ERROR codex_core::session: failed to load cloud-quotas skill", flush=True)
    if mode == "trace_fail":
        emit({"type": "turn.failed", "error": {"message": "An unrelated failure"}})
    elif mode == "trace_limit":
        emit({"type": "turn.failed", "error": {"message": "You've hit your usage limit. Try again in 2 hours."}})
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
export ORCH_CLAUDE_BIN; ORCH_CLAUDE_BIN="$(native "$T/fakebin/fake_claude.py")"     # never the real claude, like codex above
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

