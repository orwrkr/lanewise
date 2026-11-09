# needs: 24-codex-limits
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

