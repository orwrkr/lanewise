echo "── a fast status line (no process, small writes, bounded ids, kills)"
SLH="$(native "$T/sl-home")"; SLN="$(native "$T/sl-no-codex")"; SLCFG="$(native "$T/sl-cfg")"; SLR="$T/sl-repo"
SLP="$T/sl-cfg/projects/p"; SLD="$T/sl-home/session_tokens"; SLT="$(native "$T/sl_tool.py")"
mkdir -p "$SLH" "$SLN" "$SLP" "$SLR/sub" && git -C "$SLR" init -q || die "cannot create the status line fixture"
SLRESET=$(( $(date +%s) + 7200 ))
sl_in() {
  printf '{"session_id":"%s","transcript_path":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":%s}}}' \
    "$1" "$(native "$SLP/$1.jsonl")" "$(native "${2:-$SLR}")" "$SLRESET"
}
sl_env() { ORCH_HOME="$SLH" CODEX_HOME="$SLN" CLAUDE_CONFIG_DIR="$SLCFG" "$@"; }
sl_run() { sl_in "$1" | sl_env $ORCH statusline; }
sl_file() { native "$SLD/$1.json"; }
cat > "$T/sl_tool.py" <<'EOF'
import datetime as dt, json, os, sys, time
cmd, args = sys.argv[1], sys.argv[2:]
compact = lambda o: json.dumps(o, separators=(",", ":"))
def message(i, output):
    t = dt.datetime(2026, 11, 2, 10) + dt.timedelta(seconds=i)
    return compact({"type": "assistant", "timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                    "message": {"id": "msg-%d" % i, "model": "claude-opus-5-5",
                                "usage": {"input_tokens": 10, "output_tokens": output}}}) + "\n"
def load(orch):
    import importlib.machinery, importlib.util
    loader = importlib.machinery.SourceFileLoader("sl_orch", orch)
    m = importlib.util.module_from_spec(importlib.util.spec_from_loader("sl_orch", loader))
    loader.exec_module(m)
    return m
if cmd == "gen":                 # messages: two adjacent lines each, as a streamed response writes them
    with open(args[0], "a", encoding="utf-8") as f:
        for i in range(int(args[1]), int(args[1]) + int(args[2])):
            f.write(message(i, 1) + message(i, 3))
elif cmd == "resend":            # a copy of an old line, its own timestamp included
    with open(args[0], "a", encoding="utf-8") as f:
        f.write(message(int(args[1]), 3))
elif cmd in ("age", "fresh"):    # the session's last save is a minute ago, or now
    e = json.load(open(args[0], encoding="utf-8"))
    back = dt.timedelta(seconds=60 if cmd == "age" else 0)
    e["updated"] = (dt.datetime.now().astimezone() - back).isoformat(timespec="seconds")
    json.dump(e, open(args[0], "w", encoding="utf-8"))
elif cmd == "backdate":          # file modification time, seconds ago
    t = time.time() - int(args[1])
    os.utime(args[0], (t, t))
elif cmd == "ids":               # the largest number of ids held for one file
    e = json.load(open(args[0], encoding="utf-8"))
    print(max(len(s.get("ids") or {}) for s in e["files"].values()))
elif cmd == "old-cache":         # home, session, transcript: an entry whose totals only the old cache knows
    home, sid, transcript = args
    key = str(os.path.normpath(transcript))
    entry = {"format": 2, "ledger": {"codex": {"input": 40, "output": 4}}, "ledger_offset": 0, "updated": "2026-11-02T10:00:00+00:00",
             "files": {key: {"offset": os.path.getsize(transcript), "in": 7000, "out": 900, "provider": "claude",
                             "ids": {"old-%d" % i: {"i": 1, "o": 1} for i in range(150)}}}}
    json.dump({sid: entry, "other-session": dict(entry, ledger={})}, open(os.path.join(home, "session_tokens.json"), "w", encoding="utf-8"))
