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
# TEMP can hold a Windows short name (RUNNER~1), and orch reports the long one: compare like with like
if command -v cygpath >/dev/null 2>&1; then T="$(cygpath -u "$(cygpath -w -l "$T")")"; fi
export ORCH_HOME; ORCH_HOME="$(native "$T/home")"
export PATH="$T/fakebin:$PATH"
unset CLAUDE_PROJECT_DIR ORCH_PROJECT_DIR ORCH_WORKER ORCH_CODEX_BIN ORCH_CLAUDE_BIN DEEPSEEK_API_KEY ORCH_NOTIFY_CMD ORCH_DEEPSEEK_BALANCE_URL
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
# private names: read at run time from ~/.orchestra, never listed in the repository
rm -f "$GT/msg"    # it holds a home path from above, and this repository is scanned and committed below
GH="$T/guard-home"; mkdir -p "$GH" || die "cannot create guard home"
printf 'Acmecorp\n# a comment\n\n' > "$GH/private_terms.txt"
cat > "$GH/profiles.json" <<'EOF'
{"providers": {"deepseek": {"profiles": {"betacli": {"key": "KEY_OF_GAMMA"}, "personal": {"key": "DEEPSEEK_API_KEY"}}}},
 "projects": {"/path/to/delta-app": {"deepseek": "betacli"}}, "project_rules": {"/path/to/epsilon-app": "rule"}}
EOF
guard_private() { printf '%s\n' "$1" > "$GT/f.txt"; ORCH_HOME="$(native "$GH")" $PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1; }
for text in "acmecorp" "ACMECORP-web" "x_acmecorp_y" "deepseek@betacli" "KEY_OF_GAMMA" "delta-app" "epsilon-app"; do
  guard_private "see $text here" && bad "guard missed a private name: $text" || ok "guard flags a private name: $text"
done
for text in "macmecorpx" "personal" "deepseek@personal" "DEEPSEEK_API_KEY" "a comment" "client"; do
  guard_private "see $text here" && ok "guard allows: $text" || bad "guard false alarm on a private name: $text"
done
guard_on "see acmecorp here" && ok "no ~/.orchestra (CI): no private names to check" || bad "guard flagged a name with no list"
printf 'subject acmecorp\n' > "$T/guard-msg"
ORCH_HOME="$(native "$GH")" $PY "$GUARD" --message "$(native "$T/guard-msg")" >/dev/null 2>&1 && bad "guard missed a private name in a message" || ok "guard flags a private name in a message"
printf '{broken' > "$GH/profiles.json"
guard_private "see acmecorp here" && bad "a broken profiles.json dropped the private terms" || ok "a broken profiles.json leaves the private terms working"
guard_private "see betacli here" && ok "a broken profiles.json is no finding" || bad "guard failed on a broken profiles.json"
# a push: the last stop before commits leave this machine, for what the commit hooks didn't see
GR="$T/guard-remote.git"; git init -q --bare "$GR" || die "cannot create guard remote"
git -C "$GT" remote add origin "$(native "$GR")" || die "guard remote"
git -C "$GT" checkout -q -- f.txt 2>/dev/null
git -C "$GT" add -A; git -C "$GT" -c commit.gpgsign=false commit -qm "clean again" --no-verify >/dev/null 2>&1
gpush() { ORCH_HOME="$(native "$GH")" git -C "$GT" -c core.hooksPath="$HOOKS" push -q origin "$@" >/dev/null 2>&1; }
gcommit() { git -C "$GT" add -A; git -C "$GT" -c commit.gpgsign=false commit -q --no-verify "$@" >/dev/null 2>&1; }
gbranch="$(git -C "$GT" symbolic-ref --short HEAD)"
printf 'acmecorp\n' > "$GT/old.txt"; gcommit -m "an early name"; git -C "$GT" rm -q old.txt; gcommit -m "removed again"
gpush "$gbranch" && bad "pre-push let a name through in an old commit, though the tree is clean" || ok "pre-push reads the whole history a new branch would send"
git -C "$GT" reset -q --hard HEAD~2
gpush "$gbranch" && ok "pre-push lets a clean branch through" || bad "pre-push stopped a clean branch"
gcommit --allow-empty -m "subject acmecorp"
gpush "$gbranch" && bad "pre-push let a private name through in a message" || ok "pre-push stops a private name in a message"
git -C "$GT" reset -q --hard HEAD~1
printf 'x /home/%s/y\n' "$u" > "$GT/f2.txt"; gcommit -m "a home path"
gpush "$gbranch" && bad "pre-push let a home path through" || ok "pre-push stops a home path"
git -C "$GT" reset -q --hard HEAD~1
git -C "$GT" -c tag.gpgsign=false tag -a t1 -m "tag acmecorp"
gpush t1 && bad "pre-push let a private name through in a tag" || ok "pre-push stops a private name in an annotated tag"
git -C "$GT" tag -d t1 >/dev/null
gcommit --allow-empty -m "fine again"
gpush "$gbranch" && ok "pre-push lets the next clean commit through" || bad "pre-push stopped a clean commit"

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
FAKE_CLAUDE=ok $ORCH run deepseek "default model" >/dev/null; rc=$?
expect_rc 0 $rc "deepseek run without --model"
check 'e["ANTHROPIC_MODEL"] == "deepseek-flash" and a[a.index("--model") + 1] == "deepseek-flash"' "default model deepseek-flash passed to Claude Code"
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
contains "$out" "Command: .*--model deepseek-flash --resume" "claude arguments after --, default lead model Flash"
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
assert ds["usage"] == {"input_tokens": 150, "cached_input_tokens": 400, "output_tokens": 25, "model": "deepseek-flash"}, ds
EOF
# a worktree holds no git-ignored files: an @import it lacks comes from the project folder
IP="$T/import-proj"; mkdir -p "$IP/.local-notes" "$IP/docs" && git -C "$IP" init -q && git -C "$IP" config user.email t@t && git -C "$IP" config user.name t \
  && printf 'TRACKED-MARKER\n@.local-notes/env.md\n@.local-notes/own.md\n@.local-notes/missing.md\n' > "$IP/CLAUDE.md" \
  && printf 'MAIN-DOC\n' > "$IP/docs/branch.md" \
  && printf '.local-notes/\n' > "$IP/.gitignore" && git -C "$IP" add . && git -C "$IP" -c commit.gpgsign=false commit -qm init \
  && git -C "$IP" worktree add -q "$T/import-wt" -b import-wt || die "cannot create the import fixture"
