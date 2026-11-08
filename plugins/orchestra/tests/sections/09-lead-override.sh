echo "── a lead started without orch launch (its own ANTHROPIC_* override)"
# standalone setup (a no-op once the earlier sections have run)
mkdir -p "$T/claude-cfg"
LEADH="$(native "$T/lead-home")"; mkdir -p "$LEADH"
ORCH_HOME="$LEADH" $ORCH profile set deepseek work --key DEEPSEEK_API_KEY_WORK >/dev/null
printf 'DEEPSEEK_API_KEY_WORK=sk-fake-work\n' > "$LEADH/secrets.env"
# lead <cmd…>: a session whose own override points at DeepSeek, as a hand-started one would
lead() { env ORCH_HOME="$LEADH" ANTHROPIC_BASE_URL="${LBASE:-https://api.deepseek.com/anthropic}" \
             ANTHROPIC_AUTH_TOKEN="${LTOKEN:-sk-fake-work}" ANTHROPIC_MODEL="${LMODEL:-deepseek-v4-pro}" "$@"; }
out=$(lead $ORCH status)
contains "$out" "Lead: DeepSeek@work · DeepSeek V4 Pro (detected: ANTHROPIC_BASE_URL)" \
  "status: the override makes a lead, named by the profile whose key it is"
out=$(printf '{"session_id":"s-detected","cwd":"%s"}' "$(native "$REPO")" | lead $ORCH hook session-start)
contains "$out" "Lead: DeepSeek@work · DeepSeek V4 Pro (detected: ANTHROPIC_BASE_URL)" \
  "session-start: a detected lead is told who it is"
$PY - "$LEADH" <<'EOF' && ok "session-start records the detected lead in sessions.json" || bad "sessions.json: no detected lead"
import json, os, sys
d = json.load(open(os.path.join(sys.argv[1], "sessions.json"), encoding="utf-8"))
assert d["s-detected"]["lead"] == "deepseek@work", d
EOF
out=$(lead $ORCH doctor </dev/null)
contains "$out" "DeepSeek@work · DeepSeek V4 Pro (detected: ANTHROPIC_BASE_URL)" "doctor: the lead row says how it was seen"
out=$(lead $ORCH key claude 2>&1); rc=$?
expect_rc 1 $rc "orch key claude refuses under a detected lead"
contains "$out" "non-Claude lead may not read the Claude API key" "the refusal explains itself"
out=$(LTOKEN=sk-none-of-them lead $ORCH status)
contains "$out" "Lead: DeepSeek · DeepSeek V4 Pro (detected: ANTHROPIC_BASE_URL)" "a token none of the keys matches: the bare provider"
contains "$out" "none of your profiles' keys" "…and the note that spend is not under a profile's limit"
out=$(LBASE=https://api.anthropic.com lead $ORCH status); lacks "$out" "Lead:" "Anthropic itself is not a lead"
out=$(LBASE=https://gateway.example/anthropic lead $ORCH status); lacks "$out" "Lead:" "another proxy is not a lead"
out=$(FAKE_CLAUDE=ok lead $ORCH run claude --model haiku "x" 2>&1); rc=$?
expect_rc 0 $rc "orch run claude under a detected lead"
check 'e["ANTHROPIC_BASE_URL"] is None and e["ANTHROPIC_AUTH_TOKEN"] is None and e["ANTHROPIC_MODEL"] is None' \
  "a detected lead's endpoint, token and model never reach the Claude worker"
out=$(ORCH_HOME="$LEADH" ORCH_LEAD=deepseek@work ORCH_LEAD_MODEL=deepseek-v4-pro \
      ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic ANTHROPIC_AUTH_TOKEN=sk-fake-work $ORCH status)
contains "$out" "Lead: DeepSeek@work · DeepSeek V4 Pro (orch launch)" "an existing ORCH_LEAD keeps its (orch launch) wording"
lacks "$out" "detected: ANTHROPIC_BASE_URL" "…and is not re-detected"
UC="$(native "$T/lead-user-cfg")"; mkdir -p "$UC"
printf '{"env": {"ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic"}}\n' > "$UC/settings.json"
rm -f "$FAKE_CLAUDE_LOG"
out=$(CLAUDE_CONFIG_DIR="$UC" FAKE_CLAUDE=ok lead $ORCH run claude "x" 2>&1); rc=$?
expect_rc 1 $rc "orch run claude under user settings that move the endpoint fails before starting"
contains "$out" "set env.ANTHROPIC_BASE_URL to https://api.deepseek.com/anthropic" "the report names the setting"
[[ -e "$FAKE_CLAUDE_LOG" ]] && bad "the Claude worker started despite the user settings" \
  || ok "no worker was started"
printf '{"env": {"ANTHROPIC_BASE_URL": "https://gateway.example/anthropic", "ANTHROPIC_MODEL": "claude-sonnet-5-5"}}\n' > "$UC/settings.json"
out=$(CLAUDE_CONFIG_DIR="$UC" FAKE_CLAUDE=ok lead $ORCH run claude "x" 2>&1); rc=$?
expect_rc 0 $rc "user settings with a gateway to Claude leave orch run claude alone"
printf '{"env": {"ANTHROPIC_MODEL": "deepseek-v4-pro"}}\n' > "$UC/settings.json"
out=$(CLAUDE_CONFIG_DIR="$UC" FAKE_CLAUDE=ok lead $ORCH run claude "x" 2>&1); rc=$?
expect_rc 1 $rc "user settings with a non-Claude model block orch run claude"
contains "$out" "set env.ANTHROPIC_MODEL to deepseek-v4-pro .*ask for that model" "that report names the model setting"
unset -f lead