elif cmd == "audit":             # log, orch, arguments: what a run starts and which modules it loads
    log, orch = args[0], args[1]
    sys.argv = [orch] + args[2:]
    started, before = [], set(sys.modules)
    def hook(name, a):
        if name in ("subprocess.Popen", "os.system", "os.spawn", "os.exec", "os.posix_spawn", "os.startfile"):
            started.append("%s %r" % (name, a[:2]))
    sys.addaudithook(hook)
    code = compile(open(orch, encoding="utf-8").read(), orch, "exec")
    try:
        exec(code, {"__name__": "__main__", "__file__": orch})
    except SystemExit:
        pass
    heavy = sorted(({"argparse", "shutil", "subprocess", "tempfile"} & set(sys.modules)) - before)
    json.dump({"started": started, "heavy": heavy}, open(log, "w", encoding="utf-8"))
elif cmd == "kill":              # mode, orch: die in the middle of writing the session's file
    m = load(args[1])
    if args[0] == "before-replace":
        replace = os.replace
        def die_replacing(src, dst):
            if "session_tokens" in str(dst):
                os._exit(9)
            return replace(src, dst)
        m.os.replace = die_replacing
    else:
        dump = json.dump
        def die_dumping(data, f, **kw):
            if "session_tokens" in str(getattr(f, "name", "")):
                f.write('{"format": 3, "fil'); f.flush(); os._exit(9)
            return dump(data, f, **kw)
        m.json.dump = die_dumping
    sys.exit(m.main(["statusline"]))
elif cmd == "busy":              # orch: a status line while another process holds the lock
    import subprocess
    m = load(args[0])
    with m.state_lock(m.ORCH_HOME / ".state.lock"):
        r = subprocess.run([sys.executable, args[0], "statusline"], stdin=sys.stdin, stdout=subprocess.PIPE)
    sys.stdout.buffer.write(r.stdout)
    sys.exit(r.returncode)
