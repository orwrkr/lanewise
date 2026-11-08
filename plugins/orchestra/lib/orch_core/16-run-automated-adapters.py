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
    run_dir = state_dir(create=True) / "runs" / run_id
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


