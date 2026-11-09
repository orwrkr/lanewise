echo "── launcher run as a program: finds its own Python"
# The plugin's bin/ is on the Bash tool's PATH; there `python3` may be missing or broken (Windows: only `python`, or
# the Store alias). Started as a program, bin/orch searches like hooks/run.sh and caches the interpreter that passed.
$PY -W error -c "import sys; compile(open(sys.argv[1], encoding='utf-8').read(), 'orch', 'exec')" "$(native "$PLUGIN/bin/orch")" \
  && ok "bin/orch compiles without warnings (no backslash escapes in its shell part)" || bad "bin/orch compiles with warnings"
[[ "$(head -n 1 "$PLUGIN/bin/orch")" == "#!/bin/sh" ]] && ok "bin/orch starts as a shell script" || bad "bin/orch has another first line"
lp_real=$($PY -c 'import sys; print(sys.executable.replace(chr(92), "/"))')
lp_ost=$(/bin/sh -c 'printf %s "${OSTYPE:-posix}"')
lp_home="$(native "$T/lp-home")"
lp_bin="$T/lp-stubs"; lp_mark="$T/lp-python-used"
mkdir -p "$lp_bin"
printf '#!/bin/sh\nexit 1\n' > "$lp_bin/python3"
printf '#!/bin/sh\necho used >> "%s"\nexec "%s" "$@"\n' "$lp_mark" "$lp_real" > "$lp_bin/python"
chmod +x "$lp_bin/python3" "$lp_bin/python"
out=$(PATH="$lp_bin:$PATH" ORCH_HOME="$lp_home" /bin/sh "$PLUGIN/bin/orch" --help 2>&1); rc=$?
expect_rc 0 $rc "bin/orch run by sh with a broken python3 first on PATH"
contains "$out" "usage: orch" "…runs orch on the next interpreter"
[[ -f "$lp_mark" ]] && ok "…which is the python after the broken python3" || bad "the python stub was not used"
[[ "$(cat "$lp_home/.hook-python-$lp_ost" 2>/dev/null)" == "$lp_real" ]] && ok "…and is cached for the platform ($lp_ost)" \
  || bad "the interpreter was not cached: $(cat "$lp_home/.hook-python-$lp_ost" 2>&1)"
rm -f "$lp_mark"
PATH="$lp_bin:$PATH" ORCH_HOME="$lp_home" "$PLUGIN/bin/orch" --help >/dev/null 2>&1; rc=$?
expect_rc 0 $rc "bin/orch started directly (its shebang) from the cache"
[[ -e "$lp_mark" ]] && bad "the cached interpreter was ignored: the search ran again" || ok "…without searching again"
lp_none="$T/lp-none"; mkdir -p "$lp_none"
for p in python3 python py; do printf '#!/bin/sh\nexit 1\n' > "$lp_none/$p"; chmod +x "$lp_none/$p"; done
out=$(PATH="$lp_none" ORCH_HOME="$(native "$T/lp-home-none")" /bin/sh "$PLUGIN/bin/orch" --help 2>&1); rc=$?
expect_rc 127 $rc "bin/orch with no working Python and no cache"
contains "$out" "no Python 3.8+ found" "…says so"

