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
check '"WebFetch" not in a[a.index("--tools") + 1] and not any(x.startswith("WebFetch") for x in r["allowed"])' "tool_policy: without a WebFetch rule the worker has no web tool"
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
FAKE_CLAUDE=ok DEEPSEEK_API_KEY=sk-env $ORCH run deepseek --model deepseek-flash --effort none   --allow 'WebFetch(domain:api-docs.deepseek.com)' "read a price page" >/dev/null; rc=$?
expect_rc 0 $rc "deepseek analysis run with a WebFetch rule"
check '"WebFetch" in a[a.index("--tools") + 1].split(",") and "WebFetch(domain:api-docs.deepseek.com)" in r["allowed"] and "Edit" not in a[a.index("--tools") + 1]' "tool_policy: an allowed WebFetch rule adds the WebFetch tool (analysis)"
FAKE_CLAUDE=ok DEEPSEEK_API_KEY=sk-env $ORCH run deepseek --model deepseek-flash --effort none --mode write   --allow 'WebFetch(domain:api-docs.deepseek.com)' "read a price page and write" >/dev/null; rc=$?
expect_rc 0 $rc "deepseek write run with a WebFetch rule"
check '"WebFetch" in a[a.index("--tools") + 1].split(",") and "Edit" in a[a.index("--tools") + 1].split(",")' "tool_policy: an allowed WebFetch rule adds the WebFetch tool (write)"
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
# 12–15 minutes left: a busy machine can spend a couple of minutes between the run and this check
out=$($ORCH quota show); contains "$out" "deepseek .*exhausted .*in 1[2-5]m" "rate limit blocks for 15 minutes"
$ORCH quota clear deepseek >/dev/null
out=$(FAKE_CLAUDE=401 $ORCH run deepseek "x"); rc=$?
expect_rc 1 $rc "401 bad key → failure"
contains "$out" "rejected the key (401)" "bad key explained"
FAKE_CLAUDE=quota-text $ORCH run deepseek "x" >/dev/null; rc=$?
expect_rc 1 $rc "worker failure passes through"
$ORCH quota check deepseek >/dev/null; expect_rc 0 $? "limit words in worker output do not block deepseek"
rm -f "$REPO/CLAUDE.md"

