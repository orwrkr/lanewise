# ───────────────────────── hooks (orch hook) and handoff wait, show, done, close ─────────────────────────

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
            try:                      # a detected lead has already started: the spend check is a warning only
                warning = detected_lead_spend_line()
                if warning:
                    print(warning)
            except Exception:
                pass
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
    with state_lock(state_dir(create=True) / ".state.lock"):
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


