echo "── prices: show, check, diff, apply (orch prices)"
PRD="$T/prices-home"; PRH="$(native "$PRD")"; PRP="$T/prices-props"; PRPN="$(native "$PRP")"
mkdir -p "$PRD" "$PRP"
pr() { ORCH_HOME="$PRH" $ORCH prices "$@"; }
PRICES_BUILTIN="$(native "$PLUGIN/registry/prices.json")"
prices_sha() { $PY -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$PRICES_BUILTIN"; }
PRICES_SHA_BEFORE=$(prices_sha)
PRGEN="$(native "$T/prices_gen.py")"
cat > "$T/prices_gen.py" <<'EOF'
import datetime as dt, json, sys
mode, where = sys.argv[1], sys.argv[2]
today = dt.date.today()
def w(path, data):
    with open(path, "w", encoding="utf-8") as f:
        f.write(data if isinstance(data, str) else json.dumps(data, indent=2))
PEAK = {"off_peak_multiplier": 0.5, "peak_days": ["mon", "tue", "wed", "thu", "fri"],
        "peak_windows_utc": [["01:00", "04:00"], ["06:00", "10:00"]]}
DS = "https://api-docs.deepseek.com/quick_start/pricing"
OA = "https://developers.openai.com/api/docs/pricing"
if mode == "pin":        # synthetic personal entries, written by hand (no `models` list in the source)
    w(where + "/prices.json", {"usd_per_1m_tokens": {
        "deepseek-test-a": dict({"input": 1.0, "cache_read": 0.1, "output": 2.0}, **PEAK),
        "deepseek-test-b": {"input": 2.0, "cache_read": 0.2, "output": 4.0},
        "deepseek-test-d": {"input": 3.0, "cache_read": 0.3, "output": 6.0},
        "gpt-test-a": {"input": 1.0, "cache_read": 0.1, "output": 2.0},
        "gpt-test-b": {"input": 5.0, "cache_read": 0.5, "output": 9.0}},
        "sources": {"deepseek": {"as_of": (today - dt.timedelta(days=10)).isoformat(), "source": "api-docs.example.test/pricing"}}})
elif mode == "showpin":  # an override and a source dated 40 days back
    w(where + "/prices.json", {"usd_per_1m_tokens": {"deepseek-flash": {"input": 0.31, "cache_read": 0.006, "output": 1.2}},
        "sources": {"claude": {"as_of": (today - dt.timedelta(days=40)).isoformat(), "source": "example.test/prices"}}})
elif mode == "props":
    t = today.isoformat()
    p1 = {"checked_on": t, "providers": {
        "deepseek": {"source": DS, "notes": "test-a raised", "models": {
            "deepseek-test-a": {"input": 1.5, "cache_read": 0.1, "output": 2.0},
            "deepseek-test-b": {"input": 2.0, "cache_read": 0.2, "output": 4.0},
            "deepseek-test-c": {"input": 9, "cache_read": 1, "output": 9}}},
        "codex": {"source": OA, "models": {"gpt-test-a": {"input": 1.0, "cache_read": 0.1, "output": 2.2}}}}}
    w(where + "/p1.json", p1)
    w(where + "/report.md", "I read the pages.\n\n```json\n{ not json at all\n```\n\n```json\n{\"note\": \"no providers key\"}\n```\n\n"
      "Here is the proposal:\n\n```json\n" + json.dumps(p1, indent=2) + "\n```\n\nSTATUS: DONE\n")
    w(where + "/nochange.json", {"checked_on": t, "providers": {"deepseek": {"source": DS, "models": {
        "deepseek-test-a": dict({"input": 1.0, "cache_read": 0.1, "output": 2.0}, **PEAK),
        "deepseek-test-b": {"input": 2.0, "cache_read": 0.2, "output": 4.0},
        "deepseek-test-d": {"input": 3.0, "cache_read": 0.3, "output": 6.0}}}}})
    ok = {"input": 1, "cache_read": 0.1, "output": 2}
    w(where + "/bad-provider.json", {"checked_on": t, "providers": {"mistral": {"models": {"mistral-x": ok}}}})
    w(where + "/negative.json", {"checked_on": t, "providers": {"deepseek": {"models": {"deepseek-test-a": dict(ok, input=-1)}}}})
    w(where + "/wrong-provider.json", {"checked_on": t, "providers": {"codex": {"models": {"deepseek-test-a": ok}}}})
    w(where + "/future.json", {"checked_on": (today + dt.timedelta(days=400)).isoformat(),
                               "providers": {"deepseek": {"models": {"deepseek-test-a": ok}}}})
    w(where + "/missing-field.json", {"checked_on": t, "providers": {"deepseek": {"models": {
        "deepseek-test-a": {"input": 1, "output": 2}}}}})
    w(where + "/garbage.txt", "no proposal here\n```json\n[1, 2]\n```\n")
EOF
$PY "$PRGEN" props "$PRPN" || bad "prices: could not write the proposals"

# show: the built-in figures, per provider, with source, date, age and origin
out=$(pr show); expect_rc 0 $? "prices show"
contains "$out" "claude: platform.claude.com.*as of [0-9-]* ([0-9]* days old), built in" "prices show: a provider's source, date, age and origin"
[[ -e "$PRD/prices.json" ]] && bad "prices show created the personal file" || ok "prices show writes nothing"
pr show --json > "$T/prices-show.json"; expect_rc 0 $? "prices show --json"
$PY - "$(native "$T/prices-show.json")" "$PRICES_BUILTIN" <<'EOF' && ok "prices show: the built-in figures, machine-readable and in the text" || bad "prices show: built-in figures differ"
import json, sys
shown = json.load(open(sys.argv[1], encoding="utf-8"))
built = json.load(open(sys.argv[2], encoding="utf-8"))
seen = {k: v for p in shown["providers"].values() for k, v in p["models"].items()}
assert set(seen) == set(built["usd_per_1m_tokens"]), (sorted(seen), sorted(built["usd_per_1m_tokens"]))
for key, raw in built["usd_per_1m_tokens"].items():
    v = seen[key]
    assert v["origin"] == "built-in", key
    if isinstance(raw, list):
        assert v["dated_entries"] == len(raw) and v["active"], key
    else:
        for f, x in raw.items():
            if f in ("input", "cache_read", "cache_write", "output", "off_peak_multiplier"):
                assert v["rates"][f] == x, (key, f)
for name, p in shown["providers"].items():
    assert p["origin"] == "built-in" and p["as_of"] == built["sources"][name]["as_of"], name
    assert p["source"] == built["sources"][name]["source"], name
assert "off_peak_multiplier" in seen["deepseek-flash"]["rates"] and "peak_windows_utc" in seen["deepseek-flash"]["rates"]
EOF
out=$(pr); contains "$out" "deepseek-flash" "prices (no action) is show"
contains "$out" "peak: the rates are peak rates; off-peak x0.5" "prices show: DeepSeek's peak information"
pr --json | $PY -c 'import json, sys; json.load(sys.stdin)' && ok "prices --json before the action works too" || bad "prices --json before the action"

# show: a personal override and a source dated 40 days back
$PY "$PRGEN" showpin "$PRH"
out=$(pr show)
contains "$out" "claude: example.test/prices, as of [0-9-]* (40 days old), from your personal prices.json" "prices show: a personal source and its age"
contains "$out" "older than 30 days: run .orch prices check" "prices show: the stale flag points to prices check"
contains "$out" "deepseek-flash  *input 0.31 .*\[personal\]" "prices show: a personal override is marked"
pr show --json | $PY -c '
import json, sys
d = json.load(sys.stdin)
assert d["providers"]["claude"]["stale"] is True and d["providers"]["claude"]["origin"] == "personal" and d["providers"]["claude"]["age_days"] == 40
assert d["providers"]["deepseek"]["models"]["deepseek-flash"]["origin"] == "personal"
assert d["providers"]["deepseek"]["models"]["deepseek-flash"]["rates"]["input"] == 0.31
assert d["providers"]["deepseek"]["models"]["deepseek-v4-pro"]["origin"] == "built-in"
' && ok "prices show --json: personal origin and the stale flag" || bad "prices show --json: personal data"
rm -f "$PRD/prices.json"

# check: TASK.md with each provider's https source and exactly its model keys
out=$(pr check); expect_rc 0 $? "prices check"
TASK=$(head -n 1 <<<"$out" | tr -d '\r')
contains "$out" "orch guide spend" "prices check points to the guide"
[[ -f "$TASK" ]] && ok "prices check wrote TASK.md" || bad "prices check: no TASK.md at $TASK"
$PY - "$TASK" "$PRICES_BUILTIN" <<'EOF' && ok "prices check: TASK.md names each https source and exactly its model keys" || bad "prices check: TASK.md content"
import json, re, sys
text = open(sys.argv[1], encoding="utf-8", newline="").read()
built = json.load(open(sys.argv[2], encoding="utf-8"))
keys = set(re.findall(r"^- `([^`]+)`:", text, re.M))
assert keys == set(built["usd_per_1m_tokens"]), (sorted(keys), sorted(built["usd_per_1m_tokens"]))
for name, s in built["sources"].items():
    assert "### %s: https://%s" % (name, s["source"]) in text, name
for needle in ("STATUS: DONE | PARTIAL | BLOCKED", "exactly one fenced", "Never guess", "peak_windows_utc", "```json"):
    assert needle in text, needle
assert "\r" not in text
EOF
out=$(pr check --provider deepseek); expect_rc 0 $? "prices check --provider"
TASK=$(head -n 1 <<<"$out" | tr -d '\r')
$PY - "$TASK" "$PRICES_BUILTIN" <<'EOF' && ok "prices check --provider: only that provider's source and keys" || bad "prices check --provider: TASK.md content"
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
built = json.load(open(sys.argv[2], encoding="utf-8"))
keys = set(re.findall(r"^- `([^`]+)`:", text, re.M))
assert keys == {k for k in built["usd_per_1m_tokens"] if k.startswith("deepseek-")}, sorted(keys)
assert "api-docs.deepseek.com" in text and "platform.claude.com" not in text and "openai.com" not in text
assert "gpt-" not in text and "sonnet" not in text
EOF
pr check --provider nope >/dev/null 2>&1; expect_rc 2 $? "prices check: an unknown provider is refused"

# diff: a plain proposal, the same one inside a report, changes with percentages, unchanged, left out, new
$PY "$PRGEN" pin "$PRH"
out=$(pr diff "$PRPN/p1.json"); expect_rc 0 $? "prices diff of a plain JSON proposal"
contains "$out" "input: 1 → 1.5 (+50.0%)  ⚠ large change" "prices diff: a changed rate, its percentage and the mark on 25% or more"
contains "$out" "output: 2 → 2.2 (+10.0%)$" "prices diff: a small change carries no mark"
contains "$out" "unchanged: deepseek-test-b" "prices diff: unchanged models in one line"
contains "$out" "not found on the page: .*deepseek-test-d" "prices diff: a model left out is not found on the page"
contains "$out" "not found on the page: .*gpt-test-b" "prices diff: …per provider"
contains "$out" "new (not in our table, never applied): deepseek-test-c" "prices diff: a new model key is reported"
contains "$out" "notes: test-a raised" "prices diff: the proposal's notes"
out2=$(pr diff "$PRPN/report.md"); expect_rc 0 $? "prices diff of a report with the proposal in a fenced block"
[[ "$out" == "$out2" ]] && ok "prices diff: a report gives the same diff as the plain file" || bad "prices diff: the report differs from the plain file"
out=$(pr diff "$PRPN/nochange.json"); expect_rc 0 $? "prices diff: a proposal with no changes is valid"
contains "$out" "no rate changes" "prices diff: says there are no changes"
for f in bad-provider negative wrong-provider future missing-field garbage; do
  ext=json; [[ $f == garbage ]] && ext=txt
  out=$(pr diff "$PRPN/$f.$ext" 2>&1); expect_rc 2 $? "prices diff: invalid input ($f)"
done
out=$(pr diff "$PRPN/bad-provider.json" 2>&1); contains "$out" "unknown provider" "prices diff: names the reason (unknown provider)"
out=$(pr diff "$PRPN/negative.json" 2>&1); contains "$out" ">= 0" "prices diff: names the reason (negative rate)"
out=$(pr diff "$PRPN/wrong-provider.json" 2>&1); contains "$out" "belongs to deepseek" "prices diff: names the reason (a model of another provider)"
out=$(pr diff "$PRPN/future.json" 2>&1); contains "$out" "in the future" "prices diff: names the reason (future date)"
out=$(pr diff "$PRPN/missing-field.json" 2>&1); contains "$out" "cache_read. is required" "prices diff: names the reason (missing field)"
pr diff "$PRPN/no-such-file.json" >/dev/null 2>&1; expect_rc 2 $? "prices diff: a missing file is invalid input"

# apply: nothing without --yes
cp "$PRD/prices.json" "$T/prices-before.json"
out=$(pr apply "$PRPN/p1.json"); expect_rc 0 $? "prices apply without --yes"
contains "$out" "Nothing written" "prices apply without --yes says so"
cmp -s "$PRD/prices.json" "$T/prices-before.json" && ok "prices apply without --yes leaves the personal file alone" || bad "prices apply without --yes changed the file"
# apply --yes: dated entries, sources, kept peak fields, untouched unchanged models
out=$(pr apply "$PRPN/p1.json" --yes); expect_rc 0 $? "prices apply --yes"
contains "$out" "Written to" "prices apply --yes says what it wrote"
ORCH_HOME="$PRH" $PY -B - "$(native "$PLUGIN/bin/orch")" "$PRH/prices.json" <<'EOF' && ok "prices apply --yes: dated entries, rates by date, sources, peak fields kept, unchanged models not written" || bad "prices apply --yes: personal file"
import datetime as dt, importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
today = dt.date.today().isoformat()
p = json.load(open(sys.argv[2], encoding="utf-8"))
rates = p["usd_per_1m_tokens"]
a = rates["deepseek-test-a"]
assert isinstance(a, list) and len(a) == 2, a
assert a[0]["to"] == today and a[0]["input"] == 1.0 and "from" not in a[0], a[0]
assert a[1]["from"] == today and a[1]["input"] == 1.5 and a[1]["cache_read"] == 0.1 and a[1]["output"] == 2.0, a[1]
assert a[1]["off_peak_multiplier"] == 0.5 and a[1]["peak_days"][0] == "mon" and a[1]["peak_windows_utc"][1] == ["06:00", "10:00"], a[1]
assert isinstance(rates["deepseek-test-b"], dict) and isinstance(rates["deepseek-test-d"], dict) and "deepseek-test-c" not in rates
assert isinstance(rates["gpt-test-b"], dict)
now = dt.datetime.now().astimezone()
assert m.price_for("gpt-test-a", "codex", now)["output"] == 2.2
assert m.price_for("gpt-test-a", "codex", now - dt.timedelta(days=1))["output"] == 2.0
assert m.price_for("gpt-test-a", "codex", now)["input"] == 1.0
s = p["sources"]
assert s["deepseek"]["as_of"] == today and s["deepseek"]["source"] == "https://api-docs.deepseek.com/quick_start/pricing", s
assert set(s["deepseek"]["models"]) == {"deepseek-test-a", "deepseek-test-b", "deepseek-test-d"}, s
assert s["codex"]["as_of"] == today and s["codex"]["models"] == ["gpt-test-a", "gpt-test-b"], s
assert m.price_as_of("codex") == today
EOF
# a second apply on the same day replaces its own element instead of stacking a closed empty one
sed 's/"input": 1.5/"input": 1.6/' "$PRPN/p1.json" > "$PRPN/p2.json"
pr apply "$PRPN/p2.json" --yes >/dev/null; expect_rc 0 $? "prices apply --yes again on the same day"
$PY - "$PRH/prices.json" <<'EOF' && ok "prices apply: a same-day re-apply replaces the open element" || bad "prices apply: same-day re-apply stacked entries"
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))["usd_per_1m_tokens"]["deepseek-test-a"]
assert len(a) == 2 and a[1]["input"] == 1.6 and "to" not in a[1], a
EOF
# filters
$PY "$PRGEN" pin "$PRH"
pr apply "$PRPN/p1.json" --yes --provider codex >/dev/null; expect_rc 0 $? "prices apply --provider"
$PY - "$PRH/prices.json" <<'EOF' && ok "prices apply --provider: only that provider changes" || bad "prices apply --provider wrote the other provider"
import datetime as dt, json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(p["usd_per_1m_tokens"]["gpt-test-a"], list) and isinstance(p["usd_per_1m_tokens"]["deepseek-test-a"], dict)
assert p["sources"]["codex"]["as_of"] == dt.date.today().isoformat()
assert p["sources"]["deepseek"]["as_of"] != dt.date.today().isoformat() and "models" not in p["sources"]["deepseek"], p["sources"]
EOF
$PY "$PRGEN" pin "$PRH"
pr apply "$PRPN/p1.json" --yes --model deepseek-test-a >/dev/null; expect_rc 0 $? "prices apply --model"
$PY - "$PRH/prices.json" <<'EOF' && ok "prices apply --model: only that model is written, and a provider with a skipped change keeps its date" || bad "prices apply --model wrote another model or confirmed a skipped one"
import datetime as dt, json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
r, s, today = p["usd_per_1m_tokens"], p["sources"], dt.date.today().isoformat()
assert isinstance(r["deepseek-test-a"], list) and isinstance(r["gpt-test-a"], dict), r
assert s["deepseek"]["as_of"] == today, s          # its only change was applied
assert s["codex"]["as_of"] != today, s             # gpt-test-a's change was left out by --model
EOF
$PY "$PRGEN" pin "$PRH"
pr apply "$PRPN/p1.json" --yes --provider mistral >/dev/null 2>&1; expect_rc 2 $? "prices apply: --provider outside the proposal is refused"
pr apply "$PRPN/p1.json" --yes --model deepseek-nope >/dev/null 2>&1; expect_rc 2 $? "prices apply: --model outside the proposal is refused"
pr apply "$PRPN/negative.json" --yes >/dev/null 2>&1; expect_rc 2 $? "prices apply: an invalid proposal is refused even with --yes"
# a check with no changes still confirms the date
$PY "$PRGEN" pin "$PRH"
pr apply "$PRPN/nochange.json" --yes >/dev/null; expect_rc 0 $? "prices apply --yes with no changes"
$PY - "$PRH/prices.json" <<'EOF' && ok "prices apply: a check with no changes still updates as_of and writes no rates" || bad "prices apply: no-change check"
import datetime as dt, json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["sources"]["deepseek"]["as_of"] == dt.date.today().isoformat() and "deepseek-test-a" in p["sources"]["deepseek"]["models"], p["sources"]
assert all(isinstance(v, dict) for v in p["usd_per_1m_tokens"].values()), p["usd_per_1m_tokens"]
EOF
# a personal file that cannot be read is never overwritten
printf '{ broken' > "$PRD/prices.json"
pr apply "$PRPN/p1.json" --yes >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "prices apply: an unreadable personal file refuses the write" || bad "prices apply wrote over an unreadable file"
[[ "$(cat "$PRD/prices.json")" == "{ broken" ]] && ok "prices apply: the unreadable file is left as it was" || bad "prices apply changed the unreadable file"
rm -f "$PRD/prices.json"
[[ "$(prices_sha)" == "$PRICES_SHA_BEFORE" ]] && ok "prices: the built-in prices.json never changes" || bad "prices: the built-in prices.json was written"

