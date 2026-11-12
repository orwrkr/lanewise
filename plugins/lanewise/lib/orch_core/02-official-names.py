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
def state_lock(path, wait=None):
    """Reentrant process lock on a stable sidecar file; the OS releases it on process death. `wait` overrides the
    usual wait: 0 makes the call non-blocking (`orch migrate` checks the home's locks this way)."""
    path = Path(path)
    key = os.path.normcase(str(path.resolve()))
    if key in _held_locks:
        yield
        return
    if not path.parent.is_dir():
        path.parent.mkdir(parents=True, exist_ok=True)
    if wait is None:
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
            if scope == "home":
                path = ORCH_HOME / ".state.lock"
            else:
                d = state_dir()
                if not d.is_dir():       # a folder the plugin never used: nothing to protect, and nothing to create
                    return fn(*args, **kwargs)
                path = d / ".state.lock"
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
                                    SPEND_FILE, SPEND_CACHE_FILE, SPEND_EVENTS_FILE, BALANCE_FILE, WATCH_FILE,
                                    DAILY_FILE)
        if home_state:
            try:                     # write_json replaces a file atomically: only preserving a corrupt one takes the lock
                return _read_json(path, default, False, object_required)
            except StateError:
                pass
            lock = ORCH_HOME / ".state.lock"
        else:
            d = state_dir()
            if not d.is_dir():       # no project state yet: there is nothing to preserve, and nothing to create
                return _read_json(path, default, False, object_required)
            lock = d / ".state.lock"
        with state_lock(lock):
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


def state_dir_name(where=None):
    """The name of the project's state folder in use: the first that exists of .lanewise, .partitura (before
    0.36.0) and .orchestra (before 0.35.0), else .lanewise (a new project). They are never merged."""
    proj = Path(where) if where is not None else project_dir()
    for name in (STATE_DIR_NAME,) + LEGACY_STATE_DIR_NAMES:
        if (proj / name).exists():
            return name
    return STATE_DIR_NAME


def state_dir(create=False):
    """<project>/.lanewise, or an older name (.partitura, .orchestra) while a project keeps it. Creation is explicit:
    a command that only reads must not leave one in a folder where the plugin was never used (README: "projects
    where the plugin was never used get nothing")."""
    p = project_dir() / state_dir_name()
    if create and not p.exists():
        p.mkdir(parents=True, exist_ok=True)
        ensure_git_exclude(project_dir())
    return p


def git_exclude_file(proj):
    """The info/exclude of the repository that owns proj (the common git directory, shared by all worktrees)."""
    r = git(["rev-parse", "--git-common-dir"], proj)
    if r is None or r.returncode != 0:
        return None
    common = Path(r.stdout.strip())
    if not common.is_absolute():
        common = (proj / common).resolve()
    return common / "info" / "exclude"


def ensure_git_exclude(proj, patterns=None):
    """Keep the plugin's files out of git status without touching .gitignore (shared by all worktrees). The default
    pattern is the project's state folder, whichever name it uses."""
    excl = git_exclude_file(proj)
    if excl is None:
        return
    if patterns is None:
        patterns = (state_dir_name(proj) + "/",)
    excl.parent.mkdir(parents=True, exist_ok=True)
    text = excl.read_text(encoding="utf-8") if excl.exists() else ""
    missing = [p for p in patterns if p not in text.split()]
    if missing:
        with excl.open("a", encoding="utf-8") as f:
            if text and not text.endswith("\n"):
                f.write("\n")
            f.write("# lanewise plugin state\n" + "".join(p + "\n" for p in missing))


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