EOF
# the transcripts: messages of 10 in, 3 out
$PY "$SLT" gen "$(native "$SLP/speed-ids-1.jsonl")" 0 250
# no process: a recording git for POSIX, the audit hook for every system (native Windows finds only a git.exe on PATH)
mkdir -p "$T/sl-gitbin"; printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$T/sl-git-called" > "$T/sl-gitbin/git"; chmod +x "$T/sl-gitbin/git"
( cd "$SLR/sub" && sl_in speed-ids-1 "$SLR/sub" | PATH="$T/sl-gitbin:$PATH" sl_env $PY "$SLT" audit "$(native "$T/sl-audit.json")" "$(native "$PLUGIN/bin/orch")" statusline >"$T/sl-out.txt" )
out=$(cat "$T/sl-out.txt"); contains "$out" "Session in/out: Claude 2.5k/750" "fast status line: a streamed message counts once"
contains "$out" "5h 12%" "fast status line: the limits line comes from this run's input"
[[ -e "$T/sl-git-called" ]] && bad "the status line called git" || ok "the status line does not call git"
$PY - "$(native "$T/sl-audit.json")" <<'EOF' && ok "the status line starts no process, in a git repository, without ORCH_PROJECT_DIR" || bad "the status line started a process"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert not d["started"], d
EOF
$PY - "$(native "$T/sl-audit.json")" <<'EOF' && ok "the status line loads neither argparse, shutil, subprocess nor tempfile" || bad "the status line loaded a heavy module"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert not d["heavy"], d
EOF
sl_in speed-ids-1 | sl_env $PY "$SLT" audit "$(native "$T/sl-audit.json")" "$(native "$PLUGIN/bin/orch")" statusline --then "echo mine" >/dev/null
$PY - "$(native "$T/sl-audit.json")" <<'EOF' && ok "the audit hook sees a process: --then, the operator's own command, is the only one" || bad "the audit hook is blind, or --then did not run"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d["started"]) == 1 and "mine" in d["started"][0], d
EOF
out=$(sl_in speed-ids-1 | sl_env $ORCH statusline --the "echo mine"); contains "$out" "^mine  " "statusline: an abbreviated option still goes through argparse"
sl_in speed-ids-1 | sl_env $ORCH statusline --nope >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "statusline: an unknown option is still refused" || bad "statusline accepted --nope"
# ids stay bounded; a message re-sent after its id was dropped still counts once
n=$($PY "$SLT" ids "$(sl_file speed-ids-1)"); n=${n%$'\r'}
[[ "$n" -le 100 ]] && ok "ids stay bounded in a long transcript ($n of 250)" || bad "ids not bounded: $n"
$PY "$SLT" resend "$(native "$SLP/speed-ids-1.jsonl")" 3
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "a message re-sent after its id was dropped counts once"
$PY "$SLT" resend "$(native "$SLP/speed-ids-1.jsonl")" 249
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "a message re-sent next to its first copy counts once"
sl_env $ORCH usage --session speed-ids-1 --json > "$T/sl-usage.json"
$PY - "$(native "$T/sl-usage.json")" <<'EOF' && ok "the bounded ids agree with orch usage" || bad "the bounded ids disagree with orch usage"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["rows"]
u = [r for r in rows if r["who"] == "orchestrator"][0]["usage"]
assert (u["input_tokens"], u["output_tokens"]) == (2500, 750), u
EOF
# a file idle for 10 minutes keeps no ids, and still does not count an old message twice
$PY "$SLT" backdate "$(native "$SLP/speed-ids-1.jsonl")" 660; $PY "$SLT" age "$(sl_file speed-ids-1)"
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "dropping an idle file's ids keeps the totals"
n=$($PY "$SLT" ids "$(sl_file speed-ids-1)"); [[ "${n%$'\r'}" == 0 ]] && ok "a file idle for 10 minutes keeps no ids" || bad "idle file ids: $n"
$PY "$SLT" resend "$(native "$SLP/speed-ids-1.jsonl")" 249
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/750" "a message re-sent after the idle drop counts once"
# new messages after the drop still count
$PY "$SLT" gen "$(native "$SLP/speed-ids-1.jsonl")" 1000 1
out=$(sl_run speed-ids-1); contains "$out" "Session in/out: Claude 2.5k/753" "a new message after the drop counts"
# a refresh writes this session's file only, at most once per 30 seconds
$PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" 0 2; $PY "$SLT" gen "$(native "$SLP/speed-two.jsonl")" 0 4
sl_run speed-one >/dev/null; sl_run speed-two >/dev/null
[[ -f "$SLD/speed-one.json" && -f "$SLD/speed-two.json" ]] && ok "each session has its own file" || bad "no per-session files"
[[ -e "$T/sl-home/session_tokens.json" ]] && bad "the shared cache came back" || ok "nothing writes the old shared cache"
cp "$SLD/speed-two.json" "$T/sl-b.snap"
$PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" 2 1
$PY "$SLT" fresh "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"      # the clock starts here, however slow the machine
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "a refresh inside 30 seconds shows the new tokens"
cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && ok "a refresh inside 30 seconds does not write" || bad "two refreshes inside 30 seconds wrote twice"
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "parsing from the saved offset again counts nothing twice"
$PY "$SLT" age "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "the refresh that saves shows the same totals"
cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && bad "no save after 30 seconds" || ok "after 30 seconds the refresh saves"
cmp -s "$SLD/speed-two.json" "$T/sl-b.snap" && ok "a refresh leaves other sessions' data alone" || bad "a refresh rewrote another session's file"
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 30/9" "the saved state continues without a drift"
# a session running across the upgrade: its entry has no cache, so both its ledger part and its transcript files are
# parsed again from 0 (a long one catches up over a few updates, with lower numbers until then)
$PY "$SLT" gen "$(native "$SLP/speed-mig.jsonl")" 0 1
$PY "$SLT" old-cache "$SLH" speed-mig "$(native "$SLP/speed-mig.jsonl")"
cp "$T/sl-home/session_tokens.json" "$T/sl-old.snap"
$PY "$SLT" gen "$(native "$SLP/speed-mig.jsonl")" 1 1
out=$(sl_run speed-mig); contains "$out" "Session in/out: Claude 20/6" "migration: an entry in the previous format is parsed again from the transcript"
n=$($PY "$SLT" ids "$(sl_file speed-mig)"); [[ "${n%$'\r'}" -le 100 ]] && ok "migration: the rebuilt file state holds only the real messages ($n of 150 old ids)" || bad "migration ids: $n"
cmp -s "$T/sl-home/session_tokens.json" "$T/sl-old.snap" && ok "migration: other sessions' old entries stay where they are" || bad "migration rewrote the old cache"
$PY "$SLT" backdate "$(native "$T/sl-home/session_tokens.json")" 90000
out=$(sl_run speed-mig); contains "$out" "Session in/out: Claude 20/6" "migration: totals survive the old cache going away"
[[ -e "$T/sl-home/session_tokens.json" ]] && bad "the old cache outlived its last day" || ok "migration: the old cache goes once a day old"
# a kill in the middle of a save leaves valid state, and the next refresh is right
next_message=100
for mode in before-replace mid-dump; do
  $PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" $next_message 1; next_message=$((next_message + 1))
  $PY "$SLT" age "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"
  sl_in speed-one | sl_env $PY "$SLT" kill "$mode" "$(native "$PLUGIN/bin/orch")" >/dev/null; rc=$?
  [[ $rc -eq 9 ]] && ok "kill test ($mode): the run died while saving" || bad "kill test ($mode): rc=$rc"
  cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && ok "a kill ($mode) leaves the session's file whole" || bad "a kill ($mode) damaged the session's file"
