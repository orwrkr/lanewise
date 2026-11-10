echo "── manual tasks: read-only in the project folder, writing ones in a worktree inside it"
MP="$T/mt-proj"; mkdir -p "$MP" && git -C "$MP" init -q && git -C "$MP" config user.email t@t && git -C "$MP" config user.name t \
  && echo hi > "$MP/f.txt" && git -C "$MP" add . && git -C "$MP" -c commit.gpgsign=false commit -qm init || die "cannot create the manual-task fixture"
NMP="$(native "$MP")"     # orch prints native paths, and contains() compares them with forward slashes
mt() { (cd "$MP" && "$@"); }
mt_id() { grep -o 'AG-[0-9]*' <<<"$1" | head -1; }
mt_meta() { $PY -c 'import json, sys; m = json.load(open(sys.argv[1], encoding="utf-8")); print(m.get(sys.argv[2]))' "$(native "$MP/.lanewise/handoffs/$1/meta.json")" "$2"; }
mt_cancel_all() {
  for h in $(mt $ORCH handoff list --json | $PY -c "import json, sys; print(' '.join(m['id'] for m in json.load(sys.stdin)))"); do
    mt $ORCH handoff cancel "$h" >/dev/null
  done
}

# --worktree is gone, --base goes only with --write (a session that has not reloaded may still pass the old flags)
out=$(printf 'x' | mt $ORCH handoff offer --title "wt" --worktree 2>&1); rc=$?
expect_rc 1 $rc "offer --worktree fails"
contains "$out" "orch: --worktree is gone: a task that changes files takes --write" "offer --worktree: the line names --write"
contains "$out" "see orch guide manual" "offer --worktree: the line points to the guide"
out=$(printf 'x' | mt $ORCH handoff new --title "wt" --worktree 2>&1); rc=$?
expect_rc 1 $rc "new --worktree fails"
contains "$out" "--worktree is gone: a task that changes files takes --write" "new --worktree: the same line"
out=$(printf 'x' | mt $ORCH handoff offer --title "wt" --base main 2>&1); rc=$?
expect_rc 1 $rc "offer --base without --write fails"
contains "$out" "--base goes only with --write" "offer --base: the line says so"
out=$(printf 'x' | mt $ORCH handoff new --title "wt" --base main 2>&1); rc=$?
expect_rc 1 $rc "new --base without --write fails"
[[ -z "$(mt $ORCH handoff list --all | grep ' wt · ')" ]] && ok "a refused flag leaves no task behind" || bad "a refused flag left a task"
for sub in offer new; do
  out=$(mt $ORCH handoff $sub --help)
  lacks "$out" "--worktree" "handoff $sub --help no longer offers --worktree"
  contains "$out" "--write" "handoff $sub --help offers --write"
  contains "$out" "--base" "handoff $sub --help offers --base (with --write)"
done

# a read-only task (the default) in the project folder
out=$(printf '## Goal\nlook\n' | mt $ORCH handoff new --title "read one" --model "Gemini 3.8 Flash" --max-open 99); R1=$(mt_id "$out")
contains "$out" "In Antigravity, in the project folder: $NMP" "taken: the card says the project folder"
lacks "$out" "Open in" "taken: no 'Open in' line"
lacks "$out" "It works in" "a read-only task has no worktree line"
lacks "$out" "Branch:" "taken: no branch line"
[[ "$(mt_meta "$R1" write)" == "False" && "$(mt_meta "$R1" branch)" == "None" && "$(mt_meta "$R1" workdir)" == "." ]] \
  && ok "meta: write false, no branch, workdir is the project" || bad "meta of a read-only task"
