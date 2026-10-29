#!/usr/bin/env bash
# Installs the Orchestra plugin into Claude Code straight from THIS folder.
# Environments: WSL / Linux / macOS and Windows (Git Bash, for Claude Code running natively on Windows).
# Each environment has its own Claude Code installation: run the script in every environment you work in.
# The installation is "live": edits in the repository take effect after /reload-plugins or in a new session.
# Re-running is safe (it re-registers the marketplace at the current folder).
#
#   bash install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$ROOT/plugins/orchestra/bin/orch"
MARKET="orchestra"
PLUGIN="orchestra@$MARKET"
LEGACY_MARKETS="orchestra-local"     # marketplace names of earlier versions
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; *) WIN=0 ;; esac

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }

PY=""
for p in python3 python py; do     # on Windows, python3 may be a Microsoft Store stub
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PY="$p"; break
  fi
done

command -v claude >/dev/null 2>&1 || { echo "claude CLI not found: install Claude Code in this environment."; exit 1; }
[[ -n "$PY" ]] || { echo "Python >= 3.8 is required (WSL/Linux: sudo apt install python3; Windows: winget install Python.Python.3.13)"; exit 1; }
command -v git    >/dev/null 2>&1 || warn "git not found: worktrees and manual tasks with --worktree will not work."

case "$ROOT" in
  *$'\r'*) echo "The path contains a CR: check the line endings."; exit 1 ;;
esac
if head -1 "$ORCH" | grep -q $'\r'; then
  echo "Files have CRLF line endings. Run: git config core.autocrlf false && git rm -rq --cached . && git reset --hard"
  exit 1
fi

MARKETS="$(claude plugin marketplace list 2>/dev/null || true)"
for m in $MARKET $LEGACY_MARKETS; do
  if grep -qE "(^|[^[:alnum:]_-])$m([^[:alnum:]_-]|$)" <<<"$MARKETS"; then
    say "Removing the previous installation of $m"
    claude plugin uninstall "orchestra@$m" >/dev/null 2>&1 || true
    claude plugin marketplace remove "$m" >/dev/null 2>&1 || true
  fi
done

MROOT="$ROOT"
[[ $WIN == 1 ]] && MROOT="$(cygpath -w "$ROOT")"      # claude.exe is a Windows program
say "Adding the marketplace from $MROOT"
claude plugin marketplace add "$MROOT"
say "Installing $PLUGIN"
claude plugin install "$PLUGIN"

mkdir -p "$HOME/.local/bin"
chmod +x "$ORCH" "$ROOT"/plugins/orchestra/adapters/{codex,deepseek,claude} 2>/dev/null || true
if [[ $WIN == 1 ]]; then
  # in Git Bash a symlink is a plain copy, but orch finds adapters and the registry next to itself: use launchers
  printf '#!/bin/sh\n# orch launcher (Git Bash) → %s\nexec %s "%s" "$@"\n' "$ORCH" "$PY" "$(cygpath -m "$ORCH")" > "$HOME/.local/bin/orch"
  printf '@echo off\r\nrem orch launcher (cmd / PowerShell)\r\ncall "%s" %%*\r\n' "$(cygpath -w "$ROOT/plugins/orchestra/bin/orch.cmd")" \
    > "$HOME/.local/bin/orch.cmd"
  say "orch → ~/.local/bin/orch (Git Bash) and orch.cmd (PowerShell / cmd)"
else
  ln -sf "$ORCH" "$HOME/.local/bin/orch"
  say "orch → ~/.local/bin/orch"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "~/.local/bin is not in PATH. Add to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

HOME_DIR="${ORCH_HOME:-$HOME/.orchestra}"
had_registry=0; [[ -f "$HOME_DIR/providers.yaml" ]] && had_registry=1
$PY "$ORCH" registry init
echo
DOCTOR="$($PY "$ORCH" doctor 2>&1 || true)"
echo "$DOCTOR"
echo
say "Done. In open Claude Code sessions run /reload-plugins (or start a new session)."
if [[ $had_registry == 1 ]]; then
  warn "Your personal registry $HOME_DIR/providers.yaml overrides the built-in one: copy new entries into it"
  warn "  from plugins/orchestra/registry/providers.yaml or recreate it: $PY \"$ORCH\" registry init --force"
fi
grep -q '✔ codex CLI' <<<"$DOCTOR" || warn "Codex CLI not found: npm i -g @openai/codex && codex login"
grep -q '✔ DEEPSEEK_API_KEY\|✔ deepseek@' <<<"$DOCTOR" || \
  warn "DeepSeek: put the key as a DEEPSEEK_API_KEY=sk-… line in $HOME_DIR/secrets.env (not in the repository)"
say "Executor profiles: orch profile show · manual task pool: /orchestra:manual · session usage: orch usage"
say "DeepSeek as the lead instead of Claude: orch launch deepseek [--no-claude] (from a terminal)"
say "Claude budget mode (use the 5-hour window before it expires): set \"orch statusline\" as your status line (orch guide budget)"
say "What the plugin created outside Claude Code: orch footprint · uninstall: bash uninstall.sh [--purge]"