done
out=$(sl_run speed-one); contains "$out" "Session in/out: Claude 50/15" "after the kills the totals are right"
# leftovers of killed runs go after a day, a write in progress stays
printf '{"x' > "$T/sl-home/usage.json.old.tmp"; printf '{"x' > "$T/sl-home/usage.json.new.tmp"; printf '{"x' > "$SLD/x.json.old.tmp"
printf '{}' > "$SLD/gone-session.json"
for f in "$T/sl-home/usage.json.old.tmp" "$SLD/x.json.old.tmp" "$SLD/gone-session.json"; do $PY "$SLT" backdate "$(native "$f")" 90000; done
sl_run speed-one >/dev/null
[[ ! -e "$T/sl-home/usage.json.old.tmp" && ! -e "$SLD/x.json.old.tmp" ]] && ok "*.tmp files older than a day are removed" || bad "old *.tmp files stayed"
[[ -e "$T/sl-home/usage.json.new.tmp" ]] && ok "a recent *.tmp stays: it may be a write in progress" || bad "a recent *.tmp was removed"
[[ ! -e "$SLD/gone-session.json" && -e "$SLD/speed-one.json" ]] && ok "a session's file goes a day after its last save" || bad "session files not pruned by age"
# a busy lock: print what is cached, including tokens parsed in this run, and save nothing
$PY "$SLT" gen "$(native "$SLP/speed-one.jsonl")" 200 1
$PY "$SLT" age "$(sl_file speed-one)"; cp "$SLD/speed-one.json" "$T/sl-a.snap"
out=$(sl_in speed-one | sl_env $PY "$SLT" busy "$(native "$PLUGIN/bin/orch")"); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "5h 12%" "a busy lock: the limits line comes from the cache" || bad "busy lock: rc=$rc out=$out"
contains "$out" "Session in/out: Claude 60/18" "a busy lock: the session's new tokens still show"
cmp -s "$SLD/speed-one.json" "$T/sl-a.snap" && ok "a busy lock skips the save" || bad "a save went through a busy lock"
# what takes a module to check: the codex scan throttle, the byte budget, one read per run, the root without git
sl_git_wt="$T/sl-repo-wt"; git -C "$SLR" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init && git -C "$SLR" worktree add -q "$sl_git_wt" -b sl-wt \
  || die "cannot create the worktree fixture"
