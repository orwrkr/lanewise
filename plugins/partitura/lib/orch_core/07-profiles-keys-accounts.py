# ───────────────────────── profiles (keys/accounts, models, rules; default and per project) ─────────────────────────
#
# ~/.partitura/profiles.json:
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
    data["_readme"] = ("Partitura executor profiles: orch profile list|show|use|set|rm. "
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


def key_origin(var):
    """Where the key variable `var` is set: "environment", the secrets file's path, or None. Never the value."""
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
        parts.append("key %s %s" % (d["key"], "✔" if key_origin(d["key"]) else "✘ not in secrets.env"))
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


