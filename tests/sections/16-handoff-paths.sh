echo "── handoff paths: relative on disk, absolute in output, move-safe"
out=$(printf 'task' | $ORCH handoff new --title "paths" --max-open 99); HID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
$PY - "$(native "$REPO/.lanewise/handoffs/$HID/meta.json")" "$HID" <<'EOF' && ok "meta.json stores paths relative to the project root" || bad "meta.json has absolute paths"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid = sys.argv[2]
assert m["workdir"] == "." and m["task_path"] == ".lanewise/handoffs/%s/TASK.md" % hid, m
assert m["result_path"] == ".lanewise/handoffs/%s/RESULT.md" % hid, m
EOF
out=$($ORCH handoff show "$HID")
contains "$out" "$(native "$REPO")/.lanewise/handoffs/$HID/RESULT.md" "show prints the absolute result path"
$PY - "$(native "$REPO/.lanewise/MANUAL.md")" "$(native "$REPO")" <<'EOF' && ok "board shows the absolute folder" || bad "board folder not absolute"
import sys
text = open(sys.argv[1], encoding="utf-8").read().replace("\\", "/")
proj = sys.argv[2].replace("\\", "/").rstrip("/")
assert ("folder: `" + proj + "`") in text, text
EOF
# a task of an older version keeps its worktree as a sibling path, relative on disk
out=$(printf 'x' | $ORCH handoff offer --title "wt rel" --max-offers 99); WID=$(grep -o 'AG-[0-9]*' <<<"$out" | head -1)
$ORCH handoff take "$WID" --max-open 99 >/dev/null
git -C "$REPO" worktree add -q -b "ag/old-$WID" "$T/proj.wt/$WID" || die "cannot create the old-task worktree"
$PY - "$(native "$REPO/.lanewise/handoffs/$WID/meta.json")" "$(native "$T/proj.wt/$WID")" "$WID" <<'EOF'
import json, sys
p, wt, hid = sys.argv[1:4]
m = json.load(open(p, encoding="utf-8"))
m.update(worktree=True, workdir=wt, branch="ag/old-" + hid, task_path=wt + "/.orchestra/handoffs/%s/TASK.md" % hid,
         result_path=wt + "/.orchestra/handoffs/%s/RESULT.md" % hid)
json.dump(m, open(p, "w", encoding="utf-8"))
EOF
$ORCH handoff done "$WID" --note "saved once" >/dev/null
$PY - "$(native "$REPO/.lanewise/handoffs/$WID/meta.json")" "$WID" <<'EOF' && ok "an older worktree task keeps a relative sibling path" || bad "worktree path not relative"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid = sys.argv[2]
assert m["workdir"] == "../proj.wt/" + hid, m["workdir"]
assert m["result_path"] == "../proj.wt/%s/.orchestra/handoffs/%s/RESULT.md" % (hid, hid), m["result_path"]
EOF
mkdir -p "$REPO/sub"
out=$(cd "$REPO/sub" && $ORCH handoff list); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "$HID" "list works from a subdirectory" || bad "list from subdirectory: rc=$rc"
out=$(cd "$REPO/sub" && $ORCH handoff show "$HID")
contains "$out" "$(native "$REPO")/.lanewise/handoffs/$HID/RESULT.md" "show from a subdirectory prints the absolute path"
$ORCH handoff cancel "$HID" >/dev/null; $ORCH handoff cancel "$WID" >/dev/null

# a taken task whose project folder was moved still works; a RESULT.md at the new place is detected
MV="$T/mvproj"; mkdir -p "$MV" && cd "$MV" || die "mv repo"
git init -q && git config user.email t@t && git config user.name t
echo hi > f.txt && git add . && git commit -qm init
MA=$(printf 'task' | $ORCH handoff new --title "moved A" --max-open 99 | grep -o 'AG-[0-9]*' | head -1)
MB=$(printf 'task' | $ORCH handoff new --title "moved B" --max-open 99 | grep -o 'AG-[0-9]*' | head -1)
cd "$REPO" || die "back from mv repo"
MV2="$T/mvproj-new"; mv "$MV" "$MV2" && cd "$MV2" || die "enter moved repo"
out=$($ORCH handoff list); contains "$out" "$MA" "list after the project folder moved"
contains "$out" "$MB" "list after the move names the second task"
out=$($ORCH status); contains "$out" "Open manual tasks" "status after the move"
printf 'STATUS: DONE\nmoved result\n' > "$MV2/.lanewise/handoffs/$MA/RESULT.md"
out=$($ORCH handoff check); contains "$out" "$MA finished: STATUS DONE" "RESULT.md at the new place is detected"
out=$($ORCH handoff done "$MB" --note "marked after the move"); contains "$out" "DONE" "done after the move"
out=$($ORCH handoff show "$MB"); contains "$out" "DONE" "show after the move"
cd "$REPO" || die "back from moved repo"

