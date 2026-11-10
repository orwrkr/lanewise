echo "── migrate .partitura/.orchestra → .lanewise"
# a project that keeps the old folder name still works, and running it creates no .lanewise
MG_OLD="$T/mg-old"; mkdir -p "$MG_OLD" && git -C "$MG_OLD" init -q \
  && git -C "$MG_OLD" config user.email t@t && git -C "$MG_OLD" config user.name t \
  && echo hi > "$MG_OLD/f.txt" && git -C "$MG_OLD" add . && git -C "$MG_OLD" -c commit.gpgsign=false commit -qm init \
  || die "cannot create the old-name fixture"
mkdir -p "$MG_OLD/.orchestra"
out=$(cd "$MG_OLD" && $ORCH status); expect_rc 0 $? "a project that keeps .orchestra: status works"
MG_OID=$(printf 'x' | (cd "$MG_OLD" && $ORCH handoff new --title "old name" --max-open 99) | grep -o 'AG-[0-9]*' | head -1)
[[ -f "$MG_OLD/.orchestra/handoffs/$MG_OID/TASK.md" ]] && ok "handoff new writes under .orchestra" \
  || bad "handoff new did not use the old folder"
(cd "$MG_OLD" && $ORCH handoff cancel "$MG_OID" >/dev/null)
(cd "$MG_OLD" && FAKE_CODEX=ok $ORCH run codex --model gpt-6.1-terra "old name run") >/dev/null; rc=$?
expect_rc 0 $rc "a run in a project that keeps .orchestra"
[[ -d "$MG_OLD/.orchestra/runs" ]] && ok "the run lives in .orchestra/runs" || bad "no run in .orchestra"
[[ -e "$MG_OLD/.lanewise" ]] && bad "a project that keeps .orchestra got a .lanewise folder" \
  || ok "a project that keeps .orchestra gets no .lanewise"
out=$(cd "$MG_OLD" && $ORCH doctor)
contains "$out" "still under the name .orchestra" "doctor hints at the old folder name"
contains "$out" "orch migrate moves it" "doctor says what to do"

# a project that keeps .partitura (the name between 0.35.0 and 0.36.0) moves to .lanewise, stored paths follow
MG_PT="$T/mg-pt"; mkdir -p "$MG_PT" && git -C "$MG_PT" init -q \
  && git -C "$MG_PT" config user.email t@t && git -C "$MG_PT" config user.name t \
  && echo hi > "$MG_PT/f.txt" && git -C "$MG_PT" add . && git -C "$MG_PT" -c commit.gpgsign=false commit -qm init \
  || die "cannot create the .partitura fixture"
mkdir -p "$MG_PT/.partitura"
out=$(cd "$MG_PT" && $ORCH status); expect_rc 0 $? "a project that keeps .partitura: status works"
MG_PTID=$(printf 'x' | (cd "$MG_PT" && $ORCH handoff new --title "partitura name" --write --max-open 99) | grep -o 'AG-[0-9]*' | head -1)
[[ -f "$MG_PT/.partitura/handoffs/$MG_PTID/TASK.md" ]] && ok "handoff new writes under .partitura" \
  || bad "handoff new did not use .partitura"
(cd "$MG_PT" && $ORCH handoff done "$MG_PTID" --note "done before the move" >/dev/null)
[[ -e "$MG_PT/.lanewise" ]] && bad "a project that keeps .partitura got a .lanewise folder" \
  || ok "a project that keeps .partitura gets no .lanewise"
out=$(cd "$MG_PT" && $ORCH doctor)
contains "$out" "still under the name .partitura" "doctor hints at the .partitura folder"
contains "$out" "orch migrate moves it" "doctor says what to do about .partitura"
out=$(cd "$MG_PT" && $ORCH migrate 2>&1); rc=$?
expect_rc 0 $rc "a dry run of a .partitura project exits 0"
contains "$out" "would move .*\.partitura" "the dry run names the move from .partitura"
contains "$out" "replace .partitura/ with .lanewise/" "the dry run names the exclude line from .partitura"
contains "$out" "handoff meta.json" "the dry run names the stored paths of .partitura"
contains "$out" "git worktree(s) to repair" "the dry run names the worktree of .partitura"
[[ -d "$MG_PT/.partitura" && ! -e "$MG_PT/.lanewise" ]] && ok "a .partitura dry run moves nothing" \
  || bad "a .partitura dry run moved the folder"