printf 'ENV-MARKER\n@deeper.md\n' > "$IP/.local-notes/env.md"; printf 'DEEPER-MARKER\n' > "$IP/.local-notes/deeper.md"
printf 'OWN-MAIN-MARKER\n' > "$IP/.local-notes/own.md"
mkdir -p "$T/import-wt/.local-notes"; printf 'OWN-WORKTREE-MARKER\n' > "$T/import-wt/.local-notes/own.md"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$IP")" "$(native "$T/import-wt")" "$(native "$T/import-out.md")" <<'EOF' && ok "an @import missing from a worktree comes from the project folder" || bad "imports in a worktree"
import importlib.machinery, importlib.util, sys
from pathlib import Path
orch, main, wt, out = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("orch_imports", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
text = m.build_context(wt, set(), Path(out)).read_text(encoding="utf-8")
for found in ("TRACKED-MARKER", "ENV-MARKER", "DEEPER-MARKER", "OWN-WORKTREE-MARKER", "@.local-notes/missing.md"):
    assert found in text, (found, text)
assert "OWN-MAIN-MARKER" not in text, text
text = m.build_context(main, set(), Path(out)).read_text(encoding="utf-8")
assert "OWN-MAIN-MARKER" in text and "OWN-WORKTREE-MARKER" not in text, text
EOF
mkdir -p "$IP/docs" "$IP/.claude" "$T/import-wt/docs"
printf 'AGENTS.md\n' >> "$IP/.git/info/exclude"
printf '.claude/CLAUDE.md\n' >> "$IP/.gitignore"
printf 'IGNORED-AGENTS\n@docs/branch.md\n' > "$IP/AGENTS.md"
printf 'IGNORED-CLAUDE\n@../AGENTS.md\n' > "$IP/.claude/CLAUDE.md"
printf 'MAIN-DOC\n' > "$IP/docs/branch.md"
printf 'BRANCH-DOC\n' > "$T/import-wt/docs/branch.md"
rm "$T/import-wt/CLAUDE.md"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$IP")" "$(native "$T/import-wt")" "$(native "$T/import-out.md")" <<'EOF' && ok "ignored instructions reach worktrees with branch imports" || bad "ignored instructions"
import importlib.machinery, importlib.util, sys
from pathlib import Path
orch, main, wt, out = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("orch_ignored", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
for native in (set(), {"AGENTS.md"}):
    text = m.build_context(wt, native, Path(out)).read_text(encoding="utf-8")
    assert text.count("IGNORED-AGENTS") == 1 and text.count("IGNORED-CLAUDE") == 1, text
    assert "BRANCH-DOC" in text and "MAIN-DOC" not in text and "TRACKED-MARKER" not in text, text
Path(wt, "AGENTS.md").write_text("WORKTREE-AGENTS\n", encoding="utf-8")
text = m.build_context(wt, {"AGENTS.md"}, Path(out)).read_text(encoding="utf-8")
assert "WORKTREE-AGENTS" not in text and "IGNORED-AGENTS" not in text, text
EOF
# a git-ignored AGENTS.md missing from a worktree reaches a real codex run: codex reads AGENTS.md natively, so
# the file the adapter cannot find still goes into the run's context.md
rm -f "$T/import-wt/AGENTS.md"
out=$(FAKE_CODEX=ok $ORCH run codex --cd "$(native "$T/import-wt")" "review the form"); rc=$?
expect_rc 0 $rc "a run in the worktree starts"
RID=$(grep -o 'cod-[0-9]*-[0-9]*-[a-z0-9]*' <<<"$out" | head -1)
[[ -n "$RID" ]] && grep -q "IGNORED-AGENTS" "$REPO/.orchestra/runs/$RID/context.md" \
  && ok "the ignored AGENTS.md reaches the run's context.md" || bad "the ignored AGENTS.md is missing from the run's context.md ($RID)"
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
contains "$out" "DeepSeek *DeepSeek V4.1 Flash .*Café parser tests" "DeepSeek executor in the session report"
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
out=$(printf '## Goal\nDo X — naïve café ✓\n' | $ORCH handoff new --title "UI check" --model "Gemini 4 Argon" --model-key gemini-4-argon --effort High --fallback "codex gpt-5.6-sol high")
contains "$out" "AG-0001" "handoff id assigned"
contains "$out" "Execute the task described in .orchestra/handoffs/AG-0001/TASK.md" "paste line in card"
WT="$REPO"
[[ -f "$WT/.orchestra/handoffs/AG-0001/TASK.md" ]] && ok "TASK.md inside the project folder" || bad "TASK.md missing"
grep -q "STATUS: IN_PROGRESS" "$WT/.orchestra/handoffs/AG-0001/TASK.md" && ok "protocol appended" || bad "protocol missing"
grep -q "ag/ag-0001" "$WT/.orchestra/handoffs/AG-0001/TASK.md" && bad "a branch named in TASK.md" || ok "no branch in TASK.md"
out=$($ORCH handoff list); contains "$out" "AG-0001 *WAITING" "state WAITING"
out=$($ORCH handoff check); contains "$out" "No new events" "no events yet"
sleep 2; echo "edit by someone" > "$WT/scratch-activity.txt"
out=$($ORCH handoff list); contains "$out" "AG-0001 *WAITING" "a file touched in the project folder does not start the task"
lacks "$out" "STARTED?" "file activity in the project folder → not STARTED?"
rm -f "$WT/scratch-activity.txt"
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
      --model-key gemini-4-argon --effort High --fallback "codex gpt-6.1-sol high"); rc=$?
expect_rc 0 $rc "task offered to the pool"
PID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
contains "$out" "in the manual pool" "pool card shown"
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
TW="$REPO"
grep -q "an executor in the Orchestra system" "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "TASK.md: executor role for the manual agent" || bad "role missing"
grep -q 'Project rules.*`CLAUDE.md`' "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "TASK.md points to the project rules" || bad "rules pointer missing"
grep -q "AGENT:" "$TW/.orchestra/handoffs/$PID/TASK.md" && ok "protocol asks the agent to name itself" || bad "AGENT line missing"
grep -q "only that task.s RESULT.md and, for a task that changes files, its own worktree" "$TW/.agents/rules/orchestra-task.md" 2>/dev/null && ok "the rule allows a writing task its own worktree" || bad "rule does not mention the task worktree"
grep -q "trigger: always_on" "$TW/.agents/rules/orchestra-task.md" 2>/dev/null && ok "Antigravity workspace rule in the project folder" || bad "rule file missing"
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
# a task of an older version keeps its worktree as a sibling path, relative on disk
out=$(printf 'x' | $ORCH handoff offer --title "wt rel" --max-offers 99); WID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
$ORCH handoff take "$WID" --max-open 99 >/dev/null
git -C "$REPO" worktree add -q -b "ag/old-$WID" "$T/proj.wt/$WID" || die "cannot create the old-task worktree"
$PY - "$(native "$REPO/.orchestra/handoffs/$WID/meta.json")" "$(native "$T/proj.wt/$WID")" "$WID" <<'EOF'
import json, sys
p, wt, hid = sys.argv[1:4]
m = json.load(open(p, encoding="utf-8"))
m.update(worktree=True, workdir=wt, branch="ag/old-" + hid, task_path=wt + "/.orchestra/handoffs/%s/TASK.md" % hid,
         result_path=wt + "/.orchestra/handoffs/%s/RESULT.md" % hid)
json.dump(m, open(p, "w", encoding="utf-8"))
EOF
$ORCH handoff done "$WID" --note "saved once" >/dev/null
$PY - "$(native "$REPO/.orchestra/handoffs/$WID/meta.json")" "$WID" <<'EOF' && ok "an older worktree task keeps a relative sibling path" || bad "worktree path not relative"
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

echo "── manual tasks: read-only in the project folder, writing ones in a worktree inside it"
MP="$T/mt-proj"; mkdir -p "$MP" && git -C "$MP" init -q && git -C "$MP" config user.email t@t && git -C "$MP" config user.name t \
  && echo hi > "$MP/f.txt" && git -C "$MP" add . && git -C "$MP" -c commit.gpgsign=false commit -qm init || die "cannot create the manual-task fixture"
NMP="$(native "$MP")"     # orch prints native paths, and contains() compares them with forward slashes
mt() { (cd "$MP" && "$@"); }
mt_id() { grep -o 'AG-[0-9]*' <<<"$1" | head -1; }
mt_meta() { $PY -c 'import json, sys; m = json.load(open(sys.argv[1], encoding="utf-8")); print(m.get(sys.argv[2]))' "$(native "$MP/.orchestra/handoffs/$1/meta.json")" "$2"; }
mt_cancel_all() {
  for h in $(mt $ORCH handoff list --json | $PY -c "import json, sys; print(' '.join(m['id'] for m in json.load(sys.stdin)))"); do
    mt $ORCH handoff cancel "$h" >/dev/null
  done
}

# --worktree is gone, --base goes only with --write (a session that has not reloaded may still pass the old flags)
out=$(printf 'x' | mt $ORCH handoff offer --title "wt" --worktree 2>&1); rc=$?
expect_rc 1 $rc "offer --worktree fails"
contains "$out" "orch: --worktree is gone: a task that changes files takes --write" "offer --worktree: the line names --write"
contains "$out" "see orch guide manual" "offer --worktree: the line points to the guide"
out=$(printf 'x' | mt $ORCH handoff new --title "wt" --worktree 2>&1); rc=$?
expect_rc 1 $rc "new --worktree fails"
contains "$out" "--worktree is gone: a task that changes files takes --write" "new --worktree: the same line"
out=$(printf 'x' | mt $ORCH handoff offer --title "wt" --base main 2>&1); rc=$?
expect_rc 1 $rc "offer --base without --write fails"
contains "$out" "--base goes only with --write" "offer --base: the line says so"
out=$(printf 'x' | mt $ORCH handoff new --title "wt" --base main 2>&1); rc=$?
expect_rc 1 $rc "new --base without --write fails"
[[ -z "$(mt $ORCH handoff list --all | grep ' wt · ')" ]] && ok "a refused flag leaves no task behind" || bad "a refused flag left a task"
for sub in offer new; do
  out=$(mt $ORCH handoff $sub --help)
  lacks "$out" "--worktree" "handoff $sub --help no longer offers --worktree"
  contains "$out" "--write" "handoff $sub --help offers --write"
  contains "$out" "--base" "handoff $sub --help offers --base (with --write)"
done

# a read-only task (the default) in the project folder
out=$(printf '## Goal\nlook\n' | mt $ORCH handoff new --title "read one" --model "Gemini 3.8 Flash" --max-open 99); R1=$(mt_id "$out")
contains "$out" "In Antigravity, in the project folder: $NMP" "taken: the card says the project folder"
lacks "$out" "Open in" "taken: no 'Open in' line"
lacks "$out" "It works in" "a read-only task has no worktree line"
lacks "$out" "Branch:" "taken: no branch line"
[[ "$(mt_meta "$R1" write)" == "False" && "$(mt_meta "$R1" branch)" == "None" && "$(mt_meta "$R1" workdir)" == "." ]] \
  && ok "meta: write false, no branch, workdir is the project" || bad "meta of a read-only task"
[[ -d "$T/mt-proj.wt" || -d "$MP/.orchestra/wt" ]] && bad "a read-only task made a worktree folder" || ok "no worktree folder for a read-only task"
RP="Execute the task described in .orchestra/handoffs/$R1/TASK.md, by the execution protocol at the end of that file (RESULT.md status markers). Run no shell commands unless the task lists them. If your file tools can't open .orchestra/ because git ignores it, don't use the terminal to get around that: say so in the chat and stop."
[[ "$(mt_meta "$R1" paste)" == "$RP" ]] && ok "read-only paste line: exact text, one line" || bad "read-only paste line: $(mt_meta "$R1" paste)"
[[ $(mt_meta "$R1" paste | wc -l) -eq 1 ]] && ok "the paste line is one line" || bad "the paste line spans lines"
TK="$MP/.orchestra/handoffs/$R1/TASK.md"
grep -q "This task changes nothing: change no file except \`.orchestra/handoffs/$R1/RESULT.md\`, and do not commit. Other work goes on in this$" "$TK" \
  && ok "read-only protocol: changes nothing, other work goes on in this folder" || bad "read-only protocol step 2"
grep -q "Run no shell commands unless this task lists them" "$TK" && ok "read-only protocol: no shell commands" || bad "read-only protocol step 3"
grep -q "with your file editor, with two lines" "$TK" && grep -q "Gemini 3.8 Flash>" "$TK" && ok "read-only protocol: RESULT.md created with the file editor" || bad "read-only protocol step 1"
grep -q '## Summary` (your findings)' "$TK" && ok "read-only protocol: findings, no changed files" || bad "read-only report sections"
grep -q "Changed files" "$TK" && bad "read-only protocol asks for changed files" || ok "read-only protocol has no Changed files section"
contains "$(cat "$TK")" "^- Working folder: \`$NMP\`" "TASK.md header keeps the working folder"
grep -q "Branch" "$TK" && bad "a read-only TASK.md names a branch" || ok "a read-only TASK.md has no branch line"
contains "$(cat "$MP/.orchestra/MANUAL.md")" "in the project folder: \`$NMP\`" "the board follows the card"

# one general rule file, not one per task
RULE="$MP/.agents/rules/orchestra-task.md"
[[ -f "$RULE" ]] && grep -q "trigger: always_on" "$RULE" && ok "Antigravity rule written into the project folder" || bad "rule missing"
grep -q "This applies only when a message names an Orchestra task (an id such as AG-0004); other conversations ignore it." "$RULE" \
  && grep -q "The task file is \`.orchestra/handoffs/<id>/TASK.md\`" "$RULE" && ok "the rule is general: it names no task" || bad "rule text"
grep -q "A task that changes files names its own worktree: work only inside it." "$RULE" && ok "the rule tells a writing task to stay in its worktree" || bad "rule: worktree line"
grep -q "$R1" "$RULE" && bad "the rule names the first task" || ok "the rule does not name the task that wrote it"
grep -q "^.agents/rules/orchestra-task.md$" "$MP/.git/info/exclude" && ok "the rule is excluded from git" || bad "rule not excluded"
RULE_SUM=$(cksum < "$RULE")
out=$(printf 'x' | mt $ORCH handoff new --title "read two" --max-open 99); R2=$(mt_id "$out")
[[ "$(cksum < "$RULE")" == "$RULE_SUM" && $(ls "$MP/.agents/rules" | wc -l) -eq 1 ]] && ok "two open tasks share the one rule file" || bad "rule changed or multiplied"
echo "stale" > "$RULE"
printf 'x' | mt $ORCH handoff new --title "read three" --max-open 99 >/dev/null
[[ "$(cksum < "$RULE")" == "$RULE_SUM" ]] && ok "a different rule file is rewritten at the next assignment" || bad "rule not restored"

# a read-only task starts with its RESULT.md only: a file touched in the project after the take starts nothing
sleep 2; echo "other work" >> "$MP/f.txt"
out=$(mt $ORCH handoff list); contains "$out" "$R1 *WAITING" "a file touched after the take: still WAITING"
lacks "$out" "STARTED?" "a file touched in the project never shows STARTED?"
out=$(mt $ORCH handoff check); lacks "$out" "STARTED" "check: no start from someone else's edit"
printf 'x' | mt $ORCH handoff new --title "read, dirty tree" --max-open 99 >/dev/null; expect_rc 0 $? "a read-only task on a dirty tree is handed out"

# a writing task: a worktree of its own inside the project folder, whatever the state of the project folder
out=$(printf '## Goal\nchange\n' | mt $ORCH handoff offer --title "write offer" --write --max-offers 99); OW=$(mt_id "$out")
expect_rc 0 $? "a writing task can be offered"
contains "$out" "(changes files, in its own worktree)" "the pool card says a writing task changes files in its own worktree"
lacks "$out" "(own worktree)" "the pool card no longer uses the old wording"
contains "$out" "you then get the line to paste" "the pool card says what the take gives"
contains "$(cat "$MP/.orchestra/MANUAL.md")" "(changes files, in its own worktree)" "the board marks a writing task in the pool"
[[ -e "$MP/.orchestra/wt/$OW" ]] && bad "a worktree before the take" || ok "no worktree until the task is taken"
out=$(mt $ORCH handoff take "$OW" --max-open 99); rc=$?
expect_rc 0 $rc "a writing task is taken while the project folder is dirty"
BR1="ag/$(tr 'A-Z' 'a-z' <<<"$OW")"
contains "$out" "In Antigravity, in the project folder: $NMP" "writing card: the agent's window stays on the project folder"
contains "$out" "It works in: .orchestra/wt/$OW (its own worktree, branch $BR1); no need to open it" "writing card: says where the task works"
lacks "$out" "Open in" "writing card: no 'Open in' line"
[[ -f "$MP/.orchestra/wt/$OW/f.txt" && "$(git -C "$MP/.orchestra/wt/$OW" rev-parse --abbrev-ref HEAD)" == "$BR1" ]] \
  && ok "the worktree is .orchestra/wt/<id> on branch ag/<id>" || bad "worktree layout"
[[ "$(cat "$MP/.orchestra/wt/$OW/f.txt")" == "hi" ]] && ok "the worktree starts from HEAD, not from the dirty project folder" || bad "worktree content"
[[ -f "$MP/.orchestra/handoffs/$OW/TASK.md" && ! -e "$MP/.orchestra/wt/$OW/.orchestra" ]] && ok "TASK.md stays in the project's handoffs folder" || bad "TASK.md location"
$PY - "$(native "$MP/.orchestra/handoffs/$OW/meta.json")" "$OW" "$BR1" <<'EOF' && ok "meta: workdir is the worktree, task and result paths are the project's" || bad "writing meta"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid, br = sys.argv[2], sys.argv[3]
assert m["write"] is True and m["branch"] == br, m
assert m["workdir"] == ".orchestra/wt/" + hid, m["workdir"]
assert m["task_path"] == ".orchestra/handoffs/%s/TASK.md" % hid and m["result_path"] == ".orchestra/handoffs/%s/RESULT.md" % hid, m
EOF
WP="Execute the task described in .orchestra/handoffs/$OW/TASK.md, by the execution protocol at the end of that file (RESULT.md status markers). Work only inside .orchestra/wt/$OW, a separate git worktree. If your file tools can't open .orchestra/ because git ignores it, don't use the terminal to get around that: say so in the chat and stop."
[[ "$(mt_meta "$OW" paste)" == "$WP" ]] && ok "writing paste line: exact text, one line" || bad "writing paste line: $(mt_meta "$OW" paste)"
[[ $(mt_meta "$OW" paste | wc -l) -eq 1 ]] && ok "the writing paste line is one line" || bad "the writing paste line spans lines"
TW="$MP/.orchestra/handoffs/$OW/TASK.md"
grep -q "Work only inside \`.orchestra/wt/$OW\`, a separate git worktree on branch \`$BR1\`" "$TW" && ok "writing protocol: work only inside the worktree" || bad "writing protocol step 2"
grep -q "never its same-named original at the project root" "$TW" && ok "writing protocol: not the original at the project root" || bad "writing protocol: same-named original"
grep -q "install dependencies as the project instructions say; do not copy secrets" "$TW" && ok "writing protocol: dependencies, no secrets" || bad "writing protocol: dependencies"
grep -q "Do not commit and do not switch branches: the orchestrator reviews the changes in that worktree and commits them." "$TW" && ok "writing protocol: the orchestrator commits" || bad "writing protocol: commit rule"
grep -q '## Changed files' "$TW" && ok "writing protocol keeps the Changed files section" || bad "writing protocol: Changed files"
grep -q "Run no shell commands" "$TW" && bad "the writing protocol forbids commands" || ok "the writing protocol does not forbid commands"
grep -q "^- Branch: \`$BR1\`" "$TW" && ok "TASK.md header names the branch of a writing task" || bad "TASK.md branch line"
# the project's git status does not see the nested worktree, with .orchestra/ ignored through .git/info/exclude
[[ "$(git -C "$MP" status --porcelain)" == " M f.txt" ]] && ok "the project's git status shows only its own edit, not the nested worktree" || bad "git status: $(git -C "$MP" status --porcelain)"
git -C "$MP" worktree list | grep -q "wt/$OW" && ok "git knows the nested worktree" || bad "git worktree list"

# two writing tasks open at once with a dirty project folder
out=$(printf 'x' | mt $ORCH handoff new --title "write two" --write --max-open 99); rc=$?
expect_rc 0 $rc "a second writing task beside the first, on a dirty folder"
OW2=$(mt_id "$out"); BR2="ag/$(tr 'A-Z' 'a-z' <<<"$OW2")"
[[ -d "$MP/.orchestra/wt/$OW2" && "$(git -C "$MP/.orchestra/wt/$OW2" rev-parse --abbrev-ref HEAD)" == "$BR2" && "$BR1" != "$BR2" ]] \
  && ok "each writing task has its own worktree and branch" || bad "second worktree"
lacks "$out" "HANDOFF" "no HANDOFF_DIRTY or HANDOFF_WRITE_BUSY any more"
[[ "$(git -C "$MP" status --porcelain)" == " M f.txt" ]] && ok "two nested worktrees stay out of the project's git status" || bad "git status: $(git -C "$MP" status --porcelain)"
grep -rq "HANDOFF_DIRTY\|HANDOFF_WRITE_BUSY" "$PLUGIN/bin/orch" "$PLUGIN/skills" "$PLUGIN/README.md" && bad "the removed guards are still mentioned" || ok "the removed guards are gone from code and docs"

# a start in a worktree is seen by the folder scan; the project folder's edits are not the task's
sleep 2; echo "agent edit" >> "$MP/.orchestra/wt/$OW/f.txt"
out=$(mt $ORCH handoff list); contains "$out" "$OW *STARTED?" "a file changed in the task's worktree shows STARTED?"
contains "$out" "$OW2 *WAITING" "the other writing task, untouched, is still WAITING"
# RESULT.md is detected in the project's handoffs folder
printf 'STATUS: DONE\nAGENT: Antigravity · Gemini 3.8 Flash\n## Summary\nok\n## Changed files\nf.txt\n' > "$MP/.orchestra/handoffs/$OW/RESULT.md"
out=$(mt $ORCH handoff check); contains "$out" "$OW finished: STATUS DONE" "RESULT.md in the project's handoffs folder is detected for a writing task"
[[ "$(git -C "$MP/.orchestra/wt/$OW" diff --stat | wc -l)" -ge 1 ]] && ok "the agent's change is in the worktree, ready to review" || bad "worktree diff"
[[ "$(git -C "$MP" status --porcelain)" == " M f.txt" ]] && ! grep -q "agent edit" "$MP/f.txt" && ok "the project folder got no stray edit from the agent" || bad "project folder changed"

# --base: the worktree starts from another ref
git -C "$MP" stash -q; git -C "$MP" checkout -q -b side && echo "side" > "$MP/side.txt" && git -C "$MP" add side.txt && git -C "$MP" -c commit.gpgsign=false commit -qm side && git -C "$MP" checkout -q - && git -C "$MP" stash pop -q
out=$(printf 'x' | mt $ORCH handoff new --title "based" --write --base side --max-open 99); rc=$?
expect_rc 0 $rc "new --write --base"
[[ -f "$MP/.orchestra/wt/$(mt_id "$out")/side.txt" ]] && ok "--base: the worktree starts from that ref" || bad "--base content"
out=$(printf 'x' | mt $ORCH handoff new --title "bad base" --write --base no-such-ref --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "an unknown --base fails" || bad "unknown base accepted"

# something at the task's worktree path must really be that worktree: inside a plain folder git answers for the project
out=$(printf 'x' | mt $ORCH handoff offer --title "plain folder" --write --max-offers 99); PF=$(mt_id "$out")
mkdir -p "$MP/.orchestra/wt/$PF"
out=$(mt $ORCH handoff take "$PF" --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a plain folder at the worktree path is refused" || bad "a plain folder taken for a worktree"
contains "$out" "is not a working git worktree" "the refusal says what is wrong with the folder"
contains "$(mt $ORCH handoff list)" "$PF *OFFERED" "the task stays in the pool after that refusal"
rmdir "$MP/.orchestra/wt/$PF"
out=$(mt $ORCH handoff take "$PF" --max-open 99); expect_rc 0 $? "taken once the plain folder is gone"
[[ "$(git -C "$MP/.orchestra/wt/$PF" rev-parse --show-toplevel)" != "$(git -C "$MP" rev-parse --show-toplevel)" ]] && ok "then it is a worktree of its own" || bad "still the project's tree"
out=$(printf 'x' | mt $ORCH handoff offer --title "wrong branch" --write --max-offers 99); WB=$(mt_id "$out")
git -C "$MP" worktree add -q -b "wrong-$WB" "$MP/.orchestra/wt/$WB" HEAD
out=$(mt $ORCH handoff take "$WB" --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a worktree on another branch is refused" || bad "a worktree on another branch was accepted"
contains "$out" "is on branch wrong-$WB" "the refusal names the branch it found"
git -C "$MP" worktree remove --force "$MP/.orchestra/wt/$WB"
out=$($ORCH worktree add feat-x); contains "$out" "orch/feat-x" "orch worktree add on an existing worktree reports its branch"
mkdir -p "$T/proj.wt/plain-x"
out=$($ORCH worktree add plain-x 2>&1); rc=$?
[[ $rc -ne 0 ]] && contains "$out" "is not a working git worktree" "orch worktree add refuses a plain folder too" || bad "orch worktree add took a plain folder: $out"
rmdir "$T/proj.wt/plain-x"

# a failure after the worktree was made leaves it on record: a later take reuses it, close can remove it
[[ -e "$MP/.agents" ]] && mv "$MP/.agents" "$MP/.agents.saved"
printf 'x' > "$MP/.agents"                 # the Antigravity rule can't be written now
out=$(printf 'x' | mt $ORCH handoff offer --title "fails after the worktree" --write --max-offers 99); FA=$(mt_id "$out")
out=$(mt $ORCH handoff take "$FA" --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a take fails when the rule can't be written" || bad "the take went through"
contains "$(mt $ORCH handoff list)" "$FA *OFFERED" "after the failure the task is back in the pool"
[[ "$(mt_meta "$FA" branch)" == "ag/$(tr 'A-Z' 'a-z' <<<"$FA")" && -d "$MP/.orchestra/wt/$FA" ]] && ok "the worktree it left stays on record" || bad "unrecorded worktree: $(mt_meta "$FA" branch)"
printf 'x' | mt $ORCH handoff new --title "fails, direct" --write --max-open 99 >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "new fails when the rule can't be written" || bad "new went through"
FN=$(basename "$(ls -d "$MP"/.orchestra/handoffs/AG-* | sort | tail -1)")
contains "$(mt_meta "$FN" manual_note)" "close $FN --remove-worktree" "a failed new says how to remove the worktree it left"
out=$(mt $ORCH handoff close "$FN" --remove-worktree); contains "$out" "worktree removed" "close removes the worktree a failed new left"
[[ -d "$MP/.orchestra/wt/$FN" ]] && bad "the failed task's worktree is still there" || ok "the failed task's worktree is gone"
rm -f "$MP/.agents"; [[ -e "$MP/.agents.saved" ]] && mv "$MP/.agents.saved" "$MP/.agents"
out=$(mt $ORCH handoff take "$FA" --max-open 99); expect_rc 0 $? "a later take reuses the worktree"
contains "$out" "It works in: .orchestra/wt/$FA" "the card of the retaken task says where it works"

# close --remove-worktree is the normal end of a writing task
mt $ORCH handoff done "$OW" --note "reviewed" >/dev/null
out=$(mt $ORCH handoff close "$OW" --remove-worktree --force); contains "$out" "worktree removed" "close --remove-worktree removes a writing task's worktree"
[[ -d "$MP/.orchestra/wt/$OW" ]] && bad "the worktree is still there" || ok "the nested worktree is gone"
git -C "$MP" worktree list | grep -q "wt/$OW" && bad "git still lists it" || ok "git no longer lists it"
out=$(mt $ORCH handoff close "$R1" --remove-worktree); contains "$out" "nothing to remove" "close --remove-worktree on a read-only task says there is nothing to remove"

# an old meta with no write field made no promise: it counts as writing and gets a nested worktree at the take
mt_cancel_all
git -C "$MP" worktree prune
git -C "$MP" checkout -q -- f.txt
out=$(printf 'x' | mt $ORCH handoff offer --title "old offer" --max-offers 99); OO=$(mt_id "$out")
$PY - "$(native "$MP/.orchestra/handoffs/$OO/meta.json")" <<'EOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8")); m.pop("write", None); m.update(worktree=True, base="HEAD"); json.dump(m, open(p, "w", encoding="utf-8"))
EOF
contains "$(mt $ORCH handoff show "$OO")" "(changes files, in its own worktree)" "an old offered task is shown as changing files"
out=$(mt $ORCH handoff take "$OO" --max-open 99); expect_rc 0 $? "an old offered task is taken"
contains "$out" "It works in: .orchestra/wt/$OO" "it gets a nested worktree"
[[ -d "$MP/.orchestra/wt/$OO" && "$(mt_meta "$OO" branch)" != "None" ]] && ok "worktree and branch exist for it" || bad "an old offer got no worktree"
mt $ORCH handoff cancel "$OO" >/dev/null

# a task taken by an older version keeps working: its worktree next to the project, from a hand-edited meta
out=$(printf 'x' | mt $ORCH handoff new --title "taken long ago" --max-open 99); OT=$(mt_id "$out")
OTW="$T/mt-proj.wt/$OT"
git -C "$MP" worktree add -q -b "ag/old-$OT" "$OTW" || die "cannot create the old-task worktree"
mkdir -p "$OTW/.orchestra/handoffs/$OT"; cp "$MP/.orchestra/handoffs/$OT/TASK.md" "$OTW/.orchestra/handoffs/$OT/TASK.md"
rm -f "$MP/.orchestra/handoffs/$OT/RESULT.md"
$PY - "$(native "$MP/.orchestra/handoffs/$OT/meta.json")" "$(native "$OTW")" "$OT" <<'EOF'
import json, sys, time
p, wt, hid = sys.argv[1:4]
m = json.load(open(p, encoding="utf-8"))
m.pop("write", None)
m.update(worktree=True, base="HEAD", workdir=wt, branch="ag/old-" + hid, activity_baseline=time.time(),
         task_path=wt + "/.orchestra/handoffs/%s/TASK.md" % hid, result_path=wt + "/.orchestra/handoffs/%s/RESULT.md" % hid)
json.dump(m, open(p, "w", encoding="utf-8"))
EOF
out=$(mt $ORCH handoff show "$OT"); contains "$out" "Open in Antigravity: .*mt-proj.wt/$OT" "an older task: the card still says where its worktree is"
contains "$out" "Branch: ag/old-$OT" "an older task: the card names its branch"
lacks "$out" "It works in" "an older task: no nested-worktree line"
contains "$(mt $ORCH handoff list)" "$OT *WAITING" "an older task: listed, waiting"
sleep 2; echo "edit in the old worktree" >> "$OTW/f.txt"
contains "$(mt $ORCH handoff list)" "$OT *STARTED?" "an older task: the folder scan still shows STARTED?"
printf 'STATUS: DONE\nAGENT: Antigravity · Gemini 3.8 Flash\n## Summary\nold\n' > "$OTW/.orchestra/handoffs/$OT/RESULT.md"
out=$(mt $ORCH handoff check); contains "$out" "$OT finished: STATUS DONE" "an older task: its RESULT.md is still detected"
$PY - "$(native "$MP/.orchestra/handoffs/$OT/meta.json")" "$OT" <<'EOF' && ok "an older task: paths stay relative on disk after a save" || bad "an older task: meta paths"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["workdir"] == "../mt-proj.wt/" + sys.argv[2], m["workdir"]
EOF
mt $ORCH handoff done "$OT" --note "ok" >/dev/null
out=$(mt $ORCH handoff close "$OT" --remove-worktree --force); contains "$out" "worktree removed" "close --remove-worktree still removes an older task's worktree"
[[ -d "$OTW" ]] && bad "the old worktree is still there" || ok "the old worktree is gone"
git -C "$MP" worktree prune; git -C "$MP" branch -D "ag/old-$OT" >/dev/null 2>&1

# `orch worktree` for automated executors is untouched: it still lives in <project>.wt/
out=$(mt $ORCH worktree add mt-feat); contains "$out" "mt-proj.wt/mt-feat" "orch worktree still works, next to the project"
mt_cancel_all

# the nested worktree stays out of git status when .orchestra/ is ignored through .gitignore as well
MP2="$T/mt-proj2"; mkdir -p "$MP2" && git -C "$MP2" init -q && git -C "$MP2" config user.email t@t && git -C "$MP2" config user.name t \
  && printf '.orchestra/\n' > "$MP2/.gitignore" && echo hi > "$MP2/f.txt" && git -C "$MP2" add . && git -C "$MP2" -c commit.gpgsign=false commit -qm init || die "cannot create the second fixture"
out=$(printf 'x' | (cd "$MP2" && $ORCH handoff new --title "gitignore" --write --provider cursor --max-open 99)); rc=$?
expect_rc 0 $rc "a writing task in a project that ignores .orchestra/ through .gitignore"
: > "$MP2/.git/info/exclude"
[[ -z "$(git -C "$MP2" status --porcelain)" ]] && ok "ignored through .gitignore alone: git status is clean with the nested worktree" || bad "gitignore status: $(git -C "$MP2" status --porcelain)"

# --write needs a git repository; a read-only task works anywhere
NG="$T/mt-nogit"; mkdir -p "$NG"
ng() { (cd "$NG" && "$@"); }
out=$(printf 'x' | ng $ORCH handoff new --title "no git, read" --max-open 99); rc=$?
expect_rc 0 $rc "a read-only task outside git"
contains "$out" "In Antigravity, in the project folder:" "no git: the card is the same"
out=$(printf 'x' | ng $ORCH handoff new --title "no git, write" --write --max-open 99 2>&1); rc=$?
expect_rc 1 $rc "new --write outside git is refused"
contains "$out" "--write needs a git repository" "new --write outside git: a clear line"
out=$(printf 'x' | ng $ORCH handoff offer --title "no git, write offer" --write 2>&1); rc=$?
expect_rc 1 $rc "offer --write outside git is refused"
contains "$out" "give the task read-only" "offer --write outside git: says what to do"
out=$(printf 'x' | ng $ORCH handoff offer --title "no git, offered" --max-offers 99); NGO=$(mt_id "$out")
ng $ORCH handoff take "$NGO" --max-open 99 >/dev/null; expect_rc 0 $? "outside git: offer and take (read-only)"
[[ -f "$NG/.orchestra/handoffs/$NGO/TASK.md" && -f "$NG/.agents/rules/orchestra-task.md" ]] && ok "outside git: TASK.md and the rule are written" || bad "outside git: files missing"
[[ -e "$NG/.git" ]] && bad "orch created a repository" || ok "outside git: nothing creates a repository"
out=$(printf 'x' | ng $ORCH handoff offer --title "no git, old" --max-offers 99); NGW=$(mt_id "$out")
$PY - "$(native "$NG/.orchestra/handoffs/$NGW/meta.json")" <<'EOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8")); m.pop("write", None); json.dump(m, open(p, "w", encoding="utf-8"))
EOF
out=$(ng $ORCH handoff take "$NGW" --max-open 99); rc=$?
expect_rc 1 $rc "an old writing offer cannot be taken outside git"
contains "$out" "needs a git repository for its worktree" "and the line says why"
contains "$(ng $ORCH handoff list)" "$NGW *OFFERED" "it stays in the pool"
printf 'STATUS: DONE\nok\n' > "$NG/.orchestra/handoffs/$NGO/RESULT.md"
out=$(ng $ORCH handoff check); contains "$out" "$NGO finished: STATUS DONE" "outside git: completion detected"
out=$(ng $ORCH footprint); contains "$out" ".agents/rules/orchestra-task.md" "footprint names the general Antigravity rule"
contains "$out" "git worktree prune" "footprint tells what to do about worktree entries if .orchestra/ is deleted by hand"
grep -q "orchestra-task.md" "$PLUGIN/../../uninstall.sh" && ok "uninstall.sh names the rule" || bad "uninstall.sh does not name the rule"
grep -q "git worktree prune" "$PLUGIN/../../uninstall.sh" && ok "uninstall.sh mentions git worktree prune" || bad "uninstall.sh: prune"
grep -q "orchestra-task.md" "$PLUGIN/README.md" && ok "README names the rule among what the plugin leaves behind" || bad "README: rule missing"
grep -q "effort High --worktree\|always \`--worktree\`" "$PLUGIN/skills/orchestrate/reference/manual.md" && bad "manual.md still offers --worktree" || ok "manual.md no longer offers --worktree"
grep -q "\[--worktree\]" "$PLUGIN/registry/providers.yaml" && bad "the registry still offers --worktree" || ok "the registry no longer offers --worktree"
cd "$REPO" || die "back from the manual-task fixtures"

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
$PY -B - "$PLUGIN/bin/orch" <<'EOF' && ok "status line: money joins its own account, even when two accounts display alike" || bad "money attached by the display name"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
m.native_account = lambda where: "claude"
m.scope_name = lambda s: "Same@work"
m.fmt_tok = str
m.session_tokens = lambda sid, path, native: {"a@work": {"input": 1, "output": 10}, "B@Work": {"input": 2, "output": 20}}
spend = [("a@work", "Same@work", "est. $1"), ("b@work", "Same@work", "est. $9"), ("c@work", "Same@work", "est. $2")]
out = m.session_status_part("s", None, None, spend)
assert "Same@work 1/10 (est. $1)" in out and "Same@work 2/20 (est. $9)" in out, out
assert out.index("2/20") < out.index("Same@work (est. $2)"), out
EOF
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
out=$($ORCH budget); grep -q "SURPLUS\|TIGHT" <<<"$out" && bad "projected too early: $out" || ok "no projection in the window's first hour"
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
# reserve and the pace of all sessions: snap USED [BASE_USED MINUTES_AGO] — window resets in 2 h (SNAP_LEFT minutes),
# optional sample
snap() { $PY - "$(native "$ORCH_HOME/claude_usage.json")" "$@" <<'EOF'
import datetime as dt, json, os, sys
p, used = sys.argv[1], float(sys.argv[2])
t = dt.datetime.now().astimezone()
reset = (t + dt.timedelta(minutes=int(os.environ.get("SNAP_LEFT", "120")))).isoformat(timespec="seconds")
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
# early in the window a projection is too thin to act on: a five-hour projection needs 60 minutes of the window
# behind it, the recent pace a base sample at least 30 minutes old; a used share at the reserve is TIGHT at once
SNAP_LEFT=270 snap 5 0 15
out=$($ORCH budget); contains "$out" "5-hour window 5% used" "early window: the line is shown"
grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "5% used, a 15-min burst, 30 min in: $out" || ok "30 min in: a short burst is not projected over the window"
SNAP_LEFT=241 snap 40
out=$($ORCH budget); grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "59 min in: $out" || ok "59 min in: the window average is not yet a projection"
SNAP_LEFT=239 snap 40
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (window average)" "61 min in: the window average projects, and 40% is tight"
SNAP_LEFT=255 snap 1
out=$($ORCH budget); grep -q "TIGHT\|SURPLUS" <<<"$out" && bad "45 min in, 1% used: $out" || ok "45 min in: no surplus from a window too young to project"
SNAP_LEFT=225 snap 1
out=$($ORCH budget); contains "$out" "SURPLUS: at the current pace (window average)" "75 min in: the same light use is a surplus"
SNAP_LEFT=210 snap 20 5 15
out=$($ORCH budget); grep -q "TIGHT" <<<"$out" && bad "a 15-min sample at 90 min in: $out" || ok "90 min in: a base sample under 30 min old gives no recent pace"
SNAP_LEFT=210 snap 40 10 40
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (last 4[0-9] min, all sessions) it reaches the reserve" "90 min in: a squeeze measured over 40 min is tight"
SNAP_LEFT=290 snap 95
out=$($ORCH budget); contains "$out" "TIGHT: at the current pace (used share) the reserve is already reached" "10 min in: a used share over the reserve is tight at once"
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

# Codex's internal auto-review step writes turn_context events too: its model is not the one the operator works with
cat > "$T/gen_rollout_ar.py" <<'EOF'
import datetime as dt, json, sys
path = sys.argv[1]; models = sys.argv[2:]          # the turn_context models, in file order
now = dt.datetime.now(dt.timezone.utc)
def iso(t): return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")
lines = [json.dumps({"timestamp": iso(now - dt.timedelta(minutes=10 - i)), "type": "turn_context",
                     "payload": {"model": m, "effort": "medium"}}) for i, m in enumerate(models)]
lines.append(json.dumps({"timestamp": iso(now), "type": "event_msg", "payload": {"type": "token_count",
    "rate_limits": {"limit_id": "codex",
        "primary": {"used_percent": 30.0, "window_minutes": 300, "resets_at": int((now + dt.timedelta(hours=2)).timestamp())},
        "secondary": {"used_percent": 20.0, "window_minutes": 10080, "resets_at": int((now + dt.timedelta(days=7)).timestamp())},
        "plan_type": "plus"}}}))
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
EOF
ar_home() { rm -rf "$T/$1"; mkdir -p "$T/$1/sessions/2026/11/02"; export CODEX_HOME; CODEX_HOME="$(native "$T/$1")"; }
ar_roll() { local h=$1; shift; $PY "$(native "$T/gen_rollout_ar.py")" "$(native "$T/$h/sessions/2026/11/02/rollout-0001.jsonl")" "$@"; }
ar_home cxar1; ar_roll cxar1 codex-auto-review
out=$(cx_status); contains "$out" "^Codex · 5h 30%" "codex: only the auto-review model in the rollout → just Codex"
lacks "$out" "auto-review" "codex: the auto-review model is not shown"
ar_home cxar2; ar_roll cxar2 gpt-6.1-sol codex-auto-review
out=$(cx_status); contains "$out" "GPT-6.1 Sol · 5h 30%" "codex: an auto-review turn after the real one keeps the real model"
lacks "$out" "auto-review" "codex: nothing of the auto-review turn shows after a real model"
ar_home cxar3; ar_roll cxar3 codex-auto-review my-custom-model-7b codex-auto-review
out=$(cx_status); contains "$out" "my-custom-model-7b · 5h 30%" "codex: the last real model is shown between auto-review turns"
ar_home cxar4; ar_roll cxar4 gpt-6.1-sol codex-auto-review gpt-6.1-terra
out=$(cx_status); contains "$out" "GPT-6.1 Terra · 5h 30%" "codex: a real model after an auto-review turn is shown"
# an entry saved by an older version holds the internal model: it is no model, on show and on every re-scan
rm -f "$ORCH_HOME/codex_usage.json"          # the seeding below touches every entry of the cache
ar_home cxar5; ar_roll cxar5 codex-auto-review
cx_status >/dev/null
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF' && ok "codex: stored entry set to the auto-review model" || bad "codex: could not seed the stored entry"
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["model"] = "codex-auto-review"
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "^Codex · 5h 30%" "codex: a stored auto-review model is shown as no model"
lacks "$out" "auto-review" "codex: nothing of the stored auto-review model shows"
$PY - "$(native "$ORCH_HOME/codex_usage.json")" <<'EOF'
import datetime as dt, json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k, v in d.items():
    if isinstance(v, dict) and "updated" in v:
        v["updated"] = (dt.datetime.now().astimezone() - dt.timedelta(minutes=5)).isoformat(timespec="seconds")
json.dump(d, open(p, "w", encoding="utf-8"))
EOF
out=$(cx_status); contains "$out" "^Codex · 5h 30%" "codex: a re-scan with no real model leaves no model"
lacks "$(cat "$ORCH_HOME/codex_usage.json")" "auto-review" "codex: a re-scan drops the stored auto-review model"

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

# a few minutes into a window its average is no projection: it needs 60 minutes of the window behind it, while a used
# share at the reserve is TIGHT at once
cx_early() {     # NAME USED_5H MINUTES_INTO_THE_WINDOW
  rm -rf "$T/$1"; mkdir -p "$T/$1/sessions/2026/11/02"
  export CODEX_HOME; CODEX_HOME="$(native "$T/$1")"
  $PY "$(native "$T/gen_rollout.py")" "$(native "$T/$1/sessions/2026/11/02/rollout-0001.jsonl")" "$2"       "$($PY -c "print((300 - $3) / 60)")" 2 168
}
cx_early cxe1 15 5
out=$($ORCH status); contains "$out" "Codex subscription: 5-hour window 15% used" "codex: 15% used 5 min after a reset is in the line"
lacks "$out" "TIGHT" "codex: 15% used 5 min after a reset is not TIGHT"
out=$(cx_status); contains "$out" "Codex · 5h 15%" "codex: 15% used 5 min after a reset in the compact text"
lacks "$out" "tight" "codex: 15% used 5 min after a reset has no mode in the compact text"
cx_early cxe2 50 55
out=$($ORCH status); lacks "$out" "TIGHT" "codex: 50% used 55 min in is still too early to project"
cx_early cxe3 50 65
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: 50% used 65 min in projects past the reserve → TIGHT"
out=$(cx_status); contains "$out" "tight: 5h" "codex: the projection past the reserve in the compact text"
cx_early cxe4 80 120
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: 80% used two hours in → TIGHT"
out=$(cx_status); contains "$out" "tight: 5h" "codex: 80% used two hours in, compact text"
cx_early cxe5 95 10
out=$($ORCH status); contains "$out" "TIGHT: treat Codex as low" "codex: 95% used 10 min in → TIGHT at once"
out=$(cx_status); contains "$out" "tight: 5h" "codex: 95% used 10 min in, compact text"

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
out=$(cx_status); grep -q "Codex ·" <<<"$out" && bad "codex key profile: limits in the status line: $out" || ok "codex key profile: no limits in the status line"
contains "$out" "Codex@keyed (est. \$0.00/\$10)" "codex key profile: its estimate and limit stand in the status line, with no account part"
lacks "$out" "account" "codex key profile: no account figure without a balance API"
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
contains "$out" "^Session in/out: Codex 400/40 · DeepSeek (est. \$3.0[0-9]/\$10, account \$15.09, 3h ago)\$" \
  "status line: a scope with money and no tokens follows the counters"
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
unset -f sl_spend

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

echo "── project rules"
fb "$FA" profile rules --set "PROJECT-RULE" >/dev/null
out=$(fb "$FA" profile show); contains "$out" "Project rules: PROJECT-RULE" "project rules: show"
lacks "$out" "not in force while it is exhausted" "project rules: no warning before fallback"
out=$(fb "$FA" status); contains "$out" "Project rules: PROJECT-RULE" "project rules: status"
out=$(fb_hook "$FA" session-start); contains "$out" "Project rules: PROJECT-RULE" "project rules: session start"
out=$(fb "$FA" profile show --json); contains "$out" '"rules": \[' "project rules: JSON list"
contains "$out" '"text": "PROJECT-RULE"' "project rules: JSON text"
out=$(fb "$FA" profile list); contains "$out" "Project rules:" "project rules: list section"
mkdir -p "$T/rules/inner" "$T/rules-sibling"
fb "$FA" profile rules --set "OUTER-RULE" --path "$(native "$T/rules")" >/dev/null
fb "$FA" profile rules --set "INNER-RULE" --path "$(native "$T/rules/inner")" >/dev/null
out=$(fb "$(native "$T/rules/inner")" profile rules)
contains "$out" 'Project rules (' "project rules: parent named"
[[ "$out" == *OUTER-RULE*INNER-RULE* ]] && ok "project rules: parent first" || bad "project rules: parent order"
out=$(fb "$(native "$T/rules-sibling")" profile rules); lacks "$out" "OUTER-RULE" "project rules: sibling excluded"
fb "$REPO" profile rules --set "WORKTREE-RULE" >/dev/null
out=$(fb "$(native "$T/proj.wt/feat-x")" profile show); contains "$out" "WORKTREE-RULE" "project rules: worktree"
fb "$REPO" profile rules --clear >/dev/null
fb "$FA" profile rules --clear --path "$(native "$T/rules")" >/dev/null
fb "$FA" profile rules --set "" --path "$(native "$T/rules/inner")" >/dev/null
out=$(fb "$FA" profile rules --set "   " --path "$(native "$T/rules/inner")"); contains "$out" "No project rules to clear" "project rules: empty and blank text both clear"
out=$(fb "$FA" profile rules --clear --path "$(native "$T/rules/inner")"); expect_rc 0 $? "project rules: clear missing"
contains "$out" "No project rules to clear" "project rules: clear missing says so"
out=$(fb "$FA" profile rules --set x --clear 2>&1); [[ $? -ne 0 ]] && ok "project rules: exclusive options" || bad "project rules: exclusive options accepted"
cp "$FDIR/profiles.json" "$FDIR/rules.good"
printf '{"project_rules": []}' > "$FDIR/profiles.json"
out=$(fb "$FA" profile rules 2>&1); [[ $? -ne 0 ]] && contains "$out" "project_rules" "project rules: invalid object refused" || bad "project rules: invalid object accepted"
cp "$FDIR/rules.good" "$FDIR/profiles.json"

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
contains "$out" "Project rules: PROJECT-RULE" "project rules: survives fallback"
contains "$out" "rules of client are not in force while it is exhausted" "project rules: fallback warns"
lacks "$out" "CLIENT-RULES" "at the limit: the exhausted profile's rules are gone"
lacks "$out" "prefer for: tests" "at the limit: the exhausted profile's prefer_for is gone"
contains "$out" "prefer for: docs" "at the limit: the fallback's prefer_for"
out=$(fb "$FA" status)
contains "$out" "personal (fallback: client is at its limit)" "at the limit: status shows it too"
fb "$FA" profile rules --clear >/dev/null
out=$(fb "$FA" profile list); lacks "$out" "Project rules:" "project rules: empty list has no section"
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
fb "$FA" quota set deepseek@client/deepseek-v4-pro busy >/dev/null
out=$(fb "$FA" profile show); contains "$out" "client (project)" "availability: a busy model is no reason to switch"
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

# SURPLUS follows the active profile: a key with `prefer for` and budget goes first, even in a SURPLUS; on its
# fallback the global rule returns, and the status line says so
SXA="$(native "$T/fb-sx")"; SXB="$(native "$T/fb-sz")"; SXC="$(native "$T/fb-none")"
mkdir -p "$T/fb-sx" "$T/fb-sz" "$T/fb-none"
fb "$FA" profile set deepseek sy --key FB_KEY_PERS --rules "SY-RULES" >/dev/null          # the fallback: no prefer_for
fb "$FA" profile set deepseek sx --key FB_KEY_CLIENT --prefer-for tests,docs --fallback sy >/dev/null
fb "$FA" profile set deepseek sz --key FB_KEY_PLAIN --rules "SZ-RULES" >/dev/null         # a key, no prefer_for
fb "$FA" profile use deepseek sx --path "$SXA" >/dev/null
fb "$FA" profile use deepseek sz --path "$SXB" >/dev/null
for l in sx sy; do
  fb "$SXA" spend limit deepseek@$l 5 >/dev/null; fb "$SXA" spend mode deepseek@$l stop >/dev/null
  fb "$SXA" spend reset deepseek@$l >/dev/null
done
fb "$SXA" budget set --used 20 --resets +3h --week 50 >/dev/null
fb_sl() { printf '{"session_id":"s-sx","model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"%s"}}' "$1" | ORCH_HOME="$FH" $ORCH statusline; }
SX_ON="except the task types preferred for DeepSeek@sx (tests, docs)"
SX_TODAY="executors (DeepSeek, API-key profiles); orch guide budget."
out=$(fb_sl "$SXA")
contains "$out" "Claude Opus 5.5 · 5h 20% → .* · week 50% .*surplus" "prefer for with budget: the status line says surplus"
lacks "$out" "Claude first" "prefer for with budget: no 'Claude first' on the status line"
out=$(fb "$SXA" status)
contains "$out" "SURPLUS: at the current pace" "prefer for with budget: orch status keeps the SURPLUS word"
contains "$out" "give subtasks to Claude subagents rather than to API-billed executors (DeepSeek, API-key profiles), $SX_ON; orch guide budget." \
  "prefer for with budget: orch status names the exception"
out=$(fb_hook "$SXA" user-prompt)
contains "$out" "💡 Claude subscription: .*SURPLUS: .*$SX_ON" "prefer for with budget: the budget event names the exception"
# another project, no such profile (a key without prefer_for; the built-in default): today's text
for d in "$SXB" "$SXC"; do
  out=$(fb_sl "$d"); contains "$out" "week 50% .*surplus: Claude first" "no prefer for in $(basename "$d"): the status line is as before"
  out=$(fb "$d" status); contains "$out" "$SX_TODAY" "no prefer for in $(basename "$d"): orch status is as before"
  lacks "$out" "except the task types" "no prefer for in $(basename "$d"): no exception in orch status"
done
# a session with tokens: the fallback note joins its line; without them it stands on a line of its own
fb_sl_tok() { printf '{"session_id":"s-sx-tok","model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"%s"}}' "$1" | ORCH_HOME="$FH" $ORCH statusline; }
out=$(fb_sl "$SXA"); lacks "$out" "(fallback:" "a key with budget: no fallback note on the status line"
# the key hits its limit: the profile moves to its fallback
fb_spent deepseek@sx 6
out=$(fb_sl "$SXA")
contains "$out" "week 50% .*surplus: Claude first" "on the fallback: the status line has today's surplus text"
contains "$out" "^DeepSeek@sy (fallback: DeepSeek@sx at its limit; est. \$0.00/\$5)\$" "on the fallback: the note and the fallback's own estimate stand on a line of their own with no session tokens"
lacks "$out" "Session in/out" "on the fallback: no session line without tokens"
out=$(fb "$SXA" status)
contains "$out" "$SX_TODAY" "on the fallback: orch status has today's text"
lacks "$out" "except the task types" "on the fallback: the exception is gone with the key's prefer_for"
$PY - "$FDIR/usage.jsonl" <<'EOF'
import datetime as dt, json, sys
rec = {"kind": "run", "provider": "codex", "label": "codex", "model": "gpt-6.1-terra", "billing": "subscription",
       "session": "s-sx-tok", "project": "fb-project",
       "usage": {"input_tokens": 400, "cached_input_tokens": 0, "output_tokens": 40},
       "ts": dt.datetime.now().astimezone().isoformat(timespec="microseconds")}
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps(rec) + "\n")
EOF
out=$(fb_sl_tok "$SXA")
contains "$out" "^Session in/out: .* · DeepSeek@sy (fallback: DeepSeek@sx at its limit; est. \$0.00/\$5)\$" "on the fallback: the note and the estimate join the session in/out line"
grep -q "^DeepSeek@sy" <<<"$out" && bad "on the fallback: with session tokens the note has a line of its own" \
  || ok "on the fallback: with session tokens it has no line of its own"
# the fallback's own spend follows the note, at any level
fb_spent deepseek@sy 4.5
out=$(fb_sl "$SXA")
contains "$out" "DeepSeek@sy (fallback: DeepSeek@sx at its limit; est. \$4.50/\$5)" "on the fallback: its own estimate follows the note"
# and the account figure of the fallback's key, not the exhausted one's
$PY - "$FDIR/balances.json" <<'EOF'
import datetime as dt, json, sys
at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
json.dump({"deepseek@sx": {"amount": 1.0, "currency": "USD", "at": at},
           "deepseek@sy": {"amount": 9.75, "currency": "USD", "at": at}}, open(sys.argv[1], "w", encoding="utf-8"))
EOF
out=$(fb_sl "$SXA")
contains "$out" "DeepSeek@sy (fallback: DeepSeek@sx at its limit; est. \$4.50/\$5, account \$9.75)" "on the fallback: the account figure is the fallback's own"
lacks "$out" "account \$1.00" "on the fallback: the exhausted profile's figure is not shown"
# the fallback profile's own tokens in this session carry the note and the money in the same parentheses
$PY - "$FDIR/usage.jsonl" <<'EOF2'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({"kind": "run", "session": "s-sx-tok", "provider": "deepseek", "label": "deepseek@sy", "model": "m",
                        "usage": {"input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 10}}) + "\n")
EOF2
out=$(fb_sl_tok "$SXA")
contains "$out" " · DeepSeek@sy 100/10 (fallback: DeepSeek@sx at its limit; est. \$4.5[0-9]/\$5, account \$9.75)\$" \
  "on the fallback: the tokens, the note, the estimate and the account figure share one pair of parentheses"
rm -f "$FDIR/balances.json"
# the cause words of the other causes
fb "$SXA" spend limit deepseek@sx 50 >/dev/null
out=$(fb_sl "$SXA"); lacks "$out" "(fallback:" "the key has budget again: the note is gone"
contains "$out" "week 50% .*surplus\$" "the key has budget again: surplus without 'Claude first'"
fb "$SXA" quota set deepseek@sx exhausted >/dev/null
out=$(fb_sl "$SXA"); contains "$out" "DeepSeek@sy (fallback: DeepSeek@sx exhausted;" "an exhausted key: the note says so"
fb "$SXA" quota set deepseek@sx disabled >/dev/null
out=$(fb_sl "$SXA"); contains "$out" "DeepSeek@sy (fallback: DeepSeek@sx disabled;" "a disabled key: the note says so"
fb "$SXA" quota clear deepseek@sx >/dev/null
out=$(fb_sl "$SXA"); lacks "$out" "(fallback:" "the entry cleared: the note is gone"
out=$(fb "$SXA" status); contains "$out" "$SX_ON" "the entry cleared: orch status names the exception again"
out=$(fb_sl "$SXB"); lacks "$out" "(fallback:" "a profile without a fallback never shows a note"

echo "── provider account balances (a fake DeepSeek balance server on localhost)"
BDIR="$T/bal-home"; BH="$(native "$BDIR")"
BA="$(native "$T/bal-a")"; BB="$(native "$T/bal-b")"; BC="$(native "$T/bal-c")"
BD="$(native "$T/bal-d")"; BE="$(native "$T/bal-e")"; BF="$(native "$T/bal-f")"
BANS="$(native "$T/bal.answers")"; BLOG="$(native "$T/bal.log")"; BPORT="$T/bal.port"
mkdir -p "$BDIR" "$T/bal-a" "$T/bal-b" "$T/bal-c" "$T/bal-d" "$T/bal-e" "$T/bal-f"
printf 'DEEPSEEK_API_KEY_CLIENT=sk-fake-client\nDEEPSEEK_API_KEY_WORK=sk-fake-work\nDEEPSEEK_API_KEY_BAD=sk-fake-bad\nCODEX_API_KEY_WORK=sk-fake-codex\n' > "$BDIR/secrets.env"
printf '{"usd_per_1m_tokens": {"deepseek-v4-pro": {"input": 1.0, "cache_read": 0.0, "output": 0.0}}}' > "$BDIR/prices.json"
# the server answers by the key it receives; a missing key is a 401. answers: {key: {total, currency, status, raw, sleep}}
cat > "$T/bal_server.py" <<'EOF' || die "cannot write the fake balance server"
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port_file, answers_file, log_file = sys.argv[1:4]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/quit":
            self.send_response(200); self.end_headers(); self.wfile.write(b"bye")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        key = self.headers.get("Authorization", "").replace("Bearer ", "", 1)
        with open(log_file, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (self.path, key))
        try:
            answers = json.load(open(answers_file, encoding="utf-8"))
        except (OSError, ValueError):
            answers = {}
        a = answers.get(key)
        if self.path != "/user/balance" or a is None:
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error":"invalid key"}')
            return
        time.sleep(a.get("sleep", 0))
        body = a["raw"] if "raw" in a else json.dumps({"is_available": True, "balance_infos": [
            {"currency": a.get("currency", "USD"), "total_balance": a["total"],
             "granted_balance": "0.00", "topped_up_balance": a["total"]}]})
        self.send_response(a.get("status", 200))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_address[1]))
timer = threading.Timer(900, lambda: os._exit(0)); timer.daemon = True; timer.start()   # never outlives a forgotten run
server.serve_forever()
EOF
bal_answers() { printf '%s' "$1" > "$T/bal.answers"; }   # JSON, see above
bal_start() {
  rm -f "$BPORT"
  $PY "$(native "$T/bal_server.py")" "$(native "$BPORT")" "$BANS" "$BLOG" >/dev/null 2>&1 &
  BSRV=$!
  for _ in $(seq 1 60); do [[ -s "$BPORT" ]] && break; sleep 0.25; done
  [[ -s "$BPORT" ]] || { bad "the fake balance server did not start"; return 1; }
  BURL="http://127.0.0.1:$(cat "$BPORT")/user/balance"
}
bal_stop() {
  $PY -c 'import sys, urllib.request; urllib.request.urlopen("http://127.0.0.1:%s/quit" % sys.argv[1], timeout=5).read()' "$(cat "$BPORT")" >/dev/null 2>&1
  wait "$BSRV" 2>/dev/null
}
bal() { ORCH_HOME="$BH" ORCH_PROJECT_DIR="${BWHERE:-$BA}" ORCH_BALANCE="${BAL_MODE:-on}" ORCH_DEEPSEEK_BALANCE_URL="${BURL:-}" NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 $ORCH "$@"; }
bal_count() { echo $(( $(wc -l < "$T/bal.log") )); }          # requests the server has seen
bal_ms() { $PY -c 'import time; print(int(time.time() * 1000))'; }
bal_cache_get() { $PY - "$BH/balances.json" "$1" "$2" <<'EOF'
import json, sys
e = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], {})
v = e.get(sys.argv[3])
print(v.get("message") if isinstance(v, dict) else "" if v is None else v)
EOF
}
bal_age() { $PY - "$BH/balances.json" "$1" "$2" <<'EOF'
import datetime as dt, json, sys
path, scope, secs = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(path, encoding="utf-8"))
t = (dt.datetime.now().astimezone() - dt.timedelta(seconds=secs)).isoformat(timespec="seconds")
d[scope]["at"] = t
if "error" in d[scope]:
    d[scope]["error"]["at"] = t
json.dump(d, open(path, "w", encoding="utf-8"))
EOF
}
: > "$T/bal.log"
bal_answers '{"sk-fake-client": {"total": "8.42"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal_start || die "no fake balance server"
bal profile set deepseek client --key DEEPSEEK_API_KEY_CLIENT --default >/dev/null
bal profile set deepseek work --key DEEPSEEK_API_KEY_WORK >/dev/null
bal profile set deepseek bad --key DEEPSEEK_API_KEY_BAD >/dev/null
bal profile set codex work --key CODEX_API_KEY_WORK >/dev/null
bal profile use deepseek work --path "$BB" >/dev/null
bal profile use deepseek bad --path "$BC" >/dev/null

# nothing is fetched without being asked: spend and status are quiet while ORCH_BALANCE is off
out=$(BAL_MODE=off bal balance); contains "$out" "Balance checks are off" "ORCH_BALANCE=off: orch balance fetches nothing"
BAL_MODE=off bal status >/dev/null; BAL_MODE=off bal spend >/dev/null
[[ $(bal_count) -eq 0 ]] && ok "ORCH_BALANCE=off: status and spend make no request" || bad "a request was made with ORCH_BALANCE=off"

# orch balance: every key profile, each with its own figure; a 401 names the variable; no API → says so
out=$(bal balance); rc=$?
expect_rc 1 $rc "orch balance exits 1 when a fetch failed"
contains "$out" "DeepSeek@client .*DEEPSEEK_API_KEY_CLIENT .*\$8.42" "balance: the client key's own amount"
contains "$out" "DeepSeek@work .*DEEPSEEK_API_KEY_WORK .*¥110.00" "balance: the work key's own amount, in the currency the provider reports"
contains "$out" "DeepSeek@bad .*rejected the key (HTTP 401): check DEEPSEEK_API_KEY_BAD" "balance: a 401 says the key was rejected and names the variable"
lacks "$out" "sk-fake" "balance: no key value in the output"
contains "$out" "Account balances: the provider's own figure for the account a key belongs to, shared by all its keys" "balance: the heading says it is the account's balance"
contains "$out" "our estimate of orch's own runs" "balance: the heading says orch spend is an estimate of orch's runs"
grep -qE "^scope +key variable +account balance +checked" <<<"$out" && ok "balance: the column is called account balance" || bad "balance: column header: $out"
lacks "$out" "API key balances" "balance: no heading that calls the figure a key's"
contains "$out" "Codex@work .*no balance API: see \`orch spend\`" "balance: a provider without a balance API says so"
# the built-in key and a profile holding the same variable are one account: one row, one request
bal profile set deepseek main --key DEEPSEEK_API_KEY >/dev/null
out=$(DEEPSEEK_API_KEY=sk-fake-main bal balance)
contains "$out" "DeepSeek@main .*DEEPSEEK_API_KEY " "balance: a profile on the standard variable has its row"
grep -qE '^DeepSeek +DEEPSEEK_API_KEY ' <<<"$out" && bad "balance: the same key listed twice: $out" || ok "balance: one row for one key"
bal profile rm deepseek main >/dev/null
out=$(DEEPSEEK_API_KEY=sk-fake-main bal balance)
contains "$out" "DeepSeek  *DEEPSEEK_API_KEY " "balance: the built-in key is listed when no profile holds it"
out=$(bal balance)
grep -q "sk-fake-codex" "$T/bal.log" && bad "a key of a provider without a balance API was sent somewhere" || ok "balance: the key of a provider without a balance API is never used"
grep -q "/user/balance sk-fake-client" "$T/bal.log" && grep -q "/user/balance sk-fake-work" "$T/bal.log" \
  && ok "balance: each scope asks with its own key" || bad "the server did not see both keys"
[[ "$(bal_cache_get deepseek@client amount)" == "8.42" && "$(bal_cache_get deepseek@work amount)" == "110.0" ]] \
  && ok "the cache holds a separate amount per scope" || bad "the cache amounts are wrong"
[[ "$(bal_cache_get deepseek@work currency)" == "CNY" ]] && ok "the cache keeps the provider's currency (no conversion)" || bad "currency not kept"
contains "$(bal_cache_get deepseek@bad error)" "DEEPSEEK_API_KEY_BAD" "the cache holds the last error of a scope with no figure"
[[ -z "$(bal_cache_get deepseek@bad amount)" ]] && ok "a failed first fetch stores no amount" || bad "an amount appeared for a rejected key"
out=$(bal balance deepseek@client --json); rc=$?
$PY -c 'import json, sys; d = json.loads(sys.argv[1]); assert len(d) == 1 and d[0]["scope"] == "deepseek@client" and d[0]["amount"] == 8.42 and d[0]["supported"]' "$out" \
  && ok "balance --json is valid and carries the amount" || bad "balance --json: $out"
lacks "$out" "sk-fake" "balance --json holds no key"
out=$(bal balance --json 2>/dev/null)
$PY -c 'import json, sys; d = json.loads(sys.argv[1]); assert {r["scope"] for r in d} == {"deepseek@client", "deepseek@work", "deepseek@bad", "codex@work"}; assert [r for r in d if r["scope"] == "codex@work"][0]["note"].startswith("no balance API")' "$out" \
  && ok "balance --json lists every key profile" || bad "balance --json list: $out"
lacks "$out" "sk-fake" "balance --json (all scopes) holds no key"
out=$(bal balance nope@nope 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "an unknown scope is refused" || bad "unknown scope accepted"
out=$(ORCH_WORKER=run-x bal balance 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a worker may not run orch balance" || bad "balance ran inside a worker"

# the amount reaches status, spend show and the status line, per project
out=$(bal status); contains "$out" "DeepSeek@client .*account \$8.42" "status: the account balance of the project's scope"
contains "$out" "API keys (spend and limit: our estimate of orch's own runs; account: the provider's figure, for all keys of that account):" "status: the heading says where each number comes from"
contains "$out" "DeepSeek@client  *est. \$0.00 of \$10 (manual.*) · account \$8.42 (checked" "status: the estimate sits next to the account balance"
lacks "$out" "API key balance" "status: nothing calls the figure a key's balance"
BWHERE="$BB"; out=$(bal status); contains "$out" "DeepSeek@work .*account ¥110.00" "status: another project, another key, its own amount"; BWHERE=""
BWHERE="$BC"; out=$(bal status); contains "$out" "last fetch failed: DeepSeek rejected the key (HTTP 401): check DEEPSEEK_API_KEY_BAD" "status: a rejected key shows the failure and the variable"
lacks "$out" "sk-fake" "status holds no key"; BWHERE=""
out=$(bal spend)
contains "$out" "account" "spend show: an account column"
contains "$out" "\`spent\` is our estimate of orch's own runs" "spend show: the header says spent is an estimate of orch's runs"
contains "$out" "\`account\` is the provider's figure for the whole account.*which can include spending outside orch" "spend show: the header says account is the provider's figure and can include outside spending"
grep -qE "^scope +spent +limit +account " <<<"$out" && ok "spend show: the column is called account" || bad "spend show: column header: $out"
contains "$out" "DeepSeek@client .*\$8.42" "spend show: the account balance of the scope"
sl_bal() { printf '{"session_id":"s-bal","workspace":{"current_dir":"%s"}}' "${1:-$BA}" | ORCH_HOME="$BH" $ORCH statusline; }
out=$(sl_bal); contains "$out" "DeepSeek@client (est. \$0.00/\$10, account \$8.42)" "status line: estimate, limit and account figure for the active scope"
out=$(sl_bal "$BB"); contains "$out" "DeepSeek@work (est. \$0.00/\$10, account ¥110.00)" "status line: the other project shows its own key's account figure"
lacks "$(sl_bal)" "ago)" "status line: no age while the figure is fresh"
lacks "$(sl_bal)" "balance" "status line: the figure is called account, not balance"

# an active key scope the provider was never asked about: the status line shows our part only, orch status says so
bal profile set deepseek fresh --key DEEPSEEK_API_KEY_FRESH >/dev/null
bal profile use deepseek fresh --path "$BD" >/dev/null
out=$(sl_bal "$BD"); contains "$out" "^DeepSeek@fresh (est. \$0.00/\$10)\$" "status line: a scope with no balance fetched shows only our part"
BWHERE="$BD"; out=$(BAL_MODE=off bal status); BWHERE=""
contains "$out" "DeepSeek@fresh  *est. \$0.00 of \$10 (manual.*) · account balance not fetched yet" "status: a key scope with no balance still has its line"
# a provider with no balance API: our part, and orch status says so
bal profile use codex work --path "$BE" >/dev/null
out=$(sl_bal "$BE"); contains "$out" "^Codex@work (est. \$0.00/\$10) · DeepSeek@client (est. " "status line: a provider with no balance API shows only our part"
lacks "$out" "Codex@work (est. \$0.00/\$10, account" "status line: and no account figure follows it"
BWHERE="$BE"; out=$(BAL_MODE=off bal status); BWHERE=""
contains "$out" "Codex@work  *est. \$0.00 of \$10 (manual.*) · no balance API" "status: a provider with no balance API says so"
# two keys of one account: each scope shows the account's figure, the same one
printf 'DEEPSEEK_API_KEY_TWIN=sk-fake-twin\n' >> "$BDIR/secrets.env"
bal profile set deepseek twin --key DEEPSEEK_API_KEY_TWIN >/dev/null
bal profile use deepseek twin --path "$BF" >/dev/null
bal_answers '{"sk-fake-client": {"total": "8.42"}, "sk-fake-twin": {"total": "8.42"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal balance deepseek@twin >/dev/null
out=$(sl_bal "$BF"); contains "$out" "DeepSeek@twin (est. \$0.00/\$10, account \$8.42)" "status line: a second key of the account shows the same figure"
out=$(sl_bal); contains "$out" "DeepSeek@client (est. \$0.00/\$10, account \$8.42)" "status line: and the first key still shows it"
BWHERE="$BF"; out=$(BAL_MODE=off bal status); BWHERE=""
contains "$out" "DeepSeek@twin  *est. \$0.00 of \$10 (manual.*) · account \$8.42" "status: the second key's block line carries the account figure"
# next to the token-based estimate the status line says which is which
bal spend reset deepseek@client >/dev/null
$PY - "$BH/usage.jsonl" <<'EOF'
import datetime as dt, json, sys
rec = {"kind": "run", "provider": "deepseek", "label": "deepseek@client", "model": "deepseek-v4-pro", "billing": "api",
       "project": "bal-a", "usage": {"input_tokens": 8500000, "cached_input_tokens": 0, "output_tokens": 0},
       "ts": dt.datetime.now().astimezone().isoformat(timespec="microseconds")}
open(sys.argv[1], "a", encoding="utf-8").write(json.dumps(rec) + "\n")
EOF
out=$(sl_bal); contains "$out" "DeepSeek@client (est. \$8.50/\$10, account \$8.42)" "status line: the estimate is marked est., the account figure is the provider's"
out=$(bal status); contains "$out" "est. \$8.50 of \$10 (manual.*) · account \$8.42" "status: the estimate beside the account figure"
contains "$out" "API spend: DeepSeek@client \$8.50/\$10 (85%)" "status: the warning at 80% is still there, apart from the block"

# the status line never touches the network: the server sees no request, a sleeping server cannot slow it, a stopped one changes nothing
before=$(bal_count)
sl_bal >/dev/null; sl_bal "$BB" >/dev/null
[[ $(bal_count) -eq $before ]] && ok "the status line makes no request" || bad "the status line made a request"
bal_age deepseek@client 10800
bal_answers '{"sk-fake-client": {"total": "1.00", "sleep": 8}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
t0=$(bal_ms); out=$(sl_bal); t1=$(bal_ms)
contains "$out" "DeepSeek@client (est. .*account \$8.42, 3h ago)" "status line: an old figure says how old it is"
[[ $((t1 - t0)) -lt 7000 ]] && ok "the status line does not wait for a slow provider ($((t1 - t0)) ms)" || bad "the status line took $((t1 - t0)) ms"
[[ $(bal_count) -eq $before ]] && ok "an old figure makes the status line fetch nothing" || bad "the status line fetched an old figure"
bal_stop
out=$(sl_bal); contains "$out" "account \$8.42, 3h ago)" "status line: with the server stopped the cached amount still shows"

# a stale cache triggers a fetch from orch status and spend show, a fresh one does not
bal_answers '{"sk-fake-client": {"total": "7.00"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal_start || die "the fake balance server did not restart"
: > "$T/bal.log"
out=$(bal status); contains "$out" "\$7.00" "status: a stale figure (3h) is fetched again"
[[ $(bal_count) -eq 1 ]] && ok "status asks only for the stale scope of the project" || bad "status made $(bal_count) requests"
bal status >/dev/null; bal spend >/dev/null
[[ $(bal_count) -eq 1 ]] && ok "a fresh figure is not fetched again by status or spend show" || bad "fresh figure fetched again: $(bal_count) requests"
bal_age deepseek@client 700
bal_answers '{"sk-fake-client": {"total": "6.50"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
out=$(bal spend); contains "$out" "DeepSeek@client .*\$6.50" "spend show: a figure older than 10 minutes is fetched again"
[[ $(bal_count) -eq 2 ]] && ok "spend show made one request" || bad "spend show made $(bal_count) requests in total"

# the end of a run reads the account balance behind its key
bal_answers '{"sk-fake-client": {"total": "6.25"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
out=$(FAKE_CLAUDE=ok bal run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 0 $rc "run on a key profile with a balance server"
[[ "$(bal_cache_get deepseek@client amount)" == "6.25" ]] && ok "the end of a run refreshes the balance of its scope" || bad "run did not refresh the balance"
lacks "$out" "sk-fake" "run output holds no key"

# SessionStart: a stale balance is fetched by a detached process the hook does not wait for; a worker starts nothing
bal_age deepseek@client 3600
bal_answers '{"sk-fake-client": {"total": "5.75", "sleep": 4}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
: > "$T/bal.log"
old_at=$(bal_cache_get deepseek@client at)
out=$(printf '{"session_id":"s-bal"}' | bal hook session-start); rc=$?
expect_rc 0 $rc "SessionStart hook with a stale balance"
[[ "$(bal_cache_get deepseek@client at)" == "$old_at" ]] && ok "the hook did not wait for the fetch" || bad "the hook waited for the fetch"
for _ in $(seq 1 60); do [[ "$(bal_cache_get deepseek@client amount)" == "5.75" ]] && break; sleep 0.5; done
[[ "$(bal_cache_get deepseek@client amount)" == "5.75" ]] && ok "the detached fetch stores the balance after the hook is gone" || bad "no detached fetch happened"
bal_age deepseek@client 3600
before=$(bal_count)
out=$(printf '{"session_id":"s-bal"}' | ORCH_WORKER=run-x bal hook session-start); rc=$?
sleep 2
[[ $rc -eq 0 && $(bal_count) -eq $before ]] && ok "a worker's hook starts no fetch" || bad "a worker's hook fetched (rc=$rc, $(( $(bal_count) - before )) requests)"
[[ -z "$out" ]] && ok "a worker's hook is silent" || bad "a worker's hook printed: $out"
out=$(printf '{"session_id":"s-bal"}' | bal hook session-start)
for _ in $(seq 1 60); do [[ $(bal_count) -gt $before ]] && break; sleep 0.5; done
[[ $(bal_count) -gt $before ]] && ok "the same hook outside a worker does start the fetch" || bad "no fetch outside a worker"
sleep 5   # let the detached fetch (it sleeps 4 s on the server) land before the next scenario

# failures keep the last amount and break nothing: HTTP 500, malformed JSON, a timeout, a refused connection
bal_answers '{"sk-fake-client": {"total": "4.00"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal balance deepseek@client >/dev/null
bal_answers '{"sk-fake-client": {"total": "1.00", "status": 500}}'
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "an HTTP 500 fails the fetch"
contains "$out" "answered HTTP 500" "an HTTP 500 is named"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "HTTP 500: the last amount is kept" || bad "HTTP 500 lost the amount"
bal_answers '{"sk-fake-client": {"raw": "<html>not json"}}'
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "malformed JSON fails the fetch"
contains "$out" "not JSON" "malformed JSON is named"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "malformed JSON: the last amount is kept" || bad "malformed JSON lost the amount"
bal_answers '{"sk-fake-client": {"raw": "{\"balance_infos\": []}"}}'
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "a balance with no figure fails the fetch"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "an empty balance list: the last amount is kept" || bad "an empty list lost the amount"
bal_answers '{"sk-fake-client": {"total": "1.00", "sleep": 9}}'
t0=$(bal_ms); out=$(bal balance deepseek@client); rc=$?; t1=$(bal_ms)
contains "$out" "did not answer within 5 s" "a slow provider times out after 5 s"
[[ $((t1 - t0)) -lt 8500 ]] && ok "the timeout bounds the fetch ($((t1 - t0)) ms)" || bad "the fetch took $((t1 - t0)) ms"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "a timeout: the last amount is kept" || bad "a timeout lost the amount"
bal_answers '{"sk-fake-client": {"total": "1.00"}}'
bal_stop
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "a refused connection fails the fetch"
contains "$out" "cannot reach DeepSeek" "a refused connection is named"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "a refused connection: the last amount is kept" || bad "a refused connection lost the amount"
[[ -n "$(bal_cache_get deepseek@client error)" ]] && ok "the failure is recorded beside the amount" || bad "no error recorded"
bal_age deepseek@client 7200
out=$(bal status); rc=$?
expect_rc 0 $rc "status with the provider down"
contains "$out" "account \$4.00 (checked" "status keeps showing the last amount with the provider down"
contains "$out" "last fetch failed: " "status keeps the failed fetch visible beside the last amount"
out=$(bal spend); rc=$?
expect_rc 0 $rc "spend show with the provider down"
out=$(FAKE_CLAUDE=ok bal run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 0 $rc "a run with the provider down still succeeds"
out=$(printf '{"session_id":"s-bal"}' | bal hook session-start); rc=$?
expect_rc 0 $rc "SessionStart hook with the provider down"
sleep 2
out=$(sl_bal); contains "$out" "account \$4.00" "status line with the provider down"

# a key is never written outside secrets.env
leaks=$(grep -rl "sk-fake" "$BDIR" 2>/dev/null | grep -v "secrets.env$")
[[ -z "$leaks" ]] && ok "no key value in any file under ORCH_HOME except secrets.env" || bad "a key is stored in: $leaks"
echo "── per-session account budgets (isolated home and the fake balance endpoint)"
bal_start || die "no fake balance server for session budgets"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$T/session-budget")" "$BANS" "$BURL" <<'SESSION_BUDGET_TEST'
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest import mock

orch, root, answers, url = sys.argv[1:]
root = Path(root)
home, project = root / "home", root / "work"
home.mkdir(parents=True)
project.mkdir()
(home / "adapters").mkdir()
(home / "adapters" / "deepseek").write_text(
    '#!/usr/bin/env python3\n# orch-secrets: DEEPSEEK_API_KEY\n'
    'import os\nfrom pathlib import Path\n'
    'Path(os.environ["ORCH_OUTPUT_FILE"]).write_text("STATUS: DONE\\n" + os.environ["ORCH_PROFILE"])\n',
    encoding="utf-8")
(home / "secrets.env").write_text("BUDGET_KEY=sk-fake-client\nPERSONAL_KEY=sk-fake-personal\n", encoding="utf-8")
env = dict(os.environ, ORCH_HOME=str(home), ORCH_PROJECT_DIR=str(project), ORCH_SESSION_ID="budget-one",
           ORCH_BALANCE="on", ORCH_DEEPSEEK_BALANCE_URL=url, NO_PROXY="127.0.0.1", no_proxy="127.0.0.1",
           PYTHONUTF8="1", CODEX_HOME=str(root / "no-codex"))
for key in ("ORCH_WORKER", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR", "ORCH_PROFILES", "ORCH_USAGE_LOG"):
    env.pop(key, None)


def call(*args, **kwargs):
    e = dict(env)
    for key, value in kwargs.pop("env", {}).items():
        if value is None:
            e.pop(key, None)
        else:
            e[key] = value
    rc = kwargs.pop("rc", 0)
    p = subprocess.run([sys.executable, orch] + list(args), input=kwargs.pop("stdin", ""),
                       env=e, encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    assert p.returncode == rc, (args, p.returncode, p.stdout)
    assert "Traceback" not in p.stdout, p.stdout
    return p.stdout


def answer(amount=15.5, fail=False):
    Path(answers).write_text(json.dumps({"sk-fake-client": {"total": str(amount), "status": 500 if fail else 200},
                                       "sk-fake-personal": {"total": "50"}}), encoding="utf-8")


def fetch(amount):
    answer(amount)
    call("balance", "deepseek@client")


def hook(**kwargs):
    return call("hook", "user-prompt", stdin='{"session_id":"budget-one"}', **kwargs)


def shown(**kwargs):
    return json.loads(call("profile", "show", "--json", **kwargs))["providers"]["deepseek"]


def run(*args, **kwargs):
    return call("run", "deepseek", *args, "budget check", **kwargs)


def baseline(sid="budget-one"):
    return json.loads((home / "session_budget.json").read_text())["deepseek@client"][sid]


call("profile", "set", "deepseek", "personal", "--key", "PERSONAL_KEY")
out = call("profile", "set", "deepseek", "client", "--key", "BUDGET_KEY", "--session-soft", "30",
           "--session-hard", "90", "--balance-floor", "1", "--fallback", "personal", "--default")
assert "session budget: soft 30%, hard 90%, floor $1" in out, out
assert shown()["profile"] == "client"  # no first figure is not exhaustion
for option, value in (("--session-soft", "0"), ("--session-soft", "-1"), ("--session-soft", "101"), ("--session-hard", "0"),
                      ("--session-hard", "101"), ("--session-soft", "90"), ("--session-hard", "30"),
                      ("--balance-floor", "-1"), ("--balance-floor", "nan"), ("--session-hard", "inf"),
                      ("--session-soft", "bad")):
    call("profile", "set", "deepseek", "client", option, value, rc=1)
for option in ("--session-soft", "--session-hard", "--balance-floor"):
    assert "no balance API" in call("profile", "set", "codex", "client", option, "30", rc=1)
call("profile", "set", "deepseek", "fields", "--session-soft", "30", "--session-hard", "90", "--balance-floor", "0")
call("profile", "set", "deepseek", "fields", "--session-soft", "", "--session-hard", "", "--balance-floor", "")
fields = json.loads((home / "profiles.json").read_text())["providers"]["deepseek"]["profiles"]["fields"]
assert not any(f in fields for f in ("session_soft", "session_hard", "balance_floor"))
print("fields: set, shown, cleared; invalid percentages, ordering, floor and unsupported provider refused")

answer()
assert "client" in run()
assert baseline()["baseline"] == 15.5
fetch(15)
hook()
assert baseline()["baseline"] == 15.5 and baseline()["last"] == 15
hook(env={"ORCH_SESSION_ID": "budget-two"})
assert baseline("budget-two")["baseline"] == 15
hook(env={"ORCH_SESSION_ID": None})  # stdin supplies the same session id, including after compaction
assert baseline()["baseline"] == 15.5
fetch(10.85)  # exactly 30%: soft is strictly above, not at
hook()
assert shown()["profile"] == "client"
answer(10.8)
assert "personal" in run()  # fresh preflight itself moves before starting the fake adapter
out = hook()
assert "moved to personal" in out and "$4.70" in out and "$15.50" in out and "30.3%" in out, out
assert "moved to" not in hook()
other_event = hook(env={"ORCH_SESSION_ID": "budget-two"})
assert "returned to" not in other_event and "moved to" not in other_event, other_event
assert "moved to" not in hook()  # parallel sessions do not overwrite each other's transition state
assert shown()["profile"] == "personal" and shown()["fallback_cause"] == "session-soft"
assert shown()["session_budget"]["baseline"] == 15.5
assert "session: account down $4.70 of $15.50" in call("profile", "show")
assert "session: account down $4.70 of $15.50" in call("status")
assert "personal" in run()
call("profile", "set", "deepseek", "personal", "--balance-floor", "50")
assert "SESSION_BUDGET" in run(rc=75)  # the one-level fallback's own budget is enforced too
call("profile", "set", "deepseek", "personal", "--balance-floor", "")
print("baselines: isolated sessions and persistent baseline; show, status and run agree above soft; one move event")

call("budget", "set", "--used", "95", "--resets", "+2h")
out = hook()
assert "returned to client" in out and "Claude is TIGHT" in out and "$4.70" in out, out
assert shown()["profile"] == "client"
assert "returned to" not in hook()
call("budget", "clear")
assert "moved to personal" in hook()
call("budget", "set", "--used", "95", "--resets", "+2h")
fetch(1.55)  # exactly 90%, above the floor
hook()
assert shown()["fallback_cause"] == "session-hard"
fetch(1)
assert shown(env={"ORCH_SESSION_ID": None})["fallback_cause"] == "floor"
fetch(16)
out = hook()
assert "returned to client" in out and "topped up" in out and "$16.00" in out, out
assert baseline()["baseline"] == 16 and shown()["profile"] == "client"
assert "returned to" not in hook()
call("budget", "clear")
fetch(10)
assert "moved to personal" in hook()
fetch(16)  # a top-up to the same numeric baseline must still be announced as a top-up
assert "topped up" in hook()
fetch(10)
assert "moved to personal" in hook()
assert call("status").count("session: account down") == 1  # not repeated under the profiles
budget_file = home / "session_budget.json"
before = budget_file.stat().st_mtime_ns
hook()
assert budget_file.stat().st_mtime_ns == before  # hooks run after every tool call: no change, no write
balances = json.loads((home / "balances.json").read_text())
balances["deepseek@client"]["at"] = (dt.datetime.now().astimezone() - dt.timedelta(hours=5)).isoformat(timespec="seconds")
(home / "balances.json").write_text(json.dumps(balances), encoding="utf-8")
assert shown()["profile"] == "personal"  # an old figure can't clear a budget
answer(10, fail=True)
assert "personal" in run()  # the configured key's failed read doesn't stop a run on the fallback
assert shown()["profile"] == "personal"  # nor does it bring the project back
answer(18)
assert "DeepSeek@client" in run()  # a run reads the configured key first, so a top-up brings the project back
assert "topped up" in hook()
print("TIGHT: soft returns and reactivates; hard and no-session floor still move; top-up returns with figures")

call("profile", "set", "deepseek", "client", "--fallback", "none")
answer(fail=True)
out = run(rc=75)
assert "SESSION_BUDGET" in out and "no fresh balance" in out, out
assert json.loads((home / "usage.jsonl").read_text().splitlines()[-1])["status"] == "SESSION_BUDGET"
out = run(env={"ORCH_BALANCE": "off"})
assert out.count("warning: ORCH_BALANCE=off") == 1 and "[OK]" in out, out
answer(1)
assert "SESSION_BUDGET" in run(rc=75)
assert "SESSION_BUDGET" in run("--force", rc=75)
call("profile", "set", "deepseek", "client", "--fallback", "personal")
assert "SESSION_BUDGET" in run("--profile", "client", rc=75)
call("profile", "set", "deepseek", "client", "--fallback", "none")
fetch(20)
hook()
answer(13)
out = run()
assert "over its session budget" in out and "[OK]" in out, out
call("spend", "limit", "deepseek@client", "0")
assert "SPEND_LIMIT" in run(rc=75)
call("spend", "limit", "deepseek@client", "1000")
answer(1)
assert "SESSION_BUDGET" in run(rc=75)
print("preflight: failure, hard, explicit profile and force refuse; off and soft-only warn; spend limit remains independent")

# A corrupt baseline is never repaired into a fresh allowance by hooks or status.
answer(20)
baseline_path = home / "session_budget.json"
baseline_path.write_text("{broken", encoding="utf-8")
call("status")
hook()
assert baseline_path.read_text() == "{broken"
assert "SESSION_BUDGET" in run(rc=75)
baseline_path.unlink()
fetch(20)
hook()

# Pruning and top-ups of exactly 0.01; another session's record is preserved under the lock.
data = json.loads(baseline_path.read_text())
data["deepseek@client"]["old-session"] = dict(baseline(), at=(dt.datetime.now().astimezone() - dt.timedelta(days=8)).isoformat())
baseline_path.write_text(json.dumps(data), encoding="utf-8")
fetch(20.01)
hook()
assert baseline()["baseline"] == 20.01
assert "old-session" not in json.loads(baseline_path.read_text())["deepseek@client"]

sl_input = json.dumps({"session_id": "budget-one", "workspace": {"current_dir": str(project)}})
before = baseline_path.read_bytes(), baseline_path.stat().st_mtime_ns
with_fields = call("statusline", stdin=sl_input)
call("profile", "set", "deepseek", "client", "--session-soft", "", "--session-hard", "", "--balance-floor", "")
assert call("statusline", stdin=sl_input) == with_fields
assert (baseline_path.read_bytes(), baseline_path.stat().st_mtime_ns) == before
baseline_path.unlink()
call("profile", "set", "deepseek", "client", "--session-soft", "30", "--session-hard", "90", "--balance-floor", "1")
call("statusline", stdin=sl_input, env={"ORCH_SESSION_ID": None})
assert not baseline_path.exists()

# Exercise the recursion from both directions and prohibit all network/process/writes in the new status-line path.
os.environ.update(env)
loader = importlib.machinery.SourceFileLoader("session_budget_orch", orch)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.session_budget_hooks(project)
fetch(13)
call("profile", "set", "deepseek", "client", "--fallback", "personal", "--prefer-for", "tests")
call("budget", "set", "--used", "1", "--resets", "+2h")
m._exhaustion_memo.clear()
assert m.claude_budget(project)[0] == "surplus"
m._exhaustion_memo.clear()
assert m.resolve_profile("deepseek", project).name == "personal"
for field, value, cause in (("session_soft", 30, "session-soft"), ("session_hard", 30, "session-hard"),
                            ("balance_floor", 13, "floor")):
    p = m.Profile("deepseek", "client", {field: value}, "profile", True)
    assert m.session_budget_cause(p, project) == cause
cached = m.balance_cache()
with mock.patch.object(m, "balance_cache", return_value=dict(cached, **{"deepseek@client":
        dict(cached["deepseek@client"], error={"at": m.iso(m.now()), "message": "offline"})})):
    assert m.session_budget_cause(m.resolve_profile("deepseek", project, follow=False), project) == "session-soft"
with mock.patch.object(m, "balance_cache", return_value=dict(cached, **{"deepseek@client":
        dict(cached["deepseek@client"], at=m.iso(m.now() - dt.timedelta(hours=1)))})):
    assert m.session_budget_cause(m.resolve_profile("deepseek", project, follow=False), project) == "session-soft"
with mock.patch.object(m, "balance_cache", return_value=dict(cached, **{"deepseek@client":
        dict(cached["deepseek@client"], at="invalid")})):
    assert m.session_budget_cause(m.resolve_profile("deepseek", project, follow=False), project) is None
with mock.patch.object(m, "balance_refresh", side_effect=AssertionError("network")), \
        mock.patch.object(m, "write_json", side_effect=AssertionError("write")), \
        mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")):
    m._exhaustion_memo.clear()
    assert m.resolve_profile("deepseek", project).name == "personal"
    m.session_budget_figure(m.resolve_profile("deepseek", project, follow=False))
print("state/status line: corrupt file fails closed, pruning and cent top-up work; no baseline writes, network or subprocess; recursion guarded")
SESSION_BUDGET_TEST
expect_rc 0 $? "session budget checks"
bal_stop
unset -f bal bal_answers bal_start bal_stop bal_count bal_ms bal_cache_get bal_age sl_bal
BWHERE=""; BURL=""

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
contains "$out" "Session in/out: Claude 1.5k/150 +6.0k cache · Codex 400/40 · DeepSeek 500/60" "session tokens: claude from the transcript (with its cache reads), runs from the ledger"
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
    by[r["who"]] = (int(u.get("input_tokens") or 0), int(u.get("output_tokens") or 0),
                    int(u.get("cached_input_tokens") or 0))
assert by["orchestrator"] == (1500, 150, 6000), by
assert by["codex"] == (400, 40, 0), by
assert by["deepseek"] == (500, 60, 0), by
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
contains "$out" "Session in/out: Claude 1.2k/100 +5.0k cache" "first run counts the transcript once, cache reads too"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(c({"type": "assistant", "timestamp": "2026-11-02T10:05:00.000Z",
               "message": {"id": "i2", "model": "claude-opus-5-5",
                           "usage": {"input_tokens": 300, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1000, "output_tokens": 50}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 1.5k/150 +6.0k cache" "appended lines are counted once (not re-read)"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
open(sys.argv[1], "w", encoding="utf-8").write(c({"type": "assistant", "timestamp": "2026-11-02T10:06:00.000Z",
    "message": {"id": "i3", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 500, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 30}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 500/30" "a shrunken transcript restarts from scratch"
lacks "$out" " cache" "a shrunken transcript resets its cache reads too"
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
contains "$out" "Session in/out: Claude 1.7k/170 +6.0k cache · Codex 500/50 · Codex@work 90/10 · DeepSeek@client 520/65 · DeepSeek@personal 100/10" \
  "session tokens: one counter per account, plain account first, labels alphabetical, cache only where there is some"
grep -qE "DeepSeek [0-9]|DeepSeek@other" <<<"$out" && bad "session tokens: a sum over the keys, or another session's run: $out" \
  || ok "session tokens: two keys of one provider are not added up"
contains "$out" "Codex 500/50 · Codex@work" "a run without a label counts under its provider, with the plain codex runs"
contains "$out" "Claude 1.7k/170" "orch run claude on the default login adds up with the native thread"
out2=$(acct_sl sess-acct); [[ "$out2" == "$out" ]] && ok "session tokens: a second refresh changes nothing" || bad "session tokens drifted on refresh: $out2"
# a native session billed to a key profile counts under that profile's label, the default-login run stays apart
acct profile set claude work --key ANTHROPIC_API_KEY_WORK >/dev/null
out=$(acct_sl sess-acct ORCH_PROFILES=claude=work)
contains "$out" "Session in/out: Claude 200/20 · Claude@work 1.5k/150 +6.0k cache (est. \$0.00/\$10) · Codex" "a native session on a key profile shows its label, with its money in the same parentheses"
# its apiKeyHelper names that profile, so the thread keeps billing there while runs have moved to the fallback
acct profile set claude personal >/dev/null
acct profile set claude work --fallback personal >/dev/null
acct quota set claude@work exhausted >/dev/null
out=$(acct_sl sess-acct ORCH_PROFILES=claude=work)
contains "$out" "Session in/out: Claude 200/20 · Claude@work 1.5k/150 +6.0k cache · Codex" "a native session keeps its key's label while runs use the fallback"
acct quota clear claude@work >/dev/null
acct profile set claude work --fallback none >/dev/null
out=$(acct_sl sess-acct)
contains "$out" "Session in/out: Claude 1.7k/170 +6.0k cache · Codex" "the same session on the default login adds up again"
# an old-format cache entry (keyed by provider, no format mark) is rebuilt from the ledger with labels
$PY - "$AH" <<'EOF'
import json, os, sys, time
home = sys.argv[1]
size = os.path.getsize(os.path.join(home, "usage.jsonl"))
with open(os.path.join(home, "usage.jsonl"), "a", encoding="utf-8") as f:
    for label, i, o in (("deepseek@client", 500, 60), ("deepseek@personal", 100, 10)):
        f.write(json.dumps({"kind": "run", "session": "sess-old", "provider": "deepseek", "label": label,
                            "usage": {"input_tokens": i, "output_tokens": o}}) + "\n")
cache = os.path.join(home, "session_tokens.json")      # the cache of all sessions, as 0.18.0 and earlier wrote it
data = {"sess-old": {"files": {}, "ledger": {"deepseek": {"input": 600, "output": 70}},
                     "ledger_offset": size + 1000000, "updated": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())}}
json.dump(data, open(cache, "w", encoding="utf-8"))
EOF
out=$(acct_sl sess-old)
contains "$out" "Session in/out: DeepSeek@client 500/60 · DeepSeek@personal 100/10" "an old-format cache entry is rebuilt with labels"
grep -qE "DeepSeek [0-9]" <<<"$out" && bad "old cache: the stale provider sum survived: $out" || ok "old cache: no stale provider sum next to the keys"
out2=$(acct_sl sess-old); [[ "$out2" == "$out" ]] && ok "a rebuilt entry is not read twice" || bad "rebuilt entry drifted: $out2"
$PY - "$AH" <<'EOF' && ok "the rebuilt entry carries the format mark" || bad "the rebuilt entry has no format mark"
import json, os, sys
e = json.load(open(os.path.join(sys.argv[1], "session_tokens", "sess-old.json"), encoding="utf-8"))
assert e.get("format") == 3 and "deepseek" not in e["ledger"] and set(e["ledger"]) == {"deepseek@client", "deepseek@personal"}, e
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
data["sess-bad"] = {"format": 3, "files": {"x": "junk", "y": {"in": "a", "out": None, "cache": None, "provider": 5}},
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
grep -qE "^Session in/out: Claude 1\.[0-9]k/[0-9]+ \+6\.4k cache · DeepSeek@client [0-9]+/[0-9]+ \+400 cache · DeepSeek@personal [0-9]+/[0-9]+ \+400 cache$" <<<"$line" \
  && ok "end to end: two keys and the native login, three counters" || bad "end to end session line: $line"
[[ "$line" == *"Claude 1.5k/150"* ]] && bad "end to end: the claude run did not add to the native thread: $line" \
  || ok "end to end: orch run claude adds to the native Claude counter"

echo "── session tokens: cache reads (a third figure per account)"
CC="$TCFG/sess-cache.jsonl"
$PY - "$(native "$CC")" "$(native "$TCFG/sess-cache")" <<'EOF'
import json, os, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
def a(mid, inp, cr, out):
    return c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
              "message": {"id": mid, "model": "claude-opus-5-5",
                          "usage": {"input_tokens": inp, "cache_creation_input_tokens": 0,
                                    "cache_read_input_tokens": cr, "output_tokens": out}}})
open(sys.argv[1], "w", encoding="utf-8").write(a("k1", 1000, 20000, 100) + "\n")
os.makedirs(os.path.join(sys.argv[2], "subagents"), exist_ok=True)          # a subagent's own transcript
open(os.path.join(sys.argv[2], "subagents", "agent-k1.jsonl"), "w", encoding="utf-8").write(a("k2", 300, 8000, 50) + "\n")
EOF
$PY - "$AH/usage.jsonl" <<'EOF'
import json, sys
def rec(sid, prov, label, inp, cache, out):
    r = {"kind": "run", "session": sid, "provider": prov, "model": "m",
         "usage": {"input_tokens": inp, "cached_input_tokens": cache, "output_tokens": out}}
    if label is not None:
        r["label"] = label
    return json.dumps(r)
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(rec("sess-cache", "deepseek", "deepseek@client", 500, 3000, 60) + "\n")
    f.write(rec("sess-cache", "codex", None, 400, 0, 40) + "\n")            # no cache reads: no third figure
EOF
out=$(acct_sl sess-cache)
contains "$out" "Session in/out: Claude 1.3k/150 +28k cache · Codex 400/40 · DeepSeek@client 500/60 +3.0k cache" \
  "session cache: the thread and its subagents add up, and a run's cache follows its account"
lacks "$out" "Codex 400/40 +" "session cache: an account with no cache reads shows no third figure"
out2=$(acct_sl sess-cache); [[ "$out2" == "$out" ]] && ok "session cache: a second refresh counts the cache once" \
  || bad "session cache drifted on refresh: $out2"
# the figures are the `cache` column of `orch usage` for the same session
ORCH_HOME="$AH" $ORCH usage --session sess-cache --json > "$T/cache-usage.json"
printf '%s\n' "$out" > "$T/cache-line.txt"
$PY - "$(native "$T/cache-usage.json")" "$(native "$T/cache-line.txt")" <<'EOF' \
  && ok "session cache: the figures equal orch usage's cache column" || bad "session cache disagrees with orch usage"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["rows"]
line = [l for l in open(sys.argv[2], encoding="utf-8").read().splitlines() if l.startswith("Session in/out:")][0]
def fmt(n):
    if n < 1000:
        return str(n)
    if n < 10000:
        return "%.1fk" % (n / 1000.0)
    if n < 1000000:
        return "%dk" % round(n / 1000.0)
    return "%.1fM" % (n / 1000000.0)
fig = {}
for r in rows:
    u = r.get("usage") or {}
    key = "claude" if r["who"] == "orchestrator" or r["who"].startswith("subagent ") else r["who"]
    t = fig.setdefault(key, [0, 0, 0])
    for i, k in enumerate(("input_tokens", "output_tokens", "cached_input_tokens")):
        t[i] += int(u.get(k) or 0)
def counter(key, name):
    i, o, c = fig[key]
    return "%s %s/%s%s" % (name, fmt(i), fmt(o), (" +%s cache" % fmt(c)) if c else "")
assert counter("claude", "Claude") in line, (counter("claude", "Claude"), line)
assert counter("deepseek@client", "DeepSeek@client") in line, (fig, line)
assert counter("codex", "Codex") in line, (fig, line)
EOF
# a message re-sent with growing usage counts its cache once, at its last figure
CF="$TCFG/sess-cache-again.jsonl"
$PY - "$(native "$CF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
open(sys.argv[1], "w", encoding="utf-8").write(c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
    "message": {"id": "r1", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 1000, "cache_read_input_tokens": 100000, "output_tokens": 10}}}) + "\n")
EOF
out=$(acct_sl sess-cache-again)
contains "$out" "Session in/out: Claude 1.0k/10 +100k cache" "a message's first copy counts its cache"
$PY - "$(native "$CF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(c({"type": "assistant", "timestamp": "2026-11-02T10:00:01.000Z",
               "message": {"id": "r1", "model": "claude-opus-5-5",
                           "usage": {"input_tokens": 1200, "cache_read_input_tokens": 250000, "output_tokens": 20}}}) + "\n")
EOF
out=$(acct_sl sess-cache-again)
contains "$out" "Session in/out: Claude 1.2k/20 +250k cache" "a re-sent message counts its cache once, at its last figure"
# an entry saved in the previous format has no cache in its totals: it is parsed again from offset 0
$PY - "$AH" <<'EOF'
import json, os, sys, time
home = sys.argv[1]
os.makedirs(os.path.join(home, "session_tokens"), exist_ok=True)
entry = {"format": 2, "files": {"old-transcript": {"offset": 1, "in": 7000, "out": 900, "provider": "claude"}},
         "ledger": {"deepseek@client": {"input": 900, "output": 90}}, "ledger_offset": 0,
         "updated": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - 120))}
json.dump(entry, open(os.path.join(home, "session_tokens", "sess-cache-again.json"), "w", encoding="utf-8"))
EOF
out=$(acct_sl sess-cache-again)
contains "$out" "Session in/out: Claude 1.2k/20 +250k cache" "an entry in the previous format is rebuilt from the transcript, cache included"
lacks "$out" "7.0k/900" "the previous format's cache-less totals are gone"
$PY - "$AH" <<'EOF' && ok "the rebuilt entry is saved in the new format, with cache in its files" || bad "the rebuilt entry keeps the old format"
import json, os, sys
e = json.load(open(os.path.join(sys.argv[1], "session_tokens", "sess-cache-again.json"), encoding="utf-8"))
assert e.get("format") == 3, e
assert e["files"] and all("cache" in s for s in e["files"].values() if isinstance(s, dict)), e
EOF
out2=$(acct_sl sess-cache-again); [[ "$out2" == "$out" ]] && ok "a rebuilt entry is not parsed twice" || bad "rebuilt entry drifted: $out2"

echo "── a fast status line (no process, small writes, bounded ids, kills)"
SLH="$(native "$T/sl-home")"; SLN="$(native "$T/sl-no-codex")"; SLCFG="$(native "$T/sl-cfg")"; SLR="$T/sl-repo"
SLP="$T/sl-cfg/projects/p"; SLD="$T/sl-home/session_tokens"; SLT="$(native "$T/sl_tool.py")"
mkdir -p "$SLH" "$SLN" "$SLP" "$SLR/sub" && git -C "$SLR" init -q || die "cannot create the status line fixture"
SLRESET=$(( $(date +%s) + 7200 ))
sl_in() {
  printf '{"session_id":"%s","transcript_path":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":%s}}}' \
    "$1" "$(native "$SLP/$1.jsonl")" "$(native "${2:-$SLR}")" "$SLRESET"
}
sl_env() { ORCH_HOME="$SLH" CODEX_HOME="$SLN" CLAUDE_CONFIG_DIR="$SLCFG" "$@"; }
sl_run() { sl_in "$1" | sl_env $ORCH statusline; }
sl_file() { native "$SLD/$1.json"; }
cat > "$T/sl_tool.py" <<'EOF'
import datetime as dt, json, os, sys, time
cmd, args = sys.argv[1], sys.argv[2:]
compact = lambda o: json.dumps(o, separators=(",", ":"))
def message(i, output):
    t = dt.datetime(2026, 11, 2, 10) + dt.timedelta(seconds=i)
    return compact({"type": "assistant", "timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                    "message": {"id": "msg-%d" % i, "model": "claude-opus-5-5",
                                "usage": {"input_tokens": 10, "output_tokens": output}}}) + "\n"
def load(orch):
    import importlib.machinery, importlib.util
    loader = importlib.machinery.SourceFileLoader("sl_orch", orch)
    m = importlib.util.module_from_spec(importlib.util.spec_from_loader("sl_orch", loader))
    loader.exec_module(m)
    return m
if cmd == "gen":                 # messages: two adjacent lines each, as a streamed response writes them
    with open(args[0], "a", encoding="utf-8") as f:
        for i in range(int(args[1]), int(args[1]) + int(args[2])):
            f.write(message(i, 1) + message(i, 3))
elif cmd == "resend":            # a copy of an old line, its own timestamp included
    with open(args[0], "a", encoding="utf-8") as f:
        f.write(message(int(args[1]), 3))
elif cmd in ("age", "fresh"):    # the session's last save is a minute ago, or now
    e = json.load(open(args[0], encoding="utf-8"))
    back = dt.timedelta(seconds=60 if cmd == "age" else 0)
    e["updated"] = (dt.datetime.now().astimezone() - back).isoformat(timespec="seconds")
    json.dump(e, open(args[0], "w", encoding="utf-8"))
elif cmd == "backdate":          # file modification time, seconds ago
    t = time.time() - int(args[1])
    os.utime(args[0], (t, t))
elif cmd == "ids":               # the largest number of ids held for one file
    e = json.load(open(args[0], encoding="utf-8"))
    print(max(len(s.get("ids") or {}) for s in e["files"].values()))
elif cmd == "old-cache":         # home, session, transcript: an entry whose totals only the old cache knows
    home, sid, transcript = args
    key = str(os.path.normpath(transcript))
    entry = {"format": 2, "ledger": {"codex": {"input": 40, "output": 4}}, "ledger_offset": 0, "updated": "2026-11-02T10:00:00+00:00",
             "files": {key: {"offset": os.path.getsize(transcript), "in": 7000, "out": 900, "provider": "claude",
                             "ids": {"old-%d" % i: {"i": 1, "o": 1} for i in range(150)}}}}
    json.dump({sid: entry, "other-session": dict(entry, ledger={})}, open(os.path.join(home, "session_tokens.json"), "w", encoding="utf-8"))
elif cmd == "audit":             # log, orch, arguments: what a run starts and which modules it loads
    log, orch = args[0], args[1]
    sys.argv = [orch] + args[2:]
    started, before = [], set(sys.modules)
    def hook(name, a):
        if name in ("subprocess.Popen", "os.system", "os.spawn", "os.exec", "os.posix_spawn", "os.startfile"):
            started.append("%s %r" % (name, a[:2]))
    sys.addaudithook(hook)
    code = compile(open(orch, encoding="utf-8").read(), orch, "exec")
    try:
        exec(code, {"__name__": "__main__", "__file__": orch})
    except SystemExit:
        pass
    heavy = sorted(({"argparse", "shutil", "subprocess", "tempfile"} & set(sys.modules)) - before)
    json.dump({"started": started, "heavy": heavy}, open(log, "w", encoding="utf-8"))
elif cmd == "kill":              # mode, orch: die in the middle of writing the session's file
    m = load(args[1])
    if args[0] == "before-replace":
        replace = os.replace
        def die_replacing(src, dst):
            if "session_tokens" in str(dst):
                os._exit(9)
            return replace(src, dst)
        m.os.replace = die_replacing
    else:
        dump = json.dump
        def die_dumping(data, f, **kw):
            if "session_tokens" in str(getattr(f, "name", "")):
                f.write('{"format": 3, "fil'); f.flush(); os._exit(9)
            return dump(data, f, **kw)
        m.json.dump = die_dumping
    sys.exit(m.main(["statusline"]))
elif cmd == "busy":              # orch: a status line while another process holds the lock
    import subprocess
    m = load(args[0])
    with m.state_lock(m.ORCH_HOME / ".state.lock"):
        r = subprocess.run([sys.executable, args[0], "statusline"], stdin=sys.stdin, stdout=subprocess.PIPE)
    sys.stdout.buffer.write(r.stdout)
    sys.exit(r.returncode)
EOF
# the transcripts: messages of 10 in, 3 out
$PY "$SLT" gen "$(native "$SLP/speed-ids-1.jsonl")" 0 250
# no process: a recording git for POSIX, the audit hook for every system (native Windows finds only a git.exe on PATH)
mkdir -p "$T/sl-gitbin"; printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$T/sl-git-called" > "$T/sl-gitbin/git"; chmod +x "$T/sl-gitbin/git"
( cd "$SLR/sub" && sl_in speed-ids-1 "$SLR/sub" | PATH="$T/sl-gitbin:$PATH" sl_env $PY "$SLT" audit "$(native "$T/sl-audit.json")" "$(native "$PLUGIN/bin/orch")" statusline >"$T/sl-out.txt" )
out=$(cat "$T/sl-out.txt"); contains "$out" "Session in/out: Claude 2.5k/750" "fast status line: a streamed message counts once"
contains "$out" "5h 12%" "fast status line: the limits line comes from this run's input"
[[ -e "$T/sl-git-called" ]] && bad "the status line called git" || ok "the status line does not call git"
$PY - "$(native "$T/sl-audit.json")" <<'EOF' && ok "the status line starts no process, in a git repository, without ORCH_PROJECT_DIR" || bad "the status line started a process"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert not d["started"], d
EOF
$PY - "$(native "$T/sl-audit.json")" <<'EOF' && ok "the status line loads neither argparse, shutil, subprocess nor tempfile" || bad "the status line loaded a heavy module"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert not d["heavy"], d
EOF
sl_in speed-ids-1 | sl_env $PY "$SLT" audit "$(native "$T/sl-audit.json")" "$(native "$PLUGIN/bin/orch")" statusline --then "echo mine" >/dev/null
$PY - "$(native "$T/sl-audit.json")" <<'EOF' && ok "the audit hook sees a process: --then, the operator's own command, is the only one" || bad "the audit hook is blind, or --then did not run"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d["started"]) == 1 and "mine" in d["started"][0], d
EOF
out=$(sl_in speed-ids-1 | sl_env $ORCH statusline --the "echo mine"); contains "$out" "^mine  " "statusline: an abbreviated option still goes through argparse"
sl_in speed-ids-1 | sl_env $ORCH statusline --nope >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "statusline: an unknown option is still refused" || bad "statusline accepted --nope"
# ids stay bounded; a message re-sent after its id was dropped still counts once
n=$($PY "$SLT" ids "$(sl_file speed-ids-1)"); n=${n%$'\r'}
[[ "$n" -le 100 ]] && ok "ids stay bounded in a long transcript ($n of 250)" || bad "ids not bounded: $n"
$PY "$SLT" resend "$(native "$SLP/speed-ids-1.jsonl")" 3
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "a message re-sent after its id was dropped counts once"
$PY "$SLT" resend "$(native "$SLP/speed-ids-1.jsonl")" 249
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "a message re-sent next to its first copy counts once"
sl_env $ORCH usage --session speed-ids-1 --json > "$T/sl-usage.json"
$PY - "$(native "$T/sl-usage.json")" <<'EOF' && ok "the bounded ids agree with orch usage" || bad "the bounded ids disagree with orch usage"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["rows"]
u = [r for r in rows if r["who"] == "orchestrator"][0]["usage"]
assert (u["input_tokens"], u["output_tokens"]) == (2500, 750), u
EOF
# a file idle for 10 minutes keeps no ids, and still does not count an old message twice
$PY "$SLT" backdate "$(native "$SLP/speed-ids-1.jsonl")" 660; $PY "$SLT" age "$(sl_file speed-ids-1)"
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "dropping an idle file's ids keeps the totals"
n=$($PY "$SLT" ids "$(sl_file speed-ids-1)"); [[ "${n%$'\r'}" == 0 ]] && ok "a file idle for 10 minutes keeps no ids" || bad "idle file ids: $n"
$PY "$SLT" resend "$(native "$SLP/speed-ids-1.jsonl")" 249
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "a message re-sent after the idle drop counts once"
# new messages after the drop still count
$PY "$SLT" gen "$(native "$SLP/speed-ids-1.jsonl")" 1000 1
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/753" "a new message after the drop counts"
# a refresh writes this session's file only, at most once per 30 seconds
$PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" 0 2; $PY "$SLT" gen "$(native "$SLP/speed-two.jsonl")" 0 4
sl_run speed-one >/dev/null; sl_run speed-two >/dev/null
[[ -f "$SLD/speed-one.json" && -f "$SLD/speed-two.json" ]] && ok "each session has its own file" || bad "no per-session files"
[[ -e "$T/sl-home/session_tokens.json" ]] && bad "the shared cache came back" || ok "nothing writes the old shared cache"
cp "$SLD/speed-two.json" "$T/sl-b.snap"
$PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" 2 1
$PY "$SLT" fresh "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"      # the clock starts here, however slow the machine
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "a refresh inside 30 seconds shows the new tokens"
cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && ok "a refresh inside 30 seconds does not write" || bad "two refreshes inside 30 seconds wrote twice"
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "parsing from the saved offset again counts nothing twice"
$PY "$SLT" age "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "the refresh that saves shows the same totals"
cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && bad "no save after 30 seconds" || ok "after 30 seconds the refresh saves"
cmp -s "$SLD/speed-two.json" "$T/sl-b.snap" && ok "a refresh leaves other sessions' data alone" || bad "a refresh rewrote another session's file"
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "the saved state continues without a drift"
# a session running across the upgrade: its entry has no cache, so both its ledger part and its transcript files are
# parsed again from 0 (a long one catches up over a few updates, with lower numbers until then)
$PY "$SLT" gen "$(native "$SLP/speed-mig.jsonl")" 0 1
$PY "$SLT" old-cache "$SLH" speed-mig "$(native "$SLP/speed-mig.jsonl")"
cp "$T/sl-home/session_tokens.json" "$T/sl-old.snap"
$PY "$SLT" gen "$(native "$SLP/speed-mig.jsonl")" 1 1
out=$(sl_run speed-mig); contains "$out" "Session in/out: Claude 20/6" "migration: an entry in the previous format is parsed again from the transcript"
n=$($PY "$SLT" ids "$(sl_file speed-mig)"); [[ "${n%$'\r'}" -le 100 ]] && ok "migration: the rebuilt file state holds only the real messages ($n of 150 old ids)" || bad "migration ids: $n"
cmp -s "$T/sl-home/session_tokens.json" "$T/sl-old.snap" && ok "migration: other sessions' old entries stay where they are" || bad "migration rewrote the old cache"
$PY "$SLT" backdate "$(native "$T/sl-home/session_tokens.json")" 90000
out=$(sl_run speed-mig); contains "$out" "Session in/out: Claude 20/6" "migration: totals survive the old cache going away"
[[ -e "$T/sl-home/session_tokens.json" ]] && bad "the old cache outlived its last day" || ok "migration: the old cache goes once a day old"
# a kill in the middle of a save leaves valid state, and the next refresh is right
next_message=100
for mode in before-replace mid-dump; do
  $PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" $next_message 1; next_message=$((next_message + 1))
  $PY "$SLT" age "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"
  sl_in speed-one | sl_env $PY "$SLT" kill "$mode" "$(native "$PLUGIN/bin/orch")" >/dev/null; rc=$?
  [[ $rc -eq 9 ]] && ok "kill test ($mode): the run died while saving" || bad "kill test ($mode): rc=$rc"
  cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && ok "a kill ($mode) leaves the session's file whole" || bad "a kill ($mode) damaged the session's file"
done
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 50/15" "after the kills the totals are right"
# leftovers of killed runs go after a day, a write in progress stays
printf '{"x' > "$T/sl-home/usage.json.old.tmp"; printf '{"x' > "$T/sl-home/usage.json.new.tmp"; printf '{"x' > "$SLD/x.json.old.tmp"
printf '{}' > "$SLD/gone-session.json"
for f in "$T/sl-home/usage.json.old.tmp" "$SLD/x.json.old.tmp" "$SLD/gone-session.json"; do $PY "$SLT" backdate "$(native "$f")" 90000; done
sl_run speed-one >/dev/null
[[ ! -e "$T/sl-home/usage.json.old.tmp" && ! -e "$SLD/x.json.old.tmp" ]] && ok "*.tmp files older than a day are removed" || bad "old *.tmp files stayed"
[[ -e "$T/sl-home/usage.json.new.tmp" ]] && ok "a recent *.tmp stays: it may be a write in progress" || bad "a recent *.tmp was removed"
[[ ! -e "$SLD/gone-session.json" && -e "$SLD/speed-one.json" ]] && ok "a session's file goes a day after its last save" || bad "session files not pruned by age"
# a busy lock: print what is cached, including tokens parsed in this run, and save nothing
$PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" 200 1
$PY "$SLT" age "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"
out=$(sl_in speed-one | sl_env $PY "$SLT" busy "$(native "$PLUGIN/bin/orch")"); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "5h 12%" "a busy lock: the limits line comes from the cache" || bad "busy lock: rc=$rc out=$out"
contains "$out" "Session in/out: Claude 60/18" "a busy lock: the session's new tokens still show"
cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && ok "a busy lock skips the save" || bad "a save went through a busy lock"
# what takes a module to check: the codex scan throttle, the byte budget, one read per run, the root without git
sl_git_wt="$T/sl-repo-wt"; git -C "$SLR" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init && git -C "$SLR" worktree add -q "$sl_git_wt" -b sl-wt \
  || die "cannot create the worktree fixture"
slunit=$(sl_env $PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/sl-unit")" "$(native "$SLR")" "$(native "$sl_git_wt")" 2>&1 <<'EOF'
import importlib.machinery, importlib.util, json, os, subprocess, sys, traceback
from pathlib import Path
from unittest import mock
orch, root, repo, worktree = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
root.mkdir()
os.environ.update(ORCH_HOME=str(root / "home"), CODEX_HOME=str(root / "cx"))
os.environ.pop("ORCH_PROJECT_DIR", None); os.environ.pop("CLAUDE_PROJECT_DIR", None)
loader = importlib.machinery.SourceFileLoader("sl_unit", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("sl_unit", loader)); loader.exec_module(m)

def check(name, fn):
    try:
        fn()
        print("PASS " + name, flush=True)
    except Exception:
        print("FAIL " + name + ": " + traceback.format_exc().replace("\n", " | "), flush=True)

def rollout_without_limits():
    d = root / "cx" / "sessions" / "2026" / "11" / "02"
    d.mkdir(parents=True, exist_ok=True)
    (d / "rollout-0001.jsonl").write_text('{"type": "noise"}\n', encoding="utf-8")

def scan_throttled_when_it_finds_nothing():
    rollout_without_limits()
    with mock.patch.object(m, "scan_codex_limits", wraps=m.scan_codex_limits) as scan:
        m.refresh_codex(); m.refresh_codex()
        assert scan.call_count == 1, scan.call_count
        m.refresh_codex(force=True)
        assert scan.call_count == 2, scan.call_count
    assert not m.codex_status_part(), "a scan that found nothing must not show a line"

def scan_throttled_when_killed():
    m.write_json(m.CODEX_USAGE_FILE, {})
    with mock.patch.object(m, "scan_codex_limits", side_effect=KeyboardInterrupt):
        try:
            m.refresh_codex()
            raise AssertionError("the scan did not run")
        except KeyboardInterrupt:
            pass
    with mock.patch.object(m, "scan_codex_limits", side_effect=AssertionError("scanned again")):
        m.refresh_codex()

def no_rollouts_no_write():
    with mock.patch.dict(os.environ, {"CODEX_HOME": str(root / "no-such-codex")}):
        before = m.CODEX_USAGE_FILE.read_bytes()
        m.refresh_codex()
        assert m.CODEX_USAGE_FILE.read_bytes() == before

def transcript_lines(path, first, count, padding=""):
    with open(str(path), "a", encoding="utf-8") as f:
        for i in range(first, first + count):
            f.write(json.dumps({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z", "message": {
                "id": "b-%d" % i, "model": "claude-opus-5-5", "pad": padding,
                "usage": {"input_tokens": 10, "output_tokens": 1}}}, separators=(",", ":")) + "\n")

def backlog_progress_survives_kills():
    tr = root / "backlog-session.jsonl"
    transcript_lines(tr, 0, 40)
    transcript_lines(tr, 40, 1, "x" * 2000)            # one line longer than the budget
    transcript_lines(tr, 41, 40)
    saved = m.session_tokens_path("backlog-session")
    seen = []
    with mock.patch.object(m, "PARSE_BYTES_PER_RUN", 400):
        for _ in range(100):
            t = m.session_tokens("backlog-session", str(tr))["claude"]["input"]
            seen.append(t)
            if t == 810:
                break
            state = list(json.loads(saved.read_text(encoding="utf-8"))["files"].values())[0]
            assert state["in"] == t, "a run behind saves at once, or a killed one would start over"
    assert seen[-1] == 810 and len(seen) > 2 and seen == sorted(seen), seen

def one_read_per_run():
    f = root / "home" / "memo.json"
    m.write_json(f, {"v": 1})
    with mock.patch.object(m, "_statusline_run", True):
        assert m.read_json(f, {})["v"] == 1
        f.write_text('{"v": 2}', encoding="utf-8")
        assert m.read_json(f, {})["v"] == 1, "the second read opened the file"
        with m.state_lock(m.ORCH_HOME / ".state.lock"):
            assert m.read_json(f, {})["v"] == 2, "a locked read-modify-write must see the file as it is now"
        m.write_json(f, {"v": 3})
        assert m.read_json(f, {})["v"] == 3
        missing = root / "home" / "missing.json"
        assert m.read_json(missing, {}) == {}
        m.write_json(missing, {"v": 4})
        assert m.read_json(missing, {})["v"] == 4
    m._run_reads.clear()
    f.write_text('{"v": 5}', encoding="utf-8")
    assert m.read_json(f, {})["v"] == 5 and m.read_json(f, {})["v"] == 5 and not m._run_reads

def session_file_names():
    for sid in ("../../evil", "CON", "UPPER-case-id", "a/b", "x" * 300):
        p = m.session_tokens_path(sid)
        assert p.parent == m.SESSION_TOKENS_DIR and p.name.startswith("x-") and len(p.name) < 80, p
    assert m.session_tokens_path("1f0e-uuid-like").name == "1f0e-uuid-like.json"

def git_says(args, cwd):
    return Path(subprocess.run(["git"] + args, cwd=str(cwd), stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout.strip())

def root_agrees_with_git():
    (repo / "sub").mkdir(exist_ok=True); (worktree / "deep").mkdir(exist_ok=True)
    for d in (repo, repo / "sub", worktree, worktree / "deep"):
        top = git_says(["rev-parse", "--show-toplevel"], d).resolve()
        cwd = os.getcwd()
        m._toplevels.clear()
        try:
            os.chdir(str(d))
            assert m.project_dir() == top, (d, m.project_dir(), top)
        finally:
            os.chdir(cwd)
        common = git_says(["rev-parse", "--git-common-dir"], d)
        common = common if common.is_absolute() else (d / common).resolve()
        assert m._project_root(d.resolve()) == common.resolve().parent, (d, m._project_root(d.resolve()), common)
    assert m._project_root(worktree.resolve()) == repo.resolve(), "a worktree belongs to its main repository"

def root_edge_cases():
    outside = root / "outside"; outside.mkdir()
    assert m._project_root(outside.resolve()) == outside.resolve()
    nogit = outside / "empty-git"; (nogit / ".git").mkdir(parents=True)           # git goes on looking above a non-repository
    assert m._project_root(nogit.resolve()) == nogit.resolve()
    broken = outside / "broken"; broken.mkdir(); (broken / ".git").write_text("not a gitdir\n", encoding="utf-8")
    assert m._project_root(broken.resolve()) == broken.resolve()
    dangling = outside / "dangling"; dangling.mkdir()                              # a worktree whose main repository is gone
    (dangling / ".git").write_text("gitdir: ../gone/.git/worktrees/x\n", encoding="utf-8")
    assert m._project_root(dangling.resolve()) == dangling.resolve(), "a .git file that points nowhere is no repository"
    sub = outside / "submodule"; own = outside / "super" / ".git" / "modules" / "submodule"
    sub.mkdir(); own.mkdir(parents=True); (own / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
    (sub / ".git").write_text("gitdir: ../super/.git/modules/submodule\n", encoding="utf-8")
    (sub / "deep").mkdir()
    assert m._project_root((sub / "deep").resolve()) == sub.resolve(), "a submodule is its own project, as with git"

check("codex: a scan that finds nothing waits for the throttle too", scan_throttled_when_it_finds_nothing)
check("codex: a run killed mid-scan does not make the next one scan", scan_throttled_when_killed)
check("codex: without a sessions folder a refresh writes nothing", no_rollouts_no_write)
check("a backlog over the byte budget is saved as it goes, and reaches the right total", backlog_progress_survives_kills)
check("a status line run reads a file once, and afresh under a lock or after its own write", one_read_per_run)
check("an unusual session id cannot leave the session folder", session_file_names)
check("the root found without git agrees with git: repository, subfolder, linked worktree", root_agrees_with_git)
check("the root found without git: outside a repository, a broken .git file, a submodule", root_edge_cases)
EOF
)
while IFS= read -r line; do
  line=${line%$'\r'}
  case "$line" in "PASS "*) ok "${line#PASS }" ;; *) bad "$line" ;; esac
done <<<"$slunit"

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

if not (os.environ.get("ORCH_CODEX_BIN") and os.environ.get("ORCH_CLAUDE_BIN")):
    sys.exit("This block runs inside run_tests.sh: without its fakes, its runs would call the real codex and claude.")
orch, root = str(Path(sys.argv[1]).resolve()), Path(sys.argv[2])
root.mkdir()
root = root.resolve()      # a Windows short name in TEMP: orch compares and reports the long form
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
        hid = offered()
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
    # a status line doesn't wait for a busy lock and registers on a later update; a hook waits, and none may be lost
    ps = [start(["hook", "user-prompt"], json.dumps({"session_id": "parallel-%d" % i, "cwd": str(proj)})) for i in range(8)]
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
    hid = offered(write=True, base="missing-review-ref")     # the worktree cannot be made: the take fails
    rc, out = run(["handoff", "take", hid])
    assert rc != 0 and m.result_status(meta(hid)) == "OFFERED", (rc, out, meta(hid))
    clear_tasks()
    hid = offered()
    (m.handoffs_root() / hid / "BODY.md").unlink()           # the assignment cannot read its task: the take fails
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
                 ["close", hid], ["take", hid], ["reclaim", hid], ["hold", hid], ["new", "--title", "x"], ["offer", "--title", "x"]):
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
    assert m.claude_budget()[0] == "surplus"   # an early projection is noise: it neither raises TIGHT nor blocks SURPLUS
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

    # week_history sampling: at most one per 15 min, kept for 80 h, capped at 400, malformed entries dropped.
    t0 = fixed
    hist = m.week_history_update([], {"used": 80.0, "resets_at": m.iso(reset)}, t0)
    hist = m.week_history_update(hist, {"used": 81.0, "resets_at": m.iso(reset)}, t0 + dt.timedelta(minutes=5))
    assert len(hist) == 1                    # a change within 15 min adds no second sample
    hist = m.week_history_update(hist, {"used": 82.0, "resets_at": m.iso(reset)}, t0 + dt.timedelta(minutes=20))
    assert len(hist) == 2                    # past the gap a change adds a sample
    hist = m.week_history_update([["garbage", 80.0, m.iso(reset)]], {"used": 90.0, "resets_at": m.iso(reset)},
                                 t0 + dt.timedelta(hours=1))
    assert len(hist) == 1 and hist[0][1] == 90.0      # the malformed entry is skipped, never fatal
    many = [[m.iso(t0 + dt.timedelta(minutes=5 * i)), 1.0, m.iso(reset)] for i in range(450)]
    assert len(m.week_history_update(many, None, t0 + dt.timedelta(hours=72))) == 400   # the cap
    # a sample about 72 h old must survive the 80 h retention; one past it is dropped
    three_days = [[m.iso(t0 - dt.timedelta(hours=78)), 1.0, m.iso(reset)]]
    assert len(m.week_history_update(three_days, None, t0)) == 1
    assert m.week_history_update([[m.iso(t0 - dt.timedelta(hours=82)), 1.0, m.iso(reset)]], None, t0) == []

    # The weekly base sample: earliest within 72 h (three days), same reset (10 min), at least 6 h before the
    # measurement.
    hist8 = [[m.iso(fixed - dt.timedelta(hours=8)), 82.0, m.iso(reset)]]
    assert m.week_base_sample(hist8, reset, fixed) == (fixed - dt.timedelta(hours=8), 82.0)
    old = reset - dt.timedelta(days=7)                 # a sample from the previous week
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=8)), 50.0, m.iso(old)]], reset, fixed) is None
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=5)), 82.0, m.iso(reset)]], reset, fixed) is None
    rw = fixed + dt.timedelta(hours=24)                 # a week with 24 h still to its reset
    assert m.week_base_sample([[m.iso(fixed - dt.timedelta(hours=75)), 82.0, m.iso(rw)]], rw, fixed) is None
    # three days back is the point: the earliest within 72 h wins over a nearer sample
    mixed = [[m.iso(fixed - dt.timedelta(hours=60)), 60.0, m.iso(rw)],
             [m.iso(fixed - dt.timedelta(hours=20)), 70.0, m.iso(rw)]]
    assert m.week_base_sample(mixed, rw, fixed) == (fixed - dt.timedelta(hours=60), 60.0)
    rate, basis = m.week_rate(mixed, 80.0, rw, fixed)
    assert basis == "the last 2d 12h" and abs(rate - 20.0 / 3600) < 1e-12, (rate, basis)
    # After the window, the newest older sample with the same reset stands in for a flat week: zero pace,
    # basis "the last 3 d" — only while the used value is unchanged (a change means the recent pace is unknown).
    rr2 = fixed + dt.timedelta(hours=48)
    idle = [[m.iso(fixed - dt.timedelta(hours=75)), 70.0, m.iso(rr2)]]
    assert m.week_base_sample(idle, rr2, fixed, 70.0) == (fixed - dt.timedelta(hours=72), 70.0)
    assert m.week_base_sample(idle, rr2, fixed, 71.0) is None
    rate, basis = m.week_rate(idle, 70.0, rr2, fixed)
    assert basis == "the last 3 d" and rate == 0.0, (rate, basis)
    assert m.week_recent_basis(3 * 24 * 60) == "the last 3 d"
    assert m.week_recent_basis(8 * 60) == "the last 8 h"
    assert m.week_recent_basis(6 * 60 + 30) == "the last 6h 30m"

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
    # a task in the project folder shares it with other work: a changed file starts nothing
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "shared"])).group()
    task = meta(hid)
    task.update(created=m.iso(fixed - dt.timedelta(hours=8)), taken=m.iso(fixed - dt.timedelta(hours=8)))
    m.save_meta(task)
    (proj / "app.txt").write_text("someone else\n", encoding="utf-8")
    with mock.patch.object(m, "scan_latest_mtime", side_effect=AssertionError("a shared folder was scanned")):
        assert m.last_activity(m.load_meta(hid)) is None and m.effective_state(m.load_meta(hid)) == "WAITING"
    assert not any("in progress" in e and hid in e for e in m.check_events()), "a shared edit counted as activity"
    subprocess.run(["git", "checkout", "--", "app.txt"], cwd=str(proj), check=True)
    clear_tasks()
    # an older task has a worktree of its own: the folder scan stays for it
    hid = re.search(r"AG-\d+", good(["handoff", "new", "--title", "activity"])).group()
    task = meta(hid)
    task.update(created=m.iso(fixed - dt.timedelta(hours=8)), taken=m.iso(fixed - dt.timedelta(hours=8)), branch="ag/older")
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
    assert rc == 75 and "CAPACITY" in out, out
    entries = m.read_json(m.AVAIL_FILE, {})["entries"]
    assert set(entries) == {"codex/capacity-model"}, entries
    assert entries["codex/capacity-model"]["status"] == "busy"
    until = m.parse_iso(entries["codex/capacity-model"]["until"])     # checked at once: the runs below take time
    assert 9 * 60 < (until - m.now()).total_seconds() <= 10 * 60, (until, m.now())
    assert "CAPACITY" in run(["run", "codex", "--model", "capacity-model", "review"])[1]
    assert "CAPACITY" in good(["usage"])
    # capacity with an unknown model id: no --model and no model in the codex config → no block is recorded
    before = m.read_json(m.AVAIL_FILE, {})["entries"]
    rc, out = run(["run", "codex", "review"], extra={"FAKE_CODEX": "capacity"})
    assert rc == 75 and "CAPACITY" in out and "no availability block was recorded" in out, out
    assert m.read_json(m.AVAIL_FILE, {})["entries"] == before, out
    rc, out = run(["run", "codex", "--model", "trace-model", "review"], extra={"FAKE_CODEX":"trace_fail"})
    assert rc != 75 and "[FAILED]" in out, out
    assert set(m.read_json(m.AVAIL_FILE, {})["entries"]) == {"codex/capacity-model"}
    rc, out = run(["run", "codex", "--model", "trace-model", "review"], extra={"FAKE_CODEX":"trace_limit"})
    assert rc == 75 and "[QUOTA_EXHAUSTED]" in out, out
    assert "subscription limit: You've hit your usage limit" in out, out
    assert all("cloud-quotas" not in line for line in out.splitlines() if "subscription limit:" in line), out
    assert m.read_json(m.AVAIL_FILE, {})["entries"]["codex"]["status"] == "exhausted"
    good(["quota", "clear", "codex"])
    rc, out = run(["run", "codex", "--model", "trace-model", "review"], extra={"FAKE_CODEX":"trace_only_limit"})
    assert rc == 75 and "[QUOTA_EXHAUSTED]" in out, out
    good(["quota", "clear", "codex"])
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
    hid = offered()
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
    good(["handoff", "take", hid])
    assert meta(hid)["branch"] is None and Path(m.load_meta(hid)["workdir"]) == proj, meta(hid)
    clear_tasks()
    hid = offered(write=True)
    task = meta(hid)
    task.update(taken=m.iso(m.now() - dt.timedelta(minutes=11)), assigning="old-token")
    m.save_meta(task)
    assert any(hid in e and "returned to the pool" in e for e in m.check_events())
    branch = "ag/" + hid.lower()
    subprocess.run(["git", "branch", branch], cwd=str(proj), check=True)     # the branch is left from the first try
    good(["handoff", "take", hid])
    assert meta(hid)["branch"] == branch and meta(hid)["workdir"] == ".orchestra/wt/" + hid, meta(hid)
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
out=$($ORCH registry diff); contains "$out" "No personal or project copy: the built-in registry is in effect." "registry diff with no copy names the built-in one"
$ORCH registry show > "$T/registry-shown.yaml" || bad "registry show failed"
reg_checks=$($PY - "$(native "$T/registry-shown.yaml")" <<'EOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
routes = []                      # 2-space keys whose value is an inline list (the routing block)
for line in text.splitlines():
    m = re.match(r"^  ([a-z0-9_]+):\s*\[(.*)\]", line)
    if m:
        routes.append([s.strip() for s in m.group(2).split(",")])
pro = [s for slots in routes for s in slots if s.startswith("deepseek/pro-")]
print("PRO-ROUTE-OK" if routes and not pro else "PRO-ROUTE-BAD %r" % pro)
blocks = re.split(r"\n\s*- id: ", text)      # each slot: its fields up to the next slot
slots = {b.partition("\n")[0].strip(): b.partition("\n")[2] for b in blocks[1:]}
def has(sid, pattern):
    return re.search(pattern, slots.get(sid, ""), re.M) is not None
print("FLASH-MAX-OK" if has("deepseek/flash-max", r"^\s+effort: max$") else "FLASH-MAX-BAD")
print("FLASH-HIGH-D4-OK" if has("deepseek/flash-high", r"^\s+max_difficulty: 4$") else "FLASH-HIGH-D4-BAD")
EOF
)
for k in PRO-ROUTE-OK FLASH-MAX-OK FLASH-HIGH-D4-OK; do
  contains "$reg_checks" "$k" "registry: $k"
