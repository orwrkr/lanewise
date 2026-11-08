echo "── registry & doctor"
# standalone setup (a no-op once the earlier sections have run)
[[ -f "$T/home/secrets.env" ]] || printf '# keys\r\nexport DEEPSEEK_API_KEY="sk-from-file"\r\n' > "$T/home/secrets.env"
out=$($ORCH registry path); contains "$out" "registry/providers.yaml" "default registry path"
out=$($ORCH registry diff); contains "$out" "No personal or project copy: the built-in registry is in effect." "registry diff with no copy names the built-in one"
$ORCH registry show --full > "$T/registry-shown.yaml" || bad "registry show --full failed"
$ORCH registry show --json > "$T/registry-shown.json" || bad "registry show --json failed"
reg_checks=$($PY - "$(native "$T/registry-shown.yaml")" "$(native "$T/registry-shown.json")" <<'EOF'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
routes = []                      # 2-space keys whose value is an inline list (the routing block)
for line in text.splitlines():
    m = re.match(r"^  ([a-z0-9_]+):\s*\[(.*)\]", line)
    if m:
        routes.append([s.strip() for s in m.group(2).split(",")])
pro = [s for slots in routes for s in slots if s.startswith("deepseek/pro-")]
print("PRO-ROUTE-OK" if routes and not pro else "PRO-ROUTE-BAD %r" % pro)
blocks = re.split(r"\n\s*- id: ", text)      # each slot: its fields up to the next slot
slots = {b.partition("\n")[0].strip(): b.partition("\n")[2] for b in blocks[1:]}
def has(sid, pattern):
    return re.search(pattern, slots.get(sid, ""), re.M) is not None
print("FLASH-MAX-OK" if has("deepseek/flash-max", r"^\s+effort: max$") else "FLASH-MAX-BAD")
print("FLASH-HIGH-D4-OK" if has("deepseek/flash-high", r"^\s+max_difficulty: 4$") else "FLASH-HIGH-D4-BAD")
# the same three facts, read from --json
data = json.load(open(sys.argv[2], encoding="utf-8"))
jroutes = data["routing"]
jpro = [s for slots in jroutes.values() for s in slots if s.startswith("deepseek/pro-")]
print("PRO-ROUTE-JSON-OK" if jroutes and not jpro else "PRO-ROUTE-JSON-BAD %r" % jpro)
jslots = {s["id"]: s for p in data["providers"].values() for s in p["slots"]}
print("FLASH-MAX-JSON-OK" if jslots["deepseek/flash-max"]["effort"] == "max" else "FLASH-MAX-JSON-BAD")
print("FLASH-HIGH-D4-JSON-OK" if jslots["deepseek/flash-high"]["max_difficulty"] == 4 else "FLASH-HIGH-D4-JSON-BAD")
EOF
)
for k in PRO-ROUTE-OK FLASH-MAX-OK FLASH-HIGH-D4-OK PRO-ROUTE-JSON-OK FLASH-MAX-JSON-OK FLASH-HIGH-D4-JSON-OK; do
  contains "$reg_checks" "$k" "registry: $k"
done
cmp -s "$T/registry-shown.yaml" "$PLUGIN/registry/providers.yaml" && ok "registry show --full is the file, byte for byte" || bad "registry show --full differs from the file"
json_checks=$($PY - "$(native "$T/registry-shown.json")" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print("JSON-FIRST-SLOT-OK" if data["providers"]["claude"]["slots"][0]["id"] == "claude/haiku-low" else "JSON-FIRST-SLOT-BAD")
good = {s["id"]: s["good_for"] for s in data["providers"]["deepseek"]["slots"]}["deepseek/flash-high"]   # spans lines in the file
print("JSON-GOOD-FOR-OK" if isinstance(good, list) and len(good) == 6 and good[-1] == "log analysis" else "JSON-GOOD-FOR-BAD %r" % good)
routes_plain = all(isinstance(v, list) for v in data["routing"].values())
print("JSON-ROUTES-OK" if routes_plain and data["routing_comments"].get("review_of_claude") == "cross-review" else "JSON-ROUTES-BAD")
print("JSON-POLICY-OK" if data["policy"]["never_auto"][0] == "codex/sol-ultra" and data["operator"]["max_offers"] == 5 else "JSON-POLICY-BAD")
EOF
)
for k in JSON-FIRST-SLOT-OK JSON-GOOD-FOR-OK JSON-ROUTES-OK JSON-POLICY-OK; do
  contains "$json_checks" "$k" "registry --json: $k"