out=$(cd "$MG_PT" && $ORCH migrate --yes 2>&1); rc=$?
expect_rc 0 $rc "the .partitura project moves"
contains "$out" "moved .*\.partitura → .*\.lanewise" "the .partitura move is reported"
contains "$out" ".partitura/ → .lanewise/" "the exclude line is replaced from .partitura"
[[ -d "$MG_PT/.lanewise" && ! -e "$MG_PT/.partitura" ]] && ok "the .partitura state folder is .lanewise now" \
  || bad "the .partitura state folder did not move"
$PY - "$(native "$MG_PT/.lanewise/handoffs/$MG_PTID/meta.json")" "$MG_PTID" <<'EOF' && ok "a .partitura meta.json names .lanewise" || bad ".partitura meta.json paths were not rewritten"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid = sys.argv[2]
assert m["workdir"] == ".lanewise/wt/" + hid, m["workdir"]
assert m["task_path"] == ".lanewise/handoffs/%s/TASK.md" % hid, m["task_path"]
assert m["result_path"] == ".lanewise/handoffs/%s/RESULT.md" % hid, m["result_path"]
assert ".partitura" not in m["paste"] and ".lanewise/wt/" in m["paste"], m["paste"]
EOF
grep -qx ".lanewise/" "$MG_PT/.git/info/exclude" && ok ".git/info/exclude has .lanewise/ after a .partitura move" \
  || bad "exclude: no .lanewise/ after a .partitura move"
grep -qx ".partitura/" "$MG_PT/.git/info/exclude" && bad "exclude still has .partitura/" \
  || ok "exclude no longer has .partitura/"
out=$(cd "$MG_PT" && $ORCH doctor)
lacks "$out" "still under the name .partitura" "the .partitura doctor hint goes away after the move"

# a project with a closed task, a pooled task, a writing task's worktree with committed work, and a run
MG_P="$T/mg-proj"; mkdir -p "$MG_P" && git -C "$MG_P" init -q \
  && git -C "$MG_P" config user.email t@t && git -C "$MG_P" config user.name t \
  && echo hi > "$MG_P/f.txt" && git -C "$MG_P" add . && git -C "$MG_P" -c commit.gpgsign=false commit -qm init \
  || die "cannot create the migrate fixture"
mkdir -p "$MG_P/.orchestra"
mg() { (cd "$MG_P" && "$@"); }
MG_DONE=$(printf 'x' | mg $ORCH handoff new --title "closed one" --max-open 99 | grep -o 'AG-[0-9]*' | head -1)
mg $ORCH handoff done "$MG_DONE" --note "reviewed" >/dev/null; expect_rc 0 $? "a closed manual task"
MG_POOL=$(printf 'x' | mg $ORCH handoff offer --title "pooled one" --max-offers 99 | grep -o 'AG-[0-9]*' | head -1)
[[ -n "$MG_POOL" ]] && ok "a pooled, untaken task" || bad "no pooled task"
MG_WID=$(printf 'x' | mg $ORCH handoff new --title "writes files" --write --max-open 99 | grep -o 'AG-[0-9]*' | head -1)
echo work > "$MG_P/.orchestra/wt/$MG_WID/w.txt" \
  && git -C "$MG_P/.orchestra/wt/$MG_WID" add w.txt \
  && git -C "$MG_P/.orchestra/wt/$MG_WID" -c commit.gpgsign=false commit -qm work \
  && ok "a writing task's worktree under .orchestra/wt with committed work" || bad "no committed work in the worktree"
mg $ORCH handoff done "$MG_WID" --note "committed" >/dev/null
(cd "$MG_P" && FAKE_CODEX=ok $ORCH run codex --model gpt-6.1-terra "migrate me") >/dev/null; rc=$?
expect_rc 0 $rc "a finished run before the move"

