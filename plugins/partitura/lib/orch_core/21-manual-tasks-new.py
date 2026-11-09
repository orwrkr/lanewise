# ───────────────────────── manual tasks (new, offer, take, reclaim, hold, list) ─────────────────────────

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
    (handoffs_root(create=True) / hid / "BODY.md").write_text(body, encoding="utf-8")
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
    """The one general Antigravity rule of the project folder, written when absent or different. The same rule under
    its name before 0.34.0 goes away, so that Antigravity never reads it twice."""
    try:
        (proj / LEGACY_AG_RULE_PATH).unlink()
    except OSError:
        pass
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
        workdir, branch = make_worktree(hid, m.get("base") or "HEAD", "ag/" + hid.lower(), root=state_dir(create=True) / "wt")
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
    with state_lock(state_dir(create=True) / ".state.lock"):
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
    with state_lock(state_dir(create=True) / ".state.lock"):
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
        with state_lock(state_dir(create=True) / ".state.lock"):
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
        wt = state_dir(create=True) / "wt" / claim["id"]
        left = quietly(worktree_branch_at, wt, project_dir()) if task_writes(claim) else None
        with state_lock(state_dir(create=True) / ".state.lock"):
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
    with state_lock(state_dir(create=True) / ".state.lock"):
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
    with state_lock(state_dir(create=True) / ".state.lock"):
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


