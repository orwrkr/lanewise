echo "── test runner (section list and selection)"
RT="$TESTS/run_tests.sh"
out=$(bash "$RT" --list 2>&1); rc=$?
expect_rc 0 $rc "--list succeeds"
missing=""
for f in "$TESTS"/sections/[0-9][0-9]-*.sh; do
  n="${f##*/}"; n="${n%.sh}"
  case "$out" in *"$n  "*) ;; *) missing="$missing $n" ;; esac
done
[[ -z "$missing" ]] && ok "--list names every section file" || bad "--list misses:$missing"
out=$(bash "$RT" no-such-section 2>&1); rc=$?
expect_rc 2 $rc "an unknown selector exits 2"
contains "$out" "no section matches 'no-such-section'" "an unknown selector says so"
out=$(bash "$RT" 'zz-*' 2>&1); expect_rc 2 $? "a glob that matches nothing exits 2"
out=$(bash "$RT" session 2>&1); rc=$?
expect_rc 2 $rc "an ambiguous prefix exits 2"
contains "$out" "session-tokens-cache" "an ambiguous prefix lists its matches"
# a section file without its title line is flagged, by every kind of run
RTD="$T/runner-copy"; mkdir -p "$RTD/sections" && cp "$RT" "$RTD/run_tests.sh" && printf 'echo hi\n' > "$RTD/sections/01-no-title.sh"
out=$(bash "$RTD/run_tests.sh" --list 2>&1); rc=$?
expect_rc 2 $rc "a section file without the title line fails the runner"
contains "$out" "01-no-title" "and the runner names the file"
printf '# needs: 99-gone\necho "── x"\n' > "$RTD/sections/01-no-title.sh"
out=$(bash "$RTD/run_tests.sh" 1 2>&1); expect_rc 2 $? "a needs line naming no section exits 2"
rm -rf "$RTD"
