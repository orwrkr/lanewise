echo "── project rules for every executor, usage ledger"
# standalone setup (a no-op once the earlier sections have run)
[[ -f "$T/home/secrets.env" ]] || printf '# keys\r\nexport DEEPSEEK_API_KEY="sk-from-file"\r\n' > "$T/home/secrets.env"
printf '# Rules\nCLAUDE-MARKER\n@AGENTS.md\n' > "$REPO/CLAUDE.md"; printf 'AGENTS-MARKER\n' > "$REPO/AGENTS.md"
FAKE_CLAUDE=ok $ORCH run deepseek --task "Café parser tests" "x" >/dev/null
check 'r["claude_n"] == 1 and r["agents_n"] == 1' "deepseek: CLAUDE.md + AGENTS.md, @import inlined once"
FAKE_CODEX=ok $ORCH run codex --model gpt-6.1-terra --effort high "implement" >/dev/null
out=$(cat "$REPO"/.lanewise/runs/cod-*/codex_prompt.md | tail -c 2000)
contains "$out" "CLAUDE-MARKER" "codex: CLAUDE.md rules added to the prompt"
grep -q "AGENTS-MARKER" "$REPO"/.lanewise/runs/cod-*/codex_prompt.md && bad "codex got AGENTS.md twice" || ok "codex: AGENTS.md left to codex itself"
rm -f "$REPO/CLAUDE.md" "$REPO/AGENTS.md"
out=$(FAKE_CODEX=ok $ORCH run codex --model gpt-6.1-terra "Implement the café parser"); contains "$out" "tokens: input 200 · cache 1.0k · output 30" "codex usage parsed from --json (cached split out)"
$PY - "$ORCH_HOME/usage.jsonl" <<'EOF' && ok "ledger: runs with session, task, model, tokens" || bad "ledger content"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
cx = [r for r in recs if r["kind"] == "run" and r["provider"] == "codex" and r["task"] == "Implement the café parser"][-1]
ds = [r for r in recs if r["kind"] == "run" and r["provider"] == "deepseek" and r["task"] == "Café parser tests"][-1]
assert cx["session"] == "sess-test" and cx["model"] == "gpt-6.1-terra" and cx["usage"]["output_tokens"] == 30, cx
assert ds["usage"] == {"input_tokens": 150, "cached_input_tokens": 400, "output_tokens": 25, "model": "deepseek-flash"}, ds
EOF
# a worktree holds no git-ignored files: an @import it lacks comes from the project folder
IP="$T/import-proj"; mkdir -p "$IP/.local-notes" "$IP/docs" && git -C "$IP" init -q && git -C "$IP" config user.email t@t && git -C "$IP" config user.name t \
  && printf 'TRACKED-MARKER\n@.local-notes/env.md\n@.local-notes/own.md\n@.local-notes/missing.md\n' > "$IP/CLAUDE.md" \
  && printf 'MAIN-DOC\n' > "$IP/docs/branch.md" \
  && printf '.local-notes/\n' > "$IP/.gitignore" && git -C "$IP" add . && git -C "$IP" -c commit.gpgsign=false commit -qm init \
  && git -C "$IP" worktree add -q "$T/import-wt" -b import-wt || die "cannot create the import fixture"
printf 'ENV-MARKER\n@deeper.md\n' > "$IP/.local-notes/env.md"; printf 'DEEPER-MARKER\n' > "$IP/.local-notes/deeper.md"
printf 'OWN-MAIN-MARKER\n' > "$IP/.local-notes/own.md"
mkdir -p "$T/import-wt/.local-notes"; printf 'OWN-WORKTREE-MARKER\n' > "$T/import-wt/.local-notes/own.md"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$IP")" "$(native "$T/import-wt")" "$(native "$T/import-out.md")" <<'EOF' && ok "an @import missing from a worktree comes from the project folder" || bad "imports in a worktree"
import importlib.machinery, importlib.util, sys
from pathlib import Path
orch, main, wt, out = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("orch_imports", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
text = m.build_context(wt, set(), Path(out)).read_text(encoding="utf-8")
for found in ("TRACKED-MARKER", "ENV-MARKER", "DEEPER-MARKER", "OWN-WORKTREE-MARKER", "@.local-notes/missing.md"):
    assert found in text, (found, text)
assert "OWN-MAIN-MARKER" not in text, text
text = m.build_context(main, set(), Path(out)).read_text(encoding="utf-8")
assert "OWN-MAIN-MARKER" in text and "OWN-WORKTREE-MARKER" not in text, text
EOF
mkdir -p "$IP/docs" "$IP/.claude" "$T/import-wt/docs"
printf 'AGENTS.md\n' >> "$IP/.git/info/exclude"
printf '.claude/CLAUDE.md\n' >> "$IP/.gitignore"
printf 'IGNORED-AGENTS\n@docs/branch.md\n' > "$IP/AGENTS.md"
printf 'IGNORED-CLAUDE\n@../AGENTS.md\n' > "$IP/.claude/CLAUDE.md"
printf 'MAIN-DOC\n' > "$IP/docs/branch.md"
printf 'BRANCH-DOC\n' > "$T/import-wt/docs/branch.md"
rm "$T/import-wt/CLAUDE.md"
$PY - "$(native "$PLUGIN/bin/orch")" "$(native "$IP")" "$(native "$T/import-wt")" "$(native "$T/import-out.md")" <<'EOF' && ok "ignored instructions reach worktrees with branch imports" || bad "ignored instructions"
import importlib.machinery, importlib.util, sys
from pathlib import Path
orch, main, wt, out = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("orch_ignored", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
for native in (set(), {"AGENTS.md"}):
    text = m.build_context(wt, native, Path(out)).read_text(encoding="utf-8")
    assert text.count("IGNORED-AGENTS") == 1 and text.count("IGNORED-CLAUDE") == 1, text
    assert "BRANCH-DOC" in text and "MAIN-DOC" not in text and "TRACKED-MARKER" not in text, text
Path(wt, "AGENTS.md").write_text("WORKTREE-AGENTS\n", encoding="utf-8")
text = m.build_context(wt, {"AGENTS.md"}, Path(out)).read_text(encoding="utf-8")
assert "WORKTREE-AGENTS" not in text and "IGNORED-AGENTS" not in text, text
EOF
# a git-ignored AGENTS.md missing from a worktree reaches a real codex run: codex reads AGENTS.md natively, so
# the file the adapter cannot find still goes into the run's context.md
rm -f "$T/import-wt/AGENTS.md"
out=$(FAKE_CODEX=ok $ORCH run codex --cd "$(native "$T/import-wt")" "review the form"); rc=$?
expect_rc 0 $rc "a run in the worktree starts"
RID=$(grep -o 'cod-[0-9]*-[0-9]*-[a-z0-9]*' <<<"$out" | head -1)
[[ -n "$RID" ]] && grep -q "IGNORED-AGENTS" "$REPO/.lanewise/runs/$RID/context.md" \
  && ok "the ignored AGENTS.md reaches the run's context.md" || bad "the ignored AGENTS.md is missing from the run's context.md ($RID)"
CFG="$T/claude-cfg/projects/$(native "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$CFG/sess-test/subagents"
$PY - "$CFG" <<'EOF'
import json, os, sys
d = sys.argv[1]
def a(mid, model, inp, cw, cr, out, agent=None, effort="high"):
    ev = {"type": "assistant", "timestamp": "2026-10-29T10:0%d:00.000Z" % (len(mid) % 9), "effort": effort,
          "message": {"id": mid, "model": model, "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw,
                                                          "cache_read_input_tokens": cr, "output_tokens": out}}}
    if agent:
        ev.update(isSidechain=True, agentId=agent)
    return json.dumps(ev, separators=(",", ":"))
main = [a("m1", "claude-opus-5-5", 10, 100, 1000, 50), a("m1", "claude-opus-5-5", 10, 100, 1000, 50),
        a("m22", "claude-opus-5-5", 5, 0, 2000, 20), json.dumps({"type": "ai-title", "aiTitle": "Café parser"}, separators=(",", ":"))]
open(os.path.join(d, "sess-test.jsonl"), "w", encoding="utf-8").write("\n".join(main) + "\n")
open(os.path.join(d, "sess-test", "subagents", "agent-a1.jsonl"), "w", encoding="utf-8").write(
    a("s1", "claude-sonnet-5-5", 3, 30, 300, 7, agent="a1", effort="medium") + "\n")
json.dump({"agentType": "lanewise:orch-sonnet-high", "description": "Find naïve parse calls"},
          open(os.path.join(d, "sess-test", "subagents", "agent-a1.meta.json"), "w", encoding="utf-8"), ensure_ascii=False)
EOF
out=$($ORCH usage)
contains "$out" "Session sess-tes · “Café parser”" "usage: current session with its title"
contains "$out" "orchestrator *Claude Opus 5.5 *high .* 115 *3.0k *70" "main thread: streamed lines counted once"
contains "$out" "subagent orch-sonnet-high *Claude Sonnet 5.5 *medium *Find naïve parse calls" "subagent: type, model, what for"
contains "$out" "Codex *GPT-6.1 Terra *.*Implement the café parser · OK" "CLI executor in the session report"
contains "$out" "DeepSeek *DeepSeek V4.1 Flash .*Café parser tests" "DeepSeek executor in the session report"
$PY - "$(native "$CFG")" <<'EOF'
import json, os, sys
d = sys.argv[1]
c = lambda x: json.dumps(x, separators=(",", ":"))
original = [json.loads(line) for line in open(os.path.join(d, "sess-test.jsonl"), encoding="utf-8") if '"type":"assistant"' in line]
new = dict(original[0], timestamp="2026-10-30T11:00:00.000Z")
new["message"] = dict(new["message"], id="new", usage={"input_tokens": 17, "output_tokens": 8})
with open(os.path.join(d, "sess-fork.jsonl"), "w", encoding="utf-8") as f:
    for ev in [{"type": "mode"}, {"type": "queue-operation", "timestamp": "2026-10-30T10:00:00.000Z"}] + original + [new]:
        f.write(c(ev) + "\n")
sub = os.path.join(d, "sess-fork", "subagents")
os.makedirs(sub, exist_ok=True)
sub_new = dict(new, message=dict(new["message"], id="sub-new"))
with open(os.path.join(sub, "agent-fork.jsonl"), "w", encoding="utf-8") as f:
    for ev in [{"type": "mode"}, {"type": "queue-operation", "timestamp": "2026-10-30T10:00:00.000Z"}, original[0], sub_new]:
        f.write(c(ev) + "\n")
EOF
$ORCH usage --session sess-fork --json > "$T/fork-usage.json"
$ORCH usage --session sess-test --json > "$T/original-usage.json"
$PY - "$(native "$T/fork-usage.json")" "$(native "$T/original-usage.json")" <<'EOF' && ok "usage excludes copied fork history and retains the original" || bad "fork usage"
import json, sys
fork, original = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]
f = fork["rows"][0]["usage"]
o = next(r["usage"] for r in original["rows"] if r["who"] == "orchestrator")
assert (f["input_tokens"], f["output_tokens"], f["calls"]) == (17, 8, 1), f
assert (o["input_tokens"], o["output_tokens"]) == (115, 70), o
assert fork["start"] == fork["end"] == "2026-10-30T11:00:00.000Z", fork
assert next(r["usage"] for r in fork["rows"] if r["who"].startswith("subagent"))["input_tokens"] == 17, fork
EOF
echo "{\"session_id\": \"sess-test\", \"transcript_path\": \"$(native "$CFG/sess-test.jsonl")\", \"cwd\": \"$(native "$REPO")\"}" | \
  $ORCH hook session-end >"$T/se.out"; rc=$?
