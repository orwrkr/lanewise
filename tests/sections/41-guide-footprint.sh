echo "── guide, footprint, plugin wiring"
# standalone setup (a no-op once the earlier sections have run)
mkdir -p "$REPO/.orchestra"
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
contains "$out" "claude plugin uninstall partitura@partitura " "footprint shows the standard uninstall"
grep -q '"SessionEnd"' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd hook registered" || bad "SessionEnd hook missing"
grep -q 'run.sh\\" session-end' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd → orch hook session-end" || bad "session-end wiring"

