# ───────────────────────── manual pool clock, board and events ─────────────────────────

POOL_CHECK_MIN = 5
ASSIGNMENT_TIMEOUT_MIN = 10


def pool_state(pool_ids, check_min=None):
    """<state>/handoffs/.pool.json: pooled ids, when the pool opened, its check interval, the last check reported.
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
    """<project>/.partitura/MANUAL.md (or the old .orchestra/) — the manual lane at a glance for the operator (any
    editor or the agent's IDE)."""
    every = all_metas()
    metas = [m for m in every if not m.get("archived")]
    states = {m["id"]: result_status(m) for m in metas}       # no workdir scans: the board is rewritten from hooks
    pool = [m for m in metas if states[m["id"]] == "OFFERED"]
    state = pool_state(sorted(m["id"] for m in pool))
    out = [m for m in metas if states[m["id"]] in OPEN_TAKEN]
    # a closed task is archived: it still belongs under "Recently finished", which close must not empty
    done = sorted((m for m in every if result_status(m) in TERMINAL),
                  key=lambda m: m.get("closed") or (m.get("notified") or {}).get("final") or m.get("created") or "")[-10:]
    lines = ["# Partitura manual tasks", "",
             "Updated %s · `%s` · maintained by orch, do not edit." % (now().strftime("%Y-%m-%d %H:%M"), project_dir()),
             "Take from the pool: tell the orchestrator “AG-0004 to Antigravity” "
             "(or `/partitura:manual AG-0004 to Antigravity`). Done / cancel: “AG-0004 done” / “AG-0004: cancel”.", "",
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
        lines.append("- %s %s — %s%s" % (m["id"], result_status(m), m["title"],
                                         " (%s)" % (agent_reported(m) or agent_name(m.get("provider"))) if m.get("taken") else ""))
    lines += [] if done else ["_none_"]
    (state_dir(create=True) / "MANUAL.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


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
        print("Partitura: manual lane events\n" + "\n".join(events))
    elif not a.quiet:
        print("No new events.")
    return 0