[[ $rc -eq 0 && ! -s "$T/se.out" ]] && ok "SessionEnd hook silent" || bad "session-end: rc=$rc $(cat "$T/se.out")"
mv "$CFG" "$T/cfg-gone"
out=$($ORCH usage --session sess-test); contains "$out" "orchestrator *Claude Opus 5.5" "usage survives transcript cleanup (SessionEnd snapshot)"
out=$($ORCH usage --list); contains "$out" "sess-tes *Café parser" "usage --list shows the project's sessions"
mv "$T/cfg-gone" "$CFG"
$PY - "$CFG" <<'EOF'
import json, os, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
ev = {"type": "assistant", "timestamp": "2026-10-29T11:00:00.000Z", "message": {"id": "d1", "model": "deepseek-v4-pro",
      "usage": {"input_tokens": 9, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 90, "output_tokens": 4}}}
open(os.path.join(sys.argv[1], "sess-lead.jsonl"), "w", encoding="utf-8").write(
    c(ev) + "\n" + c({"type": "cost-state", "totalCostUSD": 1.5}) + "\n")
EOF
out=$($ORCH usage --session sess-lead); contains "$out" "lead: DeepSeek V4 Pro" "a DeepSeek-led session is recognised in its transcript"
contains "$out" "assumes Claude prices" "no misleading Claude cost estimate for a DeepSeek lead"
# outside a session: no data is not an error, and records made outside a session stay reachable
EMPTY="$T/usage-empty"; mkdir -p "$EMPTY" || die "cannot create an empty usage folder"
out=$( cd "$EMPTY" && env -u CLAUDE_CODE_SESSION_ID $ORCH usage 2>&1 ); rc=$?
expect_rc 0 $rc "usage with no session and no data is not an error"
contains "$out" "collected per Claude Code session" "usage outside a session says how to pick one"
( cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID FAKE_CODEX=ok $ORCH run codex --model gpt-5.6-terra "outside a session" >/dev/null 2>&1 )
out=$( cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID $ORCH usage --list )
contains "$out" "(outside a session)" "usage --list has a row for records made outside a session"
out=$( cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID $ORCH usage --session none )
contains "$out" "outside a session" "usage --session none shows them"
contains "$out" "outside a session · OK" "usage --session none keeps the usual rows"

# ───────────────────────── daily totals: orch usage --daily ─────────────────────────
echo "── daily totals: orch usage --daily"
DH="$T/daily-home"; DHN="$(native "$DH")"; DCFG="$T/daily-cfg"
DA="$T/daily-a"; DB="$T/daily-b"; DTR="$DCFG/projects/p/sess-mid.jsonl"
mkdir -p "$DH" "$DCFG/projects/p" "$DA" "$DB" || die "cannot create the daily-totals folders"
for d in "$DA" "$DB"; do
  git -C "$d" init -q && git -C "$d" config user.email t@t && git -C "$d" config user.name t || die "cannot init $d"
  echo x > "$d/x.txt"
  git -C "$d" add . && git -C "$d" -c commit.gpgsign=false commit -qm init || die "cannot commit in $d"
done
drun() { ORCH_HOME="$DHN" CLAUDE_CONFIG_DIR="$DCFG" "$@"; }
$PY - "$(native "$T/daily-dates")" <<'EOF'
import datetime as dt, sys
t = dt.date.today()
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
    f.write(" ".join(str(t - dt.timedelta(days=n)) for n in (0, 1, 2, 3, 59, 61, 100)) + "\n")
EOF
read -r T0 D1 D2 D3 T59 T61 T100 < "$T/daily-dates"
$PY - "$(native "$DTR")" <<'EOF'
import datetime as dt, json, sys, time
def stamp(days_ago, hh, mm):
    d = dt.date.today() - dt.timedelta(days=days_ago)
    epoch = time.mktime(dt.datetime(d.year, d.month, d.day, hh, mm).timetuple())
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def message(mid, ts, i, cw, cr, out):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": "claude-opus-5-5",
            "usage": {"input_tokens": i, "cache_creation_input_tokens": cw,
                      "cache_read_input_tokens": cr, "output_tokens": out}}}