# a dry run is the default and changes nothing
out=$(cd "$MG_P" && $ORCH migrate 2>&1); rc=$?
expect_rc 0 $rc "a dry run of the current project exits 0"
contains "$out" "would move .*\.orchestra" "the dry run names the move"
contains "$out" "replace .orchestra/ with .lanewise/" "the dry run names the exclude line"
contains "$out" "handoff meta.json" "the dry run names the stored paths"
contains "$out" "git worktree(s) to repair" "the dry run names the worktrees"
contains "$out" "Nothing changed: add --yes to move." "the dry run says how to apply"
[[ -d "$MG_P/.orchestra" && ! -e "$MG_P/.lanewise" ]] && ok "a dry run moves nothing" || bad "a dry run moved the folder"
$PY - "$(native "$MG_P/.orchestra/handoffs/$MG_WID/meta.json")" <<'EOF' && ok "a dry run leaves meta.json alone" || bad "a dry run rewrote meta.json"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["workdir"].startswith(".orchestra/wt/") and ".orchestra/" in m["paste"], m
EOF
out=$(ORCH_WORKER=dee-1 $ORCH migrate "$(native "$MG_P")" 2>&1); rc=$?
expect_rc 1 $rc "migrate refuses inside an executor"
contains "$out" "only the orchestrator moves the folders" "the refusal says who moves the folders"

# --yes moves it and points everything stored inside at the new name
out=$(cd "$MG_P" && $ORCH migrate --yes 2>&1); rc=$?
expect_rc 0 $rc "the project moves"
contains "$out" "moved .*\.orchestra → .*\.lanewise" "the move is reported"
contains "$out" ".orchestra/ → .lanewise/" "the exclude line is replaced"
contains "$out" "\.agents/rules/lanewise-task.md: rewritten" "the Antigravity rule is rewritten"
contains "$out" "MANUAL.md: regenerated" "the board is regenerated"
[[ -d "$MG_P/.lanewise" && ! -e "$MG_P/.orchestra" ]] && ok "the state folder is .lanewise now" || bad "the state folder did not move"
$PY - "$(native "$MG_P/.lanewise/handoffs/$MG_WID/meta.json")" "$MG_WID" <<'EOF' && ok "meta.json: stored paths and paste name .lanewise" || bad "meta.json paths were not rewritten"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid = sys.argv[2]
assert m["workdir"] == ".lanewise/wt/" + hid, m["workdir"]
assert m["task_path"] == ".lanewise/handoffs/%s/TASK.md" % hid, m["task_path"]
assert m["result_path"] == ".lanewise/handoffs/%s/RESULT.md" % hid, m["result_path"]
assert ".orchestra" not in m["paste"] and ".lanewise/handoffs/" in m["paste"], m["paste"]
EOF
$PY - "$(native "$MG_P/.lanewise/handoffs/$MG_DONE/meta.json")" <<'EOF' && ok "a closed task's meta.json names .lanewise" || bad "the closed task's meta.json"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["task_path"].startswith(".lanewise/handoffs/"), m
EOF
git -C "$MG_P" worktree list --porcelain | grep -q "\.lanewise/wt/$MG_WID" \
  && ok "git worktree list shows the new path" || bad "git still lists the old worktree path"
git -C "$MG_P/.lanewise/wt/$MG_WID" status --porcelain >/dev/null 2>&1
expect_rc 0 $? "git status works in the moved worktree"
[[ "$(git -C "$MG_P/.lanewise/wt/$MG_WID" log --oneline -1)" == *work* ]] \
  && ok "the committed work is still in the moved worktree" || bad "the committed work is missing"
echo after > "$MG_P/.lanewise/wt/$MG_WID/a.txt" && git -C "$MG_P/.lanewise/wt/$MG_WID" add a.txt \
  && git -C "$MG_P/.lanewise/wt/$MG_WID" -c commit.gpgsign=false commit -qm "after migrate"
expect_rc 0 $? "a commit in the moved worktree"
grep -qx ".lanewise/" "$MG_P/.git/info/exclude" && ok ".git/info/exclude has .lanewise/" || bad "exclude: no .lanewise/"
grep -qx ".orchestra/" "$MG_P/.git/info/exclude" && bad "exclude still has .orchestra/" || ok "exclude no longer has .orchestra/"
grep -q "The task file is \`.lanewise/handoffs/<id>/TASK.md\`" "$MG_P/.agents/rules/lanewise-task.md" \
  && ok "the Antigravity rule names .lanewise" || bad "the Antigravity rule still names the old folder"
