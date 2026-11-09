# needs: 32-session-tokens
echo "── session tokens per account (a profile label, never a sum over a provider)"
AH="$(native "$T/acct-home")"; mkdir -p "$AH"
acct() { ORCH_HOME="$AH" $ORCH "$@"; }
acct_sl() {      # acct_sl <session> [extra env…]: the status line of that session, run in the test repository
  local sid=$1; shift
  printf '{"session_id":"%s","transcript_path":"%s","workspace":{"current_dir":"%s"}}' \
    "$sid" "$(native "$TCFG/$sid.jsonl")" "$(native "$REPO")" | env "$@" ORCH_HOME="$AH" $ORCH statusline
}
cp "$TCFG/sess-tok.jsonl" "$TCFG/sess-acct.jsonl"       # the native thread: 1500 in / 150 out
$PY - "$AH/usage.jsonl" <<'EOF'
import json, sys
def rec(sid, prov, label, inp, out):
    r = {"kind": "run", "session": sid, "provider": prov, "model": "m",
         "usage": {"input_tokens": inp, "cached_input_tokens": 0, "output_tokens": out}}
    if label is not None:
        r["label"] = label
    return json.dumps(r)
with open(sys.argv[1], "a", encoding="utf-8") as f:
    for line in (rec("sess-acct", "deepseek", "deepseek@client", 500, 60),
                 rec("sess-acct", "deepseek", "deepseek@personal", 100, 10),
                 rec("sess-acct", "deepseek", "deepseek@client", 20, 5),
                 rec("sess-acct", "codex", None, 400, 40),               # an old record: no label
                 rec("sess-acct", "codex", "codex", 100, 10),
                 rec("sess-acct", "codex", "codex@work", 90, 10),        # a non-default login profile
                 rec("sess-acct", "claude", "claude", 200, 20),          # orch run claude on the default login
                 rec("sess-other", "deepseek", "deepseek@other", 7, 7)):
        f.write(line + "\n")
EOF
out=$(acct_sl sess-acct)
acct_block="Session in/out: Claude 1.7k/170 +6.0k cache"$'\n  Codex 500/50\n  Codex@work 90/10\n  DeepSeek@client 520/65\n  DeepSeek@personal 100/10'
[[ "${out//$'\r'/}" == *"$acct_block"* ]] \
  && ok "session tokens: one counter per account, plain account first, labels alphabetical, cache only where there is some" \
  || bad "session tokens: account lines: $out"
grep -qE "DeepSeek [0-9]|DeepSeek@other" <<<"$out" && bad "session tokens: a sum over the keys, or another session's run: $out" \
  || ok "session tokens: two keys of one provider are not added up"
contains "$out" "^  Codex 500/50" "a run without a label counts under its provider, with the plain codex runs"
contains "$out" "Claude 1.7k/170" "orch run claude on the default login adds up with the native thread"
out2=$(acct_sl sess-acct); [[ "$out2" == "$out" ]] && ok "session tokens: a second refresh changes nothing" || bad "session tokens drifted on refresh: $out2"
# a native session billed to a key profile counts under that profile's label, the default-login run stays apart
acct profile set claude work --key ANTHROPIC_API_KEY_WORK >/dev/null
out=$(acct_sl sess-acct ORCH_PROFILES=claude=work)
contains "$out" "^Session in/out: Claude 200/20" "a native session on a key profile keeps the default-login counter on the heading line"
contains "$out" "^  Claude@work 1.5k/150 +6.0k cache (est. \$0.00/\$10)" "a native session on a key profile shows its label, with its money in the same parentheses"
# its apiKeyHelper names that profile, so the thread keeps billing there while runs have moved to the fallback
acct profile set claude personal >/dev/null
acct profile set claude work --fallback personal >/dev/null
acct quota set claude@work exhausted >/dev/null
out=$(acct_sl sess-acct ORCH_PROFILES=claude=work)
contains "$out" "^  Claude@work 1.5k/150 +6.0k cache" "a native session keeps its key's label while runs use the fallback"
acct quota clear claude@work >/dev/null
acct profile set claude work --fallback none >/dev/null
out=$(acct_sl sess-acct)
contains "$out" "^Session in/out: Claude 1.7k/170 +6.0k cache" "the same session on the default login adds up again"
# an old-format cache entry (keyed by provider, no format mark) is rebuilt from the ledger with labels
$PY - "$AH" <<'EOF'
import json, os, sys, time
home = sys.argv[1]
size = os.path.getsize(os.path.join(home, "usage.jsonl"))
with open(os.path.join(home, "usage.jsonl"), "a", encoding="utf-8") as f:
    for label, i, o in (("deepseek@client", 500, 60), ("deepseek@personal", 100, 10)):
        f.write(json.dumps({"kind": "run", "session": "sess-old", "provider": "deepseek", "label": label,
                            "usage": {"input_tokens": i, "output_tokens": o}}) + "\n")
cache = os.path.join(home, "session_tokens.json")      # the cache of all sessions, as 0.18.0 and earlier wrote it
data = {"sess-old": {"files": {}, "ledger": {"deepseek": {"input": 600, "output": 70}},
                     "ledger_offset": size + 1000000, "updated": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())}}
