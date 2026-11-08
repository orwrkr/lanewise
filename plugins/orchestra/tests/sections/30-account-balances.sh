echo "── provider account balances (a fake DeepSeek balance server on localhost)"
BDIR="$T/bal-home"; BH="$(native "$BDIR")"
BA="$(native "$T/bal-a")"; BB="$(native "$T/bal-b")"; BC="$(native "$T/bal-c")"
BD="$(native "$T/bal-d")"; BE="$(native "$T/bal-e")"; BF="$(native "$T/bal-f")"
BANS="$(native "$T/bal.answers")"; BLOG="$(native "$T/bal.log")"; BPORT="$T/bal.port"
mkdir -p "$BDIR" "$T/bal-a" "$T/bal-b" "$T/bal-c" "$T/bal-d" "$T/bal-e" "$T/bal-f"
printf 'DEEPSEEK_API_KEY_CLIENT=sk-fake-client\nDEEPSEEK_API_KEY_WORK=sk-fake-work\nDEEPSEEK_API_KEY_BAD=sk-fake-bad\nCODEX_API_KEY_WORK=sk-fake-codex\n' > "$BDIR/secrets.env"
printf '{"usd_per_1m_tokens": {"deepseek-v4-pro": {"input": 1.0, "cache_read": 0.0, "output": 0.0}}}' > "$BDIR/prices.json"
# the server answers by the key it receives; a missing key is a 401. answers: {key: {total, currency, status, raw, sleep}}
cat > "$T/bal_server.py" <<'EOF' || die "cannot write the fake balance server"
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port_file, answers_file, log_file = sys.argv[1:4]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/quit":
            self.send_response(200); self.end_headers(); self.wfile.write(b"bye")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        key = self.headers.get("Authorization", "").replace("Bearer ", "", 1)
        with open(log_file, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (self.path, key))
        try:
            answers = json.load(open(answers_file, encoding="utf-8"))
        except (OSError, ValueError):
            answers = {}
        a = answers.get(key)
        if self.path != "/user/balance" or a is None:
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error":"invalid key"}')
            return
        time.sleep(a.get("sleep", 0))
        body = a["raw"] if "raw" in a else json.dumps({"is_available": True, "balance_infos": [
            {"currency": a.get("currency", "USD"), "total_balance": a["total"],
             "granted_balance": "0.00", "topped_up_balance": a["total"]}]})
        self.send_response(a.get("status", 200))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_address[1]))
timer = threading.Timer(900, lambda: os._exit(0)); timer.daemon = True; timer.start()   # never outlives a forgotten run
server.serve_forever()
EOF
bal_answers() { printf '%s' "$1" > "$T/bal.answers"; }   # JSON, see above
bal_start() {
  rm -f "$BPORT"
  $PY "$(native "$T/bal_server.py")" "$(native "$BPORT")" "$BANS" "$BLOG" >/dev/null 2>&1 &
  BSRV=$!
  for _ in $(seq 1 60); do [[ -s "$BPORT" ]] && break; sleep 0.25; done
  [[ -s "$BPORT" ]] || { bad "the fake balance server did not start"; return 1; }
  BURL="http://127.0.0.1:$(cat "$BPORT")/user/balance"
}
bal_stop() {
  $PY -c 'import sys, urllib.request; urllib.request.urlopen("http://127.0.0.1:%s/quit" % sys.argv[1], timeout=5).read()' "$(cat "$BPORT")" >/dev/null 2>&1
  wait "$BSRV" 2>/dev/null
}
bal() { ORCH_HOME="$BH" ORCH_PROJECT_DIR="${BWHERE:-$BA}" ORCH_BALANCE="${BAL_MODE:-on}" ORCH_DEEPSEEK_BALANCE_URL="${BURL:-}" NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 $ORCH "$@"; }
bal_count() { echo $(( $(wc -l < "$T/bal.log") )); }          # requests the server has seen
bal_ms() { $PY -c 'import time; print(int(time.time() * 1000))'; }
bal_cache_get() { $PY - "$BH/balances.json" "$1" "$2" <<'EOF'
import json, sys
e = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], {})
v = e.get(sys.argv[3])
print(v.get("message") if isinstance(v, dict) else "" if v is None else v)
EOF
}
bal_age() { $PY - "$BH/balances.json" "$1" "$2" <<'EOF'
import datetime as dt, json, sys
path, scope, secs = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(path, encoding="utf-8"))
t = (dt.datetime.now().astimezone() - dt.timedelta(seconds=secs)).isoformat(timespec="seconds")
d[scope]["at"] = t
if "error" in d[scope]:
    d[scope]["error"]["at"] = t
