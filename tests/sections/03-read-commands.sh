echo "── read commands leave an unused folder alone"
FRESH="$T/fresh-git"; mkdir -p "$FRESH" || die "cannot create a fresh repository folder"
git init -q "$FRESH" || die "cannot init a fresh repository"
PLAIN="$T/fresh-plain"; mkdir -p "$PLAIN" || die "cannot create a fresh folder"
for cmd in "status" "profile show" "handoff list" "guide manual" "doctor"; do
  ( cd "$FRESH" && $ORCH $cmd >/dev/null 2>&1 )
  ( cd "$PLAIN" && $ORCH $cmd >/dev/null 2>&1 )
done
[[ -e "$FRESH/.lanewise" ]] && bad "a read in a fresh git folder created .lanewise" || ok "a read in a fresh git folder creates no .lanewise"
[[ -e "$PLAIN/.lanewise" ]] && bad "a read in a folder outside git created .lanewise" || ok "a read in a folder outside git creates no .lanewise"
grep -q ".lanewise/" "$FRESH/.git/info/exclude" 2>/dev/null && bad "a read added the .lanewise/ line to .git/info/exclude" || ok "a read leaves .git/info/exclude alone"
( cd "$FRESH" && $ORCH statusline </dev/null >/dev/null 2>&1 )
( cd "$FRESH" && printf '{}' | $ORCH hook post-tool >/dev/null 2>&1 )
( cd "$FRESH" && printf '{}' | $ORCH hook user-prompt >/dev/null 2>&1 )
[[ -e "$FRESH/.lanewise" ]] && bad "the status line or a hook created .lanewise" || ok "the status line and hooks create no .lanewise in an unused folder"
printf 'x' | ( cd "$PLAIN" && $ORCH handoff offer --title "first here" >/dev/null 2>&1 ); rc=$?
expect_rc 0 $rc "a write command still works in a folder with no state"
[[ -d "$PLAIN/.lanewise/handoffs" ]] && ok "handoff offer creates .lanewise (a write command)" || bad "handoff offer created no state"

