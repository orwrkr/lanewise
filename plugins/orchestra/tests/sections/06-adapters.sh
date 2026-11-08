echo "── adapters: python, nesting guard"
mkdir -p "$T/home/adapters"
printf '#!/usr/bin/env python3\nimport os\nopen(os.environ["ORCH_OUTPUT_FILE"], "w").write("py adapter ok " + os.environ["ORCH_MODE"])\n' \
  > "$T/home/adapters/pyecho"
out=$($ORCH run pyecho "x"); rc=$?
expect_rc 0 $rc "python adapter without +x runs via orch's interpreter"
contains "$out" "py adapter ok analysis" "python adapter output"
n=$(wc -l < "$FAKE_LOG")
out=$(ORCH_WORKER=cod-1 $ORCH run codex "x" 2>&1); rc=$?
[[ $rc -ne 0 && $(wc -l < "$FAKE_LOG") -eq $n ]] && ok "nested orch run refused inside a worker" || bad "nested run: rc=$rc"
contains "$out" "nested delegation is not allowed" "nested refusal explained"
printf 'task' | ORCH_WORKER=cod-1 $ORCH handoff new --title "nested" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "nested handoff refused inside a worker" || bad "nested handoff created"
# the claude and deepseek executors find `claude` also where the native installer puts it, when PATH lacks it (a Git
# Bash without the user's own PATH entries); a temporary home and an empty PATH, never the real ones
$PY -B - "$(native "$PLUGIN/adapters")" "$(native "$T/fc-home")" "$(native "$T/fc-empty")" <<'EOF' \
  && ok "executors find claude in ~/.local/bin when it is not on PATH, and report none when it is nowhere" \
  || bad "find_claude fallback"
import os, sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import _claude_headless as H
home, empty = Path(sys.argv[2]), Path(sys.argv[3])
empty.mkdir(parents=True, exist_ok=True)
os.environ.pop("ORCH_CLAUDE_BIN", None)
os.environ.update({"PATH": str(empty), "HOME": str(home), "USERPROFILE": str(home)})
assert H.find_claude() is None, H.find_claude()
exe = home / ".local" / "bin" / ("claude.exe" if os.name == "nt" else "claude")
exe.parent.mkdir(parents=True)
exe.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
exe.chmod(0o755)
assert Path(H.find_claude()) == exe, H.find_claude()
os.environ["ORCH_CLAUDE_BIN"] = "/path/to/claude"
assert H.find_claude() == "/path/to/claude"
EOF

