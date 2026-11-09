#!/usr/bin/env python3
"""orch — helper CLI for the Partitura plugin (Claude Code multi-model orchestrator).

Subcommands
  status                     availability + open handoffs (used by SessionStart hook)
  quota set|clear|show|check provider/model availability (subscription limits, operator away)
  run PROVIDER ...           run an automated executor through adapters/<provider> (codex, deepseek, claude, …)
  launch PROVIDER ...        start Claude Code with another model as the lead (deepseek), optionally without Claude
  budget [show|set|clear]    Claude subscription budget: surplus (prefer Claude to API-billed executors) / tight
  spend [show|limit|mode|reset]
                             USD spend limits for API-billed executors (DeepSeek always; key profiles)
  balance [SCOPE …]          the provider's own balance of the account behind each API key (DeepSeek)
  statusline [--then CMD]    Claude Code statusLine command: records the subscription usage for `budget`
  profile show|list|use|set|rm
                             executor profiles (API key / account, models, rules): default and per project
  handoff offer|take|new|list|check|wait|show|done|cancel|reclaim|close
                             manual lane (Antigravity & co): task pool, task packets, completion detection
  usage [--session|--list]   per session: which model did what and how many tokens
  guide [topic]              reference parts of the orchestrate skill
  footprint                  what Partitura created outside Claude Code (cleanup list)
  worktree add NAME          isolated git worktree for a write task
  registry path|show|init|diff
                             model registry (providers.yaml); show is brief, [PROVIDER|--full|--json] for more;
                             diff [--accept] compares a copy with the built-in one
  doctor                     environment check

Runs in WSL/Linux/macOS and natively on Windows (shell adapters via Git Bash).
Stdlib only, Python 3.8+.
"""
# Only what every run needs is imported here: the status line starts on every update and may be killed by the next
# one. argparse, shutil, subprocess and the like are imported inside the functions that use them.
import datetime as dt
import json
import os
import re
import sys
import time
from contextlib import contextmanager
from functools import wraps
from pathlib import Path
from types import SimpleNamespace

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
ORCH_HOME = Path(os.environ.get("ORCH_HOME", str(Path.home() / ".orchestra")))
IS_WINDOWS = os.name == "nt"
EXIT_QUOTA = 75
EXIT_TIMEOUT = 124
# monthly spend limits for API-billed executors (prices, limits/modes, counters, announced events)
PRICES_FILE = PLUGIN_ROOT / "registry" / "prices.json"
PERSONAL_PRICES_FILE = ORCH_HOME / "prices.json"
SPEND_FILE = ORCH_HOME / "spend_limits.json"
SPEND_CACHE_FILE = ORCH_HOME / "spend_cache.json"
SPEND_EVENTS_FILE = ORCH_HOME / "spend_events.json"
BALANCE_FILE = ORCH_HOME / "balances.json"      # the providers' own figures for API keys (orch balance)
SESSION_BUDGET_FILE = ORCH_HOME / "session_budget.json"
SESSION_BUDGET_FIELDS = ("session_soft", "session_hard", "balance_floor")
SESSION_STATE_DAYS = 7        # how long a per-session entry (a budget baseline, a fallback move) is kept
BALANCE_STALE_SECONDS = 10 * 60   # orch status / spend show / SessionStart fetch again when the figure is older
BALANCE_FRESH_SECONDS = 30 * 60   # the status line adds "(3h ago)" to a figure older than this
BALANCE_TIMEOUT = 5               # seconds a provider gets to answer; every fetch is bounded by it
DEFAULT_SPEND = {"limit": 10, "mode": "evaluate", "lead_mode": "continue", "overrun": 20}   # USD, %, mode
SPEND_WARN_PCT = 80            # a warning (status line, 💡 event) starts at this % of the limit
SPEND_POLL_SECONDS = 15        # how often a run checks the executor's live token cost
TERMINAL = ("DONE", "BLOCKED", "FAILED", "CANCELLED", "REASSIGNED")
STATUS_RE = re.compile(r"^\s*STATUS:\s*([A-Z_]+)", re.M)
SCAN_SKIP = {".git", ".orchestra", "node_modules", ".venv", "venv", "__pycache__", "bin", "obj",
             "dist", "build", ".idea", ".vs", "target"}


