echo "── project rules for every executor, usage ledger"
# standalone setup (a no-op once the earlier sections have run)
[[ -f "$T/home/secrets.env" ]] || printf '# keys\r\nexport DEEPSEEK_API_KEY="sk-from-file"\r\n' > "$T/home/secrets.env"
printf '# Rules\nCLAUDE-MARKER\n@AGENTS.md\n' > "$REPO/CLAUDE.md"; printf 'AGENTS-MARKER\n' > "$REPO/AGENTS.md"
FAKE_CLAUDE=ok $ORCH run deepseek --task "Café parser tests" "x" >/dev/null
check 'r["claude_n"] == 1 and r["agents_n"] == 1' "deepseek: CLAUDE.md + AGENTS.md, @import inlined once"
FAKE_CODEX=ok $ORCH run codex --model gpt-6.1-terra --effort high "implement" >/dev/null
out=$(cat "$REPO"/.orchestra/runs/cod-*/codex_prompt.md | tail -c 2000)
contains "$out" "CLAUDE-MARKER" "codex: CLAUDE.md rules added to the prompt"
grep -q "AGENTS-MARKER" "$REPO"/.orchestra/runs/cod-*/codex_prompt.md && bad "codex got AGENTS.md twice" || ok "codex: AGENTS.md left to codex itself"
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
[[ -n "$RID" ]] && grep -q "IGNORED-AGENTS" "$REPO/.orchestra/runs/$RID/context.md" \
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
json.dump({"agentType": "orchestra:orch-sonnet-high", "description": "Find naïve parse calls"},
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