done
# the brief view: what the orchestrator reads once per session
$ORCH registry show > "$T/registry-brief.txt"; rc=$?
expect_rc 0 $rc "registry show (brief)"
BRIEF_MAX=7000     # bytes (CRLF on Windows included): the built-in good_for texts, ids, models, calls and routes alone come to about 4.5 KB
brief_checks=$($PY - "$(native "$T/registry-brief.txt")" "$(native "$T/registry-shown.json")" "$BRIEF_MAX" <<'EOF'
import json, sys
brief = open(sys.argv[1], encoding="utf-8").read()
data = json.load(open(sys.argv[2], encoding="utf-8"))
size, limit = len(brief.encode("utf-8")), int(sys.argv[3])
print("BRIEF-SIZE-OK" if size <= limit else "BRIEF-SIZE-BAD %d > %d" % (size, limit))
ids = [s["id"] for p in data["providers"].values() for s in p["slots"]]
missing = [i for i in ids if i not in brief]
print("BRIEF-SLOTS-OK" if len(ids) > 20 and not missing else "BRIEF-SLOTS-BAD %r" % missing)
missing = [r for r in data["routing"] if (r + ":") not in brief]
print("BRIEF-ROUTES-OK" if data["routing"] and not missing else "BRIEF-ROUTES-BAD %r" % missing)
never = data["policy"]["never_auto"]
print("BRIEF-NEVER-AUTO-OK" if never and "never_auto: " + ", ".join(never) in brief else "BRIEF-NEVER-AUTO-BAD")
print("BRIEF-FOOTER-OK" if brief.rstrip().endswith("orch registry show --full") and "orch registry show <provider>" in brief else "BRIEF-FOOTER-BAD")
phrase = "Flash is the default"
assert phrase in data["providers"]["deepseek"]["notes"]
print("BRIEF-NO-NOTES-OK" if phrase not in brief and "DEEPSEEK_API_KEY" not in brief else "BRIEF-NO-NOTES-BAD")
print("BRIEF-COMMENT-OK" if "# cross-review" in brief and "# both, independently" in brief else "BRIEF-COMMENT-BAD")
print("BRIEF-AGENT-OK" if "agent=orchestra:orch-opus-high" in brief else "BRIEF-AGENT-BAD")
EOF
)
for k in BRIEF-SIZE-OK BRIEF-SLOTS-OK BRIEF-ROUTES-OK BRIEF-NEVER-AUTO-OK BRIEF-FOOTER-OK BRIEF-NO-NOTES-OK BRIEF-COMMENT-OK BRIEF-AGENT-OK; do
  contains "$brief_checks" "$k" "registry brief: $k"
