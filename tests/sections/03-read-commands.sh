echo "── read commands leave an unused folder alone"
FRESH="$T/fresh-git"; mkdir -p "$FRESH" || die "cannot create a fresh repository folder"
git init -q "$FRESH" || die "cannot init a fresh repository"
PLAIN="$T/fresh-plain"; mkdir -p "$PLAIN" || die "cannot create a fresh folder"
for cmd in "status" "profile show" "handoff list" "guide manual" "doctor"; do
  ( cd "$FRESH" && $ORCH $cmd >/dev/null 2>&1 )
  ( cd "$PLAIN" && $ORCH $cmd >/dev/null 2>&1 )
done
[[ -e "$FRESH/.partitura" ]] && bad "a read in a fresh git folder created .partitura" || ok "a read in a fresh git folder creates no .partitura"
[[ -e "$PLAIN/.partitura" ]] && bad "a read in a folder outside git created .partitura" || ok "a read in a folder outside git creates no .partitura"
grep -q ".partitura/" "$FRESH/.git/info/exclude" 2>/dev/null && bad "a read added the .partitura/ line to .git/info/exclude" || ok "a read leaves .git/info/exclude alone"
( cd "$FRESH" && $ORCH statusline </dev/null >/dev/null 2>&1 )
( cd "$FRESH" && printf '{}' | $ORCH hook post-tool >/dev/null 2>&1 )
( cd "$FRESH" && printf '{}' | $ORCH hook user-prompt >/dev/null 2>&1 )
[[ -e "$FRESH/.partitura" ]] && bad "the status line or a hook created .partitura" || ok "the status line and hooks create no .partitura in an unused folder"
printf 'x' | ( cd "$PLAIN" && $ORCH handoff offer --title "first here" >/dev/null 2>&1 ); rc=$?
expect_rc 0 $rc "a write command still works in a folder with no state"
[[ -d "$PLAIN/.partitura/handoffs" ]] && ok "handoff offer creates .partitura (a write command)" || bad "handoff offer created no state"