compact = lambda o: json.dumps(o, separators=(",", ":"))
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
    f.write(compact(message("dm1", stamp(3, 23, 55), 10, 1000, 100, 5)) + "\n")
    f.write(compact(message("dm2", stamp(2, 0, 5), 20, 0, 200, 7)) + "\n")
EOF
printf '%s' '{"session_id":"sess-mid","transcript_path":"'"$(native "$DTR")"'","workspace":{"current_dir":"'"$(native "$DA")"'"}}' | drun $ORCH statusline >/dev/null
[[ -f "$DH/session_tokens/sess-mid.json" ]] && ok "status line: a session's tokens per day stay in its own file" || bad "no per-day buckets in the session's counter file"
[[ -e "$DH/daily_usage.json" ]] && bad "the status line wrote the shared daily store" || ok "status line: the daily store is left to the hooks and reports"
( cd "$DA" && drun $ORCH usage --daily --by day --json --since "$D3" --until "$D2" ) > "$T/daily-mid.json"
$PY - "$(native "$T/daily-mid.json")" "$D3" "$D2" <<'EOF' && ok "usage --daily: a session crossing midnight splits between the two days" || bad "the midnight split"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["since"] == sys.argv[2] and d["until"] == sys.argv[3] and d["days"] == 2, d
t = d["totals"]
assert (t["input"], t["cache_read"], t["cache_write"], t["output"]) == (30, 300, 1000, 12), t
assert t["sessions"] == 2 and t["runs"] == 0 and t["cost_usd"] > 0, t
g = d["providers"][0]
assert g["provider"] == "claude" and g["rows"][0]["account"] == "claude" and g["rows"][0]["paid_via"] == "subscription", g
assert [x["providers"][0]["input"] for x in d["daily"]] == [10, 20], d["daily"]
assert [x["providers"][0]["cache_write"] for x in d["daily"]] == [1000, 0], d["daily"]
EOF
printf '%s' '{"session_id":"sess-mid","transcript_path":"'"$(native "$DTR")"'","cwd":"'"$(native "$DA")"'"}' | drun $ORCH hook session-end > "$T/daily-se.out"; rc=$?
[[ $rc -eq 0 && ! -s "$T/daily-se.out" ]] && ok "session-end: silent while it keeps the daily totals" || bad "daily session-end: rc=$rc $(cat "$T/daily-se.out")"
( cd "$DA" && drun $ORCH usage --daily --by day --json --since "$D3" --until "$D2" ) > "$T/daily-mid-after.json"
$PY - "$(native "$T/daily-mid.json")" "$(native "$T/daily-mid-after.json")" <<'EOF' && ok "a live fold and the SessionEnd snapshot count each token once" || bad "a token counted twice across live and SessionEnd"
import json, sys
a, b = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]
assert a["totals"] == b["totals"], (a["totals"], b["totals"])
assert a["providers"] == b["providers"] and a["daily"] == b["daily"], "the report changed after SessionEnd"
EOF
out=$( cd "$REPO" && FAKE_CODEX=ok ORCH_HOME="$DHN" $ORCH run codex --model gpt-6.1-terra --effort high --task "daily run" "run for the daily totals" )
expect_rc 0 $? "an executor run for the daily totals starts"
( cd "$REPO" && ORCH_HOME="$DHN" $ORCH usage --daily --json --since "$T0" --until "$T0" ) > "$T/daily-run.json"
( cd "$REPO" && ORCH_HOME="$DHN" $ORCH usage --daily --json --since "$D1" --until "$D1" ) > "$T/daily-run-before.json"
$PY - "$(native "$T/daily-run.json")" "$(native "$T/daily-run-before.json")" "$(native "$DH/usage.jsonl")" <<'EOF' && ok "an executor run counts on its end day, under its account, at its own cost" || bad "the executor run in the daily totals"
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
before = json.load(open(sys.argv[2], encoding="utf-8"))
recs = [json.loads(line) for line in open(sys.argv[3], encoding="utf-8") if line.strip()]
rec = [r for r in recs if r.get("kind") == "run" and r.get("task") == "daily run"][-1]
t = report["totals"]
assert t["runs"] == 1 and (t["input"], t["cache_read"], t["cache_write"], t["output"]) == (200, 1000, 0, 30), t
assert abs(t["cost_usd"] - float(rec["cost_usd"])) < 1e-6, (t["cost_usd"], rec["cost_usd"])
row = report["providers"][0]["rows"][0]
assert row["account"] == "codex" and row["model"] == "gpt-6.1-terra" and row["paid_via"] in ("api", "subscription"), row
assert before["totals"]["runs"] == 0 and not before["providers"], before["totals"]
EOF
$PY - "$(native "$DH/session_tokens/sess-mid.json")" "$(native "$DH/session_tokens/sess-crash-1.json")" "$D1" <<'EOF'
import json, os, sys, time
src, dst, day = sys.argv[1:]
entry = json.load(open(src, encoding="utf-8"))
fixture = {"format": 4, "session": "sess-crash-1", "project": entry["project"], "accounts": {"claude": "claude"},
           "daily": {day: {"claude-opus-5-5": {"in": 50, "cr": 0, "cw": 0, "out": 5, "cost": 0.004}}}}
with open(dst, "w", encoding="utf-8", newline="\n") as f:
    json.dump(fixture, f)
old = time.time() - 2 * 86400
os.utime(dst, (old, old))
EOF
( cd "$DA" && drun $ORCH usage --daily --json --since "$D1" --until "$D1" ) > "$T/daily-crash-a.json"
( cd "$DA" && drun $ORCH usage --daily --json --since "$D1" --until "$D1" ) > "$T/daily-crash-b.json"
$PY - "$(native "$T/daily-crash-a.json")" "$(native "$T/daily-crash-b.json")" <<'EOF' && ok "a crashed session's counters count once over repeated reports" || bad "a crashed session counted twice"
import json, sys
a, b = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]
assert a["totals"]["input"] == 50 and a["totals"]["sessions"] == 1, a["totals"]
assert a["totals"] == b["totals"], (a["totals"], b["totals"])
EOF
ORCH_HOME="$DHN" $PY -B - "$(native "$PLUGIN/bin/orch")" <<'EOF' && ok "a counter file unchanged for a day is folded into the store" || bad "the stale counter file was not folded"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("daily_sweep", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("daily_sweep", loader))
loader.exec_module(m)
m.sweep_orch_home()
EOF
[[ ! -e "$DH/session_tokens/sess-crash-1.json" ]] && ok "the folded counter file is removed" || bad "the folded counter file stayed"
( cd "$DA" && drun $ORCH usage --daily --json --since "$D1" --until "$D1" ) > "$T/daily-crash-c.json"
$PY - "$(native "$T/daily-crash-b.json")" "$(native "$T/daily-crash-c.json")" <<'EOF' && ok "folding it again from the store changes nothing" || bad "the sweep changed the totals"
import json, sys
a, b = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]
assert a["totals"] == b["totals"], (a["totals"], b["totals"])
EOF
$PY - "$(native "$DH/session_tokens/sess-mid.json")" "$(native "$DH/session_tokens/sess-crash-2.json")" "$D1" <<'EOF'
import json, os, sys, time
src, dst, day = sys.argv[1:]
entry = json.load(open(src, encoding="utf-8"))
fixture = {"format": 4, "session": "sess-crash-2", "project": entry["project"], "accounts": {"claude": "claude"},
           "daily": {day: {"claude-opus-5-5": {"in": 40, "cr": 0, "cw": 0, "out": 2, "cost": 0.003}}}}