done
$ORCH registry init >/dev/null; out=$($ORCH registry path); contains "$out" "$ORCH_HOME/providers.yaml" "user registry overrides default"
marker=$(head -n 1 "$ORCH_HOME/providers.yaml")
marker_re='^# orchestra-registry-base: [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{16}$'
[[ "$marker" =~ $marker_re ]] && ok "registry init writes the base marker" || bad "registry init marker: $marker"
out=$($ORCH status --brief); lacks "$out" "the built-in registry has changed" "fresh registry copy: no warning in status"
out=$($ORCH doctor); lacks "$out" "the built-in registry has changed" "fresh registry copy: no warning in doctor"
out=$($ORCH doctor); ok "doctor runs (rc=$?)"
contains "$out" "DEEPSEEK_API_KEY *set" "doctor sees the DeepSeek key"
contains "$out" "Codex login *Logged in" "doctor checks the codex login"
contains "$out" "✔ Codex CLI" "doctor prints the Codex CLI row the way install.sh greps for it"
# install.sh greps doctor's output: each pattern it greps for must occur in a real doctor table (no drift in the wording)
INSTALL_SH="$PLUGIN/../../install.sh"
cx_pat=$(sed -n "s/^grep -q '\([^']*\)' <<<\"\$DOCTOR\" || warn \"Codex CLI not found.*/\1/p" "$INSTALL_SH")
[[ -n "$cx_pat" ]] && ok "install.sh: the Codex pattern is found ($cx_pat)" || bad "install.sh: Codex pattern not found"
contains "$out" "$cx_pat" "install.sh's Codex pattern occurs in doctor's output"
ds_pat=$(sed -n "s/^grep -q '\([^']*\)' <<<\"\$DOCTOR\" || .*/\1/p" "$INSTALL_SH" | grep -F DEEPSEEK | head -1)
contains "$out" "$ds_pat" "install.sh's DeepSeek pattern occurs in doctor's output"
bash -n "$INSTALL_SH" && ok "install.sh parses" || bad "install.sh has a syntax error"
grep -q 'WindowsApps' "$INSTALL_SH" && ok "install.sh: a Microsoft Store alias is only the last resort" \
  || bad "install.sh does not skip a WindowsApps alias"