json.dump(d, open(path, "w", encoding="utf-8"))
EOF
}
: > "$T/bal.log"
bal_answers '{"sk-fake-client": {"total": "8.42"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal_start || die "no fake balance server"
bal profile set deepseek client --key DEEPSEEK_API_KEY_CLIENT --default >/dev/null
bal profile set deepseek work --key DEEPSEEK_API_KEY_WORK >/dev/null
bal profile set deepseek bad --key DEEPSEEK_API_KEY_BAD >/dev/null
bal profile set codex work --key CODEX_API_KEY_WORK >/dev/null
bal profile use deepseek work --path "$BB" >/dev/null
bal profile use deepseek bad --path "$BC" >/dev/null

# nothing is fetched without being asked: spend and status are quiet while ORCH_BALANCE is off
out=$(BAL_MODE=off bal balance); contains "$out" "Balance checks are off" "ORCH_BALANCE=off: orch balance fetches nothing"
BAL_MODE=off bal status >/dev/null; BAL_MODE=off bal spend >/dev/null
[[ $(bal_count) -eq 0 ]] && ok "ORCH_BALANCE=off: status and spend make no request" || bad "a request was made with ORCH_BALANCE=off"

# orch balance: every key profile, each with its own figure; a 401 names the variable; no API → says so
out=$(bal balance); rc=$?
expect_rc 1 $rc "orch balance exits 1 when a fetch failed"
contains "$out" "DeepSeek@client .*DEEPSEEK_API_KEY_CLIENT .*\$8.42" "balance: the client key's own amount"
contains "$out" "DeepSeek@work .*DEEPSEEK_API_KEY_WORK .*¥110.00" "balance: the work key's own amount, in the currency the provider reports"
contains "$out" "DeepSeek@bad .*rejected the key (HTTP 401): check DEEPSEEK_API_KEY_BAD" "balance: a 401 says the key was rejected and names the variable"
lacks "$out" "sk-fake" "balance: no key value in the output"
contains "$out" "Account balances: the provider's own figure for the account a key belongs to, shared by all its keys" "balance: the heading says it is the account's balance"
contains "$out" "our estimate of orch's own runs" "balance: the heading says orch spend is an estimate of orch's runs"
grep -qE "^scope +key variable +account balance +checked" <<<"$out" && ok "balance: the column is called account balance" || bad "balance: column header: $out"
lacks "$out" "API key balances" "balance: no heading that calls the figure a key's"
contains "$out" "Codex@work .*no balance API: see \`orch spend\`" "balance: a provider without a balance API says so"
# the built-in key and a profile holding the same variable are one account: one row, one request
bal profile set deepseek main --key DEEPSEEK_API_KEY >/dev/null
out=$(DEEPSEEK_API_KEY=sk-fake-main bal balance)
contains "$out" "DeepSeek@main .*DEEPSEEK_API_KEY " "balance: a profile on the standard variable has its row"
grep -qE '^DeepSeek +DEEPSEEK_API_KEY ' <<<"$out" && bad "balance: the same key listed twice: $out" || ok "balance: one row for one key"
bal profile rm deepseek main >/dev/null
out=$(DEEPSEEK_API_KEY=sk-fake-main bal balance)
contains "$out" "DeepSeek  *DEEPSEEK_API_KEY " "balance: the built-in key is listed when no profile holds it"
out=$(bal balance)
grep -q "sk-fake-codex" "$T/bal.log" && bad "a key of a provider without a balance API was sent somewhere" || ok "balance: the key of a provider without a balance API is never used"
grep -q "/user/balance sk-fake-client" "$T/bal.log" && grep -q "/user/balance sk-fake-work" "$T/bal.log" \
  && ok "balance: each scope asks with its own key" || bad "the server did not see both keys"