slunit=$(sl_env $PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/sl-unit")" "$(native "$SLR")" "$(native "$sl_git_wt")" 2>&1 <<'EOF'
import importlib.machinery, importlib.util, json, os, subprocess, sys, traceback
from pathlib import Path
from unittest import mock
orch, root, repo, worktree = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
root.mkdir()
os.environ.update(ORCH_HOME=str(root / "home"), CODEX_HOME=str(root / "cx"))
os.environ.pop("ORCH_PROJECT_DIR", None); os.environ.pop("CLAUDE_PROJECT_DIR", None)
loader = importlib.machinery.SourceFileLoader("sl_unit", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("sl_unit", loader)); loader.exec_module(m)

def check(name, fn):
    try:
        fn()
        print("PASS " + name, flush=True)
    except Exception:
        print("FAIL " + name + ": " + traceback.format_exc().replace("\n", " | "), flush=True)

def rollout_without_limits():
    d = root / "cx" / "sessions" / "2026" / "11" / "02"
    d.mkdir(parents=True, exist_ok=True)
    (d / "rollout-0001.jsonl").write_text('{"type": "noise"}\n', encoding="utf-8")

def scan_throttled_when_it_finds_nothing():
    rollout_without_limits()
    with mock.patch.object(m, "scan_codex_limits", wraps=m.scan_codex_limits) as scan:
        m.refresh_codex(); m.refresh_codex()
        assert scan.call_count == 1, scan.call_count
        m.refresh_codex(force=True)
        assert scan.call_count == 2, scan.call_count
    assert not m.codex_status_part(), "a scan that found nothing must not show a line"

def scan_throttled_when_killed():
    m.write_json(m.CODEX_USAGE_FILE, {})
    with mock.patch.object(m, "scan_codex_limits", side_effect=KeyboardInterrupt):
        try:
            m.refresh_codex()
            raise AssertionError("the scan did not run")
        except KeyboardInterrupt:
            pass
    with mock.patch.object(m, "scan_codex_limits", side_effect=AssertionError("scanned again")):
        m.refresh_codex()

def no_rollouts_no_write():
    with mock.patch.dict(os.environ, {"CODEX_HOME": str(root / "no-such-codex")}):
        before = m.CODEX_USAGE_FILE.read_bytes()
        m.refresh_codex()
        assert m.CODEX_USAGE_FILE.read_bytes() == before

def transcript_lines(path, first, count, padding=""):
    with open(str(path), "a", encoding="utf-8") as f:
        for i in range(first, first + count):
            f.write(json.dumps({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z", "message": {
                "id": "b-%d" % i, "model": "claude-opus-5-5", "pad": padding,
                "usage": {"input_tokens": 10, "output_tokens": 1}}}, separators=(",", ":")) + "\n")

def backlog_progress_survives_kills():
    tr = root / "backlog-session.jsonl"
    transcript_lines(tr, 0, 40)
    transcript_lines(tr, 40, 1, "x" * 2000)            # one line longer than the budget
    transcript_lines(tr, 41, 40)
    saved = m.session_tokens_path("backlog-session")
    seen = []
    with mock.patch.object(m, "PARSE_BYTES_PER_RUN", 400):
        for _ in range(100):
            t = m.session_tokens("backlog-session", str(tr))["claude"]["input"]
            seen.append(t)
            if t == 810:
                break
            state = list(json.loads(saved.read_text(encoding="utf-8"))["files"].values())[0]
            assert state["in"] == t, "a run behind saves at once, or a killed one would start over"
    assert seen[-1] == 810 and len(seen) > 2 and seen == sorted(seen), seen

def one_read_per_run():
    f = root / "home" / "memo.json"
    m.write_json(f, {"v": 1})
    with mock.patch.object(m, "_statusline_run", True):
        assert m.read_json(f, {})["v"] == 1
        f.write_text('{"v": 2}', encoding="utf-8")
        assert m.read_json(f, {})["v"] == 1, "the second read opened the file"
        with m.state_lock(m.ORCH_HOME / ".state.lock"):
            assert m.read_json(f, {})["v"] == 2, "a locked read-modify-write must see the file as it is now"
        m.write_json(f, {"v": 3})
        assert m.read_json(f, {})["v"] == 3
        missing = root / "home" / "missing.json"
        assert m.read_json(missing, {}) == {}
        m.write_json(missing, {"v": 4})
        assert m.read_json(missing, {})["v"] == 4
    m._run_reads.clear()
    f.write_text('{"v": 5}', encoding="utf-8")
    assert m.read_json(f, {})["v"] == 5 and m.read_json(f, {})["v"] == 5 and not m._run_reads

