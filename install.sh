#!/usr/bin/env bash
# Installs the Lanewise plugin (called Partitura before 0.36.0 and Orchestra before 0.34.0) into Claude Code straight
# from THIS folder.
# Environments: WSL / Linux / macOS and Windows (Git Bash, for Claude Code running natively on Windows).
# Each environment has its own Claude Code installation: run the script in every environment you work in.
# The installation is "live": edits in the repository take effect after /reload-plugins or in a new session.
# Re-running is safe (it re-registers the marketplace at the current folder).
#
#   bash install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$ROOT/plugins/lanewise/bin/orch"
MARKET="lanewise"
PLUGIN="lanewise@$MARKET"
LEGACY_MARKETS="partitura orchestra orchestra-local"    # partitura before 0.36.0, orchestra before 0.34.0
LEGACY_PLUGINS="partitura orchestra"                    # the plugin's names before 0.36.0 and 0.34.0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; *) WIN=0 ;; esac

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
# a file path in the form the user's own tools show it: on Windows `C:\…`, as orch doctor prints, not `/c/…`
wpath() { if [[ $WIN == 1 ]] && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

py_check() {    # the interpreter's absolute path (forward slashes, for Git Bash) when it is Python >= 3.8
  "$1" -c 'import sys; print(sys.executable.replace("\\", "/")) if sys.version_info >= (3, 8) else sys.exit(1)' 2>/dev/null
}
PY=""; PYEXE=""                    # the command name for this script and the interpreter's absolute path (the launcher)
for want in real alias; do         # on Windows, python3 may be a Microsoft Store stub: a last resort only
  for p in python3 python py; do
    cmd="$(command -v "$p")" || continue
    case "$cmd" in
      *WindowsApps*) [[ $want == alias ]] || continue ;;
      *) [[ $want == real ]] || continue ;;
    esac
    exe="$(py_check "$p")" || continue
    [[ -n $exe ]] || continue
    PY="$p"; PYEXE="$exe"; break 2
  done
done

command -v claude >/dev/null 2>&1 || { echo "claude CLI not found: install Claude Code in this environment."; exit 1; }
[[ -n "$PY" ]] || { echo "Python >= 3.8 is required (WSL/Linux: sudo apt install python3; Windows: winget install Python.Python.3.13)"; exit 1; }
command -v git    >/dev/null 2>&1 || warn "git not found: worktrees (orch worktree) will not work."

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
    for p in lanewise $LEGACY_PLUGINS; do
      claude plugin uninstall "$p@$m" >/dev/null 2>&1 || true
    done
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
chmod +x "$ORCH" "$ROOT"/plugins/lanewise/adapters/{codex,deepseek,claude} 2>/dev/null || true
if [[ $WIN == 1 ]]; then
  # in Git Bash a symlink is a plain copy, but orch finds adapters and the registry next to itself: use launchers
  # the absolute path, not the command name: `python3` in Git Bash is often the Microsoft Store alias (~0.2 s a start)
  printf '#!/bin/sh\n# orch launcher (Git Bash) → %s\nexec "%s" "%s" "$@"\n' "$ORCH" "$PYEXE" "$(cygpath -m "$ORCH")" > "$HOME/.local/bin/orch"
  printf '@echo off\r\nrem orch launcher (cmd / PowerShell)\r\ncall "%s" %%*\r\n' "$(cygpath -w "$ROOT/plugins/lanewise/bin/orch.cmd")" \
    > "$HOME/.local/bin/orch.cmd"
  say "orch → ~/.local/bin/orch (Git Bash) and orch.cmd (PowerShell / cmd)"
else
  ln -sf "$ORCH" "$HOME/.local/bin/orch"
  say "orch → ~/.local/bin/orch"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) OFF_PATH=0 ;;
  *) OFF_PATH=1 ;;
esac

if [[ -n "${ORCH_HOME:-}" ]]; then
  HOME_DIR="$ORCH_HOME"
elif [[ -d "$HOME/.lanewise" ]]; then
  HOME_DIR="$HOME/.lanewise"
elif [[ -d "$HOME/.partitura" ]]; then
  HOME_DIR="$HOME/.partitura"
elif [[ -d "$HOME/.orchestra" ]]; then
  HOME_DIR="$HOME/.orchestra"
else
  HOME_DIR="$HOME/.lanewise"
fi
had_registry=0; [[ -f "$HOME_DIR/providers.yaml" ]] && had_registry=1
$PY "$ORCH" registry init
echo
DOCTOR="$($PY "$ORCH" doctor 2>&1 || true)"
echo "$DOCTOR"
echo
say "Done. In open Claude Code sessions run /reload-plugins (or start a new session)."
if [[ $had_registry == 1 ]] && grep -q 'registry copy' <<<"$DOCTOR"; then    # doctor names a stale copy
  warn "Your personal registry $(wpath "$HOME_DIR/providers.yaml") overrides the built-in one, which has changed since:"
  warn "  orch registry diff shows the difference; take over what you need, then: orch registry diff --accept"
fi
grep -q '✔ Codex CLI' <<<"$DOCTOR" || warn "Codex CLI not found: npm i -g @openai/codex && codex login"
grep -q '✔ DEEPSEEK_API_KEY\|✔ DeepSeek@' <<<"$DOCTOR" || \
  warn "DeepSeek: put the key as a DEEPSEEK_API_KEY=sk-… line in $(wpath "$HOME_DIR/secrets.env") (not in the repository)"
say "Executor profiles: orch profile show · manual task pool: /lanewise:manual · session usage: orch usage (inside a Claude Code session)"
say "DeepSeek as the lead instead of Claude: orch launch deepseek [--no-claude] (from a terminal)"
say "Claude budget mode (use the 5-hour window before it expires): set \"orch statusline\" as your status line (orch guide budget)"
say "What the plugin created outside Claude Code: orch footprint · uninstall: bash uninstall.sh [--purge]"
if [[ $OFF_PATH == 1 ]]; then       # last, so that it is the line the user reads
  echo
  warn "~/.local/bin is not in PATH, so orch is not found yet. Add it in Git Bash / bash:"
  cat <<'EOF'
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
  then run: source ~/.bashrc   (or open a new terminal)
EOF
  if [[ $WIN == 1 ]]; then
    echo "  In PowerShell / cmd (orch.cmd) add it to your user PATH, then open a new terminal:"
    cat <<'EOF'
    [Environment]::SetEnvironmentVariable('Path', "$env:USERPROFILE\.local\bin;" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')
EOF
  fi
fi
