# Shared runner of Orchestra's headless Claude Code executors (adapters `claude` and `deepseek`).
#
# Not an adapter itself: orch ignores adapter names that start with "_". The adapters import it from their own
# directory, so if you override one of them in ~/.orchestra/adapters, copy this file next to it.
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

EFFORTS = ("low", "medium", "high", "xhigh", "max")
GIT_READ = ["Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git blame:*)"]
# Never let a worker read secret files; whatever it reads goes to its provider. A deny outranks an allow, so `.env.*`
# covers `.env.example` too: a tracked one stays readable with `git show HEAD:.env.example`. Claude Code applies Read
# rules to a Bash command that names the file (`cat .env`), but a search that walks the tree prints what it finds in
# ignored files, and it auto-approves such commands as read-only. So those are denied: the Grep tool does the same job
# and skips ignored and hidden files.
SECRET_DENY = ["Read(**/.env)", "Read(**/.env.*)",
               "Bash(grep *)", "Bash(egrep *)", "Bash(fgrep *)", "Bash(rg *)", "Bash(ag *)", "Bash(ack *)",
               "Bash(git grep *--no-index*)", "Bash(git grep *--untracked*)"]
EXIT_QUOTA = 75
KEEP_CLAUDE_VARS = ("CLAUDE_CODE_GIT_BASH_PATH",)


def utf8_stdio():
    for stream in (sys.stdout, sys.stderr):     # the run log is UTF-8; Windows pipes/files default to the ANSI page
        stream.reconfigure(encoding="utf-8", errors="replace")


def one_line(text, n):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[:n] + "…"


def brief(tool_input):
    if not isinstance(tool_input, dict):
        return one_line(tool_input, 160)
    for k in ("command", "file_path", "pattern", "path", "url"):
        if tool_input.get(k):
            return one_line(tool_input[k], 160)
    return one_line(json.dumps(tool_input, ensure_ascii=False), 160)


def find_claude():
    return os.environ.get("ORCH_CLAUDE_BIN") or shutil.which("claude")


def lead_vars():
    """Variables a non-Claude lead session (`orch launch`) set for itself: its API endpoint, token and models."""
    return {v for v in os.environ.get("ORCH_LEAD_ENV", "").split(",") if v}


def base_env(keep=(), drop_anthropic=False):
    """The adapter's environment without the orchestrating session: no CLAUDECODE / CLAUDE_* (a nested `claude` would
    attach to that session), no variables of a non-Claude lead, optionally no ANTHROPIC_* at all."""
    lead = lead_vars()
    return {k: v for k, v in os.environ.items()
            if not (k == "CLAUDECODE" or k in lead or (drop_anthropic and k.startswith("ANTHROPIC_"))
                    or (k.startswith("CLAUDE_") and k not in KEEP_CLAUDE_VARS and k not in keep))}


def system_prompt(run_dir):
    """Executor role + project rules. --setting-sources user skips the project's CLAUDE.md, and Claude Code never
    reads AGENTS.md: orch hands both over in ORCH_CONTEXT_FILE (@imports already inlined)."""
    parts = []
    for var in ("ORCH_ROLE_FILE", "ORCH_CONTEXT_FILE"):
        p = os.environ.get(var)
        if p and Path(p).is_file():
            parts.append(Path(p).read_text(encoding="utf-8"))
    out = run_dir / "system.md"
    out.write_text("\n\n---\n\n".join(parts), encoding="utf-8")
    return out


def tool_policy():
    """analysis → Read/Grep/Glob + read-only git; write → plus Edit/Write inside ORCH_CWD; other commands only via
    `orch run --allow RULE`."""
    allowed = GIT_READ + [r.strip() for r in os.environ.get("ORCH_ALLOW", "").splitlines() if r.strip()]
    if os.environ.get("ORCH_MODE") == "write":
        # `/**` in a CLI rule anchors at the primary working directory; `./**` follows the worker's `cd`, which would
        # silently shrink its write scope to wherever it last went.
        return "Read,Grep,Glob,Edit,Write,Bash", ["Edit(/**)", "Write(/**)"] + allowed
    return "Read,Grep,Glob,Bash", allowed


def settings_deny():
    """The target project's permissions.deny Read/Bash rules. `--setting-sources user` skips the project's
    settings, so orch forwards the deny rules the worker would otherwise lose."""
    deny = []
    d = Path(os.environ.get("ORCH_CWD") or ".").resolve()
    for _ in range(8):
        for name in ("settings.json", "settings.local.json"):
            p = d / ".claude" / name
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            perms = data.get("permissions") if isinstance(data, dict) else None
            rules = perms.get("deny") if isinstance(perms, dict) else None
            if isinstance(rules, list):
                for rule in rules:
                    if isinstance(rule, str) and rule.split("(", 1)[0] in ("Read", "Bash"):
                        deny.append(rule)
        if (d / ".git").exists() or (d / ".orchestra").exists():
            break
        if d.parent == d:
            break
        d = d.parent
    return list(dict.fromkeys(deny))


def disallowed_tools():
    return SECRET_DENY + settings_deny()