# load_prices: a newer built-in source wins over an old check; a hand-written entry still overrides
ORCH_HOME="$PRH" $PY -B - "$(native "$PLUGIN/bin/orch")" "$PRICES_BUILTIN" "$PRH/prices.json" <<'EOF' && ok "prices: an old personal check yields to newer built-in prices; hand-written entries still override" || bad "prices: precedence of personal and built-in sources"
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
built = json.load(open(sys.argv[2], encoding="utf-8"))
def write(data):
    open(sys.argv[3], "w", encoding="utf-8").write(json.dumps(data))
old = {"usd_per_1m_tokens": {"sonnet": {"input": 99, "cache_read": 9, "output": 999}},
       "sources": {"claude": {"as_of": "2000-01-01", "source": "old.example.test", "models": ["sonnet"]}}}
write(old)
t = m.load_prices()
assert t["usd_per_1m_tokens"]["sonnet"] == built["usd_per_1m_tokens"]["sonnet"], t["usd_per_1m_tokens"]["sonnet"]
assert t["sources"]["claude"] == built["sources"]["claude"], t["sources"]["claude"]
assert m.price_for("sonnet", "claude")["input"] == built["usd_per_1m_tokens"]["sonnet"]["input"]
# the same entries written by hand (no models list) always override
hand = json.loads(json.dumps(old)); del hand["sources"]["claude"]["models"]
write(hand)
t = m.load_prices()
assert t["usd_per_1m_tokens"]["sonnet"]["input"] == 99 and t["sources"]["claude"]["source"] == "old.example.test"
# a check as new as, or newer than, the built-in source stays in force
for as_of in (built["sources"]["claude"]["as_of"], "2999-01-01"):
    new = json.loads(json.dumps(old)); new["sources"]["claude"]["as_of"] = as_of
    write(new)
    assert m.load_prices()["usd_per_1m_tokens"]["sonnet"]["input"] == 99, as_of
# the staleness warning points to the check
write({"sources": {"deepseek": {"as_of": "2000-01-01", "source": "stale.example.test"}}})
w = m.price_staleness("deepseek")
assert w and "stale.example.test" in w and "run `orch prices check`" in w, w
EOF
$PY - "$PRH/prices.json" <<'EOF'
import json, sys
json.dump({"usd_per_1m_tokens": {"sonnet": {"input": 99, "cache_read": 9, "output": 999}},
           "sources": {"claude": {"as_of": "2000-01-01", "source": "old.example.test", "models": ["sonnet"]}}}, open(sys.argv[1], "w"))
EOF
out=$(pr show); contains "$out" "personal check of 2000-01-01 is older than the built-in prices" "prices show: flags a personal check older than the built-in source"
rm -f "$PRD/prices.json"

