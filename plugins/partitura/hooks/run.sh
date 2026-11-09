#!/bin/sh
# Hook launcher: finds Python >= 3.8 and runs `orch hook <event>`.
# No Python → silent exit 0: a hook must never break a Claude Code session.
# Inside a Partitura worker (ORCH_WORKER set) hooks are a no-op: events belong to the orchestrator.
# The interpreter that passed the check is cached in $ORCH_HOME/.hook-python-<platform> (one line, sys.executable;
# per platform, since WSL and Git Bash may share ORCH_HOME), so the usual run starts a single process: in Git Bash
# `python3` is often the Microsoft Store alias, whose redirect costs ~0.2 s, and every process start is slow.
[ -n "${ORCH_WORKER:-}" ] && exit 0
case "$0" in    # hooks.json passes ".../hooks/run.sh": no `dirname` process then; a Windows-only path still gets one
  */*) HERE="${0%/*}" ;;
  *) HERE="$(dirname "$0")" ;;
esac
ORCH="$HERE/../bin/orch"
if [ -n "${ORCH_HOME:-}" ]; then
  HOME_DIR="$ORCH_HOME"
elif [ -d "$HOME/.partitura" ]; then
  HOME_DIR="$HOME/.partitura"
elif [ -d "$HOME/.orchestra" ]; then
  HOME_DIR="$HOME/.orchestra"
else
  HOME_DIR="$HOME/.partitura"
fi
CACHE="$HOME_DIR/.hook-python-${OSTYPE:-posix}"
if [ -f "$CACHE" ]; then
  CACHED=""
  IFS= read -r CACHED < "$CACHE" 2>/dev/null
  if [ -n "$CACHED" ] && [ -x "$CACHED" ]; then
    exec "$CACHED" "$ORCH" hook "$@"
  fi
fi
# Real interpreters first: an alias under .../WindowsApps/ is taken only when nothing else passes.
PY=""
for KIND in real alias; do
  for p in python3 python py; do
    CMD="$(command -v "$p" 2>/dev/null)" || continue
    case "$CMD" in
      *WindowsApps*) [ "$KIND" = real ] && continue ;;
      *) [ "$KIND" = alias ] && continue ;;
    esac
    EXE="$("$p" -c 'import sys; print(sys.executable.replace("\\", "/")) if sys.version_info >= (3, 8) else sys.exit(1)' 2>/dev/null)" || continue
    if [ -n "$EXE" ]; then PY="$EXE"; break 2; fi
  done
done
[ -n "$PY" ] || exit 0
mkdir -p "$HOME_DIR" 2>/dev/null
TMP="$CACHE.$$"
if printf '%s\n' "$PY" > "$TMP" 2>/dev/null; then
  mv -f "$TMP" "$CACHE" 2>/dev/null || rm -f "$TMP" 2>/dev/null
fi
exec "$PY" "$ORCH" hook "$@"