grep -q 'exec "%s"' "$INSTALL_SH" && ok "install.sh: the Git Bash launcher names the interpreter's absolute path" \
  || bad "install.sh: the launcher does not hold an absolute interpreter path"
tail_install=$(tail -14 "$INSTALL_SH")
contains "$tail_install" "OFF_PATH == 1" "install.sh: the PATH warning is the last thing it prints"
doctor_paths=$($PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/doctor-paths")" <<'EOF'
import contextlib, importlib.machinery, importlib.util, io, os, shutil, sys
from pathlib import Path
from unittest import mock
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
root = Path(sys.argv[2]); (root / ".local" / "bin").mkdir(parents=True)
# 1. launchers missing: the old hint; present: the folder is off PATH
hint = m.orch_path_hint(root)
print("MISSING-OK" if "install.sh" in hint or "ln -s" in hint else "MISSING-BAD " + hint)
(root / ".local" / "bin" / ("orch.cmd" if m.IS_WINDOWS else "orch")).write_text("x", encoding="utf-8")
hint = m.orch_path_hint(root)
print("PRESENT-OK" if "not on PATH" in hint and "install.sh" not in hint else "PRESENT-BAD " + hint)
# 2. no Codex found: the row is optional ("·"), and it alone does not fail doctor
real_which = shutil.which
def which(name, *a, **k):
    return "/path/to/orch" if name == "orch" else None if name == "codex" else real_which(name, *a, **k)
buf = io.StringIO()
with mock.patch.object(m, "find_codex", lambda: (None, "")), mock.patch("shutil.which", which), \
     contextlib.redirect_stdout(buf):
    rc = m.cmd_doctor(None)
out = buf.getvalue()
row = [l for l in out.splitlines() if "Codex CLI" in l]
print("NOCODEX-ROW-OK" if row and row[0].startswith("·") else "NOCODEX-ROW-BAD %r" % row)
print("NOCODEX-RC-OK" if rc == 0 else "NOCODEX-RC-BAD rc=%s\n%s" % (rc, out))
EOF
)
for k in MISSING-OK PRESENT-OK NOCODEX-ROW-OK NOCODEX-RC-OK; do
  contains "$doctor_paths" "$k" "doctor: $k"