[[ -d "$T/mt-proj.wt" || -d "$MP/.lanewise/wt" ]] && bad "a read-only task made a worktree folder" || ok "no worktree folder for a read-only task"
RP="Execute the task described in .lanewise/handoffs/$R1/TASK.md, by the execution protocol at the end of that file (RESULT.md status markers). Run no shell commands unless the task lists them. If your file tools can't open .lanewise/ because git ignores it, don't use the terminal to get around that: say so in the chat and stop."
[[ "$(mt_meta "$R1" paste)" == "$RP" ]] && ok "read-only paste line: exact text, one line" || bad "read-only paste line: $(mt_meta "$R1" paste)"
[[ $(mt_meta "$R1" paste | wc -l) -eq 1 ]] && ok "the paste line is one line" || bad "the paste line spans lines"
TK="$MP/.lanewise/handoffs/$R1/TASK.md"
grep -q "This task changes nothing: change no file except \`.lanewise/handoffs/$R1/RESULT.md\`, and do not commit. Other work goes on in this$" "$TK" \
  && ok "read-only protocol: changes nothing, other work goes on in this folder" || bad "read-only protocol step 2"
grep -q "Run no shell commands unless this task lists them" "$TK" && ok "read-only protocol: no shell commands" || bad "read-only protocol step 3"
grep -q "with your file editor, with two lines" "$TK" && grep -q "Gemini 3.8 Flash>" "$TK" && ok "read-only protocol: RESULT.md created with the file editor" || bad "read-only protocol step 1"
grep -q '## Summary` (your findings)' "$TK" && ok "read-only protocol: findings, no changed files" || bad "read-only report sections"
grep -q "Changed files" "$TK" && bad "read-only protocol asks for changed files" || ok "read-only protocol has no Changed files section"
contains "$(cat "$TK")" "^- Working folder: \`$NMP\`" "TASK.md header keeps the working folder"
grep -q "Branch" "$TK" && bad "a read-only TASK.md names a branch" || ok "a read-only TASK.md has no branch line"
contains "$(cat "$MP/.lanewise/MANUAL.md")" "in the project folder: \`$NMP\`" "the board follows the card"

# one general rule file, not one per task
RULE="$MP/.agents/rules/lanewise-task.md"
[[ -f "$RULE" ]] && grep -q "trigger: always_on" "$RULE" && ok "Antigravity rule written into the project folder" || bad "rule missing"
grep -q "This applies only when a message names a Lanewise task (an id such as AG-0004); other conversations ignore it." "$RULE" \
  && grep -q "The task file is \`.lanewise/handoffs/<id>/TASK.md\`" "$RULE" && ok "the rule is general: it names no task" || bad "rule text"
grep -q "A task that changes files names its own worktree: work only inside it." "$RULE" && ok "the rule tells a writing task to stay in its worktree" || bad "rule: worktree line"
grep -q "$R1" "$RULE" && bad "the rule names the first task" || ok "the rule does not name the task that wrote it"
grep -q "^.agents/rules/lanewise-task.md$" "$MP/.git/info/exclude" && ok "the rule is excluded from git" || bad "rule not excluded"
RULE_SUM=$(cksum < "$RULE")
out=$(printf 'x' | mt $ORCH handoff new --title "read two" --max-open 99); R2=$(mt_id "$out")
[[ "$(cksum < "$RULE")" == "$RULE_SUM" && $(ls "$MP/.agents/rules" | wc -l) -eq 1 ]] && ok "two open tasks share the one rule file" || bad "rule changed or multiplied"
echo "stale" > "$RULE"
printf 'old rule\n' > "$MP/.agents/rules/partitura-task.md"      # the rule's name before 0.36.0
printf 'old rule\n' > "$MP/.agents/rules/orchestra-task.md"      # …and before 0.34.0
printf 'x' | mt $ORCH handoff new --title "read three" --max-open 99 >/dev/null
[[ "$(cksum < "$RULE")" == "$RULE_SUM" ]] && ok "a different rule file is rewritten at the next assignment" || bad "rule not restored"
[[ ! -e "$MP/.agents/rules/partitura-task.md" && ! -e "$MP/.agents/rules/orchestra-task.md" ]] \
  && ok "the rules under their names before 0.36.0 and 0.34.0 go away" \
  || bad "an old rule file is left beside the new one"

