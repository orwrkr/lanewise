echo "── registry copy staleness"
# standalone setup (a no-op once the earlier sections have run): a personal copy of the registry, as `registry init` makes it
[[ -f "$ORCH_HOME/providers.yaml" ]] || $ORCH registry init >/dev/null
marker_re='^# orchestra-registry-base: [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{16}$'
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

