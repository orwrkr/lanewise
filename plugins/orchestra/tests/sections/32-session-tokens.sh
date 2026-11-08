# needs: 24-codex-limits
echo "── session tokens per provider (their own status line)"
rm -rf "$T/cx9"; mkdir -p "$T/cx9/sessions/2026/11/02"
export CODEX_HOME; CODEX_HOME="$(native "$T/cx9")"
$PY "$(native "$T/gen_rollout.py")" "$(native "$T/cx9/sessions/2026/11/02/rollout-0001.jsonl")" 81 2 20 168
TCFG="$T/claude-cfg/projects/$(native "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$TCFG"
$PY - "$(native "$TCFG/sess-tok.jsonl")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
def a(mid, inp, cw, cr, out):
    return c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
              "message": {"id": mid, "model": "claude-opus-5-5",
                          "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw,
                                    "cache_read_input_tokens": cr, "output_tokens": out}}})
open(sys.argv[1], "w", encoding="utf-8").write(
    a("t1", 1000, 200, 5000, 100) + "\n" + a("t2", 300, 0, 1000, 50) + "\n")
EOF
$PY - "$(native "$ORCH_HOME/usage.jsonl")" <<'EOF'
import json, sys
def rec(prov, model, inp, out):
    return json.dumps({"kind": "run", "session": "sess-tok", "provider": prov, "model": model,
                       "usage": {"input_tokens": inp, "cached_input_tokens": 0, "output_tokens": out}})
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(rec("codex", "gpt-6.1-terra", 400, 40) + "\n")
    f.write(rec("deepseek", "deepseek-v4-pro", 500, 60) + "\n")
