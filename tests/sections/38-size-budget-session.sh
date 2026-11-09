echo "── size budget: session start in a used home"
# standalone setup (a no-op once the earlier sections have run)
SIZES="$(native "$TESTS/check_sizes.py")"
# what every session starts with, measured on a copy of the suite's home as the tests above left it (profiles, limits,
# spend, manual tasks): a copy, so this hook run registers no session in the suite's own home
rm -rf "$T/sizes-home" && cp -R "$ORCH_HOME" "$T/sizes-home" || die "cannot copy the suite's home"
out=$(echo '{}' | ORCH_HOME="$(native "$T/sizes-home")" $ORCH hook session-start | $PY "$SIZES" --output session-start 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "orch hook session-start (a used home) is within its budget: $out" || { bad "orch hook session-start is over its budget"; echo "$out"; }