# a read-only task starts with its RESULT.md only: a file touched in the project after the take starts nothing
sleep 2; echo "other work" >> "$MP/f.txt"
out=$(mt $ORCH handoff list); contains "$out" "$R1 *WAITING" "a file touched after the take: still WAITING"
lacks "$out" "STARTED?" "a file touched in the project never shows STARTED?"
out=$(mt $ORCH handoff check); lacks "$out" "STARTED" "check: no start from someone else's edit"
printf 'x' | mt $ORCH handoff new --title "read, dirty tree" --max-open 99 >/dev/null; expect_rc 0 $? "a read-only task on a dirty tree is handed out"

# a writing task: a worktree of its own inside the project folder, whatever the state of the project folder
out=$(printf '## Goal\nchange\n' | mt $ORCH handoff offer --title "write offer" --write --max-offers 99); OW=$(mt_id "$out")
expect_rc 0 $? "a writing task can be offered"
contains "$out" "(changes files, in its own worktree)" "the pool card says a writing task changes files in its own worktree"
lacks "$out" "(own worktree)" "the pool card no longer uses the old wording"
contains "$out" "you then get the line to paste" "the pool card says what the take gives"
contains "$(cat "$MP/.lanewise/MANUAL.md")" "(changes files, in its own worktree)" "the board marks a writing task in the pool"
[[ -e "$MP/.lanewise/wt/$OW" ]] && bad "a worktree before the take" || ok "no worktree until the task is taken"
out=$(mt $ORCH handoff take "$OW" --max-open 99); rc=$?
expect_rc 0 $rc "a writing task is taken while the project folder is dirty"
BR1="ag/$(tr 'A-Z' 'a-z' <<<"$OW")"
contains "$out" "In Antigravity, in the project folder: $NMP" "writing card: the agent's window stays on the project folder"
contains "$out" "It works in: .lanewise/wt/$OW (its own worktree, branch $BR1); no need to open it" "writing card: says where the task works"
lacks "$out" "Open in" "writing card: no 'Open in' line"
[[ -f "$MP/.lanewise/wt/$OW/f.txt" && "$(git -C "$MP/.lanewise/wt/$OW" rev-parse --abbrev-ref HEAD)" == "$BR1" ]] \
  && ok "the worktree is .lanewise/wt/<id> on branch ag/<id>" || bad "worktree layout"