[[ "$(bal_cache_get deepseek@client amount)" == "8.42" && "$(bal_cache_get deepseek@work amount)" == "110.0" ]] \
  && ok "the cache holds a separate amount per scope" || bad "the cache amounts are wrong"
[[ "$(bal_cache_get deepseek@work currency)" == "CNY" ]] && ok "the cache keeps the provider's currency (no conversion)" || bad "currency not kept"
contains "$(bal_cache_get deepseek@bad error)" "DEEPSEEK_API_KEY_BAD" "the cache holds the last error of a scope with no figure"
[[ -z "$(bal_cache_get deepseek@bad amount)" ]] && ok "a failed first fetch stores no amount" || bad "an amount appeared for a rejected key"
out=$(bal balance deepseek@client --json); rc=$?
$PY -c 'import json, sys; d = json.loads(sys.argv[1]); assert len(d) == 1 and d[0]["scope"] == "deepseek@client" and d[0]["amount"] == 8.42 and d[0]["supported"]' "$out" \
  && ok "balance --json is valid and carries the amount" || bad "balance --json: $out"
lacks "$out" "sk-fake" "balance --json holds no key"
out=$(bal balance --json 2>/dev/null)
$PY -c 'import json, sys; d = json.loads(sys.argv[1]); assert {r["scope"] for r in d} == {"deepseek@client", "deepseek@work", "deepseek@bad", "codex@work"}; assert [r for r in d if r["scope"] == "codex@work"][0]["note"].startswith("no balance API")' "$out" \
  && ok "balance --json lists every key profile" || bad "balance --json list: $out"
