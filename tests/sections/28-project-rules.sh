# needs: 27-fallback-profile 11-worktree
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
contains "$out" "Claude Opus 5.5 · 5h 20% (≈[0-9]*[0-9]%) → .* · week 50% .*surplus" "prefer for with budget: the status line says surplus"
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
contains "$out" "^Session in/out: .*" "on the fallback: the session in/out heading carries the first counter"
contains "$out" "^  DeepSeek@sy (fallback: DeepSeek@sx at its limit; est. \$0.00/\$5)" "on the fallback: the note and the estimate get an account line of their own"
grep -q "^  DeepSeek@sy" <<<"$out" && ok "on the fallback: with session tokens the note is indented under the counters" \
  || bad "on the fallback: with session tokens the note is not under the counters"
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
contains "$out" "^  DeepSeek@sy 100/10 (fallback: DeepSeek@sx at its limit; est. \$4.5[0-9]/\$5, account \$9.75)\$" \
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