[[ "$(cat "$MP/.lanewise/wt/$OW/f.txt")" == "hi" ]] && ok "the worktree starts from HEAD, not from the dirty project folder" || bad "worktree content"
[[ -f "$MP/.lanewise/handoffs/$OW/TASK.md" && ! -e "$MP/.lanewise/wt/$OW/.lanewise" ]] && ok "TASK.md stays in the project's handoffs folder" || bad "TASK.md location"
$PY - "$(native "$MP/.lanewise/handoffs/$OW/meta.json")" "$OW" "$BR1" <<'EOF' && ok "meta: workdir is the worktree, task and result paths are the project's" || bad "writing meta"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid, br = sys.argv[2], sys.argv[3]
assert m["write"] is True and m["branch"] == br, m
assert m["workdir"] == ".lanewise/wt/" + hid, m["workdir"]
assert m["task_path"] == ".lanewise/handoffs/%s/TASK.md" % hid and m["result_path"] == ".lanewise/handoffs/%s/RESULT.md" % hid, m
EOF
WP="Execute the task described in .lanewise/handoffs/$OW/TASK.md, by the execution protocol at the end of that file (RESULT.md status markers). Work only inside .lanewise/wt/$OW, a separate git worktree. If your file tools can't open .lanewise/ because git ignores it, don't use the terminal to get around that: say so in the chat and stop."
[[ "$(mt_meta "$OW" paste)" == "$WP" ]] && ok "writing paste line: exact text, one line" || bad "writing paste line: $(mt_meta "$OW" paste)"
[[ $(mt_meta "$OW" paste | wc -l) -eq 1 ]] && ok "the writing paste line is one line" || bad "the writing paste line spans lines"
TW="$MP/.lanewise/handoffs/$OW/TASK.md"
grep -q "Work only inside \`.lanewise/wt/$OW\`, a separate git worktree on branch \`$BR1\`" "$TW" && ok "writing protocol: work only inside the worktree" || bad "writing protocol step 2"
grep -q "never its same-named original at the project root" "$TW" && ok "writing protocol: not the original at the project root" || bad "writing protocol: same-named original"
grep -q "install dependencies as the project instructions say; do not copy secrets" "$TW" && ok "writing protocol: dependencies, no secrets" || bad "writing protocol: dependencies"
grep -q "Do not commit and do not switch branches: the orchestrator reviews the changes in that worktree and commits them." "$TW" && ok "writing protocol: the orchestrator commits" || bad "writing protocol: commit rule"
grep -q '## Changed files' "$TW" && ok "writing protocol keeps the Changed files section" || bad "writing protocol: Changed files"
grep -q "Run no shell commands" "$TW" && bad "the writing protocol forbids commands" || ok "the writing protocol does not forbid commands"
grep -q "^- Branch: \`$BR1\`" "$TW" && ok "TASK.md header names the branch of a writing task" || bad "TASK.md branch line"
# the project's git status does not see the nested worktree, with .lanewise/ ignored through .git/info/exclude
[[ "$(git -C "$MP" status --porcelain)" == " M f.txt" ]] && ok "the project's git status shows only its own edit, not the nested worktree" || bad "git status: $(git -C "$MP" status --porcelain)"
git -C "$MP" worktree list | grep -q "wt/$OW" && ok "git knows the nested worktree" || bad "git worktree list"

# two writing tasks open at once with a dirty project folder
out=$(printf 'x' | mt $ORCH handoff new --title "write two" --write --max-open 99); rc=$?
expect_rc 0 $rc "a second writing task beside the first, on a dirty folder"
OW2=$(mt_id "$out"); BR2="ag/$(tr 'A-Z' 'a-z' <<<"$OW2")"
[[ -d "$MP/.lanewise/wt/$OW2" && "$(git -C "$MP/.lanewise/wt/$OW2" rev-parse --abbrev-ref HEAD)" == "$BR2" && "$BR1" != "$BR2" ]] \
  && ok "each writing task has its own worktree and branch" || bad "second worktree"
lacks "$out" "HANDOFF" "no HANDOFF_DIRTY or HANDOFF_WRITE_BUSY any more"
[[ "$(git -C "$MP" status --porcelain)" == " M f.txt" ]] && ok "two nested worktrees stay out of the project's git status" || bad "git status: $(git -C "$MP" status --porcelain)"
grep -rq "HANDOFF_DIRTY\|HANDOFF_WRITE_BUSY" "$PLUGIN/lib/orch_core" "$PLUGIN/skills" "$PLUGIN/README.md" && bad "the removed guards are still mentioned" || ok "the removed guards are gone from code and docs"

# a start in a worktree is seen by the folder scan; the project folder's edits are not the task's
sleep 2; echo "agent edit" >> "$MP/.lanewise/wt/$OW/f.txt"
out=$(mt $ORCH handoff list); contains "$out" "$OW *STARTED?" "a file changed in the task's worktree shows STARTED?"
contains "$out" "$OW2 *WAITING" "the other writing task, untouched, is still WAITING"
# RESULT.md is detected in the project's handoffs folder
printf 'STATUS: DONE\nAGENT: Antigravity · Gemini 3.8 Flash\n## Summary\nok\n## Changed files\nf.txt\n' > "$MP/.lanewise/handoffs/$OW/RESULT.md"
out=$(mt $ORCH handoff check); contains "$out" "$OW finished: STATUS DONE" "RESULT.md in the project's handoffs folder is detected for a writing task"
[[ "$(git -C "$MP/.lanewise/wt/$OW" diff --stat | wc -l)" -ge 1 ]] && ok "the agent's change is in the worktree, ready to review" || bad "worktree diff"
[[ "$(git -C "$MP" status --porcelain)" == " M f.txt" ]] && ! grep -q "agent edit" "$MP/f.txt" && ok "the project folder got no stray edit from the agent" || bad "project folder changed"

