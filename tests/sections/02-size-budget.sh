echo "── size budget (what the plugin puts into a session)"
# standalone setup (a no-op once the earlier sections have run)
ROOT_REPO="$(cd "$PLUGIN/../.." && pwd)"
SIZES="$(native "$TESTS/check_sizes.py")"
out=$($PY "$SIZES" --root "$(native "$ROOT_REPO")" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "the repository is within its size budgets" || { bad "a size budget is exceeded"; echo "$out"; }
SZ="$T/sizes-tree"; mkdir -p "$SZ/plugins/orchestra" || die "cannot create the size-budget tree"
cp -R "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/commands" "$SZ/plugins/orchestra/" && cp "$ROOT_REPO/AGENTS.md" "$ROOT_REPO/CLAUDE.md" "$SZ/" \
  || die "cannot copy the budgeted files"
out=$($PY "$SIZES" --root "$(native "$SZ")" 2>&1); expect_rc 0 $? "a copy of the budgeted files passes"
contains "$out" "skills/orchestrate/SKILL.md: [0-9]* / [0-9]* tokens" "check_sizes prints a line for every budget"
$PY -c "print('x' * 40000)" >> "$SZ/plugins/orchestra/skills/orchestrate/SKILL.md"
out=$($PY "$SIZES" --root "$(native "$SZ")" 2>&1); rc=$?
expect_rc 1 $rc "a budgeted file padded past its budget fails"
contains "$out" "skills/orchestrate/SKILL.md: [0-9]* tokens, over its budget of [0-9]*: move rarely needed text to skills/orchestrate/reference/ (orch guide), or raise the budget in tests/check_sizes.py and say why in the commit message" "the over-budget message says what to do"
cp "$PLUGIN/skills/orchestrate/SKILL.md" "$SZ/plugins/orchestra/skills/orchestrate/SKILL.md"
$PY -c "print('x' * 4000)" >> "$SZ/plugins/orchestra/agents/orch-haiku-low.md"
out=$($PY "$SIZES" --root "$(native "$SZ")" 2>&1); rc=$?
expect_rc 1 $rc "an executor agent padded past the per-file budget fails"
contains "$out" "agents/orch-haiku-low.md: [0-9]* tokens, over its budget" "the message names the agent file"
cp "$PLUGIN/agents/orch-haiku-low.md" "$SZ/plugins/orchestra/agents/orch-haiku-low.md"
printf -- '---\nname: x\ndescription: %s\n---\n' "$($PY -c "print('y' * 5000)")" > "$SZ/plugins/orchestra/commands/run.md"
out=$($PY "$SIZES" --root "$(native "$SZ")" 2>&1); rc=$?
expect_rc 1 $rc "descriptions past the always-on budget fail"
contains "$out" "always-on descriptions: [0-9]* tokens, over its budget" "the message names the always-on budget"
out=$($PY "$SIZES" --root "$(native "$T/no-such-tree")" 2>&1); expect_rc 2 $? "check_sizes on a tree with no files is a usage error"
out=$($PY "$SIZES" --output nosuch </dev/null 2>&1); expect_rc 2 $? "check_sizes with an unknown output name is a usage error"
out=$($PY -c "print('x' * 40000)" | $PY "$SIZES" --output registry-brief 2>&1); rc=$?
expect_rc 1 $rc "an output past its budget fails"
contains "$out" "registry-brief: [0-9]* tokens, over its budget of [0-9]*" "the over-budget message names the output"
out=$(printf 'short' | $PY "$SIZES" --output session-start 2>&1); expect_rc 0 $? "a short output passes"
out=$($ORCH registry show | $PY "$SIZES" --output registry-brief 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "orch registry show (built-in registry) is within its budget: $out" || { bad "orch registry show is over its budget"; echo "$out"; }
# orch hook session-start is measured near the end, where the suite's home holds profiles, limits and manual tasks

