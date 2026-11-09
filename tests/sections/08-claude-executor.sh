echo "── claude executor, a non-Claude lead (orch launch)"
# standalone setup (a no-op once the earlier sections have run)
[[ -f "$T/home/secrets.env" ]] || printf '# keys\r\nexport DEEPSEEK_API_KEY="sk-from-file"\r\n' > "$T/home/secrets.env"
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