# --base: the worktree starts from another ref
git -C "$MP" stash -q; git -C "$MP" checkout -q -b side && echo "side" > "$MP/side.txt" && git -C "$MP" add side.txt && git -C "$MP" -c commit.gpgsign=false commit -qm side && git -C "$MP" checkout -q - && git -C "$MP" stash pop -q
out=$(printf 'x' | mt $ORCH handoff new --title "based" --write --base side --max-open 99); rc=$?
expect_rc 0 $rc "new --write --base"
[[ -f "$MP/.lanewise/wt/$(mt_id "$out")/side.txt" ]] && ok "--base: the worktree starts from that ref" || bad "--base content"
out=$(printf 'x' | mt $ORCH handoff new --title "bad base" --write --base no-such-ref --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "an unknown --base fails" || bad "unknown base accepted"

# something at the task's worktree path must really be that worktree: inside a plain folder git answers for the project
out=$(printf 'x' | mt $ORCH handoff offer --title "plain folder" --write --max-offers 99); PF=$(mt_id "$out")
mkdir -p "$MP/.lanewise/wt/$PF"
out=$(mt $ORCH handoff take "$PF" --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a plain folder at the worktree path is refused" || bad "a plain folder taken for a worktree"
contains "$out" "is not a working git worktree" "the refusal says what is wrong with the folder"
contains "$(mt $ORCH handoff list)" "$PF *OFFERED" "the task stays in the pool after that refusal"
rmdir "$MP/.lanewise/wt/$PF"
out=$(mt $ORCH handoff take "$PF" --max-open 99); expect_rc 0 $? "taken once the plain folder is gone"
[[ "$(git -C "$MP/.lanewise/wt/$PF" rev-parse --show-toplevel)" != "$(git -C "$MP" rev-parse --show-toplevel)" ]] && ok "then it is a worktree of its own" || bad "still the project's tree"
out=$(printf 'x' | mt $ORCH handoff offer --title "wrong branch" --write --max-offers 99); WB=$(mt_id "$out")
git -C "$MP" worktree add -q -b "wrong-$WB" "$MP/.lanewise/wt/$WB" HEAD
out=$(mt $ORCH handoff take "$WB" --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a worktree on another branch is refused" || bad "a worktree on another branch was accepted"
contains "$out" "is on branch wrong-$WB" "the refusal names the branch it found"
git -C "$MP" worktree remove --force "$MP/.lanewise/wt/$WB"
out=$($ORCH worktree add feat-x); contains "$out" "orch/feat-x" "orch worktree add on an existing worktree reports its branch"
mkdir -p "$T/proj.wt/plain-x"
out=$($ORCH worktree add plain-x 2>&1); rc=$?
[[ $rc -ne 0 ]] && contains "$out" "is not a working git worktree" "orch worktree add refuses a plain folder too" || bad "orch worktree add took a plain folder: $out"
rmdir "$T/proj.wt/plain-x"

# a failure after the worktree was made leaves it on record: a later take reuses it, close can remove it
[[ -e "$MP/.agents" ]] && mv "$MP/.agents" "$MP/.agents.saved"
printf 'x' > "$MP/.agents"                 # the Antigravity rule can't be written now
out=$(printf 'x' | mt $ORCH handoff offer --title "fails after the worktree" --write --max-offers 99); FA=$(mt_id "$out")
out=$(mt $ORCH handoff take "$FA" --max-open 99 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a take fails when the rule can't be written" || bad "the take went through"
contains "$(mt $ORCH handoff list)" "$FA *OFFERED" "after the failure the task is back in the pool"
[[ "$(mt_meta "$FA" branch)" == "ag/$(tr 'A-Z' 'a-z' <<<"$FA")" && -d "$MP/.lanewise/wt/$FA" ]] && ok "the worktree it left stays on record" || bad "unrecorded worktree: $(mt_meta "$FA" branch)"
printf 'x' | mt $ORCH handoff new --title "fails, direct" --write --max-open 99 >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "new fails when the rule can't be written" || bad "new went through"
FN=$(basename "$(ls -d "$MP"/.lanewise/handoffs/AG-* | sort | tail -1)")
contains "$(mt_meta "$FN" manual_note)" "close $FN --remove-worktree" "a failed new says how to remove the worktree it left"
out=$(mt $ORCH handoff close "$FN" --remove-worktree); contains "$out" "worktree removed" "close removes the worktree a failed new left"
[[ -d "$MP/.lanewise/wt/$FN" ]] && bad "the failed task's worktree is still there" || ok "the failed task's worktree is gone"
rm -f "$MP/.agents"; [[ -e "$MP/.agents.saved" ]] && mv "$MP/.agents.saved" "$MP/.agents"
out=$(mt $ORCH handoff take "$FA" --max-open 99); expect_rc 0 $? "a later take reuses the worktree"
contains "$out" "It works in: .lanewise/wt/$FA" "the card of the retaken task says where it works"

# close --remove-worktree is the normal end of a writing task
mt $ORCH handoff done "$OW" --note "reviewed" >/dev/null
out=$(mt $ORCH handoff close "$OW" --remove-worktree --force); contains "$out" "worktree removed" "close --remove-worktree removes a writing task's worktree"
[[ -d "$MP/.lanewise/wt/$OW" ]] && bad "the worktree is still there" || ok "the nested worktree is gone"
git -C "$MP" worktree list | grep -q "wt/$OW" && bad "git still lists it" || ok "git no longer lists it"
out=$(mt $ORCH handoff close "$R1" --remove-worktree); contains "$out" "nothing to remove" "close --remove-worktree on a read-only task says there is nothing to remove"

# an old meta with no write field made no promise: it counts as writing and gets a nested worktree at the take
mt_cancel_all
git -C "$MP" worktree prune
git -C "$MP" checkout -q -- f.txt
out=$(printf 'x' | mt $ORCH handoff offer --title "old offer" --max-offers 99); OO=$(mt_id "$out")
$PY - "$(native "$MP/.lanewise/handoffs/$OO/meta.json")" <<'EOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8")); m.pop("write", None); m.update(worktree=True, base="HEAD"); json.dump(m, open(p, "w", encoding="utf-8"))
EOF
contains "$(mt $ORCH handoff show "$OO")" "(changes files, in its own worktree)" "an old offered task is shown as changing files"
out=$(mt $ORCH handoff take "$OO" --max-open 99); expect_rc 0 $? "an old offered task is taken"
contains "$out" "It works in: .lanewise/wt/$OO" "it gets a nested worktree"
[[ -d "$MP/.lanewise/wt/$OO" && "$(mt_meta "$OO" branch)" != "None" ]] && ok "worktree and branch exist for it" || bad "an old offer got no worktree"
mt $ORCH handoff cancel "$OO" >/dev/null

# a task taken by an older version keeps working: its worktree next to the project, from a hand-edited meta
out=$(printf 'x' | mt $ORCH handoff new --title "taken long ago" --max-open 99); OT=$(mt_id "$out")
OTW="$T/mt-proj.wt/$OT"
git -C "$MP" worktree add -q -b "ag/old-$OT" "$OTW" || die "cannot create the old-task worktree"
mkdir -p "$OTW/.orchestra/handoffs/$OT"; cp "$MP/.lanewise/handoffs/$OT/TASK.md" "$OTW/.orchestra/handoffs/$OT/TASK.md"
rm -f "$MP/.lanewise/handoffs/$OT/RESULT.md"
$PY - "$(native "$MP/.lanewise/handoffs/$OT/meta.json")" "$(native "$OTW")" "$OT" <<'EOF'
import json, sys, time
p, wt, hid = sys.argv[1:4]
m = json.load(open(p, encoding="utf-8"))
m.pop("write", None)
m.update(worktree=True, base="HEAD", workdir=wt, branch="ag/old-" + hid, activity_baseline=time.time(),
         task_path=wt + "/.orchestra/handoffs/%s/TASK.md" % hid, result_path=wt + "/.orchestra/handoffs/%s/RESULT.md" % hid)
json.dump(m, open(p, "w", encoding="utf-8"))
EOF
out=$(mt $ORCH handoff show "$OT"); contains "$out" "Open in Antigravity: .*mt-proj.wt/$OT" "an older task: the card still says where its worktree is"
contains "$out" "Branch: ag/old-$OT" "an older task: the card names its branch"
lacks "$out" "It works in" "an older task: no nested-worktree line"
contains "$(mt $ORCH handoff list)" "$OT *WAITING" "an older task: listed, waiting"
sleep 2; echo "edit in the old worktree" >> "$OTW/f.txt"
contains "$(mt $ORCH handoff list)" "$OT *STARTED?" "an older task: the folder scan still shows STARTED?"
printf 'STATUS: DONE\nAGENT: Antigravity · Gemini 3.8 Flash\n## Summary\nold\n' > "$OTW/.orchestra/handoffs/$OT/RESULT.md"
out=$(mt $ORCH handoff check); contains "$out" "$OT finished: STATUS DONE" "an older task: its RESULT.md is still detected"
$PY - "$(native "$MP/.lanewise/handoffs/$OT/meta.json")" "$OT" <<'EOF' && ok "an older task: paths stay relative on disk after a save" || bad "an older task: meta paths"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["workdir"] == "../mt-proj.wt/" + sys.argv[2], m["workdir"]
EOF
mt $ORCH handoff done "$OT" --note "ok" >/dev/null
out=$(mt $ORCH handoff close "$OT" --remove-worktree --force); contains "$out" "worktree removed" "close --remove-worktree still removes an older task's worktree"
[[ -d "$OTW" ]] && bad "the old worktree is still there" || ok "the old worktree is gone"
git -C "$MP" worktree prune; git -C "$MP" branch -D "ag/old-$OT" >/dev/null 2>&1

# `orch worktree` for automated executors is untouched: it still lives in <project>.wt/
out=$(mt $ORCH worktree add mt-feat); contains "$out" "mt-proj.wt/mt-feat" "orch worktree still works, next to the project"
mt_cancel_all

# the nested worktree stays out of git status when .lanewise/ is ignored through .gitignore as well
MP2="$T/mt-proj2"; mkdir -p "$MP2" && git -C "$MP2" init -q && git -C "$MP2" config user.email t@t && git -C "$MP2" config user.name t \
  && printf '.lanewise/\n' > "$MP2/.gitignore" && echo hi > "$MP2/f.txt" && git -C "$MP2" add . && git -C "$MP2" -c commit.gpgsign=false commit -qm init || die "cannot create the second fixture"
out=$(printf 'x' | (cd "$MP2" && $ORCH handoff new --title "gitignore" --write --provider cursor --max-open 99)); rc=$?
expect_rc 0 $rc "a writing task in a project that ignores .lanewise/ through .gitignore"
: > "$MP2/.git/info/exclude"
[[ -z "$(git -C "$MP2" status --porcelain)" ]] && ok "ignored through .gitignore alone: git status is clean with the nested worktree" || bad "gitignore status: $(git -C "$MP2" status --porcelain)"

# --write needs a git repository; a read-only task works anywhere
NG="$T/mt-nogit"; mkdir -p "$NG"
ng() { (cd "$NG" && "$@"); }
out=$(printf 'x' | ng $ORCH handoff new --title "no git, read" --max-open 99); rc=$?
expect_rc 0 $rc "a read-only task outside git"
contains "$out" "In Antigravity, in the project folder:" "no git: the card is the same"
out=$(printf 'x' | ng $ORCH handoff new --title "no git, write" --write --max-open 99 2>&1); rc=$?
expect_rc 1 $rc "new --write outside git is refused"
contains "$out" "--write needs a git repository" "new --write outside git: a clear line"
out=$(printf 'x' | ng $ORCH handoff offer --title "no git, write offer" --write 2>&1); rc=$?
expect_rc 1 $rc "offer --write outside git is refused"
contains "$out" "give the task read-only" "offer --write outside git: says what to do"
out=$(printf 'x' | ng $ORCH handoff offer --title "no git, offered" --max-offers 99); NGO=$(mt_id "$out")
ng $ORCH handoff take "$NGO" --max-open 99 >/dev/null; expect_rc 0 $? "outside git: offer and take (read-only)"
[[ -f "$NG/.lanewise/handoffs/$NGO/TASK.md" && -f "$NG/.agents/rules/lanewise-task.md" ]] && ok "outside git: TASK.md and the rule are written" || bad "outside git: files missing"
[[ -e "$NG/.git" ]] && bad "orch created a repository" || ok "outside git: nothing creates a repository"
out=$(printf 'x' | ng $ORCH handoff offer --title "no git, old" --max-offers 99); NGW=$(mt_id "$out")
$PY - "$(native "$NG/.lanewise/handoffs/$NGW/meta.json")" <<'EOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8")); m.pop("write", None); json.dump(m, open(p, "w", encoding="utf-8"))
EOF
out=$(ng $ORCH handoff take "$NGW" --max-open 99); rc=$?
expect_rc 1 $rc "an old writing offer cannot be taken outside git"
contains "$out" "needs a git repository for its worktree" "and the line says why"
contains "$(ng $ORCH handoff list)" "$NGW *OFFERED" "it stays in the pool"
printf 'STATUS: DONE\nok\n' > "$NG/.lanewise/handoffs/$NGO/RESULT.md"
out=$(ng $ORCH handoff check); contains "$out" "$NGO finished: STATUS DONE" "outside git: completion detected"
out=$(ng $ORCH footprint); contains "$out" ".agents/rules/lanewise-task.md" "footprint names the general Antigravity rule"
contains "$out" "git worktree prune" "footprint tells what to do about worktree entries if .lanewise/ is deleted by hand"
contains "$out" "project .*: \.lanewise, \.agents/rules/lanewise-task.md" "footprint names the project's own paths relative to it"
grep -q "lanewise-task.md" "$PLUGIN/../../uninstall.sh" && ok "uninstall.sh names the rule" || bad "uninstall.sh does not name the rule"
grep -q "git worktree prune" "$PLUGIN/../../uninstall.sh" && ok "uninstall.sh mentions git worktree prune" || bad "uninstall.sh: prune"
grep -q "Yours to remove: the clone folder" "$PLUGIN/../../uninstall.sh" && ok "uninstall.sh: the clone folder and a PATH line you added are yours to remove" || bad "uninstall.sh: no line about the clone folder"
grep -q "lanewise-task.md" "$PLUGIN/README.md" && ok "README names the rule among what the plugin leaves behind" || bad "README: rule missing"
grep -q "effort High --worktree\|always \`--worktree\`" "$PLUGIN/skills/orchestrate/reference/manual.md" && bad "manual.md still offers --worktree" || ok "manual.md no longer offers --worktree"
grep -q "\[--worktree\]" "$PLUGIN/registry/providers.yaml" && bad "the registry still offers --worktree" || ok "the registry no longer offers --worktree"
cd "$REPO" || die "back from the manual-task fixtures"