def command(claude, model, run_dir, isolation, extra_args, say):
    """`claude -p` in stream-json with the executor's tools, role and project rules."""
    tools, allowed = tool_policy()
    cmd = [sys.executable, claude] if claude.endswith(".py") else [claude]
    cmd += ["-p", "--model", model, "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--strict-mcp-config"] + list(isolation) + ["--permission-mode", "dontAsk", "--tools", tools,
                                                        "--append-system-prompt-file", str(system_prompt(run_dir))]
    effort = (os.environ.get("ORCH_EFFORT") or "").lower()
    if effort in EFFORTS:
        cmd += ["--effort", effort]
    elif effort:
        say("effort %r is not supported (%s) — keeping the default" % (effort, "|".join(EFFORTS)))
    disallowed = disallowed_tools()
    cmd += shlex.split(extra_args or "")
    cmd += ["--disallowedTools"] + disallowed + ["--allowedTools"] + allowed    # variadic options: allowed last
    say("model=%s mode=%s tools=%s allow=%s deny=%s" % (model, os.environ.get("ORCH_MODE"), tools,
                                                        " ".join(allowed), " ".join(disallowed)))
    return cmd


def clean_live_usage(u, model):
    """A message's usage → the ledger shape: uncached input (incl. cache writes), cache reads, output."""
    return {"input_tokens": int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0),
            "cached_input_tokens": int(u.get("cache_read_input_tokens") or 0),
            "output_tokens": int(u.get("output_tokens") or 0), "model": model}


def write_live(run_dir, live):
    """The running total of a run's token usage → usage_live.json (for orch's mid-run spend check)."""
    total = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
    per_model = {}
    for u in live.values():
        total["input_tokens"] += u["input_tokens"]
        total["cached_input_tokens"] += u["cached_input_tokens"]
        total["output_tokens"] += u["output_tokens"]
        t = per_model.setdefault(u["model"], {"input_tokens": 0, "output_tokens": 0})
        t["input_tokens"] += u["input_tokens"]
        t["output_tokens"] += u["output_tokens"]
    if per_model:
        total["model"] = max(per_model, key=lambda m: per_model[m]["output_tokens"])
        if len(per_model) > 1:
            total["models"] = per_model
    path = Path(run_dir) / "usage_live.json"
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(json.dumps(total), encoding="utf-8")
        os.replace(tmp, path)                 # atomic: orch never reads a half-written total
    except OSError:
        pass


def run(cmd, env):
    """Run the worker on ORCH_PROMPT_FILE; condense stream-json into the run log. → (result event or None, rc)."""
    run_dir = Path(os.environ["ORCH_RUN_DIR"])
    live = {}                      # message id → usage, so the running total never double-counts a resend
    with open(os.environ["ORCH_PROMPT_FILE"], "rb") as prompt:
        proc = subprocess.Popen(cmd, cwd=os.environ["ORCH_CWD"], env=env, stdin=prompt, stdout=subprocess.PIPE)
        result = None
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                print(line, flush=True)
                continue
            kind = ev.get("type")
            if kind == "assistant":
                msg = ev.get("message") or {}
                mid, model, u = msg.get("id"), msg.get("model"), msg.get("usage") or {}
                if mid and model and isinstance(u, dict) and not str(model).startswith("<"):
                    live[mid] = clean_live_usage(u, model)
                    write_live(run_dir, live)
            content = (ev.get("message") or {}).get("content") if kind in ("assistant", "user") else None
            for block in content if isinstance(content, list) else []:
                if block.get("type") == "tool_use":
                    print("→ %s %s" % (block.get("name"), brief(block.get("input"))), flush=True)
                elif block.get("type") == "text" and block.get("text", "").strip():
                    print("· " + one_line(block["text"], 300), flush=True)
                elif block.get("type") == "tool_result" and block.get("is_error"):
                    print("  ✘ " + one_line(block.get("content"), 200), flush=True)
            if kind == "result":
                result = ev
        return result, proc.wait()


def write_usage(run_dir, result, model):
    """Token usage of the run (result event of stream-json) → usage.json for the orch usage log."""
    u = result.get("usage") if isinstance(result.get("usage"), dict) else None
    if not u:
        return
    per_model = result.get("modelUsage") if isinstance(result.get("modelUsage"), dict) else {}
    per_model = {m: v for m, v in per_model.items() if isinstance(v, dict)}
    if per_model:                # the model id the API reports (an alias such as "sonnet" resolves to it)
        model = max(per_model, key=lambda m: int(per_model[m].get("outputTokens") or 0))
    usage = {"input_tokens": int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0),
             "cached_input_tokens": int(u.get("cache_read_input_tokens") or 0),
             "output_tokens": int(u.get("output_tokens") or 0), "model": model}
    if len(per_model) > 1:       # e.g. the fast model of background calls
        usage["models"] = {m: {"input_tokens": int(v.get("inputTokens") or 0),
                               "output_tokens": int(v.get("outputTokens") or 0)} for m, v in per_model.items()}
    (run_dir / "usage.json").write_text(json.dumps(usage), encoding="utf-8")


def write_output(result):
    """The worker's answer → ORCH_OUTPUT_FILE, with the actions its permissions refused listed at the end."""
    text = result.get("result") or ""
    denied = ["%s %s" % (d.get("tool_name"), brief(d.get("tool_input"))) for d in result.get("permission_denials") or []]
    if denied:
        text += "\n\n---\n[orch] denied by the executor's permissions (grant: orch run … --allow 'Bash(<command>:*)'):\n" + \
            "\n".join("- " + d for d in denied[:15])
    Path(os.environ["ORCH_OUTPUT_FILE"]).write_text(text, encoding="utf-8")