with open(dst, "w", encoding="utf-8", newline="\n") as f:
    json.dump(fixture, f)
old = time.time() - 2 * 86400
os.utime(dst, (old, old))
EOF
ORCH_HOME="$DHN" $PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$DH/daily_usage.json")" "$D1" <<'EOF' && ok "hook maintenance folds a crashed session with no report in between, and only once" || bad "hook maintenance lost a crashed session"
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("daily_sweep2", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("daily_sweep2", loader))
loader.exec_module(m)
if m.DAILY_MARKER.exists():
    m.DAILY_MARKER.unlink()
m.daily_maintenance()
m.daily_maintenance()                   # a second hook stays inside the machine-wide gap
store = json.load(open(sys.argv[2], encoding="utf-8"))
leaf = store["sessions"]["sess-crash-2"]["days"][sys.argv[3]]["claude|claude-opus-5-5|claude|subscription"]
assert (leaf["in"], leaf["out"]) == (40, 2), leaf
assert not (m.SESSION_TOKENS_DIR / "sess-crash-2.json").exists(), "the folded file stayed"
EOF
$PY - "$(native "$DH/daily_usage.json")" "$(native "$T/daily-mid.json")" "$T61" <<'EOF'
import json, sys
path, report, old = sys.argv[1:]
store = json.load(open(path, encoding="utf-8"))
project = json.load(open(report, encoding="utf-8"))["project"]
store.setdefault("runs", {})[old] = {
    "%s|claude|claude-opus-5-5|claude|subscription" % project:
        {"runs": 1, "in": 999, "cr": 0, "cw": 0, "out": 0, "cost": 1.0}}
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f)
EOF
( cd "$DA" && drun $ORCH usage --daily --json --since "$D1" --until "$T0" ) > "$T/daily-prune.json"
$PY - "$(native "$DH/daily_usage.json")" "$T59" <<'EOF' && ok "days older than 60 are pruned" || bad "the store kept days older than 60"
import json, sys
store = json.load(open(sys.argv[1], encoding="utf-8"))
assert not any(day < sys.argv[2] for day in (store.get("runs") or {})), sorted((store.get("runs") or {}))
assert store.get("pruned_before") == sys.argv[2], store.get("pruned_before")
EOF
( cd "$DA" && drun $ORCH usage --daily --json --since "$T100" ) > "$T/daily-since.json"
$PY - "$(native "$T/daily-since.json")" "$T59" "$D3" <<'EOF' && ok "a --since before the kept range says how far back the data goes" || bad "a --since before the kept range is silent"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["since"] == sys.argv[2] and d["days"] == 60, d
assert any(("the data goes back to " + sys.argv[2]) in n for n in d["notes"]), d["notes"]
assert any(n == "the stored totals begin on " + sys.argv[3] for n in d["notes"]), d["notes"]
EOF
S2H="$T/daily-sl-home"; S2N="$(native "$S2H")"; S2TR="$T/daily-sl/sess-slot.jsonl"
mkdir -p "$S2H" "$T/daily-sl" || die "cannot create the status line's daily folder"
$PY - "$(native "$S2TR")" <<'EOF'
import datetime as dt, json, sys, time
d = dt.date.today()
epoch = time.mktime(dt.datetime(d.year, d.month, d.day, 12, 0).timetuple())
ts = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
ev = {"type": "assistant", "timestamp": ts,
      "message": {"id": "sl1", "model": "claude-sonnet-5-5",
                  "usage": {"input_tokens": 7, "cache_creation_input_tokens": 3,
                            "cache_read_input_tokens": 0, "output_tokens": 4}}}
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps(ev, separators=(",", ":")) + "\n")
EOF
printf '%s' '{"session_id":"sess-slot","transcript_path":"'"$(native "$S2TR")"'","workspace":{"current_dir":"'"$(native "$DA")"'"}}' | ORCH_HOME="$S2N" CLAUDE_CONFIG_DIR="$DCFG" $ORCH statusline >/dev/null
[[ -e "$S2H/daily_usage.json" ]] && bad "the status line wrote a daily store of its own" || ok "the status line writes no daily store: the folding is left to the hooks and reports"
$PY - "$(native "$S2H/session_tokens/sess-slot.json")" "$T0" <<'EOF' && ok "the status line's own file carries the session's days and models" || bad "the status line kept no daily buckets"
import json, sys
entry = json.load(open(sys.argv[1], encoding="utf-8"))
bucket = entry["daily"][sys.argv[2]]["claude-sonnet-5-5"]
assert (bucket["in"], bucket["cw"], bucket["out"]) == (7, 3, 4) and bucket["cost"] > 0, bucket
EOF
( cd "$DA" && ORCH_HOME="$S2N" $ORCH usage --daily --json --since "$T0" --until "$T0" ) > "$T/daily-sl.json"
$PY - "$(native "$T/daily-sl.json")" <<'EOF' && ok "a report folds the status line's buckets from a home the hooks never touched" || bad "the report did not fold the status line's buckets"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
t = d["totals"]
assert (t["input"], t["cache_write"], t["output"], t["sessions"]) == (7, 3, 4, 1), t
assert t["cost_usd"] > 0, t
EOF
# daily totals: subscription share
DS="$T/daily-sub"; DSN="$(native "$DS")"
mkdir -p "$DS" || die "cannot create the daily subscription folder"
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --json --since "$T0" --until "$T0" ) > "$T/daily-sub-a0.json"
( cd "$DB" && ORCH_HOME="$DSN" $ORCH usage --daily --json --since "$T0" --until "$T0" ) > "$T/daily-sub-b0.json"
$PY - "$(native "$T/daily-sub-a0.json")" "$(native "$T/daily-sub-b0.json")" "$(native "$DS/daily_usage.json")" \
      "$(native "$T/daily-proj-a.txt")" "$(native "$T/daily-proj-b.txt")" "$T0" "$D1" <<'EOF' && ok "the two projects of the daily totals are distinct" || bad "cannot tell the two daily projects apart"
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))["project"]
b = json.load(open(sys.argv[2], encoding="utf-8"))["project"]
assert a and b and a != b, (a, b)
for path, value in ((sys.argv[4], a), (sys.argv[5], b)):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(value + "\n")
t0, d1 = sys.argv[6], sys.argv[7]
def leaf(runs, tokens, cost):
    return {"runs": runs, "in": tokens, "cr": 0, "cw": 0, "out": 0, "cost": cost}
def point(amount):
    return {"amount": amount, "currency": "USD", "at": d1 + "T00:00:00+00:00"}
claude = "claude|claude-opus-5-5"
store = {"version": 1, "_readme": "fixture", "pruned_before": d1, "ledger_offset": 0,
         "runs": {t0: {a + "|" + claude + "|claude|subscription": leaf(1, 100, 3.0),
                       a + "|" + claude + "|claude@work|api": leaf(1, 1000, 5.0),
                       b + "|" + claude + "|claude|subscription": leaf(1, 50, 1.0)},
                  d1: {b + "|" + claude + "|claude|subscription": leaf(1, 7, 0.1)}},
         "sessions": {},
         "limits": {t0: {"claude": {"seven_day": 30, "five_hour": 5}}},
         "limit_tails": {},
         "balances": {d1: {"deepseek@work": {"first": point(100), "last": point(40)}},
                      t0: {"deepseek@work": {"first": point(70), "last": point(20)}}}}
