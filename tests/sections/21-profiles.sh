# needs: 11-worktree
echo "── profiles"
# standalone setup (a no-op once the earlier sections have run)
[[ -f "$T/home/secrets.env" ]] || printf '# keys\r\nexport DEEPSEEK_API_KEY="sk-from-file"\r\n' > "$T/home/secrets.env"
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
grep -q '"profile": "argon"' "$REPO/.lanewise/handoffs/$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)/meta.json" && \
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
m.session_tokens = lambda sid, path, native, where: {"a@work": {"input": 1, "output": 10}, "B@Work": {"input": 2, "output": 20}}
spend = [("a@work", "Same@work", "est. $1"), ("b@work", "Same@work", "est. $9"), ("c@work", "Same@work", "est. $2")]
out = m.session_status_part("s", None, None, spend)
# "B@Work" sorts before "a@work" (the account key as given), then the spend-only scope c@work
assert out == "Session in/out: Same@work 2/20 (est. $9)\n  Same@work 1/10 (est. $1)\n  Same@work (est. $2)", out
m.session_tokens = lambda sid, path, native, where: {}
assert m.session_status_part("s", None, None, spend) == "Same@work (est. $1)\n  Same@work (est. $9)\n  Same@work (est. $2)", "no tokens: no heading, one line each"
assert m.session_status_part("s", None, None, []) is None, "nothing to show"
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

