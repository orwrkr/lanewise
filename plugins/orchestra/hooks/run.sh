#!/bin/sh
# Hook launcher: finds Python >= 3.8 and runs `orch hook <event>`.
# No Python → silent exit 0: a hook must never break a Claude Code session.
# Inside an Orchestra worker (ORCH_WORKER set) hooks are a no-op: events belong to the orchestrator.
[ -n "${ORCH_WORKER:-}" ] && exit 0
ORCH="$(dirname "$0")/../bin/orch"
for p in python3 python py; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    exec "$p" "$ORCH" hook "$@"
  fi
done
exit 0
