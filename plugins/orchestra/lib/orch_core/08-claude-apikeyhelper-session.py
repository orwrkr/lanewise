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