grep -q "\.orchestra" "$MG_P/.agents/rules/lanewise-task.md" && bad "the rule also names .orchestra" \
  || ok "the rule names only .lanewise"
out=$(cd "$MG_P" && $ORCH status); contains "$out" "board .lanewise/MANUAL.md" "status names the new board"
out=$(cd "$MG_P" && $ORCH footprint); contains "$out" "project .*\.lanewise" "footprint lists the new state folder"

# skip: a task handed out and not finished would lose its agent's RESULT.md
MG_BLK="$T/mg-blocked"; mkdir -p "$MG_BLK/.orchestra"
MG_BID=$(printf 'x' | (cd "$MG_BLK" && $ORCH handoff new --title "still out" --max-open 99) | grep -o 'AG-[0-9]*' | head -1)
out=$(cd "$MG_BLK" && $ORCH migrate "$(native "$MG_BLK")" --yes 2>&1); rc=$?
expect_rc 1 $rc "a handed-out task blocks the move"
contains "$out" "handed out and not finished" "the skip says why"
contains "$out" "$MG_BID" "the skip names the task"
[[ -d "$MG_BLK/.orchestra" && ! -e "$MG_BLK/.lanewise" ]] && ok "a blocked project is not moved" || bad "a blocked project moved"
$PY - "$(native "$MG_BLK/.orchestra/handoffs/$MG_BID/meta.json")" <<'EOF' && ok "a blocked project keeps its meta.json as it was" || bad "a blocked project changed meta.json"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["task_path"].startswith(".orchestra/handoffs/"), m
EOF

# skip: both folders exist — never merge them
MG_BOTH="$T/mg-both"; mkdir -p "$MG_BOTH/.orchestra" "$MG_BOTH/.lanewise"
printf 'old' > "$MG_BOTH/.orchestra/marker.txt"; printf 'new' > "$MG_BOTH/.lanewise/marker.txt"
out=$(cd "$MG_BOTH" && $ORCH migrate "$(native "$MG_BOTH")" --yes 2>&1); rc=$?
expect_rc 1 $rc "both folders present: reported"
contains "$out" "both \.lanewise/ and \.orchestra/ exist" "the report names both folders"
contains "$out" "nothing was merged" "the report says they are not merged"
[[ "$(cat "$MG_BOTH/.orchestra/marker.txt")" == "old" && "$(cat "$MG_BOTH/.lanewise/marker.txt")" == "new" ]] \
  && ok "both folders are left untouched" || bad "both folders were changed"

# skip: both old folders exist — never merge them (the names before 0.36.0 and before 0.35.0)
MG_OB="$T/mg-old-both"; mkdir -p "$MG_OB/.partitura" "$MG_OB/.orchestra"
printf 'p' > "$MG_OB/.partitura/marker.txt"; printf 'o' > "$MG_OB/.orchestra/marker.txt"
out=$(cd "$MG_OB" && $ORCH migrate "$(native "$MG_OB")" --yes 2>&1); rc=$?
expect_rc 1 $rc "both old folders present: reported"
contains "$out" "both \.partitura/ and \.orchestra/ exist" "the report names both old folders"
contains "$out" "nothing was merged" "the report says the old ones are not merged"
[[ "$(cat "$MG_OB/.partitura/marker.txt")" == "p" && "$(cat "$MG_OB/.orchestra/marker.txt")" == "o" \
   && ! -e "$MG_OB/.lanewise" ]] && ok "both old folders are left untouched" || bad "both old folders were changed"

