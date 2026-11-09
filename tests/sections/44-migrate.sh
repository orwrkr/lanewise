echo "── migrate .orchestra → .partitura"
# a project that keeps the old folder name still works, and running it creates no .partitura
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
[[ -e "$MG_OLD/.partitura" ]] && bad "a project that keeps .orchestra got a .partitura folder" \
  || ok "a project that keeps .orchestra gets no .partitura"
out=$(cd "$MG_OLD" && $ORCH doctor)
contains "$out" "still under the name .orchestra" "doctor hints at the old folder name"
contains "$out" "orch migrate moves it" "doctor says what to do"

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
contains "$out" "replace .orchestra/ with .partitura/" "the dry run names the exclude line"
contains "$out" "handoff meta.json" "the dry run names the stored paths"
contains "$out" "git worktree(s) to repair" "the dry run names the worktrees"
contains "$out" "Nothing changed: add --yes to move." "the dry run says how to apply"
[[ -d "$MG_P/.orchestra" && ! -e "$MG_P/.partitura" ]] && ok "a dry run moves nothing" || bad "a dry run moved the folder"
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
contains "$out" "moved .*\.orchestra → .*\.partitura" "the move is reported"
contains "$out" ".orchestra/ → .partitura/" "the exclude line is replaced"
contains "$out" "\.agents/rules/partitura-task.md: rewritten" "the Antigravity rule is rewritten"
contains "$out" "MANUAL.md: regenerated" "the board is regenerated"
[[ -d "$MG_P/.partitura" && ! -e "$MG_P/.orchestra" ]] && ok "the state folder is .partitura now" || bad "the state folder did not move"
$PY - "$(native "$MG_P/.partitura/handoffs/$MG_WID/meta.json")" "$MG_WID" <<'EOF' && ok "meta.json: stored paths and paste name .partitura" || bad "meta.json paths were not rewritten"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); hid = sys.argv[2]
assert m["workdir"] == ".partitura/wt/" + hid, m["workdir"]
assert m["task_path"] == ".partitura/handoffs/%s/TASK.md" % hid, m["task_path"]
assert m["result_path"] == ".partitura/handoffs/%s/RESULT.md" % hid, m["result_path"]
assert ".orchestra" not in m["paste"] and ".partitura/handoffs/" in m["paste"], m["paste"]
EOF
$PY - "$(native "$MG_P/.partitura/handoffs/$MG_DONE/meta.json")" <<'EOF' && ok "a closed task's meta.json names .partitura" || bad "the closed task's meta.json"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["task_path"].startswith(".partitura/handoffs/"), m
EOF
git -C "$MG_P" worktree list --porcelain | grep -q "\.partitura/wt/$MG_WID" \
  && ok "git worktree list shows the new path" || bad "git still lists the old worktree path"
git -C "$MG_P/.partitura/wt/$MG_WID" status --porcelain >/dev/null 2>&1
expect_rc 0 $? "git status works in the moved worktree"
[[ "$(git -C "$MG_P/.partitura/wt/$MG_WID" log --oneline -1)" == *work* ]] \
  && ok "the committed work is still in the moved worktree" || bad "the committed work is missing"
echo after > "$MG_P/.partitura/wt/$MG_WID/a.txt" && git -C "$MG_P/.partitura/wt/$MG_WID" add a.txt \
  && git -C "$MG_P/.partitura/wt/$MG_WID" -c commit.gpgsign=false commit -qm "after migrate"
expect_rc 0 $? "a commit in the moved worktree"
grep -qx ".partitura/" "$MG_P/.git/info/exclude" && ok ".git/info/exclude has .partitura/" || bad "exclude: no .partitura/"
grep -qx ".orchestra/" "$MG_P/.git/info/exclude" && bad "exclude still has .orchestra/" || ok "exclude no longer has .orchestra/"
grep -q "The task file is \`.partitura/handoffs/<id>/TASK.md\`" "$MG_P/.agents/rules/partitura-task.md" \
  && ok "the Antigravity rule names .partitura" || bad "the Antigravity rule still names the old folder"
grep -q "\.orchestra" "$MG_P/.agents/rules/partitura-task.md" && bad "the rule also names .orchestra" \
  || ok "the rule names only .partitura"
out=$(cd "$MG_P" && $ORCH status); contains "$out" "board .partitura/MANUAL.md" "status names the new board"
out=$(cd "$MG_P" && $ORCH footprint); contains "$out" "project .*\.partitura" "footprint lists the new state folder"

# skip: a task handed out and not finished would lose its agent's RESULT.md
MG_BLK="$T/mg-blocked"; mkdir -p "$MG_BLK/.orchestra"
MG_BID=$(printf 'x' | (cd "$MG_BLK" && $ORCH handoff new --title "still out" --max-open 99) | grep -o 'AG-[0-9]*' | head -1)
out=$(cd "$MG_BLK" && $ORCH migrate "$(native "$MG_BLK")" --yes 2>&1); rc=$?
expect_rc 1 $rc "a handed-out task blocks the move"
contains "$out" "handed out and not finished" "the skip says why"
contains "$out" "$MG_BID" "the skip names the task"
[[ -d "$MG_BLK/.orchestra" && ! -e "$MG_BLK/.partitura" ]] && ok "a blocked project is not moved" || bad "a blocked project moved"
$PY - "$(native "$MG_BLK/.orchestra/handoffs/$MG_BID/meta.json")" <<'EOF' && ok "a blocked project keeps its meta.json as it was" || bad "a blocked project changed meta.json"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["task_path"].startswith(".orchestra/handoffs/"), m
EOF