EOF
out=$(printf '{"session_id":"sess-tok","transcript_path":"%s","workspace":{"current_dir":"%s"}}' \
      "$(native "$TCFG/sess-tok.jsonl")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Codex · 5h 81%" "status line: codex limits part"
contains "$out" "week 20%" "status line: codex week part"
contains "$out" "Session in/out: Claude 1.5k/150 +6.0k cache" "session tokens: claude from the transcript (with its cache reads), runs from the ledger"
[[ "$(sed -n 2p <<<"$out")" == "Codex · 5h 81%"* && "$(sed -n 3p <<<"$out")" == "Session in/out: "* ]] \
  && ok "Codex limits and session tokens are on lines of their own" || bad "status line layout: $out"
sl3=$(sed -n 3p <<<"$out"); sl4=$(sed -n 4p <<<"$out"); sl5=$(sed -n 5p <<<"$out")
sl3=${sl3%$'\r'}; sl4=${sl4%$'\r'}; sl5=${sl5%$'\r'}
[[ "$sl3" == "Session in/out: Claude 1.5k/150 +6.0k cache" &&
   "$sl4" == "  Codex 400/40" && "$sl5" == "  DeepSeek 500/60"* && "$(wc -l <<<"$out")" -eq 5 ]] \
  && ok "session tokens: three accounts are three lines, the later ones indented by two spaces in the same order" \
  || bad "session tokens: account lines: $out"
out=$(printf '{"session_id":"sess-tok","transcript_path":"%s","workspace":{"current_dir":"%s"}}' \
      "$(native "$TCFG/sess-tok.jsonl")" "$(native "$REPO")" | $ORCH statusline --then "echo mine")
contains "$out" "^mine  " "statusline --then: the operator's own line stays first"
contains "$out" "Session in/out: Claude 1.5k/150" "statusline --then keeps the Codex and session lines"
$ORCH usage --session sess-tok --json > "$T/usage-tok.json"
$PY - "$(native "$T/usage-tok.json")" <<'EOF' && ok "session tokens agree with orch usage --session" || bad "session tokens disagree with orch usage"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["rows"]
by = {}
for r in rows:
    u = r.get("usage") or {}
    by[r["who"]] = (int(u.get("input_tokens") or 0), int(u.get("output_tokens") or 0),
                    int(u.get("cached_input_tokens") or 0))
assert by["orchestrator"] == (1500, 150, 6000), by
assert by["codex"] == (400, 40, 0), by
assert by["deepseek"] == (500, 60, 0), by
assert {r["model"] for r in rows} == {"claude-opus-5-5", "gpt-6.1-terra", "deepseek-v4-pro"}, [r["model"] for r in rows]
EOF
INCF="$TCFG/sess-inc.jsonl"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
open(sys.argv[1], "w", encoding="utf-8").write(c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
    "message": {"id": "i1", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 1000, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 5000, "output_tokens": 100}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 1.2k/100 +5.0k cache" "first run counts the transcript once, cache reads too"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(c({"type": "assistant", "timestamp": "2026-11-02T10:05:00.000Z",
               "message": {"id": "i2", "model": "claude-opus-5-5",
                           "usage": {"input_tokens": 300, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1000, "output_tokens": 50}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 1.5k/150 +6.0k cache" "appended lines are counted once (not re-read)"
$PY - "$(native "$INCF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
open(sys.argv[1], "w", encoding="utf-8").write(c({"type": "assistant", "timestamp": "2026-11-02T10:06:00.000Z",
    "message": {"id": "i3", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 500, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 30}}}) + "\n")
EOF
out=$(printf '{"session_id":"sess-inc","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$INCF")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Session in/out: Claude 500/30" "a shrunken transcript restarts from scratch"
lacks "$out" " cache" "a shrunken transcript resets its cache reads too"
out=$(printf '{"session_id":"sess-empty","workspace":{"current_dir":"%s"}}' "$(native "$REPO")" | $ORCH statusline)
grep -q "Session in/out:" <<<"$out" && bad "session line shown with no tokens" || ok "no session line with no tokens"

FORK="$TCFG/sess-fork-tokens.jsonl"
$PY - "$(native "$FORK")" <<'EOF'
import json, sys
c = lambda x: json.dumps(x, separators=(",", ":"))
def a(mid, ts, n):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": "claude-opus-5-5", "usage": {"input_tokens": n, "output_tokens": n}}}
events = [{"type": "mode"}, {"type": "queue-operation", "timestamp": "2026-11-02T12:00:00.000Z"},
          a("old", "2026-11-02T10:00:00.000Z", 900), a("new", "2026-11-02T13:00:00.000Z", 100)]
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(map(c, events)) + "\n")
EOF
fork_sl() { printf '{"session_id":"sess-fork-tokens","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$FORK")" "$(native "$REPO")" | $ORCH statusline; }
out=$(fork_sl); contains "$out" "Claude 100/100" "fork tokens exclude copies on first parse"
$PY - "$(native "$FORK")" <<'EOF'
import json, sys
def a(mid, ts, n):
    return json.dumps({"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": "claude-opus-5-5", "usage": {"input_tokens": n, "output_tokens": n}}}, separators=(",", ":"))
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(a("old2", "2026-11-02T11:00:00.000Z", 800) + "\n" + a("new2", "2026-11-02T14:00:00.000Z", 50) + "\n")
EOF
out=$(fork_sl); contains "$out" "Claude 150/150" "fork tokens exclude copies after saved offset"
unset -f fork_sl
$PY - "$(native "$TCFG/sess-attachment.jsonl")" <<'EOF'
import json, sys
events = [{"type": "attachment", "timestamp": "2026-11-02T09:00:00.000Z"},
          {"type": "user", "timestamp": "2026-11-02T10:00:00.000Z"},
          {"type": "assistant", "timestamp": "2026-11-02T11:00:00.000Z", "message": {"id": "a", "model": "claude-opus-5-5", "usage": {"input_tokens": 123, "output_tokens": 12}}}]
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(json.dumps(e, separators=(",", ":")) for e in events) + "\n")
EOF
out=$(printf '{"session_id":"sess-attachment","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$(native "$TCFG/sess-attachment.jsonl")" "$(native "$REPO")" | $ORCH statusline)
contains "$out" "Claude 123/12" "an earlier attachment does not hide ordinary usage"