with open(sys.argv[3], "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f)
EOF
read -r PROJ_A < "$T/daily-proj-a.txt"
read -r PROJ_B < "$T/daily-proj-b.txt"
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --json --since "$T0" --until "$T0" ) > "$T/daily-sub-a.json"
$PY - "$(native "$T/daily-sub-a.json")" "$PROJ_A" "$T0" <<'EOF' && ok "subscription: two projects' subscription tokens share the planned points, the API-key use stays out" || bad "the subscription share of two projects"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["project"] == sys.argv[2] and d["days"] == 1, (d["project"], d["days"])
t = d["totals"]
assert (t["input"], t["runs"], t["cost_usd"]) == (1100, 2, 8.0), t
sub = d["subscriptions"][0]
assert len(sub["projects"]) == 2, sub["projects"]
assert sub["account"] == "claude" and not sub["no_limit_data"] and not sub["no_token_data"], sub
assert (sub["tokens"], sub["cost_usd"]) == (150, 4.0), sub
assert sub["points"] == {"seven_day": 30.0, "five_hour": 5.0} and sub["days_with_limits"] == 1, sub
mine = [p for p in sub["projects"] if p["project"] == sys.argv[2]]
assert len(mine) == 1, sub["projects"]
p = mine[0]
assert (p["token_share"], p["cost_share"]) == (0.6667, 0.75), p
assert (p["points_by_tokens"], p["points_by_cost"]) == (20.0, 22.5), p
EOF
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --since "$T0" --until "$T0" ) > "$T/daily-sub-a.txt"
contains "$(cat "$T/daily-sub-a.txt")" "30 points of the weekly limit used in all and 5 points of the 5-hour windows" "subscription: the points of the whole subscription in the interval"
contains "$(cat "$T/daily-sub-a.txt")" "This project: 67% of the tokens (75% by cost), about 20–22.5 weekly points" "subscription: both shares of the project and both estimates"
contains "$(cat "$T/daily-sub-a.txt")" "not in the denominator" "subscription: the caveat that only this machine's sessions are seen"
contains "$(cat "$T/daily-sub-a.txt")" "cache reads are left out" "subscription: the caveat about cache reads in the share"
# daily totals: limits missing
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --since "$D1" --until "$T0" ) > "$T/daily-sub-gap.txt"
contains "$(cat "$T/daily-sub-gap.txt")" "weekly estimate covers 1 of 2 days; $D1 have no limit data." "subscription: the days without a sample are counted, not estimated"
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --since "$D1" --until "$D1" ) > "$T/daily-sub-none.txt"
contains "$(cat "$T/daily-sub-none.txt")" "no limit data for these days" "subscription: an interval with no sample says so instead of guessing"
# daily totals: the weekly reset
DLH="$T/daily-limit-home"; DLHN="$(native "$DLH")"
mkdir -p "$DLH" || die "cannot create the daily limit folder"
$PY - "$(native "$DLH/claude_usage.json")" "$T0" "$D1" "$D2" <<'EOF' || die "cannot write the limit samples"
import datetime as dt, json, sys, time
def stamp(day, hh, mm):
    y, m, d = (int(x) for x in day.split("-"))
    epoch = time.mktime(dt.datetime(y, m, d, hh, mm).timetuple())
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
t0, d1, d2 = sys.argv[2], sys.argv[3], sys.argv[4]
snap = {"updated": stamp(t0, 10, 0),
        "week_history": [[stamp(d2, 10, 0), 40, "2026-01-01T00:00:00+00:00"],
                         [stamp(d1, 10, 0), 70, "2026-01-01T00:00:00+00:00"],
                         [stamp(d1, 20, 0), 5, "2026-01-08T00:00:00+00:00"],
                         [stamp(t0, 10, 0), 35, "2026-01-08T00:00:00+00:00"]]}
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
    json.dump(snap, f)
EOF
( cd "$DA" && ORCH_HOME="$DLHN" $ORCH usage --daily --days 3 --json --by day ) > "$T/daily-limit.json"
$PY - "$(native "$T/daily-limit.json")" "$T0" "$D1" "$D2" <<'EOF' && ok "subscription: the steps of a weekly window count across a reset, per day" || bad "the weekly limit points across a reset"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
t0, d1, d2 = sys.argv[2], sys.argv[3], sys.argv[4]
assert d["since"] == d2 and d["until"] == t0 and d["days"] == 3, d
per = {x["day"]: x for x in d["daily"]}
assert set(per) == {d2, d1, t0}, per
assert per[d2]["limits"]["claude"]["seven_day"] == 0.0, per[d2]
assert per[d1]["limits"]["claude"]["seven_day"] == 35.0, per[d1]
assert per[t0]["limits"]["claude"]["seven_day"] == 30.0, per[t0]
sub = d["subscriptions"][0]
assert sub["account"] == "claude" and sub["points"] == {"seven_day": 65.0, "five_hour": 0.0}, sub
assert sub["days_with_limits"] == 3 and sub["days_without_limits"] == 0, sub
assert sub["no_token_data"] and not sub["no_limit_data"], sub
EOF
( cd "$DA" && ORCH_HOME="$DLHN" $ORCH usage --daily --days 3 ) > "$T/daily-limit.txt"
contains "$(cat "$T/daily-limit.txt")" "65 points of the weekly limit used in all" "subscription: the points across the reset are summed"
contains "$(cat "$T/daily-limit.txt")" "No token data for these days, so no share can be estimated." "subscription: no token data means no share, not zero"
# daily totals: projects, interval and balance
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --all-projects --since "$D1" --until "$T0" --json ) > "$T/daily-all.json"
$PY - "$(native "$T/daily-all.json")" "$T0" "$D1" <<'EOF' && ok "projects: every project's totals sum to the all-projects total, and the balance rises on a top-up" || bad "the all-projects split or the balance"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
t0, d1 = sys.argv[2], sys.argv[3]
assert d["since"] == d1 and d["until"] == t0 and d["days"] == 2 and d["all_projects"] and d["project"] is None, d
t = d["totals"]
assert (t["input"], t["runs"], t["cost_usd"]) == (1157, 4, 9.1), t
assert len(d["projects"]) == 2, d["projects"]
for k in ("runs", "sessions", "input", "cache_read", "cache_write", "output", "cost_usd"):
    assert round(sum(p[k] for p in d["projects"]), 6) == round(t[k], 6), (k, t[k])
b = d["balances"][0]
assert b["account"] == "deepseek@work", b
assert (b["first"]["day"], b["first"]["amount"]) == (d1, 100.0), b
assert (b["last"]["day"], b["last"]["amount"]) == (t0, 20.0) and b["change"] == -80.0, b
assert b["rises"] == [{"day": t0, "amount": 30.0, "currency": "USD"}], b["rises"]
EOF
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --all-projects --since "$D1" --until "$T0" ) > "$T/daily-all.txt"
contains "$(cat "$T/daily-all.txt")" "By project:" "all-projects: the per-project split is shown"
contains "$(cat "$T/daily-all.txt")" "a rise of \$30.00 (a top-up)" "balance: a top-up shows as a rise"
contains "$(cat "$T/daily-all.txt")" "$D1 \$100.00 → $T0 \$20.00" "balance: the day's first and last figure"
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --since "$D1" --until "$T0" --json ) > "$T/daily-proj-a.json"
$PY - "$(native "$T/daily-proj-a.json")" "$PROJ_A" <<'EOF' && ok "the default project of a report is the current one, as the usage log keys it" || bad "the default project of the daily report"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["project"] == sys.argv[2] and d["totals"]["input"] == 1100, d
EOF
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --project "$(native "$DB")" --since "$D1" --until "$T0" --json ) > "$T/daily-proj-b.json"
$PY - "$(native "$T/daily-proj-b.json")" "$PROJ_B" <<'EOF' && ok "--project picks another project's totals" || bad "--project of the daily report"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["project"] == sys.argv[2] and d["totals"]["input"] == 57, d
EOF
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --all-projects --days 2 --json ) > "$T/daily-days.json"
$PY - "$(native "$T/daily-days.json")" "$T0" "$D1" <<'EOF' && ok "--days 2 is today and yesterday" || bad "--days of the daily report"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["since"] == sys.argv[3] and d["until"] == sys.argv[2] and d["totals"]["input"] == 1157, d
EOF
( cd "$DA" && ORCH_HOME="$DSN" $ORCH usage --daily --days 2 --since "$D1" 2>&1 ); expect_rc 2 $? "--days and --since together are refused"
# daily totals: filters and CSV
$PY - "$(native "$DH/daily_usage.json")" "$PROJ_A" "$T0" <<'EOF' || die "cannot add the daily filter fixture"
import json, sys
path, project, t0 = sys.argv[1], sys.argv[2], sys.argv[3]
store = json.load(open(path, encoding="utf-8"))
runs = store.setdefault("runs", {}).setdefault(t0, {})
runs[project + "|deepseek|deepseek-flash|deepseek@work|api"] = {
    "runs": 3, "in": 900, "cr": 100, "cw": 0, "out": 10, "cost": 0.02}
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f)
EOF
printf '%s' '{"providers":{"deepseek":{"profiles":{"work":{"key":"DEEPSEEK_API_KEY_WORK"}}}},"projects":{},"project_rules":{}}' > "$DH/profiles.json"
dfilt() {
  ( cd "$DA" && ORCH_HOME="$DHN" $ORCH usage --daily --since "$T0" --until "$T0" --json "$@" )
}
dfilt --provider deepseek > "$T/daily-f-provider.json"
dfilt --model deepseek-fl > "$T/daily-f-model.json"
dfilt --key deepseek@work > "$T/daily-f-key.json"
dfilt --key DEEPSEEK_API_KEY_WORK > "$T/daily-f-var.json"
$PY - "$(native "$T/daily-f-provider.json")" "$(native "$T/daily-f-model.json")" \
      "$(native "$T/daily-f-key.json")" "$(native "$T/daily-f-var.json")" <<'EOF' && ok "filters: by provider, by model prefix, by account label and by the key's variable name" || bad "the daily filters"
