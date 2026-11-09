echo "── guide, footprint, plugin wiring"
# standalone setup (a no-op once the earlier sections have run)
mkdir -p "$REPO/.orchestra"
out=$($ORCH guide); contains "$out" "manual" "guide lists the reference parts"
for t in manual profiles quota usage spend settings; do
  out=$($ORCH guide $t); [[ -n "$out" ]] && ok "guide $t" || bad "guide $t empty"
done
$ORCH guide nope >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "unknown guide topic refused" || bad "guide nope accepted"
out=$($ORCH guide settings); contains "$out" "secrets.env" "settings guide names secrets.env"
contains "$out" "orch registry show" "settings guide names orch registry show"
contains "$out" "orch profile use claude <name>" "settings guide pairs the budget thresholds with their use"
contains "$out" "ANTHROPIC_AUTH_TOKEN" "settings guide: a worker never sees the operator's Anthropic credentials"
grep -q 'description:.*config' "$PLUGIN/skills/orchestrate/SKILL.md" && ok "skill description names configuration" || bad "skill description does not name configuration"
grep -q 'subscription slots before API-billed' "$PLUGIN/skills/orchestrate/SKILL.md" && ok "routing: subscriptions before API-billed slots" || bad "SKILL.md lost the rule: subscriptions before API-billed slots"
grep -q 'subscriptions go before API-billed' "$PLUGIN/skills/orchestrate/reference/budget.md" && ok "budget guide states the default order" || bad "budget.md lost the default order"
out=$($ORCH footprint); contains "$out" "$ORCH_HOME" "footprint names ORCH_HOME"
contains "$out" "  project .*proj.*\.orchestra" "footprint lists project state"
contains "$out" "claude plugin uninstall partitura@partitura " "footprint shows the standard uninstall"
grep -q '"SessionEnd"' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd hook registered" || bad "SessionEnd hook missing"
grep -q 'run.sh\\" session-end' "$PLUGIN/hooks/hooks.json" && ok "SessionEnd → orch hook session-end" || bad "session-end wiring"
# the plugin was Orchestra before 0.34.0: the old name appears only where a line explains it (it names 0.34.0 or a
# LEGACY_ constant); .orchestra, orchestra-local and the registry marker are internal names that stay
old_names=$($PY - "$(native "$PLUGIN")" "$(native "$PLUGIN/../..")" <<'EOF'
import re, sys
from pathlib import Path
plugin, repo = Path(sys.argv[1]), Path(sys.argv[2])
files = [p for p in plugin.rglob("*") if p.is_file() and "__pycache__" not in p.parts]
files += [repo / n for n in ("README.md", "SECURITY.md", "CONTRIBUTING.md", "AGENTS.md", "CLAUDE.md", "ROADMAP.md",
                             "install.sh", "uninstall.sh", "docs/index.html", ".claude-plugin/marketplace.json")]
word = re.compile(r"(?<![.~/\w-])[Oo]rchestra(?![\w:-])")
for p in files:
    try:
        lines = p.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        continue
    for n, line in enumerate(lines, 1):
        if word.search(line) and "0.34.0" not in line and "LEGACY" not in line:
            print("%s:%d: %s" % (p.relative_to(repo).as_posix(), n, line.strip()[:100]))
EOF
)
[[ -z "$old_names" ]] && ok "the old name Orchestra appears only where a line explains the rename" \
  || { bad "the old name Orchestra is left in the plugin or its docs"; echo "$old_names"; }