done
# doctor: the Git Bash launcher — a bare python3 that resolves to the Store alias, or an interpreter path that is gone
LH="$T/launcher-home"; mkdir -p "$LH/.local/bin" "$T/win-alias/WindowsApps" "$T/win-real"
: > "$T/win-alias/WindowsApps/python3"; : > "$T/win-alias/WindowsApps/python3.exe"
: > "$T/win-real/python3"; : > "$T/win-real/python3.exe"
chmod +x "$T/win-alias/WindowsApps/python3" "$T/win-alias/WindowsApps/python3.exe" \
  "$T/win-real/python3" "$T/win-real/python3.exe"
PYBIN="$(command -v "$PY")"           # a PATH of our own must not decide which Python runs orch
if command -v cygpath >/dev/null 2>&1; then LH_PROFILE="$(cygpath -w "$LH")"; else LH_PROFILE="$LH"; fi
WPATH="$T/win-alias/WindowsApps"; RPATH="$T/win-real"   # POSIX form: Git Bash converts the whole PATH for a native
                                                         # Python, while a C:\ entry would be split at its colon
printf '#!/bin/sh\nexec python3 "/nowhere/bin/orch" "$@"\n' > "$LH/.local/bin/orch"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" PATH="$WPATH:$PATH" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
contains "$out" "Microsoft Store alias" "doctor: a launcher that runs the Store alias warns"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" PATH="$RPATH:$PATH" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
lacks "$out" "Microsoft Store alias" "doctor: silent when the bare python3 is not an alias"
realpy=$($PY -c 'import sys; print(sys.executable.replace("\\", "/"))')
printf '#!/bin/sh\nexec "%s" "/nowhere/bin/orch" "$@"\n' "$realpy" > "$LH/.local/bin/orch"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
lacks "$out" "orch launcher" "doctor: silent for a launcher with an absolute interpreter path"
printf '#!/bin/sh\nexec "/no/such/python" "/nowhere/bin/orch" "$@"\n' > "$LH/.local/bin/orch"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
contains "$out" "does not exist" "doctor: a launcher whose interpreter is gone warns"