done
contains "$(head -n 1 "$T/registry-brief.txt")" "Registry in effect: built-in registry (.*registry/providers.yaml)" "registry brief: the first line names the file in effect"
out=$($ORCH registry show deepseek); rc=$?
expect_rc 0 $rc "registry show <provider>"
flat=$(printf '%s' "$out" | tr -s ' \r\n' '   ')      # the paragraph is wrapped: compare it as one line
contains "$flat" "Flash is the default: it is newer, ahead on coding and agentic work, and several times cheaper" "registry show deepseek: the notes, as one paragraph"
contains "$out" "deepseek/pro-max" "registry show deepseek: its slots"
contains "$out" "implement_d3: .*deepseek/flash-high" "registry show deepseek: a route naming its slot"
lacks "$out" "codex/luna-low" "registry show deepseek: no other provider's slots"
lacks "$out" "explore:" "registry show deepseek: no route that names none of its slots"
out=$($ORCH registry show nosuch 2>&1); rc=$?
expect_rc 2 $rc "registry show with an unknown provider"
contains "$out" "claude, codex, deepseek, antigravity" "an unknown provider: the known ones are named"
out=$($ORCH registry path claude 2>&1); rc=$?
expect_rc 2 $rc "registry path with a provider is refused"
out=$($ORCH registry show --full deepseek 2>&1); rc=$?
expect_rc 2 $rc "registry show --full with a provider is refused"
# a personal copy: an extra slot field and an extra top-level section are kept and shown, a stale copy is flagged
$PY - "$(native "$PLUGIN/registry/providers.yaml")" "$(native "$ORCH_HOME/providers.yaml")" <<'EOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
old = "      - id: claude/haiku-low\n"
assert old in text
text = text.replace(old, old + "        zz_extra: sentinel-field\n") + "\nzz_extra_section:\n  note: x\n"
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(text)
EOF
out=$($ORCH registry show); rc=$?
expect_rc 0 $rc "registry show of a personal copy"
contains "$out" "Registry in effect: personal copy (.*providers.yaml)" "a personal copy: the first line says so"
contains "$out" "orch registry diff" "a personal copy that lags the built-in registry: the first line says so"
contains "$out" "zz_extra=sentinel-field" "a personal copy: an unknown slot field is shown as key=value"
contains "$out" "other sections: zz_extra_section" "a personal copy: an unknown top-level section is named"
printf 'providers:\n\tclaude: x\n' > "$ORCH_HOME/providers.yaml"
out=$($ORCH registry show); rc=$?
expect_rc 0 $rc "registry show of a copy with a tab in its indentation"
contains "$out" "could not read .*providers.yaml as a registry (line 2: a tab in the indentation): showing the file as is" "a copy that cannot be parsed: the fallback line"
contains "$out" "claude: x" "a copy that cannot be parsed: the file follows"
printf '# only\n# comments\n' > "$ORCH_HOME/providers.yaml"
out=$($ORCH registry show); rc=$?
expect_rc 0 $rc "registry show of a file of only comments"
contains "$out" "as a registry (no providers): showing the file as is" "a file of only comments: the fallback line"
contains "$out" "# only" "a file of only comments: the file follows"
rm -f "$ORCH_HOME/providers.yaml"
$ORCH registry init >/dev/null; out=$($ORCH registry path); contains "$out" "$ORCH_HOME/providers.yaml" "user registry overrides default"
marker=$(head -n 1 "$ORCH_HOME/providers.yaml")
marker_re='^# orchestra-registry-base: [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{16}$'
[[ "$marker" =~ $marker_re ]] && ok "registry init writes the base marker" || bad "registry init marker: $marker"
out=$($ORCH status --brief); lacks "$out" "the built-in registry has changed" "fresh registry copy: no warning in status"
out=$($ORCH doctor); lacks "$out" "the built-in registry has changed" "fresh registry copy: no warning in doctor"
out=$($ORCH doctor); ok "doctor runs (rc=$?)"
contains "$out" "DEEPSEEK_API_KEY *set" "doctor sees the DeepSeek key"
contains "$out" "Codex login *Logged in" "doctor checks the codex login"
contains "$out" "✔ Codex CLI" "doctor prints the Codex CLI row the way install.sh greps for it"
# install.sh greps doctor's output: each pattern it greps for must occur in a real doctor table (no drift in the wording)
INSTALL_SH="$PLUGIN/../../install.sh"
cx_pat=$(sed -n "s/^grep -q '\([^']*\)' <<<\"\$DOCTOR\" || warn \"Codex CLI not found.*/\1/p" "$INSTALL_SH")
[[ -n "$cx_pat" ]] && ok "install.sh: the Codex pattern is found ($cx_pat)" || bad "install.sh: Codex pattern not found"
contains "$out" "$cx_pat" "install.sh's Codex pattern occurs in doctor's output"
ds_pat=$(sed -n "s/^grep -q '\([^']*\)' <<<\"\$DOCTOR\" || .*/\1/p" "$INSTALL_SH" | grep -F DEEPSEEK | head -1)
contains "$out" "$ds_pat" "install.sh's DeepSeek pattern occurs in doctor's output"
bash -n "$INSTALL_SH" && ok "install.sh parses" || bad "install.sh has a syntax error"
grep -q 'WindowsApps' "$INSTALL_SH" && ok "install.sh: a Microsoft Store alias is only the last resort" \
  || bad "install.sh does not skip a WindowsApps alias"
grep -q 'exec "%s"' "$INSTALL_SH" && ok "install.sh: the Git Bash launcher names the interpreter's absolute path" \
  || bad "install.sh: the launcher does not hold an absolute interpreter path"