import json, sys
loaded = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:5]]
for d in loaded:
    assert (d["totals"]["input"], d["totals"]["runs"]) == (900, 3), d["totals"]
    rows = [r for g in d["providers"] for r in g["rows"]]
    assert len(rows) == 1 and rows[0]["account"] == "deepseek@work" and rows[0]["paid_via"] == "api", rows
assert loaded[0]["filters"]["accounts"] == [] and loaded[1]["filters"]["accounts"] == [], loaded[0]["filters"]
assert loaded[2]["filters"]["accounts"] == ["deepseek@work"], loaded[2]["filters"]
assert "deepseek@work" in loaded[3]["filters"]["accounts"], loaded[3]["filters"]
assert loaded[3]["filters"]["key"] == ["DEEPSEEK_API_KEY_WORK"], loaded[3]["filters"]
EOF
( cd "$DA" && ORCH_HOME="$DHN" $ORCH usage --daily --since "$T0" --until "$T0" --csv --provider deepseek ) > "$T/daily.csv"
contains "$(cat "$T/daily.csv")" "day,project,provider,model,account,paid_via,runs,sessions,input_tokens,cache_read_tokens,cache_write_tokens,output_tokens,cost_usd" "CSV: the documented header"
contains "$(cat "$T/daily.csv")" ",deepseek,deepseek-flash,deepseek@work,api,3,0,900,100,0,10," "CSV: one row of the totals"
( cd "$DA" && ORCH_HOME="$DHN" $ORCH usage --daily --since "$T0" --until "$T0" --provider codex ) > "$T/daily-empty.txt"
contains "$(cat "$T/daily-empty.txt")" "No daily totals for these days with these filters." "a filter with no totals says so"
$PY - "$(native "$T/daily-f-provider.json")" <<'EOF' && ok "--json keeps a stable structure" || bad "the structure of --json"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(d) == {"since", "until", "days", "project", "all_projects", "notes", "filters", "totals",
                  "providers", "projects", "balances", "subscriptions"}, set(d)