# skip: both folders exist — never merge them
MG_BOTH="$T/mg-both"; mkdir -p "$MG_BOTH/.orchestra" "$MG_BOTH/.partitura"
printf 'old' > "$MG_BOTH/.orchestra/marker.txt"; printf 'new' > "$MG_BOTH/.partitura/marker.txt"
out=$(cd "$MG_BOTH" && $ORCH migrate "$(native "$MG_BOTH")" --yes 2>&1); rc=$?
expect_rc 1 $rc "both folders present: reported"
contains "$out" "both \.orchestra/ and \.partitura/ exist" "the report names both folders"
contains "$out" "nothing was merged" "the report says they are not merged"
[[ "$(cat "$MG_BOTH/.orchestra/marker.txt")" == "old" && "$(cat "$MG_BOTH/.partitura/marker.txt")" == "new" ]] \
  && ok "both folders are left untouched" || bad "both folders were changed"

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
[[ -d "$MG_ALLP/.partitura" && ! -e "$MG_ALLP/.orchestra" ]] && ok "the ledger's project moved" || bad "the ledger's project did not move"
contains "$out" "no state folder" "the current folder has nothing to move"

# the personal folder: dry run, a busy lock, then the move with a Codex account inside it
MG_H="$T/mg-home"; mkdir -p "$MG_H/.orchestra/codex-accounts/work"
printf 'DEEPSEEK_API_KEY=sk-test\n' > "$MG_H/.orchestra/secrets.env"
MG_NEW="$(native "$MG_H")/.partitura"
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
[[ -d "$MG_H/.orchestra" && ! -e "$MG_H/.partitura" ]] && ok "a home dry run moves nothing" || bad "a home dry run moved the folder"

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
[[ -d "$MG_B/.orchestra" && ! -e "$MG_B/.partitura" ]] && ok "a busy home is not moved" || bad "a busy home was moved"
: > "$T/mg-lock-stop"; wait "$MG_HPID" 2>/dev/null || true

out=$(env -u ORCH_HOME HOME="$MG_H" USERPROFILE="$(native "$MG_H")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 0 $rc "an idle old home moves"
contains "$out" "moved .*\.orchestra → .*\.partitura" "the home move is reported"
contains "$out" "JSON file(s) now name .partitura" "the profile's home path is rewritten"
contains "$out" "/reload-plugins" "open sessions are told to reload"
[[ -d "$MG_H/.partitura" && ! -e "$MG_H/.orchestra" && -f "$MG_H/.partitura/secrets.env" ]] \
  && ok "the home is .partitura now, its files moved with it" || bad "the home did not move"
$PY - "$(native "$MG_H/.partitura/profiles.json")" "$(native "$MG_H/.partitura/codex-accounts/work")" <<'EOF' && ok "profiles.json: the Codex account folder names .partitura" || bad "profiles.json still names .orchestra"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["providers"]["codex"]["profiles"]["work"]["home"] == sys.argv[2], data
assert data["note"] == "~/.partitura/old", data.get("note")
EOF
out=$(env -u ORCH_HOME HOME="$MG_H" USERPROFILE="$(native "$MG_H")" $ORCH footprint 2>&1)
contains "$out" "$MG_NEW — personal data" "orch resolves ~/.partitura after the move"
out=$(env -u ORCH_HOME HOME="$MG_H" USERPROFILE="$(native "$MG_H")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 0 $rc "a second --home run has nothing to move"
contains "$out" "nothing to move" "…and says so"

# ORCH_HOME decides the home: --home must do nothing
MG_SET="$T/mg-set-home"; mkdir -p "$MG_SET"
out=$(ORCH_HOME="$(native "$MG_SET")" $ORCH migrate --home --yes 2>&1); rc=$?
expect_rc 0 $rc "with ORCH_HOME set, --home does nothing"
contains "$out" "ORCH_HOME is set: it decides the personal folder" "…and says the variable decides"
[[ ! -e "$MG_SET/.partitura" ]] && ok "…and moves nothing" || bad "a home moved although ORCH_HOME is set"

# the doctor hint goes away once the project is migrated
out=$(cd "$MG_OLD" && $ORCH migrate --yes 2>&1); rc=$?
expect_rc 0 $rc "the old-name project migrates"
[[ -d "$MG_OLD/.partitura" && ! -e "$MG_OLD/.orchestra" ]] && ok "the old-name project is moved" || bad "the old-name project did not move"
out=$(cd "$MG_OLD" && $ORCH doctor)
lacks "$out" "still under the name .orchestra" "the doctor hint goes away after the move"