tail_install=$(tail -14 "$INSTALL_SH")
contains "$tail_install" "OFF_PATH == 1" "install.sh: the PATH warning is the last thing it prints"
doctor_paths=$($PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$T/doctor-paths")" <<'EOF'
import contextlib, importlib.machinery, importlib.util, io, os, shutil, sys
from pathlib import Path
from unittest import mock
loader = importlib.machinery.SourceFileLoader("orch", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader)); loader.exec_module(m)
root = Path(sys.argv[2]); (root / ".local" / "bin").mkdir(parents=True)
# 1. launchers missing: the old hint; present: the folder is off PATH
hint = m.orch_path_hint(root)
print("MISSING-OK" if "install.sh" in hint or "ln -s" in hint else "MISSING-BAD " + hint)
(root / ".local" / "bin" / ("orch.cmd" if m.IS_WINDOWS else "orch")).write_text("x", encoding="utf-8")
hint = m.orch_path_hint(root)
print("PRESENT-OK" if "not on PATH" in hint and "install.sh" not in hint else "PRESENT-BAD " + hint)
# 2. no Codex found: the row is optional ("·"), and it alone does not fail doctor
real_which = shutil.which
def which(name, *a, **k):
    return "/path/to/orch" if name == "orch" else None if name == "codex" else real_which(name, *a, **k)
buf = io.StringIO()
with mock.patch.object(m, "find_codex", lambda: (None, "")), mock.patch("shutil.which", which), \
     contextlib.redirect_stdout(buf):
    rc = m.cmd_doctor(None)
out = buf.getvalue()
row = [l for l in out.splitlines() if "Codex CLI" in l]
print("NOCODEX-ROW-OK" if row and row[0].startswith("·") else "NOCODEX-ROW-BAD %r" % row)
print("NOCODEX-RC-OK" if rc == 0 else "NOCODEX-RC-BAD rc=%s\n%s" % (rc, out))
EOF
)
for k in MISSING-OK PRESENT-OK NOCODEX-ROW-OK NOCODEX-RC-OK; do
  contains "$doctor_paths" "$k" "doctor: $k"
done
# doctor: the Git Bash launcher — a bare python3 that resolves to the Store alias, or an interpreter path that is gone
LH="$T/launcher-home"; mkdir -p "$LH/.local/bin" "$T/win-alias/WindowsApps" "$T/win-real"
: > "$T/win-alias/WindowsApps/python3"; : > "$T/win-alias/WindowsApps/python3.exe"
: > "$T/win-real/python3"; : > "$T/win-real/python3.exe"
chmod +x "$T/win-alias/WindowsApps/python3" "$T/win-alias/WindowsApps/python3.exe" \
  "$T/win-real/python3" "$T/win-real/python3.exe"
PYBIN="$(command -v "$PY")"           # a PATH of our own must not decide which Python runs orch
if command -v cygpath >/dev/null 2>&1; then LH_PROFILE="$(cygpath -w "$LH")"; else LH_PROFILE="$LH"; fi
WPATH="$T/win-alias/WindowsApps"; RPATH="$T/win-real"   # POSIX form: Git Bash converts the whole PATH for a native
                                                         # Python, while a C:\ entry would be split at its colon
printf '#!/bin/sh\nexec python3 "/nowhere/bin/orch" "$@"\n' > "$LH/.local/bin/orch"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" PATH="$WPATH:$PATH" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
contains "$out" "Microsoft Store alias" "doctor: a launcher that runs the Store alias warns"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" PATH="$RPATH:$PATH" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
lacks "$out" "Microsoft Store alias" "doctor: silent when the bare python3 is not an alias"
realpy=$($PY -c 'import sys; print(sys.executable.replace("\\", "/"))')
printf '#!/bin/sh\nexec "%s" "/nowhere/bin/orch" "$@"\n' "$realpy" > "$LH/.local/bin/orch"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
lacks "$out" "orch launcher" "doctor: silent for a launcher with an absolute interpreter path"
printf '#!/bin/sh\nexec "/no/such/python" "/nowhere/bin/orch" "$@"\n' > "$LH/.local/bin/orch"
out=$(HOME="$LH" USERPROFILE="$LH_PROFILE" "$PYBIN" "$PLUGIN/bin/orch" doctor </dev/null)
contains "$out" "does not exist" "doctor: a launcher whose interpreter is gone warns"