# the state folder name: .lanewise, then .partitura, then .orchestra; a new project gets .lanewise
MG_RES="$T/mg-resolve"; mkdir -p "$MG_RES"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$MG_RES")" <<'EOF' && ok "the state folder name: .lanewise, then .partitura, then .orchestra" || bad "the state folder resolution order"
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("orch_resolve_state", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
base = Path(sys.argv[2])
assert m.state_dir_name(base) == ".lanewise", m.state_dir_name(base)
for names, want in (([".orchestra"], ".orchestra"), ([".orchestra", ".partitura"], ".partitura"),
                    ([".orchestra", ".partitura", ".lanewise"], ".lanewise")):
    for n in names:
        (base / n).mkdir()
    got = m.state_dir_name(base)
    assert got == want, (names, got)
    for n in names:
        (base / n).rmdir()
EOF

# skip: an orch run whose recorded process is still alive (the rule itself, without spawning one)
MG_LIVE="$T/mg-live"; mkdir -p "$MG_LIVE/.orchestra/runs/mg-live"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$MG_LIVE")" <<'EOF' && ok "a run with a live process blocks the move" || bad "the live-run rule"
import importlib.machinery, importlib.util, json, os, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("orch_migrate_live", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
state = Path(sys.argv[2]) / ".orchestra"
meta = state / "runs" / "mg-live" / "meta.json"
meta.write_text(json.dumps({"id": "mg-live", "finished": None, "pid": os.getpid()}), encoding="utf-8")
blocker = m.project_blocker(state)
assert blocker and "still going" in blocker, blocker
meta.write_text(json.dumps({"id": "mg-live", "finished": "2026-01-01T00:00:00", "pid": os.getpid()}), encoding="utf-8")
assert m.project_blocker(state) is None, m.project_blocker(state)
meta.write_text(json.dumps({"id": "mg-live", "finished": None, "pid": 999999999}), encoding="utf-8")
assert m.project_blocker(state) is None, m.project_blocker(state)
# killed two days ago: its pid may belong to another process by now, so it blocks nothing
old = m.iso(m.now() - m.dt.timedelta(days=2))
meta.write_text(json.dumps({"id": "mg-live", "started": old, "finished": None, "pid": os.getpid()}), encoding="utf-8")
assert m.project_blocker(state) is None, m.project_blocker(state)
recent = m.iso(m.now() - m.dt.timedelta(hours=1))
meta.write_text(json.dumps({"id": "mg-live", "started": recent, "finished": None, "pid": os.getpid()}), encoding="utf-8")
assert "still going" in (m.project_blocker(state) or ""), m.project_blocker(state)
EOF

# --all: the projects the usage ledger and profiles know
MG_ALLHOME="$T/mg-all-home"; MG_ALLP="$T/mg-all-proj"; MG_ALLCWD="$T/mg-all-cwd"
mkdir -p "$MG_ALLHOME" "$MG_ALLP/.orchestra" "$MG_ALLCWD"
printf 'x' | (cd "$MG_ALLP" && ORCH_HOME="$(native "$MG_ALLHOME")" $ORCH handoff offer --title "pooled" --max-offers 99) >/dev/null
$PY - "$(native "$MG_ALLHOME/usage.jsonl")" "$(native "$MG_ALLP")" <<'EOF'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(json.dumps({"kind": "run", "project_path": sys.argv[2], "ts": "2026-01-01T00:00:00"}, ensure_ascii=False) + "\n")
EOF
out=$(cd "$MG_ALLCWD" && ORCH_HOME="$(native "$MG_ALLHOME")" $ORCH migrate --all --yes 2>&1); rc=$?
expect_rc 0 $rc "--all migrates the projects the ledger knows"
contains "$out" "$(native "$MG_ALLP")" "the ledger's project is named"
[[ -d "$MG_ALLP/.lanewise" && ! -e "$MG_ALLP/.orchestra" ]] && ok "the ledger's project moved" || bad "the ledger's project did not move"
contains "$out" "no state folder" "the current folder has nothing to move"

# the personal folder: dry run, a busy lock, then the move with a Codex account inside it
MG_H="$T/mg-home"; mkdir -p "$MG_H/.orchestra/codex-accounts/work"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$MG_H/.orchestra/secrets.env"
MG_NEW="$(native "$MG_H")/.lanewise"
$PY - "$(native "$MG_H/.orchestra/profiles.json")" "$(native "$MG_H/.orchestra/codex-accounts/work")" <<'EOF'
import json, sys
json.dump({"providers": {"codex": {"profiles": {"work": {"home": sys.argv[2]}}}}, "note": "~/.orchestra/old"},
          open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
EOF
out=$(env -u ORCH_HOME HOME="$MG_H" USERPROFILE="$(native "$MG_H")" $ORCH migrate --home 2>&1); rc=$?
expect_rc 0 $rc "a home dry run exits 0"
contains "$out" "would move .*\.orchestra" "the dry run names the home move"
contains "$out" "JSON file(s): paths into the old folder" "the dry run names the stored paths"
contains "$out" "/reload-plugins" "the dry run names the reload"
[[ -d "$MG_H/.orchestra" && ! -e "$MG_H/.lanewise" ]] && ok "a home dry run moves nothing" || bad "a home dry run moved the folder"

MG_B="$T/mg-busy-home"; mkdir -p "$MG_B/.orchestra"
$PY - "$(native "$MG_B/.orchestra/.usage.lock")" "$(native "$T/mg-lock-ready")" "$(native "$T/mg-lock-stop")" \
  >/dev/null 2>&1 <<'EOF' &
import os, sys, time
from pathlib import Path
lock, ready, stop = (Path(p) for p in sys.argv[1:4])
f = open(str(lock), "a+b")
f.seek(0, os.SEEK_END)
if f.tell() == 0:
    f.write(b"\0")
    f.flush()
f.seek(0)
if os.name == "nt":
    import msvcrt
    msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
else:
    import fcntl
    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
ready.write_text("ready", encoding="utf-8")
deadline = time.time() + 30
while time.time() < deadline and not stop.exists():
    time.sleep(0.05)
EOF
MG_HPID=$!
for _ in {1..20}; do [[ -f "$T/mg-lock-ready" ]] && break; sleep 1; done
[[ -f "$T/mg-lock-ready" ]] && ok "the lock holder started" || bad "the lock holder did not start"
out=$(env -u ORCH_HOME HOME="$MG_B" USERPROFILE="$(native "$MG_B")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 1 $rc "a busy home is skipped"
contains "$out" "busy, try again" "the skip says to try again"
[[ -d "$MG_B/.orchestra" && ! -e "$MG_B/.lanewise" ]] && ok "a busy home is not moved" || bad "a busy home was moved"
: > "$T/mg-lock-stop"; wait "$MG_HPID" 2>/dev/null || true

out=$(env -u ORCH_HOME HOME="$MG_H" USERPROFILE="$(native "$MG_H")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 0 $rc "an idle old home moves"
contains "$out" "moved .*\.orchestra → .*\.lanewise" "the home move is reported"
contains "$out" "JSON file(s) now name .lanewise" "the profile's home path is rewritten"
contains "$out" "/reload-plugins" "open sessions are told to reload"
[[ -d "$MG_H/.lanewise" && ! -e "$MG_H/.orchestra" && -f "$MG_H/.lanewise/secrets.env" ]] \
  && ok "the home is .lanewise now, its files moved with it" || bad "the home did not move"
$PY - "$(native "$MG_H/.lanewise/profiles.json")" "$(native "$MG_H/.lanewise/codex-accounts/work")" <<'EOF' && ok "profiles.json: the Codex account folder names .lanewise" || bad "profiles.json still names .orchestra"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["providers"]["codex"]["profiles"]["work"]["home"] == sys.argv[2], data
assert data["note"] == "~/.lanewise/old", data.get("note")
EOF
out=$(env -u ORCH_HOME HOME="$MG_H" USERPROFILE="$(native "$MG_H")" $ORCH footprint 2>&1)
contains "$out" "$MG_NEW — personal data" "orch resolves ~/.lanewise after the move"
out=$(env -u ORCH_HOME HOME="$MG_H" USERPROFILE="$(native "$MG_H")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 0 $rc "a second --home run has nothing to move"
contains "$out" "nothing to move" "…and says so"

# ORCH_HOME decides the home: --home must do nothing
MG_SET="$T/mg-set-home"; mkdir -p "$MG_SET"
out=$(ORCH_HOME="$(native "$MG_SET")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 0 $rc "with ORCH_HOME set, --home does nothing"
contains "$out" "ORCH_HOME is set: it decides the personal folder" "…and says the variable decides"
[[ ! -e "$MG_SET/.lanewise" ]] && ok "…and moves nothing" || bad "a home moved although ORCH_HOME is set"

# the personal folder under its name before 0.36.0: .partitura moves like .orchestra, and its JSON follows
MG_HP="$T/mg-home-pt"; mkdir -p "$MG_HP/.partitura/codex-accounts/work"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$MG_HP/.partitura/secrets.env"
MG_HP_NEW="$(native "$MG_HP")/.lanewise"
$PY - "$(native "$MG_HP/.partitura/profiles.json")" "$(native "$MG_HP/.partitura/codex-accounts/work")" <<'EOF'
import json, sys
json.dump({"providers": {"codex": {"profiles": {"work": {"home": sys.argv[2]}}}}, "note": "~/.partitura/old"},
          open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
EOF
out=$(env -u ORCH_HOME HOME="$MG_HP" USERPROFILE="$(native "$MG_HP")" $ORCH migrate --home 2>&1); rc=$?
expect_rc 0 $rc "a .partitura home dry run exits 0"
contains "$out" "would move .*\.partitura" "the dry run names the .partitura home move"
contains "$out" "JSON file(s): paths into the old folder" "the dry run names the stored paths of .partitura"
[[ -d "$MG_HP/.partitura" && ! -e "$MG_HP/.lanewise" ]] && ok "a .partitura home dry run moves nothing" \
  || bad "a .partitura home dry run moved the folder"
out=$(env -u ORCH_HOME HOME="$MG_HP" USERPROFILE="$(native "$MG_HP")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 0 $rc "an idle .partitura home moves"
contains "$out" "moved .*\.partitura → .*\.lanewise" "the .partitura home move is reported"
contains "$out" "JSON file(s) now name .lanewise" "the profile's home path is rewritten from .partitura"
[[ -d "$MG_HP/.lanewise" && ! -e "$MG_HP/.partitura" && -f "$MG_HP/.lanewise/secrets.env" ]] \
  && ok "the .partitura home is .lanewise now, its files moved with it" || bad "the .partitura home did not move"
$PY - "$(native "$MG_HP/.lanewise/profiles.json")" "$(native "$MG_HP/.lanewise/codex-accounts/work")" <<'EOF' && ok "profiles.json: the Codex account folder names .lanewise after a .partitura move" || bad "profiles.json still names .partitura"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["providers"]["codex"]["profiles"]["work"]["home"] == sys.argv[2], data
assert data["note"] == "~/.lanewise/old", data.get("note")
EOF
out=$(env -u ORCH_HOME HOME="$MG_HP" USERPROFILE="$(native "$MG_HP")" $ORCH footprint 2>&1)
contains "$out" "$MG_HP_NEW — personal data" "orch resolves ~/.lanewise after the .partitura move"

# both old home folders: reported, never merged
MG_HB="$T/mg-home-both"; mkdir -p "$MG_HB/.partitura" "$MG_HB/.orchestra"
printf 'p' > "$MG_HB/.partitura/marker.txt"; printf 'o' > "$MG_HB/.orchestra/marker.txt"
out=$(env -u ORCH_HOME HOME="$MG_HB" USERPROFILE="$(native "$MG_HB")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 1 $rc "both old home folders: reported"
contains "$out" "both \.partitura/ and \.orchestra/ exist" "the home report names both old folders"
contains "$out" "nothing was merged" "the home report says they are not merged"
[[ "$(cat "$MG_HB/.partitura/marker.txt")" == "p" && "$(cat "$MG_HB/.orchestra/marker.txt")" == "o" \
   && ! -e "$MG_HB/.lanewise" ]] && ok "both old home folders are left untouched" || bad "both old home folders were changed"

# the home's own name: .lanewise, then .partitura, then .orchestra
MG_RH="$T/mg-resolve-home"; mkdir -p "$MG_RH/.orchestra" "$MG_RH/.partitura"
out=$(env -u ORCH_HOME HOME="$MG_RH" USERPROFILE="$(native "$MG_RH")" $ORCH footprint 2>&1)
contains "$out" "\.partitura — personal data" "the home: .partitura wins over .orchestra"
[[ ! -e "$MG_RH/.lanewise" ]] && ok "reading a .partitura home creates no .lanewise" \
  || bad "reading a .partitura home created .lanewise"
mkdir -p "$MG_RH/.lanewise"
out=$(env -u ORCH_HOME HOME="$MG_RH" USERPROFILE="$(native "$MG_RH")" $ORCH footprint 2>&1)
contains "$out" "\.lanewise — personal data" "the home: .lanewise wins over the old names"

# profiles in a .partitura home are read there, and no ~/.lanewise appears
MG_PR="$T/mg-profile-home"; mkdir -p "$MG_PR/.partitura"
$PY - "$(native "$MG_PR/.partitura/profiles.json")" <<'EOF'
import json, sys
json.dump({"providers": {"deepseek": {"default": "work", "profiles": {"work": {"key": "DEEPSEEK_API_KEY"}}}}},
          open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
EOF
out=$(env -u ORCH_HOME HOME="$MG_PR" USERPROFILE="$(native "$MG_PR")" $ORCH profile list 2>&1); rc=$?
expect_rc 0 $rc "orch profile list in a .partitura home"
contains "$out" "deepseek (default: work)" "orch reads the profiles from ~/.partitura"
contains "$out" "  work (" "the profile itself is read from ~/.partitura"
[[ ! -e "$MG_PR/.lanewise" ]] && ok "reading ~/.partitura creates no ~/.lanewise" \
  || bad "reading ~/.partitura created ~/.lanewise"
out=$(env -u ORCH_HOME HOME="$MG_PR" USERPROFILE="$(native "$MG_PR")" $ORCH profile show 2>&1)
contains "$out" "\.partitura/profiles\.json" "profile show names ~/.partitura/profiles.json"

# the launcher's code cache and interpreter cache follow the old home, and create no ~/.lanewise
MG_LC="$T/mg-launch-cache"; mkdir -p "$MG_LC/.partitura"
TAG=$($PY -c 'import sys; print(sys.implementation.cache_tag or "")')
env -u ORCH_HOME HOME="$MG_LC" USERPROFILE="$(native "$MG_LC")" sh "$PLUGIN/bin/orch" --help >/dev/null 2>&1
expect_rc 0 $? "the launcher runs with a .partitura home"
ls "$MG_LC/.partitura"/.hook-python-* >/dev/null 2>&1 && ok "the launcher's interpreter cache is in ~/.partitura" \
  || bad "no interpreter cache under ~/.partitura"
[[ -f "$MG_LC/.partitura/.pycache/orch_core.$TAG.bin" ]] && ok "the launcher's code cache is in ~/.partitura/.pycache" \
  || bad "no code cache under ~/.partitura/.pycache"
[[ ! -e "$MG_LC/.lanewise" ]] && ok "the launcher creates no ~/.lanewise" || bad "the launcher created ~/.lanewise"

# hooks/run.sh's interpreter cache follows the old home too
MG_HK="$T/mg-hook-cache"; mkdir -p "$MG_HK/.partitura"
echo '{}' | env -u ORCH_HOME HOME="$MG_HK" USERPROFILE="$(native "$MG_HK")" sh "$PLUGIN/hooks/run.sh" session-start \
  >/dev/null 2>&1
expect_rc 0 $? "hooks/run.sh runs with a .partitura home"
ls "$MG_HK/.partitura"/.hook-python-* >/dev/null 2>&1 && ok "hooks/run.sh's interpreter cache is in ~/.partitura" \
  || bad "hooks/run.sh did not cache its interpreter under ~/.partitura"
[[ ! -e "$MG_HK/.lanewise" ]] && ok "hooks/run.sh creates no ~/.lanewise" || bad "hooks/run.sh created ~/.lanewise"

# the doctor hint goes away once the project is migrated
out=$(cd "$MG_OLD" && $ORCH migrate --yes 2>&1); rc=$?
expect_rc 0 $rc "the old-name project migrates"
[[ -d "$MG_OLD/.lanewise" && ! -e "$MG_OLD/.orchestra" ]] && ok "the old-name project is moved" || bad "the old-name project did not move"
out=$(cd "$MG_OLD" && $ORCH doctor)
lacks "$out" "still under the name .orchestra" "the doctor hint goes away after the move"