lacks "$out" "sk-fake" "balance --json (all scopes) holds no key"
out=$(bal balance nope@nope 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "an unknown scope is refused" || bad "unknown scope accepted"
out=$(ORCH_WORKER=run-x bal balance 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a worker may not run orch balance" || bad "balance ran inside a worker"

# the amount reaches status, spend show and the status line, per project
out=$(bal status); contains "$out" "DeepSeek@client .*account \$8.42" "status: the account balance of the project's scope"
contains "$out" "API keys (spend and limit: our estimate of orch's own runs; account: the provider's figure, for all keys of that account):" "status: the heading says where each number comes from"
contains "$out" "DeepSeek@client  *est. \$0.00 of \$10 (manual.*) · account \$8.42 (checked" "status: the estimate sits next to the account balance"
lacks "$out" "API key balance" "status: nothing calls the figure a key's balance"
BWHERE="$BB"; out=$(bal status); contains "$out" "DeepSeek@work .*account ¥110.00" "status: another project, another key, its own amount"; BWHERE=""
BWHERE="$BC"; out=$(bal status); contains "$out" "last fetch failed: DeepSeek rejected the key (HTTP 401): check DEEPSEEK_API_KEY_BAD" "status: a rejected key shows the failure and the variable"
lacks "$out" "sk-fake" "status holds no key"; BWHERE=""
out=$(bal spend)
contains "$out" "account" "spend show: an account column"
contains "$out" "\`spent\` is our estimate of orch's own runs" "spend show: the header says spent is an estimate of orch's runs"
contains "$out" "\`account\` is the provider's figure for the whole account.*which can include spending outside orch" "spend show: the header says account is the provider's figure and can include outside spending"
grep -qE "^scope +spent +limit +account " <<<"$out" && ok "spend show: the column is called account" || bad "spend show: column header: $out"
contains "$out" "DeepSeek@client .*\$8.42" "spend show: the account balance of the scope"
sl_bal() { printf '{"session_id":"s-bal","workspace":{"current_dir":"%s"}}' "${1:-$BA}" | ORCH_HOME="$BH" $ORCH statusline; }
out=$(sl_bal); contains "$out" "DeepSeek@client (est. \$0.00/\$10, account \$8.42)" "status line: estimate, limit and account figure for the active scope"
out=$(sl_bal "$BB"); contains "$out" "DeepSeek@work (est. \$0.00/\$10, account ¥110.00)" "status line: the other project shows its own key's account figure"
lacks "$(sl_bal)" "ago)" "status line: no age while the figure is fresh"
lacks "$(sl_bal)" "balance" "status line: the figure is called account, not balance"

# an active key scope the provider was never asked about: the status line shows our part only, orch status says so
bal profile set deepseek fresh --key DEEPSEEK_API_KEY_FRESH >/dev/null
bal profile use deepseek fresh --path "$BD" >/dev/null
out=$(sl_bal "$BD"); contains "$out" "^DeepSeek@fresh (est. \$0.00/\$10)\$" "status line: a scope with no balance fetched shows only our part"
BWHERE="$BD"; out=$(BAL_MODE=off bal status); BWHERE=""
contains "$out" "DeepSeek@fresh  *est. \$0.00 of \$10 (manual.*) · account balance not fetched yet" "status: a key scope with no balance still has its line"
# a provider with no balance API: our part, and orch status says so
bal profile use codex work --path "$BE" >/dev/null
out=$(sl_bal "$BE"); contains "$out" "^Codex@work (est. \$0.00/\$10)\$" "status line: a provider with no balance API shows only our part"
contains "$out" "^  DeepSeek@client (est. " "status line: the next scope is on its own indented line"
lacks "$out" "Codex@work (est. \$0.00/\$10, account" "status line: and no account figure follows it"
BWHERE="$BE"; out=$(BAL_MODE=off bal status); BWHERE=""
contains "$out" "Codex@work  *est. \$0.00 of \$10 (manual.*) · no balance API" "status: a provider with no balance API says so"
# two keys of one account: each scope shows the account's figure, the same one
printf 'DEEPSEEK_API_KEY_TWIN=sk-fake-twin\n' >> "$BDIR/secrets.env"
bal profile set deepseek twin --key DEEPSEEK_API_KEY_TWIN >/dev/null
bal profile use deepseek twin --path "$BF" >/dev/null
bal_answers '{"sk-fake-client": {"total": "8.42"}, "sk-fake-twin": {"total": "8.42"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal balance deepseek@twin >/dev/null
out=$(sl_bal "$BF"); contains "$out" "DeepSeek@twin (est. \$0.00/\$10, account \$8.42)" "status line: a second key of the account shows the same figure"
out=$(sl_bal); contains "$out" "DeepSeek@client (est. \$0.00/\$10, account \$8.42)" "status line: and the first key still shows it"
BWHERE="$BF"; out=$(BAL_MODE=off bal status); BWHERE=""
contains "$out" "DeepSeek@twin  *est. \$0.00 of \$10 (manual.*) · account \$8.42" "status: the second key's block line carries the account figure"
# next to the token-based estimate the status line says which is which
bal spend reset deepseek@client >/dev/null
$PY - "$BH/usage.jsonl" <<'EOF'
import datetime as dt, json, sys
rec = {"kind": "run", "provider": "deepseek", "label": "deepseek@client", "model": "deepseek-v4-pro", "billing": "api",
       "project": "bal-a", "usage": {"input_tokens": 8500000, "cached_input_tokens": 0, "output_tokens": 0},
       "ts": dt.datetime.now().astimezone().isoformat(timespec="microseconds")}
open(sys.argv[1], "a", encoding="utf-8").write(json.dumps(rec) + "\n")
EOF
out=$(sl_bal); contains "$out" "DeepSeek@client (est. \$8.50/\$10, account \$8.42)" "status line: the estimate is marked est., the account figure is the provider's"
out=$(bal status); contains "$out" "est. \$8.50 of \$10 (manual.*) · account \$8.42" "status: the estimate beside the account figure"
contains "$out" "API spend: DeepSeek@client \$8.50/\$10 (85%)" "status: the warning at 80% is still there, apart from the block"

# the status line never touches the network: the server sees no request, a sleeping server cannot slow it, a stopped one changes nothing
before=$(bal_count)
sl_bal >/dev/null; sl_bal "$BB" >/dev/null
[[ $(bal_count) -eq $before ]] && ok "the status line makes no request" || bad "the status line made a request"
bal_age deepseek@client 10800
bal_answers '{"sk-fake-client": {"total": "1.00", "sleep": 8}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
t0=$(bal_ms); out=$(sl_bal); t1=$(bal_ms)
contains "$out" "DeepSeek@client (est. .*account \$8.42, 3h ago)" "status line: an old figure says how old it is"
[[ $((t1 - t0)) -lt 7000 ]] && ok "the status line does not wait for a slow provider ($((t1 - t0)) ms)" || bad "the status line took $((t1 - t0)) ms"
[[ $(bal_count) -eq $before ]] && ok "an old figure makes the status line fetch nothing" || bad "the status line fetched an old figure"
bal_stop
out=$(sl_bal); contains "$out" "account \$8.42, 3h ago)" "status line: with the server stopped the cached amount still shows"

# a stale cache triggers a fetch from orch status and spend show, a fresh one does not
bal_answers '{"sk-fake-client": {"total": "7.00"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal_start || die "the fake balance server did not restart"
: > "$T/bal.log"
out=$(bal status); contains "$out" "\$7.00" "status: a stale figure (3h) is fetched again"
[[ $(bal_count) -eq 1 ]] && ok "status asks only for the stale scope of the project" || bad "status made $(bal_count) requests"
bal status >/dev/null; bal spend >/dev/null
[[ $(bal_count) -eq 1 ]] && ok "a fresh figure is not fetched again by status or spend show" || bad "fresh figure fetched again: $(bal_count) requests"
bal_age deepseek@client 700
bal_answers '{"sk-fake-client": {"total": "6.50"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
out=$(bal spend); contains "$out" "DeepSeek@client .*\$6.50" "spend show: a figure older than 10 minutes is fetched again"
[[ $(bal_count) -eq 2 ]] && ok "spend show made one request" || bad "spend show made $(bal_count) requests in total"

# the end of a run reads the account balance behind its key
bal_answers '{"sk-fake-client": {"total": "6.25"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
out=$(FAKE_CLAUDE=ok bal run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 0 $rc "run on a key profile with a balance server"
[[ "$(bal_cache_get deepseek@client amount)" == "6.25" ]] && ok "the end of a run refreshes the balance of its scope" || bad "run did not refresh the balance"
lacks "$out" "sk-fake" "run output holds no key"

# SessionStart: a stale balance is fetched by a detached process the hook does not wait for; a worker starts nothing
bal_age deepseek@client 3600
bal_answers '{"sk-fake-client": {"total": "5.75", "sleep": 4}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
: > "$T/bal.log"
old_at=$(bal_cache_get deepseek@client at)
out=$(printf '{"session_id":"s-bal"}' | bal hook session-start); rc=$?
expect_rc 0 $rc "SessionStart hook with a stale balance"
[[ "$(bal_cache_get deepseek@client at)" == "$old_at" ]] && ok "the hook did not wait for the fetch" || bad "the hook waited for the fetch"
for _ in $(seq 1 60); do [[ "$(bal_cache_get deepseek@client amount)" == "5.75" ]] && break; sleep 0.5; done
[[ "$(bal_cache_get deepseek@client amount)" == "5.75" ]] && ok "the detached fetch stores the balance after the hook is gone" || bad "no detached fetch happened"
bal_age deepseek@client 3600
before=$(bal_count)
out=$(printf '{"session_id":"s-bal"}' | ORCH_WORKER=run-x bal hook session-start); rc=$?
sleep 2
[[ $rc -eq 0 && $(bal_count) -eq $before ]] && ok "a worker's hook starts no fetch" || bad "a worker's hook fetched (rc=$rc, $(( $(bal_count) - before )) requests)"
[[ -z "$out" ]] && ok "a worker's hook is silent" || bad "a worker's hook printed: $out"
out=$(printf '{"session_id":"s-bal"}' | bal hook session-start)
for _ in $(seq 1 60); do [[ $(bal_count) -gt $before ]] && break; sleep 0.5; done
[[ $(bal_count) -gt $before ]] && ok "the same hook outside a worker does start the fetch" || bad "no fetch outside a worker"
sleep 5   # let the detached fetch (it sleeps 4 s on the server) land before the next scenario

# failures keep the last amount and break nothing: HTTP 500, malformed JSON, a timeout, a refused connection
bal_answers '{"sk-fake-client": {"total": "4.00"}, "sk-fake-work": {"total": "110.00", "currency": "CNY"}}'
bal balance deepseek@client >/dev/null
bal_answers '{"sk-fake-client": {"total": "1.00", "status": 500}}'
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "an HTTP 500 fails the fetch"
contains "$out" "answered HTTP 500" "an HTTP 500 is named"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "HTTP 500: the last amount is kept" || bad "HTTP 500 lost the amount"
bal_answers '{"sk-fake-client": {"raw": "<html>not json"}}'
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "malformed JSON fails the fetch"
contains "$out" "not JSON" "malformed JSON is named"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "malformed JSON: the last amount is kept" || bad "malformed JSON lost the amount"
bal_answers '{"sk-fake-client": {"raw": "{\"balance_infos\": []}"}}'
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "a balance with no figure fails the fetch"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "an empty balance list: the last amount is kept" || bad "an empty list lost the amount"
bal_answers '{"sk-fake-client": {"total": "1.00", "sleep": 9}}'
t0=$(bal_ms); out=$(bal balance deepseek@client); rc=$?; t1=$(bal_ms)
contains "$out" "did not answer within 5 s" "a slow provider times out after 5 s"
[[ $((t1 - t0)) -lt 8500 ]] && ok "the timeout bounds the fetch ($((t1 - t0)) ms)" || bad "the fetch took $((t1 - t0)) ms"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "a timeout: the last amount is kept" || bad "a timeout lost the amount"
bal_answers '{"sk-fake-client": {"total": "1.00"}}'
bal_stop
out=$(bal balance deepseek@client); rc=$?
expect_rc 1 $rc "a refused connection fails the fetch"
contains "$out" "cannot reach DeepSeek" "a refused connection is named"
[[ "$(bal_cache_get deepseek@client amount)" == "4.0" ]] && ok "a refused connection: the last amount is kept" || bad "a refused connection lost the amount"
[[ -n "$(bal_cache_get deepseek@client error)" ]] && ok "the failure is recorded beside the amount" || bad "no error recorded"
bal_age deepseek@client 7200
out=$(bal status); rc=$?
expect_rc 0 $rc "status with the provider down"
contains "$out" "account \$4.00 (checked" "status keeps showing the last amount with the provider down"
contains "$out" "last fetch failed: " "status keeps the failed fetch visible beside the last amount"
out=$(bal spend); rc=$?
expect_rc 0 $rc "spend show with the provider down"
out=$(FAKE_CLAUDE=ok bal run deepseek --model deepseek-v4-pro "x"); rc=$?
expect_rc 0 $rc "a run with the provider down still succeeds"
out=$(printf '{"session_id":"s-bal"}' | bal hook session-start); rc=$?
expect_rc 0 $rc "SessionStart hook with the provider down"
sleep 2
out=$(sl_bal); contains "$out" "account \$4.00" "status line with the provider down"

# a key is never written outside secrets.env
leaks=$(grep -rl "sk-fake" "$BDIR" 2>/dev/null | grep -v "secrets.env$")
[[ -z "$leaks" ]] && ok "no key value in any file under ORCH_HOME except secrets.env" || bad "a key is stored in: $leaks"