assert set(d["totals"]) == {"runs", "sessions", "input", "cache_read", "cache_write", "output", "cost_usd"}, d["totals"]
assert "daily" not in d, "daily comes only with --by day"
EOF
ORCH_HOME="$DHN" $PY -B - "$(native "$PLUGIN/bin/orch")" "$T0" <<'EOF' && ok "a balance_store writes the day's first and last figure for the daily totals" || bad "balance_store did not note the daily figures"
import importlib.machinery, importlib.util, sys
orch, day = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("orch_daily_balance", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
m.balance_store({"deepseek@work": ({"amount": 5.0, "currency": "USD"}, None)})
m.balance_store({"deepseek@work": ({"amount": 7.5, "currency": "USD"}, None)})
entry = m.daily_read()["balances"][day]["deepseek@work"]
assert entry["first"]["amount"] == 5.0 and entry["last"]["amount"] == 7.5, entry
EOF

# Review regressions use private homes and fault injection, so permissions behave alike even under root/Windows.
daily_review=$($PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/daily-review")" <<'DAILY_REVIEW'
import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

orch, base = sys.argv[1], Path(sys.argv[2])
base.mkdir(parents=True, exist_ok=True)
strip = ("ORCH_WORKER", "ORCH_LEAD", "ORCH_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "ORCH_PROFILES",
         "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
         "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ORCH_LEAD_ENV")
for key in strip:
    os.environ.pop(key, None)
os.environ.update(ORCH_HOME=str(base / "home"), ORCH_PROJECT_DIR=str(base), ORCH_BALANCE="off",
                  CLAUDE_CONFIG_DIR=str(base / "claude"), CODEX_HOME=str(base / "codex"))
loader = importlib.machinery.SourceFileLoader("daily_review", orch)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
m._quiet_state = True
today = m.day_str(m.now())

def check(name, fn):
    try:
        fn()
        print("OK " + name)
    except Exception as ex:
        print("NO " + name + " :: " + repr(ex))

def scene(name):
    home = base / name
    home.mkdir(exist_ok=True)
    m.ORCH_HOME = home
    m.DAILY_FILE = home / "daily_usage.json"
    m.DAILY_MARKER = home / ".daily-fold"
    m.SESSION_TOKENS_DIR = home / "session_tokens"
    m.USAGE_FILE = home / "usage.jsonl"
    m.SESSIONS_FILE = home / "sessions.json"
    m.USAGE_SNAPSHOT = home / "claude_usage.json"
    m.CODEX_USAGE_FILE = home / "codex_usage.json"
    m.BALANCE_FILE = home / "balances.json"
    return home

def counter(sid, stale=True):
    path = m.session_tokens_path(sid)
    m.write_json(path, {"session": sid, "project": str(base), "paid_via": "subscription",
                        "accounts": {"claude": "claude"}, "daily": {
                            today: {"claude-sonnet-5-5": {"in": 40, "out": 2, "cost": 0.01}}}})
    if stale:
        old = time.time() - m.SESSION_KEEP_SECONDS - 10
        os.utime(path, (old, old))
    return path

def snapshot():
    return m.DAILY_FILE.read_bytes(), m.DAILY_FILE.stat().st_mtime_ns

def large_store():
    store = m.daily_shape({})
    store.update(version=m.DAILY_FORMAT, _readme=m.DAILY_README)
    for age in range(60):
        day = (m.now().date() - dt.timedelta(days=age)).isoformat()
        for n in range(30):
            sid = "s-%s-%s" % (age, n)
            leaves = {"claude|claude-sonnet-5-5|claude|subscription": {"in": 100, "cr": 50, "cw": 5, "out": 10, "cost": .001},
                      "claude|claude-opus-5-5|claude|subscription": {"in": 20, "cr": 50, "cw": 5, "out": 5, "cost": .002},
                      "claude|claude-haiku-4-5|claude|subscription": {"in": 60, "cr": 50, "cw": 5, "out": 8, "cost": .003}}
            store["sessions"][sid] = {"project": str(base), "days": {day: leaves}, "source": "end",
                                      "paid_via": "subscription", "at": m.iso(m.now())}
    m.daily_prune(store)
    m.write_json(m.DAILY_FILE, store, compact=True)

def hot_path(reverted=False):
    home = scene("hot")
    large_store()
    stale = counter("quiet")
    before = snapshot()
    env = dict(os.environ, ORCH_HOME=str(home))
    command = [sys.executable, orch, "statusline"]
    if reverted:
        # Restore the pre-review sweep behaviour in the child, leaving repository sources untouched.
        code = """
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader('old_sweep', sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
def old_sweep():
    for path in m.daily_session_paths():
        if m.daily_fold_session_file(path):
            path.unlink()
m.sweep_orch_home = old_sweep
sys.exit(m.main(['statusline']))
"""
        command = [sys.executable, "-B", "-c", code, orch]
    p = subprocess.run(command, input="{}", text=True,
                       capture_output=True, env=env, timeout=60)
    assert p.returncode == 0, p.stderr
    assert snapshot() == before and stale.exists(), "statusline changed history or deleted the counter"
    m.daily_maintenance()
    assert not stale.exists() and "quiet" in m.daily_read()["sessions"]
    once = m.daily_leaves(m.daily_read(), [today])
    assert m.daily_leaves(m.daily_refresh(), [today]) == once
check("real statusline preserves a large store's bytes and mtime and leaves stale counts for one hook fold", hot_path)

def throttle():
    scene("throttle")
    counter("quiet")
    live = counter("live", stale=False)
    scans, writes, reads = [], [], []
    fold, write, read = m.daily_fold_limits, m.write_json, m.daily_read
    def counted_read():
        reads.append(True)
        return read()
    def scan(store, force=False):
        scans.append(True)
        return False
    def record(path, *args, **kwargs):
        if path == m.DAILY_FILE:
            writes.append(True)
        return write(path, *args, **kwargs)
    m.daily_fold_limits, m.write_json, m.daily_read = scan, record, counted_read
    try:
        for _ in range(2):
            m.hook_input = lambda: {"session_id": "live"}
            m.cmd_hook(SimpleNamespace(event="user-prompt"))
        assert len(scans) == 1 and len(writes) <= 1 and len(reads) == 1, (scans, writes, reads)
        assert "live" not in m.daily_read()["sessions"] and live.exists()
        before = snapshot()
        old = time.time() - m.DAILY_FOLD_GAP_SECONDS - 1
        os.utime(m.DAILY_MARKER, (old, old))
        m.cmd_hook(SimpleNamespace(event="user-prompt"))
        assert len(scans) == 2 and snapshot() == before, "unchanged maintenance rewrote the store"
        m.cmd_hook(SimpleNamespace(event="user-prompt"))
        assert len(scans) == 2, "an unchanged scan failed to touch the marker"
    finally:
        m.daily_fold_limits, m.write_json, m.daily_read = fold, write, read
check("prompt hooks throttle scans machine-wide without folding live counters or rewriting unchanged history", throttle)

def unreadable():
    scene("unreadable")
    large_store()
    stale = counter("quiet")
    before = snapshot()
    read = m._read_text_retry
    def denied(path, *args, **kwargs):
        if Path(path) == m.DAILY_FILE:
            raise PermissionError("injected unreadable daily store")
        return read(path, *args, **kwargs)
    m._read_text_retry = denied
    try:
        m.daily_maintenance()
        assert snapshot() == before and stale.exists(), "hook overwrote unreadable history"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rc = m.cmd_usage_daily(SimpleNamespace(days=1))
        assert rc != 0 and snapshot() == before, "report overwrote unreadable history"
        m.balance_store({"deepseek": ({"amount": 2, "currency": "USD"}, None)})
        assert snapshot() == before, "balance writer overwrote unreadable history"
    finally:
        m._read_text_retry = read
check("unreadable store survives hook, report and balance_store without replacement", unreadable)

def rejects(probe):
    try:
        probe()
    except AssertionError:
        return
    raise AssertionError("the reverted defect escaped its regression check")

check("negative probe: reverting the statusline fold makes its regression fail", lambda: rejects(lambda: hot_path(True)))

def revert_throttle():
    saved = m.daily_maintenance
    def old_maintenance(sid=None, ended=False):
        items = m.daily_session_items(m.daily_session_paths(sid=sid))
        def mutate(store):
            changed = m.daily_fold_limits(store)
            return m.daily_merge_items(store, items) or changed
        m.daily_update(mutate)
    m.daily_maintenance = old_maintenance
    try:
        rejects(throttle)
    finally:
        m.daily_maintenance = saved
check("negative probe: reverting prompt maintenance makes its regression fail", revert_throttle)

def revert_read():
    saved = m.daily_read
    def old_read():
        try:
            return saved()
        except m.StateError:
            return m.daily_shape({})
    m.daily_read = old_read
    try:
        rejects(unreadable)
    finally:
        m.daily_read = saved
check("negative probe: swallowing a store read error makes its regression fail", revert_read)

def batch_and_counter():
    scene("batch")
    paths = [counter("batch-%02d" % n) for n in range(m.DAILY_STALE_BATCH + 3)]
    denied = counter("denied")
    read, write = m._read_text_retry, m.write_json
    writes = []
    def fault(path, *args, **kwargs):
        if Path(path) == denied:
            raise PermissionError("injected unreadable counter")
        return read(path, *args, **kwargs)
    def record(path, *args, **kwargs):
        if path == m.DAILY_FILE:
            writes.append(True)
        return write(path, *args, **kwargs)
    m._read_text_retry, m.write_json = fault, record
    try:
        m.sweep_orch_home()
        m.daily_maintenance()
        assert denied.exists() and len(writes) == 1
        assert sum(not p.exists() for p in paths) == m.DAILY_STALE_BATCH
        m.daily_refresh()  # report folds all remaining files, one write
        assert denied.exists() and len(writes) == 2
        old = time.time() - m.DAILY_FOLD_GAP_SECONDS - 1
        os.utime(m.DAILY_MARKER, (old, old))
        m.daily_maintenance()                # this batch reaches the unreadable file too
        assert denied.exists() and len(writes) == 2
        corrupt = counter("bad-json")
        corrupt.write_text("{broken", encoding="utf-8")
        m.daily_refresh()
        assert corrupt.exists(), "bad JSON was deleted"
    finally:
        m._read_text_retry, m.write_json = read, write
    m.daily_refresh()
    assert not denied.exists() and "denied" in m.daily_read()["sessions"]
    before = snapshot()
    m.daily_refresh()
    assert snapshot() == before
check("stale counters fold in one bounded batch; unreadable and malformed files survive until readable", batch_and_counter)

def failed_write():
    scene("failed-write")
    stale = counter("pending")
    saved = m.write_json
    def denied(path, *args, **kwargs):
        if path == m.DAILY_FILE:
            raise m.StateError("injected failed store write")
        return saved(path, *args, **kwargs)
    m.write_json = denied
    try:
        m.daily_maintenance()
        assert stale.exists(), "failed store write removed the counter"
        try:
            m.daily_refresh()
        except m.StateError:
            pass
        assert stale.exists()
    finally:
        m.write_json = saved
    m.daily_refresh()
    assert not stale.exists() and "pending" in m.daily_read()["sessions"]
check("counter deletion waits for a successful store write", failed_write)

def corrupt_store():
    scene("corruption")
    for n, bad in enumerate(("{broken", "[]", '{"sessions": []}', '{"runs": {"bad": 3}}',
                             '{"sessions": {"s": {"days": []}}}', '{"limits": {"day": {"claude": []}}}')):
        m.DAILY_FILE.write_text(bad, encoding="utf-8")
        counter("c-%s" % n)
        m.daily_refresh()
        backups = list(m.ORCH_HOME.glob("daily_usage.json.corrupt*"))
        assert len(backups) == n + 1
        assert any(p.read_text(encoding="utf-8") == bad for p in backups)
        assert "c-%s" % n in m.daily_read()["sessions"]
check("invalid JSON and invalid shapes are preserved as unique .corrupt copies before recovery", corrupt_store)

def paid_via():
    scene("paid_via")
    tp = base / "paid_via.jsonl"
    ev = {"type": "assistant", "timestamp": m.iso(m.now()), "message": {"id": "bill", "model": "claude-sonnet-5-5",
          "usage": {"input_tokens": 100, "output_tokens": 10}}}
    tp.write_text(json.dumps(ev, separators=(",", ":")) + "\n", encoding="utf-8")
    for sid, env in (("key", {"ANTHROPIC_API_KEY": "fixture"}), ("login", {})):
        os.environ.update(env)
        m.session_tokens(sid, tp, "claude", base)
        entry = m.read_session_entry(m.session_tokens_path(sid))
        assert entry["paid_via"] == ("api" if env else "subscription"), entry
        os.environ.pop("ANTHROPIC_API_KEY", None)  # SessionEnd must use the frozen choice
        m.daily_session_end(sid, str(base), m.parse_transcript(tp)["daily"], base)
    leaves = m.daily_leaves(m.daily_refresh(), [today])
    assert {r["paid_via"] for r in leaves} == {"api", "subscription"}
    sub = m.daily_subscriptions(m.daily_read(), [today], leaves, str(base), False)[0]
    # Supply samples to make the share's denominator visible.
    store = m.daily_read()
    store["limits"] = {today: {"claude": {"seven_day": 20, "five_hour": 0}}}
    sub = m.daily_subscriptions(store, [today], leaves, str(base), False)[0]
    assert sub["tokens"] == 110, sub
    for key in ("ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"):
        os.environ[key] = "fixture"
        assert m.session_paid_via(base) == "api", key
        os.environ.pop(key)
check("lead API credentials are frozen through SessionEnd and excluded from subscription shares", paid_via)

def log_rotation():
    scene("rotation")
    def rec(rid, tokens):
        return {"kind": "run", "id": rid, "project": str(base), "provider": "codex", "model": "gpt-6.1-terra",
                "billing": "subscription", "ts": m.iso(m.now()), "usage": {"input_tokens": tokens}}
    def log(records):
        m.USAGE_FILE.write_text("".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")
    def total():
        return m.daily_totals(m.daily_leaves(m.daily_refresh(), [today]))["input"]
    a, b, c = rec("one", 10), rec("two", 20), rec("three", 30)
    log([a, b])
    assert total() == 30 and total() == 30
    log([b])
    assert total() == 30, "truncation erased or recounted runs"
    log([c, b, a, c])  # longer replacement, new first line, duplicate run
    assert total() == 60 and total() == 60, "replacement was read from the middle or counted twice"
    assert set(m.daily_read()["run_ids"][today]) == {"one", "two", "three"}
check("truncated and replaced usage logs preserve run totals and deduplicate by ledger run id", log_rotation)

def coverage():
    scene("coverage")
    yesterday = (m.now().date() - dt.timedelta(days=1)).isoformat()
    def row(day, project, tokens, cost, account="claude"):
        return {"day": day, "project": project, "provider": account, "model": "model", "account": account,
                "paid_via": "subscription", "runs": 1, "sessions": 0, "in": tokens, "cw": 0, "cr": 0,
                "out": 0, "cost": cost}
    rows = [row(today, "work", 100, 3), row(today, "other", 50, 1), row(yesterday, "other", 10000, 100)]
    store = m.daily_shape({"limits": {today: {"claude": {"seven_day": 30, "five_hour": 0}}}})
    sub = m.daily_subscriptions(store, [yesterday, today], rows, "work", False)[0]
    for key in ("seven_day", "five_hour"):
        w = sub["windows"][key]
        assert w["covered_days"] == [today] and w["missing_days"] == [yesterday]
        p = next(p for p in w["projects"] if p["project"] == "work")
        assert (p["token_share"], p["cost_share"]) == (.6667, .75), p
        assert (p["points_by_tokens"], p["points_by_cost"]) == ((20, 22.5) if key == "seven_day" else (0, 0))
    text = "\n".join(m.daily_subscription_lines([sub], m.day_start(yesterday).date(), m.now().date(), "work", False))
    assert "covers 1 of 2 days" in text and yesterday + " have no limit data" in text
    assert "20–22.5 weekly points" in text and "0–0 5-hour points" in text
    assert "0 points of the 5-hour windows" in text
    assert "five_hour" in m.daily_csv(rows, [sub]) and "seven_day" in m.daily_csv(rows, [sub])
    for r in rows:
        key = "|".join((r["project"], r["provider"], r["model"], r["account"], r["paid_via"]))
        store["runs"].setdefault(r["day"], {})[key] = {
            "runs": 1, "in": r["in"], "out": 0, "cost": r["cost"]}
    m.write_json(m.DAILY_FILE, store)
    captured = io.StringIO()
    with contextlib.redirect_stdout(captured):
        assert m.cmd_usage_daily(SimpleNamespace(days=2, json=True, all_projects=True, by="day")) == 0
    data = json.loads(captured.getvalue())
    windows = data["subscriptions"][0]["windows"]
    assert windows["seven_day"]["projects"][1]["points_by_cost"] == 22.5, windows
    assert windows["five_hour"]["projects"][1]["points_by_cost"] == 0, windows
    assert all(set(d["subscriptions"][0]["windows"]) == {"seven_day", "five_hour"} for d in data["daily"])
    del store["limits"][today]["claude"]["five_hour"]
    sub = m.daily_subscriptions(store, [yesterday, today], rows, "work", False)[0]
    text = "\n".join(m.daily_subscription_lines([sub], m.day_start(yesterday).date(), m.now().date(), "work", False))
    assert "no 5-hour data for these days" in text and sub["windows"]["five_hour"]["projects"] == []
    # Codex has the same independent coverage rule for primary and secondary windows.
    rows = [row(today, "work", 10, 1, "codex"), row(yesterday, "other", 10, 1, "codex")]
    store["limits"] = {today: {"codex": {"seven_day": 20}}, yesterday: {"codex": {"five_hour": 8}}}
    sub = m.daily_subscriptions(store, [yesterday, today], rows, "work", False)[0]
    assert sub["windows"]["seven_day"]["covered_days"] == [today]
    assert sub["windows"]["five_hour"]["covered_days"] == [yesterday]
check("partial coverage uses covered-day shares; both windows, zero and missing samples are explicit", coverage)

def usage_log_off():
    scene("off")
    counter("quiet")
    os.environ["ORCH_USAGE_LOG"] = "0"
    try:
        m.hook_input = lambda: {"session_id": "quiet"}
        m.cmd_hook(SimpleNamespace(event="session-end"))
        m.cmd_hook(SimpleNamespace(event="user-prompt"))
        assert m.daily_update(lambda store: True)[1] is False
        assert not m.DAILY_FILE.exists(), "the daily totals were written with the usage log off"
    finally:
        del os.environ["ORCH_USAGE_LOG"]
    m.daily_update(lambda store: True)
    assert m.DAILY_FILE.exists(), "the store is not written once the log is back on"
check("ORCH_USAGE_LOG=0 turns the daily totals off as well", usage_log_off)
DAILY_REVIEW
); daily_review_rc=$?
while IFS= read -r line; do
  case "$line" in
    "OK "*) ok "${line#OK }" ;;
    "NO "*) bad "${line#NO }" ;;
    *) [[ -z "$line" ]] || printf '%s\n' "$line" ;;
  esac
done <<< "$daily_review"
[[ $daily_review_rc -eq 0 ]] && ok "daily review checks completed" || bad "daily review checks aborted (rc=$daily_review_rc)"

