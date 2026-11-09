# ───────────────────────── a non-Claude lead (orch launch) ─────────────────────────

SECRET_VAR_RE = re.compile(r"KEY|TOKEN|SECRET|PASSWORD", re.I)


def masked(name, value):
    return (value[:4] + "…" + value[-2:] if len(value) > 10 else "…") if SECRET_VAR_RE.search(name) else value


LEAD_VIA_DETECTED = "detected"
# The variables an override sets for a session started by hand: they are the lead's, not an executor's.
LEAD_OVERRIDE_VARS = ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
                      "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
                      "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                      "CLAUDE_CODE_SUBAGENT_MODEL")


def lead_via_text():
    """'(orch launch)' or '(detected: ANTHROPIC_BASE_URL)' for the Lead line and the doctor's row."""
    return "(detected: ANTHROPIC_BASE_URL)" if os.environ.get("ORCH_LEAD_VIA") == LEAD_VIA_DETECTED else "(orch launch)"


def normalize_endpoint(url):
    """scheme://host[:port][/path] with a lowercase host and no trailing slash; None when it is not an http(s) URL."""
    from urllib.parse import urlsplit
    try:
        p = urlsplit(str(url or "").strip())
        scheme = p.scheme.lower()
        port = p.port
    except ValueError:
        return None
    if scheme not in ("http", "https") or not p.hostname:
        return None
    host = p.hostname.lower()
    if port is not None and (scheme, port) not in (("http", 80), ("https", 443)):
        host += ":%d" % port
    return "%s://%s%s" % (scheme, host, p.path.rstrip("/"))


def lead_endpoints():
    """{normalised endpoint: provider} of the adapters that can lead a session (`# orch-launch: env` and
    `# orch-endpoint:`). The adapter's own `base_url` variable (ORCH_DEEPSEEK_BASE_URL) is accepted too."""
    out = {}
    seen = set()
    for base in (ORCH_HOME / "adapters", PLUGIN_ROOT / "adapters"):
        try:
            adapters = sorted(base.iterdir())
        except OSError:
            continue
        for adapter in adapters:
            name = adapter.name.lower()
            try:
                is_file = adapter.is_file()
            except OSError:
                is_file = False
            if not is_file or name.startswith(("_", ".")) or name in seen:
                continue
            seen.add(name)                     # a user adapter replaces the built-in one, launch support included
            directives = adapter_directives(adapter_head(adapter))
            if directives.get("launch") != "env":
                continue
            urls = [directives.get("endpoint")]
            override = profile_env_map(directives).get("base_url")
            if override:
                urls.append(os.environ.get(override))
            for url in urls:
                key = normalize_endpoint(url)
                if key:
                    out.setdefault(key, name)
    return out


def lead_token():
    return (os.environ.get("ANTHROPIC_AUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY") or "").strip()


def detect_lead_label(provider, token):
    """(label, matched) for the provider an endpoint belongs to: the profile whose key is the token (preferring the
    one this project resolves to), else the bare provider. `matched` is False only when the token is none of the
    profile keys and not the provider's default key variable. The token is never stored or printed."""
    data, err = load_profiles()
    if err:
        return provider, False
    sec, profs = provider_section(data, provider)
    stored = None

    def secret(var):
        nonlocal stored
        val = os.environ.get(str(var))
        if val:
            return val.strip()
        if stored is None:
            stored = load_secrets()
        return (stored.get(str(var)) or "").strip()

    matches = []
    if token:
        for name in sorted(profs):
            d = profs.get(name)
            var = d.get("key") if isinstance(d, dict) else None
            if var and secret(var) == token:
                matches.append(provider + "@" + name)
    if matches:
        try:
            resolved = resolve_profile(provider, project_dir(), follow=False).label
        except Exception:
            resolved = None
        if resolved in matches:
            return resolved, True
        default = str(sec.get("default")).lower() if sec.get("default") else None
        preferred = provider + "@" + default if default else None
        return (preferred if preferred in matches else matches[0]), True
    adapter = find_adapter(provider)
    default_vars = adapter_directives(adapter_head(adapter)).get("secrets", "").split() if adapter else []
    if token and any(secret(v) == token for v in default_vars):
        return provider, True
    return provider, False


def detect_lead():
    """A Claude Code session started by hand with its own ANTHROPIC_BASE_URL override is a non-Claude lead when the
    endpoint is one an adapter declares (`# orch-endpoint:`). Sets the variables `orch launch` sets, so every reader
    of ORCH_LEAD treats the session alike. Never prints, never raises: an error leaves it a Claude session."""
    try:
        if os.environ.get("ORCH_LEAD") or os.environ.get("ORCH_WORKER"):
            return None
        base = os.environ.get("ANTHROPIC_BASE_URL")
        if not base or not base.strip():
            return None                    # the common path: no file is read
        provider = lead_endpoints().get(normalize_endpoint(base))
        if not provider:
            return None                    # Anthropic itself, a corporate gateway or another proxy is no lead
        label, matched = detect_lead_label(provider, lead_token())
        os.environ.update({
            "ORCH_LEAD": label,
            "ORCH_LEAD_MODEL": os.environ.get("ANTHROPIC_MODEL") or "",
            "ORCH_LEAD_ENV": ",".join(sorted(v for v in LEAD_OVERRIDE_VARS if os.environ.get(v))),
            "ORCH_LEAD_VIA": LEAD_VIA_DETECTED,
        })
        if not matched:
            os.environ["ORCH_LEAD_KEY"] = "none"
        return label
    except Exception:
        return None


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
    note = (" Its token is none of your profiles' keys, so this session's spend is not under a profile's limit."
            if os.environ.get("ORCH_LEAD_KEY") == "none" else "")
    return ("Lead: %s · %s %s — you are not Claude; orch-* subagents run on this model too. Claude: %s.%s "
            "Read `orch guide lead` before planning." % (
                scope_name(lead), display_name(os.environ.get("ORCH_LEAD_MODEL")) or "?", lead_via_text(), lane, note))


def detected_lead_spend_line():
    """The line `spend_lead_start` gives for a detected lead: its session has already started, so it is a warning,
    never a refusal. None in a launched or Claude-led session, or when there is nothing to say."""
    lead = (os.environ.get("ORCH_LEAD") or "").strip().lower()
    if not lead or os.environ.get("ORCH_LEAD_VIA") != LEAD_VIA_DETECTED:
        return None
    provider, _, name = lead.partition("@")
    scope = lead if name else provider
    return spend_lead_start(scope, project_dir())[1] if scope else None


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
    # a terminal that is itself a detected lead must not mark the launched session as detected
    lead = {k: v for k, v in os.environ.items() if k not in unset and k not in ("ORCH_LEAD_VIA", "ORCH_LEAD_KEY")}
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


