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


def build_parser():
    """The whole command tree: subcommands, nested subcommands and options. Built once per `parse_args` call; the
    self-test builds it too, to check that the commands the docs name still exist here."""
    import argparse
    p = argparse.ArgumentParser(prog="orch", description="Partitura helper CLI")
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

    pp = sub.add_parser("prices", help="the price table behind spend estimates: show, check (task for a web agent), "
                                       "diff / apply (a proposal from its report)")
    pp.add_argument("--json", action="store_true", help="show: machine-readable")
    pp.set_defaults(fn=cmd_prices, action="show")
    ps = pp.add_subparsers(dest="action")
    x = ps.add_parser("show", help="the effective prices, their dates and where they come from (default)")
    x.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    x = ps.add_parser("check", help="write TASK.md for an agent with web access to read the official price pages")
    x.add_argument("--provider", action="append", metavar="P", help="only this provider (repeatable); default: all")
    x = ps.add_parser("diff", help="what a proposal (JSON, or a report with a fenced json block) would change")
    x.add_argument("file", metavar="FILE")
    x = ps.add_parser("apply", help="write a proposal to the personal prices.json (only with --yes)")
    x.add_argument("file", metavar="FILE")
    x.add_argument("--provider", action="append", metavar="P", help="only this provider (repeatable)")
    x.add_argument("--model", action="append", metavar="M", help="only this model key (repeatable)")
    x.add_argument("--yes", action="store_true", help="write; without it only the diff is shown")

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
                   help="the task changes files: it gets a worktree of its own, .partitura/wt/<id> on branch ag/<id> "
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
                   help="the task changes files: when taken it gets a worktree of its own, .partitura/wt/<id> on "
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
                        "built-in one; show: the registry in brief (slots and routes)")
    g.add_argument("provider", nargs="?",
                   help="show: that provider in full (its notes, slots and routes) instead of the brief view")
    g.add_argument("--full", action="store_true", help="show: the whole file")
    g.add_argument("--json", action="store_true", help="show: the parsed registry as JSON")
    g.add_argument("--project", action="store_true", help="init into the project's .partitura/ instead of ~/.partitura/")
    g.add_argument("--force", action="store_true")
    g.add_argument("--accept", action="store_true",
                   help="diff: record the built-in registry's current version and hash in the copy as current")
    g.set_defaults(fn=cmd_registry)

    d = sub.add_parser("doctor", help="environment check")
    d.set_defaults(fn=cmd_doctor)

    u = sub.add_parser("usage", help="per session: which model did what, tokens (Claude + CLI executors + manual)")
    u.add_argument("--session", help="session id or prefix (default: current, else the latest of this project); "
                                     "`none` shows records made outside a session")
    u.add_argument("--list", action="store_true", help="recent sessions of this project (and its records outside one)")
    u.add_argument("--limit", type=int, default=10)
    u.add_argument("--json", action="store_true")
    u.set_defaults(fn=cmd_usage)

    x = sub.add_parser("guide", help="reference parts of the orchestrate skill (manual, profiles, quota, …)")
    x.add_argument("topic", nargs="?")
    x.set_defaults(fn=cmd_guide)

    x = sub.add_parser("footprint", help="what Partitura created outside Claude Code (cleanup list)")
    x.set_defaults(fn=cmd_footprint)

    x = sub.add_parser("migrate", help="move the old .orchestra folders to .partitura (dry run by default)")
    x.add_argument("path", nargs="?", metavar="PATH", help="one project (default: the current one)")
    x.add_argument("--all", action="store_true", help="every project the plugin knows (usage ledger and profiles)")
    x.add_argument("--home", action="store_true", help="the personal folder (the old ~/.orchestra)")
    x.add_argument("--yes", action="store_true", help="move; without it only what would move is printed")
    x.set_defaults(fn=cmd_migrate)

    k = sub.add_parser("key", help=argparse.SUPPRESS)      # internal: the apiKeyHelper command, hidden from --help
    k.add_argument("profile", help=argparse.SUPPRESS)
    k.set_defaults(fn=cmd_key)

    k = sub.add_parser("hook", help="Claude Code hook entry point (internal)")
    k.add_argument("event", choices=HOOK_EVENTS)
    k.add_argument("--throttle", type=int, default=60, help="post-tool: min seconds between checks")
    k.set_defaults(fn=cmd_hook)

    return p


def parse_args(argv):
    p = build_parser()

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
    detect_lead()              # a session with its own ANTHROPIC_* override is a lead for every command, hook too
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
