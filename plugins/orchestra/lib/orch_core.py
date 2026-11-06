#!/usr/bin/env python3
"""orch — helper CLI for the Orchestra plugin (Claude Code multi-model orchestrator).

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
  footprint                  what Orchestra created outside Claude Code (cleanup list)
  worktree add NAME          isolated git worktree for a write task
  registry path|show|init|diff
                             model registry (providers.yaml); diff [--accept] compares a copy with the built-in one
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


# ───────────────────────── helpers ─────────────────────────

def now():
    return dt.datetime.now().astimezone()


def iso(t):
    return t.isoformat(timespec="seconds") if t else None


def iso_precise(t):
    """For what must order within one second: ledger entries against a spend baseline (a run that ended just
    before a reset stays out of the new count, one that ended just after is in it)."""
    return t.isoformat(timespec="microseconds")


def parse_iso(s):
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.astimezone()
    return t


def pct(x):
    """Round a percentage to the nearest integer (the %d form truncates, the apps show the rounded value)."""
    try:
        return int(round(float(x)))
    except (TypeError, ValueError):
        return 0


def human_delta(t):
    """'in 2h 10m' / '5m ago'."""
    secs = int((t - now()).total_seconds())
    if abs(secs) < 60:
        return "just now"
    future = secs >= 0
    secs = abs(secs)
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    parts = []
    if d:
        parts.append("%dd" % d)
    if h:
        parts.append("%dh" % h)
    if m or not parts:
        parts.append("%dm" % m)
    s = " ".join(parts[:2])
    return ("in " + s) if future else (s + " ago")


# ───────────────────────── official names ─────────────────────────
# ids → display names for human-readable output. Ids stay exact wherever they are typed or parsed (commands,
# --json, the ledger, profiles/cache, the registry); display names are for what a person reads.

PROVIDER_NAMES = {
    "claude": "Claude", "codex": "Codex", "deepseek": "DeepSeek", "gemini": "Gemini",
    "antigravity": "Antigravity",
}
MODEL_NAMES = {
    "claude-fable-5-1": "Claude Fable 5.1", "claude-opus-5-5": "Claude Opus 5.5",
    "claude-sonnet-5-5": "Claude Sonnet 5.5", "claude-haiku-5-5": "Claude Haiku 5.5",
    "gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6.1-terra": "GPT-6.1 Terra", "gpt-6-sol": "GPT-6 Sol",
    "gpt-6-luna": "GPT-6 Luna", "gpt-6-astra": "GPT-6 Astra", "gpt-5.6-sol": "GPT-5.6 Sol",
    "gpt-5.6-terra": "GPT-5.6 Terra", "gpt-5.6-luna": "GPT-5.6 Luna",
    "deepseek-v4-pro": "DeepSeek V4 Pro", "deepseek-flash": "DeepSeek V4.1 Flash",
    "gemini-4-argon": "Gemini 4 Argon", "gemini-3.8-flash": "Gemini 3.8 Flash",
}
NAMES = dict(PROVIDER_NAMES)
NAMES.update(MODEL_NAMES)


def display_name(name):
    """id → display name. Unknown ids are shown as-is; a dated/suffixed model resolves only when exactly one
    known model name is its longest prefix (followed by a separator); a trailing [bracket] variant is stripped."""
    if name is None:
        return None
    s = str(name).strip()
    if not s:
        return name
    key = s.lower()
    if key in NAMES:
        return NAMES[key]
    key = re.sub(r"\[[^\]]*\]$", "", key)          # deepseek-v4-pro[1m] → deepseek-v4-pro
    if key in NAMES:
        return NAMES[key]
    # only model names may extend (claude-opus-5-5-…), never provider names — an unknown version stays as-is
    hits = [(k, v) for k, v in MODEL_NAMES.items() if key.startswith(k) and len(key) > len(k) and key[len(k)] in "-_."]
    if not hits:
        return s
    longest = max(len(k) for k, _ in hits)
    top = [v for k, v in hits if len(k) == longest]
    return top[0] if len(top) == 1 else s


def scope_name(scope):
    """deepseek@work → DeepSeek@work; deepseek → DeepSeek; unknown scopes shown as-is."""
    if not scope:
        return scope
    provider, _, name = str(scope).partition("@")
    base = display_name(provider) or provider
    return base + ("@" + name if name else "")


def stale_part(measured):
    """'stale: <age>' when the measurement is older than the freshness constant, else None."""
    if measured is None:
        return None
    age = max((now() - measured).total_seconds(), 0)
    if age > USAGE_FRESH_SECONDS:
        return "stale: %s" % human_delta(measured)
    return None


def provider_line(name, five, week, mode_text=None, measured=None, sessions=None):
    """One provider's status line part, built the same way for Claude and Codex:
    name · 5h used% → reset · week used% · [N session(s)] · mode text · stale: age.
    five/week are (used %, reset time) or None; any part without data is left out."""
    parts = [name] if name else []
    if five and five[0] is not None and five[1]:
        parts.append("5h %d%% → %s" % (pct(five[0]), five[1].astimezone().strftime("%H:%M")))
    if week and week[0] is not None:
        parts.append("week %d%%" % pct(week[0]))
    if sessions:
        parts.append("%d session%s" % (sessions, "" if sessions == 1 else "s"))
    if mode_text:
        parts.append(mode_text)
    stale = stale_part(measured)
    if stale:
        parts.append(stale)
    return " · ".join(parts) if parts else None


def claude_status_name(model):
    """The Claude product and model for a status line: the status line's display_name, prefixed 'Claude ' unless
    it already says Claude; in a session led by another provider the id goes through the names table with no prefix."""
    if not model:
        return "Claude"
    m = str(model).strip()
    if os.environ.get("ORCH_LEAD"):
        return display_name(m) or m
    if m.lower().startswith("claude"):
        return display_name(m) or m
    return "Claude " + m


def short_mode(mode, budget_line, where=None):
    """The compact mode text for the Claude status line: 'tight: week N% projected', 'tight: week over reserve',
    'tight: 5h', or 'surplus: Claude first' ('surplus' alone where an API-key profile has `prefer for`)."""
    if mode == "surplus":
        return "surplus" if preferred_api_profiles(where) else "surplus: Claude first"
    if mode != "tight":
        return None
    m = re.search(r"weekly limit is tight \((\d+)% projected", budget_line or "")
    if m:
        return "tight: week %s%% projected" % m.group(1)
    if "weekly limit is tight" in (budget_line or ""):
        return "tight: week over reserve"
    return "tight: 5h"


def parse_until(text):
    """Accepts: +90m +3h +2d +1w | HH:MM | YYYY-MM-DD | YYYY-MM-DD HH:MM | tomorrow HH:MM | none."""
    if text is None:
        return None
    s = text.strip().lower()
    if s in ("", "none", "never", "-", "manual"):
        return None
    base = now().replace(second=0, microsecond=0)
    m = re.fullmatch(r"\+?(\d+)\s*(m|min|h|d|w)", s)
    if m:
        n, u = int(m.group(1)), m.group(2)
        mult = {"m": 60, "min": 60, "h": 3600, "d": 86400, "w": 604800}[u]
        return base + dt.timedelta(seconds=n * mult)
    m = re.fullmatch(r"(tomorrow)\s+(\d{1,2}):(\d{2})", s)
    if m:
        t = (base + dt.timedelta(days=1)).replace(hour=int(m.group(2)), minute=int(m.group(3)))
        return t
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", s)
    if m:
        t = base.replace(hour=int(m.group(1)), minute=int(m.group(2)))
        if t <= now():
            t += dt.timedelta(days=1)
        return t
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(text.strip(), fmt).astimezone()
        except ValueError:
            pass
    t = parse_iso(text.strip())
    if t:
        return t
    raise SystemExit("orch: cannot parse time %r (use +3h, 18:00, 2026-10-26 09:00, tomorrow 09:00)" % text)


def parse_duration(text, default_unit="m"):
    s = str(text).strip().lower()
    m = re.fullmatch(r"(\d+)\s*(s|m|h|d)?", s)
    if not m:
        raise SystemExit("orch: bad duration %r" % text)
    n, u = int(m.group(1)), m.group(2) or default_unit
    return n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[u]


class StateError(Exception):
    """Shared state is busy or unreadable; never overwrite it with an empty default."""


LOCK_WAIT = 10.0
QUIET_LOCK_WAIT = 1.5
STATUSLINE_LOCK_WAIT = 0.0     # no waiting: a busy lock means this run prints what is cached
_held_locks = {}
_quiet_state = False
_statusline_run = False
_run_reads = {}                # status line: file contents already read in this run, None for a missing file


@contextmanager
def state_lock(path):
    """Reentrant process lock on a stable sidecar file; the OS releases it on process death."""
    path = Path(path)
    key = os.path.normcase(str(path.resolve()))
    if key in _held_locks:
        yield
        return
    if not path.parent.is_dir():
        path.parent.mkdir(parents=True, exist_ok=True)
    wait = STATUSLINE_LOCK_WAIT if _statusline_run else QUIET_LOCK_WAIT if _quiet_state else LOCK_WAIT
    deadline = time.monotonic() + wait
    with path.open("a+b") as f:
        f.seek(0, os.SEEK_END)
        if f.tell() == 0:
            f.write(b"\0")
            f.flush()
        while True:
            try:
                if IS_WINDOWS:
                    import msvcrt
                    f.seek(0)
                    msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise StateError("shared state busy: timed out waiting for %s; retry the command" % path)
                time.sleep(0.025)
        _held_locks[key] = f
        _run_reads.clear()     # what follows must see what others wrote before this lock
        try:
            yield
        finally:
            del _held_locks[key]
            if IS_WINDOWS:
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def locked(scope):
    def decorate(fn):
        @wraps(fn)
        def call(*args, **kwargs):
            path = ORCH_HOME / ".state.lock" if scope == "home" else state_dir() / ".state.lock"
            with state_lock(path):
                return fn(*args, **kwargs)
        return call
    return decorate


_warned_state = set()


def warn_state(path, detail):
    if not _quiet_state and str(path) not in _warned_state:
        _warned_state.add(str(path))
        print("orch: warning: %s: %s" % (path, detail), file=sys.stderr)


def read_json(path, default, recover_corrupt=False, object_required=False):
    if recover_corrupt:
        home_state = Path(path) in (USAGE_SNAPSHOT, SESSIONS_FILE, CODEX_USAGE_FILE,
                                    SPEND_FILE, SPEND_CACHE_FILE, SPEND_EVENTS_FILE, BALANCE_FILE)
        if home_state:
            try:                     # write_json replaces a file atomically: only preserving a corrupt one takes the lock
                return _read_json(path, default, False, object_required)
            except StateError:
                pass
        with state_lock(ORCH_HOME / ".state.lock" if home_state else state_dir() / ".state.lock"):
            return _read_json(path, default, True, object_required)
    return _read_json(path, default, False, object_required)


def _read_text_retry(path, encoding="utf-8"):
    """Path.read_text that retries a PermissionError — os.replace in write_json races a reader on Windows. A status line
    run opens each file once until it is written or a lock is taken: opening files is most of what such a run does."""
    key = (str(path), encoding)
    if _statusline_run and key in _run_reads:
        if _run_reads[key] is None:
            raise FileNotFoundError(str(path))
        return _run_reads[key]
    for attempt in range(5):
        try:
            text = Path(path).read_text(encoding=encoding)
            if _statusline_run:
                _run_reads[key] = text
            return text
        except FileNotFoundError:
            if _statusline_run:
                _run_reads[key] = None
            raise
        except PermissionError:
            if attempt == 4:
                raise
            time.sleep(0.01 * (2 ** attempt))


def _read_json(path, default, recover_corrupt, object_required):
    try:
        data = json.loads(_read_text_retry(path))
        if (isinstance(default, dict) or object_required) and not isinstance(data, dict):
            raise ValueError("expected a JSON object")
        return data
    except FileNotFoundError:
        return default
    except PermissionError as ex:
        raise StateError("cannot read %s: %s" % (path, ex))
    except ValueError as ex:
        if recover_corrupt:
            backup = Path(str(path) + ".corrupt")
            n = 1
            while backup.exists():
                backup = Path(str(path) + ".corrupt.%d" % n)
                n += 1
            try:
                Path(path).rename(backup)
            except OSError as rename_error:
                raise StateError("cannot preserve %s: %s" % (path, rename_error))
            warn_state(path, "corrupt state preserved as %s; starting fresh" % backup)
            return default
        raise StateError("cannot read %s: %s" % (path, ex))
    except OSError as ex:
        raise StateError("cannot read %s: %s" % (path, ex))


def write_json(path, data, compact=False):
    """Atomic: a process killed mid-write leaves the old file whole and a *.tmp beside it (sweep_orch_home removes it)."""
    path = Path(path)
    if not path.parent.is_dir():
        path.parent.mkdir(parents=True, exist_ok=True)
    _run_reads.clear()
    tmp = None
    try:
        name = path.parent / ("%s.%d.%x.tmp" % (path.name, os.getpid(), time.time_ns()))
        with open(str(name), "x", encoding="utf-8", newline="\n", opener=lambda p, fl: os.open(p, fl, 0o600)) as f:
            tmp = name
            json.dump(data, f, ensure_ascii=False, indent=None if compact else 2)
        for attempt in range(8):
            try:
                os.replace(str(tmp), str(path))
                break
            except PermissionError:
                if attempt == 7:
                    raise
                time.sleep(0.01 * (2 ** attempt))
    except OSError as ex:
        raise StateError("cannot write %s: %s" % (path, ex))
    finally:
        if tmp is not None and tmp.exists():
            tmp.unlink()


def git(args, cwd, check=False):
    import subprocess
    try:
        r = subprocess.run(["git"] + args, cwd=str(cwd), capture_output=True, text=True)
    except FileNotFoundError:
        if check:
            raise SystemExit("orch: git not found")
        return None
    if check and r.returncode != 0:
        raise SystemExit("orch: git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r


def git_common_of_file(top, dot_git):
    """The common git directory named by a `.git` file: a linked worktree's main .git, a submodule's own directory.
    None when the file is broken."""
    try:
        with open(str(dot_git), encoding="utf-8") as f:
            text = f.read().strip()
    except (OSError, UnicodeDecodeError):
        return None
    if not text.startswith("gitdir:"):
        return None
    gitdir = top / local_path(text[len("gitdir:"):].strip())
    try:
        with open(str(gitdir / "commondir"), encoding="utf-8") as f:
            return (gitdir / local_path(f.read().strip())).resolve()      # usually relative to the git directory
    except FileNotFoundError:                                             # no commondir: a repository of its own,
        return gitdir.resolve() if (gitdir / "HEAD").exists() else None   # unless the file points nowhere
    except (OSError, UnicodeDecodeError):
        return None


def git_walk(path):
    """(top of the working tree, common git directory) for a resolved directory, from the files alone, no `git`
    process. Like git, it looks upward for `.git`, a folder with a HEAD or a file (a linked worktree, a submodule).
    (None, None) outside a repository; (top, None) with a broken `.git` file."""
    for d in (path,) + tuple(path.parents):
        dot = d / ".git"
        try:
            if dot.is_dir():
                if (dot / "HEAD").exists():
                    return d, dot
            elif dot.exists():
                return d, git_common_of_file(d, dot)
        except OSError:
            continue
    return None, None


_toplevels = {}                # cwd → project root: this is called many times


def project_dir():
    for var in ("ORCH_PROJECT_DIR", "CLAUDE_PROJECT_DIR"):
        v = os.environ.get(var)
        if v:
            return Path(v).resolve()
    cwd = Path.cwd()
    if cwd not in _toplevels:
        top, common = git_walk(cwd.resolve())
        _toplevels[cwd] = top if common is not None else cwd.resolve()
    return _toplevels[cwd]


def state_dir(create=True):
    p = project_dir() / ".orchestra"
    if create and not p.exists():
        p.mkdir(parents=True, exist_ok=True)
        ensure_git_exclude(project_dir())
    return p


def ensure_git_exclude(proj, patterns=(".orchestra/",)):
    """Keep orchestra files out of git status without touching .gitignore (shared by all worktrees)."""
    r = git(["rev-parse", "--git-common-dir"], proj)
    if r is None or r.returncode != 0:
        return
    common = Path(r.stdout.strip())
    if not common.is_absolute():
        common = (proj / common).resolve()
    excl = common / "info" / "exclude"
    excl.parent.mkdir(parents=True, exist_ok=True)
    text = excl.read_text(encoding="utf-8") if excl.exists() else ""
    missing = [p for p in patterns if p not in text.split()]
    if missing:
        with excl.open("a", encoding="utf-8") as f:
            if text and not text.endswith("\n"):
                f.write("\n")
            f.write("# orchestra plugin state\n" + "".join(p + "\n" for p in missing))


def rand_suffix(n=4):
    import random
    import string
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(n))


_win_path_cache = {}


def win_path(p):
    """Windows form of a path for display; only meaningful under WSL (wslpath), None elsewhere."""
    import shutil
    import subprocess
    key = str(p)
    if key in _win_path_cache:
        return _win_path_cache[key]
    result = None
    if shutil.which("wslpath"):
        r = subprocess.run(["wslpath", "-w", str(p)], capture_output=True, text=True)
        if r.returncode == 0:
            result = r.stdout.strip()
    _win_path_cache[key] = result
    return result


def copy_to_clipboard(text):
    import shutil
    import subprocess
    candidates = [
        (["clip.exe"], text.encode("utf-16le")),
        (["wl-copy"], text.encode()),
        (["xclip", "-selection", "clipboard"], text.encode()),
        (["pbcopy"], text.encode()),
    ]
    for cmd, data in candidates:
        if shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=data, check=True, timeout=10)
                return cmd[0]
            except Exception:
                continue
    return None


def platform_name():
    import platform
    if IS_WINDOWS:
        return "Windows (native)"
    if os.environ.get("WSL_DISTRO_NAME") or "microsoft" in platform.release().lower():
        return "WSL (Linux)"
    return "macOS" if sys.platform == "darwin" else "Linux"


def find_bash():
    """bash for shell adapters. On Windows only Git Bash: System32\\bash.exe is WSL and would run the adapter in Linux."""
    import shutil
    if not IS_WINDOWS:
        return shutil.which("bash")
    cands = [os.environ.get("CLAUDE_CODE_GIT_BASH_PATH")]
    w = shutil.which("bash")
    if w and "system32" not in w.lower() and "windowsapps" not in w.lower():
        cands.append(w)
    g = shutil.which("git")
    if g:
        root = Path(g).resolve().parent.parent      # <Git>\cmd\git.exe or <Git>\mingw64\bin\git.exe
        cands += [str(root / "bin" / "bash.exe"), str(root.parent / "bin" / "bash.exe")]
    for base in (os.environ.get("ProgramFiles"), os.environ.get("LOCALAPPDATA")):
        if base:
            cands += [os.path.join(base, "Git", "bin", "bash.exe"), os.path.join(base, "Programs", "Git", "bin", "bash.exe")]
    return next((c for c in cands if c and os.path.isfile(c)), None)


def exe_command(path):
    """A .py stand-in (tests, wrappers) runs with this interpreter."""
    return [sys.executable, path] if str(path).endswith(".py") else [path]


def find_codex():
    """codex binary the way adapters/codex resolves it: ORCH_CODEX_BIN → PATH → (Windows) CLI of the Codex app."""
    import shutil
    c = os.environ.get("ORCH_CODEX_BIN") or shutil.which("codex")
    if c:
        return c, ""
    if IS_WINDOWS and os.environ.get("LOCALAPPDATA"):
        found = sorted(Path(os.environ["LOCALAPPDATA"], "OpenAI", "Codex", "bin").glob("*/codex.exe"),
                       key=lambda p: p.stat().st_mtime)
        if found:
            return str(found[-1]), " (from the Codex app; more stable: npm i -g @openai/codex)"
    return None, ""


# ───────────────────────── availability (quota) ─────────────────────────

AVAIL_FILE = ORCH_HOME / "availability.json"
STATUSES = ("ok", "low", "exhausted", "disabled", "away", "busy")


@locked("home")
def load_avail(prune=True, strict=False):
    try:
        data = read_json(AVAIL_FILE, {"entries": {}})
        if not isinstance(data.get("entries", {}), dict) or any(not isinstance(v, dict) for v in data.get("entries", {}).values()):
            raise StateError("cannot read %s: invalid entries" % AVAIL_FILE)
    except StateError as ex:
        if strict:
            raise
        warn_state(AVAIL_FILE, str(ex))
        return {"entries": {}}
    entries = data.setdefault("entries", {})
    if prune:
        changed = False
        for k in list(entries):
            until = parse_iso(entries[k].get("until"))
            if until and until <= now():
                del entries[k]
                changed = True
        if changed:
            write_json(AVAIL_FILE, data)
    return data


def norm_key(key):
    return key.strip().lower().replace(":", "/")


def key_chain(key):
    """codex/gpt-5.6-sol -> [codex/gpt-5.6-sol, codex];
    deepseek@work/deepseek-flash -> [deepseek@work/deepseek-flash, deepseek/deepseek-flash, deepseek@work, deepseek]"""
    parts = norm_key(key).split("/")
    head, _, prof = parts[0].partition("@")
    out = []
    for i in range(len(parts) - 1, -1, -1):
        tail = "".join("/" + x for x in parts[1:i + 1])
        if prof:
            out.append(head + "@" + prof + tail)
        out.append(head + tail)
    return out


def availability(key):
    """Return (available: bool, entry or None, matched_key)."""
    entries = load_avail()["entries"]
    for k in key_chain(key):
        e = entries.get(k)
        if e:
            return (e.get("status") == "low", e, k)
    return (True, None, None)


@locked("home")
def set_avail(key, status, until=None, note=None, source="manual"):
    key = norm_key(key)
    data = load_avail(strict=True)
    if status == "ok":
        data["entries"].pop(key, None)
    else:
        data["entries"][key] = {
            "status": status, "until": iso(until), "note": note,
            "set_at": iso(now()), "source": source,
        }
    write_json(AVAIL_FILE, data)


def describe_entry(k, e):
    until = parse_iso(e.get("until"))
    when = ("until %s (%s)" % (until.strftime("%d.%m %H:%M"), human_delta(until))) if until else \
        "until cleared manually"
    note = (" — " + e["note"]) if e.get("note") else ""
    return "%-28s %-9s %s%s" % (k, e.get("status"), when, note)


def availability_status(entry):
    return "CAPACITY" if entry.get("status") == "busy" else "QUOTA_EXHAUSTED"


@locked("home")
def cmd_quota(a):
    if a.action == "show":
        data = load_avail()
        if a.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
            return 0
        if not data["entries"]:
            print("All executors available (no restrictions).")
        for k, e in sorted(data["entries"].items()):
            print(describe_entry(k, e))
        return 0
    if a.action == "set":
        if a.status not in STATUSES:
            raise SystemExit("orch: status must be one of %s" % ", ".join(STATUSES))
        until = parse_until(a.until) if a.until else None
        set_avail(a.key, a.status, until, a.note)
        if a.status == "ok":
            print("%s: restriction cleared" % norm_key(a.key))
        else:
            print(describe_entry(norm_key(a.key), load_avail()["entries"][norm_key(a.key)]))
        return 0
    if a.action == "clear":
        key = norm_key(a.key)
        data = load_avail(strict=True)
        # a bare provider also clears its profile entries (deepseek → deepseek@work), not its model entries
        gone = [k for k in data["entries"] if k == key or ("/" not in key and "@" not in key and "/" not in k
                                                             and k.startswith(key + "@"))]
        for k in gone:
            del data["entries"][k]
        write_json(AVAIL_FILE, data)
        print("\n".join("%s: restriction cleared" % k for k in gone) or "%s: was not restricted" % key)
        return 0
    if a.action == "check":
        ok, e, k = availability(a.key)
        if e is None:
            print("%s: available" % norm_key(a.key))
            return 0
        print(("%s: available (LOW) — " if ok else "%s: UNAVAILABLE — ") % norm_key(a.key) + describe_entry(k, e))
        return 0 if ok else EXIT_QUOTA
    return 1


# ───────────────────────── Claude subscription budget (use it or lose it) ─────────────────────────
#
# Claude Code hands the statusLine command `rate_limits` (5-hour and 7-day windows: % used, reset time). The numbers
# are account-wide: every session on the account is already in them. `orch statusline`, running in every session,
# adds them to a shared snapshot with a short history; the operator can report the same numbers (`orch budget set`).
# The pace is the higher of the window average and the last 30–60 minutes, so the projection follows every instance
# consuming right now. A reserve is kept for other sessions and safety (profile claude: reserve, week_reserve):
# SURPLUS — the window would expire with a lot left beyond the reserve (shared between the active sessions);
# TIGHT — it would reach the reserve before the reset. A five-hour projection (either mode) needs at least
# PROJECTION_MIN_ELAPSED minutes of the window behind it; a used share that has reached the reserve needs none.

USAGE_SNAPSHOT = ORCH_HOME / "claude_usage.json"
SESSIONS_FILE = ORCH_HOME / "sessions.json"
BUDGET_DEFAULTS = {"surplus": 30, "reserve": 10, "week_reserve": 10}    # % — profile claude: --opt surplus=N|off, …
PACE_MIN_ELAPSED = 30      # minutes into a week before its average pace is trusted
PROJECTION_MIN_ELAPSED = 60    # minutes of a five-hour window that must have passed before a projection counts
RECENT_PACE = (30, 60)     # the recent pace: the oldest sample 30–60 minutes back
ACTIVE_MIN = 15            # a session seen within this many minutes is active
HISTORY_KEEP_H = 6
WEEK_HISTORY_KEEP_H = 80   # hours a weekly sample is kept (a pace base about 72 h old must still be there)
WEEK_HISTORY_CAP = 400     # most weekly samples kept (one per 15 min over 80 h is 320)
WEEK_HISTORY_MIN_GAP = 15  # minutes between weekly samples
WEEK_PACE_MAX_AGE = 72     # hours back a weekly base sample may sit
WEEK_PACE_MIN_GAP = 6      # hours a weekly base sample must be before the measurement


def epoch_iso(v):
    try:
        return iso(dt.datetime.fromtimestamp(float(v)).astimezone())
    except (TypeError, ValueError, OverflowError, OSError):
        return None


@locked("home")
def save_usage(windows, source):
    """{"five_hour": {"used": %, "resets_at": iso}, "seven_day": {…}} → the snapshot shared by all sessions, plus a
    sample of the 5-hour window for the recent pace."""
    snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
    t = now()
    stale = any((t - (measured_at(snap, k) or t - dt.timedelta(days=1))).total_seconds() > 60 for k in windows)
    if all({f: snap.get(k, {}).get(f) for f in v} == v for k, v in windows.items()) \
            and snap.get("source") == source and not stale:
        return                     # the status line refreshes often: write only on a change (or once a minute)
    # Preserve the measurement time of windows absent from this update, including old snapshots.
    for name in ("five_hour", "seven_day"):
        if isinstance(snap.get(name), dict):
            if not snap[name].get("updated"):
                snap[name]["updated"] = snap.get("updated")
    snap.update({k: dict(v, updated=iso(t)) for k, v in windows.items()}, updated=iso(t), source=source)
    five = windows.get("five_hour")
    if five:
        keep = t - dt.timedelta(hours=HISTORY_KEEP_H)
        hist = [h for h in snap.get("history") or [] if isinstance(h, list) and len(h) == 3
                and (parse_iso(str(h[0])) or keep) > keep]
        if not hist or hist[-1][1:] != [five["used"], five["resets_at"]] or stale:
            hist.append([iso(t), five["used"], five["resets_at"]])
        snap["history"] = hist[-300:]
    snap["week_history"] = week_history_update(snap.get("week_history"), windows.get("seven_day"), t)
    write_json(USAGE_SNAPSHOT, snap)


def usage_window(snap, name):
    """(used %, reset time or None) while the window is current; None once it has reset (stale numbers)."""
    w = snap.get(name) if isinstance(snap.get(name), dict) else {}
    if w.get("used") is None:
        return None
    reset = parse_iso(w.get("resets_at") or "")
    if reset and reset <= now():
        return None
    return float(w["used"]), reset


USAGE_FRESH_SECONDS = 20 * 60


def measured_at(snap, name):
    w = snap.get(name) or {}
    return parse_iso(w.get("updated") or snap.get("updated") or "")


def window_pace(snap, used, reset, hours):
    """(%/min, basis): the higher of the window average and the recent pace of all sessions; (None, None) if unknown.
    In a five-hour window both are unknown until PROJECTION_MIN_ELAPSED minutes of it have passed at the measurement."""
    if reset is None:
        return None, None
    t = measured_at(snap, "five_hour" if hours == 5 else "seven_day")
    if t is None:
        return None, None
    elapsed = (t - (reset - dt.timedelta(hours=hours))).total_seconds() / 60
    if hours == 5 and elapsed < PROJECTION_MIN_ELAPSED:
        return None, None
    rates = []
    if elapsed >= PACE_MIN_ELAPSED:
        rates.append((used / elapsed, "window average"))
    if hours == 5:
        lo, hi = t - dt.timedelta(minutes=RECENT_PACE[1]), t - dt.timedelta(minutes=RECENT_PACE[0])
        base = []
        for h in snap.get("history") or []:
            if not (isinstance(h, list) and len(h) == 3):
                continue
            ts, r = parse_iso(str(h[0])), parse_iso(str(h[2] or ""))
            if ts and r and abs((r - reset).total_seconds()) < 600 and lo <= ts <= hi:
                base.append((ts, float(h[1])))
        if base:
            ts0, u0 = min(base)                     # the longest baseline in the range
            mins = (t - ts0).total_seconds() / 60
            rates.append((max(used - u0, 0) / mins, "last %d min, all sessions" % mins))
    return max(rates) if rates else (None, None)


def projected_at_reset(used, reset, rate, measured):
    return used + rate * (reset - measured).total_seconds() / 60


def week_base_sample(history, reset, measured, used=None):
    """The earliest week_history sample from the last 72 hours (three days) with the same reset (within 10 minutes)
    and at least 6 hours before the measurement — the longest recent baseline: one heavy or light day does not swing
    the pace. Without one, the newest older sample with the same reset stands in for a flat week: if its used equals
    the current one, the recent pace is zero and the base is (measured - 72 h, used), so the basis reads 'the last
    3 d'. Malformed entries are skipped, never fatal."""
    if reset is None or measured is None:
        return None
    lo = measured - dt.timedelta(hours=WEEK_PACE_MAX_AGE)
    best = None
    newest_older = None
    for h in history or []:
        if not (isinstance(h, list) and len(h) == 3):
            continue
        ts = parse_iso(str(h[0]))
        r = parse_iso(str(h[2] or ""))
        if not (ts and r) or abs((r - reset).total_seconds()) >= 600:
            continue
        try:
            u0 = float(h[1])
        except (TypeError, ValueError):
            continue
        if ts < lo and (newest_older is None or ts > newest_older[0]):
            newest_older = (ts, u0)
        if not (lo <= ts <= measured) or (measured - ts).total_seconds() < WEEK_PACE_MIN_GAP * 3600:
            continue
        if best is None or ts < best[0]:
            best = (ts, u0)
    if best is None and newest_older is not None and used is not None and newest_older[1] == used:
        return (measured - dt.timedelta(hours=WEEK_PACE_MAX_AGE), used)
    return best


def week_recent_basis(mins):
    """'the last 8 h' / 'the last 6h 30m' / 'the last 2d 12h' from the minutes between the base sample and the
    measurement. From 24 hours on the coarse scale is days and hours, minutes dropped ('the last 3 d' at a whole
    number of days)."""
    total = int(round(mins))
    h, m = divmod(total, 60)
    if total >= 24 * 60:
        d, h = divmod(h, 24)
        if h == 0:
            return "the last %d d" % d
        return "the last %dd %dh" % (d, h)
    if m == 0:
        return "the last %d h" % h
    if h:
        return "the last %dh %dm" % (h, m)
    return "the last %d min" % max(total, 1)


def week_rate(history, used, reset, measured, window_minutes=10080):
    """(%/min, basis) of the week: the recent pace from week_history when a base sample exists, else the
    window average; (None, None) when neither is computable. The recent pace is used when it is available,
    not the higher of the two — the weekly alarm must not stay on because of an old burst."""
    base = week_base_sample(history, reset, measured, used)
    if base is not None:
        ts0, u0 = base
        mins = (measured - ts0).total_seconds() / 60.0
        if mins > 0:
            return max(used - u0, 0) / mins, week_recent_basis(mins)
    if reset is None or measured is None:
        return None, None
    elapsed = (measured - (reset - dt.timedelta(minutes=window_minutes))).total_seconds() / 60.0
    if elapsed >= PACE_MIN_ELAPSED:
        return used / elapsed, "the week's average"
    return None, None


def week_reserve(reserve, reset, measured, window_minutes=10080):
    """The effective weekly reserve: reserve × (time left / window), floored at 1 point (0 stays 0). The
    margin for what may still come shrinks as the window runs out; a reserve set to 0 stays 0."""
    if reserve <= 0:
        return 0.0
    if reset is None or measured is None:
        return float(reserve)
    remaining = (reset - measured).total_seconds() / 60.0
    if remaining <= 0 or window_minutes <= 0:
        return float(reserve)
    return float(min(reserve, max(1.0, reserve * remaining / window_minutes)))


def week_reserve_text(reserve, effective):
    """'10%' when the effective reserve rounds to the flat one, '2% (10% at the start of the week)' otherwise."""
    if pct(effective) == pct(reserve):
        return "%d%%" % pct(reserve)
    return "%d%% (%d%% at the start of the week)" % (pct(effective), pct(reserve))


def week_history_update(hist, week, t):
    """Retained week_history ([ts, used, resets_at]), plus a sample when `week` is a new measurement (used or
    reset changed) and at least WEEK_HISTORY_MIN_GAP minutes have passed. Malformed entries are dropped; the
    series is kept for WEEK_HISTORY_KEEP_H hours and capped at WEEK_HISTORY_CAP entries."""
    keep = t - dt.timedelta(hours=WEEK_HISTORY_KEEP_H)
    out = [h for h in hist or [] if isinstance(h, list) and len(h) == 3
           and (parse_iso(str(h[0])) or keep) > keep]
    if week and week.get("resets_at"):
        last = out[-1] if out else None
        last_ts = parse_iso(str(last[0])) if last else None
        changed = not last or last[1:] != [week["used"], week["resets_at"]]
        gap_ok = not last_ts or (t - last_ts).total_seconds() >= WEEK_HISTORY_MIN_GAP * 60
        if changed and gap_ok:
            out.append([iso(t), week["used"], week["resets_at"]])
    return out[-WEEK_HISTORY_CAP:]


def budget_settings(where=None):
    """surplus / reserve / week_reserve (%) from the claude profile, else BUDGET_DEFAULTS; Claude off → no surplus."""
    out = dict(BUDGET_DEFAULTS)
    try:
        prof = resolve_profile("claude", where or project_dir())
    except ProfileError as ex:
        if str(PROFILES_FILE) in str(ex):
            warn_state(PROFILES_FILE, str(ex))
        return out
    if prof.name == "off":
        out["surplus"] = 0
        return out
    for k in out:
        v = str(prof.data.get(k, out[k])).lower()
        out[k] = 0 if v in ("off", "no", "false") else int(v) if v.isdigit() else out[k]
    return out


@locked("home")
def heartbeat(key, where=None, kind="session"):
    """Mark a session (or a running Claude executor) as a Claude consumer; at most once a minute."""
    if not key:
        return
    data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    data = data if isinstance(data, dict) else {}
    t = now()
    e = data.get(key) if isinstance(data.get(key), dict) else {}
    seen, lead = parse_iso(e.get("seen") or ""), os.environ.get("ORCH_LEAD") or None
    if seen and (t - seen).total_seconds() < 60 and e.get("lead") == lead:
        return
    data = {k: v for k, v in data.items() if isinstance(v, dict) and parse_iso(v.get("seen") or "")
            and (t - parse_iso(v["seen"])).total_seconds() < 86400}
    project = e.get("project")
    if where is not None or not project:
        project = canon_path(project_root(Path(where) if where else project_dir()))
    data[key] = {"seen": iso(t), "since": e.get("since") or iso(t), "kind": kind, "lead": lead, "project": project}
    write_json(SESSIONS_FILE, data)


@locked("home")
def forget(key):
    data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    if isinstance(data, dict) and data.pop(key, None) is not None:
        write_json(SESSIONS_FILE, data)


def claude_consumers():
    """Active Claude consumers orch knows of: Claude-led sessions seen within ACTIVE_MIN minutes, and
    Claude executor runs in progress (a session led by another model does not spend Claude)."""
    data = read_json(SESSIONS_FILE, {}, recover_corrupt=True)
    t, out = now(), {}
    for k, v in (data.items() if isinstance(data, dict) else []):
        seen = parse_iso(v.get("seen") or "") if isinstance(v, dict) else None
        if not seen:
            continue
        age = (t - seen).total_seconds()
        if (v.get("kind") == "executor" and age < 3 * 3600) or (not v.get("lead") and age < ACTIVE_MIN * 60):
            out[k] = v
    return out


_claude_budget_active = False


def claude_budget(where=None):
    # SURPLUS routing resolves API profiles, whose soft budgets ask about Claude again.
    # TIGHT returns before that routing step, so a recursive query is necessarily not TIGHT.
    global _claude_budget_active
    if _claude_budget_active:
        return "normal", None
    _claude_budget_active = True
    try:
        return _claude_budget(where)
    finally:
        _claude_budget_active = False


def _claude_budget(where=None):
    """(mode, line): projections stay anchored to measurements; either limit can make Claude tight."""
    kvar = profile_key("claude", where, follow=False)
    if kvar:
        return "api", ("Claude: bills to the profile key (%s) instead of the subscription — no budget mode "
                       "(SURPLUS/TIGHT off)" % kvar)
    snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
    five, week = usage_window(snap, "five_hour"), usage_window(snap, "seven_day")
    cfg = budget_settings(where)
    weekly = None
    week_tight = False
    week_reserve_txt = "%d%%" % cfg["week_reserve"]
    if week:
        wu, wr = week
        wm = measured_at(snap, "seven_day")
        wrate, wbasis = week_rate(snap.get("week_history"), wu, wr, wm)
        weekly = max(wu, projected_at_reset(wu, wr, wrate, wm)) if wrate is not None else wu
        projection = ("%d%% projected from %s" % (pct(weekly), wbasis)) if wrate is not None else "projection unavailable"
        elapsed = (wm - (wr - dt.timedelta(days=7))).total_seconds() if wm and wr else 0
        eff = week_reserve(cfg["week_reserve"], wr, wm)
        week_reserve_txt = week_reserve_text(cfg["week_reserve"], eff)
        week_tight = wu >= 100 - eff or (
            elapsed >= 86400 and weekly >= 100 - eff)
    instruction = "treat Claude as low (conserve it; offload to Codex / DeepSeek)."
    weekly_line = (" TIGHT: weekly limit is tight (%s, %d%% used, reserve %s) — %s"
                   % (projection, pct(week[0]), week_reserve_txt, instruction)) if week_tight else ""
    if not five or five[1] is None:
        if week_tight:
            return "tight", "Claude subscription:" + weekly_line
        return "unknown", None
    used, reset = five
    measured = measured_at(snap, "five_hour")
    age = max((now() - measured).total_seconds(), 0) if measured else None
    stale = age is None or age > USAGE_FRESH_SECONDS
    users = claude_consumers()
    sessions = sum(1 for v in users.values() if v.get("kind") != "executor")
    runs = len(users) - sessions
    at = reset.astimezone().strftime("%H:%M")
    active = ("; active: %d session%s%s" % (sessions, "" if sessions == 1 else "s",
                                                        ", %d Claude executor run%s" % (runs, "" if runs == 1 else "s")
                                                        if runs else "")) if users else ""
    line = "Claude subscription: 5-hour window %d%% used, resets %s (%s)%s%s; reserve %d%%%s" % (
        pct(used), at, human_delta(reset), ", week %d%%" % pct(week[0]) if week else "",
        " — reported by the operator" if snap.get("source") == "operator" else "", cfg["reserve"], active)
    if stale:
        line += "; measured %s (stale)" % (human_delta(measured) if measured else "at an unknown time")
    if week_tight:
        return "tight", line + "." + weekly_line
    rate, basis = window_pace(snap, used, reset, 5)
    cap = 100 - cfg["reserve"]
    projected = projected_at_reset(used, reset, rate, measured) if rate is not None else used
    if used >= cap or (projected >= cap and rate is not None and rate > 0):
        hit = measured + dt.timedelta(minutes=max(cap - used, 0) / rate) if rate else None
        when = ("it reaches the reserve ≈%s, before the reset" % hit.astimezone().strftime("%H:%M")
                if hit and hit > now() else "the reserve is already reached or projected to be reached")
        return "tight", line + ". TIGHT: at the current pace (%s) %s — %s" % (basis or "used share", when, instruction)
    spare = cap - projected
    if rate is None or stale or cfg["surplus"] <= 0 or spare < cfg["surplus"]:
        return "normal", line + "."
    each = " — ≈%d%% for each of the %d sessions" % (pct(spare / sessions), sessions) if sessions > 1 else ""
    exceptions = preferred_api_profiles(where)
    except_text = (", except the task types preferred for " + " and ".join(
        "%s (%s)" % (name, ", ".join(types)) for name, types in exceptions)) if exceptions else ""
    return "surplus", line + (". SURPLUS: at the current pace (%s) about %d%% of the window would expire unused beyond "
                              "the reserve%s — until %s give subtasks to Claude subagents rather than to API-billed "
                              "executors (DeepSeek, API-key profiles)%s; orch guide budget." % (
                                  basis, pct(spare), each, at, except_text))


@locked("home")
def budget_event(session, announce=True):
    """A hook event when this session's budget mode changes (surplus / tight / normal), once per change.
    announce=False only records the mode (SessionStart already prints it in the status)."""
    mode, line = claude_budget()
    if mode in ("unknown", "api"):
        return None
    snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
    seen = snap.get("announced") if isinstance(snap.get("announced"), dict) else {}
    key = session or "-"
    if seen.get(key) == mode:
        return None
    seen.pop(key, None)
    seen[key] = mode
    snap["announced"] = dict(list(seen.items())[-30:])
    write_json(USAGE_SNAPSHOT, snap)
    return ("💡 " + line) if announce else None


@locked("home")
def cmd_budget(a):
    """orch budget [show|set|clear]: the Claude subscription budget used for routing (surplus / tight)."""
    if a.action == "set":
        if a.used is None or not a.resets:
            raise SystemExit("orch: orch budget set --used PERCENT --resets TIME [--week PERCENT [--week-resets TIME]]")
        windows = {"five_hour": {"used": float(a.used), "resets_at": iso(parse_until(a.resets))}}
        if a.week is not None:
            windows["seven_day"] = {"used": float(a.week),
                                    "resets_at": iso(parse_until(a.week_resets)) if a.week_resets else None}
        save_usage(windows, "operator")
    elif a.action == "clear":
        if USAGE_SNAPSHOT.exists():
            USAGE_SNAPSHOT.unlink()
        print("Claude budget snapshot cleared.")
        return 0
    mode, line = claude_budget()
    if mode == "unknown":
        print("No current Claude subscription numbers. Add `orch statusline` as the Claude Code status line "
              "(orch guide budget), or report them: orch budget set --used 40 --resets 18:00")
        return 0
    if mode == "api":
        print(line)
        return 0
    print(line)
    users = claude_consumers()
    if users:
        print("Active Claude consumers known to orch (sessions seen within %d min, Claude executor runs):" % ACTIVE_MIN)
        for k, v in sorted(users.items(), key=lambda kv: kv[1].get("since") or ""):
            print("  %-14s %-8s %s · since %s · seen %s%s" % (
                k[:14], "run" if v.get("kind") == "executor" else "session", v.get("project") or "?",
                short_time(v.get("since")), human_delta(parse_iso(v["seen"])), " (this session)" if k == session_id() else ""))
    cfg = budget_settings()
    print("Thresholds: surplus ≥ %d%% beyond a reserve of %d%% of the window, week reserve %d%% "
          "(profile claude: --opt surplus=N|off, reserve=N, week_reserve=N)." % (
              cfg["surplus"], cfg["reserve"], cfg["week_reserve"]))
    return 0


# ───────────────────────── Codex subscription limits (read from its session logs) ─────────────────────────
#
# Codex writes session logs to $CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl; a token_count event carries
# `rate_limits` (5-hour and weekly windows by window_minutes). The format is undocumented — parse defensively:
# anything unexpected means "no data", never an error. `orch statusline` caches the newest windows per account in
# ~/.orchestra/codex_usage.json, keyed by the effective CODEX_HOME (so a profile with --home has its own entry);
# `orch run codex` refreshes right after finishing. A window whose reset has passed counts as absent.

CODEX_USAGE_FILE = ORCH_HOME / "codex_usage.json"
CODEX_TAIL_BYTES = 256 * 1024
CODEX_REFRESH_SECONDS = 60
CODEX_WINDOWS = ((300, "five_hour"), (10080, "seven_day"))


def codex_home(where=None, prof=None):
    """Effective CODEX_HOME: the profile's --home (account) or the environment / the default ~/.codex.
    A resolved `prof` (the run's own profile) is used when given, so `--profile` is honoured."""
    home = os.environ.get("CODEX_HOME")
    try:
        p = prof if prof is not None else resolve_profile("codex", where or project_dir())
        if p.name != "off" and p.data.get("home"):
            home = local_path(str(p.data["home"]))
    except ProfileError:
        pass
    return str(Path(home).expanduser()) if home else str(Path.home() / ".codex")


def codex_rollouts(home, days=3, per_day=3):
    """Newest rollout files: the latest date directories first, a bounded few only."""
    sessions = Path(home) / "sessions"
    if not sessions.is_dir():
        return []
    day_dirs = []
    for y in sessions.iterdir():
        if not y.is_dir() or not y.name.isdigit():
            continue
        for m in y.iterdir():
            if not m.is_dir() or not m.name.isdigit():
                continue
            for d in m.iterdir():
                if d.is_dir() and d.name.isdigit():
                    day_dirs.append(d)
    day_dirs.sort(key=lambda d: (d.parent.parent.name, d.parent.name, d.name), reverse=True)
    out = []
    for d in day_dirs[:days]:
        try:
            found = sorted(d.glob("rollout-*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)
        except OSError:
            continue
        out.extend(found[:per_day])
    return out


def tail_lines(path, max_bytes):
    """The last `max_bytes` of a file, as lines, with the first partial line dropped."""
    try:
        size = path.stat().st_size
        start = max(0, size - max_bytes)
        with path.open("rb") as f:
            f.seek(start)
            data = f.read()
    except OSError:
        return []
    if start > 0:
        nl = data.find(b"\n")
        if nl != -1:
            data = data[nl + 1:]
    return data.decode("utf-8", "replace").splitlines()


def codex_event_limits(line):
    """(measured, {window_minutes: {used, resets_at}}, plan_type) of one rollout line, or None."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    if not isinstance(ev, dict) or ev.get("type") != "event_msg":
        return None
    measured = parse_iso(str(ev.get("timestamp") or "").replace("Z", "+00:00"))
    payload = ev.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None
    rl = payload.get("rate_limits")
    if not isinstance(rl, dict) or measured is None:
        return None
    windows = {}
    for name in ("primary", "secondary"):
        w = rl.get(name)
        if not isinstance(w, dict):
            continue
        wm = w.get("window_minutes")
        used = w.get("used_percent")
        if used is None:
            used = w.get("used")
        resets = epoch_iso(w.get("resets_at"))
        if not isinstance(wm, (int, float)) or not isinstance(used, (int, float)) or resets is None:
            continue
        windows[int(wm)] = {"used": float(used), "resets_at": resets}
    if not windows:
        return None
    return measured, windows, rl.get("plan_type")


def codex_work_model(model):
    """The model id, or None for no model or for Codex's internal auto-review step (`codex-auto-review`), which
    runs between the operator's own turns and is not the model they work with."""
    m = str(model).strip() if model else ""
    return None if not m or "auto-review" in m.lower() else m


def codex_event_model(line):
    """The model of a `turn_context` event (the last turn), or None; the internal auto-review model is ignored,
    so the last real model of the tail stays."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    if not isinstance(ev, dict) or ev.get("type") != "turn_context":
        return None
    payload = ev.get("payload")
    if not isinstance(payload, dict):
        return None
    return codex_work_model(payload.get("model"))


def scan_codex_limits(home):
    """The newest windows seen in the newest rollout tails, plus the last turn's model; or None when nothing is
    readable. The model comes from the same file that gave the limits; only the tail of each file is read."""
    try:
        best = None
        model = None
        for f in codex_rollouts(home):
            file_model = None
            for line in tail_lines(f, CODEX_TAIL_BYTES):
                m = codex_event_model(line)
                if m:
                    file_model = m
                ev = codex_event_limits(line)
                if ev and (best is None or ev[0] > best[0]):
                    best = (ev[0], ev[1], ev[2], f)
            if best is not None and best[3] == f:
                model = file_model
        if best is None:
            return None
        return best[0], best[1], best[2], model
    except OSError:
        return None


def codex_windows(measured, windows, plan_type):
    """Cache entry {five_hour: {…}, seven_day: {…}, plan_type} with each window's own measurement time."""
    out = {}
    for wm, name in CODEX_WINDOWS:
        w = windows.get(wm)
        if w and parse_iso(w["resets_at"]) > now():
            out[name] = {"used": w["used"], "resets_at": w["resets_at"], "measured": iso(measured)}
    if plan_type:
        out["plan_type"] = str(plan_type)
    return out


def read_codex_cache(home):
    """(whole cache, this account's entry)."""
    snap = read_json(CODEX_USAGE_FILE, {}, recover_corrupt=True)
    if not isinstance(snap, dict):
        snap = {}
    return snap, snap.get(home) if isinstance(snap.get(home), dict) else {}


def codex_scanned_recently(snap, home, entry):
    """True within the throttle of the last finished scan, or of a scan that was started: a scan that finds nothing
    updates no entry, and a run killed mid-scan none at all."""
    started = snap.get("scanning") if isinstance(snap.get("scanning"), dict) else {}
    t = now()
    for stamp in (entry.get("updated"), started.get(home)):
        when = parse_iso(stamp) if isinstance(stamp, str) else None
        if when and (t - when).total_seconds() < CODEX_REFRESH_SECONDS:
            return True
    return False


def refresh_codex(where=None, force=False, prof=None):
    """Update the cached Codex windows; one scan a minute per account (unless forced), by all sessions together, however
    the scan ends. The scan runs outside the lock. Returns the (possibly empty) entry. A busy lock raises StateError."""
    home = codex_home(where, prof)
    snap, entry = read_codex_cache(home)
    if not force and codex_scanned_recently(snap, home, entry):
        return entry
    if not (Path(home) / "sessions").is_dir():
        return entry                     # no rollouts at all: this check is the whole scan, nothing to throttle
    with state_lock(ORCH_HOME / ".state.lock"):
        snap, entry = read_codex_cache(home)
        if not force and codex_scanned_recently(snap, home, entry):
            return entry
        started = snap.get("scanning") if isinstance(snap.get("scanning"), dict) else {}
        started[home] = iso(now())
        snap["scanning"] = started
        write_json(CODEX_USAGE_FILE, snap)
    scanned = scan_codex_limits(home)
    if scanned is None:
        return entry
    measured, windows, plan_type, model = scanned
    with state_lock(ORCH_HOME / ".state.lock"):
        snap, entry = read_codex_cache(home)
        old_model = codex_work_model(entry.get("model"))      # an entry saved with the auto-review model: none
        old_week_history = entry.get("week_history")
        entry = codex_windows(measured, windows, plan_type)
        if model:
            entry["model"] = model
        elif old_model:
            entry["model"] = old_model       # a turn_context scrolled out of the tail: keep the last seen model
        entry["week_history"] = week_history_update(old_week_history, entry.get("seven_day"), measured)
        entry["updated"] = iso(now())
        snap[home] = entry
        t = now()      # drop accounts untouched for over a day (but keep the 💡 announcement state)
        announced = snap.get("announced")
        started = snap.get("scanning") if isinstance(snap.get("scanning"), dict) else {}
        started = {k: v for k, v in started.items() if k != home and isinstance(v, str) and parse_iso(v)
                   and (t - parse_iso(v)).total_seconds() < 86400}
        snap = {k: v for k, v in snap.items() if k != "scanning" and isinstance(v, dict) and (k == home or (
            parse_iso(v.get("updated") or "") and (t - parse_iso(v["updated"])).total_seconds() < 86400))}
        if isinstance(announced, dict):
            snap["announced"] = announced
        if started:
            snap["scanning"] = started
        write_json(CODEX_USAGE_FILE, snap)
    return entry


def codex_reserve(where=None):
    """reserve / week_reserve (%) from the codex profile, else 10/10; None when Codex is off for the project."""
    out = {"reserve": 10, "week_reserve": 10}
    try:
        prof = resolve_profile("codex", where or project_dir())
    except ProfileError as ex:
        if str(PROFILES_FILE) in str(ex):
            warn_state(PROFILES_FILE, str(ex))
        return out
    if prof.name == "off":
        return None
    if prof.explicit and prof.data.get("key"):
        return None          # API-billed: no subscription limits to show
    for k in out:
        v = str(prof.data.get(k, out[k])).lower()
        out[k] = 0 if v in ("off", "no", "false") else int(v) if v.isdigit() else out[k]
    return out


def codex_window(entry, name):
    """(used %, reset time, measured time) while the window is current; None once it has reset or has no data."""
    w = entry.get(name) if isinstance(entry.get(name), dict) else {}
    if w.get("used") is None:
        return None
    reset = parse_iso(w.get("resets_at") or "")
    if reset and reset <= now():
        return None
    return float(w["used"]), reset, parse_iso(w.get("measured") or "")


def codex_projected(used, reset, measured, window_minutes):
    """Projected used % at the reset, from the window average; None when it cannot be computed or when fewer
    than PROJECTION_MIN_ELAPSED minutes of the window have passed at the measurement (too early to tell)."""
    if reset is None or measured is None:
        return None
    elapsed = (measured - (reset - dt.timedelta(minutes=window_minutes))).total_seconds() / 60.0
    if elapsed < PROJECTION_MIN_ELAPSED:
        return None
    return used * window_minutes / elapsed


def codex_state(where=None):
    """(cfg, home, entry) of the Codex budget for a directory; (None, None, None) when Codex is off."""
    cfg = codex_reserve(where)
    if cfg is None:
        return None, None, None
    home = codex_home(where)
    snap = read_json(CODEX_USAGE_FILE, {}, recover_corrupt=True)
    entry = snap.get(home) if isinstance(snap, dict) else None
    if not isinstance(entry, dict):
        entry = None
    return cfg, home, entry


def codex_budget(where=None):
    """(mode, line) of the Codex subscription: TIGHT when a window's used share or its projection reaches its
    reserve (a weekly projection counts only after 24 h). No current data → no line and no mode."""
    try:
        refresh_codex(where)     # at most once a minute; routing must not depend on a status line being configured
    except Exception:
        pass
    cfg, _, entry = codex_state(where)
    if cfg is None or not entry:
        return "unknown", None
    five = codex_window(entry, "five_hour")
    week = codex_window(entry, "seven_day")
    if not five and not week:
        return "unknown", None
    parts = []
    tight = False
    measured = None
    if five:
        used, reset, m = five
        measured = m or measured
        cap = 100 - cfg["reserve"]
        proj = codex_projected(used, reset, m, 300)
        if used >= cap or (proj is not None and proj >= cap):
            tight = True
        parts.append("5-hour window %d%% used, resets %s" % (pct(used), reset.astimezone().strftime("%H:%M")))
    if week:
        used, reset, m = week
        measured = m or measured
        cap = 100 - week_reserve(cfg["week_reserve"], reset, m)
        rate, _ = week_rate(entry.get("week_history"), used, reset, m)
        weekly = max(used, projected_at_reset(used, reset, rate, m)) if rate is not None else used
        elapsed = (m - (reset - dt.timedelta(minutes=10080))).total_seconds() if m and reset else 0
        if used >= cap or (elapsed >= 86400 and weekly >= cap):
            tight = True
        parts.append("week %d%%" % pct(used) + (", resets %s" % reset.astimezone().strftime("%b %d %H:%M")
                                               if reset else ""))
    line = "Codex subscription: " + ", ".join(parts)
    if measured:
        line += " (measured %s)" % measured.astimezone().strftime("%H:%M")
    line += "."
    if tight:
        line += " TIGHT: treat Codex as low; offload to other providers."
    return ("tight" if tight else "normal"), line


def codex_short_mode(cfg, entry):
    """The compact Codex mode text: 'tight: week N% projected', 'tight: week over reserve', 'tight: 5h', or None.
    Mirrors codex_budget: a weekly cap is checked first, then the five-hour window."""
    five = codex_window(entry, "five_hour")
    week = codex_window(entry, "seven_day")
    if week:
        used, reset, m = week
        cap = 100 - week_reserve(cfg["week_reserve"], reset, m)
        if used >= cap:
            return "tight: week over reserve"
        rate, _ = week_rate(entry.get("week_history"), used, reset, m)
        weekly = max(used, projected_at_reset(used, reset, rate, m)) if rate is not None else used
        elapsed = (m - (reset - dt.timedelta(minutes=10080))).total_seconds() if m and reset else 0
        if elapsed >= 86400 and rate is not None and weekly >= cap:
            return "tight: week %d%% projected" % pct(weekly)
    if five:
        used, reset, m = five
        cap = 100 - cfg["reserve"]
        proj = codex_projected(used, reset, m, 300)
        if used >= cap or (proj is not None and proj >= cap):
            return "tight: 5h"
    return None


def codex_status_part(where=None):
    """Compact Codex limits part of the second status line ('GPT-6.1 Terra · 5h 81% → 18:28 · week 95%'),
    built by the same provider_line helper as Claude; or None with no data."""
    cfg, _, entry = codex_state(where)
    if cfg is None or not entry:
        return None
    five = codex_window(entry, "five_hour")
    week = codex_window(entry, "seven_day")
    measured = five[2] if five else (week[2] if week else None)
    m = codex_work_model(entry.get("model"))
    name = (display_name(m) if m else None) or m or "Codex"   # a known id → display name, an unknown id as-is, no model → Codex
    return provider_line(
        name,
        (five[0], five[1]) if five else None,
        (week[0], week[1]) if week else None,
        codex_short_mode(cfg, entry),
        measured,
    )


@locked("home")
def codex_event(session, announce=True):
    """A hook event when this session's Codex budget mode changes (tight / normal), once per change."""
    mode, line = codex_budget()
    if mode == "unknown":
        return None
    snap = read_json(CODEX_USAGE_FILE, {}, recover_corrupt=True)
    if not isinstance(snap, dict):
        snap = {}
    seen = snap.get("announced") if isinstance(snap.get("announced"), dict) else {}
    key = session or "-"
    if seen.get(key) == mode:
        return None
    seen.pop(key, None)
    seen[key] = mode
    snap["announced"] = dict(list(seen.items())[-30:])
    write_json(CODEX_USAGE_FILE, snap)
    return ("💡 " + line) if announce else None


# ───────────────────────── session tokens per provider (second status line) ─────────────────────────
#
# The second status line shows this session's cumulative input/output per provider, with cache reads beside them. The
# numbers must agree with `orch usage`: the orchestrator thread + subagents come from the transcript (each message
# counted once), the CLI executors from ~/.orchestra/usage.jsonl. Transcripts grow to many megabytes, so each file
# is parsed incrementally: ~/.orchestra/session_tokens/<session>.json holds the byte offset already parsed and the
# running totals; only appended bytes are read, a partial last line is left for the next call.
#
# The status line runs on every update and the next update may kill it, so a refresh rewrites only this session's small
# file, and at most once per SESSION_SAVE_SECONDS. In between it parses from the saved offset and shows the result
# without saving it: the parse is idempotent, the same bytes give the same totals on the next refresh.

SESSION_TOKENS_FILE = ORCH_HOME / "session_tokens.json"     # the old cache of all sessions: read only to migrate one
SESSION_TOKENS_DIR = ORCH_HOME / "session_tokens"
SESSION_SAVE_SECONDS = 30
SESSION_KEEP_SECONDS = 86400
SESSION_ID_RE = re.compile(r"[a-z0-9-]{8,100}")             # as a file name on any system; other ids are hashed
IDS_PER_FILE = 100             # a re-sent message is adjacent to its first copy (the lines of one streamed response)
IDS_IDLE_SECONDS = 600         # a file that has not grown for this long keeps no ids
PARSE_BYTES_PER_RUN = 8 * 1024 * 1024


def transcript_provider(model):
    m = str(model or "").lower()
    return "deepseek" if m.startswith("deepseek") else "claude"


def read_new_lines(path, offset, size, limit=None):
    """The complete lines of a file between byte `offset` and `size`, about `limit` bytes of them at most; b"" while
    there is only a partial last line. One line longer than the limit is read whole, or it could never be passed."""
    left = size - offset
    with Path(path).open("rb") as f:
        f.seek(offset)
        data = f.read(left if limit is None else min(left, limit))
        while b"\n" not in data and len(data) < left:
            more = f.read(min(left - len(data), max(len(data), 65536)))
            if not more:
                break
            data += more
    return data[:data.rfind(b"\n") + 1]


def trim_ids(state, keep):
    """Keep the newest `keep` ids of a file's state; `floor` remembers the newest of those dropped, as {t, id}.
    True when any was dropped."""
    ids = state.get("ids")
    if not isinstance(ids, dict) or len(ids) <= keep:
        return False
    names = list(ids)
    floor = state.get("floor") if isinstance(state.get("floor"), dict) else {}
    for mid in names[:len(names) - keep]:
        stamp = ids[mid].get("t") if isinstance(ids[mid], dict) else None
        if isinstance(stamp, str) and stamp >= str(floor.get("t") or ""):
            floor = {"t": stamp, "id": mid}
        del ids[mid]
    if floor:
        state["floor"] = floor
    return True


def parse_append(path, state, limit=None):
    """Count assistant usage appended to a transcript file; state: {offset, ids, floor, in, out, cache, provider}. At
    most about `limit` bytes are read. Returns (changed, behind): the state changed (bytes consumed, the file was reset
    after shrinking, ids dropped), and the limit left bytes unread.

    The lines of one message share an id and carry its usage so far: the last one replaces the earlier ones. Only the
    newest IDS_PER_FILE ids are kept, none once the file is idle, so an id seen again after being dropped cannot be
    told from a new message. Its timestamp can: a line older than the newest dropped id, or that message itself, is a
    copy of what was already counted, and is skipped. A copy with a new timestamp would count again; re-sends are
    adjacent in practice (CHANGELOG 0.18.1)."""
    path = Path(path)
    try:
        st = path.stat()
    except OSError:
        return False, False
    size = st.st_size
    offset = tok_int(state.get("offset"))
    changed = False
    if size < offset:                      # the file shrank: start over
        offset = 0
        state["offset"] = 0
        state["ids"] = {}
        state.pop("floor", None)
        state["in"] = 0
        state["out"] = 0
        state["cache"] = 0
        changed = True
    behind = limit is not None and size - offset > limit
    data = b""
    if size > offset:
        try:
            data = read_new_lines(path, offset, size, limit)
        except OSError:
            return changed, False
    if data:                               # else only a partial last line so far: leave it for the next call
        ids = state.get("ids")
        if not isinstance(ids, dict):
            ids = state["ids"] = {}
        floor = state.get("floor") if isinstance(state.get("floor"), dict) else {}
        floor_t = floor.get("t") if isinstance(floor.get("t"), str) else None
        for line in data.decode("utf-8", "replace").splitlines():
            if '"type":"assistant"' not in line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
            model = msg.get("model")
            if ev.get("type") != "assistant" or not model or str(model).startswith("<"):
                continue
            mid = msg.get("id") or ev.get("requestId") or ev.get("uuid")
            stamp = ev.get("timestamp") if isinstance(ev.get("timestamp"), str) else None
            u = claude_tokens(msg.get("usage") or {})
            inp, out, cache = int(u["input_tokens"]), int(u["output_tokens"]), int(u["cached_input_tokens"])
            if mid:
                old = ids.pop(mid, None)   # put back below as the newest
                if isinstance(old, dict):
                    inp -= tok_int(old.get("i"))
                    out -= tok_int(old.get("o"))
                    cache -= tok_int(old.get("c"))
                elif floor_t and stamp and (stamp < floor_t or (stamp == floor_t and mid == floor.get("id"))):
                    continue
                ids[mid] = {"i": u["input_tokens"], "o": u["output_tokens"], "c": u["cached_input_tokens"]}
                if stamp:
                    ids[mid]["t"] = stamp
            state["in"] = tok_int(state.get("in")) + inp
            state["out"] = tok_int(state.get("out")) + out
            state["cache"] = tok_int(state.get("cache")) + cache
            if not state.get("provider"):
                state["provider"] = transcript_provider(model)
        state["offset"] = offset + len(data)
        changed = True
    idle = not behind and time.time() - st.st_mtime >= IDS_IDLE_SECONDS
    if trim_ids(state, 0 if idle else IDS_PER_FILE):
        changed = True
    return changed, behind


def tok_int(v):
    """A token count from untrusted JSON: 0 for anything that is not a number."""
    try:
        return int(v or 0)
    except (TypeError, ValueError, OverflowError):
        return 0


def parse_ledger_append(offset, sid, limit=None):
    """(new_offset, {label: {input, output, cache}}, changed, behind) from run records of sid appended to the ledger;
    `behind`: the limit left bytes unread. The key is the record's profile label (deepseek@work, codex, …), the provider
    for a record without one: usage on different accounts stays apart."""
    out = {}
    try:
        size = USAGE_FILE.stat().st_size
    except OSError:
        return offset, out, False, False
    changed = False
    if size < offset:
        offset = 0
        changed = True
    if size <= offset:
        return offset, out, changed, False
    behind = limit is not None and size - offset > limit
    try:
        data = read_new_lines(USAGE_FILE, offset, size, limit)
    except OSError:
        return offset, out, changed, False
    if not data:
        return offset, out, changed, False
    plain_id = isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9_-]+", sid)    # stored as is: a quick test for most lines
    for line in data.decode("utf-8", "replace").splitlines():
        if plain_id and sid not in line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("kind") != "run" or rec.get("session") != sid:
            continue
        u = rec.get("usage")
        if not isinstance(u, dict):
            continue
        acct = str(rec.get("label") or rec.get("provider") or "?").lower()
        t = out.setdefault(acct, {"input": 0, "output": 0, "cache": 0})
        t["input"] += tok_int(u.get("input_tokens"))
        t["output"] += tok_int(u.get("output_tokens"))
        t["cache"] += tok_int(u.get("cached_input_tokens"))
    return offset + len(data), out, True, behind


# Version of the cached entry. 2 = keyed by the run record's profile label (an entry without it was keyed by provider);
# 3 = cache reads counted too, in the ledger and in each transcript file. An older entry's totals have no cache, so
# both its ledger part and its transcript files restart from offset 0.
SESSION_TOKENS_FORMAT = 3


def account_sort_key(label):
    """Provider, then the plain account first, then the labels alphabetically."""
    provider, _, name = str(label).partition("@")
    return (provider, bool(name), name)


def native_account(where):
    """The account this session's own thread (Claude) bills to: the label of a key profile (claude@work), else
    `claude` - the default login, the same account as `orch run claude` there. Any error or unknown directory: claude."""
    if not where:
        return "claude"
    try:
        prof = resolve_profile("claude", Path(where), follow=False)
        return prof.label if prof.explicit and prof.data.get("key") else "claude"
    except Exception:
        return "claude"


def session_tokens_path(sid):
    """This session's file. An id unfit for a file name (one from another tool, a device name, a case-only
    difference) is hashed."""
    if SESSION_ID_RE.fullmatch(sid):
        return SESSION_TOKENS_DIR / (sid + ".json")
    import hashlib
    return SESSION_TOKENS_DIR / ("x-" + hashlib.sha256(sid.encode("utf-8", "replace")).hexdigest() + ".json")


def read_session_entry(path):
    """A saved entry, or None when there is none. The data can be derived again, so damage means starting over."""
    try:
        entry = json.loads(_read_text_retry(path))
    except (OSError, ValueError):
        return None
    return entry if isinstance(entry, dict) else None


def session_entry_saved_recently(entry, t):
    updated = parse_iso(entry.get("updated")) if isinstance(entry.get("updated"), str) else None
    return updated is not None and 0 <= (t - updated).total_seconds() < SESSION_SAVE_SECONDS


def save_session_entry(sid, entry, t, always):
    """Save under the lock, unless another run of this session did so just now. A busy lock skips the save: the next
    refresh parses the same bytes from the same saved offset. An entry is a whole snapshot (offsets with their totals),
    so even a run overtaken by a newer save only makes the next refresh parse a little more."""
    path = session_tokens_path(sid)
    with state_lock(ORCH_HOME / ".state.lock"):
        if not always:
            saved = read_session_entry(path)
            if saved is not None and session_entry_saved_recently(saved, t):
                return
        write_json(path, dict(entry, updated=iso(t)), compact=True)


def session_tokens(sid, transcript_path, native="claude"):
    """Refresh this session's token counters and return {account: {input, output, cache}}: account is a profile label
    (deepseek@work, codex), so one provider's separate accounts stay separate. The session's own Claude thread counts
    under `native`. See above for when the counters are saved; a backlog over PARSE_BYTES_PER_RUN (a long transcript
    seen for the first time) is the exception, its progress is saved at once, so runs that get killed still get through it."""
    t = now()
    path = session_tokens_path(sid)
    entry = read_session_entry(path)
    first = entry is None
    if first:                               # a session running across the upgrade continues from its old entry
        try:
            old = read_json(SESSION_TOKENS_FILE, {}).get(sid)
        except StateError:
            old = None
        entry = old if isinstance(old, dict) else {}
    entry.setdefault("files", {})
    if not isinstance(entry["files"], dict):
        entry["files"] = {}
    if first:
        for state in entry["files"].values():
            if isinstance(state, dict):
                trim_ids(state, IDS_PER_FILE)
    changed = False
    if entry.get("format") != SESSION_TOKENS_FORMAT or not isinstance(entry.get("ledger"), dict) \
            or not isinstance(entry.get("ledger_offset"), int):
        changed = True                      # an old-format (or damaged) entry: rebuild ledger and transcripts
        entry["ledger"] = {}
        entry["ledger_offset"] = 0
        entry["files"] = {}                 # their saved totals carry no cache: parse the transcripts from 0 again
        entry["format"] = SESSION_TOKENS_FORMAT
    files = []
    if transcript_path and Path(transcript_path).is_file():
        files.append(Path(transcript_path))
    else:
        found = transcript_for(sid)
        if found:
            files.append(found)
    if files:
        sub = files[0].with_suffix("") / "subagents"
        if sub.is_dir():
            files += sorted(sub.glob("agent-*.jsonl"))
    left, behind = PARSE_BYTES_PER_RUN, False
    for f in files:
        if left <= 0:
            behind = True
            break
        state = entry["files"].get(str(f))
        if not isinstance(state, dict):
            state = entry["files"][str(f)] = {}
        start = tok_int(state.get("offset"))
        file_changed, file_behind = parse_append(f, state, left)
        changed = changed or file_changed
        behind = behind or file_behind
        left -= max(tok_int(state.get("offset")) - start, 0)
    offset, ledg, ledger_changed, ledger_behind = parse_ledger_append(entry["ledger_offset"], sid, PARSE_BYTES_PER_RUN)
    entry["ledger_offset"] = offset
    changed = changed or ledger_changed
    behind = behind or ledger_behind
    for acct, d in ledg.items():
        tt = entry["ledger"].get(acct)
        if not isinstance(tt, dict):
            tt = entry["ledger"][acct] = {"input": 0, "output": 0, "cache": 0}
        tt["input"] = tok_int(tt.get("input")) + d["input"]
        tt["output"] = tok_int(tt.get("output")) + d["output"]
        tt["cache"] = tok_int(tt.get("cache")) + d["cache"]
    if first or behind or (changed and not session_entry_saved_recently(entry, t)):
        try:
            save_session_entry(sid, entry, t, first or behind)
        except StateError:
            pass
    totals = {}

    def add(acct, inp, out, cache):
        tt = totals.setdefault(acct, {"input": 0, "output": 0, "cache": 0})
        tt["input"] += tok_int(inp)
        tt["output"] += tok_int(out)
        tt["cache"] += tok_int(cache)

    for f in entry["files"].values():
        if isinstance(f, dict):
            prov = f.get("provider") or "claude"
            add(native if prov == "claude" else prov, f.get("in"), f.get("out"), f.get("cache"))
    for acct, d in entry["ledger"].items():
        if isinstance(d, dict):
            add(acct, d.get("input"), d.get("output"), d.get("cache"))
    return totals


def sweep_orch_home():
    """Remove what no process will come back for, once it is over a day old: the *.tmp a killed write left, the file of
    a session gone quiet, the old cache of all sessions. Only a directory listing unless there is something to remove."""
    cutoff = time.time() - SESSION_KEEP_SECONDS
    for base in (ORCH_HOME, SESSION_TOKENS_DIR):
        try:
            with os.scandir(str(base)) as it:
                for e in it:
                    if e.name.endswith(".tmp") or e.name == SESSION_TOKENS_FILE.name \
                            or (base == SESSION_TOKENS_DIR and e.name.endswith(".json")):
                        if e.stat().st_mtime < cutoff:
                            os.unlink(e.path)
        except OSError:
            pass


def quietly(fn, *args):
    """A status line part: its failure (a busy lock above all) costs only that part, and only until the next update."""
    try:
        return fn(*args)
    except Exception:
        return None


def session_status_part(sid, transcript_path, where=None, spend=None):
    """'Session in/out: Claude 370k/111k +28M cache\n  DeepSeek@work 90k/9k (est. $0.99/$12, account $9.73)', or None
    with nothing to show. One counter per account (profile label), never a sum over a provider's accounts; cache reads
    follow the in/out pair as '+N cache', left out when there are none. One account per line: the first on the heading
    line, each further one indented by two spaces. `spend` is [(account label, display name, text)] from
    spend_status_items: each text joins the counter of the same account, in parentheses, matched on the lowercase label
    (the ledger's key), since two accounts can display alike; a scope with money but no tokens in this session follows
    the counters on a line of its own, and with no tokens at all the line is only those, with no 'Session in/out:'
    heading. Any error in the tokens costs only the tokens."""
    counters = []
    if sid:
        try:
            totals = session_tokens(sid, transcript_path, native_account(where))
            counters = [(str(acct).lower(), scope_name(acct),
                         "%s/%s%s" % (fmt_tok(d["input"]), fmt_tok(d["output"]),
                                      (" +%s cache" % fmt_tok(d["cache"])) if d.get("cache") else ""))
                        for acct, d in sorted(totals.items(), key=lambda kv: account_sort_key(kv[0]))
                        if d["input"] + d["output"] > 0]
        except Exception:
            counters = []
    extra = {label: text for label, _, text in spend or ()}
    parts = []
    for label, name, tokens in counters:
        text = extra.pop(label, None)
        parts.append("%s %s%s" % (name, tokens, " (%s)" % text if text else ""))
    loose = ["%s (%s)" % (name, text) for label, name, text in spend or () if label in extra]
    if not parts and not loose:
        return None
    return ("Session in/out: " if parts else "") + "\n  ".join(parts + loose)


def cmd_statusline(a):
    """Claude Code statusLine command: keep the subscription usage for routing; print a short status line.
    Never fails (a broken status line would be visible on every screen)."""
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""
    parts = []
    try:
        data = json.loads(raw or "{}")
        learn_session_id(data)
        rl = data.get("rate_limits") if isinstance(data.get("rate_limits"), dict) else {}
        windows = {}
        for name in ("five_hour", "seven_day"):
            w = rl.get(name)
            if isinstance(w, dict) and w.get("used_percentage") is not None and epoch_iso(w.get("resets_at")):
                windows[name] = {"used": round(float(w["used_percentage"]), 1), "resets_at": epoch_iso(w["resets_at"])}
        cwd = (data.get("workspace") or {}).get("current_dir") if isinstance(data.get("workspace"), dict) else None
        api_billed = bool(cwd) and profile_key("claude", Path(cwd), follow=False) is not None
        if windows and not api_billed:
            quietly(save_usage, windows, "statusline")
        model = (data.get("model") or {}).get("display_name") if isinstance(data.get("model"), dict) else None
        if data.get("session_id") and not api_billed:
            quietly(heartbeat, str(data["session_id"]), cwd)  # this session counts among the Claude consumers
        if not api_billed:
            snap = read_json(USAGE_SNAPSHOT, {}, recover_corrupt=True)
            five, week = usage_window(snap, "five_hour"), usage_window(snap, "seven_day")
            mode, budget_line = claude_budget(Path(cwd) if cwd else None)
            n = sum(1 for v in claude_consumers().values() if v.get("kind") != "executor")
            claude_line = provider_line(
                claude_status_name(model),
                (five[0], five[1]) if five and five[1] else None,
                (week[0], week[1]) if week else None,
                short_mode(mode, budget_line, Path(cwd) if cwd else None),
                measured_at(snap, "five_hour") if (five and five[1]) else None,
                sessions=n,
            )
            if claude_line:
                parts.append(claude_line)
        elif model:
            parts.append(claude_status_name(model))
    except Exception:
        pass
    line = " · ".join(parts) or "Orchestra"
    extra = []                 # one more line each: the Codex limits, this session's tokens
    try:
        data = json.loads(raw or "{}")
        cwd = (data.get("workspace") or {}).get("current_dir") if isinstance(data.get("workspace"), dict) else None
        sid = data.get("session_id")
        where = Path(cwd) if cwd else None
        quietly(refresh_codex, where)
        spend = (quietly(spend_status_items, where) or []) if where else []   # always shown, beside the tokens
        session_line = session_status_part(str(sid) if sid else None, data.get("transcript_path"), where, spend)
        extra = [p for p in (quietly(codex_status_part, where), session_line) if p]
        quietly(sweep_orch_home)
    except Exception:
        extra = []
    if a.then:
        try:
            import subprocess         # the operator's own command is the one process a status line may start
            r = subprocess.run(a.then, shell=True, input=raw.encode("utf-8"), stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=5)
            theirs = r.stdout.decode("utf-8", "replace").replace("\r\n", "\n").rstrip("\n")   # cmd.exe: CRLF
            line = (theirs + "  " + line) if theirs and "\n" not in theirs else (theirs + "\n" + line if theirs else line)
        except Exception:
            pass
    print(line)
    for part in extra:
        print(part)
    return 0


# ───────────────────────── profiles (keys/accounts, models, rules; default and per project) ─────────────────────────
#
# ~/.orchestra/profiles.json:
#   {"providers": {"deepseek": {"default": "personal",
#                               "profiles": {"personal": {"key": "DEEPSEEK_API_KEY"},
#                                            "work": {"key": "DEEPSEEK_API_KEY_WORK", "models": ["deepseek-flash"]}}}},
#    "projects": {"c:/users/me/work": {"deepseek": "work", "antigravity": "off"}}}
# A provider without profiles has the built-in profile "default" (no limits). "off" disables the provider.
# A directory binding covers its subdirectories; the longest matching directory wins, per provider.

PROFILES_FILE = ORCH_HOME / "profiles.json"
EFFORT_ORDER = ("none", "minimal", "low", "medium", "high", "xhigh", "max")
LIST_FIELDS = ("models", "use_for", "prefer_for")
RULE_FIELDS = ("models", "max_effort", "write", "use_for", "prefer_for", "rules", "fallback") + SESSION_BUDGET_FIELDS
MANUAL_PROVIDERS = ("antigravity",)
PROFILE_NAME_RE = re.compile(r"[a-z0-9][a-z0-9_.-]{0,39}")
VAR_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class ProfileError(Exception):
    pass


class Profile(object):
    def __init__(self, provider, name, data, source, explicit, fallback_from=None, fallback_cause=None):
        self.provider, self.name, self.data, self.source, self.explicit = provider, name, data, source, explicit
        # set when resolution moved off the configured profile `fallback_from` because it is exhausted
        # (cause: "limit" | "exhausted" | "disabled"); `name` is then the fallback profile
        self.fallback_from, self.fallback_cause = fallback_from, fallback_cause

    @property
    def label(self):
        """quota/availability key: deepseek@work, or just the provider for the built-in profile."""
        return self.provider + ("@" + self.name if self.explicit and self.name != "off" else "")


def load_profiles():
    """(data, error). A broken file is an error, never "no profiles": an "off" must not silently turn into "on"."""
    empty = {"providers": {}, "projects": {}, "project_rules": {}}
    try:
        data = json.loads(_read_text_retry(PROFILES_FILE, encoding="utf-8-sig"))
    except FileNotFoundError:
        return empty, None
    except (OSError, ValueError) as ex:
        return empty, "%s is unreadable: %s" % (PROFILES_FILE, ex)
    if not isinstance(data, dict) or not isinstance(data.get("providers", {}), dict) \
            or not isinstance(data.get("projects", {}), dict) \
            or not isinstance(data.get("project_rules", {}), dict):
        return empty, "%s: expected an object with providers, projects and project_rules fields" % PROFILES_FILE
    data.setdefault("providers", {})
    data.setdefault("projects", {})
    data.setdefault("project_rules", {})
    return data, None


def profile_key_vars():
    """Every variable named as some profile's `key` in profiles.json — names the operator may have exported in
    their shell that must not leak into a worker. A broken file → {} (the run is refused earlier anyway)."""
    data, err = load_profiles()
    if err:
        return set()
    out = set()
    for sec in (data.get("providers") or {}).values():
        profs = sec.get("profiles") if isinstance(sec, dict) else None
        for prof in (profs.values() if isinstance(profs, dict) else []):
            if isinstance(prof, dict) and prof.get("key"):
                out.add(prof["key"])
    return out


def save_profiles(data):
    data["_readme"] = ("Orchestra executor profiles: orch profile list|show|use|set|rm. "
                       "API keys live only in secrets.env; this file holds variable names.")
    data.setdefault("version", 1)
    write_json(PROFILES_FILE, data)


def canon_path(p):
    """Directory key in profiles.json, identical in Windows and WSL: C:\\Users\\Me\\x and /mnt/c/Users/Me/x → c:/users/me/x."""
    s = str(p).replace("\\", "/")
    m = re.match(r"/mnt/([A-Za-z])(?=/|$)", s)
    if m:
        s = m.group(1) + ":" + (s[m.end():] or "/")
    if re.match(r"[A-Za-z]:", s):
        s = s.lower()
    if len(s) > 1 and not re.fullmatch(r"[a-z]:/", s):
        s = s.rstrip("/")
    return s


_ROOTS = {}


def project_root(path):
    """Main working tree of the repository that contains path (a worktree maps to its project), else path itself."""
    path = Path(path)
    if path not in _ROOTS or not path.is_absolute():
        _ROOTS[path] = _project_root(path.resolve())
    return _ROOTS[path]


def _project_root(path):
    if path.is_dir():
        top, common = git_walk(path)
        if common is not None:
            return common.parent if common.name == ".git" else top
    return path


def local_path(v):
    """~ → home; C:\\… → /mnt/c/… under WSL (a shared ORCH_HOME may hold Windows paths)."""
    if v.startswith("~"):
        return str(Path(os.path.expanduser(v)))
    m = re.match(r"([A-Za-z]):[\\/]", v)
    if m and not IS_WINDOWS and Path("/mnt", m.group(1).lower()).is_dir():
        return "/mnt/%s/%s" % (m.group(1).lower(), v[3:].replace("\\", "/"))
    return v


def provider_section(data, provider):
    sec = data["providers"].get(provider)
    sec = sec if isinstance(sec, dict) else {}
    profs = sec.get("profiles")
    return sec, (profs if isinstance(profs, dict) else {})


def ensure_section(data, provider):
    sec = data["providers"].get(provider)
    if not isinstance(sec, dict):
        sec = data["providers"][provider] = {}
    if not isinstance(sec.get("profiles"), dict):
        sec["profiles"] = {}
    return sec


def binding_for(data, provider, where):
    """(profile name, source) from the longest bound directory containing `where`, or (None, None)."""
    root = canon_path(where)
    best, found = -1, (None, None)
    for k, binding in data["projects"].items():
        ck = canon_path(k)
        inside = root == ck or root.startswith(ck if ck.endswith("/") else ck + "/")
        if inside and isinstance(binding, dict) and binding.get(provider) and len(ck) > best:
            best = len(ck)
            found = (str(binding[provider]).lower(), "project" if root == ck else "directory " + ck)
    return found


def project_rules_for(data, where):
    """All nonempty directory rules containing the project, outermost first."""
    root = canon_path(project_root(where))
    matches = []
    for directory, value in data["project_rules"].items():
        ck = canon_path(directory)
        if value and (root == ck or root.startswith(ck if ck.endswith("/") else ck + "/")):
            matches.append((ck, value))
    return sorted(matches, key=lambda pair: (len(pair[0]), pair[0]))


def session_profiles(text=None):
    """ORCH_PROFILES="claude=off,codex=alt" → {provider: profile}: session-wide choices (orch launch --no-claude,
    --use); a later entry wins."""
    out = {}
    for pair in (os.environ.get("ORCH_PROFILES", "") if text is None else text).split(","):
        provider, _, name = pair.strip().partition("=")
        if provider.strip() and name.strip():
            out[provider.strip().lower()] = name.strip().lower()
    return out


def resolve_profile(provider, where, override=None, data=None, choices=None, follow=True):
    """Active profile of a provider for a directory: --profile → session choice (ORCH_PROFILES) → directory binding→
    provider default → built-in. A selected profile with a `fallback` that is exhausted resolves to the fallback
    (every consumer sees it at once); an explicit `override` (--profile) is the operator's direct request and never
    follows it. follow=False is for a Claude session's own thread: its apiKeyHelper names the bound profile
    (`orch key claude@work`), so that thread keeps billing there whatever a run would resolve to."""
    provider = provider.lower()
    if data is None:
        data, err = load_profiles()
        if err:
            raise ProfileError(err)
    sec, profs = provider_section(data, provider)
    session = session_profiles() if choices is None else choices
    if override:
        name, source = override.lower(), "--profile flag"
    elif provider in session:
        name, source = session[provider], "session"
    else:
        name, source = binding_for(data, provider, project_root(where))
        if name is None:
            name, source = (str(sec["default"]).lower(), "default") if sec.get("default") else ("default", "built-in")
    if name == "off":
        return Profile(provider, "off", {}, source, True)
    if name in profs:
        d = profs[name]
        prof = Profile(provider, name, d if isinstance(d, dict) else {}, source, True)
        return prof if override or not follow else follow_fallback(prof, profs, where)
    if name == "default":      # built-in: the usual environment (~/.codex, DEEPSEEK_API_KEY), no limits
        return Profile(provider, "default", {}, source, False)
    raise ProfileError("profile %s@%s not found (%s); available: %s" % (provider, name, source,
                                                                          ", ".join(profile_names(profs))))


_resolving = set()      # profiles whose exhaustion is being checked now: the check may itself resolve a profile


def fallback_target(prof, profs):
    """The profile `prof` falls back to (one level: its own `fallback` is not followed), or None when it has none,
    points at itself, or at a profile that no longer exists."""
    target = prof.data.get("fallback")
    target = str(target).strip().lower() if target else ""
    if not target or target == prof.name or target == "off":
        return None
    if target in profs:
        d = profs[target]
        return Profile(prof.provider, target, d if isinstance(d, dict) else {}, prof.source, True)
    if target == "default":                       # the built-in profile: the usual environment, no limits
        return Profile(prof.provider, "default", {}, prof.source, False)
    return None


def follow_fallback(prof, profs, where):
    """`prof`, or its fallback profile while `prof` is exhausted. A profile without `fallback` costs one lookup."""
    if not prof.data.get("fallback"):
        return prof
    target = fallback_target(prof, profs)
    guard = (prof.provider, prof.name)
    if target is None or guard in _resolving:
        return prof
    _resolving.add(guard)
    try:
        cause = profile_exhaustion(prof, where)
    except Exception:                             # an unreadable state is not exhaustion: resolve as usual
        cause = None
    finally:
        _resolving.discard(guard)
    if cause is None:
        return prof
    target.fallback_from, target.fallback_cause = prof.name, cause
    return target


EXHAUSTION_MEMO_SECONDS = 5
_exhaustion_memo = {}   # a hook or status line resolves a profile many times over: (label, where) → (time, cause)


def profile_exhaustion(prof, where):
    """Why a profile counts as exhausted → "limit" (its spend scope is at its limit under stop/evaluate), "exhausted"
    or "disabled" (an availability entry on the profile's own key, deepseek@work), else None. `low`, an entry on the
    whole provider, a `continue` mode and an unreadable limits file are not exhaustion."""
    key = (prof.label, str(where))
    hit = _exhaustion_memo.get(key)
    if hit and 0 <= time.time() - hit[0] < EXHAUSTION_MEMO_SECONDS:
        return hit[1]
    cause = _profile_exhaustion(prof, where)
    _exhaustion_memo[key] = (time.time(), cause)
    return cause


def _profile_exhaustion(prof, where):
    entry = load_avail()["entries"].get(prof.label)
    # A timed entry that orch recorded itself is a rate limit, gone in minutes; a balance that ran out has no timed
    # reset. A rate limit is no reason to start spending another key.
    if isinstance(entry, dict) and entry.get("status") in ("exhausted", "disabled") and not (
            entry.get("source") == "auto" and entry.get("until")):
        return entry["status"]
    scope = profile_api_scope(prof, prof.provider, where)
    if not scope:
        return None
    config, err = load_spend_limits()
    if err:
        return None
    eff = resolve_spend(config, scope, where)
    limit = _limit_number(eff)
    if limit is not None and eff.get("mode") in ("stop", "evaluate") and current_spend(scope, where) >= limit:
        return "limit"
    return session_budget_cause(prof, where)


def fallback_cause_words(cause):
    """'at its limit' | 'exhausted' | 'disabled'."""
    return {"limit": "at its limit", "floor": "at its balance floor",
            "session-hard": "at its hard session budget", "session-soft": "over its session budget"}.get(cause, str(cause))


def fallback_cause_text(name, cause):
    """'client is at its limit' — for a person; `name` is the configured (exhausted) profile."""
    return "%s is %s" % (name, fallback_cause_words(cause))


def profile_names(profs):
    return list(profs) + ([] if "default" in profs else ["default"])


def model_allowed(model, models):
    allowed = [str(m).lower() for m in models]
    return model.lower() in allowed or re.sub(r"\[[^\]]*\]$", "", model).lower() in allowed   # deepseek-flash[1m]


def profile_limits(prof, model, effort, mode):
    """Hard limits of a profile for `orch run` → (model, effort, notes, denial or None)."""
    d, notes = prof.data, []
    models = d.get("models") or []
    if models:
        if not model:
            model = str(models[0])
            notes.append("model from the profile: %s" % model)
        elif not model_allowed(model, models):
            return model, effort, notes, "model %s not allowed (allowed: %s)" % (model, ", ".join(map(str, models)))
    if mode == "write" and d.get("write") is False:
        return model, effort, notes, "write mode denied — analysis only"
    cap = str(d.get("max_effort") or "").lower()
    if cap and effort:
        e = effort.lower()
        if e not in EFFORT_ORDER or cap not in EFFORT_ORDER:
            return model, effort, notes, "effort %s is off the scale %s; the profile caps it at %s" % (
                effort, "|".join(EFFORT_ORDER), cap)
        if EFFORT_ORDER.index(e) > EFFORT_ORDER.index(cap):
            notes.append("effort %s → %s" % (effort, cap))
            effort = cap
    return model, effort, notes, None


def secret_source(var):
    if os.environ.get(var):
        return "environment"
    return str(SECRETS_FILE) if load_secrets().get(var) else None


def profile_secret(prof, names):
    """Profile field `key` names the variable (environment or secrets.env) whose value the adapter receives
    as its first declared secret → (env, secrets still to load the usual way)."""
    var = prof.data.get("key") if prof.explicit else None
    if not var or not names:
        return {}, names
    val = os.environ.get(var) or load_secrets().get(var)
    if not val:
        raise ProfileError("profile %s: key %s is neither in the environment nor in %s (line %s=…)" % (
            prof.label, var, SECRETS_FILE, var))
    return {names[0]: val}, names[1:]


def profile_key(provider, where=None, follow=True):
    """Variable name of the active profile's API key, or None when the provider runs on its login (not API-billed)."""
    try:
        prof = resolve_profile(provider, where or project_dir(), follow=follow)
    except ProfileError:
        return None
    return prof.data.get("key") if prof.explicit else None


def fallback_secret_names(directives, remaining):
    """Of the declared secrets still to load, those a login/default profile may fill from secrets.env. A name marked
    `# orch-secrets-explicit:` is supplied only by an explicit profile `key`, never from secrets.env — so a stray
    `CODEX_API_KEY=` line cannot silently switch a login profile to API billing."""
    explicit = set(directives.get("secrets-explicit", "").split())
    return [n for n in remaining if n not in explicit]


def profile_env_map(directives):
    """'# orch-profile-env: home=CODEX_HOME codex_profile=ORCH_CODEX_PROFILE' → {field: VAR}."""
    out = {}
    for pair in directives.get("profile-env", "").split():
        field, _, var = pair.partition("=")
        if field and VAR_RE.fullmatch(var):
            out[field] = var
    return out


def profile_env(prof, directives):
    return {var: local_path(str(prof.data[f])) for f, var in profile_env_map(directives).items()
            if prof.data.get(f) not in (None, "")}


def managed_providers(data):
    names = []
    for b in (ORCH_HOME / "adapters", PLUGIN_ROOT / "adapters"):
        if b.is_dir():
            names += sorted(p.name for p in b.iterdir() if p.is_file() and not p.name.startswith(("_", ".")))
    names += list(MANUAL_PROVIDERS) + list(data["providers"])
    return list(dict.fromkeys(n.lower() for n in names))


def profile_fields(provider):
    """Fields a profile of this provider may have: rules for the orchestrator + what its adapter takes."""
    adapter = find_adapter(provider)
    if adapter is None:                      # manual lane: models = model keys (gemini-4-argon, …)
        return ["models", "use_for", "prefer_for", "rules", "max_open", "fallback"]
    directives = adapter_directives(adapter_head(adapter))
    if provider.lower() == "claude":
        extra = list(BUDGET_DEFAULTS)             # budget mode: surplus, reserve, week_reserve
    elif provider.lower() == "codex":
        extra = ["reserve", "week_reserve"]       # Codex budget mode: reserve thresholds only, no surplus
    else:
        extra = []
    return (["key"] if directives.get("secrets") else []) + list(RULE_FIELDS) + list(profile_env_map(directives)) + extra


def describe_profile(prof, profs=None):
    """One line for a person. `profs` (the provider's profiles) lets it say that a configured fallback is missing."""
    if prof.name == "off":
        return "OFF (%s) — %s" % (prof.source, "do not create manual tasks" if find_adapter(prof.provider) is None
                                  else "do not use")
    d = prof.data
    if prof.fallback_from:
        parts = ["%s (fallback: %s)" % (prof.name, fallback_cause_text(prof.fallback_from, prof.fallback_cause))]
    else:
        parts = ["%s (%s)" % (prof.name, prof.source)]
    if d.get("key"):
        parts.append("key %s %s" % (d["key"], "✔" if secret_source(d["key"]) else "✘ not in secrets.env"))
    for f in sorted(set(d) - set(RULE_FIELDS) - {"key", "max_open"}):
        parts.append("%s %s" % (f, d[f]))
    if d.get("models"):
        parts.append("models: " + ", ".join(map(str, d["models"])))
    if d.get("max_effort"):
        parts.append("effort ≤ " + str(d["max_effort"]))
    if d.get("write") is False:
        parts.append("analysis only")
    if d.get("use_for"):
        parts.append("only for: " + ", ".join(map(str, d["use_for"])))
    if d.get("prefer_for"):
        parts.append("prefer for: " + ", ".join(map(str, d["prefer_for"])))
    if d.get("max_open") not in (None, ""):
        parts.append("manual tasks ≤ %s" % d["max_open"])
    if has_session_budget(prof):
        known = balance_known(balance_cache().get(prof.label))
        parts.append("session budget: " + session_budget_settings(prof, known[1] if known else "USD"))
    if d.get("fallback") and not prof.fallback_from:       # a profile used as a fallback does not chain further
        part = "fallback: %s" % d["fallback"]
        if profs is not None and fallback_target(prof, profs) is None:
            part += " (no such profile: ignored)"
        parts.append(part)
    if len(parts) == 1:
        parts.append("no limits")
    return " · ".join(parts)


def profile_lines(where, data=None, budget=True):
    """Effective profile of every provider for a directory (orch status, profile show). `orch status` passes
    budget=False: its API keys lines already carry the session budget."""
    if data is None:
        data, err = load_profiles()
        if err:
            warn_state(PROFILES_FILE, err)
            return ["⚠ " + err + " — CLI executors and manual tasks will not start until the file is fixed"]
    root = canon_path(project_root(where))
    lines = ["  Project rules%s: %s" % ("" if directory == root else " (%s)" % directory, value)
             for directory, value in project_rules_for(data, where)]
    for provider in managed_providers(data):
        try:
            prof = resolve_profile(provider, where, data=data)
        except ProfileError as ex:
            lines.append("  %-12s ⚠ %s" % (display_name(provider), ex))
            continue
        lines.append("  %-12s %s" % (display_name(provider),
                                      describe_profile(prof, provider_section(data, provider)[1])))
        budget_prof = resolve_profile(provider, where, data=data, follow=False) if budget else None
        if budget_prof and has_session_budget(budget_prof):
            lines.append("  %-12s session: %s" % ("", session_budget_text(budget_prof)))
        configured = provider_section(data, provider)[1].get(prof.fallback_from) if prof.fallback_from else None
        if isinstance(configured, dict) and configured.get("rules"):
            lines.append("  %-12s rules of %s are not in force while it is exhausted" % ("", prof.fallback_from))
        if prof.data.get("rules"):
            lines.append("  %-12s rules: %s" % ("", prof.data["rules"]))
    return lines


def parse_profile_value(field, raw):
    """CLI text → stored value; '' removes the field."""
    raw = raw.strip()
    if raw == "":
        return None
    if field in SESSION_BUDGET_FIELDS:
        import math
        try:
            value = float(raw)
            if not math.isfinite(value) or (value < 0 if field == "balance_floor" else not 0 < value <= 100):
                raise ValueError
            return value
        except ValueError:
            raise SystemExit("orch: --%s must be %s" % (field.replace("_", "-"),
                             "a nonnegative amount" if field == "balance_floor" else "a percentage above 0 and up to 100"))
    if field in LIST_FIELDS:
        return [x.strip() for x in raw.split(",") if x.strip()]
    if field == "write":
        v = raw.lower()
        if v not in ("yes", "no", "true", "false", "1", "0"):
            raise SystemExit("orch: --write yes|no")
        return v in ("yes", "true", "1")
    if field == "max_effort":
        if raw.lower() not in EFFORT_ORDER:
            raise SystemExit("orch: --max-effort must be one of %s" % "|".join(EFFORT_ORDER))
        return raw.lower()
    if field == "fallback":
        return None if raw.lower() == "none" else raw.lower()      # existence is checked by `set`
    if field == "max_open":
        if not raw.isdigit():
            raise SystemExit("orch: --max-open must be an integer ≥ 0")
        return int(raw)
    if field == "surplus":
        if raw.lower() == "off":
            return "off"
        if not raw.isdigit() or not 1 <= int(raw) <= 100:
            raise SystemExit("orch: surplus=N (projected unused percent of the 5-hour window, 1–100) or surplus=off")
        return int(raw)
    if field in ("reserve", "week_reserve"):
        if not raw.isdigit() or not 0 <= int(raw) <= 90:
            raise SystemExit("orch: %s=N — percent kept for other sessions and safety, 0–90" % field)
        return int(raw)
    if field == "key" and not VAR_RE.fullmatch(raw):
        raise SystemExit("orch: --key takes a variable name (e.g. DEEPSEEK_API_KEY_WORK), not the key itself: "
                         "put the key as a NAME=sk-… line in %s" % SECRETS_FILE)
    return raw


def check_fallback(provider, name, target, profs):
    """Validate `set --fallback`: another profile of the same provider (or the built-in default). → notes to print."""
    if target == name:
        raise SystemExit("orch: a profile cannot be its own fallback")
    names = profile_names(profs)
    if target not in names:
        raise SystemExit("orch: no profile %s@%s to fall back to (available: %s)" % (
            provider, target, ", ".join(n for n in names if n != name)))
    d = profs.get(target)
    if isinstance(d, dict) and d.get("fallback"):
        return ["note: %s@%s has a fallback of its own; only one level is followed, so it is ignored here"
                % (provider, target)]
    return []


def login_hint(home):
    hint = "CODEX_HOME='%s' codex login" % home
    if IS_WINDOWS:
        hint += "   (PowerShell: $env:CODEX_HOME='%s'; codex login)" % home
    return hint


# ───────────────────────── Claude apiKeyHelper (the session itself on an API key) ─────────────────────────
#
# The session's own credential comes from Claude Code's `apiKeyHelper` setting (it ranks above the /login
# subscription, below ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN). `orch profile use claude <profile>` with a key
# profile writes it into the project's .claude/settings.local.json (or, with --default, the user settings), so the
# session and its subagents bill to that key. The helper runs `orch key claude@<profile>` — a hidden command that
# prints only the key; it refuses inside a worker or a non-Claude lead.

def claude_config_dir():
    """CLAUDE_CONFIG_DIR or the default ~/.claude (the user settings for `--default`)."""
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def settings_target(default=False, where=None):
    """The settings file apiKeyHelper is written to: user settings (--default) or the project's settings.local.json."""
    if default:
        return claude_config_dir() / "settings.json"
    return project_root(Path(where) if where else project_dir()) / ".claude" / "settings.local.json"


def key_helper_command(profile):
    """The apiKeyHelper shell command: `<python> <orch> key claude@<profile>`, shell-quoted for the host OS."""
    import shlex
    import subprocess
    parts = [sys.executable, str(Path(__file__).resolve()), "key", "claude@" + profile]
    if IS_WINDOWS:
        return subprocess.list2cmdline(parts)
    return " ".join(shlex.quote(p) for p in parts)


def is_own_helper(value):
    """True when apiKeyHelper is the command orch wrote (`… <orch> key claude[@profile]`), not the operator's own."""
    if not isinstance(value, str):
        return False
    return str(Path(__file__).resolve()) in value and re.search(r"\bkey\s+claude(@[A-Za-z0-9_.-]+)?\b", value)


def read_settings(path):
    """(data, err) of a Claude Code settings JSON file; a broken file is an error, never "empty"."""
    path = Path(path)
    if not path.exists():
        return {}, None
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as ex:
        return None, "%s is not valid JSON: %s" % (path, ex)
    if not isinstance(data, dict):
        return None, "%s: expected a JSON object" % path
    return data, None


def manage_claude_helper(name, data, default, path):
    """After `orch profile use claude <name>`, put the session itself on the profile's key (apiKeyHelper), or remove
    the helper orch wrote when switching to a login profile / inherit / off. `--path` cannot reach child projects."""
    if path:
        print("note: --path covers `orch run claude` only; native Claude Code sessions need "
              "`orch profile use claude <profile>` in each project")
        return
    target = settings_target(default=bool(default))
    if name in ("off", "inherit"):
        _remove_helper(target)
        return
    _, profs = provider_section(data, "claude")
    d = profs.get(name) if name in profs else None
    key_var = d.get("key") if isinstance(d, dict) else None
    if not key_var:
        _remove_helper(target)
        return
    with state_lock(ORCH_HOME / ".settings.lock"):
        settings, err = read_settings(target)
        if err is not None:
            print("orch: " + err, file=sys.stderr)
            return
        settings["apiKeyHelper"] = key_helper_command(name)
        try:
            write_json(target, settings)
        except StateError as ex:
            print("orch: " + str(ex), file=sys.stderr)
            return
    if default:
        print("Every Claude Code session on this account now bills to the key of %s (apiKeyHelper in %s)."
              % (name, target))
    else:
        ensure_git_exclude(project_root(project_dir()), (".claude/settings.local.json",))
    print("A running session picks this up after a restart; /status shows the active credential.")


def _remove_helper(target):
    """Drop apiKeyHelper from a settings file only when orch wrote it; leave the operator's own helper and say so."""
    with state_lock(ORCH_HOME / ".settings.lock"):
        settings, err = read_settings(target)
        if err is not None:
            print("orch: " + err, file=sys.stderr)
            return
        cur = settings.get("apiKeyHelper")
        if cur is None:
            return
        if not is_own_helper(cur):
            print("Left apiKeyHelper in %s as it is (not written by orch)." % target)
            return
        del settings["apiKeyHelper"]
        try:
            write_json(target, settings)
        except StateError as ex:
            print("orch: " + str(ex), file=sys.stderr)


def cmd_key(a):
    """orch key claude[@profile]: print the key of a claude profile (internal — the apiKeyHelper runs this)."""
    if os.environ.get("ORCH_WORKER"):
        raise SystemExit("orch: an executor (ORCH_WORKER) may not read the Claude API key")
    if os.environ.get("ORCH_LEAD"):
        raise SystemExit("orch: a non-Claude lead may not read the Claude API key")
    provider, _, name = a.profile.lower().partition("@")
    if provider != "claude":
        raise SystemExit("orch: `orch key` serves claude only")
    try:
        prof = resolve_profile("claude", project_dir(), override=name or None)
    except ProfileError as ex:
        print("orch: %s" % ex, file=sys.stderr)
        return 1
    var = prof.data.get("key") if prof.explicit else None
    if not var:
        print("orch: no API key on the active claude profile", file=sys.stderr)
        return 1
    scope = profile_api_scope(prof, "claude", project_dir())
    if scope:
        allowed, line = spend_lead_key(scope, project_dir())
        if not allowed:
            print("orch: " + line, file=sys.stderr)      # the session's requests fail past the threshold
            return 1
    val = os.environ.get(var) or load_secrets().get(var)
    if not val:
        print("orch: key %s is neither in the environment nor in %s" % (var, SECRETS_FILE), file=sys.stderr)
        return 1
    print(val)
    return 0


@locked("home")
def cmd_profile(a):
    data, err = load_profiles()
    if err and a.action != "show":
        raise SystemExit("orch: " + err)
    if a.action in ("show", "list") and getattr(a, "json", False):
        if err:
            print(json.dumps({"error": err}, ensure_ascii=False))
            return 1
        if a.action == "list":
            print(json.dumps(data, ensure_ascii=False, indent=2))
            return 0
        where = Path(a.path).resolve() if a.path else project_dir()
        out = {}
        for provider in managed_providers(data):
            try:
                p = resolve_profile(provider, where, data=data)
                out[provider] = {"profile": p.name, "source": p.source, "label": p.label, "settings": p.data}
                configured = resolve_profile(provider, where, data=data, follow=False)
                if has_session_budget(configured):
                    out[provider]["session_budget"] = dict(session_budget_figure(configured) or {},
                                                         text=session_budget_text(configured),
                                                         settings={f: configured.data[f] for f in SESSION_BUDGET_FIELDS
                                                                   if f in configured.data})
                if p.fallback_from:
                    out[provider].update({"fallback_from": p.fallback_from, "fallback_cause": p.fallback_cause})
            except ProfileError as ex:
                out[provider] = {"error": str(ex)}
        rules = [{"directory": directory, "text": value} for directory, value in project_rules_for(data, where)]
        print(json.dumps({"project": canon_path(project_root(where)), "providers": out, "rules": rules}, ensure_ascii=False, indent=2))
        return 0
    if a.action == "show":
        where = Path(a.path).resolve() if a.path else project_dir()
        print("Executor profiles for %s:" % canon_path(project_root(where)))
        print("\n".join(profile_lines(where, None if err else data)))
        print("File: %s%s · switch: orch profile use <provider> <profile|off|inherit> [--default]"
              % (PROFILES_FILE, "" if PROFILES_FILE.exists() else " (not created yet)"))
        return 0
    if a.action == "list":
        for provider in managed_providers(data):
            if a.provider and provider != a.provider.lower():
                continue
            sec, profs = provider_section(data, provider)
            default = sec.get("default") or "default"
            print("%s (default: %s)" % (provider, default))
            for name in profile_names(profs):
                d = profs.get(name)
                print("  %s" % describe_profile(Profile(
                    provider, name, d if isinstance(d, dict) else {},
                    ("default" if name == default else "profile") if name in profs else
                    "built-in%s" % (", default" if name == default else ""), name in profs), profs))
            for k, binding in sorted(data["projects"].items()):
                if isinstance(binding, dict) and binding.get(provider):
                    print("  ↳ %s → %s" % (k, binding[provider]))
        if data["project_rules"]:
            print("Project rules:")
            for directory, value in sorted(data["project_rules"].items()):
                print("  %s: %s" % (directory, value))
        return 0

    if a.action == "rules":
        where = Path(a.path).resolve() if a.path else project_root(project_dir())
        if a.set is None and not a.clear:
            rules = project_rules_for(data, where)
            if rules:
                root = canon_path(project_root(where))
                for directory, value in rules:
                    print("  Project rules%s: %s" % ("" if directory == root else " (%s)" % directory, value))
            else:
                print("No project rules apply here; add one with orch profile rules --set TEXT.")
            return 0
        key = canon_path(where)
        if a.clear or not a.set.strip():
            if key in data["project_rules"]:
                del data["project_rules"][key]
                save_profiles(data)
                print("Cleared project rules for %s." % key)
            else:
                print("No project rules to clear for %s." % key)
        else:
            data["project_rules"][key] = a.set.strip()
            save_profiles(data)
            print("Saved project rules for %s." % key)
        return 0

    provider = a.provider.lower()
    if provider not in managed_providers(data):
        raise SystemExit("orch: unknown provider %r (available: %s)" % (provider, ", ".join(managed_providers(data))))
    sec, profs = provider_section(data, provider)
    name = a.name.lower()

    if a.action == "use":
        if name not in ("off", "inherit") and name not in profile_names(profs):
            raise SystemExit("orch: no profile %s@%s (available: %s). Create it: orch profile set %s %s …" % (
                provider, name, ", ".join(profile_names(profs)), provider, name))
        if a.default:
            sec = ensure_section(data, provider)
            if name == "inherit":
                sec.pop("default", None)
            else:
                sec["default"] = name
            scope = "as the default"
        else:
            where = Path(a.path).resolve() if a.path else project_root(project_dir())
            k = canon_path(where)
            binding = data["projects"].setdefault(k, {})
            if name == "inherit":
                binding.pop(provider, None)
                if not binding:
                    del data["projects"][k]
            else:
                binding[provider] = name
            scope = "for %s" % k
        save_profiles(data)
        if provider == "claude":
            manage_claude_helper(name, data, a.default, a.path)
        print("%s: %s %s" % (provider, "inherits the setting" if name == "inherit" else name, scope))
        print("\n".join(profile_lines(project_dir(), data)))
        return 0

    if a.action == "set":
        if name in ("off", "inherit") or not PROFILE_NAME_RE.fullmatch(name):
            raise SystemExit("orch: a profile name is Latin letters/digits/._- (neither off nor inherit)")
        allowed = profile_fields(provider)
        given = {f: v for f, v in (("key", a.key), ("models", a.models), ("max_effort", a.max_effort),
                                   ("write", a.write), ("use_for", a.use_for), ("prefer_for", a.prefer_for),
                                   ("rules", a.rules), ("max_open", a.max_open), ("home", a.home),
                                   ("codex_profile", a.codex_profile), ("fast_model", a.fast_model),
                                   ("base_url", a.base_url), ("fallback", a.fallback),
                                   ("session_soft", a.session_soft), ("session_hard", a.session_hard),
                                   ("balance_floor", a.balance_floor)) if v is not None}
        for opt in a.opt or []:
            f, sep, v = opt.partition("=")
            if not sep:
                raise SystemExit("orch: --opt FIELD=VALUE")
            given[f.strip()] = v
        if provider not in BALANCE_PROVIDERS and any(f in given for f in SESSION_BUDGET_FIELDS):
            raise SystemExit("orch: %s has no balance API; session budgets require a provider balance" % provider)
        bad = [f for f in given if f not in allowed]
        if bad:
            raise SystemExit("orch: %s profiles have no field %s (available: %s)" % (provider, ", ".join(bad),
                                                                                    ", ".join(allowed)))
        sec = ensure_section(data, provider)
        prof = sec["profiles"].setdefault(name, {})
        if not isinstance(prof, dict):
            prof = sec["profiles"][name] = {}
        notes = []
        for f, raw in given.items():
            v = parse_profile_value(f, raw)
            if v is None:
                prof.pop(f, None)
            else:
                if f == "fallback":
                    notes += check_fallback(provider, name, v, sec["profiles"])
                prof[f] = v
        if prof.get("session_soft") is not None and prof.get("session_hard") is not None \
                and prof["session_soft"] >= prof["session_hard"]:
            raise SystemExit("orch: session-soft must be below session-hard")
        if a.default:
            sec["default"] = name
        save_profiles(data)
        p = Profile(provider, name, prof, "default" if sec.get("default") == name else "profile", True)
        print("saved %s: %s" % (p.label, describe_profile(p, sec["profiles"])))
        for n in notes:
            print(n)
        if prof.get("key") and not secret_source(prof["key"]):
            print("no key yet: add a line %s=sk-… to %s (not to the repository, not to the chat)"
                  % (prof["key"], SECRETS_FILE))
        if prof.get("home"):
            home = Path(local_path(str(prof["home"])))
            home.mkdir(parents=True, exist_ok=True)
            if provider == "codex" and not (home / "auth.json").exists():
                print("log in to this profile's account: %s" % login_hint(home))
            if provider == "claude" and not (home / ".credentials.json").exists():
                print("log in to this profile's account once: CLAUDE_CONFIG_DIR='%s' claude   (then /login)%s" % (
                    home, "   (PowerShell: $env:CLAUDE_CONFIG_DIR='%s'; claude)" % home if IS_WINDOWS else ""))
        return 0

    if a.action == "rm":
        if name not in profs:
            raise SystemExit("orch: no profile %s@%s" % (provider, name))
        users = [k for k, b in data["projects"].items() if isinstance(b, dict) and b.get(provider) == name]
        if (users or sec.get("default") == name) and not a.force:
            raise SystemExit("orch: %s@%s is in use (%s) — switch those or add --force (the bindings are dropped)" % (
                provider, name, ", ".join((["default"] if sec.get("default") == name else []) + users)))
        del profs[name]
        for other, d in sorted(profs.items()):
            if isinstance(d, dict) and str(d.get("fallback") or "").lower() == name:
                print("note: %s@%s had it as its fallback; that fallback no longer applies" % (provider, other))
        if sec.get("default") == name:
            sec.pop("default")
        for k in users:
            data["projects"][k].pop(provider, None)
            if not data["projects"][k]:
                del data["projects"][k]
        save_profiles(data)
        print("removed %s@%s" % (provider, name))
        return 0
    return 1


# ───────────────────────── project instructions for workers ─────────────────────────
#
# Claude Code reads CLAUDE.md (with @imports), Codex and Antigravity read AGENTS.md, and a DeepSeek worker
# (--setting-sources user) reads nothing. orch hands each adapter the files its agent does not read itself
# ('# orch-context-native: AGENTS.md'), so the same project rules reach every executor exactly once.

INSTRUCTION_FILES = ("AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md")
IMPORT_RE = re.compile(r"^@(\S+)\s*$", re.M)
CONTEXT_LIMIT = 40000


def instruction_files(cwd, twin=None):
    """Existing instruction files for a working directory: repository top level first, then cwd."""
    cwd = Path(cwd).resolve()
    dirs = [cwd]
    r = git(["rev-parse", "--show-toplevel"], cwd) if cwd.is_dir() else None
    if r is not None and r.returncode == 0 and r.stdout.strip():
        top = Path(r.stdout.strip()).resolve()
        if top != cwd:
            dirs.insert(0, top)
    result = []
    for d in dirs:
        for name in INSTRUCTION_FILES:
            path = d / name
            if path.is_file():
                result.append((d, name, path))
            elif twin:
                copy = twin(path)
                if copy != path and copy.is_file():
                    check = git(["check-ignore", "-q", "--", str(copy)], copy.parent)
                    if check is not None and check.returncode == 0:
                        result.append((d, name, copy))
    return result


def main_folder_twin(cwd):
    """f(path) → that path's copy in the project folder, when a worktree lacks it: a worktree holds no git-ignored files,
    such as notes on this machine. None outside a worktree."""
    cwd = Path(cwd).resolve()
    r = git(["rev-parse", "--show-toplevel"], cwd) if cwd.is_dir() else None
    if r is None or r.returncode != 0 or not r.stdout.strip():
        return None
    top, main = Path(r.stdout.strip()).resolve(), project_root(cwd).resolve()
    if top == main:
        return None

    def twin(target):
        try:
            copy = main / target.relative_to(top)
        except ValueError:
            return target
        return copy if copy.is_file() else target
    return twin


def expand_imports(path, native, seen, depth=0, twin=None, source=None):
    """Text of an instruction file with whole-line @imports inlined (files the agent reads itself are skipped)."""
    seen.add(path.resolve())
    text = (source or path).read_text(encoding="utf-8", errors="replace")

    def inline(m):
        target = (path.parent / os.path.expanduser(m.group(1))).resolve()
        source = twin(target) if twin and not target.is_file() else target
        native_present = target.name in native and target.is_file()
        if native_present or target in seen or depth >= 3 or not source.is_file():
            return "" if native_present or target in seen else m.group(0)
        return expand_imports(target, native, seen, depth + 1, twin, source)
    return IMPORT_RE.sub(inline, text)


def build_context(cwd, native, out):
    """Write the project instructions an agent does not load natively to `out`; None if there are none."""
    parts, seen = [], set()
    twin = main_folder_twin(cwd)
    for d, name, source in instruction_files(cwd, twin):
        p = (d / name).resolve()
        if (name in native and source.resolve() == p) or p in seen:     # a native file the agent can't find still goes in
            continue
        text = expand_imports(p, native, seen, twin=twin, source=source).strip()
        if text:
            if len(text) > CONTEXT_LIMIT:
                text = text[:CONTEXT_LIMIT] + "\n…[truncated]"
            parts.append("# Project instructions (%s)\n\n%s" % (name, text))
    if not parts:
        return None
    out.write_text("\n\n---\n\n".join(parts) + "\n", encoding="utf-8")
    return out


# ───────────────────────── usage ledger ─────────────────────────
#
# ~/.orchestra/usage.jsonl, one record per line: kind run (CLI executor: model, task, tokens from the adapter's
# usage.json), handoff (manual task: agent, model, minutes) and session (Claude Code main thread + subagents,
# snapshot at SessionEnd so the numbers outlive transcript cleanup). `orch usage` joins them per session.

USAGE_FILE = ORCH_HOME / "usage.jsonl"


def session_id():
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("ORCH_SESSION_ID") or None


def learn_session_id(data):
    if not session_id() and data.get("session_id"):
        os.environ["ORCH_SESSION_ID"] = str(data["session_id"])


def ledger_append(rec):
    if os.environ.get("ORCH_USAGE_LOG", "1") == "0":
        return
    try:
        USAGE_FILE.parent.mkdir(parents=True, exist_ok=True)
        with state_lock(ORCH_HOME / ".usage.lock"):
            with USAGE_FILE.open("a", encoding="utf-8") as f:
                f.write(json.dumps(dict(rec, ts=iso_precise(now())), ensure_ascii=False) + "\n")
    except (OSError, StateError):
        pass                     # the ledger is a convenience: never fail a run because of it


def ledger_read():
    """The ledger's records: a line that isn't a JSON object (damaged, or a stray value) is skipped, never fatal."""
    out = []
    try:
        with USAGE_FILE.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict):
                    out.append(rec)
    except OSError:
        pass
    return out


def task_title(prompt, explicit=None):
    if explicit:
        return explicit.strip()[:80]
    for line in prompt.splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line[:80] + ("…" if len(line) > 80 else "")
    return ""


def read_usage(run_dir):
    """Adapter's usage.json → {input_tokens (uncached), cached_input_tokens, output_tokens, model?} or None."""
    u = read_json(run_dir / "usage.json", None)
    if not isinstance(u, dict):
        return None
    clean = {k: int(u[k]) for k in ("input_tokens", "cached_input_tokens", "output_tokens")
             if isinstance(u.get(k), (int, float))}
    if u.get("model"):
        clean["model"] = str(u["model"])
    if isinstance(u.get("models"), dict):
        clean["models"] = u["models"]
    return clean or None


# ───────────────────────── monthly spend limits (API-billed executors) ─────────────────────────
#
# DeepSeek bills per token always; Codex and Claude bill per token only when their active profile has a `key`.
# `orch spend` sets a USD limit per scope (a profile label: deepseek, deepseek@work, codex@work, claude@work, …)
# for all projects or one project. Spend is counted from the usage ledger: executor `run` records whose
# `billing` is api, and `session` records with a `lead` (the orchestrator itself on a key). The counters are
# cached incrementally in ~/.orchestra/spend_cache.json (like session_tokens): byte offset + running totals,
# restarted on a new calendar month or a shrunken ledger. --force does NOT bypass a limit, like profile max_open.

def _read_prices(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def load_prices():
    """Built-in registry/prices.json, overridden per model (and per source) by a personal ~/.orchestra/prices.json."""
    base = _read_prices(PRICES_FILE)
    personal = _read_prices(PERSONAL_PRICES_FILE)
    if not personal:
        return base
    rates = dict(base.get("usd_per_1m_tokens") or {})
    rates.update(personal.get("usd_per_1m_tokens") or {})
    sources = dict(base.get("sources") or {})
    sources.update(personal.get("sources") or {})
    return {"usd_per_1m_tokens": rates,
            "default": personal.get("default") or base.get("default") or {},
            "sources": sources}


def _parse_date(v):
    if not v:
        return None
    if isinstance(v, dt.datetime):
        return v.astimezone().date()
    try:
        return dt.datetime.strptime(str(v), "%Y-%m-%d").date()
    except ValueError:
        t = parse_iso(str(v))
        return t.astimezone().date() if t else None


def _active_rate(entry, when):
    """Resolve a price entry that is a constant dict or a list of dated dicts (`from`/`to`, for promotions that end)."""
    when = (when or now()).astimezone()
    if isinstance(entry, dict):
        return entry
    if isinstance(entry, list):
        best = None
        for e in entry:
            if not isinstance(e, dict):
                continue
            frm, to = _parse_date(e.get("from")), _parse_date(e.get("to"))
            today = when.date()
            if frm and today < frm:
                continue
            if to and today >= to:
                continue
            key = frm or dt.date.min
            if best is None or key >= best[0]:
                best = (key, e)
        return best[1] if best else None
    return None


def price_multiplier(rates, when):
    """1.0 inside a provider's peak windows, else its off-peak multiplier (DeepSeek peaks Mon–Fri 01–04 & 06–10 UTC)."""
    if not isinstance(rates, dict):
        return 1.0
    off = rates.get("off_peak_multiplier")
    windows = rates.get("peak_windows_utc")
    if not off or not isinstance(windows, list) or not windows:
        return 1.0
    when = (when or now()).astimezone(dt.timezone.utc)
    days = [str(d).lower() for d in rates.get("peak_days") or []]
    if days and ["mon", "tue", "wed", "thu", "fri", "sat", "sun"][when.weekday()] not in days:
        return float(off)
    t = when.strftime("%H:%M")
    for w in windows:
        if isinstance(w, list) and len(w) == 2 and w[0] <= t < w[1]:
            return 1.0
    return float(off)


def price_entry(model, provider):
    """The raw rates entry (dict or dated list) for a model, else the default; None when nothing is priced."""
    prices = load_prices()
    rates = prices.get("usd_per_1m_tokens") or {}
    default = prices.get("default")
    m = str(model or "").lower().split("[")[0].strip()
    provider = (provider or "").lower()
    entry = None
    if provider == "claude":                      # the adapter reports aliases or ids like claude-sonnet-5-5-…
        for fam in ("fable", "opus", "sonnet", "haiku"):
            if fam in m:
                entry = rates.get(fam)
                break
    if entry is None and m in rates:
        entry = rates[m]
    if entry is None:
        for key in sorted(rates, key=len, reverse=True):   # gpt-6.1-sol-… → gpt-6.1-sol; gpt-5.6-terra → gpt-5.6
            if m.startswith(key):
                entry = rates[key]
                break
    if entry is None:
        entry = default if default else None
    return entry


def price_for(model, provider, when=None):
    """{input, cache_read, cache_write?, output} rates (USD per 1M tokens) for a model at `when`, else None when
    unpriced. Dated entries and peak windows are resolved here, so the returned numbers are already scaled."""
    entry = price_entry(model, provider)
    if entry is None:
        return None
    rates = _active_rate(entry, when)
    if not isinstance(rates, dict):
        rates = {}
    mult = price_multiplier(rates, when)
    return {"input": float(rates.get("input") or 0) * mult,
            "cache_read": float(rates.get("cache_read") or 0) * mult,
            "cache_write": float(rates.get("cache_write") or 0) * mult,
            "output": float(rates.get("output") or 0) * mult}


def price_as_of(provider):
    """The `as_of` date of the effective price list for a provider, or None."""
    prices = load_prices()
    s = (prices.get("sources") or {}).get((provider or "").lower())
    return s.get("as_of") if isinstance(s, dict) else None


def price_staleness(provider):
    """A warning when a provider's prices are older than 30 days; None otherwise. Kept out of `orch status`."""
    prices = load_prices()
    s = (prices.get("sources") or {}).get((provider or "").lower())
    if not isinstance(s, dict) or not s.get("as_of"):
        return None
    d = _parse_date(s["as_of"])
    if d is None:
        return None
    age = (now().astimezone().date() - d).days
    if age > 30:
        return "prices for %s are from %s (%d days old) — check %s" % (
            provider, s["as_of"], age, s.get("source") or "the provider's price list")
    return None


def usage_cost(usage, provider, model=None, when=None):
    """USD of a token usage dict at the provider's prices: uncached input + cache reads + output (cache writes are
    folded into input, priced at the input rate)."""
    u = usage if isinstance(usage, dict) else {}
    models = u.get("models")
    if isinstance(models, dict) and len(models) > 1:   # several models (e.g. a lead's fast background calls)
        return sum(usage_cost(v, provider, m, when) for m, v in models.items() if isinstance(v, dict))
    m = (u.get("model") or model or "")
    rates = price_for(m, provider, when)
    if not rates:
        return 0.0
    inp = float(u.get("input_tokens") or 0)
    cache = float(u.get("cached_input_tokens") or 0)
    out = float(u.get("output_tokens") or 0)
    return (inp * float(rates.get("input") or 0) + cache * float(rates.get("cache_read") or 0)
            + out * float(rates.get("output") or 0)) / 1e6


def month_key(t=None):
    return (t or now()).strftime("%Y-%m")


def month_start(t=None):
    t = (t or now()).astimezone()
    return t.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def spend_where(where):
    """Canonical project path of a directory; an already-canonical ledger path passes through unchanged."""
    if isinstance(where, str) and re.match(r"^[A-Za-z]:", where.replace("\\", "/")):
        return canon_path(where)
    return canon_path(project_root(where))


def _project_settings(config, canon):
    """The longest project entry covering a canonical path, or None."""
    projects = config.get("projects") or {}
    best, found = -1, None
    for k, v in projects.items():
        ck = canon_path(k)
        if (canon == ck or canon.startswith(ck + "/")) and isinstance(v, dict) and len(ck) > best:
            best = len(ck)
            found = v
    return found


def _project_entry(data, canon, create=False):
    """The project entry dict for a canonical path (reusing the operator's spelling when it exists)."""
    projects = data.setdefault("projects", {})
    for k, v in projects.items():
        if canon_path(k) == canon and isinstance(v, dict):
            return v
    if not create:
        return None
    projects[canon] = {}
    return projects[canon]


def counter_key(config, scope, canon):
    """(counter_scope, scope): the project owning this scope's own counter (its canonical path), else 'global'."""
    projects = config.get("projects") or {}
    best, owner_key, owner = -1, None, None
    for k, v in projects.items():
        ck = canon_path(k)
        if (canon == ck or canon.startswith(ck + "/")) and isinstance(v, dict) and len(ck) > best:
            best, owner_key, owner = len(ck), ck, v
    s = owner.get(scope) if owner else None
    if isinstance(s, dict) and "limit" in s:
        return owner_key, scope
    return "global", scope


def registry_providers():
    """Provider keys in the effective registry's `providers:` block (2-space indented; no YAML library)."""
    out = []
    try:
        text = registry_path().read_text(encoding="utf-8")
    except OSError:
        return out
    in_providers = False
    for line in text.splitlines():
        if not in_providers:
            if line.rstrip() == "providers:":
                in_providers = True
            continue
        if line and not line[0].isspace():
            break                                   # a later top-level key ends the block
        m = re.match(r"^  ([A-Za-z][A-Za-z0-9_-]*):\s*$", line)
        if m:
            out.append(m.group(1).lower())
    return out


def known_providers():
    """Providers a scope may name: the registry's providers plus every adapter, manual lane and profile provider."""
    try:
        data, _ = load_profiles()
    except Exception:
        data = {"providers": {}}
    return list(dict.fromkeys(registry_providers() + managed_providers(data)))


def valid_scope(scope):
    """True when a scope names a known provider, or a known provider@profile that exists."""
    scope = (scope or "").strip().lower()
    if not scope:
        return False
    provider, _, name = scope.partition("@")
    if provider not in known_providers():
        return False
    if not name:
        return True
    try:
        data, err = load_profiles()
    except Exception:
        return True
    if err:
        return True                          # a broken profiles file cannot answer; the provider part already passed
    _, profs = provider_section(data, provider)
    return name in {p.lower() for p in profs}


def scope_has_key(scope, where=None):
    """True when the scope bills an API key with a prepaid balance → default manual reset. DeepSeek always; other
    providers when the named profile has a `key` field (or the active profile, for a bare provider scope)."""
    provider, _, name = (scope or "").partition("@")
    provider = provider.lower()
    if provider == "deepseek":
        return True
    try:
        data, err = load_profiles()
        if err:
            return False
    except Exception:
        return False
    if name:
        sec, profs = provider_section(data, provider)
        d = profs.get(name.lower())
        return isinstance(d, dict) and bool(d.get("key"))
    return profile_key(provider, where or project_dir()) is not None


def _baseline_section(config, key):
    b = config.get("baselines")
    if not isinstance(b, dict):
        b = config["baselines"] = {}
    sec = b.get(key)
    if not isinstance(sec, dict):
        sec = b[key] = {}
    return sec


def get_baseline(config, scope, where):
    """The stored baseline timestamp of `scope`'s counter (manual reset), or None."""
    key = counter_key(config, scope, spend_where(where))[0]
    return _baseline_section(config, key).get(scope)


@locked("home")
def ensure_baseline(scope, where):
    """Write a baseline (now) for a manual scope the first time it is seen, so spending from before this feature
    doesn't count. Re-reads under the lock; returns the baseline datetime, or None for a month scope / a broken
    limits file (writes refuse)."""
    config, err = load_spend_limits()
    if err or resolve_reset(config, scope, where) != "manual":
        return None
    key = counter_key(config, scope, spend_where(where))[0]
    sec = _baseline_section(config, key)
    if scope in sec:
        return parse_iso(str(sec[scope]))
    t = now()
    sec[scope] = iso_precise(t)
    save_spend_limits(config)
    return t


def resolve_reset(config, scope, where):
    """The reset kind for a scope: project → global → default, else the rule (an API key → manual, else month)."""
    defaults = config.get("defaults") or {}
    g = (config.get("global") or {}).get(scope)
    p = (_project_settings(config, spend_where(where)) or {}).get(scope)
    g = g if isinstance(g, dict) else {}
    p = p if isinstance(p, dict) else {}
    for src in (p, g):
        if src.get("reset") in ("manual", "month"):
            return src["reset"]
    d = defaults.get("reset")
    if d in ("manual", "month"):
        return d
    return "manual" if scope_has_key(scope, where) else "month"


def counter_start(config, scope, where):
    """Datetime the counter for `scope` counts from in `where`: a manual scope counts from its baseline (None until
    one is written — first seen), a month scope from the 1st of this month."""
    if resolve_reset(config, scope, where) == "month":
        return month_start(now())
    ts = get_baseline(config, scope, where)
    return parse_iso(str(ts)) if ts else None


def resolve_spend(config, scope, where):
    """Effective {limit, mode, lead_mode, overrun} for a scope in a directory (project → global → defaults)."""
    defaults = config.get("defaults") or {}
    g = (config.get("global") or {}).get(scope)
    p = (_project_settings(config, spend_where(where)) or {}).get(scope)
    g = g if isinstance(g, dict) else {}
    p = p if isinstance(p, dict) else {}
    out = {}
    for field in ("limit", "mode", "lead_mode", "overrun"):
        if field in p and p[field] is not None:
            out[field] = p[field]
        elif field in g and g[field] is not None:
            out[field] = g[field]
        else:
            out[field] = defaults.get(field, DEFAULT_SPEND.get(field))
    return out


def _limit_number(eff):
    limit = eff.get("limit")
    if limit == "off" or limit is None:
        return None
    try:
        return float(limit)
    except (TypeError, ValueError):
        return None


def spend_kill_at(eff, field="mode"):
    """Dollars at which a running executor (or the lead, field='lead_mode') stops: stop at 100%, evaluate at
    100% + overrun; None for continue (warn only) or an off/unlimited limit."""
    limit = _limit_number(eff)
    if limit is None:
        return None
    mode = eff.get(field)
    if mode == "stop":
        return limit
    if mode == "evaluate":
        try:
            overrun = float(eff.get("overrun"))
        except (TypeError, ValueError):
            overrun = DEFAULT_SPEND["overrun"]
        return limit * (1 + overrun / 100.0)
    return None


def load_spend_limits():
    """(data, error). A broken file is an error (writes refuse; reads keep the defaults) — never fail-open."""
    empty = {"defaults": dict(DEFAULT_SPEND), "global": {}, "projects": {}, "baselines": {}}
    try:
        data = json.loads(_read_text_retry(SPEND_FILE, encoding="utf-8-sig"))
    except FileNotFoundError:
        return empty, None
    except (OSError, ValueError) as ex:
        return empty, "%s is unreadable: %s" % (SPEND_FILE, ex)
    if not isinstance(data, dict):
        return empty, "%s: expected an object" % SPEND_FILE
    for k in ("defaults", "global", "projects", "baselines"):
        data.setdefault(k, {} if k != "defaults" else dict(DEFAULT_SPEND))
    if not isinstance(data["defaults"], dict):
        data["defaults"] = dict(DEFAULT_SPEND)
    for k in ("global", "projects", "baselines"):
        if not isinstance(data[k], dict):
            data[k] = {}
    return data, None


def save_spend_limits(data):
    data["_readme"] = ("Orchestra spend limits for API-billed executors: orch spend "
                       "(limit/mode/reset per scope, global or per project; baselines for manual counters).")
    data.setdefault("version", 1)
    write_json(SPEND_FILE, data)


def _api_billed_record(rec):
    """True when a run record bills to an API key: its `billing` field, else the old-entry heuristic (deepseek)."""
    billing = rec.get("billing")
    if billing in ("api", "subscription"):
        return billing == "api"
    return str(rec.get("provider") or "").lower() == "deepseek"


def session_cost(rec):
    """USD of a lead session's tokens (main thread + subagents), at the lead provider's prices."""
    lead = str(rec.get("lead") or "")
    provider = lead.split("@")[0].lower()
    total = 0.0
    for row in rec.get("rows") or []:
        if isinstance(row, dict):
            total += usage_cost(row, provider, row.get("model"))
    return total


def _run_cost(rec):
    """USD of a run record: its frozen `cost_usd` when present, else priced from usage at read time."""
    if isinstance(rec.get("cost_usd"), (int, float)):
        return float(rec["cost_usd"])
    return usage_cost(rec.get("usage"), str(rec.get("provider") or ""), rec.get("model"))


def _session_cost(rec):
    """USD of a session record: its frozen `spend_usd` when present, else priced from the rows at read time."""
    if isinstance(rec.get("spend_usd"), (int, float)):
        return float(rec["spend_usd"])
    return session_cost(rec)


def record_spend(rec):
    """(label, project, cost, ts, sid) of a ledger record, or None when it does not count toward spend.
    `sid` is the session id for session records (None for runs) — snapshots of one session are deduplicated."""
    if not isinstance(rec, dict):
        return None
    ts = parse_iso(str(rec.get("ts") or "")) or now()
    if rec.get("kind") == "run":
        if not _api_billed_record(rec):
            return None
        label = str(rec.get("label") or rec.get("provider") or "?")
        return label, rec.get("project"), _run_cost(rec), ts, None
    if rec.get("kind") == "session":
        lead = str(rec.get("lead") or "")
        if not lead:
            return None
        sid = rec.get("session")
        return lead, rec.get("project"), _session_cost(rec), ts, str(sid) if sid else None
    return None


def spend_cache_update():
    """Update the spend cache from the usage ledger. → (records, changed). Records: {label, project, cost, ts, sid}.
    Restarts on a shrunken ledger (byte offset, like session_tokens); a reset (baseline/month) is applied at read
    time, so it takes effect at once without re-reading the ledger. Session records are deduplicated by session id:
    each SessionEnd snapshot is cumulative, so only the last one per session counts. A cache that is up to date takes
    no lock; a hook or the status line that finds the lock busy uses the cached records as they are."""
    cache = read_json(SPEND_CACHE_FILE, {}, recover_corrupt=True)
    records = cache.get("records") if isinstance(cache, dict) and isinstance(cache.get("records"), list) else []
    try:
        size = USAGE_FILE.stat().st_size
    except OSError:
        size = 0
    if isinstance(cache, dict) and cache.get("format") == 3 and cache.get("offset") == size:
        return records, False
    try:
        with state_lock(ORCH_HOME / ".state.lock"):
            return _spend_cache_update()
    except StateError:
        if _quiet_state:
            return records, False
        raise


def _spend_cache_update():
    cache = read_json(SPEND_CACHE_FILE, {}, recover_corrupt=True)
    if not isinstance(cache, dict):
        cache = {}
    records = cache.get("records") if isinstance(cache.get("records"), list) else []
    offset = cache.get("offset") if isinstance(cache.get("offset"), int) else 0
    changed = False
    if cache.get("format") != 3:                          # migrate: v2 summed repeated session snapshots
        cache = {"format": 3, "offset": 0}
        records, offset, changed = [], 0, True
    try:
        size = USAGE_FILE.stat().st_size
    except OSError:
        size = 0
    if size < offset:                                     # the ledger was rotated/shrunk: recompute from zero
        records, offset, changed = [], 0, True
    if size > offset:
        try:
            with USAGE_FILE.open("rb") as f:
                f.seek(offset)
                data = f.read(size - offset)
        except OSError:
            data = b""
        nl = data.rfind(b"\n")
        consumed = len(data) if nl == len(data) - 1 else (nl + 1 if nl != -1 else 0)
        new = []
        for line in data[:consumed].decode("utf-8", "replace").splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            r = record_spend(rec)
            if r is not None:
                new.append({"label": r[0], "project": r[1], "cost": r[2], "ts": r[3].isoformat(), "sid": r[4]})
        if new:
            records = records + new
        if consumed:                                      # persist the offset even when nothing counted
            changed = True
        offset += consumed
    if changed:
        seen, deduped = {}, []                            # keep only the last snapshot per session
        for r in records:
            sid = r.get("sid")
            if sid is None:
                deduped.append(r)
            elif sid in seen:
                deduped[seen[sid]] = r
            else:
                seen[sid] = len(deduped)
                deduped.append(r)
        records = deduped
        write_json(SPEND_CACHE_FILE, {"format": 3, "offset": offset, "records": records})
    return records, changed


def current_spend(scope, where, records=None):
    """Dollars spent against `scope`'s counter for a directory (runs + lead sessions), since the counter's start."""
    if records is None:
        records, _ = spend_cache_update()
    config = load_spend_limits()[0]
    key = counter_key(config, scope, spend_where(where))[0]
    start = counter_start(config, scope, where)
    if start is None:                                    # manual scope not yet seen: nothing counts yet
        return 0.0
    total = 0.0
    for r in records:
        if r.get("label") != scope:
            continue
        if counter_key(config, r.get("label"), r.get("project") or "")[0] != key:
            continue
        ts = parse_iso(str(r.get("ts") or ""))
        if ts is not None and ts < start:
            continue
        total += float(r.get("cost") or 0)
    return total


def profile_api_scope(prof, provider, where=None):
    """The spend scope label for a run/launch on this profile, or None when it does not bill to an API key."""
    provider = (provider or "").lower()
    if prof.name == "off":
        return None
    if provider == "deepseek":
        return prof.label
    if prof.explicit and prof.data.get("key"):
        return prof.label
    return None


def spend_scope(provider, where=None):
    """The API-billed scope label active for a directory (re-resolves the profile), or None."""
    try:
        prof = resolve_profile(provider, where or project_dir())
    except ProfileError:
        return None
    return profile_api_scope(prof, provider, where or project_dir())


def api_billed(provider, where=None):
    return spend_scope(provider, where) is not None


def active_profiles(where):
    """[(profile, spend scope or None)]: the profile each provider resolves to in a directory (a fallback while its
    key is exhausted), in provider order; a provider whose profile cannot be resolved is left out."""
    where = where or project_dir()
    out = []
    for provider in known_providers():
        try:
            prof = resolve_profile(provider, where)
        except ProfileError:
            continue
        out.append((prof, profile_api_scope(prof, provider, where)))
    return out


def api_scopes(where):
    """The API-billed scope labels active in a directory (DeepSeek + any key profiles), in provider order."""
    return [scope for _, scope in active_profiles(where) if scope]


def preferred_api_profiles(where):
    """[(display name, [task types])] of the API-billed profiles active in a directory that have `prefer for`: while
    their key has budget they go first for those task types, ahead of Claude in a SURPLUS. An exhausted profile
    resolves to its fallback, whose own `prefer for` (if any) applies instead."""
    try:
        out = []
        for prof, scope in active_profiles(where):
            types = prof.data.get("prefer_for")
            types = [types] if isinstance(types, str) else list(types or [])
            if scope and types and prof.provider != "claude":
                out.append((scope_name(prof.label), [str(t) for t in types]))
        return out
    except Exception:
        return []


def counter_cover(config, scope, where):
    """What the counter covers, for the user: 'manual, since Nov 02 18:40' or 'this month'."""
    if resolve_reset(config, scope, where) == "manual":
        ts = get_baseline(config, scope, where)
        t = parse_iso(str(ts)) if ts else None
        return "manual, since %s" % t.strftime("%b %d %H:%M") if t else "manual"
    return "this month"


def _way_out(config, scope, where):
    """The operator's way out of a blocked scope, for messages."""
    if resolve_reset(config, scope, where) == "manual":
        return "top up and orch spend reset %s [--limit N]" % scope
    return "raise the limit (orch spend limit %s N) or wait for the 1st" % scope


def scope_fallback_note(scope):
    """' Without --profile, DeepSeek@personal (its fallback) takes over.' for a scope whose profile has a usable
    fallback, else ''. Only an explicit --profile can still reach a refusal for such a scope."""
    provider, _, name = (scope or "").partition("@")
    try:
        data, err = load_profiles()
        if err or not name:
            return ""
        _, profs = provider_section(data, provider.lower())
        d = profs.get(name.lower())
        if not isinstance(d, dict):
            return ""
        target = fallback_target(Profile(provider.lower(), name.lower(), d, "profile", True), profs)
    except Exception:
        return ""
    return (" Without --profile, %s (its fallback) takes over." % scope_name(target.label)) if target else ""


def _spend_warn(scope, spent, eff, kind, config=None, where=None):
    limit = _limit_number(eff)
    if limit is None or limit <= 0 or spent < limit * SPEND_WARN_PCT / 100.0:
        return None
    mode = eff.get("mode" if kind == "executor" else "lead_mode")
    if config is None:
        config = load_spend_limits()[0]
    if where is None:
        where = project_dir()
    return "%s: $%.2f of $%.2f (%s, %.0f%%), %s mode %s — orch spend" % (
        scope_name(scope), spent, limit, counter_cover(config, scope, where), spent / limit * 100, kind, mode)


def spend_start(scope, where):
    """Pre-start check of an executor run. → (allowed, line). Refuses at the limit under stop/evaluate; --force
    does not bypass it; a broken limits file refuses (fail-closed, like profiles)."""
    config, err = load_spend_limits()
    if err:
        return False, ("SPEND_LIMIT %s — %s; fix or remove it, then retry" % (scope_name(scope), err))
    ensure_baseline(scope, where)
    eff = resolve_spend(config, scope, where)
    spent = current_spend(scope, where)
    limit = _limit_number(eff)
    if limit is None:
        return True, None
    if eff.get("mode") in ("stop", "evaluate") and spent >= limit:
        return False, ("SPEND_LIMIT %s — $%.2f already spent (%s; limit $%.2f, mode %s). %s.%s" %
                       (scope_name(scope), spent, counter_cover(config, scope, where), limit, eff.get("mode"),
                        _way_out(config, scope, where), scope_fallback_note(scope)))
    return True, _spend_warn(scope, spent, eff, "executor", config, where)


def spend_lead_start(scope, where):
    """Pre-start check of a lead session (orch launch). → (allowed, line)."""
    config, err = load_spend_limits()
    if err:
        return False, ("SPEND_LIMIT %s — %s; fix or remove it, then retry" % (scope_name(scope), err))
    ensure_baseline(scope, where)
    eff = resolve_spend(config, scope, where)
    spent = current_spend(scope, where)
    limit = _limit_number(eff)
    if limit is None:
        return True, None
    if eff.get("lead_mode") in ("stop", "evaluate") and spent >= limit:
        return False, ("SPEND_LIMIT %s — $%.2f already spent (%s; limit $%.2f, lead mode %s). %s." %
                       (scope_name(scope), spent, counter_cover(config, scope, where), limit, eff.get("lead_mode"),
                        _way_out(config, scope, where)))
    return True, _spend_warn(scope, spent, eff, "lead", config, where)


def spend_lead_key(scope, where):
    """orch key refusal: a Claude lead's requests fail past the threshold (stop at 100%, evaluate past the
    overrun). → (allowed, line)."""
    config, err = load_spend_limits()
    if err:
        return False, ("SPEND_LIMIT %s — %s; fix or remove it, then retry" % (scope_name(scope), err))
    eff = resolve_spend(config, scope, where)
    spent = current_spend(scope, where)
    kill = spend_kill_at(eff, "lead_mode")
    if kill is not None and spent >= kill:
        return False, ("SPEND_LIMIT %s — $%.2f of the $%.2f limit spent (%s; lead mode %s). %s" %
                       (scope_name(scope), spent, _limit_number(eff), counter_cover(config, scope, where),
                        eff.get("lead_mode"), _way_out(config, scope, where)))
    return True, None


def live_usage(run_dir, provider, where=None, prof=None):
    """The executor's token usage so far during a run (headless adapters write usage_live.json; codex reads its
    rollout's token_count)."""
    if provider == "codex":
        return codex_live_usage(run_dir, where, prof)
    return read_json(Path(run_dir) / "usage_live.json", None)


def codex_live_usage(run_dir, where=None, prof=None):
    """Codex reports usage at the end of a turn: read token_count.info.total_token_usage from the run's rollout
    (thread_id). Best-effort — if the rollout is unreadable, codex gets no mid-run stop (pre/post checks remain)."""
    try:
        tid = (Path(run_dir) / "thread_id").read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not tid:
        return None
    sessions = Path(codex_home(where, prof)) / "sessions"
    if not sessions.is_dir():
        return None
    files = [p for p in sessions.rglob("rollout-*.jsonl") if tid in p.name]
    if not files:
        return None
    files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    usage = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
    found = False
    for line in tail_lines(files[0], CODEX_TAIL_BYTES):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("type") != "event_msg":
            continue
        payload = ev.get("payload")
        info = payload.get("info") if isinstance(payload, dict) else None
        u = info.get("total_token_usage") if isinstance(info, dict) else None
        if not isinstance(u, dict):
            continue
        try:
            inp = int(u.get("input_tokens") or 0)
            cache = int(u.get("cached_input_tokens") or 0)
            out = int(u.get("output_tokens") or 0)
        except (TypeError, ValueError):
            continue                                    # a malformed usage line must not crash the run
        found = True
        usage["input_tokens"] = max(inp - cache, 0)      # codex counts cache reads inside input
        usage["cached_input_tokens"] = cache
        usage["output_tokens"] = out
    return usage if found else None


def spend_high_scopes(where, scopes=None):
    """[(scope, spent, limit, ratio)] of the API-billed scopes of a directory at ≥ 80% of their limit."""
    config = load_spend_limits()[0]
    records, _ = spend_cache_update()
    out = []
    for scope in (api_scopes(where) if scopes is None else scopes):
        eff = resolve_spend(config, scope, where)
        limit = _limit_number(eff)
        if limit is None or limit <= 0:
            continue
        spent = current_spend(scope, where, records)
        ratio = spent / limit
        if ratio >= SPEND_WARN_PCT / 100.0:
            out.append((scope, spent, limit, ratio))
    out.sort(key=lambda x: -x[3])
    return out


def spend_status_part(where):
    """A one-line 'API spend: …' summary for status, or None when nothing is at ≥ 80%."""
    parts = ["%s $%.2f/$%.0f (%.0f%%)" % (scope_name(s), spent, limit, ratio * 100)
             for s, spent, limit, ratio in spend_high_scopes(where)]
    return ("API spend: " + " · ".join(parts)) if parts else None


def limit_text(limit):
    """'$10' for a whole limit, '$12.16' for one that is not: a limit must not misread when it is shown."""
    return "$%d" % round(limit) if abs(limit - round(limit)) < 0.005 else "$%.2f" % limit


def shown_api_scopes(where, cache=None, records=None):
    """([(profile, scope, spent, limit or None, account figure or '')], balance cache) of the API-billed scopes a
    directory shows in the status line and in `orch status`, in provider order. The built-in profile of a provider
    (DeepSeek's) is shown once it has a key, some spend or a cached balance: a provider nobody uses stays silent.
    Reads files only: no network."""
    active = active_profiles(where)
    if not any(sc for _, sc in active):
        return [], {}
    cache = balance_cache() if cache is None else cache
    if records is None:
        records, _ = spend_cache_update()
    config = load_spend_limits()[0]
    account = balance_fragments([sc for _, sc in active if sc], cache)
    secrets, out = None, []
    for prof, scope in active:
        if not scope:
            continue
        spent = current_spend(scope, where, records)
        if not prof.explicit and scope not in account and spent <= 0:
            var = (BALANCE_PROVIDERS.get(prof.provider) or {}).get("key")
            secrets = load_secrets() if secrets is None else secrets
            if not (var and balance_secret(var, secrets)):
                continue
        out.append((prof, scope, spent, _limit_number(resolve_spend(config, scope, where)), account.get(scope, "")))
    return out, cache


def spend_status_items(where):
    """For the status line, each API-billed scope active in the directory, always: [(lowercase label, display name,
    text)] where the text is our own estimate and limit and, where one is cached, the provider's figure for the account —
    'est. $1.47/$10, account $15.09, 3h ago' (the age once the figure is older than 30 minutes; 'est. $1.47' alone when
    the limit is off, and no account part before a balance was ever fetched). A provider whose active profile is a
    fallback also says so: 'fallback: DeepSeek@client at its limit; est. $0.99/$12'. The session part puts each text in
    parentheses after the counter of the same account. Reads files only: no network."""
    active = active_profiles(where)
    notes = {prof.label: "fallback: %s %s" % (scope_name("%s@%s" % (prof.provider, prof.fallback_from)),
                                              fallback_cause_words(prof.fallback_cause))
             for prof, _ in active if prof.fallback_from}
    rows = {prof.label: (spent, limit, acct) for prof, _, spent, limit, acct in shown_api_scopes(where)[0]}
    items = []
    for prof, _ in active:
        label = prof.label
        if label not in rows and label not in notes:
            continue
        text = []
        if label in rows:
            spent, limit, acct = rows[label]
            est = "est. $%.2f" % spent
            if limit is not None:
                est += "/" + limit_text(limit)
            text = [est] + ([acct] if acct else [])
        money_text = ", ".join(text)
        if label in notes:
            money_text = notes[label] + ("; " + money_text if money_text else "")
        items.append((label.lower(), scope_name(label), money_text))
    return items


@locked("home")
def spend_event(announce=True):
    """💡 events when a scope crosses 80% / 100% of its limit — once per month for a month counter, once per
    baseline for a manual one. announce=False only records the threshold (SessionStart already shows the status)."""
    state = read_json(SPEND_EVENTS_FILE, {}, recover_corrupt=True)
    if not isinstance(state, dict):
        state = {}
    announced = state.get("announced") if isinstance(state.get("announced"), dict) else {}
    config = load_spend_limits()[0]
    where = project_dir()
    events, changed = [], False
    for scope in api_scopes(where):
        eff = resolve_spend(config, scope, where)
        limit = _limit_number(eff)
        if limit is None or limit <= 0:
            continue
        spent = current_spend(scope, where)
        era = (get_baseline(config, scope, where) or "none") if resolve_reset(config, scope, where) == "manual" \
            else month_key()
        cur = announced.get(scope)
        level = cur.get("level") if isinstance(cur, dict) and cur.get("era") == era else None
        if spent >= limit and level != "100":
            announced[scope] = {"era": era, "level": "100"}
            changed = True
            events.append("💡 %s is at its spend limit ($%.2f/$%.2f, %s, mode %s) — %s" %
                          (scope_name(scope), spent, limit, counter_cover(config, scope, where), eff.get("mode"),
                           _way_out(config, scope, where)))
        elif spent >= limit * 0.8 and level not in ("80", "100"):
            announced[scope] = {"era": era, "level": "80"}
            changed = True
            events.append("💡 %s reached 80%% of its spend limit ($%.2f/$%.2f, %s) — orch spend" %
                          (scope_name(scope), spent, limit, counter_cover(config, scope, where)))
    if changed:                                          # this runs on every tool call: no write without news
        state["announced"] = announced
        write_json(SPEND_EVENTS_FILE, state)
    return events if announce else []


def fallback_expired(entry, cutoff):
    """A per-session fallback entry outlives its session only this long (an unreadable `at` counts as expired);
    a project-wide entry, one without `session`, never expires."""
    if not isinstance(entry, dict) or "session" not in entry:
        return False
    at = parse_iso(str(entry.get("at") or ""))
    return at is None or at < cutoff


@locked("home")
def fallback_forget(sid):
    """Drop the fallback state of an ended session, and every per-session entry older than SESSION_STATE_DAYS:
    a session that ends (or dies) while its provider is on a fallback must not leave an entry for every hook to read.
    Writes only when something was removed; the rest of spend_events.json stays as it was."""
    state = read_json(SPEND_EVENTS_FILE, {}, recover_corrupt=True)
    if not isinstance(state, dict):
        return
    seen = state.get("fallback")
    if not isinstance(seen, dict):
        return
    cutoff = now() - dt.timedelta(days=SESSION_STATE_DAYS)
    kept = {key: entry for key, entry in seen.items()
            if not fallback_expired(entry, cutoff)
            and not (sid and isinstance(entry, dict) and entry.get("session") == sid)}
    if len(kept) != len(seen):
        state["fallback"] = kept
        write_json(SPEND_EVENTS_FILE, state)


@locked("home")
def fallback_event(announce=True):
    """💡 events when a provider moves from its exhausted profile to the profile's `fallback` in this project, and when
    it returns — once each way (the last move is kept in spend_events.json). A per-session entry also keeps its
    `session` and `at`, so `fallback_forget` can drop it when the session ends, and any per-session entry older than
    SESSION_STATE_DAYS is dropped whenever this state is written. announce=False only records the state
    (SessionStart already shows it in the profiles)."""
    where = project_dir()
    data, err = load_profiles()
    if err:
        return []
    state = read_json(SPEND_EVENTS_FILE, {}, recover_corrupt=True)
    if not isinstance(state, dict):
        state = {}
    seen = state.get("fallback") if isinstance(state.get("fallback"), dict) else {}
    canon = canon_path(project_root(where))
    sid = session_id()
    config = None
    events, changed = [], False
    for provider in managed_providers(data):
        key = "%s|%s" % (canon, provider)
        try:
            configured = resolve_profile(provider, where, data=data, follow=False)
            prof = resolve_profile(provider, where, data=data)
        except ProfileError:
            continue
        per_session = bool(has_session_budget(configured) and sid)
        if per_session:
            key += "|" + sid
        was = seen.get(key) if isinstance(seen.get(key), dict) else None
        shown = display_name(provider)
        if prof.fallback_from:
            moved = {"from": prof.fallback_from, "to": prof.name}
            if was and all(was.get(k) == v for k, v in moved.items()):     # `at`/`session` never decide this
                continue
            if prof.fallback_cause in ("floor", "session-hard", "session-soft"):
                fig = session_budget_figure(configured) or {}
                moved.update(cause=prof.fallback_cause, baseline_at=fig.get("baseline_at"), amount=fig.get("amount"))
                if per_session:
                    moved.update(session=sid, at=iso_precise(now()))
                seen[key], changed = moved, True
                events.append("💡 %s moved to %s: %s (%s)" % (shown, prof.name,
                              fallback_cause_text(prof.fallback_from, prof.fallback_cause),
                              session_budget_text(configured, settings=False)))
                continue
            if per_session:
                moved.update(session=sid, at=iso_precise(now()))
            seen[key], changed = moved, True
            label = provider + "@" + prof.fallback_from
            if prof.fallback_cause == "limit":
                if config is None:
                    config = load_spend_limits()[0]
                way = _way_out(config, label, where)
            else:
                way = "orch quota clear " + label
            events.append("💡 %s is %s — %s in this project moved to its fallback %s: that profile's key, limits and "
                          "routing apply instead. It returns by itself when %s is usable again (%s)" % (
                              scope_name(label), "at its limit" if prof.fallback_cause == "limit"
                              else prof.fallback_cause, shown, scope_name(provider + "@" + prof.name),
                              scope_name(label), way))
        elif was:
            del seen[key]
            changed = True
            if prof.name == was.get("from"):         # still bound to the configured profile: it is usable again
                if was.get("cause") in ("floor", "session-hard", "session-soft"):
                    fig = session_budget_figure(prof) or {}
                    topped_up = fig.get("baseline_at") != was.get("baseline_at") or (
                        fig.get("amount") is not None and was.get("amount") is not None
                        and round(fig["amount"] - was["amount"], 8) >= 0.01)
                    reason = "topped up" if topped_up else (
                        "Claude is TIGHT" if was["cause"] == "session-soft" and claude_budget(where)[0] == "tight"
                        else "budget clear")
                    events.append("💡 %s returned to %s: %s (%s)" % (
                                  shown, prof.name, reason, session_budget_text(prof, settings=False)))
                    continue
                events.append("💡 %s is usable again — %s in this project is back on it (it was on its fallback %s)"
                              % (scope_name(provider + "@" + prof.name), shown,
                                 scope_name(provider + "@" + str(was.get("to")))))
    if changed:
        cutoff = now() - dt.timedelta(days=SESSION_STATE_DAYS)
        state["fallback"] = {key: entry for key, entry in seen.items() if not fallback_expired(entry, cutoff)}
        write_json(SPEND_EVENTS_FILE, state)
    return events if announce else []


def parse_limit(value):
    """USD amount (float) or None for 'off'; exits on a bad value (negative, NaN or infinity)."""
    import math
    if value == "off":
        return None
    try:
        v = float(value)
        if not math.isfinite(v) or v < 0:
            raise ValueError
        return v
    except (TypeError, ValueError):
        raise SystemExit("orch: limit is a USD amount or 'off', got %r" % value)


def _scope_entry(data, scope, where, project):
    """The dict to mutate for a scope: defaults / global / this project's entry (created on demand)."""
    if scope == "default":
        return data.setdefault("defaults", dict(DEFAULT_SPEND))
    if project:
        return _project_entry(data, spend_where(where), create=True).setdefault(scope, {})
    return data.setdefault("global", {}).setdefault(scope, {})


def cmd_spend(a):
    """The balance fetch of `show` runs before the home lock is taken (a network call never holds it)."""
    if getattr(a, "action", None) in (None, "show"):
        balance_refresh_stale(project_dir())
    return _cmd_spend(a)


@locked("home")
def _cmd_spend(a):
    """orch spend [show] | limit SCOPE USD|off [--project [PATH]] [--reset month|manual]
       | mode SCOPE stop|evaluate|continue [--lead] [--overrun PCT] [--project [PATH]]
       | reset SCOPE [--limit USD] [--project [PATH]]."""
    data, err = load_spend_limits()
    where = project_dir()
    action = getattr(a, "action", None)
    if action in (None, "show"):
        records, _ = spend_cache_update()
        canon = spend_where(where)
        labels = set((data.get("global") or {}).keys())
        labels |= set((_project_settings(data, canon) or {}).keys())
        labels |= set(api_scopes(where))
        labels |= {r.get("label") for r in records if r.get("label")}
        labels.discard("default")
        balances = balance_cache()
        print("Spend limits for API-billed executors (USD). `spent` is our estimate of orch's own runs (tokens × "
              "prices). `account` is the provider's figure for the whole account (orch balance), which can include "
              "spending outside orch.")
        print("%-18s %-11s %-11s %-18s %-10s %-10s %-24s %s" % ("scope", "spent", "limit", "account", "mode", "lead",
                                                                  "counter", ""))
        if err:
            print("  (%s — defaults shown)" % err)
        for scope in sorted(labels):
            eff = resolve_spend(data, scope, where)
            limit = _limit_number(eff)
            spent = current_spend(scope, where, records)
            shown_limit = "off" if limit is None else "%.2f" % limit
            ratio = ("%.0f%%" % (spent / limit * 100)) if limit and limit > 0 else "—"
            print("%-18s $%-10.2f $%-10s %-18s %-10s %-10s %-24s %s" % (
                scope_name(scope), spent, shown_limit, balance_cell(balances.get(scope)), eff.get("mode"),
                eff.get("lead_mode"), counter_cover(data, scope, where), ratio))
        for prov in sorted({s.split("@")[0].lower() for s in labels}):
            w = price_staleness(prov)
            if w:
                print("  ⚠ " + w)
        return 0
    if err:
        raise SystemExit("orch: %s — fix or remove it before changing limits" % err)
    scope = (a.scope or "").strip().lower()
    if scope != "default" and not valid_scope(scope):
        raise SystemExit("orch: scope is 'default', a provider, or <provider>@<profile>, got %r" % scope)
    proj_arg = getattr(a, "project", None)
    project = proj_arg is not None
    if project and isinstance(proj_arg, str) and proj_arg != ".":
        where = Path(proj_arg).resolve()          # --project PATH: another project's own counter
    where_ = "project " + canon_path(project_root(where)) if project else "global"
    if action == "limit":
        value = parse_limit(a.value)
        entry = _scope_entry(data, scope, where, project)
        entry["limit"] = "off" if value is None else value       # null would mean "unset": back to the default limit
        if getattr(a, "reset", None) in ("month", "manual"):
            entry["reset"] = a.reset
        save_spend_limits(data)
        print("%s limit %s: %s" % (scope_name(scope), where_, "off" if value is None else "$%.2f" % value))
    elif action == "mode":
        if a.value not in ("stop", "evaluate", "continue"):
            raise SystemExit("orch: mode is stop, evaluate or continue, got %r" % a.value)
        field = "lead_mode" if getattr(a, "lead", False) else "mode"
        entry = _scope_entry(data, scope, where, project)
        entry[field] = a.value
        overrun = getattr(a, "overrun", None)
        if overrun is not None:
            try:
                overrun = float(overrun)
                if overrun < 0:
                    raise ValueError
            except ValueError:
                raise SystemExit("orch: --overrun is a percentage, got %r" % a.overrun)
            entry["overrun"] = overrun
        save_spend_limits(data)
        print("%s %s %s: %s" % (scope_name(scope), where_, "lead mode" if field == "lead_mode" else "executor mode", a.value))
    elif action == "reset":
        canon = spend_where(where)
        if project and counter_key(data, scope, canon)[0] != canon and getattr(a, "limit", None) is None:
            raise SystemExit("orch: %s has no %s limit of its own — set one first: orch spend limit %s N --project"
                             % (where_, scope_name(scope), scope))
        owner = canon if project else counter_key(data, scope, canon)[0]
        spent = current_spend(scope, where)
        old_limit = _limit_number(resolve_spend(data, scope, where))
        kind = resolve_reset(data, scope, where)
        if getattr(a, "limit", None) is not None:
            new = parse_limit(a.limit)
            _scope_entry(data, scope, where, project)["limit"] = "off" if new is None else new
        _baseline_section(data, owner)[scope] = iso_precise(now())
        save_spend_limits(data)
        new_limit = _limit_number(resolve_spend(data, scope, where))
        old = "off" if old_limit is None else "$%.2f" % old_limit
        new = "off" if new_limit is None else "$%.2f" % new_limit
        owner_desc = "global" if owner == "global" else "project " + canon_path(project_root(where))
        print("%s reset: $%.2f spent, limit %s → %s, %s counter (%s)" %
              (scope_name(scope), spent, old, new, kind, owner_desc))
    return 0


# ───────────────────────── provider account balances ─────────────────────────
#
# What the account behind an API key really has left, read from the provider with that key. All keys of one account share
# the figure, and the account can be spent from outside orch, so it never stands for one key's spend. `orch spend` only
# estimates orch's own runs (tokens × prices); this is the provider's own figure. A provider is one fetch function and one BALANCE_PROVIDERS entry. Only what
# an ordinary key can read counts, and only DeepSeek offers it (GET /user/balance). OpenAI and Anthropic keep their
# billing and cost reports behind admin keys, and Google offers no balance API for the Gemini API or Vertex AI, so
# those scopes keep the estimate (`orch balance` says so). ~/.orchestra/balances.json keeps, per scope label,
# {amount, currency, at} and the last failure {error: {message, at}}; a failed fetch keeps the last amount. The key is
# never written anywhere, never printed, and no message contains it. The status line only reads that file.

class BalanceError(Exception):
    """A balance could not be read. The text is safe to show and to store: it never contains the key."""
    def __init__(self, message, rejected=False):
        Exception.__init__(self, message)
        self.rejected = rejected        # the provider refused the key (401/403): the caller names the variable


def balance_get(url, key, label):
    """GET `url` with the key as a bearer token → the parsed JSON object. Every failure is a BalanceError that says
    what went wrong without the key or the request headers; a redirect is never followed (it would carry the key on)."""
    import socket
    import urllib.error
    import urllib.request

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + key, "Accept": "application/json",
                                               "User-Agent": "orch"})
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=BALANCE_TIMEOUT) as r:
            raw = r.read(65536)
    except urllib.error.HTTPError as ex:
        if ex.code in (401, 403):
            raise BalanceError("%s rejected the key (HTTP %d)" % (label, ex.code), rejected=True)
        raise BalanceError("%s answered HTTP %d" % (label, ex.code))
    except urllib.error.URLError as ex:
        if isinstance(ex.reason, (socket.timeout, TimeoutError)):
            raise BalanceError("%s did not answer within %d s" % (label, BALANCE_TIMEOUT))
        raise BalanceError("cannot reach %s (%s)" % (label, type(ex.reason).__name__))
    except (socket.timeout, TimeoutError):
        raise BalanceError("%s did not answer within %d s" % (label, BALANCE_TIMEOUT))
    except Exception as ex:
        raise BalanceError("no usable answer from %s (%s)" % (label, type(ex).__name__))
    try:
        data = json.loads(raw.decode("utf-8"))
    except ValueError:
        raise BalanceError("%s sent an answer that is not JSON" % label)
    if not isinstance(data, dict):
        raise BalanceError("%s sent an unexpected answer" % label)
    return data


def deepseek_balance(key):
    """DeepSeek: GET /user/balance → {balance_infos: [{currency: CNY|USD, total_balance: "110.00", …}]}. The currency is
    the one DeepSeek reports (no conversion); with several, the first. ORCH_DEEPSEEK_BALANCE_URL replaces the URL."""
    url = os.environ.get("ORCH_DEEPSEEK_BALANCE_URL") or "https://api.deepseek.com/user/balance"
    data = balance_get(url, key, "DeepSeek")
    infos = data.get("balance_infos")
    for info in infos if isinstance(infos, list) else []:
        try:
            amount = float(info.get("total_balance"))
        except (AttributeError, TypeError, ValueError):
            continue
        currency = str(info.get("currency") or "").strip().upper()
        if currency and amount == amount and abs(amount) != float("inf"):
            return {"amount": amount, "currency": currency}
    raise BalanceError("DeepSeek sent a balance this version cannot read")


# provider → {fetch: key → {amount, currency}, key: the variable of the built-in profile, when that profile bills a key}
BALANCE_PROVIDERS = {
    "deepseek": {"fetch": deepseek_balance, "key": "DEEPSEEK_API_KEY"},
}
NO_BALANCE_API = "no balance API: see `orch spend`"


def balance_off():
    """ORCH_BALANCE=off: no balance request is ever made (orch balance included); the cache is still shown."""
    return os.environ.get("ORCH_BALANCE", "").strip().lower() in ("off", "0", "no", "false")


def money(amount, currency):
    """'$8.42', '¥110.00', '3.50 EUR': the currency the provider reported."""
    symbol = {"USD": "$", "CNY": "¥"}.get(str(currency).upper())
    text = "%.2f" % abs(amount)
    return ("-" if amount < 0 else "") + (symbol + text if symbol else "%s %s" % (text, currency))


def balance_cache():
    """{scope: entry} from balances.json; an unreadable file or an odd entry is no data (never an error)."""
    try:
        data = read_json(BALANCE_FILE, {})
    except StateError:
        return {}
    return {k: v for k, v in data.items() if isinstance(v, dict)}


def balance_known(entry):
    """(amount, currency) of a cache entry, or None when it holds no figure."""
    if not isinstance(entry, dict):
        return None
    amount, currency = entry.get("amount"), entry.get("currency")
    if isinstance(amount, (int, float)) and not isinstance(amount, bool) and isinstance(currency, str) and currency:
        return float(amount), currency
    return None


def balance_checked(entry):
    """When the provider was last asked about this scope, success or not (the later of `at` and the error's time)."""
    if not isinstance(entry, dict):
        return None
    times = [parse_iso(str(entry.get("at") or ""))]
    if isinstance(entry.get("error"), dict):
        times.append(parse_iso(str(entry["error"].get("at") or "")))
    times = [t for t in times if t is not None]
    return max(times) if times else None


def has_session_budget(prof):
    return prof.provider in BALANCE_PROVIDERS and any(prof.data.get(f) is not None for f in SESSION_BUDGET_FIELDS)


def session_budget_store():
    """Read and validate without repairing: a broken baseline must never silently reset a budget."""
    try:
        import math
        data = read_json(SESSION_BUDGET_FILE, {}, object_required=True)
        for sessions in data.values():
            if not isinstance(sessions, dict):
                raise ValueError("expected sessions by scope")
            for entry in sessions.values():
                if not isinstance(entry, dict) or not balance_known({"amount": entry.get("baseline"),
                        "currency": entry.get("currency")}) or not balance_known({"amount": entry.get("last"),
                        "currency": entry.get("currency")}) or not parse_iso(str(entry.get("at") or "")):
                    raise ValueError("invalid session baseline")
                if not all(math.isfinite(entry[f]) for f in ("baseline", "last")):
                    raise ValueError("invalid session baseline")
        return data
    except (StateError, ValueError, TypeError) as ex:
        warn_state(SESSION_BUDGET_FILE, str(ex))
        return None


def session_budget_record(prof):
    """Only hooks and run preflight write baselines. Lock, re-read, prune, then update this session."""
    sid = session_id()
    if not sid or not has_session_budget(prof) or balance_off():
        return True
    entry = balance_cache().get(prof.label)
    known = balance_known(entry)
    if not known or not parse_iso(str(entry.get("at") or "")) or balance_age(entry) or entry.get("error"):
        return False
    amount, currency = known
    try:
        with state_lock(ORCH_HOME / ".session_budget.lock"):
            data = session_budget_store()
            if data is None:
                return False
            cutoff = now() - dt.timedelta(days=SESSION_STATE_DAYS)
            data = {scope: {s: e for s, e in sessions.items() if parse_iso(e["at"]) >= cutoff}
                    for scope, sessions in data.items()}
            data = {scope: sessions for scope, sessions in data.items() if sessions}
            sessions = data.setdefault(prof.label, {})
            old = sessions.get(sid)
            if not old or old["currency"] != currency or round(amount - old["last"], 8) >= 0.01:
                new = {"baseline": amount, "currency": currency, "at": iso_precise(now()), "last": amount}
            else:
                new = dict(old, last=amount)
            if new == old:                # hooks run after every tool call: no change, no write
                return True
            sessions[sid] = new
            write_json(SESSION_BUDGET_FILE, data)
        _exhaustion_memo.clear()
        return True
    except (StateError, OSError) as ex:
        warn_state(SESSION_BUDGET_FILE, str(ex))
        return False


def session_budget_figure(prof):
    """The last known figure, however old: a balance only rises with a top-up, so age can't clear a budget and a failed
    read can't make a session flap. A run fetches a fresh one first; only a baseline insists on a recent figure."""
    if not has_session_budget(prof) or balance_off():
        return None
    entry = balance_cache().get(prof.label)
    known = balance_known(entry)
    if not known or not parse_iso(str(entry.get("at") or "")):
        return None
    amount, currency = known
    figure = {"amount": amount, "currency": currency}
    if session_id():
        data = session_budget_store()
        baseline = (data or {}).get(prof.label, {}).get(session_id())
        if data is None:
            return None
        if baseline and baseline["currency"] == currency and \
                parse_iso(baseline["at"]) >= now() - dt.timedelta(days=SESSION_STATE_DAYS):
            base = baseline["baseline"]
            down = max(base - amount, 0)
            figure.update(baseline=base, baseline_at=baseline["at"], down=down,
                          percent=round(100 * down / base, 10) if base > 0 else 0)
    return figure


def session_budget_settings(prof, currency="USD"):
    parts = []
    for field, name in (("session_soft", "soft"), ("session_hard", "hard")):
        if prof.data.get(field) is not None:
            parts.append("%s %g%%" % (name, prof.data[field]))
    if prof.data.get("balance_floor") is not None:
        parts.append("floor " + money(prof.data["balance_floor"], currency).replace(".00", ""))
    return ", ".join(parts)


def session_budget_text(prof, settings=True):
    fig = session_budget_figure(prof)
    if not fig:
        text = "no budget figure available"
    elif "baseline" in fig:
        text = "account down %s of %s (%.1f%%" % (money(fig["down"], fig["currency"]),
                money(fig["baseline"], fig["currency"]), fig["percent"])
        return text + ("; " + session_budget_settings(prof, fig["currency"]) if settings else "") + ")"
    else:
        text = "account " + money(fig["amount"], fig["currency"]) + "; no session baseline"
    return text + (" (" + session_budget_settings(prof, fig["currency"] if fig else "USD") + ")" if settings else "")


def session_budget_cause(prof, where):
    fig = session_budget_figure(prof)
    if not fig:
        return None
    floor = prof.data.get("balance_floor")
    if floor is not None and fig["amount"] <= floor:
        return "floor"
    if "percent" not in fig:
        return None
    hard, soft = prof.data.get("session_hard"), prof.data.get("session_soft")
    if hard is not None and fig["percent"] >= hard:
        return "session-hard"
    if soft is not None and fig["percent"] > soft and claude_budget(where)[0] != "tight":
        return "session-soft"
    return None


def session_budget_hooks(where):
    data, err = load_profiles()
    if err or balance_off():
        return
    for provider in managed_providers(data):
        try:
            prof = resolve_profile(provider, where, data=data, follow=False)
            if not has_session_budget(prof):
                continue
            session_budget_record(prof)
            active = resolve_profile(provider, where, data=data)
            if active.name != prof.name:
                session_budget_record(active)
        except ProfileError:
            continue


def session_budget_preflight(provider, where, override):
    """Fresh figures before a run. The configured key comes first even while the project is on its fallback, or a top-up
    would never bring it back; its failed read refuses only a run that would use it. Then a fallback's own budget."""
    configured = resolve_profile(provider, where, override, follow=False)
    prof = resolve_profile(provider, where, override)
    if balance_off():
        if has_session_budget(configured) or has_session_budget(prof):
            print("warning: ORCH_BALANCE=off — running with no session budget")
        return prof, None

    def refresh(target):
        var = target.data.get("key") or BALANCE_PROVIDERS[provider].get("key")
        results = balance_refresh([{"scope": target.label, "provider": provider, "var": str(var or "")}])
        data, error = results.get(target.label, (None, "no fresh balance"))
        fresh = not error and balance_known(data) and session_budget_record(target)
        _exhaustion_memo.clear()
        return fresh

    no_figure = "no fresh balance was available (or the session baseline is unreadable)"
    fresh = refresh(configured) if has_session_budget(configured) else True
    prof = resolve_profile(provider, where, override)
    if prof.label == configured.label:
        if not fresh:
            return prof, no_figure
    elif has_session_budget(prof) and not refresh(prof):
        return prof, no_figure
    cause = session_budget_cause(prof, where)
    if cause in ("floor", "session-hard"):
        return prof, "%s: %s" % (fallback_cause_words(cause), session_budget_text(prof))
    if cause == "session-soft":
        print("warning: %s is over its session budget; %s; no fallback move available" % (
              prof.label, session_budget_text(prof)))
    return prof, None


def balance_age(entry):
    """'3h ago' once a figure is older than BALANCE_FRESH_SECONDS, else ''."""
    at = parse_iso(str(entry.get("at") or "")) if isinstance(entry, dict) else None
    if at is not None and (now() - at).total_seconds() > BALANCE_FRESH_SECONDS:
        return human_delta(at)
    return ""


def balance_age_note(entry):
    """' (3h ago)' once a figure is older than BALANCE_FRESH_SECONDS, else ''."""
    age = balance_age(entry)
    return " (%s)" % age if age else ""


def balance_cell(entry):
    """The balance column of `orch spend`: '$8.42', '$8.42 (3h ago)', or '' where unknown."""
    known = balance_known(entry)
    return (money(*known) + balance_age_note(entry)) if known else ""


def balance_fragments(scopes, cache=None):
    """{scope: 'account $8.42, 3h ago'} for the scopes with a cached figure: the status line's read of the cache. The
    figure is the provider's balance of the whole account the key belongs to, not of the key."""
    scopes = [s for s in scopes if s.partition("@")[0] in BALANCE_PROVIDERS]
    if not scopes:
        return {}
    cache = balance_cache() if cache is None else cache
    out = {}
    for scope in scopes:
        known = balance_known(cache.get(scope))
        if known:
            age = balance_age(cache[scope])
            out[scope] = "account " + money(*known) + (", " + age if age else "")
    return out


API_KEYS_HEADING = ("API keys (spend and limit: our estimate of orch's own runs; account: the provider's figure, "
                    "for all keys of that account):")


def balance_status_lines(where):
    """`orch status`: a line per API-billed scope active in the directory, whether or not the provider has been asked —
    our estimate and limit (orch's own runs), and the provider's figure for the account with its age, the last failed
    fetch, or that the provider has no balance API. Never fails."""
    try:
        rows, cache = shown_api_scopes(where)
        if not rows:
            return []
        config = load_spend_limits()[0]
        lines = [API_KEYS_HEADING]
        for prof, scope, spent, limit, _ in rows:
            ours = "est. $%.2f" % spent
            ours += (" of " + limit_text(limit)) if limit is not None else ", limit off"
            ours += " (%s)" % counter_cover(config, scope, where)
            parts = [ours]
            entry = cache.get(scope)
            if scope.partition("@")[0] not in BALANCE_PROVIDERS:
                parts.append("no balance API")
            else:
                known = balance_known(entry)
                if known:
                    at = parse_iso(str(entry.get("at") or ""))
                    parts.append("account " + money(*known) + (" (checked %s)" % human_delta(at) if at else ""))
                elif not isinstance(entry, dict):
                    parts.append("account balance not fetched yet")
                else:
                    parts.append("account balance unknown")
                err = entry.get("error") if isinstance(entry, dict) else None
                if isinstance(err, dict) and err.get("message"):
                    parts.append("last fetch failed: %s" % err["message"])
            if has_session_budget(prof):
                parts.append("session: " + session_budget_text(prof))
            lines.append("  %-18s %s" % (scope_name(scope), " · ".join(parts)))
            if prof.fallback_from:
                configured = resolve_profile(prof.provider, where, follow=False)
                if has_session_budget(configured):
                    lines.append("  %-18s session: %s" % (scope_name(configured.label), session_budget_text(configured)))
        return lines
    except Exception:
        return []


def balance_secret(var, secrets):
    """The key's value the way a run resolves it: the environment first, then secrets.env."""
    return os.environ.get(var) or secrets.get(var)


def balance_targets(data=None):
    """[{scope, provider, var}]: a profile with a `key` (any provider: an unsupported one is reported as such), and the
    built-in profile of a supported provider that bills a key, when its variable is set."""
    if data is None:
        data = load_profiles()[0]
    out, secrets = [], None
    for provider in data["providers"]:
        for name, d in provider_section(data, provider)[1].items():
            if isinstance(d, dict) and d.get("key"):
                out.append({"scope": "%s@%s" % (provider.lower(), name), "provider": provider.lower(),
                            "var": str(d["key"])})
    for provider, spec in BALANCE_PROVIDERS.items():
        # a profile already holding the variable is the same account: one row and one request, not two
        if spec.get("key") and not any(t["provider"] == provider and t["var"] == spec["key"] for t in out):
            secrets = load_secrets() if secrets is None else secrets
            if balance_secret(spec["key"], secrets):
                out.append({"scope": provider, "provider": provider, "var": spec["key"]})
    return out


def balance_active_targets(where):
    """The targets with a balance API among the API-billed scopes active in a directory (a fallback included). The
    built-in profile counts only when its key variable is set, so a provider nobody uses stays silent."""
    out, secrets = [], None
    for prof, scope in active_profiles(where):
        spec = BALANCE_PROVIDERS.get(prof.provider)
        if not scope or spec is None:
            continue
        var = prof.data.get("key") if prof.explicit else spec.get("key")
        if not var:
            continue
        if not prof.explicit:
            secrets = load_secrets() if secrets is None else secrets
            if not balance_secret(var, secrets):
                continue
        out.append({"scope": scope, "provider": prof.provider, "var": str(var)})
    return out


def balance_fetch_all(targets):
    """Ask the providers about these targets at once (a thread each), the whole call bounded by one timeout.
    → {scope: (data, error)}: data {amount, currency} or None, error a text or None. No lock is held and nothing is
    stored here. The key is read, used for the request and dropped; error texts are scrubbed of it."""
    import threading
    secrets = load_secrets()
    results, pending = {}, []
    for t in targets:
        spec = BALANCE_PROVIDERS.get(t["provider"])
        if spec is None:
            continue
        key = balance_secret(t["var"], secrets)
        if not key:
            results[t["scope"]] = (None, "%s is neither in the environment nor in %s" % (t["var"], SECRETS_FILE))
            continue
        box = {}

        def work(fn=spec["fetch"], key=key, box=box):
            try:
                box["data"] = fn(key)
            except BalanceError as ex:
                box["error"], box["rejected"] = str(ex), ex.rejected
            except Exception as ex:
                box["error"] = "unexpected failure (%s)" % type(ex).__name__
        th = threading.Thread(target=work)
        th.daemon = True
        th.start()
        pending.append((t, key, box, th))
    deadline = time.monotonic() + BALANCE_TIMEOUT + 1
    for t, key, box, th in pending:
        th.join(max(0.0, deadline - time.monotonic()))
        data, error = box.get("data"), box.get("error")
        if th.is_alive():
            error = "%s did not answer within %d s" % (display_name(t["provider"]), BALANCE_TIMEOUT)
        elif error is None and not balance_known(data):
            error = "%s sent a balance this version cannot read" % display_name(t["provider"])
        if error is not None:
            data = None
            if box.get("rejected"):
                error += ": check %s" % t["var"]
            error = error.replace(key, "…")
        results[t["scope"]] = (data, error)
    return results


@locked("home")
def balance_store(results):
    """Write fetch results into balances.json, re-reading it under the lock: a figure replaces the entry; a failure
    keeps the last amount and records the error with its time. Held only for the write, never during a request."""
    cache = read_json(BALANCE_FILE, {}, recover_corrupt=True)
    stamp = iso(now())
    for scope, (data, error) in results.items():
        old = cache.get(scope) if isinstance(cache.get(scope), dict) else {}
        if data is not None:
            cache[scope] = {"amount": data["amount"], "currency": data["currency"], "at": stamp}
        else:
            entry = {k: old[k] for k in ("amount", "currency", "at") if k in old}
            entry["error"] = {"message": error, "at": stamp}
            cache[scope] = entry
    write_json(BALANCE_FILE, cache)


def balance_refresh(targets):
    """Fetch and store; a failure of any kind is swallowed (it shows as staleness). → the fetch results."""
    try:
        results = balance_fetch_all(targets)
        if results:
            balance_store(results)
        return results
    except Exception:
        return {}


def balance_stale(targets, cache):
    """True when some target has not been asked about for BALANCE_STALE_SECONDS (a failed ask counts as asked)."""
    for t in targets:
        at = balance_checked(cache.get(t["scope"]))
        if at is None or (now() - at).total_seconds() > BALANCE_STALE_SECONDS:
            return True
    return False


def balance_refresh_stale(where):
    """`orch status` and `orch spend show`: fetch the active scopes whose figure is stale, bounded by the timeout.
    Never fails, and does nothing in a worker or with ORCH_BALANCE=off."""
    if balance_off() or os.environ.get("ORCH_WORKER"):
        return
    try:
        cache = balance_cache()
        stale = [t for t in balance_active_targets(where) if balance_stale([t], cache)]
    except Exception:
        return
    if stale:
        balance_refresh(stale)


def balance_start_refresh(where):
    """SessionStart: when a balance is stale, start `orch balance --quiet` detached and go on at once. The child has
    no console window (Windows) or its own session (POSIX), no inherited stdio, and outlives the hook."""
    if balance_off() or os.environ.get("ORCH_WORKER"):
        return
    try:
        if not balance_stale(balance_active_targets(where), balance_cache()):
            return
        import subprocess
        kw = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "close_fds": True}
        if IS_WINDOWS:
            kw["creationflags"] = 0x00000008 | 0x00000200 | 0x08000000   # DETACHED_PROCESS | NEW_PROCESS_GROUP | NO_WINDOW
        else:
            kw["start_new_session"] = True
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "balance", "--quiet"], **kw)
    except Exception:
        pass


def balance_refresh_run(prof):
    """End of `orch run`: read the account balance behind the run's key. Never fails, never delays more than the timeout."""
    if balance_off() or os.environ.get("ORCH_WORKER"):
        return
    try:
        spec = BALANCE_PROVIDERS.get(prof.provider)
        var = (prof.data.get("key") if prof.explicit else spec.get("key")) if spec else None
        if var:
            balance_refresh([{"scope": prof.label, "provider": prof.provider, "var": str(var)}])
    except Exception:
        pass


def balance_row(target, entry):
    """One scope as shown by `orch balance` and as its --json object (variable names only, never a key)."""
    supported = target["provider"] in BALANCE_PROVIDERS
    row = {"scope": target["scope"], "provider": target["provider"], "key_variable": target["var"],
           "supported": supported, "amount": None, "currency": None, "checked_at": None, "error": None,
           "error_at": None, "note": None if supported else NO_BALANCE_API}
    if not supported or not isinstance(entry, dict):
        return row
    known = balance_known(entry)
    if known:
        row["amount"], row["currency"], row["checked_at"] = known[0], known[1], entry.get("at")
    if isinstance(entry.get("error"), dict):
        row["error"], row["error_at"] = entry["error"].get("message"), entry["error"].get("at")
    return row


def cmd_balance(a):
    """orch balance [SCOPE …] [--json] [--quiet]: ask each provider for the balance of the account behind every API
    key (a profile with a `key`, DeepSeek's built-in key) and keep it for status, spend and the status line. Keys of
    one account share the figure. Exit 1 when a fetch
    failed (the last amount is kept); --quiet prints nothing and always exits 0."""
    if os.environ.get("ORCH_WORKER"):
        if a.quiet:
            return 0
        raise SystemExit("orch: you are an executor (ORCH_WORKER) — only the orchestrator reads balances")
    if balance_off():
        if not a.quiet:
            print("[]" if a.json else "Balance checks are off (ORCH_BALANCE=off): nothing was fetched.")
        return 0
    data, err = load_profiles()
    if err and not a.quiet:
        print("orch: warning: %s" % err, file=sys.stderr)
    targets = balance_targets(data)
    if a.scopes:
        want = [s.strip().lower() for s in a.scopes]
        unknown = [s for s in want if s not in {t["scope"] for t in targets}]
        if unknown and not a.quiet:
            raise SystemExit("orch: no API key for %s (orch balance lists the keys it knows)" % ", ".join(unknown))
        targets = [t for t in targets if t["scope"] in want]
    results = {}
    try:
        results = balance_fetch_all([t for t in targets if t["provider"] in BALANCE_PROVIDERS])
        if results:
            balance_store(results)
    except Exception:
        if not a.quiet:
            raise
    if a.quiet:
        return 0
    cache = balance_cache()
    rows = [balance_row(t, cache.get(t["scope"])) for t in targets]
    failed = any(got is None for got, _ in results.values())
    if a.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 1 if failed else 0
    if not rows:
        print("No API keys: DeepSeek (DEEPSEEK_API_KEY in %s or the environment) or a profile with a key "
              "(orch profile set <provider> <name> --key VAR)." % SECRETS_FILE)
        return 0
    print("Account balances: the provider's own figure for the account a key belongs to, shared by all its keys "
          "(`orch spend` shows our estimate of orch's own runs).")
    width = max([len("key variable")] + [len(row["key_variable"] or "") for row in rows])
    print("%-20s %-*s %-16s %-12s %s" % ("scope", width, "key variable", "account balance", "checked", ""))
    for row in rows:
        shown = money(row["amount"], row["currency"]) if row["amount"] is not None else "—"
        at = parse_iso(str(row["checked_at"] or ""))
        note = row["note"] or ("error: %s" % row["error"] if row["error"] else "")
        print("%-20s %-*s %-16s %-12s %s" % (scope_name(row["scope"]), width, row["key_variable"], shown,
                                             human_delta(at) if at else "—", note))
    return 1 if failed else 0


# ───────────────────────── run (automated adapters) ─────────────────────────

LIMIT_PATTERNS = [
    r"usage limit", r"rate[ _-]?limit", r"\b429\b", r"too many requests", r"quota",
    r"limit (?:has been )?(?:reached|exceeded)", r"exceeded your", r"out of credits",
]
UNTIL_IN = re.compile(r"(?:try again|retry|resets?|available again)\s+in\s+(?:about\s+)?(\d+)\s*(second|sec|minute|min|hour|hr|day|h|m|d)s?", re.I)
UNTIL_AT = re.compile(r"(?:try again|retry|resets?|available again)\s+(?:at|after)\s+(\d{1,2}):(\d{2})\s*(am|pm)?", re.I)


def detect_limit(text):
    low = text.lower()
    if not any(re.search(p, low) for p in LIMIT_PATTERNS):
        return (False, None)
    m = UNTIL_IN.search(text)
    if m:
        n, u = int(m.group(1)), m.group(2).lower()
        secs = n * (60 if u.startswith("m") else 3600 if u.startswith("h") else 86400 if u.startswith("d") else 1)
        return (True, now() + dt.timedelta(seconds=secs))
    m = UNTIL_AT.search(text)
    if m:
        h, mi, ap = int(m.group(1)), int(m.group(2)), (m.group(3) or "").lower()
        if ap == "pm" and h < 12:
            h += 12
        if ap == "am" and h == 12:
            h = 0
        t = now().replace(hour=h, minute=mi, second=0, microsecond=0)
        if t <= now():
            t += dt.timedelta(days=1)
        return (True, t)
    return (True, None)


def find_adapter(provider):
    for base in (ORCH_HOME / "adapters", PLUGIN_ROOT / "adapters"):
        p = base / provider
        if p.exists():
            return p
    return None


def adapter_head(adapter, lines=40):
    try:
        with open(str(adapter), encoding="utf-8", errors="replace") as f:
            return "".join(f.readline() for _ in range(lines))
    except OSError:
        return ""


def adapter_directives(head):
    """'# orch-secrets: A B' / '# orch-limit-detect: exit-code' comments in an adapter's header."""
    return {m.group(1): m.group(2).strip() for m in re.finditer(r"^#\s*orch-([a-z-]+):\s*(.+)$", head, re.M)}


def adapter_command(adapter, head):
    """Python adapters → this interpreter; shell adapters → bash (Git Bash on Windows)."""
    if adapter.suffix == ".py" or (head.startswith("#!") and "python" in head.splitlines()[0]):
        return [sys.executable, str(adapter)]
    if not IS_WINDOWS and os.access(str(adapter), os.X_OK):
        return [str(adapter)]
    bash = find_bash()
    if not bash:
        raise SystemExit("orch: bash not found for adapter %s (Windows needs Git for Windows; the path can be set "
                         "in CLAUDE_CODE_GIT_BASH_PATH)" % adapter)
    return [bash, str(adapter)]


SECRETS_FILE = ORCH_HOME / "secrets.env"


def load_secrets():
    """KEY=value lines of ~/.orchestra/secrets.env (API keys for adapters; never stored in a repository)."""
    try:
        text = SECRETS_FILE.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError):
        return {}
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].strip()
        k, sep, v = line.partition("=")
        k, v = k.strip(), v.strip()
        if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
            continue
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        out[k] = v
    return out


# Variables of the orchestrating Claude Code session (messaging socket and token, session id, effort, …) must not
# reach a worker: a nested `claude` would attach to our session, and for any other CLI they are just leaked secrets.
KEEP_CLAUDE_VARS = ("CLAUDE_CODE_GIT_BASH_PATH", "CLAUDE_CONFIG_DIR")
# The operator's own API credentials must not leak into a worker either: a login-profile worker would silently
# switch to API billing on the operator's key. A profile's own key re-enters via `extra` (its declared secret name).
WORKER_LEAK_VARS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY")


def anthropic_key_var(name):
    """An operator Anthropic credential beyond the four in WORKER_LEAK_VARS (a gateway/foundry key, a token)."""
    return name.startswith("ANTHROPIC_") and (name.endswith("_API_KEY") or name.endswith("_AUTH_TOKEN"))


def lead_vars():
    """Variables a non-Claude lead (orch launch) set for its own session: endpoint, token, models."""
    return {v for v in os.environ.get("ORCH_LEAD_ENV", "").split(",") if v}


def worker_env(extra, secrets=()):
    lead = lead_vars()          # a DeepSeek lead's endpoint and token are not the worker's business
    keep = set(secrets)         # names the adapter declares (# orch-secrets, not explicit): the real env wins
    drop = set(WORKER_LEAK_VARS) | profile_key_vars()
    env = {}
    for k, v in os.environ.items():
        if k in lead:
            continue
        if k in KEEP_CLAUDE_VARS:
            env[k] = v
            continue
        if k == "CLAUDECODE" or k.startswith("CLAUDE_"):
            continue
        if k in keep or not (k in drop or anthropic_key_var(k)):
            env[k] = v
    stored = load_secrets() if secrets else {}
    for name in secrets:          # only the keys the adapter declares (# orch-secrets: …), real environment wins
        if name in stored and not env.get(name):
            env[name] = stored[name]
    env.update(extra)
    return env


WORKER_BRIEF = """# Role: Orchestra executor ({provider} · {model} · effort {effort} · mode {mode})

You are an executor in the Orchestra system. Tasks are assigned by the orchestrator — another Claude Code
instance that talks to the operator. It gives you exactly one subtask. You do not see its conversation,
and the operator does not talk to you directly: your only reader is the orchestrator, and it checks the
result itself (diff, tests) before accepting it.

Rules:
- Do exactly what the task says: do not widen the scope, do not touch files beyond the ones named.
- Work only in the working directory: {cwd}
- {mode_rule}
- Do not commit, push or switch branches unless the task explicitly requires it.
- Do not delegate or start other executors (`orch run`, `orch handoff`, other CLI agents): the orchestrator decides.
- If the task is unclear or contradicts the code, do not guess: STATUS: BLOCKED with questions under "Blockers".
- If permissions deny an action, you may do the same thing by allowed means (e.g. search with a tool
  instead of a command), but do not work around the restriction itself. If you need a command (tests, build),
  name it under "Blockers" and the orchestrator will grant it.
- You already run in the working directory. Run an allowed command on its own, without `cd`, `git -C`, `&&`, `;` or
  pipes around it: a permission rule matches the command as written, and a wrapped command is denied.
- Verify the result yourself (build, tests) if the task and your permissions allow it.

Reply to the orchestrator (your last message) — brief, strictly in this form:
STATUS: DONE | PARTIAL | BLOCKED
## Done
## Changed files
## Verification  (commands and outcome)
## Blockers / questions
"""
MODE_RULES = {
    "analysis": "analysis mode: read and analyse only — do not change files.",
    "write": "write mode: you may change files inside the working directory.",
}


def win_job(proc):
    """Windows: put the (suspended) adapter into a kill-on-close job object, then resume it.
    Git Bash/MSYS children lose their parent-PID chain, so taskkill /T misses them; a job holds every
    descendant, and because it is closed when orch exits, workers die with orch even if orch is killed."""
    import ctypes
    from ctypes import wintypes

    class Basic(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                    ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                    ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                    ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]

    class Extended(ctypes.Structure):
        _fields_ = [("Basic", Basic), ("Io", ctypes.c_ulonglong * 6), ("ProcessMemoryLimit", ctypes.c_size_t),
                    ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                    ("PeakJobMemoryUsed", ctypes.c_size_t)]

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    handle = int(proc._handle)          # full-access handle owned by Popen
    job = None
    try:
        job = k32.CreateJobObjectW(None, None)
        info = Extended()
        info.Basic.LimitFlags = 0x2000                       # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not (job and k32.SetInformationJobObject(wintypes.HANDLE(job), 9, ctypes.byref(info), ctypes.sizeof(info))
                and k32.AssignProcessToJobObject(wintypes.HANDLE(job), wintypes.HANDLE(handle))):
            job = None
    except Exception:
        job = None
    finally:
        ctypes.WinDLL("ntdll").NtResumeProcess(wintypes.HANDLE(handle))   # never leave the adapter suspended
    return job


def kill_tree(proc, job=None):
    """Stop the adapter and everything it started (codex, claude, test runs): an orphaned agent keeps spending."""
    import signal
    import subprocess
    try:
        if IS_WINDOWS:
            import ctypes
            if not (job and ctypes.WinDLL("kernel32").TerminateJobObject(ctypes.c_void_p(job), 1)):
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=30)
        else:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            os.killpg(proc.pid, signal.SIGKILL)
    except Exception:
        pass
    try:
        proc.kill()
        proc.wait(timeout=10)
    except Exception:
        pass


def cmd_run(a):
    import signal
    import subprocess
    if os.environ.get("ORCH_WORKER"):
        raise SystemExit("orch: you are an executor (ORCH_WORKER=%s) — nested delegation is not allowed, "
                         "return your result to the orchestrator" % os.environ["ORCH_WORKER"])
    provider = a.provider.lower()
    adapter = find_adapter(provider)
    if adapter is None:
        raise SystemExit("orch: no adapter for %r (looked in %s/adapters and %s/adapters)" % (provider, ORCH_HOME, PLUGIN_ROOT))
    head = adapter_head(adapter)
    directives = adapter_directives(head)
    command = adapter_command(adapter, head)
    cwd = Path(a.cd).resolve() if a.cd else project_dir()
    # profile of the project the worker works on: off / allowed models, write, effort cap / key or account
    try:
        prof, budget_denied = session_budget_preflight(provider, cwd, a.profile)
        if budget_denied:
            print("[SESSION_BUDGET] %s — %s. Take the fallback; do not work around it." % (prof.label, budget_denied))
            ledger_append({"kind": "run", "session": session_id(), "project": canon_path(project_root(cwd)),
                           "provider": provider, "label": prof.label, "model": a.model, "mode": a.mode,
                           "status": "SESSION_BUDGET", "cost_usd": 0, "elapsed_s": 0})
            return EXIT_QUOTA
        if prof.name == "off":
            print("PROFILE_OFF %s — executor disabled by the profile (%s) for %s." % (
                provider, prof.source, canon_path(project_root(cwd))))
            print("Assign the task to another provider. To enable: orch profile use %s <profile>." % provider)
            return EXIT_QUOTA
        model, effort, notes, denied = profile_limits(prof, a.model, a.effort, a.mode)
        if denied:
            print("PROFILE_DENIED %s — %s (%s)." % (prof.label, denied, prof.source))
            print("Pick a slot the profile allows (orch profile show) or another provider.")
            return EXIT_QUOTA
        declared = directives.get("secrets", "").split()
        secret_env, remaining = profile_secret(prof, declared)
        secret_names = fallback_secret_names(directives, remaining)
    except ProfileError as ex:
        print("PROFILE_ERROR %s — %s" % (provider, ex))
        return 1
    key_var = prof.data.get("key") if prof.explicit else None    # the run's own API key variable (--profile honoured)
    key = prof.label + ("/" + model if model else "")
    ok, e, k = availability(key)
    if not ok and not a.force:
        print("%s %s — %s" % (availability_status(e), key, describe_entry(k, e)))
        print("Pick a fallback from the registry or wait for the reset (orch quota show).")
        return EXIT_QUOTA

    scope = profile_api_scope(prof, provider, cwd)          # the spend scope, or None when not API-billed
    billing = "api" if scope else "subscription"
    spend_base = spend_kill = None
    if scope:
        allowed, line = spend_start(scope, cwd)
        if line:
            print(line)
        if not allowed:                                      # like profile max_open: --force does not bypass
            return EXIT_QUOTA
        eff = resolve_spend(load_spend_limits()[0], scope, cwd)
        spend_base = current_spend(scope, cwd)               # the counter before this run; live usage is added
        spend_kill = spend_kill_at(eff)

    if a.prompt_file:
        prompt = Path(a.prompt_file).read_text(encoding="utf-8")
    elif a.prompt:
        prompt = " ".join(a.prompt)
    elif not sys.stdin.isatty():
        prompt = sys.stdin.read()
    else:
        raise SystemExit("orch: no prompt (pass text, --prompt-file or stdin)")
    if not prompt.strip():
        raise SystemExit("orch: empty prompt")

    handoff = a.handoff.upper() if a.handoff else None
    if handoff:
        load_meta(handoff)                 # a reclaimed pooled task this run executes: must exist
    run_id = "%s-%s-%s" % (provider[:3], now().strftime("%m%d-%H%M%S"), rand_suffix())
    run_dir = state_dir() / "runs" / run_id
    run_dir.mkdir(parents=True)
    (run_dir / "prompt.md").write_text(prompt, encoding="utf-8")
    out_file = run_dir / "output.md"
    log_file = run_dir / "log.txt"
    task = task_title(prompt, a.task)
    meta = {"id": run_id, "provider": provider, "profile": prof.name if prof.explicit else None,
            "profile_source": prof.source, "model": model, "effort": effort, "mode": a.mode, "task": task,
            "session": session_id(), "cwd": str(cwd), "started": iso(now()), "adapter": str(adapter),
            "allow": a.allow or []}
    write_json(run_dir / "meta.json", meta)
    role_file = run_dir / "role.md"
    role_file.write_text(WORKER_BRIEF.format(provider=provider, model=model or "default model",
                                             effort=effort or "default", mode=a.mode, cwd=cwd,
                                             mode_rule=MODE_RULES[a.mode]), encoding="utf-8")
    context = build_context(cwd, directives.get("context-native", "").split(), run_dir / "context.md")

    extra = {"ORCH_MODEL": model or "", "ORCH_EFFORT": effort or "", "ORCH_MODE": a.mode,
             "ORCH_CWD": str(cwd), "ORCH_PROMPT_FILE": str(run_dir / "prompt.md"),
             "ORCH_OUTPUT_FILE": str(out_file), "ORCH_RUN_DIR": str(run_dir),
             "ORCH_ROLE_FILE": str(role_file), "ORCH_CONTEXT_FILE": str(context) if context else "",
             "ORCH_ALLOW": "\n".join(a.allow or []),
             "ORCH_HOME": str(ORCH_HOME), "ORCH_WORKER": run_id, "ORCH_PROFILE": prof.name if prof.explicit else ""}
    extra.update(profile_env(prof, directives))     # profile fields the adapter declares (CODEX_HOME, …)
    extra.update(secret_env)                         # the profile's key under the adapter's secret name
    env = worker_env(extra, secrets=secret_names)
    timeout = parse_duration(a.timeout) if a.timeout else None
    # own process group (POSIX) / kill-on-close job (Windows, started suspended until it is in the job):
    # on timeout or stop the whole tree goes, not just the adapter
    detach = ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP | 0x4} if IS_WINDOWS   # | CREATE_SUSPENDED
              else {"start_new_session": True})
    consumer = "run:" + run_id if provider == "claude" and not key_var else None
    if consumer:
        try:
            heartbeat(consumer, cwd, kind="executor")
        except Exception:
            consumer = None
    t0 = time.time()
    state = {"interrupted": None}       # SIGTERM/SIGHUP signum, or "keyboard"
    with log_file.open("w", encoding="utf-8") as log:
        try:
            proc = subprocess.Popen(command, env=env, cwd=str(cwd), stdout=log, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, **detach)
        except OSError as ex:
            raise SystemExit("orch: cannot start adapter %s: %s" % (adapter, ex))
        job = win_job(proc) if IS_WINDOWS else None

        def stop(signum, frame):
            kill_tree(proc, job)
            state["interrupted"] = signum
        for name in ("SIGTERM", "SIGHUP"):
            if hasattr(signal, name):
                signal.signal(getattr(signal, name), stop)
        deadline = (time.time() + timeout) if timeout else None
        spend_killed = False
        try:
            while True:
                wait = SPEND_POLL_SECONDS
                if deadline:
                    remaining = deadline - time.time()
                    if remaining <= 0:
                        kill_tree(proc, job)
                        rc = EXIT_TIMEOUT
                        log.write("\n[orch] killed after timeout %ss\n" % timeout)
                        break
                    wait = min(wait, remaining)
                try:
                    rc = proc.wait(timeout=wait)
                    kill_tree(proc, job)   # reap what the worker left behind (e.g. codex's Windows sandbox helper)
                    break
                except subprocess.TimeoutExpired:
                    try:
                        if scope and spend_kill is not None:
                            try:
                                live = live_usage(run_dir, provider, cwd, prof)
                            except Exception:
                                continue      # a half-written usage_live.json / unreadable rollout skips one poll
                            if live and spend_base + usage_cost(live, provider, model) >= spend_kill:
                                kill_tree(proc, job)
                                rc = EXIT_QUOTA
                                spend_killed = True
                                log.write("\n[orch] killed: spend limit reached (%s)\n" % scope)
                                break
                    except KeyboardInterrupt:      # a Ctrl-C during the poll must stop the run, not escape the handler
                        kill_tree(proc, job)
                        state["interrupted"] = "keyboard"
                        break
                except KeyboardInterrupt:
                    kill_tree(proc, job)
                    state["interrupted"] = "keyboard"
                    break
        finally:
            kill_tree(proc, job)         # an orphaned agent keeps spending; kill it whatever happened
    if state["interrupted"] == "keyboard":
        rc = 130
    elif isinstance(state["interrupted"], int):
        rc = 128 + state["interrupted"]
    elapsed = int(time.time() - t0)
    if consumer:
        try:
            forget(consumer)
        except Exception:
            pass
    log_text = log_file.read_text(encoding="utf-8", errors="replace")

    output = out_file.read_text(encoding="utf-8", errors="replace") if out_file.exists() else ""
    report = re.search(r"^[ \t]*STATUS:[ \t]*(DONE|BLOCKED|PARTIAL)\b", output, re.M)
    status = (report.group(1) if report and report.group(1) != "DONE" else "OK") if rc == 0 else "FAILED"
    if spend_killed:
        status = "SPEND_LIMIT"
    quota_note = ""
    if rc != 0 and rc != EXIT_TIMEOUT and not spend_killed:
        # adapters that report limits themselves opt out of scanning the log (worker output may mention "quota")
        scan = directives.get("limit-detect") != "exit-code"
        hit, until = (True, None) if rc == EXIT_QUOTA else detect_limit(log_text) if scan else (False, None)
        qfile = run_dir / "quota_until"
        manual = False
        if qfile.exists():
            qtext = qfile.read_text(encoding="utf-8", errors="replace").strip()
            manual = qtext.lower() in ("manual", "none", "never")
            try:
                until = (None if manual else parse_until(qtext)) or until
            except SystemExit:
                pass
        if hit:
            kind_file = run_dir / "quota_kind"
            capacity = kind_file.exists() and kind_file.read_text(encoding="utf-8", errors="replace").strip() == "capacity"
            status = "CAPACITY" if capacity else "QUOTA_EXHAUSTED"
            # An adapter may narrow an availability failure to the selected model (never widen its scope).
            scoped_model = read_json(run_dir / "quota_model.json", None)
            block = (prof.label + "/" + scoped_model if isinstance(scoped_model, str) and scoped_model
                     else prof.label if a.quota_scope == "provider" else key)
            if manual:
                quota_note = " (no timed reset — after topping up: orch quota clear %s)" % block
            elif until is None:
                until = now() + dt.timedelta(minutes=a.quota_backoff)
                quota_note = " (reset time not recognised — rechecking in %d min)" % a.quota_backoff
            if scoped_model == "":
                quota_note = " (model id unknown — no availability block recorded)"
            else:
                set_avail(block, "busy" if capacity else "exhausted", until,
                          ("auto: model at capacity at the provider, not a limit (%s)" if capacity else
                           "auto: limit detected in the output of %s") % run_id, source="auto")
            rc = EXIT_QUOTA
    if rc == EXIT_TIMEOUT:
        status = "TIMEOUT"

    usage = None
    try:
        usage = read_usage(run_dir)
    except Exception:
        usage = None
    if not usage:
        try:
            usage = live_usage(run_dir, provider, cwd, prof)
        except Exception:
            usage = None
    # the cost is frozen at run time (peak/off-peak and dated prices as of now); later price changes don't rewrite it.
    # A corrupt usage file or bad price data must not lose the ledger line: keep the tokens, price 0, and say so.
    run_cost = 0.0
    cost_note = ""
    if usage:
        try:
            run_cost = usage_cost(usage, provider, usage.get("model") or model)
        except Exception:
            cost_note = " (cost not priced)"
    run_cost_as_of = price_as_of(provider)
    meta.update({"finished": iso(now()), "elapsed_s": elapsed, "exit": rc, "status": status, "usage": usage,
                 "billing": billing})
    write_json(run_dir / "meta.json", meta)
    proj = project_root(cwd)
    ledger_append({"kind": "run", "session": meta["session"], "project": canon_path(proj), "project_path": str(proj),
                   "id": run_id, "provider": provider, "label": prof.label,
                   "model": (usage or {}).get("model") or model, "effort": effort, "mode": a.mode, "task": task,
                   "status": status, "elapsed_s": elapsed, "usage": usage, "handoff": handoff, "billing": billing,
                   "cost_usd": run_cost, "cost_as_of": run_cost_as_of})
    if handoff and status == "OK":
        finish_reclaimed(handoff, "DONE", run_id)     # frees the one-at-a-time slot of the pool
    elif handoff and status in ("PARTIAL", "BLOCKED"):
        print("The reclaimed task slot stays busy until orch handoff done %s." % handoff)

    if not output.strip() and rc == 0:
        output = log_text[-a.max_chars:]
    shown = display_name(model) or ("(default: %s)" % display_name(usage["model"])
                                    if usage and usage.get("model") else "(default)")
    usage_note = (" · " + usage_brief(usage) + cost_note) if usage else cost_note
    print("[%s] %s · %s %s effort=%s mode=%s · %ds%s" % (status, run_id, scope_name(prof.label), shown,
                                                       effort or "(default)", a.mode, elapsed, usage_note))
    if prof.explicit:
        print("profile %s (%s)%s" % (scope_name(prof.label), prof.source, ("; " + "; ".join(notes)) if notes else ""))
    if status == "QUOTA_EXHAUSTED":
        print("Limit exhausted (subscription or balance), recorded in orch quota%s. Reassign the task to a fallback."
              % quota_note)
    if status == "CAPACITY":
        scope_note = ("no availability block was recorded because the model id is unknown" if scoped_model == "" else
                      "only this model is blocked until %s" % until.astimezone().strftime("%H:%M"))
        print("Model at capacity at the provider, not your limit; %s. Take a fallback or another model of the provider. "
              "Whatever the run already changed stays in its folder: check it before running the task again." % scope_note)
    if status == "SPEND_LIMIT":
        config = load_spend_limits()[0]
        print("Spend limit reached (%s; %s) — %s." % (scope_name(scope), counter_cover(config, scope, cwd),
                                                      _way_out(config, scope, cwd)))
    body = output if output.strip() else log_text
    if len(body) > a.max_chars:
        body = body[:a.max_chars] + "\n…[truncated, full text: %s]" % (out_file if output.strip() else log_file)
    print(body.rstrip())
    print("\n-- files: %s (output) · %s (log)" % (out_file, log_file))
    if provider == "codex" and not key_var:
        try:
            refresh_codex(cwd, force=True, prof=prof)   # the run just spent the Codex limits: read the freshest numbers
        except Exception:
            pass
    if scope:
        balance_refresh_run(prof)                       # the run just spent the key's money: read what is left
    return rc


# ───────────────────────── a non-Claude lead (orch launch) ─────────────────────────

SECRET_VAR_RE = re.compile(r"KEY|TOKEN|SECRET|PASSWORD", re.I)


def masked(name, value):
    return (value[:4] + "…" + value[-2:] if len(value) > 10 else "…") if SECRET_VAR_RE.search(name) else value


def lead_line():
    """'Lead: DeepSeek@work · DeepSeek V4 Pro …' for status / SessionStart, or None in a Claude-led session."""
    lead = os.environ.get("ORCH_LEAD")
    if not lead:
        return None
    try:
        claude = resolve_profile("claude", project_dir())
        lane = "off (%s)" % claude.source if claude.name == "off" else "only as an executor: orch run claude"
    except ProfileError as ex:
        lane = "unknown (%s)" % ex
    return ("Lead: %s · %s (orch launch) — you are not Claude; orch-* subagents run on this model too. Claude: %s. "
            "Read `orch guide lead` before planning." % (
                scope_name(lead), display_name(os.environ.get("ORCH_LEAD_MODEL")) or "?", lane))


def cmd_launch(a):
    """Start an interactive Claude Code session whose every model request goes to another provider (the lead)."""
    import shutil
    import subprocess
    if os.environ.get("ORCH_WORKER"):
        raise SystemExit("orch: you are an executor (ORCH_WORKER=%s) — an executor does not start lead sessions"
                         % os.environ["ORCH_WORKER"])
    if os.environ.get("CLAUDECODE") and not a.dry_run:
        raise SystemExit("orch: run `orch launch` from a terminal, not inside a Claude Code session")
    provider = a.provider.lower()
    adapter = find_adapter(provider)
    if adapter is None:
        raise SystemExit("orch: no adapter for %r (looked in %s/adapters and %s/adapters)" % (provider, ORCH_HOME,
                                                                                            PLUGIN_ROOT))
    head = adapter_head(adapter)
    directives = adapter_directives(head)
    if directives.get("launch") != "env":
        raise SystemExit("orch: %s cannot lead a session (its adapter declares no `# orch-launch: env`)" % provider)
    choices = [c.strip().lower() for c in os.environ.get("ORCH_PROFILES", "").split(",") if c.strip()]
    for spec in a.use or []:
        if not re.fullmatch(r"[a-z0-9_.-]+=[a-z0-9_.-]+", spec.strip().lower()):
            raise SystemExit("orch: --use expects PROVIDER=PROFILE (e.g. codex=alt), got %r" % spec)
        choices.append(spec.strip().lower())
    if a.no_claude:
        choices.append("claude=off")
    selected = session_profiles(",".join(choices))
    cwd = project_dir()
    try:
        prof = resolve_profile(provider, cwd, a.profile, choices=selected)
        if prof.name == "off":
            raise SystemExit("orch: PROFILE_OFF %s — off for %s (%s); choose one: orch launch %s --profile <name>"
                             % (provider, canon_path(project_root(cwd)), prof.source, provider))
        model, _, notes, denied = profile_limits(prof, a.model, None, "write")
        if denied:
            raise SystemExit("orch: PROFILE_DENIED %s — %s (%s)" % (prof.label, denied, prof.source))
        declared = directives.get("secrets", "").split()
        secret_env, remaining = profile_secret(prof, declared)
        secret_names = fallback_secret_names(directives, remaining)
    except ProfileError as ex:
        raise SystemExit("orch: PROFILE_ERROR %s — %s" % (provider, ex))
    key = prof.label + ("/" + model if model else "")
    ok, e, k = availability(key)
    if not ok and not a.force:
        raise SystemExit("orch: %s %s — %s (orch quota show; --force starts anyway)"
                         % (availability_status(e), k, describe_entry(k, e)))
    scope = profile_api_scope(prof, provider, cwd)
    if scope:
        allowed, line = spend_lead_start(scope, cwd)
        if line:
            print(line)
        if not allowed:                                    # --force does not bypass a spend limit
            raise SystemExit("orch: %s" % line)

    env = dict(os.environ)                       # the adapter computes the lead's environment from this one
    stored = load_secrets() if secret_names else {}
    for name in secret_names:
        if name in stored and not env.get(name):
            env[name] = stored[name]
    env.update(profile_env(prof, directives))
    env.update(secret_env)
    env.update({"ORCH_MODEL": model or "", "ORCH_PROFILE": prof.name if prof.explicit else "", "ORCH_HOME": str(ORCH_HOME)})
    try:
        r = subprocess.run(adapter_command(adapter, head) + ["--launch-env"], env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        spec = json.loads(r.stdout.decode("utf-8", "replace")) if r.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired) as ex:
        raise SystemExit("orch: %s --launch-env failed: %s" % (adapter, ex))
    if not isinstance(spec, dict) or not isinstance(spec.get("set"), dict):
        print((r.stdout + r.stderr).decode("utf-8", "replace").rstrip())
        return r.returncode or 1

    unset = set(spec.get("unset") or [])
    lead = {k: v for k, v in os.environ.items() if k not in unset}
    lead.update({k: str(v) for k, v in spec["set"].items()})
    if choices:
        lead["ORCH_PROFILES"] = ",".join(choices)
    lead.update({"ORCH_LEAD": prof.label, "ORCH_LEAD_MODEL": str(spec.get("model") or model or ""),
                 "ORCH_LEAD_ENV": ",".join(sorted(spec["set"]))})
    claude = os.environ.get("ORCH_CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise SystemExit("orch: claude CLI not found (or set ORCH_CLAUDE_BIN)")
    cmd = exe_command(claude) + [str(x) for x in spec.get("args") or []] + list(a.claude_args or [])
    try:
        claude_off = resolve_profile("claude", cwd, choices=selected).name == "off"
    except ProfileError as ex:
        raise SystemExit("orch: PROFILE_ERROR claude — %s" % ex)
    print("Lead: %s · %s (background calls: %s) — every model request of this session goes to %s"
          % (scope_name(prof.label), display_name(lead["ORCH_LEAD_MODEL"]),
             display_name(spec.get("fast_model")) or "?", display_name(spec.get("endpoint") or provider)))
    print("Claude: %s" % ("off — no Claude model is used in this session" if claude_off else
                          "only as an executor (orch run claude, on your Claude login)"))
    for n in notes:
        print("profile %s: %s" % (scope_name(prof.label), n))
    if unset:
        print("Dropped for this session: %s" % ", ".join(sorted(unset)))
    if a.dry_run:
        print("Command: %s" % " ".join(cmd))
        for name in sorted(n for n in lead if os.environ.get(n) != lead[n]):
            print("  %s=%s" % (name, masked(name, lead[name])))
        return 0
    sys.stdout.flush()
    if not IS_WINDOWS:
        os.execve(cmd[0], cmd, lead)                # the session replaces orch
    proc = subprocess.Popen(cmd, env=lead)
    while True:
        try:
            return proc.wait()
        except KeyboardInterrupt:                   # Ctrl+C belongs to Claude Code, not to its launcher
            continue


# ───────────────────────── worktrees ─────────────────────────

def worktree_branch_at(path, proj):
    """The branch of the git worktree rooted exactly at `path`, if it belongs to proj's repository, else None. Git asked
    inside a plain folder under the project answers for the project around it, so a commit there would land on the
    project's own branch: the root and the repository are both compared. A detached HEAD gives 'HEAD'."""
    if not Path(path).is_dir():
        return None

    def common(cwd):
        r = git(["rev-parse", "--git-common-dir"], cwd)
        if r is None or r.returncode != 0:
            return None
        c = Path(r.stdout.strip())
        return c if c.is_absolute() else Path(cwd) / c
    top, head = git(["rev-parse", "--show-toplevel"], path), git(["rev-parse", "--abbrev-ref", "HEAD"], path)
    mine, theirs = common(path), common(proj)
    if not (top and head and mine and theirs) or top.returncode != 0 or head.returncode != 0:
        return None
    try:
        same = os.path.samefile(top.stdout.strip(), str(path)) and os.path.samefile(str(mine), str(theirs))
    except OSError:
        return None
    return head.stdout.strip() if same else None


def make_worktree(name, base="HEAD", branch=None, root=None):
    """A git worktree `name` on `branch`: next to the project in <project>.wt/ unless `root` says where. Something
    already at that path is reused only if it really is that worktree."""
    proj = project_dir()
    r = git(["rev-parse", "--is-inside-work-tree"], proj)
    if r is None or r.returncode != 0:
        raise SystemExit("orch: %s is not a git repository — worktree unavailable" % proj)
    wt_root = Path(root) if root else proj.parent / (proj.name + ".wt")
    path = wt_root / name
    wanted, branch = branch, branch or ("orch/" + name.lower())
    if path.exists():
        actual = worktree_branch_at(path, proj)
        if actual is None:
            raise SystemExit("orch: %s exists but is not a working git worktree of this repository (a plain folder, "
                             "another repository, or links broken by a move: see git worktree repair). Sort it out or "
                             "remove it, then try again." % path)
        if wanted and actual != wanted:
            raise SystemExit("orch: the worktree %s is on branch %s, not %s. Sort it out or remove it, then try again."
                             % (path, actual, wanted))
        return path, actual
    wt_root.mkdir(parents=True, exist_ok=True)
    exists = git(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], proj)
    args = ["worktree", "add", str(path), branch] if exists and exists.returncode == 0 else \
        ["worktree", "add", "-b", branch, str(path), base]
    git(args, proj, check=True)
    ensure_git_exclude(proj)
    return path, branch


def cmd_worktree(a):
    path, branch = make_worktree(a.name, a.base, a.branch)
    print("worktree: %s\nbranch:   %s" % (path, branch))
    w = win_path(path)
    if w:
        print("windows:  %s" % w)
    return 0


# ───────────────────────── handoffs (manual lane) ─────────────────────────

MANUAL_ROLE = """> You are an executor in the Orchestra system. This task comes from the orchestrator — Claude Code,
> which runs the work together with the operator and checks the result itself (diff, tests) before accepting it.
> The operator only handed you the task: work autonomously and do not message them about it. Everything you need
> is in this file and in the project rules.
"""

PROTOCOL_START = """
---

## Execution protocol (follow it strictly)

1. **Right at the start** create the file `{rel}/RESULT.md` with your file editor, with two lines:
   `STATUS: IN_PROGRESS`
   `AGENT: <product and model, e.g. Antigravity · Gemini 3.8 Flash>`
"""
# A task that changes nothing (the default): the agent reads and reports. It runs in the project folder, where other
# work goes on, so it may write one file only, and it is told not to run commands that could wait for confirmation.
PROTOCOL_READ = PROTOCOL_START + """2. This task changes nothing: change no file except `{rel}/RESULT.md`, and do not commit. Other work goes on in this
   folder, so leave its files and branches alone.
3. Run no shell commands unless this task lists them: each one can stop and wait for the operator's confirmation. If
   you think you need one, write in your report what you wanted to know instead.
4. Do not start other agents or `orch`: assigning tasks is the orchestrator's job.
5. Check the result against the acceptance criteria.
6. **When finished**, overwrite `{rel}/RESULT.md`. The first line is exactly one of:
   `STATUS: DONE` · `STATUS: BLOCKED` · `STATUS: FAILED`
   The second is the same `AGENT: …` line. Then the sections: `## Summary` (your findings), `## Verification`,
   `## Open questions`.
7. Writing RESULT.md with a final status is the completion signal for the orchestrator. Change nothing after that.
"""
# A task that changes files (--write): it works in a worktree of its own inside the project folder, made by orch, and
# leaves the changes uncommitted for the orchestrator to review and commit.
PROTOCOL_WRITE = PROTOCOL_START + """2. Work only inside `{wt}`, a separate git worktree on branch `{branch}`. It is a full copy of the project, with the
   same paths as the project folder around it: every file you read or change for this task must be under that
   folder, never its same-named original at the project root. Local files (`.env`, `node_modules`, builds) may be
   missing: install dependencies as the project instructions say; do not copy secrets: if you need one,
   `STATUS: BLOCKED`. In `.orchestra/` outside that folder touch nothing except `{rel}/RESULT.md`.
3. Do not start other agents or `orch`: assigning tasks is the orchestrator's job.
4. Check the result against the acceptance criteria (run the listed commands/tests).
5. Do not commit and do not switch branches: the orchestrator reviews the changes in that worktree and commits them.
6. **When finished**, overwrite `{rel}/RESULT.md`. The first line is exactly one of:
   `STATUS: DONE` · `STATUS: BLOCKED` · `STATUS: FAILED`
   The second is the same `AGENT: …` line. Then the sections: `## Summary`, `## Changed files`,
   `## Verification` (commands and their outcome), `## Open questions`.
7. Writing RESULT.md with a final status is the completion signal for the orchestrator. Change nothing after that.
"""
# The paste line is one line, for the clipboard too. Both kinds stop where the agent's file tools cannot open
# .orchestra/ (git ignores it) instead of reaching it through the terminal; a read-only task also runs no commands.
PASTE_BASE = ("Execute the task described in {rel}/TASK.md, by the execution protocol at the end of that file "
              "(RESULT.md status markers).")
PASTE_STOP = (" If your file tools can't open .orchestra/ because git ignores it, don't use the terminal to get "
              "around that: say so in the chat and stop.")
PASTE_READ = PASTE_BASE + " Run no shell commands unless the task lists them." + PASTE_STOP
PASTE_WRITE = PASTE_BASE + " Work only inside {wt}, a separate git worktree." + PASTE_STOP
# Antigravity loads .agents/rules/*.md of the workspace (trigger always_on → every turn): the protocol survives
# long sessions and context compaction. One general rule in the project folder, because several tasks can be open
# in it and a rule naming one of them would mislead the others. It stays after a task closes; git excludes it.
AG_RULE_PATH = ".agents/rules/orchestra-task.md"
AG_RULE = """---
trigger: always_on
---
# Orchestra tasks

This applies only when a message names an Orchestra task (an id such as AG-0004); other conversations ignore it.
The task file is `.orchestra/handoffs/<id>/TASK.md`; carry it out strictly by the protocol at the end of that file.
- At the start — `.orchestra/handoffs/<id>/RESULT.md` with the lines `STATUS: IN_PROGRESS` and `AGENT: <product · model>`.
- At the end — the same file with `STATUS: DONE | BLOCKED | FAILED` and the report sections: without it the
  orchestrator will not know the task is finished.
- The project rules ({rules}) are mandatory; scope — that task only; in `.orchestra/` — only that task's RESULT.md and, for a task that changes files, its own worktree.
- A task that changes files names its own worktree: work only inside it.
"""
AGENT_RE = re.compile(r"^\s*AGENT:\s*(.+?)\s*$", re.M)
AGENT_NAMES = {"antigravity": "Antigravity", "cursor": "Cursor", "windsurf": "Windsurf", "jules": "Jules",
               "kiro": "Kiro", "copilot": "GitHub Copilot"}
OPEN_TAKEN = ("WAITING", "STARTED?", "IN_PROGRESS")


def agent_name(provider):
    return AGENT_NAMES.get((provider or "").lower(), provider or "manual agent")


# ───────────────────────── handoff path storage ─────────────────────────
#
# meta.json stores path fields relative to the project root (forward slashes), so a moved project folder or a
# switch between Windows and WSL keeps them valid. In memory the same fields stay absolute native paths: convert
# on load (abs_path) and on save (rel_path); callers never see the on-disk form. An absolute path of the *other*
# OS (a Windows path read under WSL, a /mnt/c/… path read on Windows) is kept verbatim — no guessing at
# conversions; an absolute path under the current root becomes relative on the next save.

META_PATH_FIELDS = ("workdir", "task_path", "result_path")
WINDOWS_ABS_RE = re.compile(r"^[A-Za-z]:[\\/]")


def meta_base(meta_path):
    """Project root that owns a meta.json: <proj>/.orchestra/handoffs/<hid>/meta.json → <proj>. Path arithmetic
    only (no .resolve(): a .orchestra symlink must not redirect the project), so it never depends on the cwd."""
    return meta_path.parents[3]


def _looks_absolute(v):
    """Absolute in either OS: /…, \\…, C:\\…, \\\\server\\…. Stored-relative paths never start that way."""
    return v.startswith(("/", "\\")) or bool(WINDOWS_ABS_RE.match(v))


def abs_path(v, base):
    """meta.json value → absolute native path for callers. An absolute path (either OS) is kept verbatim; only a
    stored-relative path is resolved against base."""
    if not v:
        return v
    v = str(v)
    if _looks_absolute(v):
        return v
    return os.path.normpath(str(Path(base) / v))


def _foreign_abs(v):
    """An absolute path of the other OS, not valid here: keep it verbatim on save."""
    if IS_WINDOWS:
        return v.startswith("/")            # /mnt/c/… or any POSIX absolute path
    return bool(WINDOWS_ABS_RE.match(v)) or v.startswith("\\\\")


def rel_path(v, base):
    """in-memory absolute path → meta.json form: relative to base with forward slashes when reachable, else
    absolute as-is (a different drive, or a path of the other OS)."""
    if not v:
        return v
    v = str(v)
    if _foreign_abs(v):
        return v.replace("\\", "/")
    if not Path(v).is_absolute():
        return v.replace("\\", "/")         # already relative (defensive)
    try:
        rel = os.path.relpath(v, str(base))
    except ValueError:
        return v.replace("\\", "/")         # different drive on Windows: no relative form
    return rel.replace("\\", "/")


def meta_abs(m, base):
    """Absolute view of a raw meta dict (a copy; the on-disk form is left untouched)."""
    out = dict(m)
    for f in META_PATH_FIELDS:
        if out.get(f):
            out[f] = abs_path(out[f], base)
    return out


def workdir_win(m):
    """Windows form of the workdir for display, derived from the resolved workdir (never stored)."""
    w = m.get("workdir")
    if not w or IS_WINDOWS:
        return None
    return win_path(w)


def handoffs_root():
    return state_dir() / "handoffs"


@locked("project")
def next_handoff_id(prefix):
    root = handoffs_root()
    root.mkdir(parents=True, exist_ok=True)
    counter = read_json(root / "counter.json", {}, recover_corrupt=True)
    numbers = [int(d.name[len(prefix) + 1:]) for d in root.iterdir()
               if d.name.startswith(prefix + "-") and d.name[len(prefix) + 1:].isdigit()]
    value = counter.get(prefix, 0)
    n = max(numbers + [value if isinstance(value, int) else 0])
    while True:
        n += 1
        hid = "%s-%04d" % (prefix, n)
        try:
            (root / hid).mkdir()    # a reserved id survives a lost/corrupt counter or a failed assignment
            break
        except FileExistsError:
            continue
    counter[prefix] = n
    write_json(root / "counter.json", counter)
    return hid


def load_meta(hid):
    p = handoffs_root() / hid / "meta.json"
    m = read_json(p, None, object_required=True)
    if m is None:
        raise SystemExit("orch: handoff %s not found" % hid)
    return meta_abs(m, meta_base(p))


@locked("project")
def save_meta(m):
    path = handoffs_root() / m["id"] / "meta.json"
    out = dict(m)
    base = meta_base(path)
    for f in META_PATH_FIELDS:
        if f in out:
            out[f] = rel_path(out[f], base)
    write_json(path, out)
    try:
        write_board()
    except Exception:
        pass                         # the board is a view; hooks must never fail because of it


def all_metas():
    root = handoffs_root()
    if not root.exists():
        return []
    base = meta_base(root / "x" / "meta.json")     # the project the handoffs root belongs to, computed once
    out = []
    for d in sorted(root.iterdir()):
        p = d / "meta.json"
        try:
            m = read_json(p, None, object_required=True) if d.is_dir() else None
        except StateError as ex:
            warn_state(p, str(ex))
            continue
        if m:
            out.append(meta_abs(m, base))
    return out


def result_status(m):
    """Status from RESULT.md (or manual override in meta); OFFERED = in the pool, nobody has taken it yet."""
    if m.get("manual_status"):
        return m["manual_status"]
    if m.get("offered") and not m.get("taken"):
        return "OFFERED"
    rp = Path(m["result_path"])
    if rp.exists():
        mt = STATUS_RE.search(rp.read_text(encoding="utf-8", errors="replace")[:2000])
        if mt:
            st = mt.group(1)
            return st if st in TERMINAL + ("IN_PROGRESS",) else "IN_PROGRESS"
        return "IN_PROGRESS"
    return "WAITING"


def agent_reported(m):
    """'AGENT: Antigravity · Gemini 4 Argon' line the executor wrote into RESULT.md."""
    rp = Path(m["result_path"]) if m.get("result_path") else None
    if rp and rp.exists():
        mt = AGENT_RE.search(rp.read_text(encoding="utf-8", errors="replace")[:2000])
        if mt and not mt.group(1).startswith("<"):
            return mt.group(1)[:80]
    return None


def scan_latest_mtime(root, limit=20000):
    latest, seen = 0.0, 0
    for dirpath, dirnames, filenames in os.walk(str(root)):
        dirnames[:] = [d for d in dirnames if d not in SCAN_SKIP]
        for f in filenames:
            seen += 1
            if seen > limit:
                return latest
            try:
                mt = os.path.getmtime(os.path.join(dirpath, f))
            except OSError:
                continue
            if mt > latest:
                latest = mt
    return latest


def taken_at(m):
    return parse_iso(m.get("taken") or m["created"])


def last_activity(m, limit=20000):
    """Latest change after the task was handed out (None if nothing changed). A task in the project folder (no
    `branch`) shares it with other work, so a changed file says nothing about the agent: only its RESULT.md counts.
    A task with a worktree of its own (a branch) is scanned in that worktree."""
    if result_status(m) == "OFFERED" or not m.get("workdir"):
        return None
    rp = Path(m["result_path"])
    if m.get("branch"):
        baseline = max(taken_at(m).timestamp(), m.get("activity_baseline") or 0) + 1.0
        latest = scan_latest_mtime(Path(m["workdir"]), limit)
    else:
        baseline, latest = taken_at(m).timestamp() + 1.0, 0.0
    if rp.exists():
        latest = max(latest, rp.stat().st_mtime)
    if latest <= baseline:
        return None
    return dt.datetime.fromtimestamp(latest).astimezone()


def effective_state(m):
    st = result_status(m)
    if st == "WAITING" and last_activity(m):
        return "STARTED?"   # files changed in workdir but no RESULT.md yet
    return st


def suggestion(m):
    s = agent_name(m.get("provider"))
    if m.get("model"):
        s += " · " + m["model"]
    if m.get("effort"):
        s += " · " + m["effort"]
    return s


def operator_card(m):
    if result_status(m) == "OFFERED":
        lines = ["┌ %s · %s — in the manual pool" % (m["id"], m["title"]),
                 "│ Suggested: %s%s" % (suggestion(m), " (changes files, in its own worktree)" if task_writes(m) else ""),
                 "│ Take it: say “%s to %s” (or /orchestra:manual take %s) — you then get the line to paste."
                 % (m["id"], agent_name(m.get("provider")), m["id"])]
        every = read_json(handoffs_root() / ".pool.json", {}, recover_corrupt=True).get("check_min") or POOL_CHECK_MIN
        lines.append("│ No take from the pool for %d min → the orchestrator starts taking tasks back, one at a time while "
                     "waiting still makes sense%s." % (every, " (this one: %s)" % m["fallback"] if m.get("fallback") else ""))
        lines.append("└ Not needed: “%s: cancel”" % m["id"])
        return "\n".join(lines)
    agent = agent_name(m.get("provider"))
    lines = ["┌ %s · %s" % (m["id"], m["title"])]
    nested = nested_worktree(m)
    if m.get("branch") and not nested:     # a task handed out by an older version, in a worktree next to the project
        lines.append("│ Open in %s: %s" % (agent, m["workdir"]))
    else:
        lines.append("│ In %s, in the project folder: %s" % (agent, project_dir() if nested else m["workdir"]))
    ww = win_path(project_dir()) if nested else workdir_win(m)
    if ww:
        lines.append("│   (Windows path:      %s)" % ww)
    if nested:
        lines.append("│ It works in: %s (its own worktree, branch %s); no need to open it" % (nested, m["branch"]))
    elif m.get("branch"):
        lines.append("│ Branch: %s" % m["branch"])
    model = m.get("model") or "your choice"
    if m.get("effort"):
        model += " · thinking/effort: %s" % m["effort"]
    lines.append("│ Model: %s" % model)
    lines.append("│ Paste into the %s chat:" % agent)
    lines.append("│   %s" % m["paste"])
    lines.append("│ The watcher sees completion via RESULT.md — no need to report back.")
    if m.get("fallback"):
        lines.append("│ Fallback: %s if not started within %d min / not done within %d min." % (
            m["fallback"], m["pickup_min"], m["reassign_min"]))
    lines.append("└ Postpone/cancel: “AG-…: cancel” or orch handoff cancel %s" % m["id"])
    return "\n".join(lines)


def read_body(a):
    if a.prompt_file:
        body = Path(a.prompt_file).read_text(encoding="utf-8")
    elif not sys.stdin.isatty():
        body = sys.stdin.read()
    else:
        raise SystemExit("orch: task body required (--prompt-file or stdin)")
    if not body.strip():
        raise SystemExit("orch: empty task body")
    return body


def taken_count():
    return sum(1 for m in all_metas() if result_status(m) in OPEN_TAKEN)


def manual_gate(provider, model_key, override, max_open, force, check_operator=True):
    """Profile, operator and quota checks of the manual lane → ((Profile, max_open), None) or (None, exit code)."""
    try:
        prof = resolve_profile(provider, project_dir(), override)
    except ProfileError as ex:
        print("PROFILE_ERROR %s — %s" % (provider, ex))
        return None, 1
    if prof.name == "off":       # the profile is the operator's decision: --force does not override it
        print("PROFILE_OFF %s — manual tasks disabled by the profile (%s) for this project.\n"
              "Assign the task to an automated executor. To enable: orch profile use %s <profile>."
              % (provider, prof.source, provider))
        return None, EXIT_QUOTA
    models = prof.data.get("models") or []
    if models and model_key and not model_allowed(model_key, models):
        print("PROFILE_DENIED %s — model %s not allowed (allowed: %s; %s)." % (
            prof.label, model_key, ", ".join(map(str, models)), prof.source))
        return None, EXIT_QUOTA
    ok, e, k = availability("operator")
    if check_operator and not ok and not force:
        print("OPERATOR_AWAY — %s\nThe manual lane is closed; assign the task to an automated executor."
              % describe_entry(k, e))
        return None, EXIT_QUOTA
    prov_key = prof.label + ("/" + model_key if model_key else "")
    ok, e, k = availability(prov_key)
    if not ok and not force:
        print("%s %s — %s" % (availability_status(e), prov_key, describe_entry(k, e)))
        return None, EXIT_QUOTA
    return (prof, max_open), None


def limit_reached(prof, max_open, force):
    n = taken_count()
    profile_cap = prof.data.get("max_open")
    if isinstance(profile_cap, int) and n >= profile_cap:
        print("HANDOFF_LIMIT: %d manual tasks already open (profile limit %d). Wait for one to finish, "
              "merge tasks or assign to an automated executor." % (n, profile_cap))
        return True
    if n >= max_open and not force:
        print("HANDOFF_LIMIT: %d manual tasks already open (limit %d). Wait for one to finish, merge tasks "
              "or assign to an automated executor. (--force to bypass)" % (n, max_open))
        return True
    return False


def create_handoff(a, body, offered):
    hid = next_handoff_id(a.prefix)
    (handoffs_root() / hid / "BODY.md").write_text(body, encoding="utf-8")
    return {
        "id": hid, "title": a.title, "provider": a.provider.lower(), "profile": None, "model": a.model,
        "effort": a.effort, "model_key": a.model_key, "created": iso(now()),
        "offered": iso(now()) if offered else None, "taken": None, "write": bool(a.write), "base": a.base,
        "workdir": None, "branch": None, "task_path": None,
        "result_path": str(handoffs_root() / hid / "RESULT.md"), "paste": None, "fallback": a.fallback,
        "pickup_min": a.pickup_min, "reassign_min": a.reassign_min,
        "session": session_id(), "notified": {}, "manual_status": None, "reclaim": None,
    }


def task_writes(m):
    """Does the task change files? A meta without the field is from a version that made no promise: it writes."""
    return m.get("write") is not False


def nested_worktree(m):
    """'.orchestra/wt/AG-0004' for a task whose worktree lives inside the project's state folder, else ''. A task of
    an older version has its worktree next to the project (<project>.wt/) and is not nested."""
    if not m.get("branch") or not m.get("workdir"):
        return ""
    try:
        rel = Path(m["workdir"]).relative_to(state_dir(create=False) / "wt")
    except ValueError:
        return ""
    return ".orchestra/wt/%s" % rel.as_posix()


def is_git_repo(path):
    return git_walk(Path(path).resolve())[1] is not None


def ensure_ag_rule(proj, rules):
    """The one general Antigravity rule of the project folder, written when absent or different."""
    rule = proj / AG_RULE_PATH
    text = AG_RULE.format(rules=", ".join(rules) or "CLAUDE.md / AGENTS.md, if present")
    try:
        if rule.is_file() and rule.read_text(encoding="utf-8") == text:
            return
    except (OSError, UnicodeDecodeError):
        pass
    rule.parent.mkdir(parents=True, exist_ok=True)
    rule.write_text(text, encoding="utf-8")
    ensure_git_exclude(proj, (".orchestra/", AG_RULE_PATH))


def assign_handoff(m, prof):
    """Hand a task to the agent that takes it: TASK.md (role, project rules, protocol) and the paste line. TASK.md and
    RESULT.md live in the project's .orchestra/handoffs/<id>/ for every task. A read-only task works in the project
    folder; a task that changes files gets a worktree of its own inside it, .orchestra/wt/<id>, on branch ag/<id>."""
    proj = project_dir()
    hid = m["id"]
    writes = task_writes(m)
    branch = None
    if writes:
        workdir, branch = make_worktree(hid, m.get("base") or "HEAD", "ag/" + hid.lower(), root=state_dir() / "wt")
    else:
        workdir = proj
    wt = ".orchestra/wt/%s" % hid
    rel = ".orchestra/handoffs/%s" % hid
    task_dir = proj / rel
    task_dir.mkdir(parents=True, exist_ok=True)
    body = (handoffs_root() / hid / "BODY.md").read_text(encoding="utf-8")
    rules = list(dict.fromkeys(name for _, name, _ in instruction_files(workdir)))
    header = "# %s — %s\n\n%s\n" % (hid, m["title"], MANUAL_ROLE)
    header += "- Working folder: `%s`\n" % workdir
    if branch:
        header += "- Branch: `%s` (a separate git worktree inside the project folder)\n" % branch
    if rules:
        header += "- Project rules — mandatory, read them before you start: %s\n" % ", ".join("`%s`" % r for r in rules)
    header += "- Created: %s\n\n" % now().strftime("%Y-%m-%d %H:%M")
    protocol = (PROTOCOL_WRITE if writes else PROTOCOL_READ).format(rel=rel, wt=wt, branch=branch)
    (task_dir / "TASK.md").write_text(header + body.rstrip() + "\n" + protocol, encoding="utf-8")
    if m["provider"] == "antigravity":
        ensure_ag_rule(proj, rules)
    m.update({
        "taken": iso(now()), "profile": prof.name if prof.explicit else None, "workdir": str(workdir),
        "branch": branch, "task_path": str(task_dir / "TASK.md"),
        "result_path": str(task_dir / "RESULT.md"),
        "paste": (PASTE_WRITE if writes else PASTE_READ).format(rel=rel, wt=wt),
    })
    if branch:
        m["activity_baseline"] = scan_latest_mtime(workdir)   # the checkout is not "operator activity"
    return m


def print_card(m, clip):
    print(operator_card(m))
    if clip and m.get("paste"):
        used = copy_to_clipboard(m["paste"])
        print("(paste line copied to the clipboard via %s)" % used if used else "(clipboard unavailable)")


def refuse_in_worker():
    if os.environ.get("ORCH_WORKER"):
        raise SystemExit("orch: you are an executor (ORCH_WORKER) — only the orchestrator may use orch handoff")


def check_write_flags(a):
    """--worktree is gone (--write gives a task its own worktree); --base only goes with --write; --write needs a git
    repository, because its worktree is a git one. A session that has not reloaded the plugin may still pass the old
    flags, so say what changed instead of an argparse error."""
    if getattr(a, "worktree", False):
        raise SystemExit("orch: --worktree is gone: a task that changes files takes --write, which gives it a "
                         "worktree of its own inside the project folder (see orch guide manual)")
    if getattr(a, "base", None) and not a.write:
        raise SystemExit("orch: --base goes only with --write: a read-only task has no worktree to base")
    if a.write and not is_git_repo(project_dir()):
        raise SystemExit("orch: --write needs a git repository (the task gets a worktree of its own) and %s is not "
                         "one: give the task read-only" % project_dir())


def cmd_handoff_new(a):
    """Assign right away: the claim reserves capacity and ownership under the lock, the files are written outside it."""
    check_write_flags(a)
    body = read_body(a)
    with state_lock(state_dir() / ".state.lock"):
        gate, rc = manual_gate(a.provider, a.model_key, a.profile, a.max_open, a.force)
        if rc is not None:
            return rc
        prof, max_open = gate
        if limit_reached(prof, max_open, a.force):
            return EXIT_QUOTA
        m = create_handoff(a, body, offered=False)
        claim_handoff(m, prof)
    m = materialize_handoff(m, prof)
    print_card(m, a.clip)
    return 0


def cmd_handoff_offer(a):
    check_write_flags(a)
    body = read_body(a)
    with state_lock(state_dir() / ".state.lock"):
        return offer_handoff(a, body)


def offer_handoff(a, body):
    """Put a task into the pool: the operator picks it (orch handoff take) when convenient, or the orchestrator
    reclaims it for an automated executor. Nothing is prepared until it is taken."""
    gate, rc = manual_gate(a.provider, a.model_key, a.profile, 10 ** 6, a.force)
    if rc is not None:
        return rc
    pool = sum(1 for m in all_metas() if result_status(m) == "OFFERED")
    if pool >= a.max_offers and not a.force:
        print("OFFER_LIMIT: the pool already holds %d tasks (limit %d) — wait until the operator takes one or you "
              "reclaim one (orch handoff reclaim), or run it automatically." % (pool, a.max_offers))
        return EXIT_QUOTA
    m = create_handoff(a, body, offered=True)
    save_meta(m)
    pool_state(sorted(x["id"] for x in all_metas() if not x.get("archived") and result_status(x) == "OFFERED"),
               check_min=max(a.check_min, 1))
    print(operator_card(m))
    return 0


@locked("project")
def cmd_handoff_reclaim(a):
    """Take a pooled task back for an automated executor; --next: the one-at-a-time reclaim of a pool check."""
    m = load_meta(a.id.upper())
    if result_status(m) != "OFFERED" or m.get("archived"):
        print("%s is not in the pool (%s) — nothing to reclaim." % (m["id"], effective_state(m)))
        return 1
    if a.next:
        busy = next_running([x for x in all_metas() if not x.get("archived")])
        if busy:
            print("NEXT_BUSY: %s “%s”, reclaimed as the next task, is still running — wait for it (a successful "
                  "orch run … --handoff %s, or orch handoff done %s, marks it finished). Without --next reclaim only a "
                  "task no longer worth waiting for." % (busy["id"], busy["title"], busy["id"], busy["id"]))
            return EXIT_QUOTA
    m.pop("hold", None)
    m["reclaim"] = {"kind": "next" if a.next else "all", "at": iso(now()), "run": None, "finished": None}
    save_meta(m)
    cmd_handoff_done(SimpleNamespace(id=m["id"], status="REASSIGNED", force=True, note=a.note or (
        "reclaimed from the pool as the next task" if a.next else "reclaimed from the pool by the orchestrator")))
    print("Run it: orch run <provider> … --handoff %s (a successful run marks it finished), or do it another way and "
          "then: orch handoff done %s" % (m["id"], m["id"]))
    return 0


def finish_reclaimed(hid, status, run_id=None):
    """A reclaimed pooled task was executed: free the one-at-a-time slot. Never fails (called from orch run)."""
    try:
        with state_lock(state_dir() / ".state.lock"):
            _finish_reclaimed(hid, status, run_id)
    except (SystemExit, Exception):
        pass


def _finish_reclaimed(hid, status, run_id):
    m = load_meta(hid)
    r = m.get("reclaim") or {"kind": "all", "at": iso(now())}
    r.update(finished=iso(now()), status=status)
    if run_id:
        r["run"] = run_id
    m["reclaim"] = r
    save_meta(m)



def claim_handoff(m, prof):
    """Reserve both ownership and capacity before slow work; a competing take/reclaim now fails."""
    m.pop("hold", None)
    m.update(taken=iso(now()), assigning=rand_suffix(16), profile=prof.name if prof.explicit else None)
    save_meta(m)


def materialize_handoff(claim, prof):
    token = claim["assigning"]
    try:
        assigned = assign_handoff(dict(claim), prof)
    except BaseException as ex:
        # A worktree made before the failure stays on record: a later take reuses it, and close can remove it.
        wt = state_dir() / "wt" / claim["id"]
        left = quietly(worktree_branch_at, wt, project_dir()) if task_writes(claim) else None
        with state_lock(state_dir() / ".state.lock"):
            current = load_meta(claim["id"])
            if current.get("assigning") == token:
                current.pop("assigning", None)
                if result_status(current) not in TERMINAL and not current.get("archived"):
                    current["taken"] = None
                    if left:
                        current.update(workdir=str(wt), branch=left)
                    if not current.get("offered"):
                        note = "Assignment failed: %s" % ex
                        if left:
                            note += "; its worktree remains: orch handoff close %s --remove-worktree" % claim["id"]
                        current.update(manual_status="CANCELLED", archived=iso(now()), closed=iso(now()),
                                       manual_note=note)
                save_meta(current)
        raise
    with state_lock(state_dir() / ".state.lock"):
        current = load_meta(claim["id"])
        if current.get("assigning") != token or result_status(current) in TERMINAL or current.get("archived"):
            raise SystemExit("orch: %s changed while being assigned; no task handed out" % claim["id"])
        # Merge only assignment fields, preserving notification marks and other concurrent updates.
        for field in ("taken", "profile", "workdir", "branch", "task_path", "result_path", "paste"):
            current[field] = assigned[field]
        if "activity_baseline" in assigned:
            current["activity_baseline"] = assigned["activity_baseline"]
        else:
            current.pop("activity_baseline", None)  # a task in the shared project folder is not scanned
        current.pop("assigning", None)
        save_meta(current)
    return current


def cmd_handoff_take(a):
    """Claim under the project lock, then write the task files without holding it."""
    with state_lock(state_dir() / ".state.lock"):
        m = load_meta(a.id.upper())
        st = result_status(m)
        if st != "OFFERED" or m.get("archived"):
            print("%s is not available in the pool (%s) — nothing to take." % (m["id"], st))
            return 1
        for f in ("model", "model_key", "effort"):
            if getattr(a, f):
                m[f] = getattr(a, f)
        if a.agent:
            m["provider"] = a.agent.lower()
        gate, rc = manual_gate(m["provider"], m.get("model_key"), a.profile, a.max_open, a.force, check_operator=False)
        if rc is not None:
            return rc
        prof, max_open = gate
        if limit_reached(prof, max_open, a.force):
            return EXIT_QUOTA
        if task_writes(m) and not is_git_repo(project_dir()):
            print("%s changes files and needs a git repository for its worktree, and %s is not one — nothing taken. "
                  "Run it with an automated executor." % (m["id"], project_dir()))
            return 1
        claim_handoff(m, prof)
    m = materialize_handoff(m, prof)
    print_card(m, a.clip)
    return 0


def held(m):
    hold = m.get("hold")
    if not isinstance(hold, dict):
        return False
    until = parse_iso(hold.get("until"))
    return not until or until > now()


def hold_mark(m):
    if not held(m):
        return ""
    until = parse_iso(m["hold"].get("until"))
    return " · on hold for the operator" + (" until " + until.astimezone().strftime("%H:%M") if until else "")


@locked("project")
def cmd_handoff_hold(a):
    m = load_meta(a.id.upper())
    if result_status(m) != "OFFERED" or m.get("archived"):
        print("%s is not in the pool (%s) — nothing to hold." % (m["id"], effective_state(m)))
        return 1
    if a.off:
        m.pop("hold", None)
    else:
        m["hold"] = {"at": iso(now()), "until": iso(parse_until(a.until)) if a.until else None, "note": a.note}
    save_meta(m)
    print(handoff_line(m))
    return 0


def handoff_line(m):
    st = effective_state(m)
    if st == "OFFERED":
        return ("%-9s %-11s %-10s %s · suggested: %s" % (m["id"], st, human_delta(parse_iso(m["created"])),
                                                        m["title"][:50], suggestion(m))) + hold_mark(m)
    act = last_activity(m) if st not in TERMINAL else None
    act_s = ("activity %s" % human_delta(act)) if act else "no activity"
    who = agent_reported(m) or suggestion(m)
    return "%-9s %-11s %-10s %s · %s · %s" % (m["id"], st, human_delta(taken_at(m)), m["title"][:50], who, act_s)


def cmd_handoff_list(a):
    metas = all_metas()
    if not a.all:
        metas = [m for m in metas if result_status(m) not in TERMINAL]
    if a.json:
        print(json.dumps([dict(m, state=effective_state(m), agent_reported=agent_reported(m)) for m in metas],
                         ensure_ascii=False, indent=2))
        return 0
    if not metas:
        print("No open manual tasks." if not a.all else "No manual tasks.")
        return 0
    pool = [m for m in metas if result_status(m) == "OFFERED"]
    rest = [m for m in metas if result_status(m) != "OFFERED"]
    if pool:
        print("Pool — available to take (%d):" % len(pool))
        print("\n".join("  " + handoff_line(m) for m in pool))
    if rest:
        print("Handed out (%d):" % len(rest))
        print("\n".join("  " + handoff_line(m) for m in rest))
    print("Board: %s" % (state_dir() / "MANUAL.md"))
    return 0


POOL_CHECK_MIN = 5
ASSIGNMENT_TIMEOUT_MIN = 10


def pool_state(pool_ids, check_min=None):
    """.orchestra/handoffs/.pool.json: pooled ids, when the pool opened, its check interval, the last check reported.
    Updated on every meta save (write_board)."""
    path = handoffs_root() / ".pool.json"
    state = read_json(path, {}, recover_corrupt=True)
    before = dict(state)
    if pool_ids and not state.get("ids"):          # the pool opens: its clock starts
        state["started"] = iso(now())
    state["ids"] = pool_ids
    if check_min is not None:
        state["check_min"] = check_min
    if state != before and (pool_ids or path.exists()):
        write_json(path, state)
    return state


def pool_clock(metas, state):
    """(anchor, taken): the pool's clock runs from the operator's last take from the pool, else from its opening.
    Reclaims by the orchestrator do not restart it."""
    started = parse_iso(state.get("started") or state.get("changed") or "") or now()
    takes = [t for t in (parse_iso(m.get("taken") or "") for m in metas if m.get("offered")) if t]
    last = max(takes) if takes else None
    return (last, True) if last and last > started else (started, False)


def next_running(metas):
    """The pooled task reclaimed as "the next one" that is still being executed, if any (one at a time)."""
    return next((m for m in metas if (m.get("reclaim") or {}).get("kind") == "next"
                 and not m["reclaim"].get("finished")), None)


def pool_event(metas, mark=True):
    """⌛ once per check interval without a take: reclaim every task no longer worth waiting for, else the next one."""
    pool = sorted((m for m in metas if result_status(m) == "OFFERED"), key=lambda m: m.get("offered") or m["created"])
    eligible = [m for m in pool if not held(m)]
    if not eligible:
        return None
    state = pool_state(sorted(m["id"] for m in pool))
    pool = eligible
    every = max(int(state.get("check_min") or POOL_CHECK_MIN), 1)
    anchor, took = pool_clock(metas, state)
    t = now()
    tick = int((t - anchor).total_seconds() // (every * 60))
    seen = state.get("reported") or {}
    if tick < 1 or (seen.get("anchor") == iso(anchor) and seen.get("tick", 0) >= tick):
        return None
    if mark:
        state["reported"] = {"anchor": iso(anchor), "tick": tick}
        write_json(handoffs_root() / ".pool.json", state)
    lines = ["⌛ Manual pool: no task taken for %d min (since %s; check %d, every %d min). Untaken, oldest first:" % (
        (t - anchor).total_seconds() // 60, "the last take" if took else "the pool opened", tick, every)]
    for m in pool:
        lines.append("  %s “%s” — %s · in the pool %s%s" % (
            m["id"], m["title"], suggestion(m), human_delta(parse_iso(m.get("offered") or m["created"])).replace(" ago", ""),
            " · fallback: %s" % m["fallback"] if m.get("fallback") else ""))
    if not availability("operator")[0]:
        lines.append("  The operator is away: none of these is worth waiting for.")
    busy = next_running(metas)
    nxt = ("not now: %s “%s”, reclaimed as the next task %s, is still running" % (
        busy["id"], busy["title"], human_delta(parse_iso(busy["reclaim"]["at"]))) if busy
        else "orch handoff reclaim %s --next" % pool[0]["id"])
    lines.append("Reclaim every task no longer worth waiting for (orch handoff reclaim <id>; run them in parallel where "
                 "they may run in parallel). If there is none, reclaim only the next one — %s." % nxt)
    return "\n".join(lines)


@locked("project")
def write_board():
    """<project>/.orchestra/MANUAL.md — the manual lane at a glance for the operator (any editor or the agent's IDE)."""
    metas = [m for m in all_metas() if not m.get("archived")]
    states = {m["id"]: result_status(m) for m in metas}       # no workdir scans: the board is rewritten from hooks
    pool = [m for m in metas if states[m["id"]] == "OFFERED"]
    state = pool_state(sorted(m["id"] for m in pool))
    out = [m for m in metas if states[m["id"]] in OPEN_TAKEN]
    done = [m for m in metas if states[m["id"]] in TERMINAL][-10:]
    lines = ["# Orchestra manual tasks", "",
             "Updated %s · `%s` · maintained by orch, do not edit." % (now().strftime("%Y-%m-%d %H:%M"), project_dir()),
             "Take from the pool: tell the orchestrator “AG-0004 to Antigravity” "
             "(or `/orchestra:manual take AG-0004`). Done / cancel: “AG-0004 done” / “AG-0004: cancel”.", "",
             "## Pool — available to take (%d)" % len(pool)]
    if pool:
        anchor, took = pool_clock(metas, state)
        every = max(int(state.get("check_min") or POOL_CHECK_MIN), 1)
        lines.append("_%s %s. After %d min without a take the orchestrator starts taking tasks back for automated "
                     "executors (one at a time while waiting still makes sense) and checks again every %d min._" % (
                         "Last take" if took else "Pool opened", anchor.astimezone().strftime("%H:%M"), every, every))
    for m in pool:
        lines.append("- **%s** · %s — %s%s · %s in the pool%s" % (
            m["id"], m["title"], suggestion(m), " (changes files, in its own worktree)" if task_writes(m) else "",
            human_delta(parse_iso(m["created"])).replace(" ago", ""),
            (" · fallback: %s" % m["fallback"] if m.get("fallback") else "") + hold_mark(m)))
    lines += ([] if pool else ["_empty_"]) + ["", "## Handed out (%d)" % len(out)]
    for m in out:
        lines.append("- **%s** · %s — %s · %s" % (m["id"], m["title"], states[m["id"]], agent_reported(m) or suggestion(m)))
        ww = workdir_win(m)
        nested = nested_worktree(m)
        if m.get("branch") and not nested:
            lines.append("  - worktree folder: `%s`%s · branch `%s`" % (
                m["workdir"], " (Windows: `%s`)" % ww if ww else "", m["branch"]))
        else:
            where = project_dir() if nested else m["workdir"]
            pw = win_path(project_dir()) if nested else ww
            lines.append("  - in the project folder: `%s`%s" % (where, " (Windows: `%s`)" % pw if pw else ""))
            if nested:
                lines.append("  - works in: `%s` (own worktree, branch `%s`)" % (nested, m["branch"]))
        lines.append("  - paste: `%s`" % m["paste"])
    lines += ([] if out else ["_none_"]) + ["", "## Recently finished"]
    for m in done:
        lines.append("- %s %s — %s%s" % (m["id"], states[m["id"]], m["title"],
                                         " (%s)" % (agent_reported(m) or agent_name(m.get("provider"))) if m.get("taken") else ""))
    lines += [] if done else ["_none_"]
    (state_dir() / "MANUAL.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def result_excerpt(m, n=40):
    rp = Path(m["result_path"])
    if not rp.exists():
        return "(no RESULT.md — %s)" % (m.get("manual_note") or "marked manually")
    lines = rp.read_text(encoding="utf-8", errors="replace").splitlines()
    out = "\n".join(lines[:n])
    if len(lines) > n:
        out += "\n…[%d lines, full text: %s]" % (len(lines), rp)
    return out


def mark_final(m, st, log=True):
    """Remember that the final status was reported; log a handed-out task to the usage ledger once."""
    m.setdefault("notified", {})["final"] = iso(now())
    if log and m.get("taken") and not m.get("logged"):
        m["logged"] = True
        proj = project_root(project_dir())
        ledger_append({"kind": "handoff", "session": m.get("session"), "project": canon_path(proj),
                       "project_path": str(proj), "id": m["id"], "provider": m.get("provider"),
                       "label": (m.get("provider") or "") + ("@" + m["profile"] if m.get("profile") else ""),
                       "model": m.get("model") or m.get("model_key"), "agent": agent_reported(m),
                       "effort": m.get("effort"), "task": m["title"], "status": st,
                       "elapsed_s": int((now() - taken_at(m)).total_seconds())})


@locked("project")
def check_events(mark=True, fast=False):
    """Return list of human-readable events not yet reported.
    fast=True: only status transitions read from RESULT.md (no workdir scan, no reminders)."""
    events = []
    t = now()
    metas = [m for m in all_metas() if not m.get("archived")]
    pool_ev = pool_event(metas, mark=mark)          # cheap (no workdir scan): the throttled post-tool hook runs it too
    if pool_ev:
        events.append(pool_ev)
    for m in metas:
        st = result_status(m)
        claim_time = parse_iso(m.get("taken") or "")
        if not fast and st not in TERMINAL and m.get("assigning") and claim_time and \
                (t - claim_time).total_seconds() >= ASSIGNMENT_TIMEOUT_MIN * 60:
            m.pop("assigning", None)
            m["taken"] = None
            if m.get("offered"):
                events.append("⚠ %s assignment expired; returned to the pool." % m["id"])
            else:
                m.update(manual_status="CANCELLED", archived=iso(t), closed=iso(t),
                         manual_note="Assignment expired before completion")
                events.append("⚠ %s assignment expired; task cancelled and archived." % m["id"])
            if mark:
                save_meta(m)
            continue
        activity = last_activity(m) if not fast and st == "WAITING" and not m.get("assigning") else None
        if st == "WAITING" and activity:
            st = "STARTED?"
        note = m.setdefault("notified", {})
        changed = False
        age_min = (t - taken_at(m)).total_seconds() / 60
        if st in TERMINAL and st not in ("CANCELLED", "REASSIGNED") and not note.get("final"):
            who = agent_reported(m)
            events.append("✅ %s finished: STATUS %s — %s%s\n%s" % (m["id"], st, m["title"],
                                                                " (%s)" % who if who else "", result_excerpt(m, 15)))
            mark_final(m, st, log=mark)
            changed = True
        elif st == "IN_PROGRESS" and not note.get("started"):
            events.append("▶ %s picked up (%s) — %s" % (m["id"], agent_reported(m) or agent_name(m.get("provider")),
                                                       m["title"]))
            note["started"] = iso(t)
            changed = True
        elif st == "OFFERED":
            pass                   # the pool is checked as a whole: pool_event
        elif fast:
            pass
        elif st == "WAITING" and not m.get("assigning"):
            if age_min >= m.get("reassign_min", 180) and not note.get("reassign"):
                events.append("⚠ %s not started after %d min. Reassign it to the fallback (%s) and tell the operator."
                              % (m["id"], age_min, m.get("fallback") or "pick one from the registry"))
                note["reassign"] = iso(t)
                changed = True
            elif age_min >= m.get("pickup_min", 30) and not note.get("pickup"):
                events.append("⏰ %s waiting for the operator for %d min — remind them once (do not block your work)."
                              % (m["id"], age_min))
                note["pickup"] = iso(t)
                changed = True
        elif st in ("IN_PROGRESS", "STARTED?") and age_min >= m.get("reassign_min", 180) * 2 and not note.get("overdue"):
            events.append("⚠ %s in progress for %d min without a final status — check with the operator."
                          % (m["id"], age_min))
            note["overdue"] = iso(t)
            changed = True
        if changed and mark:
            save_meta(m)
    return events


def cmd_handoff_check(a):
    events = check_events(mark=not a.peek)
    if events:
        print("Orchestra: manual lane events\n" + "\n".join(events))
    elif not a.quiet:
        print("No new events.")
    return 0


def notify(message):
    """Optional desktop notification: set ORCH_NOTIFY_CMD to a command that takes the message as $1."""
    import subprocess
    cmd = os.environ.get("ORCH_NOTIFY_CMD")
    if not cmd:
        return
    sh = find_bash() if IS_WINDOWS else "/bin/sh"
    if not sh:
        return
    try:
        subprocess.run([sh, "-c", cmd + ' "$1"', "orch-notify", message], timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def hook_input():
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def cmd_hook(a):
    """Claude Code hook entry point. Never fails: any error -> silent exit 0."""
    if os.environ.get("ORCH_WORKER"):
        return 0      # inside a worker the plugin (if loaded at all) must stay silent: events belong to the orchestrator
    try:
        data = hook_input()
        learn_session_id(data)
        if data.get("cwd") and not os.environ.get("ORCH_PROJECT_DIR") and not os.environ.get("CLAUDE_PROJECT_DIR"):
            os.environ["ORCH_PROJECT_DIR"] = data["cwd"]
        sid = data.get("session_id") or session_id()
        if a.event == "session-end":
            forget(sid)               # no longer a Claude consumer
            log_session(data)         # usage snapshot of the main thread + subagents; silent
            try:
                fallback_forget(sid)  # its fallback entry (and any expired one) must not outlive the session
            except Exception:         # a busy lock costs only this cleanup, never the hook
                pass
            return 0
        has_state = (project_dir() / ".orchestra").exists()
        entrypoint = os.environ.get("CLAUDE_CODE_ENTRYPOINT") or ""
        if not entrypoint.startswith("sdk"):
            heartbeat(sid)            # an active instance (for the budget's consumer count); a headless run doesn't count
        try:
            session_budget_hooks(project_dir())
        except Exception:             # a budget problem must not cost this hook its other work
            pass
        if a.event == "session-start":
            out = io_capture(lambda: cmd_status(SimpleNamespace(brief=True)))
            print(out.rstrip())
            print("Route tasks to models with the orchestra:orchestrate skill "
                  "(registry — at the path above; availability — `orch status`).")
            budget_event(sid, announce=False)        # the status above already shows the budget mode
            codex_event(sid, announce=False)         # record the Codex mode so a change later raises a 💡 event
            spend_event(announce=False)              # record the 80%/100% spend thresholds so a change later raises 💡
            fallback_event(announce=False)           # record a move to a fallback profile so the way back raises 💡
            balance_start_refresh(project_dir())     # a stale balance is fetched by a detached process, not awaited
            return 0
        if a.event == "user-prompt":
            events = [e for e in [budget_event(sid), codex_event(sid)] if e] + spend_event() + fallback_event() \
                + (check_events(mark=True) if has_state else [])
            if events:
                print("Orchestra — events since the last message:\n" + "\n".join(events))
            return 0
        if a.event == "post-tool":
            events = [e for e in [budget_event(sid), codex_event(sid)] if e] + spend_event() + fallback_event()   # on a change only
            if has_state:
                stamp = state_dir() / ".last_hook_check"
                last = stamp.stat().st_mtime if stamp.exists() else 0
                if time.time() - last >= a.throttle:
                    stamp.touch()
                    events += check_events(mark=True, fast=True)
            if events:
                print(json.dumps({"hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": "Orchestra — event:\n" + "\n".join(events)}},
                    ensure_ascii=False))
            return 0
        if not has_state:
            return 0
        if a.event == "stop":
            events = check_events(mark=True)
            if events:
                print(json.dumps({"decision": "block", "reason":
                    "Orchestra: manual lane events came in while you were working. Handle them per the "
                    "orchestra:orchestrate skill (integrate the result / remind / pool / reassign), then "
                    "continue:\n" + "\n".join(events)}, ensure_ascii=False))
            return 0
    except Exception:
        return 0
    return 0


def io_capture(fn):
    import io
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    try:
        fn()
    finally:
        sys.stdout = old
    return buf.getvalue()


@locked("project")
def wait_poll(targets, any_task):
    metas = {m["id"]: m for m in all_metas()}
    if targets:
        watch = []
        for hid in targets:
            if hid not in metas:
                raise SystemExit("orch: handoff %s not found" % hid)
            watch.append(metas[hid])
    else:
        watch = [m for m in metas.values() if not m.get("archived") and (
            result_status(m) not in TERMINAL + ("OFFERED",) or (
                result_status(m) in TERMINAL and result_status(m) not in ("CANCELLED", "REASSIGNED")
                and not (m.get("notified") or {}).get("final")))]
    for m in watch:
        st = result_status(m)
        if st in TERMINAL:
            mark_final(m, st)
            save_meta(m)
            return m, None, [x["id"] for x in watch]
    pooled = [m for m in metas.values() if not m.get("archived") and result_status(m) == "OFFERED"]
    event = pool_event([m for m in metas.values() if not m.get("archived")]) if any_task and pooled else None
    return None, event, [m["id"] for m in watch + (pooled if any_task else [])]


def cmd_handoff_wait(a):
    deadline = time.time() + parse_duration(a.timeout, "m") if a.timeout else None
    targets = [h.upper() for h in a.ids]
    if not targets and not a.any:
        raise SystemExit("orch: pass handoff IDs or --any")
    while True:
        m, event, watch = wait_poll(targets, a.any)
        if m:
            st = result_status(m)
            print("%s: STATUS %s — %s\n%s" % (m["id"], st, m["title"], result_excerpt(m)))
            notify("Orchestra: %s — %s (%s)" % (m["id"], st, m["title"]))
            return 0 if st == "DONE" else 2
        if not watch:
            print("No manual tasks to wait for.")
            return 0
        if event:
            print(event)
            notify("Orchestra: manual pool check — nothing taken for a while")
            return 3
        if deadline and time.time() >= deadline:
            print("TIMEOUT: not finished: %s. Check orch handoff list; reassign if needed." % ", ".join(watch))
            return EXIT_TIMEOUT
        time.sleep(a.interval)


def cmd_handoff_show(a):
    m = load_meta(a.id.upper())
    print(operator_card(m))
    print("\nState: %s" % effective_state(m))
    if m.get("task_path"):
        print("TASK:   %s\nRESULT: %s" % (m["task_path"], m["result_path"]))
    if Path(m["result_path"]).exists() or m.get("manual_status"):
        print("\n" + result_excerpt(m, 80))
    return 0


@locked("project")
def cmd_handoff_done(a):
    m = load_meta(a.id.upper())
    st = a.status.upper()
    if st not in TERMINAL:
        raise SystemExit("orch: status must be one of %s" % ", ".join(TERMINAL))
    rp = Path(m["result_path"])
    current = result_status(m)
    if current in TERMINAL and (m.get("reclaim") or {}).get("kind") and not m["reclaim"].get("finished"):
        finish_reclaimed(m["id"], st)      # the orchestrator executed a reclaimed pooled task another way
        print("%s: the reclaimed task is finished (%s)%s" % (m["id"], st, "; the next pooled task may be reclaimed"
                                                             if m["reclaim"]["kind"] == "next" else ""))
        return 0
    if current in TERMINAL and not a.force:
        print("%s is already %s" % (m["id"], current))
        return 0
    m["manual_status"] = st
    m["manual_note"] = a.note or "marked manually by the operator"
    m["closed"] = iso(now())
    mark_final(m, st)        # orchestrator did this itself — no hook event
    if st in ("CANCELLED", "REASSIGNED"):
        if rp.parent.exists():
            rp.write_text("STATUS: %s\n\n%s\n" % (st, m["manual_note"]), encoding="utf-8")
    save_meta(m)
    print("%s → %s (%s)" % (m["id"], st, m["manual_note"]))
    return 0


def cmd_handoff_close(a):
    with state_lock(state_dir() / ".state.lock"):
        m = load_meta(a.id.upper())
        m["archived"] = iso(now())
        save_meta(m)
    if a.remove_worktree and m.get("branch"):
        r = git(["worktree", "remove", "--force", m["workdir"]], project_dir()) if a.force else \
            git(["worktree", "remove", m["workdir"]], project_dir())
        print("worktree removed" if r and r.returncode == 0 else "worktree remove failed: %s" % (r.stderr.strip() if r else "git?"))
    elif a.remove_worktree:
        print("nothing to remove: %s ran in the project folder, without a worktree" % m["id"])
    print("%s closed." % m["id"])
    return 0


# ───────────────────────── usage report (orch usage) ─────────────────────────
#
# Claude Code writes every API response of a session to ~/.claude/projects/<project>/<session>.jsonl (model,
# effort, usage) and each subagent to <session>/subagents/agent-<id>.jsonl (+ .meta.json: agent type,
# description). Streaming splits a response into several lines with the same message id — counted once.

def fmt_tok(n):
    if n is None:
        return "—"
    if n < 1000:
        return str(n)
    if n < 10000:
        return "%.1fk" % (n / 1000.0)
    if n < 1000000:
        return "%dk" % round(n / 1000.0)
    return "%.1fM" % (n / 1000000.0)


def fmt_dur(s):
    if s is None:
        return ""
    s = int(s)
    if s < 60:
        return "%ds" % s
    h, m = divmod(s // 60, 60)
    return ("%dh %dm" % (h, m)) if h else ("%dm" % m)


def usage_brief(u):
    return "tokens: input %s · cache %s · output %s" % (fmt_tok(u.get("input_tokens")),
                                                       fmt_tok(u.get("cached_input_tokens")),
                                                       fmt_tok(u.get("output_tokens")))


def claude_dir():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def transcript_for(session):
    base = claude_dir() / "projects"
    hits = sorted(base.glob("*/%s.jsonl" % session)) if base.is_dir() else []
    if not hits and base.is_dir() and len(session) >= 4:          # id prefix
        hits = sorted(base.glob("*/%s*.jsonl" % session))
    return hits[0] if hits else None


def project_transcripts(project):
    """Transcripts of the project's sessions, newest first (Claude Code names the folder after the path)."""
    base = claude_dir() / "projects"
    name = re.sub(r"[^A-Za-z0-9]", "-", str(project)).lower()
    dirs = [d for d in base.iterdir() if d.is_dir() and d.name.lower() == name] if base.is_dir() else []
    files = [f for d in dirs for f in d.glob("*.jsonl")]
    return sorted(files, key=lambda f: f.stat().st_mtime, reverse=True)


def claude_tokens(u):
    """Anthropic usage → uncached input (incl. cache writes), cache reads, output."""
    return {"input_tokens": int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0),
            "cached_input_tokens": int(u.get("cache_read_input_tokens") or 0),
            "output_tokens": int(u.get("output_tokens") or 0)}


def parse_transcript(path):
    path = Path(path)
    msgs, agents = {}, {}
    info = {"session": path.stem, "title": None, "start": None, "end": None, "cost_usd": None}

    def scan(f, who):
        with f.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"type":"assistant"' in line:
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
                    model = msg.get("model")
                    if ev.get("type") != "assistant" or not model or model.startswith("<"):
                        continue
                    owner = "agent:" + ev["agentId"] if ev.get("isSidechain") and ev.get("agentId") else who
                    msgs[msg.get("id") or ev.get("requestId") or ev.get("uuid")] = (owner, model, ev.get("effort"),
                                                                                     msg.get("usage") or {})
                    if who == "main" and ev.get("timestamp"):
                        info["start"] = info["start"] or ev["timestamp"]
                        info["end"] = ev["timestamp"]
                elif '"type":"ai-title"' in line or '"type":"cost-state"' in line:
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    if ev.get("type") == "ai-title" and ev.get("aiTitle"):
                        info["title"] = ev["aiTitle"]
                    elif ev.get("type") == "cost-state" and ev.get("totalCostUSD") is not None:
                        info["cost_usd"] = ev["totalCostUSD"]

    scan(path, "main")
    sub = path.with_suffix("") / "subagents"
    if sub.is_dir():
        for f in sorted(sub.glob("agent-*.jsonl")):
            meta = read_json(f.with_name(f.stem + ".meta.json"), {}) or {}
            agents[f.stem[len("agent-"):]] = meta
            scan(f, "agent:" + f.stem[len("agent-"):])
    rows = {}
    for owner, model, effort, u in msgs.values():
        r = rows.setdefault((owner, model), {"model": model, "efforts": [], "calls": 0, "input_tokens": 0,
                                             "cached_input_tokens": 0, "output_tokens": 0})
        r["calls"] += 1
        for k, v in claude_tokens(u).items():
            r[k] += v
        if effort and effort not in r["efforts"]:
            r["efforts"].append(effort)
    out = []
    for (owner, model), r in rows.items():
        if owner.startswith("agent:"):
            meta = agents.get(owner[6:], {})
            r.update({"who": "subagent", "agent_type": meta.get("agentType"), "task": meta.get("description")})
        else:
            r.update({"who": "main", "task": None})
        out.append(r)
    out.sort(key=lambda r: (r["who"] != "main", -(r["input_tokens"] + r["cached_input_tokens"] + r["output_tokens"])))
    info["rows"] = out
    return info


def log_session(data):
    """SessionEnd hook: keep the session's numbers in the ledger (transcripts are cleaned up after a while)."""
    tp = data.get("transcript_path")
    if not tp or not Path(tp).is_file():
        return
    info = parse_transcript(tp)
    if not info["rows"]:
        return
    proj = project_root(project_dir())
    lead = os.environ.get("ORCH_LEAD")
    # cost_usd is Claude Code's own totalCostUSD; spend_usd is our token×price estimate for the lead's API billing
    spend_usd = session_cost({"lead": lead, "rows": info["rows"]}) if lead else None
    ledger_append({"kind": "session", "session": data.get("session_id") or info["session"], "project": canon_path(proj),
                   "project_path": str(proj), "title": info["title"], "start": info["start"], "end": info["end"],
                   "cost_usd": info["cost_usd"], "spend_usd": spend_usd, "rows": info["rows"], "lead": lead})


def session_data(sid, ledger):
    """(info, external records) of a session: live transcript if it still exists, else the SessionEnd snapshot."""
    tp = transcript_for(sid)
    info = parse_transcript(tp) if tp else None
    if info:
        sid = info["session"]
        info["lead"] = next((r.get("lead") for r in reversed(ledger)
                             if r.get("kind") == "session" and r.get("session") == sid), None)
    else:
        snaps = [r for r in ledger if r.get("kind") == "session" and str(r.get("session", "")).startswith(sid)]
        info = dict(snaps[-1]) if snaps else {"session": sid, "title": None, "start": None, "end": None, "rows": [],
                                             "cost_usd": None}
        sid = info["session"]
    ext = [r for r in ledger if r.get("kind") in ("run", "handoff") and r.get("session") == sid]
    return info, ext


def short_time(ts):
    t = parse_iso(ts.replace("Z", "+00:00")) if ts else None
    return t.astimezone().strftime("%d.%m %H:%M") if t else "?"


def usage_rows(info, ext, display=False):
    """Uniform rows: who, model, effort, what for, tokens. With display=True the ids are shown as their
    official names (models via display_name, manual who labels via scope_name); --json always uses raw ids."""
    out = []
    for r in info["rows"]:
        who = "orchestrator" if r["who"] == "main" else "subagent " + (r.get("agent_type") or "?").split(":")[-1]
        model = r["model"]
        if display:
            model = display_name(model) or model
        out.append({"who": who, "model": model, "effort": ",".join(r.get("efforts") or []),
                    "task": r.get("task") or ("main thread" if r["who"] == "main" else ""), "usage": r})
    for r in ext:
        manual = r["kind"] == "handoff"
        who_label = r.get("label") or r.get("provider") or "?"
        model = r.get("agent") or r.get("model") or "(default)"
        if display:
            who_label = scope_name(who_label) or who_label
            model = display_name(model) or model
        out.append({"who": who_label + (" (manual)" if manual else ""), "model": model,
                    "effort": r.get("effort") or "",
                    "task": "%s · %s · %s" % (r.get("task") or "", r.get("status"), fmt_dur(r.get("elapsed_s"))),
                    "usage": r.get("usage")})
    return out


def print_session(info, ext):
    span = "%s–%s" % (short_time(info.get("start")), short_time(info.get("end"))[-5:]) if info.get("start") else "time ?"
    lead = info.get("lead") or (os.environ.get("ORCH_LEAD") if info["session"] == session_id() else None)
    main_models = {str(r.get("model")) for r in info.get("rows") or [] if r.get("who") == "main"} - {"<synthetic>"}
    if not lead and main_models and not any(m.startswith("claude") for m in main_models):
        lead = ", ".join(sorted(main_models))         # a session started with orch launch, seen in its transcript
    print("Session %s · %s · %s%s" % (info["session"][:8], ("“%s”" % info["title"]) if info.get("title") else "untitled",
                                      span, " · lead: %s" % display_name(lead) if lead else ""))
    rows = usage_rows(info, ext, display=True)
    if not rows:
        print("  (no usage data)")
        return
    def cut(s, n):
        return s if len(s) <= n else s[:n - 1] + "…"
    print("  %-28s %-24s %-7s %-44s %7s %7s %7s" % ("who", "model", "effort", "what for", "input", "cache", "output"))
    totals = {}
    for r in rows:
        u = r["usage"] or {}
        print("  %-28s %-24s %-7s %-44s %7s %7s %7s" % (cut(r["who"], 28), cut(r["model"], 24), cut(r["effort"], 7),
                                                       cut(r["task"], 44), fmt_tok(u.get("input_tokens")),
                                                       fmt_tok(u.get("cached_input_tokens")), fmt_tok(u.get("output_tokens"))))
        if r["usage"]:
            t = totals.setdefault(r["model"], [0, 0, 0])
            for i, k in enumerate(("input_tokens", "cached_input_tokens", "output_tokens")):
                t[i] += int(u.get(k) or 0)
    print("  Totals by model:")
    for model, (i, c, o) in sorted(totals.items(), key=lambda kv: -sum(kv[1])):
        print("    %-24s input %s · cache %s · output %s" % (model, fmt_tok(i), fmt_tok(c), fmt_tok(o)))
    if info.get("cost_usd") and lead:
        print("  Claude Code's estimate ($%.2f) assumes Claude prices: not meaningful with a %s lead." % (
            info["cost_usd"], display_name(lead)))
    elif info.get("cost_usd"):
        print("  Claude Code estimates the session at $%.2f at API prices (notional on a subscription)." % info["cost_usd"])
    if any(r["who"].endswith("(manual)") for r in rows):
        print("  Manual executors do not report tokens: for them the agent, model and time are shown.")


def cmd_usage(a):
    ledger = ledger_read()
    proj = project_root(project_dir())
    if a.list:
        seen, lines = set(), []
        for tp in project_transcripts(proj)[:a.limit]:
            info = parse_transcript(tp)
            seen.add(info["session"])
            lines.append((info, [r for r in ledger if r.get("session") == info["session"] and r.get("kind") != "session"]))
        for r in reversed(ledger):
            sid = r.get("session")
            if r.get("project") == canon_path(proj) and sid and sid not in seen and len(lines) < a.limit:
                seen.add(sid)
                lines.append(session_data(sid, ledger))
        if a.json:
            print(json.dumps([{"session": i["session"], "title": i.get("title"), "start": i.get("start"),
                               "rows": usage_rows(i, e)} for i, e in lines], ensure_ascii=False, indent=2))
            return 0
        if not lines:
            print("No sessions with usage data for %s." % canon_path(proj))
        for info, ext in lines:
            tok = sum(int((r["usage"] or {}).get(k) or 0) for r in usage_rows(info, ext)
                      for k in ("input_tokens", "output_tokens"))
            models = sorted({display_name(r["model"]) for r in usage_rows(info, ext)})
            print("%s  %s  %-40s  %s tokens (uncached) · %s" % (
                short_time(info.get("start")), info["session"][:8], (info.get("title") or "")[:40], fmt_tok(tok),
                ", ".join(models)[:80]))
        print("Details: orch usage --session <id>")
        return 0
    sid = a.session or session_id()
    if not sid:
        latest = project_transcripts(proj)
        sid = latest[0].stem if latest else next((r["session"] for r in reversed(ledger)
                                                   if r.get("project") == canon_path(proj) and r.get("session")), None)
    if not sid:
        print("No session to show: pick one with orch usage --list / --session <id>.")
        return 1
    info, ext = session_data(sid, ledger)
    if a.json:
        print(json.dumps({"session": info["session"], "title": info.get("title"), "start": info.get("start"),
                          "end": info.get("end"), "cost_usd": info.get("cost_usd"), "rows": usage_rows(info, ext)},
                         ensure_ascii=False, indent=2))
        return 0
    print_session(info, ext)
    return 0


# ───────────────────────── guide / footprint ─────────────────────────

GUIDE_DIR = PLUGIN_ROOT / "skills" / "orchestrate" / "reference"


def cmd_guide(a):
    """Reference parts of the orchestrate skill, loaded only when needed (keeps the skill itself small)."""
    topics = sorted(p.stem for p in GUIDE_DIR.glob("*.md"))
    if not a.topic:
        print("Topics: %s\norch guide <topic>" % ", ".join(topics))
        return 0
    p = GUIDE_DIR / (a.topic.lower() + ".md")
    if not p.is_file():
        raise SystemExit("orch: no topic %r (available: %s)" % (a.topic, ", ".join(topics)))
    print(p.read_text(encoding="utf-8").rstrip())
    return 0


def cmd_footprint(a):
    """What Orchestra created outside Claude Code's own plugin registry — the cleanup list after uninstalling."""
    print("In Claude Code (the standard way): the orchestra marketplace and the orchestra@orchestra plugin "
          "with its hooks, commands, subagents and skill.\n"
          "  Disable: claude plugin disable orchestra@orchestra · remove: "
          "claude plugin uninstall orchestra@orchestra && claude plugin marketplace remove orchestra")
    print("Outside Claude Code:")
    for p in (Path.home() / ".local" / "bin" / "orch", Path.home() / ".local" / "bin" / "orch.cmd"):
        if p.exists() or p.is_symlink():
            print("  %s — orch launcher" % p)
    if ORCH_HOME.exists():
        print("  %s — personal data: %s" % (ORCH_HOME, ", ".join(sorted(
            c.name + ("/" if c.is_dir() else "") for c in ORCH_HOME.iterdir())) or "empty"))
    data, _ = load_profiles()
    for provider in data["providers"]:
        for name, d in provider_section(data, provider)[1].items():
            home = local_path(str(d["home"])) if isinstance(d, dict) and d.get("home") else None
            if home and Path(home).exists():
                print("  %s — account directory of profile %s@%s (holds the login; delete it yourself if the account "
                      "is no longer needed)" % (home, provider, name))
    projects = {r.get("project_path") for r in ledger_read() if r.get("project_path")}
    if (project_dir() / ".orchestra").exists():
        projects.add(str(project_root(project_dir())))
    for p in sorted(x for x in projects if x):
        p = Path(p)
        found = [s for s in (p / ".orchestra", p / AG_RULE_PATH, p.parent / (p.name + ".wt")) if s.exists()]
        if found:
            print("  project %s: %s (+ their lines in .git/info/exclude; %s is the general Antigravity rule, which "
                  "stays after a task closes; .orchestra/wt/ holds the worktrees of tasks that change files, and if "
                  ".orchestra/ is deleted by hand run `git worktree prune` there)"
                  % (p, ", ".join(str(s) for s in found), AG_RULE_PATH))
    print("Remove everything outside Claude Code: bash uninstall.sh --purge (without --purge personal data is kept).")
    return 0


# ───────────────────────── registry ─────────────────────────

REGISTRY_BUILTIN = PLUGIN_ROOT / "registry" / "providers.yaml"
REGISTRY_MARKER_PREFIX = "# orchestra-registry-base:"
REGISTRY_MARKER_RE = re.compile(r"^# orchestra-registry-base:\s*(\S+)\s+sha256:([0-9a-f]{16})\s*$")


def registry_path():
    for p in (project_dir() / ".orchestra" / "providers.yaml", ORCH_HOME / "providers.yaml",
              PLUGIN_ROOT / "registry" / "providers.yaml"):
        if p.exists():
            return p
    return PLUGIN_ROOT / "registry" / "providers.yaml"


def plugin_version():
    """The plugin version from .claude-plugin/plugin.json (for the registry marker), or '?' when unreadable."""
    try:
        data = json.loads((PLUGIN_ROOT / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
        return str(data.get("version") or "?")
    except Exception:
        return "?"


def registry_builtin():
    """(text, first 16 hex of the SHA-256) of the built-in registry."""
    import hashlib
    data = REGISTRY_BUILTIN.read_bytes()
    return data.decode("utf-8"), hashlib.sha256(data).hexdigest()[:16]


def registry_body(text):
    """The registry's lines without the marker line: what a copy really adds or changes."""
    return [line for line in text.splitlines() if not line.startswith(REGISTRY_MARKER_PREFIX)]


def registry_marker(text):
    """(version, hash) recorded in the copy's marker line, or None."""
    for line in text.splitlines():
        m = REGISTRY_MARKER_RE.match(line)
        if m:
            return m.group(1), m.group(2)
    return None


def registry_copy_state():
    """(is_copy, stale, version) for the registry in effect: whether it is a personal/project copy, whether that
    copy has gone stale against the built-in registry, and the version recorded in its marker (None without one).
    Never raises: any error reads as "no copy, not stale"."""
    try:
        cur = registry_path()
        if cur == REGISTRY_BUILTIN:
            return False, False, None
        text = cur.read_text(encoding="utf-8")
        builtin_text, digest = registry_builtin()
        marker = registry_marker(text)
        if marker is not None:
            return True, marker[1] != digest, marker[0]
        return True, registry_body(text) != registry_body(builtin_text), None
    except Exception:
        return False, False, None


def registry_stale_note():
    """The one-line warning for status and doctor when the copy in effect lags the built-in registry, else None.
    Never raises."""
    _, stale, version = registry_copy_state()
    if not stale:
        return None
    return ("the built-in registry has changed since this copy was made (%s): orch registry diff"
            % (version or "an older version"))


def registry_marker_line():
    version, digest = plugin_version(), registry_builtin()[1]
    return "# orchestra-registry-base: %s sha256:%s" % (version, digest)


def registry_write(path, text):
    """Write LF-only (the repository and its registry are LF, also on Windows)."""
    with open(str(path), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def registry_diff(a):
    if registry_path() == REGISTRY_BUILTIN:
        print("No personal or project copy: the built-in registry is in effect.")
        return 0
    import difflib
    cur = registry_path()
    builtin_text, digest = registry_builtin()
    copy_text = cur.read_text(encoding="utf-8")
    if a.accept:
        body = registry_body(copy_text)
        registry_write(cur, registry_marker_line() + "\n" + ("\n".join(body) + "\n" if body else ""))
        print("accepted: %s now records %s sha256:%s" % (cur, plugin_version(), digest))
        return 0
    lines = list(difflib.unified_diff(registry_body(builtin_text), registry_body(copy_text),
                                      fromfile=str(REGISTRY_BUILTIN), tofile=str(cur), lineterm=""))
    if lines:
        print("\n".join(lines))
    print("This copy overrides the whole built-in registry. Take over what you need from the built-in one, "
          "then record it as current: orch registry diff --accept")
    return 0


def cmd_registry(a):
    if a.action == "path":
        print(registry_path())
    elif a.action == "show":
        print(registry_path().read_text(encoding="utf-8"))
    elif a.action == "init":
        dest = (project_dir() / ".orchestra" / "providers.yaml") if a.project else (ORCH_HOME / "providers.yaml")
        if dest.exists() and not a.force:
            print("already exists: %s" % dest)
            return 0
        if a.project:
            state_dir()
        dest.parent.mkdir(parents=True, exist_ok=True)
        registry_write(dest, registry_marker_line() + "\n" + registry_builtin()[0])
        print("created: %s (edit it; it overrides the built-in registry)" % dest)
    elif a.action == "diff":
        return registry_diff(a)
    return 0


# ───────────────────────── status / doctor ─────────────────────────

def cmd_status(a):
    if not a.brief:                    # the SessionStart hook (brief) starts a detached fetch instead of waiting for one
        balance_refresh_stale(project_dir())
    data = load_avail()
    lines = [lead_line()] if lead_line() else []
    if a.brief:
        line = "Orchestra: executor registry — %s" % registry_path()
        note = registry_stale_note()
        if note:
            line += " · " + note
        lines.append(line)
    mode, budget = claude_budget()
    if budget:
        lines.append(budget)
    _, codex = codex_budget()
    if codex:
        lines.append(codex)
    spend = spend_status_part(project_dir())
    if spend:
        lines.append(spend)
    lines += balance_status_lines(project_dir())
    if data["entries"]:
        lines.append("Availability restrictions:")
        lines += ["  " + describe_entry(k, e) for k, e in sorted(data["entries"].items())]
    else:
        lines.append("No availability restrictions — every executor in the registry is available.")
    if PROFILES_FILE.exists():
        where = project_dir()
        lines.append("Executor profiles for %s (orch profile show):" % canon_path(project_root(where)))
        lines += profile_lines(where, budget=False)
    metas =[m for m in all_metas() if result_status(m) not in TERMINAL] if (project_dir() / ".orchestra").exists() else []
    if metas:
        lines.append("Open manual tasks (pooled and handed out; board .orchestra/MANUAL.md):")
        lines += ["  " + handoff_line(m) for m in metas]
    if not a.brief:
        events = check_events(mark=False)
        if events:
            lines.append("Unreported events:")
            lines += ["  " + ev.splitlines()[0] for ev in events]
    print("\n".join(lines))
    return 0


def orch_path_hint(home=None):
    """The doctor hint for an `orch` that is not on PATH: the launchers may exist already, with their folder off PATH."""
    bindir = Path(home or Path.home()) / ".local" / "bin"
    if (bindir / ("orch.cmd" if IS_WINDOWS else "orch")).exists():
        return ("the launcher exists in ~/.local/bin, but that folder is not on PATH: add it, then open a new terminal "
                "(README: If orch isn't found)")
    if IS_WINDOWS:
        return "bash install.sh (creates the orch and orch.cmd launchers in ~/.local/bin)"
    return "ln -s %s ~/.local/bin/orch" % Path(__file__).resolve()


def launcher_python_warning(home=None):
    """The doctor warning for the Git Bash launcher in ~/.local/bin/orch: a bare interpreter command that resolves to
    the Microsoft Store alias, or an interpreter path that is gone, makes every `orch` call slower (about 0.2 s a
    start) or impossible; re-running install.sh records the current interpreter. None on POSIX (a symlink), when the
    launcher is missing and when it is fine."""
    try:
        path = Path(home or Path.home()) / ".local" / "bin" / "orch"
        if path.is_symlink():
            return None                 # POSIX install: a symlink to bin/orch, no interpreter named
        with path.open(encoding="utf-8", errors="replace") as f:
            if f.readline().strip() != "#!/bin/sh":
                return None
            match = None
            for line in f:
                match = re.match(r"\s*exec\s+(?:\"([^\"]+)\"|'([^']+)'|(\S+))", line)
                if match:
                    break
    except (OSError, RuntimeError):
        return None
    if not match:
        return None
    exe = match.group(1) or match.group(2) or match.group(3)
    if "/" not in exe and "\\" not in exe:      # the launcher of an older install: the bare command name
        import shutil
        resolved = shutil.which(exe)
        if resolved and "windowsapps" in resolved.replace("\\", "/").lower():
            return ("runs the Microsoft Store alias %s (%s): every orch call pays about 0.2 s more; re-run "
                    "`bash install.sh` to record the real interpreter" % (exe, resolved))
        return None
    if not Path(exe).exists():
        return ("records %s, which does not exist: orch does not start; re-run `bash install.sh` to record the "
                "current interpreter" % exe)
    return None


def cmd_doctor(a):
    import shutil
    import subprocess
    ok = True

    def row(name, good, info, optional=False):
        nonlocal ok
        ok = ok and (good or optional)
        print("%s %-22s %s" % ("✔" if good else "·" if optional else "✘", name, info))

    row("platform", True, platform_name())
    row("python", sys.version_info >= (3, 8), sys.version.split()[0])
    row("git", bool(shutil.which("git")), shutil.which("git") or "not found")
    if IS_WINDOWS:
        bash = find_bash()
        row("bash (shell adapters)", bool(bash), bash or "needed only for shell adapters: Git for Windows", optional=True)
    cx, note = find_codex()
    row("Codex CLI", bool(cx), (cx + note) if cx else "optional: npm i -g @openai/codex && codex login (or ORCH_CODEX_BIN)",
        optional=True)
    if cx:
        try:
            r = subprocess.run(exe_command(cx) + ["login", "status"], capture_output=True, text=True, timeout=20,
                               stdin=subprocess.DEVNULL)
            row("Codex login", r.returncode == 0, (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else "?")
        except Exception as ex:
            row("Codex login", False, str(ex))
    cl = os.environ.get("ORCH_CLAUDE_BIN") or shutil.which("claude")
    row("Claude CLI (headless)", bool(cl), cl or "needed for the DeepSeek and Claude executors and orch launch",
        optional=True)
    if os.environ.get("ORCH_LEAD"):
        row("lead", True, "%s · %s (orch launch)" % (display_name(os.environ["ORCH_LEAD"]),
                                                     display_name(os.environ.get("ORCH_LEAD_MODEL")) or "?"))
    src = secret_source("DEEPSEEK_API_KEY")
    row("DEEPSEEK_API_KEY", bool(src), ("set: " + src) if src else "missing — add a line DEEPSEEK_API_KEY=sk-… to %s"
        % SECRETS_FILE, optional=True)
    data, err = load_profiles()
    if err:
        row("profiles", False, err)
    elif PROFILES_FILE.exists():
        row("profiles", True, str(PROFILES_FILE))
        for provider in sorted(data["providers"]):
            for name, d in provider_section(data, provider)[1].items():
                d = d if isinstance(d, dict) else {}
                if d.get("key"):
                    src = secret_source(d["key"])
                    row("%s@%s key" % (display_name(provider), name), bool(src), ("%s set: %s" % (d["key"], src)) if src else
                        "missing — add a line %s=… to %s" % (d["key"], SECRETS_FILE), optional=True)
                if provider == "codex" and d.get("home") and not d.get("key") and cx:
                    home = local_path(str(d["home"]))
                    try:
                        r = subprocess.run(exe_command(cx) + ["login", "status"], capture_output=True, text=True,
                                           timeout=20, stdin=subprocess.DEVNULL,
                                           env=dict(os.environ, CODEX_HOME=home))
                        info = ((r.stdout or r.stderr).strip().splitlines() or ["?"])[0]
                        row("Codex@%s login" % name, r.returncode == 0, info if r.returncode == 0 else
                            "%s — %s" % (info, login_hint(home)), optional=True)
                    except Exception as ex:
                        row("Codex@%s login" % name, False, str(ex), optional=True)
    row("orch on PATH", bool(shutil.which("orch")), shutil.which("orch") or orch_path_hint())
    note = launcher_python_warning()
    if note:
        print("⚠ %-22s %s" % ("orch launcher", note))
    row("registry", registry_path().exists(), str(registry_path()))
    note = registry_stale_note()
    if note:
        print("⚠ %-22s %s" % ("registry copy", note))
    row("adapters", True, ", ".join(sorted({p.name for b in (ORCH_HOME / "adapters", PLUGIN_ROOT / "adapters")
                                             if b.exists() for p in b.iterdir()
                                             if p.is_file() and not p.name.startswith(("_", "."))})) or "none")
    clip = next((c for c in ("clip.exe", "wl-copy", "xclip", "pbcopy") if shutil.which(c)), None)
    row("clipboard (optional)", True, clip or "none — copy the paste line by hand")
    return 0 if ok else 1


# ───────────────────────── argparse ─────────────────────────

def utf8_stdio():
    """Pipes default to the ANSI code page on Windows (and to ASCII under LANG=C): Claude Code reads hook output as UTF-8."""
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def statusline_args(argv):
    """The arguments of a plain `statusline [--then CMD]`, or None for anything else: building the whole parser below
    costs more than the rest of a status line run, and argparse also deals with what this does not recognize."""
    if argv == ["statusline"]:
        then = None
    elif len(argv) == 3 and argv[:2] == ["statusline", "--then"] and not argv[2].startswith("-"):
        then = argv[2]
    else:
        return None
    return SimpleNamespace(cmd="statusline", then=then, fn=cmd_statusline)


HOOK_EVENTS = ("session-start", "user-prompt", "post-tool", "stop", "session-end")


def hook_args(argv):
    """The arguments of a plain `orch hook <event> [--throttle N]`, or None for anything else (`--help`, an unknown
    event or option, an error): building the whole parser below costs more than the hook's own work on every user
    message and tool call, and argparse still deals with what this does not recognize."""
    if not argv or argv[0] != "hook":
        return None
    event, throttle, i = None, 60, 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--throttle":
            if i + 1 >= len(argv):
                return None
            try:
                throttle = int(argv[i + 1])
            except ValueError:
                return None
            i += 2
        elif arg in HOOK_EVENTS and event is None:
            event = arg
            i += 1
        else:
            return None
    if event is None:
        return None
    return SimpleNamespace(cmd="hook", event=event, throttle=throttle, fn=cmd_hook)


def parse_args(argv):
    import argparse
    p = argparse.ArgumentParser(prog="orch", description="Orchestra helper CLI")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status", help="availability + open handoffs")
    s.add_argument("--brief", action="store_true")
    s.set_defaults(fn=cmd_status)

    q = sub.add_parser("quota", help="provider availability")
    qs = q.add_subparsers(dest="action", required=True)
    x = qs.add_parser("set")
    x.add_argument("key", help="provider[/model], e.g. codex, codex/gpt-5.6-sol, antigravity/gemini-4-argon, claude/opus, operator")
    x.add_argument("status", help="|".join(STATUSES) + "; busy is set automatically for capacity and lifts by itself")
    x.add_argument("--until", help="+3h | 18:00 | 2026-10-26 09:00 | tomorrow 09:00")
    x.add_argument("--note")
    x = qs.add_parser("clear")
    x.add_argument("key")
    x = qs.add_parser("show")
    x.add_argument("--json", action="store_true")
    x = qs.add_parser("check")
    x.add_argument("key")
    q.set_defaults(fn=cmd_quota)

    r = sub.add_parser("run", help="run automated executor via adapter")
    r.add_argument("provider")
    r.add_argument("--model")
    r.add_argument("--effort")
    r.add_argument("--mode", choices=("analysis", "write"), default="analysis")
    r.add_argument("--cd", help="working directory (e.g. a worktree)")
    r.add_argument("--timeout", default="45m", help="e.g. 30m, 2h")
    r.add_argument("--prompt-file")
    r.add_argument("--max-chars", type=int, default=6000)
    r.add_argument("--quota-backoff", type=int, default=60, help="minutes to block provider when reset time unknown")
    r.add_argument("--quota-scope", choices=("provider", "model"), default="provider")
    r.add_argument("--allow", action="append", metavar="RULE",
                   help="extra permission for the worker, e.g. 'Bash(npm test:*)' (repeatable; deepseek)")
    r.add_argument("--profile", help="one-off profile instead of the project's (only on the operator's request)")
    r.add_argument("--task", help="short title for the usage log (default: first line of the prompt)")
    r.add_argument("--handoff", metavar="ID", help="the reclaimed pooled task this run executes (marked finished on OK)")
    r.add_argument("--force", action="store_true", help="ignore availability block")
    r.add_argument("prompt", nargs="*")
    r.set_defaults(fn=cmd_run)

    x = sub.add_parser("budget", help="Claude subscription budget for routing: surplus (use it) / tight (conserve)")
    x.add_argument("action", nargs="?", choices=("show", "set", "clear"), default="show")
    x.add_argument("--used", type=float, help="set: percent of the 5-hour window used")
    x.add_argument("--resets", help="set: when the 5-hour window resets (18:00, +2h, …)")
    x.add_argument("--week", type=float, help="set: percent of the weekly limit used")
    x.add_argument("--week-resets", help="set: when the weekly limit resets")
    x.set_defaults(fn=cmd_budget)

    x = sub.add_parser("statusline", help="Claude Code statusLine command: records rate_limits, prints a short line")
    x.add_argument("--then", metavar="CMD", help="your own status line command; its output comes first")
    x.set_defaults(fn=cmd_statusline)

    sp = sub.add_parser("spend", help="USD limits for API-billed executors (DeepSeek always; key profiles)")
    sp.set_defaults(fn=cmd_spend, action="show")
    ss = sp.add_subparsers(dest="action")
    x = ss.add_parser("show", help="limits, spend and modes (default)")
    x = ss.add_parser("limit", help="set a USD limit (or 'off') for a scope")
    x.add_argument("scope", help="default | a provider | <provider>@<profile>")
    x.add_argument("value", help="USD amount or 'off'")
    x.add_argument("--project", nargs="?", const=".", metavar="PATH",
                   help="this project's own limit (PATH for another project); default: global")
    x.add_argument("--reset", choices=("month", "manual"), help="also set the reset kind")
    x = ss.add_parser("mode", help="set the executor (or --lead) mode: stop | evaluate | continue")
    x.add_argument("scope")
    x.add_argument("value", choices=("stop", "evaluate", "continue"))
    x.add_argument("--lead", action="store_true", help="the lead mode instead of the executor mode")
    x.add_argument("--overrun", metavar="PCT", help="how far past the limit counts as material (percent)")
    x.add_argument("--project", nargs="?", const=".", metavar="PATH",
                   help="this project's own mode (PATH for another project); default: global")
    x = ss.add_parser("reset", help="count from zero from now (top-up); optionally set a new limit")
    x.add_argument("scope")
    x.add_argument("--limit", metavar="USD", help="set a new limit with the reset")
    x.add_argument("--project", nargs="?", const=".", metavar="PATH",
                   help="this project's own counter (PATH for another project); default: global")

    x = sub.add_parser("balance", help="the provider's own balance of the account behind each API key (DeepSeek)")
    x.add_argument("scopes", nargs="*", metavar="SCOPE", help="only these scopes (provider@profile); default: all keys")
    x.add_argument("--json", action="store_true")
    x.add_argument("--quiet", action="store_true", help="fetch and store, print nothing, always exit 0")
    x.set_defaults(fn=cmd_balance)

    x = sub.add_parser("launch", help="start Claude Code with another model as the lead (e.g. deepseek)")
    x.add_argument("provider", help="an adapter declaring `# orch-launch: env` (deepseek)")
    x.add_argument("--profile", help="the lead's profile (key, models) instead of the project's")
    x.add_argument("--model", help="the lead's model (default: the profile's first, else the adapter's default)")
    x.add_argument("--no-claude", action="store_true", help="no Claude models at all in this session (claude=off)")
    x.add_argument("--use", action="append", metavar="PROVIDER=PROFILE",
                   help="session-wide profile choice, e.g. codex=alt (repeatable)")
    x.add_argument("--dry-run", action="store_true", help="print the command and environment (secrets masked)")
    x.add_argument("--force", action="store_true", help="start even if the lead's quota is marked exhausted")
    x.set_defaults(fn=cmd_launch, claude_args=[])      # orch launch deepseek … -- <claude arguments>, see below

    f = sub.add_parser("profile", help="executor profiles: keys/accounts, models, rules; default and per project")
    fs = f.add_subparsers(dest="action", required=True)
    x = fs.add_parser("show", help="active profile of every executor for this project")
    x.add_argument("--path", help="directory instead of the current project")
    x.add_argument("--json", action="store_true")
    x = fs.add_parser("list", help="all profiles, defaults and directory bindings")
    x.add_argument("provider", nargs="?")
    x.add_argument("--json", action="store_true")
    x = fs.add_parser("rules", help="show or change project directory rules")
    x.add_argument("--path", help="directory instead of the current project")
    xg = x.add_mutually_exclusive_group()
    xg.add_argument("--set", metavar="TEXT", help="set rules; an empty value clears them")
    xg.add_argument("--clear", action="store_true", help="clear rules")
    x = fs.add_parser("use", help="bind a profile (or off / inherit) to this project, a directory or the default")
    x.add_argument("provider")
    x.add_argument("name", help="profile | off | inherit")
    xg = x.add_mutually_exclusive_group()
    xg.add_argument("--default", action="store_true", help="provider default for every project")
    xg.add_argument("--path", help="bind to this directory (covers its subdirectories)")
    x = fs.add_parser("set", help="create or update a profile ('' removes a field)")
    x.add_argument("--session-soft", help="account balance decrease in percent; ignored while Claude is TIGHT")
    x.add_argument("--session-hard", help="maximum account balance decrease in percent, including TIGHT")
    x.add_argument("--balance-floor", help="minimum account balance in its currency, including TIGHT")
    x.add_argument("provider")
    x.add_argument("name")
    x.add_argument("--key", help="NAME of the variable in secrets.env holding the API key (not the key itself)")
    x.add_argument("--models", help="allowed models, comma-separated; the first is the default")
    x.add_argument("--max-effort", help="|".join(EFFORT_ORDER))
    x.add_argument("--write", help="yes|no — may the executor change files")
    x.add_argument("--use-for", help="task types it may take: tests,docs,review,… (empty = any)")
    x.add_argument("--prefer-for", help="task types to route to it first")
    x.add_argument("--rules", help="free-text rules the orchestrator follows for this profile")
    x.add_argument("--max-open", help="manual lane: open handoffs at most")
    x.add_argument("--fallback", help="another profile of this provider that takes over while this one is exhausted "
                                      "(its spend limit reached, or marked exhausted/disabled); 'none' clears it")
    x.add_argument("--home", help="codex: CODEX_HOME of the account (created; then codex login); "
                                  "claude: CLAUDE_CONFIG_DIR of the account")
    x.add_argument("--codex-profile", help="codex: --profile <name> ($CODEX_HOME/<name>.config.toml)")
    x.add_argument("--fast-model", help="deepseek: model for the worker's light background calls")
    x.add_argument("--base-url", help="deepseek: Anthropic-compatible endpoint")
    x.add_argument("--opt", action="append", metavar="FIELD=VALUE", help="adapter-specific field (# orch-profile-env)")
    x.add_argument("--default", action="store_true", help="also make it the provider default")
    x = fs.add_parser("rm", help="delete a profile")
    x.add_argument("provider")
    x.add_argument("name")
    x.add_argument("--force", action="store_true", help="also drop the default/bindings that use it")
    f.set_defaults(fn=cmd_profile)

    w = sub.add_parser("worktree", help="git worktree helpers")
    ws = w.add_subparsers(dest="action", required=True)
    x = ws.add_parser("add")
    x.add_argument("name")
    x.add_argument("--base", default="HEAD")
    x.add_argument("--branch")
    w.set_defaults(fn=cmd_worktree)

    h = sub.add_parser("handoff", help="manual lane (Antigravity)")
    hs = h.add_subparsers(dest="action", required=True)
    x = hs.add_parser("new")
    x.add_argument("--title", required=True)
    x.add_argument("--provider", default="antigravity")
    x.add_argument("--model", help="display name for the operator, e.g. 'Gemini 4 Argon'")
    x.add_argument("--model-key", help="availability key part, e.g. gemini-4-argon")
    x.add_argument("--effort", help="thinking level to select, e.g. High")
    x.add_argument("--prompt-file")
    x.add_argument("--write", action="store_true",
                   help="the task changes files: it gets a worktree of its own, .orchestra/wt/<id> on branch ag/<id> "
                        "(default: read-only, in the project folder)")
    x.add_argument("--base", help="with --write: the ref the task's worktree starts from (default HEAD)")
    x.add_argument("--worktree", action="store_true", help=argparse.SUPPRESS)     # gone: refused, naming --write
    x.add_argument("--fallback", help="e.g. 'codex gpt-5.6-terra high'")
    x.add_argument("--pickup-min", type=int, default=30)
    x.add_argument("--reassign-min", type=int, default=180)
    x.add_argument("--max-open", type=int, default=2)
    x.add_argument("--prefix", default="AG")
    x.add_argument("--clip", action="store_true", help="copy the paste line to clipboard")
    x.add_argument("--profile", help="one-off profile instead of the project's (only on the operator's request)")
    x.add_argument("--force", action="store_true")
    x.set_defaults(fn=cmd_handoff_new)
    x = hs.add_parser("offer", help="put a task into the pool; the operator takes it when convenient")
    x.add_argument("--title", required=True)
    x.add_argument("--provider", default="antigravity", help="suggested manual agent")
    x.add_argument("--model")
    x.add_argument("--model-key")
    x.add_argument("--effort")
    x.add_argument("--prompt-file")
    x.add_argument("--write", action="store_true",
                   help="the task changes files: when taken it gets a worktree of its own, .orchestra/wt/<id> on "
                        "branch ag/<id> (default: read-only, in the project folder)")
    x.add_argument("--base", help="with --write: the ref the task's worktree starts from (default HEAD)")
    x.add_argument("--worktree", action="store_true", help=argparse.SUPPRESS)     # gone: refused, naming --write
    x.add_argument("--fallback")
    x.add_argument("--pickup-min", type=int, default=30)
    x.add_argument("--reassign-min", type=int, default=180)
    x.add_argument("--check-min", type=int, default=POOL_CHECK_MIN,
                   help="pool check interval: an event every N min without a take (pool-wide; the latest offer sets it)")
    x.add_argument("--max-offers", type=int, default=5)
    x.add_argument("--prefix", default="AG")
    x.add_argument("--profile")
    x.add_argument("--force", action="store_true")
    x.set_defaults(fn=cmd_handoff_offer)
    x = hs.add_parser("take", help="the operator takes a pooled task: TASK.md (and a worktree for a task that changes files), paste line")
    x.add_argument("id")
    x.add_argument("--agent", help="manual agent that takes it (default: the suggested one)")
    x.add_argument("--model")
    x.add_argument("--model-key")
    x.add_argument("--effort")
    x.add_argument("--max-open", type=int, default=2)
    x.add_argument("--clip", action="store_true")
    x.add_argument("--profile")
    x.add_argument("--force", action="store_true")
    x.set_defaults(fn=cmd_handoff_take)
    x = hs.add_parser("reclaim", help="take a pooled task back for an automated executor")
    x.add_argument("id")
    x.add_argument("--next", action="store_true",
                   help="the one-at-a-time reclaim of a pool check (refused while the previous one is running)")
    x.add_argument("--note")
    x.set_defaults(fn=cmd_handoff_reclaim)
    x = hs.add_parser("hold", help="hold a pooled task at the operator's request")
    x.add_argument("id")
    x.add_argument("--until", help="when the hold expires (as for orch quota set --until)")
    x.add_argument("--off", action="store_true")
    x.add_argument("--note")
    x.set_defaults(fn=cmd_handoff_hold)
    x = hs.add_parser("list")
    x.add_argument("--all", action="store_true")
    x.add_argument("--json", action="store_true")
    x.set_defaults(fn=cmd_handoff_list)
    x = hs.add_parser("check")
    x.add_argument("--quiet", action="store_true")
    x.add_argument("--peek", action="store_true", help="do not mark events as reported")
    x.set_defaults(fn=cmd_handoff_check)
    x = hs.add_parser("wait")
    x.add_argument("ids", nargs="*")
    x.add_argument("--any", action="store_true")
    x.add_argument("--timeout", default="8h")
    x.add_argument("--interval", type=int, default=15)
    x.set_defaults(fn=cmd_handoff_wait)
    x = hs.add_parser("show")
    x.add_argument("id")
    x.set_defaults(fn=cmd_handoff_show)
    x = hs.add_parser("done")
    x.add_argument("id")
    x.add_argument("--status", default="DONE")
    x.add_argument("--note")
    x.add_argument("--force", action="store_true")
    x.set_defaults(fn=cmd_handoff_done)
    x = hs.add_parser("cancel")
    x.add_argument("id")
    x.add_argument("--note")
    x.add_argument("--reassigned", action="store_true")
    x.set_defaults(fn=lambda a: cmd_handoff_done(SimpleNamespace(
        id=a.id, status="REASSIGNED" if a.reassigned else "CANCELLED", note=a.note, force=True)))
    x = hs.add_parser("close")
    x.add_argument("id")
    x.add_argument("--remove-worktree", action="store_true", help="after merging a task that changed files: remove its worktree")
    x.add_argument("--force", action="store_true", help="remove the worktree even with uncommitted changes")
    x.set_defaults(fn=cmd_handoff_close)

    g = sub.add_parser("registry", help="model registry (providers.yaml)")
    g.add_argument("action", choices=("path", "show", "init", "diff"),
                   help="init: copy the built-in registry to edit; diff: what the copy in effect changes, vs. the "
                        "built-in one")
    g.add_argument("--project", action="store_true", help="init into project .orchestra/ instead of ~/.orchestra/")
    g.add_argument("--force", action="store_true")
    g.add_argument("--accept", action="store_true",
                   help="diff: record the built-in registry's current version and hash in the copy as current")
    g.set_defaults(fn=cmd_registry)

    d = sub.add_parser("doctor", help="environment check")
    d.set_defaults(fn=cmd_doctor)

    u = sub.add_parser("usage", help="per session: which model did what, tokens (Claude + CLI executors + manual)")
    u.add_argument("--session", help="session id or prefix (default: current, else the latest of this project)")
    u.add_argument("--list", action="store_true", help="recent sessions of this project")
    u.add_argument("--limit", type=int, default=10)
    u.add_argument("--json", action="store_true")
    u.set_defaults(fn=cmd_usage)

    x = sub.add_parser("guide", help="reference parts of the orchestrate skill (manual, profiles, quota, …)")
    x.add_argument("topic", nargs="?")
    x.set_defaults(fn=cmd_guide)

    x = sub.add_parser("footprint", help="what Orchestra created outside Claude Code (cleanup list)")
    x.set_defaults(fn=cmd_footprint)

    k = sub.add_parser("key", help=argparse.SUPPRESS)      # internal: the apiKeyHelper command, hidden from --help
    k.add_argument("profile", help=argparse.SUPPRESS)
    k.set_defaults(fn=cmd_key)

    k = sub.add_parser("hook", help="Claude Code hook entry point (internal)")
    k.add_argument("event", choices=HOOK_EVENTS)
    k.add_argument("--throttle", type=int, default=60, help="post-tool: min seconds between checks")
    k.set_defaults(fn=cmd_hook)

    tail = []
    if argv[:1] == ["launch"] and "--" in argv:        # everything after -- goes to claude untouched
        argv, tail = argv[:argv.index("--")], argv[argv.index("--") + 1:]
    a, extra = p.parse_known_args(argv)
    if a.cmd == "launch":
        a.claude_args = tail
    if extra and a.cmd == "run" and not any(x.startswith("-") for x in extra):
        a.prompt = (a.prompt or []) + extra      # argparse < 3.13 leaves `run … --opt v "text"` text unparsed
    elif extra:
        p.error("unrecognized arguments: %s" % " ".join(extra))
    return a


def main(argv=None):
    utf8_stdio()
    argv = sys.argv[1:] if argv is None else list(argv)
    a = statusline_args(argv) or hook_args(argv) or parse_args(argv)
    global _quiet_state, _statusline_run
    _quiet_state = a.cmd in ("hook", "statusline")
    _statusline_run = a.cmd == "statusline"
    if a.cmd == "handoff":
        refuse_in_worker()
    try:
        return a.fn(a) or 0
    except StateError as ex:
        if _quiet_state:
            return 0
        print("orch: %s" % ex, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