echo "── registry copy staleness"
reg_edit() {      # reg_edit CODE — run CODE with the copy's path as sys.argv[1]
  $PY - "$(native "$ORCH_HOME/providers.yaml")" <<EOF
import sys
p = sys.argv[1]
$1
EOF
}
reg_edit 'lines = open(p, encoding="utf-8").read().splitlines()
lines[0] = "# orchestra-registry-base: 9.9.9 sha256:0000000000000000"
open(p, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")'
out=$($ORCH status --brief); contains "$out" "the built-in registry has changed since this copy was made (9.9.9): orch registry diff" "a stale marker: status warns with the copy's version"
out=$($ORCH doctor); contains "$out" "the built-in registry has changed since this copy was made (9.9.9)" "a stale marker: doctor warns"
reg_pat=$(sed -n "s/.*grep -q '\([^']*\)' <<<\"\$DOCTOR\"; then.*/\1/p" "$PLUGIN/../../install.sh" | head -1)
[[ -n "$reg_pat" ]] && ok "install.sh: the stale-registry pattern is found ($reg_pat)" || bad "install.sh: no stale-registry pattern"
contains "$out" "${reg_pat:-no pattern}" "install.sh's stale-registry pattern occurs in doctor's warning"
reg_edit 'text = open(p, encoding="utf-8").read().replace("version: 1", "version: 2", 1)
open(p, "w", encoding="utf-8", newline="\n").write(text)'
out=$($ORCH registry diff)
contains "$out" "^+version: 2$" "registry diff shows a changed line"
contains "$out" "^--- .*registry/providers.yaml" "registry diff names the built-in file in its header"
contains "$out" "^+++ .*$ORCH_HOME/providers.yaml" "registry diff names the copy in its header"
contains "$out" "This copy overrides the whole built-in registry" "registry diff says what a copy does"
contains "$out" "orch registry diff --accept" "registry diff says how to accept"
$ORCH registry diff --accept >/dev/null
out=$($ORCH status --brief); lacks "$out" "the built-in registry has changed" "accept clears the status warning"
out=$($ORCH doctor); lacks "$out" "the built-in registry has changed" "accept clears the doctor warning"
marker=$(head -n 1 "$ORCH_HOME/providers.yaml")
[[ "$marker" =~ $marker_re ]] && ok "accept writes the current marker" || bad "accept marker: $marker"
# a copy without a marker: equal to the built-in is not stale, a changed one is
cp "$PLUGIN/registry/providers.yaml" "$ORCH_HOME/providers.yaml"
out=$($ORCH status --brief); lacks "$out" "the built-in registry has changed" "an unmarked copy equal to the built-in: no warning in status"
out=$($ORCH doctor); lacks "$out" "the built-in registry has changed" "an unmarked copy equal to the built-in: no warning in doctor"
printf '\n# local change\n' >> "$ORCH_HOME/providers.yaml"
out=$($ORCH status --brief); contains "$out" "the built-in registry has changed since this copy was made (an older version)" "an unmarked copy that differs: status warns"
out=$($ORCH doctor); contains "$out" "the built-in registry has changed since this copy was made (an older version)" "an unmarked copy that differs: doctor warns"
# a project copy takes precedence over the personal one, and over the built-in one
$ORCH registry init --project >/dev/null
out=$($ORCH registry path); contains "$out" "\.orchestra/providers.yaml" "project registry copy takes precedence"
rm -f "$REPO/.orchestra/providers.yaml"
rm -f "$ORCH_HOME/providers.yaml"
out=$($ORCH registry diff); contains "$out" "No personal or project copy: the built-in registry is in effect." "no copy in effect: diff says so"

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
