#!/usr/bin/env bash
# Removes the Orchestra plugin from Claude Code in THIS environment (WSL / Linux / macOS or Git Bash on Windows).
# Claude Code: the standard way, `claude plugin uninstall` + `claude plugin marketplace remove` (Claude Code
# settings are not edited by hand). Outside Claude Code: the orch launchers in ~/.local/bin. Personal data
# (~/.orchestra: limits, profiles, keys, usage log) is kept; --purge deletes it too.
# Per-project state (<project>/.orchestra/ with the worktrees of tasks that change files in .orchestra/wt/, the
# Antigravity rule <project>/.agents/rules/orchestra-task.md, worktrees <project>.wt/ from `orch worktree`) is left
# alone: the script only lists it. If you delete .orchestra/ by hand, run `git worktree prune` in the project.
#
#   bash uninstall.sh            # plugin and launchers
#   bash uninstall.sh --purge    # plus ~/.orchestra
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$ROOT/plugins/orchestra/bin/orch"
MARKET="orchestra"
LEGACY_MARKETS="orchestra-local"     # marketplace names of earlier versions
PURGE=0; [[ "${1:-}" == "--purge" ]] && PURGE=1
HOME_DIR="${ORCH_HOME:-$HOME/.orchestra}"

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
# a file path in the form the user's own tools show it: on Windows `C:\…`, as orch doctor prints, not `/c/…`
wpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

PY=""
for p in python3 python py; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PY="$p"; break
  fi
done
# what will be left after removal: collect it before orch disappears
TMPF="$(mktemp)"
[[ -n "$PY" && -f "$ORCH" ]] && "$PY" "$ORCH" footprint 2>/dev/null | sed -n '/^Outside Claude Code/,$p' | grep '  project ' > "$TMPF" || true

if command -v claude >/dev/null 2>&1; then
  say "Removing the plugin orchestra@$MARKET and the marketplace $MARKET (the standard way, via claude plugin)"
  claude plugin uninstall "orchestra@$MARKET" >/dev/null 2>&1 && say "plugin removed" || warn "the plugin was not installed"
  claude plugin marketplace remove "$MARKET" >/dev/null 2>&1 && say "marketplace removed" || warn "the marketplace was not registered"
  for m in $LEGACY_MARKETS; do          # an installation of an earlier version, if any
    claude plugin uninstall "orchestra@$m" >/dev/null 2>&1 && say "plugin orchestra@$m removed" || true
    claude plugin marketplace remove "$m" >/dev/null 2>&1 && say "marketplace $m removed" || true
  done
else
  warn "claude CLI not found: remove the plugin in Claude Code via /plugin → orchestra → Uninstall"
fi

for f in "$HOME/.local/bin/orch" "$HOME/.local/bin/orch.cmd"; do
  if [[ -L "$f" ]] || { [[ -f "$f" ]] && grep -q "orch launcher\|plugins/orchestra/bin/orch" "$f" 2>/dev/null; }; then
    rm -f "$f" && say "removed launcher $(wpath "$f")"
  fi
done

if [[ $PURGE == 1 && -d "$HOME_DIR" ]]; then
  rm -rf "$HOME_DIR" && say "removed personal data $(wpath "$HOME_DIR")"
elif [[ -d "$HOME_DIR" ]]; then
  say "Personal data kept: $(wpath "$HOME_DIR") (limits, profiles, keys, usage log; to delete: bash uninstall.sh --purge)"
fi

if [[ -s "$TMPF" ]]; then
  warn "Orchestra state is left in projects (excluded from git via .git/info/exclude); delete it by hand if you don't need it:"
  cat "$TMPF"
fi
rm -f "$TMPF"
say "Yours to remove: the clone folder this plugin was installed from, and any PATH line you added yourself (~/.bashrc, or your user PATH on Windows)."
say "Done. In open Claude Code sessions run /reload-plugins (or start a new session)."