def session_file_names():
    for sid in ("../../evil", "CON", "UPPER-case-id", "a/b", "x" * 300):
        p = m.session_tokens_path(sid)
        assert p.parent == m.SESSION_TOKENS_DIR and p.name.startswith("x-") and len(p.name) < 80, p
    assert m.session_tokens_path("1f0e-uuid-like").name == "1f0e-uuid-like.json"

def git_says(args, cwd):
    return Path(subprocess.run(["git"] + args, cwd=str(cwd), stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout.strip())

def root_agrees_with_git():
    (repo / "sub").mkdir(exist_ok=True); (worktree / "deep").mkdir(exist_ok=True)
    for d in (repo, repo / "sub", worktree, worktree / "deep"):
        top = git_says(["rev-parse", "--show-toplevel"], d).resolve()
        cwd = os.getcwd()
        m._toplevels.clear()
        try:
            os.chdir(str(d))
            assert m.project_dir() == top, (d, m.project_dir(), top)
        finally:
            os.chdir(cwd)
        common = git_says(["rev-parse", "--git-common-dir"], d)
        common = common if common.is_absolute() else (d / common).resolve()
        assert m._project_root(d.resolve()) == common.resolve().parent, (d, m._project_root(d.resolve()), common)
    assert m._project_root(worktree.resolve()) == repo.resolve(), "a worktree belongs to its main repository"

def root_edge_cases():
    outside = root / "outside"; outside.mkdir()
    assert m._project_root(outside.resolve()) == outside.resolve()
    nogit = outside / "empty-git"; (nogit / ".git").mkdir(parents=True)           # git goes on looking above a non-repository
    assert m._project_root(nogit.resolve()) == nogit.resolve()
    broken = outside / "broken"; broken.mkdir(); (broken / ".git").write_text("not a gitdir\n", encoding="utf-8")
    assert m._project_root(broken.resolve()) == broken.resolve()
    dangling = outside / "dangling"; dangling.mkdir()                              # a worktree whose main repository is gone
    (dangling / ".git").write_text("gitdir: ../gone/.git/worktrees/x\n", encoding="utf-8")
    assert m._project_root(dangling.resolve()) == dangling.resolve(), "a .git file that points nowhere is no repository"
    sub = outside / "submodule"; own = outside / "super" / ".git" / "modules" / "submodule"
    sub.mkdir(); own.mkdir(parents=True); (own / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
    (sub / ".git").write_text("gitdir: ../super/.git/modules/submodule\n", encoding="utf-8")
    (sub / "deep").mkdir()
    assert m._project_root((sub / "deep").resolve()) == sub.resolve(), "a submodule is its own project, as with git"

check("codex: a scan that finds nothing waits for the throttle too", scan_throttled_when_it_finds_nothing)
check("codex: a run killed mid-scan does not make the next one scan", scan_throttled_when_killed)
check("codex: without a sessions folder a refresh writes nothing", no_rollouts_no_write)
check("a backlog over the byte budget is saved as it goes, and reaches the right total", backlog_progress_survives_kills)
check("a status line run reads a file once, and afresh under a lock or after its own write", one_read_per_run)
check("an unusual session id cannot leave the session folder", session_file_names)
check("the root found without git agrees with git: repository, subfolder, linked worktree", root_agrees_with_git)
check("the root found without git: outside a repository, a broken .git file, a submodule", root_edge_cases)
EOF
)
while IFS= read -r line; do
  line=${line%$'\r'}
  case "$line" in "PASS "*) ok "${line#PASS }" ;; *) bad "$line" ;; esac
done <<<"$slunit"