json.dump(data, open(cache, "w", encoding="utf-8"))
EOF
out=$(acct_sl sess-old)
contains "$out" "^Session in/out: DeepSeek@client 500/60" "an old-format cache entry is rebuilt with labels"
contains "$out" "^  DeepSeek@personal 100/10" "an old-format cache entry gives each account its own line"
grep -qE "DeepSeek [0-9]" <<<"$out" && bad "old cache: the stale provider sum survived: $out" || ok "old cache: no stale provider sum next to the keys"
out2=$(acct_sl sess-old); [[ "$out2" == "$out" ]] && ok "a rebuilt entry is not read twice" || bad "rebuilt entry drifted: $out2"
$PY - "$AH" <<'EOF' && ok "the rebuilt entry carries the format mark" || bad "the rebuilt entry has no format mark"
import json, os, sys
e = json.load(open(os.path.join(sys.argv[1], "session_tokens", "sess-old.json"), encoding="utf-8"))
assert e.get("format") == 3 and "deepseek" not in e["ledger"] and set(e["ledger"]) == {"deepseek@client", "deepseek@personal"}, e
EOF
# a malformed cache entry and malformed ledger lines never break the status line
$PY - "$AH" <<'EOF'
import json, os, sys, time
home = sys.argv[1]
with open(os.path.join(home, "usage.jsonl"), "a", encoding="utf-8") as f:
    f.write("[1, 2]\n")
    f.write(json.dumps({"kind": "run", "session": "sess-bad", "provider": "codex", "label": "codex@work",
                        "usage": {"input_tokens": "many", "output_tokens": 1}}) + "\n")
    f.write(json.dumps({"kind": "run", "session": "sess-bad", "provider": "codex", "label": "codex@work",
                        "usage": {"input_tokens": 10, "output_tokens": 1}}) + "\n")
    for prov, i in (("deepseek", 3), ("codex", 4)):        # land on the damaged cache values below
        f.write(json.dumps({"kind": "run", "session": "sess-bad", "provider": prov,
                            "usage": {"input_tokens": i, "output_tokens": 1}}) + "\n")
cache = os.path.join(home, "session_tokens.json")
data = json.load(open(cache, encoding="utf-8"))
data["sess-bad"] = {"format": 3, "files": {"x": "junk", "y": {"in": "a", "out": None, "cache": None, "provider": 5}},
                    "ledger": {"deepseek": "junk", "codex": {"input": "x", "output": None}, "claude": [1]},
                    "ledger_offset": 0, "updated": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())}
json.dump(data, open(cache, "w", encoding="utf-8"))
EOF
out=$(acct_sl sess-bad); rc=$?
[[ $rc -eq 0 ]] && contains "$out" "Session in/out: Codex 4/1" "the status line survives a malformed cache entry and ledger lines" \
  || bad "malformed entry: rc=$rc out=$out"
[[ "${out//$'\r'/}" == *"Session in/out: Codex 4/1"$'\n  Codex@work 10/2\n  DeepSeek 3/1'* ]] \
  && ok "malformed entry: the accounts keep their own lines and their order" || bad "malformed entry: account lines: $out"
# end to end: the labels `orch run` writes (two deepseek keys, the default claude login) reach the status line
acct profile set deepseek client --key DEEPSEEK_KEY_CLIENT >/dev/null
acct profile set deepseek personal --key DEEPSEEK_KEY_PERSONAL >/dev/null
cp "$TCFG/sess-tok.jsonl" "$TCFG/sess-e2e.jsonl"
e2e() { CLAUDE_CODE_SESSION_ID=sess-e2e FAKE_CLAUDE=ok DEEPSEEK_KEY_CLIENT=sk-a DEEPSEEK_KEY_PERSONAL=sk-b ORCH_HOME="$AH" $ORCH run "$@" >/dev/null; }
e2e deepseek --profile client "x"; expect_rc 0 $? "run on the first deepseek key"
e2e deepseek --profile personal "x"; expect_rc 0 $? "run on the second deepseek key"
e2e claude "x"; expect_rc 0 $? "run claude on the default login"
line=$(acct_sl sess-e2e); block=$(grep -A2 "^Session in/out:" <<<"$line")
grep -qE "^Session in/out: Claude 1\.[0-9]k/[0-9]+ \+6\.4k cache" <<<"$block" &&
  grep -qE "^  DeepSeek@client [0-9]+/[0-9]+ \+400 cache" <<<"$block" &&
  grep -qE "^  DeepSeek@personal [0-9]+/[0-9]+ \+400 cache" <<<"$block" \
  && ok "end to end: two keys and the native login, three counters on three lines" || bad "end to end session lines: $block"
[[ "$block" == *"Claude 1.5k/150"* ]] && bad "end to end: the claude run did not add to the native thread: $block" \
  || ok "end to end: orch run claude adds to the native Claude counter"
# a session led by another provider: its own thread is that lead's account, never the bare provider
$PY - "$(native "$TCFG/sess-leadacct.jsonl")" <<'EOF'
import json, sys
c = lambda o: json.dumps(o, separators=(",", ":"))
ev = {"type": "assistant", "timestamp": "2026-11-02T11:00:00.000Z",
      "message": {"id": "l1", "model": "deepseek-v4-pro",
                  "usage": {"input_tokens": 9, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 4}}}
open(sys.argv[1], "w", encoding="utf-8").write(c(ev) + "\n")
EOF
out=$(acct_sl sess-leadacct ORCH_LEAD=deepseek@work)
contains "$out" "^Session in/out: DeepSeek@work 9/4" "a lead's own thread counts under the lead's account"
grep -qE "Session in/out: DeepSeek 9/4" <<<"$out" && bad "the lead's thread fell back to the bare provider: $out" \
  || ok "the lead's thread never shows as the bare provider"

