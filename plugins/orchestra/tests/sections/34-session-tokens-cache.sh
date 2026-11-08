# needs: 33-session-tokens-accounts
echo "── session tokens: cache reads (a third figure per account)"
CC="$TCFG/sess-cache.jsonl"
$PY - "$(native "$CC")" "$(native "$TCFG/sess-cache")" <<'EOF'
import json, os, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
def a(mid, inp, cr, out):
    return c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
              "message": {"id": mid, "model": "claude-opus-5-5",
                          "usage": {"input_tokens": inp, "cache_creation_input_tokens": 0,
                                    "cache_read_input_tokens": cr, "output_tokens": out}}})
open(sys.argv[1], "w", encoding="utf-8").write(a("k1", 1000, 20000, 100) + "\n")
os.makedirs(os.path.join(sys.argv[2], "subagents"), exist_ok=True)          # a subagent's own transcript
open(os.path.join(sys.argv[2], "subagents", "agent-k1.jsonl"), "w", encoding="utf-8").write(a("k2", 300, 8000, 50) + "\n")
EOF
$PY - "$AH/usage.jsonl" <<'EOF'
import json, sys
def rec(sid, prov, label, inp, cache, out):
    r = {"kind": "run", "session": sid, "provider": prov, "model": "m",
         "usage": {"input_tokens": inp, "cached_input_tokens": cache, "output_tokens": out}}
    if label is not None:
        r["label"] = label
    return json.dumps(r)
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(rec("sess-cache", "deepseek", "deepseek@client", 500, 3000, 60) + "\n")
    f.write(rec("sess-cache", "codex", None, 400, 0, 40) + "\n")            # no cache reads: no third figure
EOF
out=$(acct_sl sess-cache)
cache_block="Session in/out: Claude 1.3k/150 +28k cache"$'\n  Codex 400/40\n  DeepSeek@client 500/60 +3.0k cache'
[[ "${out//$'\r'/}" == *"$cache_block"* ]] \
  && ok "session cache: the thread and its subagents add up, and a run's cache follows its account on its own line" \
  || bad "session cache: account lines: $out"
lacks "$out" "Codex 400/40 +" "session cache: an account with no cache reads shows no third figure"
out2=$(acct_sl sess-cache); [[ "$out2" == "$out" ]] && ok "session cache: a second refresh counts the cache once" \
  || bad "session cache drifted on refresh: $out2"
# the figures are the `cache` column of `orch usage` for the same session
ORCH_HOME="$AH" $ORCH usage --session sess-cache --json > "$T/cache-usage.json"
printf '%s\n' "$out" > "$T/cache-line.txt"
$PY - "$(native "$T/cache-usage.json")" "$(native "$T/cache-line.txt")" <<'EOF' \
  && ok "session cache: the figures equal orch usage's cache column" || bad "session cache disagrees with orch usage"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["rows"]
line = open(sys.argv[2], encoding="utf-8").read()          # every account line of the session block
def fmt(n):
    if n < 1000:
        return str(n)
    if n < 10000:
        return "%.1fk" % (n / 1000.0)
    if n < 1000000:
        return "%dk" % round(n / 1000.0)
    return "%.1fM" % (n / 1000000.0)
fig = {}
for r in rows:
    u = r.get("usage") or {}
    key = "claude" if r["who"] == "orchestrator" or r["who"].startswith("subagent ") else r["who"]
    t = fig.setdefault(key, [0, 0, 0])
    for i, k in enumerate(("input_tokens", "output_tokens", "cached_input_tokens")):
        t[i] += int(u.get(k) or 0)
def counter(key, name):
    i, o, c = fig[key]
    return "%s %s/%s%s" % (name, fmt(i), fmt(o), (" +%s cache" % fmt(c)) if c else "")
assert counter("claude", "Claude") in line, (counter("claude", "Claude"), line)
assert counter("deepseek@client", "DeepSeek@client") in line, (fig, line)
assert counter("codex", "Codex") in line, (fig, line)
EOF
# a message re-sent with growing usage counts its cache once, at its last figure
CF="$TCFG/sess-cache-again.jsonl"
$PY - "$(native "$CF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
open(sys.argv[1], "w", encoding="utf-8").write(c({"type": "assistant", "timestamp": "2026-11-02T10:00:00.000Z",
    "message": {"id": "r1", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 1000, "cache_read_input_tokens": 100000, "output_tokens": 10}}}) + "\n")
EOF
out=$(acct_sl sess-cache-again)
contains "$out" "Session in/out: Claude 1.0k/10 +100k cache" "a message's first copy counts its cache"
$PY - "$(native "$CF")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(c({"type": "assistant", "timestamp": "2026-11-02T10:00:01.000Z",
               "message": {"id": "r1", "model": "claude-opus-5-5",
                           "usage": {"input_tokens": 1200, "cache_read_input_tokens": 250000, "output_tokens": 20}}}) + "\n")
EOF
out=$(acct_sl sess-cache-again)
contains "$out" "Session in/out: Claude 1.2k/20 +250k cache" "a re-sent message counts its cache once, at its last figure"
# an entry saved in the previous format has no cache in its totals: it is parsed again from offset 0
$PY - "$AH" <<'EOF'
import json, os, sys, time
home = sys.argv[1]
os.makedirs(os.path.join(home, "session_tokens"), exist_ok=True)
entry = {"format": 2, "files": {"old-transcript": {"offset": 1, "in": 7000, "out": 900, "provider": "claude"}},
         "ledger": {"deepseek@client": {"input": 900, "output": 90}}, "ledger_offset": 0,
         "updated": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - 120))}
json.dump(entry, open(os.path.join(home, "session_tokens", "sess-cache-again.json"), "w", encoding="utf-8"))
EOF
out=$(acct_sl sess-cache-again)
contains "$out" "Session in/out: Claude 1.2k/20 +250k cache" "an entry in the previous format is rebuilt from the transcript, cache included"
lacks "$out" "7.0k/900" "the previous format's cache-less totals are gone"
$PY - "$AH" <<'EOF' && ok "the rebuilt entry is saved in the new format, with cache in its files" || bad "the rebuilt entry keeps the old format"
import json, os, sys
e = json.load(open(os.path.join(sys.argv[1], "session_tokens", "sess-cache-again.json"), encoding="utf-8"))
assert e.get("format") == 3, e
assert e["files"] and all("cache" in s for s in e["files"].values() if isinstance(s, dict)), e
EOF
out2=$(acct_sl sess-cache-again); [[ "$out2" == "$out" ]] && ok "a rebuilt entry is not parsed twice" || bad "rebuilt entry drifted: $out2"

